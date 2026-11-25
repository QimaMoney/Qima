import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/asset.dart';
import 'package:qima/models/book_account.dart';
import 'package:qima/models/book_entry.dart';
import 'package:qima/models/holding_transaction.dart';
import 'package:qima/services/book_db/book_database.dart';
import 'package:qima/services/book_db/db_records.dart';
import 'package:qima/services/book_store.dart';
import 'package:qima/services/cloud_kv_store.dart';
import 'package:qima/services/holdings_ledger.dart';
import 'package:qima/services/local_file_store.dart';
import 'package:qima/services/synced_store.dart';

BookEntry _spend(String id, int amount) => BookEntry(
      id: id,
      date: DateTime(2026, 1, 2),
      template: EntryTemplate.spend,
      baseCurrency: 'USD',
      merchant: 'Cafe',
      lines: [
        EntryLine(accountId: 'bank', amount: -amount, currency: 'USD', baseAmount: -amount),
        EntryLine(accountId: 'category.dining', amount: amount, currency: 'USD', baseAmount: amount),
      ],
    );

HoldingTransaction _buy(String id) => HoldingTransaction(
      id: id,
      instrumentID: 'metal.XAU',
      kind: TransactionKind.buy,
      quantity: 1,
      unit: PriceUnit.troyOunce,
      unitPrice: 2000,
      currency: 'USD',
      date: DateTime(2026, 1, 1),
    );

Record<BookEntry> _record(BookEntry e, {double order = 0, DateTime? at, bool deleted = false}) =>
    Record<BookEntry>(item: e, order: order, updatedAt: at ?? DateTime.utc(2026, 3, 1), deleted: deleted);

/// A cloud that holds nothing and can hold a read back, so a load can be
/// stopped between reading the local copy and writing it.
class _GateCloud implements CloudKVStore {
  Completer<void>? gate;

  @override
  Future<String?> getString(String key) async {
    if (gate != null) await gate!.future;
    return null;
  }

  @override
  Future<void> setString(String key, String value) async {}

  @override
  Future<void> synchronize() async {}

  @override
  Future<bool> accountStatus() async => false;

