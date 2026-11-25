import 'dart:async';

import '../../models/book_account.dart';
import '../../models/book_entry.dart';
import '../../models/money_settings.dart';
import '../../models/syncable.dart';
import '../local_file_store.dart';
import '../synced_store.dart';
import 'ledger_plan.dart';

/// The ledger migration for storage that is JSON files (the web build, which
/// has no database): the same result as `LedgerMigration`, over files.
///
/// Step A reads the four old files, which it never writes, and writes
/// `ledger.accounts.json`, `ledger.recurring.json`, `ledger.settings.json` and
/// `ledger.entries.json`, then the marker `ledger.migrated.book.json`.
/// Nothing reads or writes a ledger file before that marker, and each file is
/// written whole from the old ones, so a run that stopped half way is run
/// again from the start and writes the same files.
///
/// Step B (unless a caller asks for it not to run) collapses the holdings trades into the entries. When A and B are done
/// together the entries are written already collapsed. When B comes to a book
/// that A migrated earlier it rewrites `ledger.entries.json`, with a
/// `collapsed` key in the same file, then writes the marker
/// `ledger.migrated.holdings.json`; a run that stopped between the two finds
/// the key and writes only the marker, so the collapse is never run over its
/// own output.
abstract final class LedgerJsonMigration {
  static Future<void>? _running;

  /// Runs what is not done yet, if this build runs it. Calls that overlap
  /// share one run, and a call after it re-checks the markers, so nothing
  /// that was written after the markers is written over.
  static Future<void> ensure({bool collapseHoldings = true}) {
    final running = _running;
    if (running != null) return running;
    final run = _run(collapseHoldings).whenComplete(() => _running = null);
    _running = run;
    return run;
  }

  static Future<bool> _marked(String marker) async => (await LocalFileStore.readJsonStrict(marker)) != null;

  static Future<void> _mark(String marker) => _write(marker, {'done': 1});

  static Future<void> _write(String file, Map<String, dynamic> json) async {
    if (!await LocalFileStore.writeJson(file, json)) throw StateError('The book file $file could not be written.');
  }

  static Future<void> _run(bool collapse) async {
    final bookDone = await _marked(LedgerNames.markerBookFile);
    if (!bookDone) {
      final accounts = await _read<BookAccount>(LedgerNames.legacyAccountsFile, BookAccount.fromJson);
      final recurring = await _read<RecurringPayment>(LedgerNames.legacyRecurringFile, RecurringPayment.fromJson);
      final settings = await _read<MoneySettings>(LedgerNames.legacySettingsFile, MoneySettings.fromJson);
      var entries = await _read<BookEntry>(LedgerNames.legacyEntriesFile, BookEntry.fromJson);
      if (collapse) entries = LedgerPlan.collapse(entries, await LedgerSources.read()).records;
      await _write(LedgerNames.accountsFile, _records(accounts));
      await _write(LedgerNames.recurringFile, _records(recurring));
      await _write(LedgerNames.settingsFile, _records(settings));
      await _write(LedgerNames.entriesFile, _records(entries, collapsed: collapse));
      await _mark(LedgerNames.markerBookFile);
      if (collapse) await _mark(LedgerNames.markerHoldingsFile);
      return;
    }
    if (!collapse || await _marked(LedgerNames.markerHoldingsFile)) return;
    final file = await _readFile(LedgerNames.entriesFile);
    if (file?['collapsed'] != 1) {
      final entries = await _read<BookEntry>(LedgerNames.entriesFile, BookEntry.fromJson);
      final collapsed = LedgerPlan.collapse(entries, await LedgerSources.read()).records;
      await _write(LedgerNames.entriesFile, _records(collapsed, collapsed: true));
    }
    await _mark(LedgerNames.markerHoldingsFile);
  }

  static Map<String, dynamic> _records<T extends Syncable>(List<Record<T>> records, {bool collapsed = false}) => {
        'records': [for (final r in records) r.toJson()],
        if (collapsed) 'collapsed': 1,
      };

  static Future<Map<String, dynamic>?> _readFile(String file) async {
    try {
      return await LocalFileStore.readJsonStrict(file);
    } catch (e) {
      throw LedgerSourceUnreadable(file, e);
    }
  }

  /// The records of [file]: none when it is not there, [LedgerSourceUnreadable]
  /// when it is and cannot be read.
  static Future<List<Record<T>>> _read<T extends Syncable>(String file, T Function(Map<String, dynamic>) fromJson) async {
    final json = await _readFile(file);
    if (json == null) return const [];
    try {
      final raw = json['records'] as List<dynamic>? ?? const [];
      return [for (final e in raw) Record.fromJson<T>(e as Map<String, dynamic>, fromJson)];
    } catch (e) {
      throw LedgerSourceUnreadable(file, e);
    }
  }
}

/// A [JsonFileRecords] that waits for the migration, so nothing reads or
/// writes a ledger file before its marker is there.
class LedgerJsonRecords<T extends Syncable> implements LocalRecords<T> {
  final JsonFileRecords<T> _file;
  final bool _collapseHoldings;

  /// [collapseHoldings] is false only in a test of the steps one at a time.
  LedgerJsonRecords(String filePath, T Function(Map<String, dynamic>) itemFromJson, {bool collapseHoldings = true})
      : _file = JsonFileRecords<T>(filePath, itemFromJson),
        _collapseHoldings = collapseHoldings;

  @override
  Future<List<Record<T>>> read() async {
    await LedgerJsonMigration.ensure(collapseHoldings: _collapseHoldings);
    return _file.read();
  }

  @override
  Future<void> write(List<Record<T>> records) async {
    await LedgerJsonMigration.ensure(collapseHoldings: _collapseHoldings);
    return _file.write(records);
  }
}
