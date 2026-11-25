import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/asset.dart';
import 'package:qima/models/book_account.dart';
import 'package:qima/models/book_entry.dart';
import 'package:qima/models/holding.dart';
import 'package:qima/models/holding_cash_id.dart';
import 'package:qima/models/holding_transaction.dart';
import 'package:qima/models/legacy_collapse.dart';
import 'package:qima/models/money_settings.dart';
import 'package:qima/services/book_db/book_database.dart';
import 'package:qima/services/book_db/db_records.dart';
import 'package:qima/services/book_db/ledger_migration.dart';
import 'package:qima/services/book_db/ledger_plan.dart';
import 'package:qima/services/book_store.dart';
import 'package:qima/services/cloud_kv_store.dart';
import 'package:qima/services/local_file_store.dart';
import 'package:qima/services/synced_store.dart';

import 'book_database_migration_test.dart' show holdWriteLock, writeV1;

/// A cloud that remembers every key written to it.
class _Cloud implements CloudKVStore {
  final Map<String, String> values = {};
  final List<String> written = [];

  @override
  Future<String?> getString(String key) async => values[key];

  @override
  Future<void> setString(String key, String value) async {
    written.add(key);
    values[key] = value;
  }

  @override
  Future<void> synchronize() async {}

  @override
  Future<bool> accountStatus() async => true;

  @override
  Stream<CloudKVChangeEvent> get didChangeExternally => const Stream.empty();
}

final _day = DateTime(2026, 3, 12);
final _t0 = DateTime.utc(2026, 5, 1, 10);
DateTime _at(int s) => _t0.add(Duration(seconds: s));

String _q(String s) => s.replaceAll("'", "''");

HoldingTransaction _trade(String id, TransactionKind kind, {double qty = 10, double px = 50, double fee = 0}) => HoldingTransaction(
      id: id,
      instrumentID: 'metal.XAU',
      kind: kind,
      quantity: qty,
      unit: PriceUnit.gram,
      unitPrice: px,
      fee: fee,
      currency: 'USD',
      date: _day,
      note: 'n-$id',
    );

Record<HoldingTransaction> _tr(HoldingTransaction t, int stamp, {double order = 1, bool deleted = false}) =>
    Record(item: t, order: order, updatedAt: _at(stamp), deleted: deleted);

Record<HoldingLot> _lot(String id, int stamp, {double order = 3}) => Record(
      item: HoldingLot(id: id, instrumentID: 'metal.XAU', quantity: 4, unit: PriceUnit.gram, unitCost: 60, costCurrency: 'USD', date: _day),
      order: order,
      updatedAt: _at(stamp),
    );

/// The cash entry the last build wrote for a trade.
Record<BookEntry> _cash(String tradeId, int amount, int stamp, {String account = 'acct.bank', double order = 5}) => Record(
      item: BookEntry(
        id: holdingCashId(tradeId),
        date: _day,
        template: EntryTemplate.holdingTrade,
        baseCurrency: 'USD',
        merchant: 'Gold',
        lines: [
          EntryLine(accountId: account, amount: amount, currency: 'USD', baseAmount: amount),
          EntryLine(accountId: 'system.holdings', amount: -amount, currency: 'USD', baseAmount: -amount),
        ],
      ),
      order: order,
      updatedAt: _at(stamp),
    );

Record<BookEntry> _spend(String id, int stamp, {int amount = 700, double order = 9, bool deleted = false}) => Record(
      item: BookEntry(id: id, date: _day, template: EntryTemplate.spend, baseCurrency: 'USD', merchant: 'Cafe', lines: [
        EntryLine(accountId: 'acct.bank', amount: -amount, currency: 'USD', baseAmount: -amount),
        EntryLine(accountId: 'category.food', amount: amount, currency: 'USD', baseAmount: amount),
      ]),
      order: order,
      updatedAt: _at(stamp),
      deleted: deleted,
    );

final _account = BookAccount(id: 'a1', name: 'Cash', side: AccountSide.own, type: AccountType.cash, currency: 'SAR');
final _gone = BookAccount(id: 'a2', name: 'Old', side: AccountSide.own, type: AccountType.cash, currency: 'SAR');

