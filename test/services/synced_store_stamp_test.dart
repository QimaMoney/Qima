import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/book_account.dart';
import 'package:qima/models/default_categories.dart';
import 'package:qima/models/legacy_collapse.dart';
import 'package:qima/models/money_settings.dart';
import 'package:qima/models/syncable.dart';
import 'package:qima/services/book_db/book_database.dart';
import 'package:qima/services/book_db/db_records.dart';
import 'package:qima/services/book_db/ledger_plan.dart';
import 'package:qima/services/book_store.dart';
import 'package:qima/services/cloud_kv_store.dart';
import 'package:qima/services/legacy_absorber.dart';
import 'package:qima/services/local_file_store.dart';
import 'package:qima/services/synced_store.dart';

/// A device never keeps a record that would lose a merge to the one it held:
/// what the person changes is stamped after what it replaces whatever the
/// clock says, and equal stamps are settled one way everywhere.

class _Item extends Syncable {
  @override
  final String id;
  final String label;

  _Item(this.id, this.label);

  @override
  Map<String, dynamic> toJson() => {'id': id, 'label': label};

  static _Item fromJson(Map<String, dynamic> json) => _Item(json['id'] as String, json['label'] as String);
}

class _Cloud implements CloudKVStore {
  final Map<String, String> values = {};
  int writes = 0;

  @override
  Future<String?> getString(String key) async => values[key];

  @override
  Future<void> setString(String key, String value) async {
    writes++;
    values[key] = value;
  }

  @override
  Future<void> synchronize() async {}

  @override
  Future<bool> accountStatus() async => true;

  @override
  Stream<CloudKVChangeEvent> get didChangeExternally => const Stream.empty();
}

RecurringPayment _rent(String name) => RecurringPayment(id: 'rent', name: name, amount: 100000, fromAccountId: 'acct.bank', categoryId: 'category.rent', start: DateTime(2026, 1, 1));

/// A cloud that can hold a read back, so a save can be stopped between
/// reading the collection and writing it.
class _Gate implements CloudKVStore {
  final _Cloud inner;
  Completer<void>? _held;
  Completer<void> _reached = Completer<void>();

  _Gate(this.inner);

  void hold() {
    _held = Completer<void>();
    _reached = Completer<void>();
  }

  Future<void> get reached => _reached.future;

  void release() => _held!.complete();

  @override
  Future<String?> getString(String key) async {
    final value = await inner.getString(key);
    final held = _held;
    if (held != null && !held.isCompleted) {
      if (!_reached.isCompleted) _reached.complete();
      await held.future;
    }
    return value;
  }

  @override
  Future<void> setString(String key, String value) => inner.setString(key, value);

  @override
  Future<void> synchronize() async {}

  @override
  Future<bool> accountStatus() async => true;

  @override
  Stream<CloudKVChangeEvent> get didChangeExternally => const Stream.empty();
}

