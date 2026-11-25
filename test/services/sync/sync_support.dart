import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:qima/models/book_account.dart';
import 'package:qima/models/book_entry.dart';
import 'package:qima/models/legacy_collapse.dart';
import 'package:qima/models/syncable.dart';
import 'package:qima/services/book_db/book_database.dart';
import 'package:qima/services/book_db/db_records.dart';
import 'package:qima/services/book_store.dart';
import 'package:qima/services/local_file_store.dart';
import 'package:qima/services/sync/sync_engine.dart';
import 'package:qima/services/sync/sync_report.dart';
import 'package:qima/services/sync/sync_transport.dart';
import 'package:qima/services/synced_store.dart';

/// The stores of the app, for their merge rules only: nothing here loads or
/// saves through them.
final BookStore book = BookStore();

final DateTime t0 = DateTime.utc(2026, 5, 1, 10);

DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

BookEntry spend(String id, int amount, {String merchant = 'Cafe'}) => BookEntry(
      id: id,
      date: DateTime(2026, 1, 2),
      template: EntryTemplate.spend,
      baseCurrency: 'USD',
      merchant: merchant,
      lines: [
        EntryLine(accountId: 'bank', amount: -amount, currency: 'USD', baseAmount: -amount),
        EntryLine(accountId: 'category.dining', amount: amount, currency: 'USD', baseAmount: amount),
      ],
    );

/// A cash entry of an old holdings trade, with the versions it was made from.
BookEntry trade(String id, int amount, {int? tradeMs, int? cashMs}) => BookEntry(
      id: id,
      date: DateTime(2026, 1, 3),
      template: EntryTemplate.holdingTrade,
      baseCurrency: 'USD',
      merchant: 'Gold',
      lines: [
        EntryLine(accountId: 'bank', amount: -amount, currency: 'USD', baseAmount: -amount),
        EntryLine(accountId: 'system.holdings', amount: amount, currency: 'USD', baseAmount: amount),
      ],
      legacy: tradeMs == null && cashMs == null ? null : LegacyProvenance(trade: tradeMs == null ? null : at(tradeMs), cash: cashMs == null ? null : at(cashMs)),
    );

BookAccount account(String id, String name) => BookAccount(id: id, name: name, side: AccountSide.own, type: AccountType.cash, currency: 'USD');

Record<T> rec<T extends Syncable>(T item, int ms, {double order = 0, bool deleted = false}) => Record<T>(item: item, order: order, updatedAt: at(ms), deleted: deleted);

/// Records as text, sorted by id, so two sets are equal when the text is.
String show(Iterable<Record> records) {
  final sorted = records.toList()..sort((a, b) => a.item.id.compareTo(b.item.id));
  return jsonEncode([for (final r in sorted) r.toJson()]);
}

EntryRecords entryRows() => EntryRecords(collection: BookStore.entriesKey, filePath: 'book.entries.json', prefer: LegacyCollapse.prefer);

DocumentRecords<BookAccount> accountRows() =>
    DocumentRecords<BookAccount>(collection: BookStore.accountsKey, filePath: 'book.accounts.json', itemFromJson: BookAccount.fromJson, prefer: LegacyCollapse.settles);

/// The engine of the two collections the tests use, on [db].
SyncEngine engineOn(BookDatabase db, SyncTransport transport, {String remote = 'main', int? partBytes, String? writer}) => SyncEngine(
      remote: remote,
      transport: transport,
      writer: writer,
      database: () async => db,
      partBytes: partBytes ?? 256 * 1024,
      collections: [
        SyncCollection<BookAccount>.of(book.accounts, accountRows()),
        SyncCollection<BookEntry>.of(book.entries, entryRows()),
      ],
    );

/// One device: a book database of its own, in memory, and the engine on it.
class Device {
  final String name;
  final BookDatabase db;
  final SyncTransport transport;
  final String remote;
  final int? partBytes;
  final EntryRecords entries = entryRows();
  final DocumentRecords<BookAccount> accounts = accountRows();
  late SyncEngine engine = newEngine();

  Device._(this.name, this.db, this.transport, this.remote, this.partBytes);