/// Rows of a version 1 file as the first release left it: every collection
/// under its old name, its JSON files already imported.
List<String> _v1Rows() {
  String doc(String collection, String id, Map<String, dynamic> body, double sort, String at, {bool deleted = false}) =>
      "INSERT INTO documents (collection, id, body, sort, updated_at, deleted) VALUES ('$collection', '$id', '${_q(jsonEncode(body))}', $sort, '$at', ${deleted ? 1 : 0})";
  return [
    for (final c in ['book.accounts', 'book.entries', 'book.recurring', 'money.settings']) "INSERT INTO meta (key, value) VALUES ('imported.$c', '1')",
    "INSERT INTO entries (id, date, template, base_currency, merchant, sort, updated_at, deleted) VALUES ('e1', '2026-11-08T09:30:00.000Z', 'spend', 'SAR', 'Cafe', 1.5, '2026-11-08T10:00:00.000000Z', 0)",
    "INSERT INTO entry_lines (entry_id, idx, account_id, amount, currency, base_amount, extra) VALUES ('e1', 0, 'category.food', 1250, 'SAR', 1250, NULL)",
    "INSERT INTO entry_lines (entry_id, idx, account_id, amount, currency, base_amount, extra) VALUES ('e1', 1, 'account.cash', -1250, 'SAR', -1250, '{\"memo\":\"x\"}')",
    "INSERT INTO entries (id, date, template, base_currency, merchant, sort, updated_at, deleted) VALUES ('e2', '2026-11-09T09:30:00.000Z', 'spend', 'SAR', 'Gone', -2.25, '2026-11-09T10:00:00.000000Z', 1)",
    "INSERT INTO entry_lines (entry_id, idx, account_id, amount, currency, base_amount, extra) VALUES ('e2', 0, 'category.food', 5, 'SAR', 5, NULL)",
    "INSERT INTO entry_lines (entry_id, idx, account_id, amount, currency, base_amount, extra) VALUES ('e2', 1, 'account.cash', -5, 'SAR', -5, NULL)",
    doc('book.accounts', 'a1', _account.toJson(), 0, '2026-11-08T10:00:00.000000Z'),
    doc('book.accounts', 'a2', _gone.toJson(), 1, '2026-11-09T10:00:00.000000Z', deleted: true),
    doc('book.recurring', 'r1', RecurringPayment(id: 'r1', name: 'Rent', amount: 900, fromAccountId: 'a1', categoryId: 'category.home', start: DateTime(2026, 1, 1)).toJson(), 4, '2026-11-08T10:00:00.000000Z'),
    doc('money.settings', 'money.settings', {'id': 'money.settings', 'seenWhatsNew': true}, 0, '2026-11-08T10:00:00.000000Z'),
    "INSERT INTO changes (at, collection, id, op, body) VALUES ('2026-11-08T10:00:00.000000Z', 'book.entries', 'e1', 'put', NULL)",
    "INSERT INTO changes (at, collection, id, op, body) VALUES ('2026-11-08T10:00:00.000000Z', 'money.settings', 'money.settings', 'put', NULL)",
  ];
}

/// The JSON files of a build that had no database.
Future<void> _writeJsonFiles() async {
  Map<String, dynamic> rec(Map<String, dynamic> item, double order, String at, {bool deleted = false}) => {'item': item, 'order': order, 'updatedAt': at, 'deleted': deleted};
  final e1 = _spend('e1', 0, amount: 1250).item;
  final e2 = _spend('e2', 0, amount: 5).item;
  await LocalFileStore.writeJson('book.accounts.json', {
    'records': [rec(_account.toJson(), 0, '2026-02-03T04:05:06.789012Z'), rec(_gone.toJson(), 1, '2026-02-04T04:05:06.789012Z', deleted: true)],
  });
  await LocalFileStore.writeJson('book.entries.json', {
    'records': [rec(e1.toJson(), 1.5, '2026-02-03T04:05:06.789012Z'), rec(e2.toJson(), -2.25, '2026-02-04T04:05:06.789012Z', deleted: true)],
  });
  await LocalFileStore.writeJson('book.recurring.json', {
    'records': [rec(RecurringPayment(id: 'r1', name: 'Rent', amount: 900, fromAccountId: 'a1', categoryId: 'category.home', start: DateTime(2026, 1, 1)).toJson(), 4, '2026-02-03T04:05:06.789012Z')],
  });
  await LocalFileStore.writeJson('money.settings.json', {'records': [rec({'id': 'money.settings', 'seenWhatsNew': true}, 0, '2026-02-03T04:05:06.789012Z')]});
}

String _dump(Record r) => jsonEncode(r.toJson());

List<String> _dumpAll(Iterable<Record> rs) => [for (final r in rs) _dump(r)];

List<Record<BookEntry>> _sorted(List<Record<BookEntry>> rs) => [...rs]..sort((a, b) => a.item.id.compareTo(b.item.id));

Record<BookEntry> _one(List<Record<BookEntry>> rs, String id) => rs.singleWhere((r) => r.item.id == id);

/// What each cash account holds, from entries that count.
Map<String, int> _money(Iterable<Record<BookEntry>> rs) {
  final out = <String, int>{};
  for (final r in rs) {
    if (r.deleted || !r.item.counts) continue;
    for (final l in r.item.lines) {
      if (l.accountId.startsWith('acct.')) out[l.accountId] = (out[l.accountId] ?? 0) + l.amount;
    }
  }
  return out;
}

/// The old collections as the first builds read them, through the stores
/// they had.
EntryRecords _oldEntries() => EntryRecords(collection: 'book.entries', filePath: 'book.entries.json');
EntryRecords _newEntries() => EntryRecords(collection: LedgerNames.entries, filePath: LedgerNames.legacyEntriesFile);

/// Makes a book from a fresh start through the stores, then returns the
/// database (step A done, step B not).
Future<BookDatabase> _open() async {
  final db = await BookDatabase.open();
  db.collapseHoldings = false;
  return db;
}

Future<BookDatabase> _freshBook() async {
  final db = await _open();
  await LedgerMigration.migrateBook(db);
  return db;
}

Future<void> _writeHoldings({List<Record<HoldingTransaction>> trades = const [], List<Record<HoldingLot>> lots = const []}) async {
  await LocalFileStore.writeJson('transactions.records.json', {'records': [for (final t in trades) t.toJson()]});
  await LocalFileStore.writeJson('holdings.records.json', {'records': [for (final l in lots) l.toJson()]});
}