BookAccount _account(String id, String name) => BookAccount(id: id, name: name, side: AccountSide.own, type: AccountType.cash, currency: 'USD');

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('qima_stamp');
    LocalFileStore.overrideDirectoryForTesting(dir);
  });

  tearDown(() async {
    await BookDatabase.closeAll();
    await dir.delete(recursive: true);
  });

  test('a stamp is now, unless the record held is stamped later: then it is one step after that', () {
    final now = DateTime.utc(2026, 6, 1, 12);
    Record<_Item> held(DateTime at) => Record(item: _Item('x', 'held'), order: 0, updatedAt: at);
    expect(SyncedStore.stampAfter(now, null), now);
    expect(SyncedStore.stampAfter(now, held(now.subtract(const Duration(days: 1)))), now);
    expect(SyncedStore.stampAfter(now, held(now)), now.add(SyncedStore.stampStep), reason: 'a tie would be left to the tie rule');
    final ahead = now.add(const Duration(minutes: 3, microseconds: 500));
    final stamp = SyncedStore.stampAfter(now, held(ahead));
    expect(stamp, ahead.add(SyncedStore.stampStep));

    // The step survives the stored form, on the platform that keeps the
    // least of a stamp (web keeps milliseconds).
    final asWebKeepsIt = DateTime.fromMillisecondsSinceEpoch(DateTime.parse(stamp.toIso8601String()).millisecondsSinceEpoch, isUtc: true);
    expect(asWebKeepsIt.isAfter(ahead), isTrue);
    expect(DateTime.parse(stamp.toUtc().toIso8601String()), stamp);
  });

  for (final (database, loaded) in [(false, true), (true, true), (false, false), (true, false)]) {
    group('a store over ${database ? 'the database' : 'a JSON file'}, with records stamped ahead of its clock ${loaded ? 'that it has taken in' : 'in the cloud, not loaded yet'},', () {
      late _Cloud cloud;
      late SyncedStore<_Item> store;
      late DateTime ahead;

      Future<Record<_Item>> stored(String id) async => (await store.exportRecords()).singleWhere((r) => r.item.id == id);

      setUp(() async {
        cloud = _Cloud();
        store = SyncedStore<_Item>(
          filePath: 'items.json',
          cloudKey: 'items',
          itemFromJson: _Item.fromJson,
          cloud: cloud,
          local: database ? DocumentRecords<_Item>(collection: 'items', filePath: 'items.json', itemFromJson: _Item.fromJson) : null,
        );
        // What a device whose clock runs an hour fast saved. Either this
        // one has taken it in, or it has only arrived in the cloud.
        ahead = DateTime.now().toUtc().add(const Duration(hours: 1));
        final theirs = [
          for (final (i, id) in ['a', 'b', 'c'].indexed) Record(item: _Item(id, 'from the other device'), order: i.toDouble(), updatedAt: ahead),
        ];
        if (loaded) {
          await store.importRecords(theirs, replace: false);
        } else {
          await store.upsert(_Item('a', 'mine, before'));
          final current = (jsonDecode(cloud.values['items']!) as List<dynamic>).cast<Map<String, dynamic>>();
          cloud.values['items'] = jsonEncode([for (final r in current) if ((r['item'] as Map<String, dynamic>)['id'] != 'a') r, for (final r in theirs) r.toJson()]);
        }
      });

      /// The record [id] as another device holds it, merged with what this
      /// one holds now: this one's change must be the one that stays.
      Future<void> expectWins(String id, {bool deleted = false, String? label}) async {
        final mine = await stored(id);
        expect(mine.updatedAt.isAfter(ahead), isTrue, reason: 'stamped after the record it replaces');
        expect(mine.updatedAt.difference(ahead), SyncedStore.stampStep, reason: 'and no further than it has to be');
        final theirs = Record(item: _Item(id, 'from the other device'), order: 0, updatedAt: ahead);
        final kept = store.merge([theirs], [mine]).single;
        expect(identical(kept, mine), isTrue);
        expect(store.merge([mine], [theirs]).single, same(mine));
        expect(mine.deleted, deleted);
        if (label != null) expect(mine.item.label, label);
        // And it is what the cloud copy holds, not dropped on the way there.
        final inCloud = (jsonDecode(cloud.values['items']!) as List<dynamic>).cast<Map<String, dynamic>>().singleWhere((r) => (r['item'] as Map<String, dynamic>)['id'] == id);
        expect(DateTime.parse(inCloud['updatedAt'] as String), mine.updatedAt);
      }

      test('a save is kept', () async {
        final live = await store.upsert(_Item('a', 'corrected'));
        expect(live.singleWhere((i) => i.id == 'a').label, 'corrected', reason: 'the person sees what they saved');
        await expectWins('a', label: 'corrected');
        expect((await stored('b')).updatedAt, ahead, reason: 'a record that was not changed keeps its stamp');
        expect(live.map((i) => i.id), ['a', 'b', 'c'], reason: 'and keeps its place');
      });

      test('a save of several is kept', () async {
        await store.upsertAll([_Item('a', 'one'), _Item('b', 'two'), _Item('new', 'three')]);
        await expectWins('a', label: 'one');
        await expectWins('b', label: 'two');
        expect((await stored('new')).updatedAt.isBefore(ahead), isTrue, reason: 'a new record is stamped by the clock');
      });

      test('a deletion is kept', () async {
        expect((await store.delete('a')).map((i) => i.id), ['b', 'c']);
        await expectWins('a', deleted: true);
      });

      test('a deletion of several is kept', () async {
        expect(await store.deleteAll(['a', 'c']), hasLength(1));
        await expectWins('a', deleted: true);
        await expectWins('c', deleted: true);
      });

      test('a new order is kept', () async {
        expect((await store.setOrder(['c', 'b', 'a'])).map((i) => i.id), ['c', 'b', 'a']);
        await expectWins('a');
        await expectWins('c');
        expect((await stored('b')).updatedAt, ahead, reason: 'b stayed where it was');
      });

      test('a restore that replaces everything is kept, the records it brings and the ones it removes', () async {
        final live = await store.importRecords([Record(item: _Item('a', 'restored'), order: 0, updatedAt: DateTime.utc(2020))], replace: true);
        expect(live.single.label, 'restored');
        await expectWins('a', label: 'restored');
        await expectWins('b', deleted: true);
        await expectWins('c', deleted: true);
      });

      test('a restore of part of the collection is kept, with the time it was given or without', () async {
        await store.importRecords(
          [Record(item: _Item('a', 'restored'), order: 0, updatedAt: DateTime.utc(2020))],
          replace: true,
          now: DateTime.utc(2021),
          replaceWhere: (r) => r.item.id != 'c',
        );
        await expectWins('a', label: 'restored');
        await expectWins('b', deleted: true);
        expect((await stored('c')).updatedAt, ahead, reason: 'outside what was replaced');
      });

      test('a change is stamped by the clock when the clock is the later of the two', () async {
        final before = DateTime.now();
        await store.upsert(_Item('old', 'first'));
        await store.importRecords([Record(item: _Item('old', 'first'), order: 9, updatedAt: DateTime.utc(2020))], replace: false);
        await store.upsert(_Item('old', 'second'));
        final stamp = (await stored('old')).updatedAt;
        expect(stamp.isBefore(before), isFalse);
        expect(stamp.isBefore(ahead), isTrue);
      });
    });
  }

  group('rows of the database', () {
    late BookDatabase db;
    Record<_Item> rec(String label, int day, {bool deleted = false}) => Record(item: _Item('x', label), order: 0, updatedAt: DateTime.utc(2026, 3, day), deleted: deleted);
    bool byLabel(Record<_Item> incoming, Record<_Item> stored) => incoming.item.label.compareTo(stored.item.label) > 0;
    DocumentRecords<_Item> rows({bool Function(Record<_Item>, Record<_Item>)? prefer}) => DocumentRecords<_Item>(collection: 'items', filePath: 'items.json', itemFromJson: _Item.fromJson, prefer: prefer);
    Future<List<String>> log() async => [for (final r in await db.customSelect("SELECT op || ':' || id AS x FROM changes WHERE id != '' ORDER BY seq").get()) r.data['x'] as String];

    setUp(() async {
      db = await BookDatabase.open();
    });

    test('a save worked out from an older read does not put an older record over a newer one, and logs nothing', () async {
      final app = rows();
      final other = rows();
      await app.write([rec('first', 1)]);
      final read = await other.read();
      await app.write([rec('newer', 5)]);

      await other.write([read.single.copyWith(item: _Item('x', 'from the old read'), updatedAt: DateTime.utc(2026, 3, 3))]);
      expect((await app.read()).single.item.label, 'newer');
      expect(await log(), ['put:x', 'put:x']);

      await other.write([rec('newest', 9)]);
      expect((await app.read()).single.item.label, 'newest');
      await other.write([rec('gone', 4, deleted: true)]);
      expect((await app.read()).single.deleted, isFalse, reason: 'an older deletion does not remove a newer record');
    });

    test('equal stamps go to the record the tie rule prefers, whichever is written second', () async {
      final held = rows(prefer: byLabel);
      await held.write([rec('m', 1)]);
      await rows(prefer: byLabel).write([rec('a', 1)]);
      expect((await held.read()).single.item.label, 'm');
      await rows(prefer: byLabel).write([rec('z', 1)]);
      expect((await held.read()).single.item.label, 'z');
      expect(await log(), ['put:x', 'put:x']);
    });

    test('without a tie rule an equal stamp goes to the record being written, as a merge without one does', () async {
      await rows().write([rec('m', 1)]);
      await rows().write([rec('a', 1)]);
      expect((await rows().read()).single.item.label, 'a');
      final bare = SyncedStore<_Item>(filePath: 'x.json', cloudKey: 'x', itemFromJson: _Item.fromJson, cloud: _Cloud());
      expect(bare.merge([rec('m', 1)], [rec('a', 1)]).single.item.label, 'a');
    });

    test('an old file is taken in by the same rule, as a source that flows one way: a tie is never taken from it', () async {
      // Rows that are there before the file of an earlier build is imported.
      for (final (id, label) in [('tie', 'stored'), ('older', 'stored'), ('newer', 'stored')]) {
        await db.customStatement("INSERT INTO documents (collection, id, body, sort, updated_at, deleted) VALUES ('items', ?, ?, 0, '2026-03-05T00:00:00.000Z', 0)", [id, jsonEncode({'id': id, 'label': label})]);
      }
      Record<_Item> filed(String id, String label, int day) => Record(item: _Item(id, label), order: 0, updatedAt: DateTime.utc(2026, 3, day));
      File('${dir.path}/items.json').writeAsStringSync(jsonEncode({
        'records': [
          for (final r in [filed('tie', 'zzz from the file', 5), filed('older', 'from the file', 4), filed('newer', 'from the file', 6), filed('twice', 'aaa', 1), filed('twice', 'mmm', 1), filed('twice', 'bbb', 1)]) r.toJson(),
        ],
      }));
      final read = {for (final r in await rows(prefer: byLabel).read()) r.item.id: r.item.label};
      expect(read, {'tie': 'stored', 'older': 'stored', 'newer': 'from the file', 'twice': 'mmm'}, reason: 'of two in the file with one stamp the tie rule picks; against a stored row only a later stamp counts');
    });

    test('the rows a caller names are the rows it gets, across more ids than one statement takes', () async {
      final many = rows();
      final records = [for (var i = 0; i < 1300; i++) Record(item: _Item('id$i', 'label $i'), order: i.toDouble(), updatedAt: DateTime.utc(2026, 3, 1))];
      await many.write(records);
      final wanted = {for (var i = 0; i < 1300; i += 2) 'id$i', 'not there'};
      final got = await db.transaction(() => many.storedIn(db, ids: wanted));
      expect(got.map((r) => r.item.id).toSet(), wanted.difference({'not there'}));
      expect(got.firstWhere((r) => r.item.id == 'id600').item.label, 'label 600');
      expect(await db.transaction(() => many.storedIn(db, ids: const [])), isEmpty);
      expect((await db.transaction(() => many.storedIn(db))).length, 1300);

      // A write of many reads and changes only those.
      await many.write([for (final r in records) r.item.id.endsWith('7') ? r.copyWith(item: _Item(r.item.id, 'changed'), updatedAt: DateTime.utc(2026, 3, 2)) : r]);
      expect((await many.read()).where((r) => r.item.label == 'changed').length, 130);
    });
  });

  group('a store whose save loses to a row another connection stored since it read', () {
    test('shows, remembers and sends to the cloud the row that is stored, not the one it tried to write', () async {
      // The same file through two paths: two connections, as two isolates
      // of the app have.
      final real = Directory('${dir.path}/real')..createSync();
      final link = Link('${dir.path}/link')..createSync(real.path);
      void here() => LocalFileStore.overrideDirectoryForTesting(real);
      void there() => LocalFileStore.overrideDirectoryForTesting(Directory(link.path));
      SyncedStore<_Item> store(CloudKVStore cloud) => SyncedStore<_Item>(
            filePath: 'items.json',
            cloudKey: 'items',
            itemFromJson: _Item.fromJson,
            cloud: cloud,
            local: DocumentRecords<_Item>(collection: 'items', filePath: 'items.json', itemFromJson: _Item.fromJson),
          );
      final cloud = _Cloud();
      here();
      final app = store(cloud);
      await app.upsert(_Item('x', 'first'));
      await app.upsert(_Item('y', 'other'));
      final db = await BookDatabase.open();

      // The other isolate saves x with a stamp ahead of this one's clock,
      // and nothing of it has reached the cloud this store reads.
      there();
      expect(identical(await BookDatabase.open(), db), isFalse);
      final ahead = DateTime.now().toUtc().add(const Duration(hours: 1));
      await store(_Cloud()).importRecords([Record(item: _Item('x', 'from the other isolate'), order: 0, updatedAt: ahead)], replace: false);

      // This store's rows are as it last read them. It reads the collection
      // (x as the other isolate left it), and before it writes the other
      // isolate saves x once more.
      here();
      final gate = _Gate(cloud);
      final slow = store(gate);
      await slow.load();
      gate.hold();
      final saving = slow.upsert(_Item('x', 'my edit'));
      await gate.reached;
      there();
      final later = ahead.add(const Duration(hours: 1));
      await store(_Cloud()).importRecords([Record(item: _Item('x', 'saved again there'), order: 0, updatedAt: later)], replace: false);
      here();
      final log = await db.customSelect('SELECT count(*) AS n FROM changes').getSingle();
      gate.release();
      final live = await saving;

      expect(live.singleWhere((i) => i.id == 'x').label, 'saved again there', reason: 'the save lost, and the person sees what is stored');
      expect((await db.customSelect('SELECT count(*) AS n FROM changes').getSingle()).data['n'], log.data['n'], reason: 'nothing was written');
      final inCloud = (jsonDecode(cloud.values['items']!) as List<dynamic>).cast<Map<String, dynamic>>().singleWhere((r) => (r['item'] as Map<String, dynamic>)['id'] == 'x');
      expect((inCloud['item'] as Map<String, dynamic>)['label'], 'saved again there', reason: 'the cloud is sent the stored row, not the one that lost');
      expect(DateTime.parse(inCloud['updatedAt'] as String), later);

      // The store remembers the stored row as what it wrote: a save of
      // something else does not touch x again.
      await slow.upsert(_Item('y', 'changed'));
      final rows = await db.customSelect("SELECT id, body FROM documents WHERE collection = 'items' ORDER BY id").get();
      expect([for (final r in rows) '${r.data['id']}:${(jsonDecode(r.data['body'] as String) as Map<String, dynamic>)['label']}'], ['x:saved again there', 'y:changed']);
      expect((await slow.load()).map((i) => i.label).toSet(), {'saved again there', 'changed'});

      // A load too: the cloud brings a version of y that is newer than the
      // one read, and the other isolate stores a newer one still before the
      // load writes.
      DateTime after(int minutes) => DateTime.now().toUtc().add(Duration(minutes: minutes));
      cloud.values['items'] = jsonEncode([
        for (final r in await slow.exportRecords())
          if (r.item.id == 'y') Record(item: _Item('y', 'from the cloud'), order: r.order, updatedAt: after(10)).toJson() else r.toJson(),
      ]);
      gate.hold();
      final loading = slow.load();
      await gate.reached;
      there();
      await store(_Cloud()).importRecords([Record(item: _Item('y', 'saved there meanwhile'), order: 1, updatedAt: after(20))], replace: false);
      here();
      gate.release();
      expect((await loading).singleWhere((i) => i.id == 'y').label, 'saved there meanwhile', reason: 'a load returns what is stored');
      final sent = (jsonDecode(cloud.values['items']!) as List<dynamic>).cast<Map<String, dynamic>>().singleWhere((r) => (r['item'] as Map<String, dynamic>)['id'] == 'y');
      expect((sent['item'] as Map<String, dynamic>)['label'], 'saved there meanwhile');
    });
  });

  group('two records with one id and one stamp in a document collection of the book', () {
    final stamp = DateTime.utc(2000);
    Record<BookAccount> version(String name) => Record(item: _account('category.x', name), order: -1000, updatedAt: stamp);

    test('settle on the same one on both devices, whichever the cloud held first, and the cloud is then left alone', () async {
      final expected = jsonEncode(BookStore().accounts.merge([version('Dining')], [version('Restaurants')]).single.toJson());
      for (final first in ['Dining', 'Restaurants']) {
        final second = first == 'Dining' ? 'Restaurants' : 'Dining';
        final cloud = _Cloud();
        final one = Directory('${dir.path}/$first-one')..createSync();
        final two = Directory('${dir.path}/$first-two')..createSync();
        LocalFileStore.overrideDirectoryForTesting(one);
        final a = BookStore(cloud: cloud);
        await a.accounts.insertMissing([version(first)]);
        LocalFileStore.overrideDirectoryForTesting(two);
        final b = BookStore(cloud: LocalOnlyCloudKVStore());
        await b.accounts.insertMissing([version(second)]);
        final joined = BookStore(cloud: cloud);
        await joined.accounts.load();
        expect(jsonEncode((await joined.accounts.exportRecords()).single.toJson()), expected, reason: 'the cloud held $first');
        LocalFileStore.overrideDirectoryForTesting(one);
        await a.accounts.load();
        expect(jsonEncode((await a.accounts.exportRecords()).single.toJson()), expected, reason: 'the cloud held $first');

        final writes = cloud.writes;
        for (final (directory, store) in [(two, joined), (one, a), (two, joined)]) {
          LocalFileStore.overrideDirectoryForTesting(directory);
          await store.accounts.load();
        }
        expect(cloud.writes, writes, reason: 'neither device writes the key again');
      }
    });

    test('are not settled by what an old cloud key holds: a tie from there is never taken', () async {
      final cloud = _Cloud();
      final book = BookStore(cloud: cloud);
      final absorber = LegacyAbsorber.forBook(book, cloud);
      await book.loadAccounts();
      final mine = (await book.accounts.exportRecords()).firstWhere((r) => r.item.id == DefaultCategories.all.first.id);
      await book.recurring.insertMissing([Record(item: _rent('Rent'), order: 0, updatedAt: stamp)]);

      // The same default category as an earlier build seeded it (same id,
      // order and fixed stamp) under two names, one sorting before this
      // build's and one after, so whichever the tie rule would prefer is
      // among them; and a recurring payment in the same position.
      for (final name in ['Aaa', 'Zzz']) {
        final theirs = Record(item: mine.item.copyWith(name: name), order: mine.order, updatedAt: mine.updatedAt);
        expect(book.accounts.merge([mine], [theirs]).single.item.name, name == 'Zzz' ? 'Zzz' : mine.item.name, reason: 'among devices of this build the tie rule decides');
        cloud.values[LedgerNames.legacyAccounts] = jsonEncode([theirs.toJson()]);
        cloud.values[LedgerNames.legacyRecurring] = jsonEncode([Record(item: _rent(name), order: 0, updatedAt: stamp).toJson()]);
        final writes = cloud.writes;
        expect(await absorber.absorb(), isEmpty, reason: name);
        expect(cloud.writes, writes, reason: name);
        expect((await book.accounts.exportRecords()).firstWhere((r) => r.item.id == mine.item.id).item.name, mine.item.name, reason: name);
        expect((await book.recurring.exportRecords()).single.item.name, 'Rent', reason: name);
      }

      // A strictly later stamp is what an old key is taken for.
      cloud.values[LedgerNames.legacyAccounts] = jsonEncode([Record(item: mine.item.copyWith(name: 'Renamed there'), order: mine.order, updatedAt: DateTime.utc(2001)).toJson()]);
      expect(await absorber.absorb(), {BookStore.accountsKey});
      expect((await book.accounts.exportRecords()).firstWhere((r) => r.item.id == mine.item.id).item.name, 'Renamed there');
    });

    test('have a tie rule of their own, one for accounts, recurring payments and settings', () {      expect(BookStore().accounts.prefer, same(BookStore().recurring.prefer));
      expect(LegacyCollapse.settles(version('B'), version('A')), isTrue);
      expect(LegacyCollapse.settles(version('A'), version('B')), isFalse);
      expect(LegacyCollapse.settles(version('A'), version('A')), isFalse, reason: 'a record does not beat itself');
      expect(LegacyCollapse.settles(version('A').copyWith(deleted: true), version('B')), isTrue, reason: 'a deletion over a live record');
    });
  });
}