  @override
  Stream<CloudKVChangeEvent> get didChangeExternally => const Stream.empty();
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('qima_db_concurrency');
    LocalFileStore.overrideDirectoryForTesting(dir);
  });

  tearDown(() async {
    await BookDatabase.closeAll();
    await dir.delete(recursive: true);
  });

  group('a write applies what the store changed, not its whole snapshot', () {
    late EntryRecords app;
    late EntryRecords other;
    late BookDatabase db;

    Future<List<String>> ids(EntryRecords store) async => [for (final r in await store.read()) r.item.id];
    Future<int> logged() async => (await db.customSelect('SELECT count(*) AS n FROM changes').getSingle()).data['n'] as int;
    Future<List<String>> ops() async => [for (final r in await db.customSelect("SELECT op || ':' || id AS x FROM changes ORDER BY seq").get()) r.data['x'] as String];

    setUp(() async {
      app = EntryRecords(collection: 'book.entries', filePath: 'book.entries.json');
      other = EntryRecords(collection: 'book.entries', filePath: 'book.entries.json');
      db = await BookDatabase.open();
    });

    test('rows another store added since this one read are left alone by an unchanged write and by one that changes other rows', () async {
      await app.write([_record(_spend('s1', 100))]);
      final read = await other.read();

      await app.write([_record(_spend('s1', 100)), _record(_spend('s2', 200), order: 1)]);
      await other.write(read);
      expect(await ids(app), ['s1', 's2'], reason: 'a write of what was read changes nothing');

      await other.write([...read, _record(_spend('s3', 300), order: 2)]);
      expect(await ids(app), ['s1', 's2', 's3']);
    });

    test('a row another store changed is not reverted by a write that did not change it', () async {
      await app.write([_record(_spend('s1', 100))]);
      final read = await other.read();
      await app.write([_record(_spend('s1', 12345), at: DateTime.utc(2026, 3, 2))]);

      await other.write([...read, _record(_spend('s2', 200), order: 1)]);
      final back = await app.read();
      expect(back.map((r) => r.item.id), ['s1', 's2']);
      expect(back.first.item.lines.first.amount, -12345);
    });

    test('a row both stores changed takes the later writer', () async {
      await app.write([_record(_spend('s1', 100))]);
      await other.read();
      await app.write([_record(_spend('s1', 111), at: DateTime.utc(2026, 3, 2))]);
      await other.write([_record(_spend('s1', 222), at: DateTime.utc(2026, 3, 3))]);
      expect((await app.read()).single.item.lines.first.amount, -222);
      await app.write([_record(_spend('s1', 333), at: DateTime.utc(2026, 3, 4))]);
      expect((await other.read()).single.item.lines.first.amount, -333);
    });

    test('an id the store read and dropped is purged, one it never read is not, and one already purged is not logged again', () async {
      await app.write([_record(_spend('s1', 100)), _record(_spend('s2', 200), order: 1)]);
      final read = await other.read();
      await app.write([_record(_spend('s1', 100)), _record(_spend('s2', 200), order: 1), _record(_spend('s3', 300), order: 2)]);

      await other.write([read.first]);
      expect(await ids(app), ['s1', 's3'], reason: 's2 was read and dropped, s3 never read');

      final before = await logged();
      await app.write([_record(_spend('s1', 100)), _record(_spend('s3', 300), order: 2)]);
      await app.write(const []);
      expect(await ids(app), isEmpty);
      expect((await ops()).skip(before), ['purge:s1', 'purge:s3']);
    });

    test('a purge of a row the other store already removed writes nothing', () async {
      await app.write([_record(_spend('s1', 100))]);
      await other.read();
      await app.write(const []);
      final before = await logged();
      await other.write(const []);
      expect(await logged(), before);
    });

    test('a first write with no earlier read puts its records and purges nothing', () async {
      await app.write([_record(_spend('s1', 100))]);
      final fresh = EntryRecords(collection: 'book.entries', filePath: 'book.entries.json');
      await fresh.write([_record(_spend('s2', 200), order: 1)]);
      expect(await ids(app), ['s1', 's2']);
    });

    test('a load that changes nothing writes nothing', () async {
      await app.write([_record(_spend('s1', 100)), _record(_spend('s2', 200), order: 1, deleted: true)]);
      final before = await logged();
      final read = await app.read();
      await app.write(read);
      await app.write(read);
      expect(await logged(), before);
    });

    test('the log names only rows this store really changed', () async {
      await app.write([_record(_spend('s1', 100))]);
      final read = await other.read();
      await app.write([_record(_spend('s1', 100)), _record(_spend('s2', 200), order: 1)]);
      final before = await logged();
      await other.write([...read, _record(_spend('s3', 300), order: 2)]);
      expect((await ops()).skip(before), ['put:s3']);

      // A row that is already what would be written is not logged either.
      final mirror = EntryRecords(collection: 'book.entries', filePath: 'book.entries.json');
      final seen = await mirror.read();
      await app.write([...seen, _record(_spend('s4', 400), order: 3)]);
      final after = await logged();
      await mirror.write([...seen, _record(_spend('s4', 400), order: 3)]);
      expect(await logged(), after);
    });

    test('a store that wrote is measured against what it wrote', () async {
      await app.write([_record(_spend('s1', 100))]);
      final before = await logged();
      await app.write([_record(_spend('s1', 100))]);
      expect(await logged(), before);
      await app.write([_record(_spend('s1', 101), at: DateTime.utc(2026, 3, 2))]);
      expect(await logged(), before + 1);
    });

    test('documents behave the same way', () async {
      BookAccount account(String id) => BookAccount(id: id, name: id, side: AccountSide.own, type: AccountType.cash, currency: 'USD');
      DocumentRecords<BookAccount> store() => DocumentRecords<BookAccount>(collection: 'book.accounts', filePath: 'book.accounts.json', itemFromJson: BookAccount.fromJson);
      Record<BookAccount> rec(String id, double order) => Record(item: account(id), order: order, updatedAt: DateTime.utc(2026, 3, 1));
      final a = store();
      final b = store();
      await a.write([rec('a1', 0)]);
      final read = await b.read();
      await a.write([rec('a1', 0), rec('a2', 1)]);
      await b.write(read);
      expect([for (final r in await a.read()) r.item.id], ['a1', 'a2']);
      await b.write([...read, rec('a3', 2)]);
      expect([for (final r in await a.read()) r.item.id], ['a1', 'a2', 'a3']);
    });
  });

  group('the book across stores', () {
    test('a second BookStore loading (the background refresh) between its read and its write does not undo a save', () async {
      final app = BookStore();
      await app.entries.upsert(_spend('s1', 700));
      await HoldingsLedger(app).upsert(_buy('t1'));

      final cloud = _GateCloud()..gate = Completer<void>();
      final background = HoldingsLedger(BookStore(cloud: cloud));
      final load = background.load();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      await app.entries.upsert(_spend('s2', 900));
      await app.entries.upsert(_spend('s1', 12345));
      await HoldingsLedger(app).upsert(_buy('t2'));

      cloud.gate!.complete();
      await load;

      final after = await app.entries.exportRecords();
      expect(after.map((r) => r.item.id).toSet(), {'s1', 's2', 't1', 't2'});
      expect(after.singleWhere((r) => r.item.id == 's1').item.lines.first.amount, -12345);
    });

    test('a load in another isolate does not lose saves made here', () async {
      final app = BookStore();
      await app.entries.upsert(_spend('seed', 1));
      final path = dir.path;
      final other = Isolate.run(() async {
        LocalFileStore.overrideDirectoryForTesting(Directory(path));
        final ledger = HoldingsLedger(BookStore());
        var loads = 0;
        while (!File('$path/stop').existsSync()) {
          await ledger.load();
          loads++;
        }
        await BookDatabase.closeAll();
        return loads;
      });

      const saves = 150;
      for (var i = 0; i < saves; i++) {
        await app.entries.upsert(_spend('e$i', 100 + i));
        if (i % 25 == 0) await HoldingsLedger(app).upsert(_buy('t$i'));
      }
      File('$path/stop').writeAsStringSync('x');
      final loads = await other;

      final ids = (await app.entries.exportRecords()).map((r) => r.item.id).toSet();
      expect([for (var i = 0; i < saves; i++) if (!ids.contains('e$i')) 'e$i'], isEmpty, reason: 'after $loads loads in the other isolate');
      expect([for (var i = 0; i < saves; i += 25) if (!ids.contains('t$i')) 't$i'], isEmpty);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