Future<String> _race(String dir, bool collapse) => Isolate.run(() async {
      LocalFileStore.overrideDirectoryForTesting(Directory(dir));
      try {
        final db = await BookDatabase.open();
        await LedgerMigration.run(db, collapseHoldings: collapse);
        final store = BookStore();
        final entries = await store.entries.exportRecords();
        final accounts = await store.accounts.exportRecords();
        await BookDatabase.closeAll();
        return jsonEncode([for (final r in [...entries, ...accounts]) r.toJson()]..sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b))));
      } catch (e, s) {
        return 'failed $e $s';
      }
    });

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('qima_ledger_migration');
    LocalFileStore.overrideDirectoryForTesting(dir);
    file = File('${dir.path}/${BookDatabase.fileName}');
    // The steps are run by hand below; the app runs both (see the test of that).
  });

  tearDown(() async {
    await BookDatabase.closeAll();
    BookDatabase.executorOverride = null;
    await dir.delete(recursive: true);
  });

  Future<List<String>> names(BookDatabase db, String sql) async => [for (final r in await db.customSelect(sql).get()) r.data.values.first as String];
  Future<int> count(BookDatabase db, String sql) async => (await db.customSelect(sql).getSingle()).data.values.first as int;

  group('step A', () {
    test('from a version 1 file: every row is under ledger.*, reads are record for record, the cloud has only the new keys', () async {
      await writeV1(file, rows: _v1Rows());
      var db = await _open();
      // What the old collections read as, before the migration.
      final before = {
        'entries': _dumpAll(await _oldEntries().read()),
        'accounts': _dumpAll(await DocumentRecords<BookAccount>(collection: 'book.accounts', filePath: 'book.accounts.json', itemFromJson: BookAccount.fromJson).read()),
        'recurring': _dumpAll(await DocumentRecords<RecurringPayment>(collection: 'book.recurring', filePath: 'book.recurring.json', itemFromJson: RecurringPayment.fromJson).read()),
        'settings': _dumpAll(await DocumentRecords<MoneySettings>(collection: 'money.settings', filePath: 'money.settings.json', itemFromJson: MoneySettings.fromJson).read()),
      };
      expect(before.values.map((v) => v.length), [2, 2, 1, 1]);
      final lines = await count(db, 'SELECT count(*) FROM entry_lines');

      final cloud = _Cloud();
      final store = BookStore(cloud: cloud);
      final live = await store.entries.load();
      final accounts = await store.accounts.load();
      await store.recurring.load();
      await store.settings.load();

      db = await _open();
      expect(await names(db, 'SELECT DISTINCT collection FROM entries'), [LedgerNames.entries]);
      expect(await names(db, 'SELECT DISTINCT collection FROM documents ORDER BY 1'), [LedgerNames.accounts, LedgerNames.recurring, LedgerNames.settings]);
      expect(await names(db, 'SELECT DISTINCT collection FROM changes ORDER BY 1'), [LedgerNames.accounts, LedgerNames.entries, LedgerNames.recurring, LedgerNames.settings]);
      expect(await count(db, "SELECT count(*) FROM changes WHERE op = 'put' AND collection = 'ledger.entries' AND id = 'e1'"), 1);
      expect(await count(db, 'SELECT count(*) FROM entry_lines'), lines);
      expect(await names(db, "SELECT key FROM meta WHERE key LIKE 'migrated.%' ORDER BY key"), [LedgerNames.flagBook]);
      expect(await names(db, "SELECT key FROM meta WHERE key LIKE 'imported.ledger.%' ORDER BY key"), ['imported.ledger.accounts', 'imported.ledger.entries', 'imported.ledger.recurring', 'imported.ledger.settings']);

      expect(_dumpAll(await _newEntries().read()), before['entries']);
      expect(_dumpAll(await DocumentRecords<BookAccount>(collection: LedgerNames.accounts, filePath: 'x', itemFromJson: BookAccount.fromJson).read()), before['accounts']);
      expect(_dumpAll(await DocumentRecords<RecurringPayment>(collection: LedgerNames.recurring, filePath: 'x', itemFromJson: RecurringPayment.fromJson).read()), before['recurring']);
      expect(_dumpAll(await DocumentRecords<MoneySettings>(collection: LedgerNames.settings, filePath: 'x', itemFromJson: MoneySettings.fromJson).read()), before['settings']);
      expect([for (final r in await store.entries.exportRecords()) _dump(r)], before['entries']);
      expect(live.map((e) => e.id), ['e1']);
      expect(accounts.map((a) => a.id), ['a1']);

      // Nothing under the old names is left or read.
      expect(await _oldEntries().read(), isEmpty);

      expect(cloud.written.toSet(), {LedgerNames.entries, LedgerNames.accounts, LedgerNames.recurring, LedgerNames.settings});
      expect(cloud.values.keys.toSet().intersection({for (final c in LedgerNames.collections) c.$1}), isEmpty);
      for (final key in BookStore.cloudKeys) {
        final envelope = jsonDecode(cloud.values[key]!) as Map<String, dynamic>;
        expect((envelope['v'], envelope['z']), (1, 'gzip'));
      }
    });

    test('from JSON files only, with no database: the same result, and the files are not written', () async {
      await _writeJsonFiles();
      final bytes = {for (final f in ['book.accounts.json', 'book.entries.json', 'book.recurring.json', 'money.settings.json']) f: File('${dir.path}/$f').readAsBytesSync()};
      expect(file.existsSync(), isFalse);

      final cloud = _Cloud();
      final store = BookStore(cloud: cloud);
      final live = await store.entries.load();
      expect(live.map((e) => e.id), ['e1']);
      expect((await store.accounts.load()).map((a) => a.id), ['a1']);
      expect((await store.recurring.load()).map((r) => r.id), ['r1']);
      expect((await store.settings.load()).single.seenWhatsNew, isTrue);

      final db = await _open();
      expect(await names(db, 'SELECT DISTINCT collection FROM entries'), [LedgerNames.entries]);
      expect(await names(db, 'SELECT DISTINCT collection FROM documents ORDER BY 1'), [LedgerNames.accounts, LedgerNames.recurring, LedgerNames.settings]);
      expect(await names(db, 'SELECT DISTINCT collection FROM changes ORDER BY 1'), [LedgerNames.accounts, LedgerNames.entries, LedgerNames.recurring, LedgerNames.settings]);
      final records = await store.entries.exportRecords();
      expect(records.map((r) => (r.item.id, r.order, r.deleted)), [('e1', 1.5, false), ('e2', -2.25, true)]);
      expect(records.first.updatedAt.toUtc().toIso8601String(), '2026-02-03T04:05:06.789012Z');
      expect(cloud.values.keys.toSet().intersection({for (final c in LedgerNames.collections) c.$1}), isEmpty);
      expect(cloud.written.toSet(), {LedgerNames.entries, LedgerNames.accounts, LedgerNames.recurring, LedgerNames.settings});
      for (final entry in bytes.entries) {
        expect(File('${dir.path}/${entry.key}').readAsBytesSync(), entry.value, reason: entry.key);
      }
      expect(File('${dir.path}/ledger.entries.json').existsSync(), isFalse);
    });

    test('a book with nothing in it migrates and stays empty', () async {
      final db = await _open();
      await LedgerMigration.migrateBook(db);
      expect(await db.hasFlag(LedgerNames.flagBook), isTrue);
      expect(await _newEntries().read(), isEmpty);
      expect(await count(db, 'SELECT count(*) FROM entries'), 0);
    });

    test('run again, even with the flag gone, it changes nothing', () async {
      await writeV1(file, rows: _v1Rows());
      var db = await _open();
      await LedgerMigration.migrateBook(db);
      String snapshot(List<Object?> rows) => jsonEncode(rows);
      Future<String> all(BookDatabase d) async => snapshot([
            for (final t in ['entries', 'entry_lines', 'documents', 'changes', 'meta'])
              [for (final r in await d.customSelect('SELECT * FROM $t').get()) r.data],
          ]);
      final once = await all(db);

      await LedgerMigration.migrateBook(db);
      expect(await all(db), once);
      await BookDatabase.closeAll();
      db = await _open();
      await LedgerMigration.migrateBook(db);
      await LedgerMigration.ensure(db);
      expect(await all(db), once);

      // With the flag gone the relabel finds nothing under the old names.
      await db.customStatement("DELETE FROM meta WHERE key = 'migrated.ledger.book'");
      await LedgerMigration.migrateBook(db);
      expect(await names(db, 'SELECT DISTINCT collection FROM entries'), [LedgerNames.entries]);
      expect(await count(db, 'SELECT count(*) FROM entries'), 2);
      expect(await count(db, "SELECT count(*) FROM changes WHERE op = 'relabel'"), 8);
    });

    test('a stop before the flag leaves the file as it was, and the next run finishes', () async {
      await writeV1(file, rows: _v1Rows());
      final db = await _open();
      await db.customStatement("CREATE TRIGGER boom BEFORE INSERT ON meta WHEN NEW.key = 'migrated.ledger.book' BEGIN SELECT RAISE(ABORT, 'boom'); END");
      await expectLater(LedgerMigration.migrateBook(db), throwsA(anything));
      expect(await names(db, 'SELECT DISTINCT collection FROM entries'), ['book.entries']);
      expect(await names(db, 'SELECT DISTINCT collection FROM documents ORDER BY 1'), ['book.accounts', 'book.recurring', 'money.settings']);
      expect(await db.hasFlag(LedgerNames.flagBook), isFalse);
      expect(await db.hasFlag('imported.ledger.entries'), isFalse);
      expect(await count(db, "SELECT count(*) FROM changes WHERE op = 'relabel'"), 0);

      await db.customStatement('DROP TRIGGER boom');
      await LedgerMigration.migrateBook(db);
      expect(await names(db, 'SELECT DISTINCT collection FROM entries'), [LedgerNames.entries]);
      expect(await count(db, "SELECT count(*) FROM changes WHERE op = 'relabel'"), 4);
    });

    test('a failed step A is thrown to the reader, and the next read tries again', () async {
      await writeV1(file, rows: _v1Rows());
      final db = await _open();
      await db.customStatement("CREATE TRIGGER boom BEFORE INSERT ON meta WHEN NEW.key = 'migrated.ledger.book' BEGIN SELECT RAISE(ABORT, 'boom'); END");
      final store = BookStore();
      await expectLater(store.entries.load(), throwsA(anything));
      await db.customStatement('DROP TRIGGER boom');
      expect((await store.entries.load()).map((e) => e.id), ['e1']);
    });

    test('an old JSON file that cannot be read is imported into the ledger collection when it can', () async {
      await _writeJsonFiles();
      final good = File('${dir.path}/book.entries.json').readAsStringSync();
      File('${dir.path}/book.entries.json').writeAsStringSync(good.substring(0, good.length ~/ 2));
      final store = BookStore();
      expect(await store.entries.load(), isEmpty);
      expect((await store.accounts.load()).map((a) => a.id), ['a1']);

      final db = await _open();
      expect(await db.hasFlag(LedgerNames.flagBook), isTrue);
      expect(await db.hasFlag('imported.ledger.entries'), isFalse);
      expect(await db.hasFlag('imported.ledger.accounts'), isTrue);
      expect(File('${dir.path}/book.entries.json').readAsStringSync(), good.substring(0, good.length ~/ 2));

      // A later start, with the file readable.
      File('${dir.path}/book.entries.json').writeAsStringSync(good);
      await BookDatabase.closeAll();
      expect((await BookStore().entries.load()).map((e) => e.id), ['e1']);
      expect(await (await _open()).hasFlag('imported.ledger.entries'), isTrue);
    });

    test('a BookEntry with its provenance round-trips through EntryRecords, in extra', () async {
      final entry = BookEntry(
        id: 'p1',
        date: _day,
        template: EntryTemplate.holdingBuy,
        baseCurrency: 'USD',
        legacy: LegacyProvenance(trade: _at(3), cash: _at(7)),
        lines: const [
          EntryLine(accountId: 'acct.bank', amount: -500, currency: 'USD', baseAmount: -500),
          EntryLine(accountId: 'system.holdings', amount: 500, currency: 'USD', baseAmount: 500),
        ],
      );
      final records = EntryRecords(collection: LedgerNames.entries, filePath: LedgerNames.legacyEntriesFile);
      await records.write([Record(item: entry, order: 2, updatedAt: _at(9))]);
      final back = (await records.read()).single;
      expect(back.item, entry);
      expect(back.item.legacy, LegacyProvenance(trade: _at(3), cash: _at(7)));
      expect(_dump(back), _dump(Record(item: entry, order: 2, updatedAt: _at(9))));
      final db = await _open();
      expect(jsonDecode((await names(db, "SELECT extra FROM entries WHERE id = 'p1'")).single), containsPair('legacy', {'t': _at(3).toIso8601String(), 'c': _at(7).toIso8601String()}));
    });
  });

  group('step B', () {
    /// The book of the interim: a spend, a buy with its cash entry, a sale
    /// with no cash, a deleted buy whose cash entry is still live, and a lot.
    Future<({List<Record<HoldingTransaction>> trades, List<Record<HoldingLot>> lots})> seed() async {
      final trades = [
        _tr(_trade('buy', TransactionKind.buy, fee: 5), 10, order: 2),
        _tr(_trade('sale', TransactionKind.sell, qty: 2, px: 70), 12, order: 3),
        _tr(_trade('gone', TransactionKind.buy, qty: 1, px: 3), 14, order: 4, deleted: true),
      ];
      final lots = [_lot('lot', 16)];
      await _newEntries().write([_spend('s1', 1), _cash('buy', -50500, 20), _cash('gone', -300, 22, account: 'acct.card', order: 7)]);
      await _writeHoldings(trades: trades, lots: lots);
      return (trades: trades, lots: lots);
    }

    Record<BookEntry> one(List<Record<BookEntry>> rs, String id) => rs.singleWhere((r) => r.item.id == id);

    test('writes what LegacyCollapse makes, with its ids, order and stamps, and the money does not move', () async {
      final db = await _freshBook();
      final s = await seed();
      final before = await _newEntries().read();
      final oracle = LegacyCollapse.collapse(transactions: s.trades, lots: s.lots, entries: before);

      expect(await LedgerMigration.collapseTrades(db), LedgerStep.done);

      final after = await _newEntries().read();
      expect(_dumpAll(_sorted(after)), _dumpAll(oracle));
      expect(await db.hasFlag(LedgerNames.flagHoldings), isTrue);
      expect(_money(before), {'acct.bank': -51200, 'acct.card': -300});
      expect(_money(after), _money(before));

      // A trade with cash: one entry under the trade's id, the cash inside.
      final buy = one(after, 'buy');
      expect((buy.item.template, buy.order, buy.updatedAt, buy.deleted), (EntryTemplate.holdingBuy, 2.0, _at(20), false));
      expect(buy.item.lines.where((l) => l.accountId == 'acct.bank').single.amount, -50500);
      expect(buy.item.legacy, LegacyProvenance(trade: _at(10), cash: _at(20)));
      final cash = one(after, holdingCashId('buy'));
      expect((cash.deleted, cash.order, cash.updatedAt), (true, 5.0, _at(20)));
      // A trade without cash: no cash account in it.
      final sale = one(after, 'sale');
      expect((sale.item.template, sale.item.lines.any((l) => l.accountId.startsWith('acct.')), sale.updatedAt), (EntryTemplate.holdingSell, false, _at(12)));
      // A deleted trade is a tombstone, and its live cash entry stays live.
      expect(one(after, 'gone').deleted, isTrue);
      expect(one(after, holdingCashId('gone')).deleted, isFalse);
      // A lot nothing replaced is a buy with the lot's order and stamp.
      final lot = one(after, 'lot');
      expect((lot.item.template, lot.order, lot.updatedAt, lot.deleted), (EntryTemplate.holdingBuy, 3.0, _at(16), false));
      // Everything else is as it was.
      expect(_dump(one(after, 's1')), _dump(one(before, 's1')));

      // Logged, in one place with the flag.
      expect(await count(db, "SELECT count(*) FROM changes WHERE op = 'collapse'"), 1);
      expect(await count(db, "SELECT count(*) FROM changes WHERE collection = 'ledger.entries' AND id IN ('buy', 'sale', 'lot') AND op = 'put'"), 3);
    });

    test('the old files are never written', () async {
      final db = await _freshBook();
      await seed();
      final files = ['transactions.records.json', 'holdings.records.json'];
      final bytes = {for (final f in files) f: File('${dir.path}/$f').readAsBytesSync()};
      await LedgerMigration.collapseTrades(db);
      for (final f in files) {
        expect(File('${dir.path}/$f').readAsBytesSync(), bytes[f], reason: f);
        expect(File('${dir.path}/$f.tmp').existsSync(), isFalse);
      }
    });

    test('run twice, it changes nothing', () async {
      final db = await _freshBook();
      await seed();
      await LedgerMigration.collapseTrades(db);
      final once = _dumpAll(await _newEntries().read());
      final log = await count(db, 'SELECT count(*) FROM changes');
      expect(await LedgerMigration.collapseTrades(db), LedgerStep.alreadyDone);
      expect(_dumpAll(await _newEntries().read()), once);
      expect(await count(db, 'SELECT count(*) FROM changes'), log);

      // Not even over a changed holdings file, nor after a restart.
      await _writeHoldings(trades: [_tr(_trade('late', TransactionKind.buy), 99)]);
      await BookDatabase.closeAll();
      final again = await _open();
      expect(await LedgerMigration.collapseTrades(again), LedgerStep.alreadyDone);
      await LedgerMigration.run(again, collapseHoldings: true);
      expect(_dumpAll(await _newEntries().read()), once);
    });

    test('collapsing again over its own output, flag or no flag, changes nothing', () async {
      final db = await _freshBook();
      await seed();
      await LedgerMigration.collapseTrades(db);
      final once = _dumpAll(await _newEntries().read());
      await db.customStatement("DELETE FROM meta WHERE key = 'migrated.ledger.holdings'");
      expect(await LedgerMigration.collapseTrades(db), LedgerStep.done);
      expect(_dumpAll(await _newEntries().read()), once);
      expect(_money(await _newEntries().read()), {'acct.bank': -51200, 'acct.card': -300});
    });

    test('a book migrated by step A alone, and then by step B, ends as one migrated together', () async {
      await _writeJsonFiles();
      await _writeHoldings(trades: [_tr(_trade('buy', TransactionKind.buy), 10)]);
      var db = await _open();
      await LedgerMigration.run(db, collapseHoldings: false);
      expect(await db.hasFlag(LedgerNames.flagBook), isTrue);
      expect(await db.hasFlag(LedgerNames.flagHoldings), isFalse);
      expect((await _newEntries().read()).map((r) => r.item.id), ['e1', 'e2']);

      // The app stops here; a build that runs B finds A done and resumes.
      await BookDatabase.closeAll();
      db = await _open();
      await LedgerMigration.run(db, collapseHoldings: true);
      expect(await db.hasFlag(LedgerNames.flagHoldings), isTrue);
      expect((await _newEntries().read()).map((r) => r.item.id), ['e1', 'e2', 'buy']);
      expect(await count(db, "SELECT count(*) FROM changes WHERE op = 'relabel'"), 4);
    });

    test('a stop before the flag writes nothing, and the next run does it all', () async {
      final db = await _freshBook();
      final s = await seed();
      final before = _dumpAll(await _newEntries().read());
      await db.customStatement("CREATE TRIGGER boom BEFORE INSERT ON meta WHEN NEW.key = 'migrated.ledger.holdings' BEGIN SELECT RAISE(ABORT, 'boom'); END");
      await expectLater(LedgerMigration.collapseTrades(db), throwsA(anything));
      expect(_dumpAll(await _newEntries().read()), before);
      expect(await db.hasFlag(LedgerNames.flagHoldings), isFalse);

      await db.customStatement('DROP TRIGGER boom');
      await LedgerMigration.collapseTrades(db);
      expect(_dumpAll(_sorted(await _newEntries().read())), _dumpAll(LegacyCollapse.collapse(transactions: s.trades, lots: s.lots, entries: [for (final j in before) Record.fromJson<BookEntry>(jsonDecode(j) as Map<String, dynamic>, BookEntry.fromJson)])));
    });

    test('an absent holdings file has no records', () async {
      final db = await _freshBook();
      await _newEntries().write([_spend('s1', 1), _cash('buy', -500, 20)]);
      final before = await _newEntries().read();
      expect(await LedgerMigration.collapseTrades(db), LedgerStep.done);
      final after = await _newEntries().read();
      expect(after.map((r) => r.item.id), before.map((r) => r.item.id));
      expect(_dump(one(after, 's1')), _dump(one(before, 's1')));
      // A cash entry nobody claims stays live, with its own version noted.
      expect(one(after, holdingCashId('buy')).deleted, isFalse);
      expect(_money(after), _money(before));
    });

    test('an unreadable holdings file sets no flag, loses nothing, and the next start does it', () async {
      final db = await _freshBook();
      final s = await seed();
      final before = _dumpAll(await _newEntries().read());
      for (final name in ['transactions.records.json', 'holdings.records.json']) {
        final f = File('${dir.path}/$name');
        final good = f.readAsStringSync();
        f.writeAsStringSync(good.substring(0, good.length ~/ 2));
        await expectLater(LedgerMigration.collapseTrades(db), throwsA(isA<LedgerSourceUnreadable>().having((e) => e.file, 'file', name)));
        // The app's own pass keeps the book working and says why.
        await LedgerMigration.run(db, collapseHoldings: true);
        expect(db.ledgerProblems[LedgerNames.flagHoldings], isA<LedgerSourceUnreadable>());
        expect(await db.hasFlag(LedgerNames.flagHoldings), isFalse);
        expect(_dumpAll(await _newEntries().read()), before);
        expect((await BookStore().entries.load()).map((e) => e.id), isNotEmpty);
        expect(f.readAsStringSync(), good.substring(0, good.length ~/ 2), reason: 'the file is not touched');
        f.writeAsStringSync(good);
      }
      await LedgerMigration.collapseTrades(db);
      expect(_dumpAll(_sorted(await _newEntries().read())), _dumpAll(LegacyCollapse.collapse(transactions: s.trades, lots: s.lots, entries: [for (final j in before) Record.fromJson<BookEntry>(jsonDecode(j) as Map<String, dynamic>, BookEntry.fromJson)])));
    });

    test('a record that does not parse is as unreadable as a file that does not', () async {
      final db = await _freshBook();
      await LocalFileStore.writeJson('transactions.records.json', {'records': [{'item': {'id': 'x'}, 'order': 1, 'updatedAt': '2026-01-01T00:00:00Z'}]});
      await expectLater(LedgerMigration.collapseTrades(db), throwsA(isA<LedgerSourceUnreadable>()));
      expect(await db.hasFlag(LedgerNames.flagHoldings), isFalse);
    });

    test('a trade with the id of an entry that is not a holding is left out and reported, and the rest is collapsed', () async {
      final db = await _freshBook();
      await _newEntries().write([_spend('clash', 1), _spend('s1', 2), _cash('buy', -500, 20)]);
      await _writeHoldings(trades: [_tr(_trade('clash', TransactionKind.buy), 10), _tr(_trade('buy', TransactionKind.buy), 11)], lots: [_lot('s1', 12)]);
      final before = _sorted(await _newEntries().read());

      expect(await LedgerMigration.collapseTrades(db), LedgerStep.done);
      expect(await db.hasFlag(LedgerNames.flagHoldings), isTrue);
      final problem = db.ledgerProblems[LedgerNames.flagHoldings];
      expect(problem, isA<LedgerConflict>().having((e) => e.ids, 'ids', ['clash', 's1']).having((e) => e.toString(), 'text', allOf(contains('clash'), contains('s1'))));

      // The two money entries are as they were, the other trade is one entry
      // with its cash folded in, and nothing else changed.
      final after = _sorted(await _newEntries().read());
      expect(_dump(_one(after, 'clash')), _dump(_one(before, 'clash')));
      expect(_dump(_one(after, 's1')), _dump(_one(before, 's1')));
      expect(_one(after, 'buy').item.template, EntryTemplate.holdingBuy);
      expect(_one(after, holdingCashId('buy')).deleted, isTrue);
      expect(_money(after), {'acct.bank': -1900}, reason: 'the cash of the trade counts once');

      final store = BookStore();
      expect((await store.entries.load()).map((e) => e.id).toSet(), {'clash', 's1', 'buy'});
      await store.entries.upsert(_spend('new', 3).item);
      expect((await store.entries.load()).map((e) => e.id), contains('new'));
    });

    test('the app pass reports a clash and does not throw', () async {
      final db = await _freshBook();
      await _newEntries().write([_spend('clash', 1)]);
      await _writeHoldings(trades: [_tr(_trade('clash', TransactionKind.buy), 10)]);
      await LedgerMigration.run(db, collapseHoldings: true);
      expect(db.ledgerProblems[LedgerNames.flagHoldings], isA<LedgerConflict>());
      expect(await BookStore().ledgerProblems(), contains(LedgerNames.flagHoldings));
      expect((await BookStore().entries.load()).map((e) => e.id), ['clash']);
    });

    test('a clash with a deleted money entry counts too', () async {
      final db = await _freshBook();
      await _newEntries().write([_spend('gone', 1, deleted: true)]);
      await _writeHoldings(trades: [_tr(_trade('gone', TransactionKind.buy), 10)]);
      expect(await LedgerMigration.collapseTrades(db), LedgerStep.done);
      expect(db.ledgerProblems[LedgerNames.flagHoldings], isA<LedgerConflict>().having((e) => e.ids, 'ids', ['gone']));
      expect((await _newEntries().read()).single.deleted, isTrue);
    });

    test('a book with no clash reports nothing', () async {
      final db = await _freshBook();
      await _writeHoldings(trades: [_tr(_trade('buy', TransactionKind.buy), 10)]);
      expect(await LedgerMigration.collapseTrades(db), LedgerStep.done);
      expect(db.ledgerProblems, isEmpty);
    });

    test('a book with a clash is done once and not run again', () async {
      final db = await _freshBook();
      await _newEntries().write([_spend('clash', 1)]);
      await _writeHoldings(trades: [_tr(_trade('clash', TransactionKind.buy), 10), _tr(_trade('other', TransactionKind.sell), 11)]);
      expect(await LedgerMigration.collapseTrades(db), LedgerStep.done);
      expect(await LedgerMigration.collapseTrades(db), LedgerStep.alreadyDone);
      expect((await _newEntries().read()).map((r) => r.item.id).toSet(), {'clash', 'other'});
    });

    test('a deleted lot or a trade of another id is no clash', () async {
      final db = await _freshBook();
      await _newEntries().write([_spend('clash', 1, deleted: true), _spend('s1', 2), _cash('buy', -500, 20)]);
      await _writeHoldings(trades: [_tr(_trade('other', TransactionKind.buy), 10)], lots: [Record(item: _lot('s1', 12).item, order: 3, updatedAt: _at(12), deleted: true)]);
      expect(await LedgerMigration.collapseTrades(db), LedgerStep.done);
      expect(db.ledgerProblems, isEmpty);
    });

    test('a holding already under the trade id (an earlier collapse, or another device) competes, and is no clash', () async {
      final db = await _freshBook();
      final trades = [_tr(_trade('buy', TransactionKind.buy, fee: 5), 10)];
      final theirs = LegacyCollapse.collapse(transactions: trades, lots: const [], entries: [_cash('buy', -50500, 20)]);
      await _newEntries().write([_spend('s1', 1), ...theirs]);
      await _writeHoldings(trades: trades);
      await LedgerMigration.collapseTrades(db);
      final after = await _newEntries().read();
      expect(_dump(one(after, 'buy')), _dump(one(theirs, 'buy')));
      expect(_money(after), {'acct.bank': -50500 - 700});
    });

    test('an old entries file that was unreadable makes it wait until the ledger entries are imported', () async {
      await _writeJsonFiles();
      final good = File('${dir.path}/book.entries.json').readAsStringSync();
      File('${dir.path}/book.entries.json').writeAsStringSync('{');
      await _writeHoldings(trades: [_tr(_trade('buy', TransactionKind.buy), 10)]);
      final db = await _open();
      expect(await LedgerMigration.collapseTrades(db), LedgerStep.waiting);
      expect(await db.hasFlag(LedgerNames.flagHoldings), isFalse);

      File('${dir.path}/book.entries.json').writeAsStringSync(good);
      await BookDatabase.closeAll();
      final next = await _open();
      expect(await LedgerMigration.collapseTrades(next), LedgerStep.done);
      expect((await _newEntries().read()).map((r) => r.item.id), ['e1', 'e2', 'buy']);
    });

    test('the app does not run it while the database has it off, and does when it is run', () async {
      await _writeJsonFiles();
      await _writeHoldings(trades: [_tr(_trade('buy', TransactionKind.buy), 10)]);
      final db = await _open();
      final store = BookStore();
      expect((await store.entries.load()).map((e) => e.id), ['e1']);
      expect(await db.hasFlag(LedgerNames.flagHoldings), isFalse);
      await LedgerMigration.run(db, collapseHoldings: true);
      expect((await store.entries.load()).map((e) => e.id), ['buy', 'e1']);
    });

    test('the app runs it on the first read of the book, now that holdings are read from the book', () async {
      await _writeJsonFiles();
      await _writeHoldings(trades: [_tr(_trade('buy', TransactionKind.buy), 10)]);
      final store = BookStore();
      expect((await store.entries.load()).map((e) => e.id), ['buy', 'e1']);
      expect(await (await BookDatabase.open()).hasFlag(LedgerNames.flagHoldings), isTrue);
      expect(await store.ledgerProblems(), isEmpty);
    });
  });

  group('several openers at once', () {
    test('four isolates and this one migrate a version 1 file, and the book is the one a single opener reads', () async {
      await writeV1(file, rows: _v1Rows());
      final results = await Future.wait([for (var i = 0; i < 4; i++) _race(dir.path, false), _race(dir.path, false)]);
      expect(results.toSet(), hasLength(1), reason: results.first);
      expect(results.first, isNot(startsWith('failed')));

      final db = await _open();
      expect(await count(db, "SELECT count(*) FROM changes WHERE op = 'relabel'"), 4);
      expect(await count(db, "SELECT count(*) FROM changes WHERE op = 'import'"), 0);
      expect(await count(db, 'SELECT count(*) FROM entries'), 2);
      expect(await count(db, 'SELECT count(*) FROM entry_lines'), 4);
      expect(await names(db, 'SELECT DISTINCT collection FROM entries'), [LedgerNames.entries]);
      expect(await count(db, "SELECT count(*) FROM meta WHERE key = 'migrated.ledger.book'"), 1);
    });

    test('and from JSON files only', () async {
      await _writeJsonFiles();
      final results = await Future.wait([for (var i = 0; i < 4; i++) _race(dir.path, false)]);
      expect(results.toSet(), hasLength(1), reason: results.first);
      expect(results.first, isNot(startsWith('failed')));
      final db = await _open();
      expect(await count(db, "SELECT count(*) FROM changes WHERE op = 'relabel'"), 4);
      expect(await count(db, "SELECT count(*) FROM changes WHERE op = 'import'"), 4);
      expect(await count(db, 'SELECT count(*) FROM entries'), 2);
    });

    test('step B done by several at once is done once', () async {
      await _writeJsonFiles();
      final trades = [_tr(_trade('buy', TransactionKind.buy, fee: 5), 10), _tr(_trade('sale', TransactionKind.sell), 11)];
      await _writeHoldings(trades: trades);
      final db = await _open();
      await LedgerMigration.migrateBook(db);
      await _newEntries().write([...await _newEntries().read(), _cash('buy', -50500, 20)]);
      final before = await _newEntries().read();
      await BookDatabase.closeAll();

      final results = await Future.wait([for (var i = 0; i < 4; i++) _race(dir.path, true)]);
      expect(results.toSet(), hasLength(1), reason: results.first);
      expect(results.first, isNot(startsWith('failed')));
      final again = await _open();
      expect(await count(again, "SELECT count(*) FROM changes WHERE op = 'collapse'"), 1);
      final oracle = LegacyCollapse.collapse(transactions: trades, lots: const [], entries: before);
      expect(_dumpAll(_sorted(await _newEntries().read())), _dumpAll(oracle));
    });

    test('a connection held open by another process makes it wait, not fail', () async {
      await writeV1(file, rows: _v1Rows());
      final released = await holdWriteLock(file, const Duration(milliseconds: 600));
      expect((await BookStore().entries.load()).map((e) => e.id), ['e1']);
      await released;
    });
  });

  group('on the background isolate', () {
    test('the migration, the collapse and the stores work through the background executor', () async {
      BookDatabase.executorOverride = (f) => NativeDatabase.createInBackground(f);
      await writeV1(file, rows: _v1Rows());
      final trades = [_tr(_trade('buy', TransactionKind.buy, fee: 5), 10)];
      await _writeHoldings(trades: trades);

      final cloud = _Cloud();
      final db = await _open();
      final store = BookStore(cloud: cloud);
      expect((await store.entries.load()).map((e) => e.id), ['e1']);
      expect(await db.hasFlag(LedgerNames.flagBook), isTrue);
      expect(await names(db, 'SELECT DISTINCT collection FROM entries'), [LedgerNames.entries]);

      await _newEntries().write([...await _newEntries().read(), _cash('buy', -50500, 20)]);
      final before = await _newEntries().read();
      expect(await LedgerMigration.collapseTrades(db), LedgerStep.done);
      expect(_dumpAll(_sorted(await _newEntries().read())), _dumpAll(LegacyCollapse.collapse(transactions: trades, lots: const [], entries: before)));
      expect(cloud.values.keys.toSet().intersection({for (final c in LedgerNames.collections) c.$1}), isEmpty);
    });
  });
}