  /// Opens a new database. Every device gets a directory of its own under
  /// [root] only so that each has its own name in the registry of open
  /// databases; the data is in memory. The device id is [name], so a run is
  /// the same every time; [id] gives another (null leaves the engine to make
  /// one, as the app does).
  static Future<Device> open(Directory root, String name, SyncTransport transport, {String remote = 'main', String? id = '', int? partBytes}) async {
    BookDatabase.executorOverride = (file) => NativeDatabase.memory();
    LocalFileStore.overrideDirectoryForTesting(Directory('${root.path}/$name')..createSync(recursive: true));
    final db = await BookDatabase.open();
    if (id != null) await db.customStatement('INSERT INTO meta (key, value) VALUES (?, ?)', [SyncEngine.deviceKey, id.isEmpty ? name : id]);
    return Device._(name, db, transport, remote, partBytes);
  }

  /// A new engine on the same database: what a restart of the app leaves.
  /// [writer] fixes the name it stores under, which is otherwise made anew.
  SyncEngine newEngine({SyncTransport? transport, String? remote, String? writer}) =>
      engineOn(db, transport ?? this.transport, remote: remote ?? this.remote, partBytes: partBytes, writer: writer);

  void restart() => engine = newEngine();

  /// A save as a store makes it: the row is written and logged in `changes`,
  /// unless the record would lose a merge to the one that is held.
  Future<void> putEntry(Record<BookEntry> record) async {
    await entries.prepareIn(db);
    await db.transaction(() => entries.writeIn(db, [record]));
  }

  Future<void> putAccount(Record<BookAccount> record) async {
    await accounts.prepareIn(db);
    await db.transaction(() => accounts.writeIn(db, [record]));
  }

  Future<List<Record<BookEntry>>> storedEntries() => db.transaction(() => entries.storedIn(db));

  Future<List<Record<BookAccount>>> storedAccounts() => db.transaction(() => accounts.storedIn(db));

  /// Everything the device holds, as text.
  Future<String> state() async => '${show(await storedAccounts())}\n${show(await storedEntries())}';

  /// The `changes` rows as `seq:op:collection:id`.
  Future<List<String>> log() async => [
        for (final row in await db.customSelect('SELECT seq, op, collection, id FROM changes ORDER BY seq').get())
          '${row.data['seq']}:${row.data['op']}:${row.data['collection']}:${row.data['id']}',
      ];

  Future<String?> meta(String key) async {
    final rows = await db.customSelect("SELECT value FROM meta WHERE key = '$key'").get();
    return rows.isEmpty ? null : rows.single.data['value'] as String;
  }
}

/// Every row of [from] into [to]: what restoring a copy of the file leaves,
/// the device id and every position included.
Future<void> copyDatabase(BookDatabase from, BookDatabase to) async {
  for (final table in const ['meta', 'documents', 'entries', 'entry_lines', 'changes']) {
    await to.customStatement('DELETE FROM $table');
    for (final row in await from.customSelect('SELECT * FROM $table').get()) {
      final columns = row.data.keys.toList();
      await to.customStatement('INSERT INTO $table (${columns.join(', ')}) VALUES (${List.filled(columns.length, '?').join(', ')})', [for (final c in columns) row.data[c]]);
    }
  }
  final high = await from.customSelect("SELECT seq FROM sqlite_sequence WHERE name = 'changes'").get();
  await to.customStatement("DELETE FROM sqlite_sequence WHERE name = 'changes'");
  if (high.isNotEmpty) await to.customStatement("INSERT INTO sqlite_sequence (name, seq) VALUES ('changes', ?)", [high.single.data['seq']]);
}

/// Runs full rounds, every device in turn, until one round moves nothing and
/// leaves nothing undone.
Future<void> settle(List<Device> devices, {int rounds = 12}) async {
  SyncRound? last;
  for (var i = 0; i < rounds; i++) {
    var quiet = true;
    for (final device in devices) {
      last = await device.engine.sync();
      if (!last.quiet) quiet = false;
    }
    if (quiet) return;
  }
  throw StateError('the devices did not settle in $rounds rounds; the last round left waiting ${last?.pull.waiting} and problems ${last?.pull.problems}');
}
