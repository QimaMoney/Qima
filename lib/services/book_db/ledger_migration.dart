import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter/foundation.dart' show debugPrint;

import '../../models/book_account.dart';
import '../../models/money_settings.dart';
import 'book_database.dart';
import 'db_records.dart';
import 'ledger_plan.dart';

/// What [LedgerMigration.collapseTrades] did.
enum LedgerStep {
  /// It ran now.
  done,

  /// It had been done before.
  alreadyDone,

  /// It must wait for the old JSON file of the entries to be read.
  waiting,
}

/// Moves the book from the collections earlier builds kept (`book.*`,
/// `money.settings`) to the ledger ones (`ledger.*`), locally, and makes
/// every holdings trade one entry.
///
/// Both steps are lazy: the first read or write of any ledger collection, in
/// any isolate, runs [ensure] on the database it opened. Both are
/// idempotent and resumable, and safe when two isolates start them together:
/// each does its work in one transaction that takes the write lock first and
/// looks at its flag again once it holds it, so one does the work and the
/// other finds it done. A flag is set in the transaction that did the work,
/// never before.
///
/// Step A ([migrateBook], flag `migrated.ledger.book`) relabels the rows.
/// Step B ([collapseTrades], flag `migrated.ledger.holdings`) folds the
/// holdings ledger into entries, which the holdings screens then read and
/// write through `HoldingsLedger`. [ensure] runs both.
abstract final class LedgerMigration {
  static const String _lock = "DELETE FROM meta WHERE key = 'lock.ledger'";

  /// Runs the steps this build runs, once per opened database in this
  /// isolate. A failure of A is thrown to the caller and tried again by the
  /// next one; a failure of B is kept in [BookDatabase.ledgerProblems] and
  /// does not stop the book.
  static Future<void> ensure(BookDatabase db) {
    final running = db.ledgerMigration;
    if (running != null) return running;
    final run = _run(db, collapseHoldings: db.collapseHoldings);
    db.ledgerMigration = run;
    run.catchError((Object _) {
      if (identical(db.ledgerMigration, run)) db.ledgerMigration = null;
    });
    return run;
  }

  /// Both steps, without remembering that it was done. For a caller that
  /// chooses whether B runs.
  static Future<void> run(BookDatabase db, {required bool collapseHoldings}) => _run(db, collapseHoldings: collapseHoldings);

  static Future<void> _run(BookDatabase db, {required bool collapseHoldings}) async {
    await migrateBook(db);
    if (!collapseHoldings) return;
    try {
      await collapseTrades(db);
    } catch (e) {
      db.ledgerProblems[LedgerNames.flagHoldings] = e;
      debugPrint('Ledger migration: trades not collapsed this run: $e');
    }
  }

  /// The stores of the old collections, as the first builds had them.
  static List<DbRecords> _legacyStores() => [
        DocumentRecords<BookAccount>(collection: LedgerNames.legacyAccounts, filePath: LedgerNames.legacyAccountsFile, itemFromJson: BookAccount.fromJson),
        EntryRecords(collection: LedgerNames.legacyEntries, filePath: LedgerNames.legacyEntriesFile),
        DocumentRecords<RecurringPayment>(collection: LedgerNames.legacyRecurring, filePath: LedgerNames.legacyRecurringFile, itemFromJson: RecurringPayment.fromJson),
        DocumentRecords<MoneySettings>(collection: LedgerNames.legacySettings, filePath: LedgerNames.legacySettingsFile, itemFromJson: MoneySettings.fromJson),
      ];

  /// Step A. Relabels the stored rows of the four old collections as the
  /// ledger ones, in `entries`, `documents` and the `changes` log, with their
  /// ids, order, stamps and tombstones as they were (entry lines name an
  /// entry, not a collection, and need nothing).
  ///
  /// The JSON files of earlier builds are imported first, by the import the
  /// old collections have always had, so a device that never had a database
  /// ends up in the same place as one that did. A collection whose file was
  /// there but could not be read is relabelled with what the database holds
  /// and its `imported.ledger.*` flag left unset: the ledger collection then
  /// imports that file itself, on a later start, as the old one would have.
  static Future<void> migrateBook(BookDatabase db) async {
    if (await db.hasFlag(LedgerNames.flagBook)) return;
    for (final store in _legacyStores()) {
      await store.ensureImported(db);
    }
    await db.transaction(() async {
      await db.customStatement(_lock);
      if (await db.hasFlag(LedgerNames.flagBook)) return;
      final at = DateTime.now().toUtc().toIso8601String();
      for (final (from, to) in LedgerNames.collections) {
        final table = from == LedgerNames.legacyEntries ? 'entries' : 'documents';
        final rows = await _relabel(db, table, from, to);
        final logged = await _relabel(db, 'changes', from, to);
        if (await db.hasFlag('imported.$from')) await _setFlag(db, 'imported.$to');
        await db.customStatement(
          "INSERT INTO changes (at, collection, id, op, body) VALUES (?, ?, '', 'relabel', ?)",
          [at, to, jsonEncode({'from': from, 'rows': rows, 'changes': logged})],
        );
      }
      await _setFlag(db, LedgerNames.flagBook);
    });
  }

  /// Step B. Collapses the holdings ledger and the stored entries into the
  /// entries [LedgerPlan.collapse] makes, written with the ids, order and
  /// stamps it returns, in one transaction with the flag.
  ///
  /// Does nothing (and sets nothing) until the ledger entries have been
  /// imported from their old file, so the collapse never runs over half a
  /// book. Throws [LedgerSourceUnreadable] when `transactions.records.json`
  /// or `holdings.records.json` is there and cannot be read: nothing is
  /// written, no flag is set, and the book works as it did (the cash rows of
  /// trades stay as they are, so balances stay right). A trade that has the
  /// id of an entry that is not a holding is left out and the rest is
  /// collapsed; the flag is set, and the ids are kept in
  /// [BookDatabase.ledgerProblems] as a [LedgerConflict] for this run. The
  /// files are never written.
  static Future<LedgerStep> collapseTrades(BookDatabase db) async {
    if (await db.hasFlag(LedgerNames.flagHoldings)) return LedgerStep.alreadyDone;
    await migrateBook(db);
    final entries = EntryRecords(collection: LedgerNames.entries, filePath: LedgerNames.legacyEntriesFile);
    await entries.ensureImported(db);
    if (!await db.hasFlag('imported.${LedgerNames.entries}')) return LedgerStep.waiting;
    final sources = await LedgerSources.read();
    var done = false;
    LedgerConflict? conflict;
    await db.transaction(() async {
      await db.customStatement(_lock);
      if (await db.hasFlag(LedgerNames.flagHoldings)) return;
      final plan = LedgerPlan.collapse(await entries.storedIn(db), sources);
      final output = plan.records;
      await entries.writeIn(db, output);
      await db.customStatement(
        "INSERT INTO changes (at, collection, id, op, body) VALUES (?, ?, '', 'collapse', ?)",
        [DateTime.now().toUtc().toIso8601String(), LedgerNames.entries, jsonEncode({'records': output.length})],
      );
      await _setFlag(db, LedgerNames.flagHoldings);
      done = true;
      conflict = plan.conflict;
    });
    if (conflict != null) {
      db.ledgerProblems[LedgerNames.flagHoldings] = conflict!;
      debugPrint('Ledger migration: $conflict');
    }
    return done ? LedgerStep.done : LedgerStep.alreadyDone;
  }

  static Future<int> _relabel(BookDatabase db, String table, String from, String to) =>
      db.customUpdate('UPDATE $table SET collection = ? WHERE collection = ?', variables: [Variable.withString(to), Variable.withString(from)]);

  static Future<void> _setFlag(BookDatabase db, String key) => db.customStatement('INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)', [key, '1']);
}
