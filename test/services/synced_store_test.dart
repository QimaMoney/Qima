import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/syncable.dart';
import 'package:qima/services/book_db/book_database.dart';
import 'package:qima/services/book_db/db_records.dart';
import 'package:qima/services/cloud_kv_store.dart';
import 'package:qima/services/local_file_store.dart';
import 'package:qima/services/switchable_cloud_kv_store.dart';
import 'package:qima/services/synced_store.dart';

/// Minimal [Syncable] test fixture: an id plus a label, so tests can assert
/// on which "version" of an item won a merge.
class _Item extends Syncable {
  @override
  final String id;
  final String label;

  _Item({required this.id, required this.label});

  @override
  Map<String, dynamic> toJson() => {'id': id, 'label': label};

  static _Item fromJson(Map<String, dynamic> json) => _Item(id: json['id'] as String, label: json['label'] as String);
}

/// In-memory [CloudKVStore] shared by however many [SyncedStore] instances
/// are constructed against it — standing in for a real iCloud/other cloud
/// backend so two simulated "devices" can sync through one object without
/// any platform channel.
class _FakeCloudKVStore implements CloudKVStore {
  final Map<String, String> _values = {};
  final _controller = StreamController<CloudKVChangeEvent>.broadcast();

  /// Makes the next read fail, once.
  bool failNextRead = false;

  /// Makes reads take a moment, so operations that overlap really interleave.
  bool slowReads = false;

  @override
  Future<String?> getString(String key) async {
    if (failNextRead) {
      failNextRead = false;
      throw StateError('cloud read failed');
    }
    if (slowReads) await Future<void>.delayed(const Duration(milliseconds: 1));
    return _values[key];
  }

  @override
  Future<void> setString(String key, String value) async {
    _values[key] = value;
    _controller.add(CloudKVChangeEvent(keys: [key], reason: CloudKVChangeReason.serverChange));
  }

  @override
  Future<void> synchronize() async {}

  @override
  Future<bool> accountStatus() async => true;

  @override
  Stream<CloudKVChangeEvent> get didChangeExternally => _controller.stream;
}

/// A local backend for the store under test, with a way to overwrite what it
/// holds behind the store's back.
class _Backend {
  final String name;
  final LocalRecords<_Item>? Function(String filePath) local;
  final Future<void> Function(String filePath, List<Record<_Item>> records) overwrite;

  const _Backend(this.name, this.local, this.overwrite);
}

final _backends = [
  _Backend(
    'the JSON file',
    (_) => null,
    (filePath, records) => LocalFileStore.writeJson(filePath, {'records': records.map((r) => r.toJson()).toList()}),
  ),
  _Backend(
    'the database',
    (filePath) => DocumentRecords<_Item>(collection: filePath, filePath: filePath, itemFromJson: _Item.fromJson),
    // A write never puts an older record over a newer one, so what is held
    // is purged first: the rows end up being exactly [records].
    (filePath, records) async {
      final rows = DocumentRecords<_Item>(collection: filePath, filePath: filePath, itemFromJson: _Item.fromJson);
      await rows.read();
      await rows.write(const []);
      await rows.write(records);
    },
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final backend in _backends) {
    group('SyncedStore over ${backend.name}', () => _suite(backend));
  }
}

void _suite(_Backend backend) {
  late Directory tempDir;
  late _FakeCloudKVStore cloud;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('qima_synced_store_test');
    LocalFileStore.overrideDirectoryForTesting(tempDir);
    cloud = _FakeCloudKVStore();
  });

  tearDown(() async {
    await BookDatabase.closeAll();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// Two independent [SyncedStore]s (distinct local mirrors, same cloud key)
  /// standing in for the same logical store on two devices.
  (SyncedStore<_Item>, SyncedStore<_Item>) devices({String cloudKey = 'items'}) {
    final deviceA = SyncedStore<_Item>(
      filePath: 'deviceA.items.json',
      local: backend.local('deviceA.items.json'),
      cloudKey: cloudKey,
      itemFromJson: _Item.fromJson,
      cloud: cloud,
    );
    final deviceB = SyncedStore<_Item>(
      filePath: 'deviceB.items.json',
      local: backend.local('deviceB.items.json'),
      cloudKey: cloudKey,
      itemFromJson: _Item.fromJson,
      cloud: cloud,
    );
    return (deviceA, deviceB);
  }

  group('last-write-wins per item', () {
    test('the later edit wins regardless of which device made it', () async {
      final (deviceA, deviceB) = devices();
      await deviceA.upsert(_Item(id: '1', label: 'from-A'));
      await deviceB.load(); // Pull A's write down to B's local mirror.
      await deviceB.upsert(_Item(id: '1', label: 'from-B-later'));

      final result = await deviceA.load(); // A picks up B's newer edit.
      expect(result.single.label, 'from-B-later');
    });
  });

  group('delete beats an older edit', () {
    test('a delete stamped after a concurrent edit wins the merge', () async {
      final (deviceA, deviceB) = devices();
      await deviceA.upsert(_Item(id: '1', label: 'v1'));
      await deviceB.load();

      await deviceA.upsert(_Item(id: '1', label: 'v2-edit'));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await deviceB.delete('1'); // Stamped later than A's edit.

      final resultA = await deviceA.load();
      final resultB = await deviceB.load();
      expect(resultA, isEmpty);
      expect(resultB, isEmpty);
    });

    test('an edit stamped after a concurrent delete resurrects the item', () async {
      final (deviceA, deviceB) = devices();
      await deviceA.upsert(_Item(id: '1', label: 'v1'));
      await deviceB.load();

      await deviceA.delete('1');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await deviceB.upsert(_Item(id: '1', label: 'v2-resurrected'));

      final result = await deviceA.load();
      expect(result.single.label, 'v2-resurrected');
    });
  });

  group('reorder', () {
    test('setOrder changes display order and is respected after a sync round-trip', () async {
      final (deviceA, deviceB) = devices();
      await deviceA.upsert(_Item(id: '1', label: 'one'));
      await deviceA.upsert(_Item(id: '2', label: 'two'));
      await deviceA.upsert(_Item(id: '3', label: 'three'));

      await deviceA.setOrder(['3', '1', '2']);
      final resultA = await deviceA.load();
      expect(resultA.map((i) => i.id).toList(), ['3', '1', '2']);

      final resultB = await deviceB.load();
      expect(resultB.map((i) => i.id).toList(), ['3', '1', '2']);
    });

    test('setOrder only bumps updatedAt for items whose order actually changed', () async {
      final store = SyncedStore<_Item>(
        filePath: 'single.items.json',
        local: backend.local('single.items.json'),
        cloudKey: 'single',
        itemFromJson: _Item.fromJson,
        cloud: cloud,
      );
      await store.upsert(_Item(id: '1', label: 'one'));
      await store.upsert(_Item(id: '2', label: 'two'));

      final beforeExport = await store.exportRecords();
      final beforeUpdatedAt = {for (final r in beforeExport) r.item.id: r.updatedAt};

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await store.setOrder(['1', '2']); // Identity reorder: nothing moved.

      final afterExport = await store.exportRecords();
      for (final r in afterExport) {
        expect(r.updatedAt, beforeUpdatedAt[r.item.id]);
      }
    });
  });

  group('tombstone pruning', () {
    test('a tombstone older than 365 days is pruned on the next load', () async {
      final store = SyncedStore<_Item>(
        filePath: 'prune.items.json',
        local: backend.local('prune.items.json'),
        cloudKey: 'prune',
        itemFromJson: _Item.fromJson,
        cloud: cloud,
      );
      await store.upsert(_Item(id: '1', label: 'one'));
      await store.delete('1');

      // Manually age the tombstone past the 365-day TTL by re-writing it
      // with an old updatedAt, bypassing the store's own now-stamping. Both
      // the local mirror and the cloud copy need aging — otherwise the
      // fresh cloud tombstone would win the LWW merge and undo the age-up.
      final records = await store.exportRecords();
      final aged = [
        for (final r in records) r.copyWith(updatedAt: DateTime.now().subtract(const Duration(days: 400))),
      ];
      await backend.overwrite('prune.items.json', aged);
      await cloud.setString('prune', jsonEncode(aged.map((r) => r.toJson()).toList()));

      final result = await store.load();
      expect(result, isEmpty);
      final remaining = await store.exportRecords();
      expect(remaining, isEmpty);
    });

    test('a tombstone within the 365-day TTL survives a load', () async {
      final store = SyncedStore<_Item>(
        filePath: 'keep.items.json',
        local: backend.local('keep.items.json'),
        cloudKey: 'keep',
        itemFromJson: _Item.fromJson,
        cloud: cloud,
      );
      await store.upsert(_Item(id: '1', label: 'one'));
      await store.delete('1');

      final remaining = await store.exportRecords();
      expect(remaining.length, 1);
      expect(remaining.single.deleted, isTrue);
    });
  });

  group('exportRecords / importRecords', () {
    test('merge folds imported records in using last-write-wins, keeping newer local edits', () async {
      final store = SyncedStore<_Item>(
        filePath: 'merge.items.json',
        local: backend.local('merge.items.json'),
        cloudKey: 'merge',
        itemFromJson: _Item.fromJson,
        cloud: cloud,
      );
      await store.upsert(_Item(id: '1', label: 'local-v1'));
      final exported = await store.exportRecords();

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await store.upsert(_Item(id: '1', label: 'local-v2-newer'));

      // Import the stale snapshot back in as a merge: the newer local edit
      // must still win.
      final result = await store.importRecords(exported, replace: false);
      expect(result.single.label, 'local-v2-newer');
    });

    test('merge adds items present only in the import', () async {
      final store = SyncedStore<_Item>(
        filePath: 'merge2.items.json',
        local: backend.local('merge2.items.json'),
        cloudKey: 'merge2',
        itemFromJson: _Item.fromJson,
        cloud: cloud,
      );
      await store.upsert(_Item(id: '1', label: 'one'));
      final imported = [
        Record<_Item>(item: _Item(id: '2', label: 'two'), order: 1, updatedAt: DateTime.now()),
      ];
      final result = await store.importRecords(imported, replace: false);
      expect(result.map((i) => i.id).toSet(), {'1', '2'});
    });

    test('replace tombstones every local live item and keeps only the imported items', () async {
      final store = SyncedStore<_Item>(
        filePath: 'replace.items.json',
        local: backend.local('replace.items.json'),
        cloudKey: 'replace',
        itemFromJson: _Item.fromJson,
        cloud: cloud,
      );
      await store.upsert(_Item(id: '1', label: 'old-1'));
      await store.upsert(_Item(id: '2', label: 'old-2'));

      final imported = [
        Record<_Item>(item: _Item(id: '3', label: 'restored-3'), order: 0, updatedAt: DateTime(2000)),
      ];
      final result = await store.importRecords(imported, replace: true);
      expect(result.map((i) => i.id).toSet(), {'3'});

      final exported = await store.exportRecords();
      final byId = {for (final r in exported) r.item.id: r};
      expect(byId['1']!.deleted, isTrue);
      expect(byId['2']!.deleted, isTrue);
      expect(byId['3']!.deleted, isFalse);
    });

    test('replace stamps everything with now so it beats an older edit already on another device', () async {
      final (deviceA, deviceB) = devices();
      await deviceA.upsert(_Item(id: '1', label: 'A-original'));
      final originalRecord = (await deviceA.exportRecords()).firstWhere((r) => r.item.id == '1');
      await deviceB.load();
      await Future<void>.delayed(const Duration(milliseconds: 5));

      // B does a full restore from an old backup, replacing its state.
      final backup = [
        Record<_Item>(item: _Item(id: '9', label: 'from-backup'), order: 0, updatedAt: DateTime(2000)),
      ];
      await deviceB.importRecords(backup, replace: true);

      // Even though the backup record itself carries an old (year-2000)
      // updatedAt, `importRecords` re-stamps it with now on write — so it's
      // newer than A's original edit, and will beat it once A syncs.
      final exportedB = await deviceB.exportRecords();
      final restoredRecord = exportedB.firstWhere((r) => r.item.id == '9');
      expect(restoredRecord.updatedAt.isAfter(originalRecord.updatedAt), isTrue);

      // Once A syncs, the restore's tombstone for item '1' wins over A's
      // untouched original (same reasoning: the tombstone is stamped now).
      final resultA = await deviceA.load();
      expect(resultA.map((i) => i.id), isNot(contains('1')));
      expect(resultA.map((i) => i.id), contains('9'));
    });
  });

  group('operations on one store', () {
    SyncedStore<_Item> store(String name) =>
        SyncedStore<_Item>(filePath: '$name.items.json', local: backend.local('$name.items.json'), cloudKey: name, itemFromJson: _Item.fromJson, cloud: cloud);

    test('a load that overlaps a save does not drop the saved item', () async {
      final s = store('race');
      cloud.slowReads = true;
      await s.upsert(_Item(id: 'seed', label: 'seed'));
      for (var i = 0; i < 30; i++) {
        await Future.wait(i.isEven ? [s.load(), s.upsert(_Item(id: 'n$i', label: 'saved'))] : [s.upsert(_Item(id: 'n$i', label: 'saved')), s.load()]);
      }
      // Read back through a store with no cloud copy, so only the local
      // records can answer; the cloud would put a dropped item back.
      final localOnly = SyncedStore<_Item>(
        filePath: 'race.items.json',
        local: backend.local('race.items.json'),
        cloudKey: 'other',
        itemFromJson: _Item.fromJson,
        cloud: _FakeCloudKVStore(),
      );
      final ids = (await localOnly.load()).map((i) => i.id).toSet();
      expect(ids, {'seed', for (var i = 0; i < 30; i++) 'n$i'});
    });

    test('saves that overlap all land', () async {
      final s = store('overlap');
      await Future.wait([for (var i = 0; i < 20; i++) s.upsert(_Item(id: 'n$i', label: 'v$i'))]);
      await Future.wait([s.delete('n0'), s.upsertAll([_Item(id: 'm', label: 'm')]), s.setOrder(['n3', 'n2'])]);
      final ids = (await s.load()).map((i) => i.id).toSet();
      expect(ids, {for (var i = 1; i < 20; i++) 'n$i', 'm'});
    });

    test('operations run in the order they were called', () async {
      final s = store('order');
      final results = await Future.wait([
        s.upsert(_Item(id: '1', label: 'one')),
        s.upsert(_Item(id: '2', label: 'two')),
        s.delete('1'),
        s.load(),
      ]);
      expect(results[0].map((i) => i.id), ['1']);
      expect(results[1].map((i) => i.id), ['1', '2']);
      expect(results[2].map((i) => i.id), ['2']);
      expect(results[3].map((i) => i.id), ['2']);
    });

    test('an operation that throws reaches its caller and does not stall the ones after it', () async {
      final s = store('fails');
      await s.upsert(_Item(id: '1', label: 'one'));
      cloud.failNextRead = true;
      final failing = s.upsert(_Item(id: '2', label: 'two'));
      final next = s.upsert(_Item(id: '3', label: 'three'));
      await expectLater(failing, throwsA(isA<StateError>()));
      expect((await next).map((i) => i.id), ['1', '3']);
      expect((await s.load()).map((i) => i.id), ['1', '3']);
    });
  });

  group('versioned cloud value', () {
    SyncedStore<_Item> store(String name, {CloudFormat format = CloudFormat.envelope}) => SyncedStore<_Item>(
          filePath: '$name.items.json',
          local: backend.local('$name.items.json'),
          cloudKey: 'k',
          itemFromJson: _Item.fromJson,
          cloud: cloud,
          cloudFormat: format,
        );

    String envelope(int version, String payload) =>
        jsonEncode({'v': version, 'z': 'gzip', 'data': base64Encode(GZipEncoder().encodeBytes(utf8.encode(payload)))});

    List<dynamic> openEnvelope(String raw) {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return jsonDecode(utf8.decode(GZipDecoder().decodeBytes(base64Decode(map['data'] as String)))) as List<dynamic>;
    }

    String recordJson(String id, String label, String at, {bool deleted = false}) =>
        jsonEncode({'item': {'id': id, 'label': label}, 'order': 0.0, 'updatedAt': at, 'deleted': deleted});

    test('writes {v, z, data} and reads it back on another device', () async {
      final a = store('a');
      await a.upsert(_Item(id: '1', label: 'one'));
      final map = jsonDecode((await cloud.getString('k'))!) as Map<String, dynamic>;
      expect(map.keys.toSet(), {'v', 'z', 'data'});
      expect(map['v'], 1);
      expect(map['z'], 'gzip');
      expect((openEnvelope(await cloud.getString('k') as String).single as Map)['item'], {'id': '1', 'label': 'one'});
      final b = store('b');
      expect((await b.load()).map((i) => i.label), ['one']);
      expect(b.cloudValueUnreadable, isFalse);
    });

    test('reads a plain list under the same key, and replaces it with the envelope on write', () async {
      await cloud.setString('k', '[${recordJson('1', 'old', '2024-01-01T00:00:00.000Z')}]');
      final s = store('plain');
      expect((await s.load()).map((i) => i.label), ['old']);
      expect(s.cloudValueUnreadable, isFalse);
      await s.upsert(_Item(id: '2', label: 'new'));
      final raw = (await cloud.getString('k'))!;
      expect(jsonDecode(raw), isA<Map>());
      expect(openEnvelope(raw), hasLength(2));
    });

    test('an empty or absent value is an empty cloud, not an unreadable one', () async {
      final s = store('empty');
      await s.load();
      expect(s.cloudValueUnreadable, isFalse);
      await cloud.setString('k', '');
      await s.load();
      expect(s.cloudValueUnreadable, isFalse);
    });

    for (final (name, value) in <(String, String)>[
      ('a newer version', envelope(2, '[]')),
      ('a newer version with another shape', jsonEncode({'v': 2, 'blob': 'x'})),
      ('garbage', 'not json at all'),
      ('bad base64', jsonEncode({'v': 1, 'z': 'gzip', 'data': '***'})),
      ('bytes that are not gzip', jsonEncode({'v': 1, 'z': 'gzip', 'data': base64Encode([1, 2, 3, 4])})),
      ('an unknown compression', jsonEncode({'v': 1, 'z': 'zstd', 'data': ''})),
      ('a payload that is not a record list', envelope(1, '{"a":1}')),
    ]) {
      test('$name is never overwritten; changes stay local', () async {
        await cloud.setString('k', value);
        final s = store('blocked');
        expect(await s.load(), isEmpty);
        expect(s.cloudValueUnreadable, isTrue);
        await s.upsert(_Item(id: '1', label: 'one'));
        await s.upsertAll([_Item(id: '2', label: 'two')]);
        await s.delete('1');
        await s.setOrder(['2']);
        await s.absorb([Record<_Item>(item: _Item(id: '3', label: 'three'), order: 5, updatedAt: DateTime.utc(2030))]);
        await s.insertMissing([Record<_Item>(item: _Item(id: '4', label: 'four'), order: 6, updatedAt: DateTime.utc(2030))]);
        await s.importRecords([], replace: false);
        expect(await cloud.getString('k'), value);
        expect((await s.load()).map((i) => i.id), ['2', '3', '4']);
        expect(await cloud.getString('k'), value);
        expect(s.cloudValueUnreadable, isTrue);
      });
    }

    test('the store writes again once a readable value arrives', () async {
      await cloud.setString('k', envelope(2, '[]'));
      final s = store('recovers');
      await s.upsert(_Item(id: '1', label: 'one'));
      expect(s.cloudValueUnreadable, isTrue);
      await cloud.setString('k', envelope(1, '[${recordJson('9', 'nine', '2024-01-01T00:00:00.000Z')}]'));
      expect((await s.load()).map((i) => i.id).toSet(), {'1', '9'});
      expect(s.cloudValueUnreadable, isFalse);
      expect(openEnvelope((await cloud.getString('k'))!), hasLength(2));
    });

    test('a default-format store writes the plain list, byte for byte', () async {
      final s = store('plainfmt', format: CloudFormat.plainList);
      await s.importRecords(
        [Record<_Item>(item: _Item(id: '1', label: 'one'), order: 0, updatedAt: DateTime.utc(2024, 1, 2, 3, 4, 5))],
        replace: false,
      );
      expect(
        await cloud.getString('k'),
        '[{"item":{"id":"1","label":"one"},"order":0.0,"updatedAt":"2024-01-02T03:04:05.000Z","deleted":false}]',
      );
      expect(s.cloudValueUnreadable, isFalse);
    });

    test('a default-format store does not treat an envelope as a reason to hold back (unchanged behaviour)', () async {
      await cloud.setString('k', envelope(2, '[]'));
      final s = store('legacy', format: CloudFormat.plainList);
      await s.upsert(_Item(id: '1', label: 'one'));
      expect(s.cloudValueUnreadable, isFalse);
      expect(jsonDecode((await cloud.getString('k'))!), isA<List>());
    });
  });

  group('absorb', () {
    SyncedStore<_Item> store(String name) =>
        SyncedStore<_Item>(filePath: '$name.items.json', local: backend.local('$name.items.json'), cloudKey: name, itemFromJson: _Item.fromJson, cloud: cloud);
    Record<_Item> rec(String id, String label, DateTime at, {bool deleted = false}) =>
        Record<_Item>(item: _Item(id: id, label: label), order: 3, updatedAt: at, deleted: deleted);

    test('takes unseen ids with their own metadata and reports a change', () async {
      final s = store('new');
      expect(await s.absorb([rec('1', 'one', DateTime.utc(2020))]), isTrue);
      final stored = (await s.exportRecords()).single;
      expect(stored.updatedAt, DateTime.utc(2020));
      expect(stored.order, 3);
      expect((await store('new').load()).map((i) => i.label), ['one']);
    });

    test('takes a strictly later stamp, ignores earlier and equal ones', () async {
      final s = store('stamps');
      await s.absorb([rec('1', 'base', DateTime.utc(2020, 6))]);
      expect(await s.absorb([rec('1', 'tie', DateTime.utc(2020, 6))]), isFalse);
      expect(await s.absorb([rec('1', 'older', DateTime.utc(2020, 5))]), isFalse);
      expect((await s.load()).single.label, 'base');
      expect(await s.absorb([rec('1', 'later', DateTime.utc(2020, 7))]), isTrue);
      expect((await s.load()).single.label, 'later');
    });

    test('a tombstone counts as seen: an equal or older copy does not revive it', () async {
      final s = store('tomb');
      final t = DateTime.now().toUtc().subtract(const Duration(days: 10));
      await s.absorb([rec('1', 'gone', t, deleted: true)]);
      expect(await s.absorb([rec('1', 'back', t)]), isFalse);
      expect(await s.absorb([rec('1', 'back', t.subtract(const Duration(days: 1)))]), isFalse);
      expect(await s.load(), isEmpty);
      expect(await s.absorb([rec('1', 'edited', t.add(const Duration(days: 1)))]), isTrue);
      expect((await s.load()).single.label, 'edited');
    });

    test('a locally deleted record is not revived by an older incoming copy', () async {
      final s = store('mine');
      await s.upsert(_Item(id: '1', label: 'one'));
      await s.delete('1');
      expect(await s.absorb([rec('1', 'old', DateTime.utc(2020))]), isFalse);
      expect(await s.load(), isEmpty);
    });

    test('an incoming tombstone later than a live record removes it', () async {
      final s = store('kill');
      final t = DateTime.now().toUtc().subtract(const Duration(days: 10));
      await s.absorb([rec('1', 'one', t)]);
      expect(await s.absorb([rec('1', 'one', t.add(const Duration(days: 1)), deleted: true)]), isTrue);
      expect(await s.load(), isEmpty);
    });

    test('within one batch the latest stamp for an id wins; empty and stale tombstone batches change nothing', () async {
      final s = store('batch');
      expect(await s.absorb([]), isFalse);
      expect(await s.absorb([rec('1', 'a', DateTime.utc(2020)), rec('1', 'b', DateTime.utc(2021)), rec('1', 'c', DateTime.utc(2019))]), isTrue);
      expect((await s.load()).single.label, 'b');
      expect(await s.absorb([rec('2', 'x', DateTime.utc(2001), deleted: true)]), isFalse);
    });

    test('concurrent absorb and upsert both land, in call order', () async {
      final s = store('conc');
      cloud.slowReads = true;
      final results = await Future.wait([
        s.absorb([rec('a', 'absorbed', DateTime.utc(2020))]),
        s.upsert(_Item(id: 'b', label: 'upserted')),
        s.absorb([rec('b', 'older than upsert', DateTime.utc(2020))]),
        s.upsert(_Item(id: 'a', label: 'edited after')),
      ]);
      expect(results[0], isTrue);
      expect(results[2], isFalse);
      final labels = {for (final i in await s.load()) i.id: i.label};
      expect(labels, {'a': 'edited after', 'b': 'upserted'});
    });

    test('the absorbed record reaches the cloud', () async {
      final s = store('cloudy');
      await s.absorb([rec('1', 'one', DateTime.utc(2020))]);
      final other = SyncedStore<_Item>(
          filePath: 'other.items.json', local: backend.local('other.items.json'), cloudKey: 'cloudy', itemFromJson: _Item.fromJson, cloud: cloud);
      expect((await other.load()).map((i) => i.label), ['one']);
    });
  });

  group('scoped replace', () {
    SyncedStore<_Item> store() =>
        SyncedStore<_Item>(filePath: 'scoped.items.json', local: backend.local('scoped.items.json'), cloudKey: 'scoped', itemFromJson: _Item.fromJson, cloud: cloud);
    bool isOld(Record<_Item> r) => r.item.label.startsWith('old');
    Record<_Item> rec(String id, String label) => Record<_Item>(item: _Item(id: id, label: label), order: 0, updatedAt: DateTime.utc(2020));

    test('only selected records are tombstoned or replaced; the rest keep their stamp', () async {
      final s = store();
      await s.upsertAll([_Item(id: '1', label: 'old-1'), _Item(id: '2', label: 'old-2'), _Item(id: '3', label: 'keep-3')]);
      final before = {for (final r in await s.exportRecords()) r.item.id: r};
      final now = DateTime.now().add(const Duration(days: 1));
      final result = await s.importRecords([rec('2', 'old-2b'), rec('9', 'old-9')], replace: true, now: now, replaceWhere: isOld);
      expect(result.map((i) => '${i.id}:${i.label}').toSet(), {'2:old-2b', '3:keep-3', '9:old-9'});
      final after = {for (final r in await s.exportRecords()) r.item.id: r};
      expect(after['1']!.deleted, isTrue);
      expect(after['3']!.updatedAt, before['3']!.updatedAt);
      expect(after['3']!.deleted, isFalse);
      expect(after['9']!.updatedAt.isAtSameMomentAs(now), isTrue);
    });

    test('imported records outside the selection are ignored, even over a stored record the selection does not cover', () async {
      final s = store();
      await s.upsertAll([_Item(id: '3', label: 'keep-3')]);
      await s.importRecords([rec('3', 'old-3-overwrite'), rec('7', 'keep-7')], replace: true, replaceWhere: isOld);
      expect((await s.load()).map((i) => '${i.id}:${i.label}'), ['3:keep-3']);
    });

    test('without a predicate replace behaves as before', () async {
      final s = store();
      await s.upsertAll([_Item(id: '1', label: 'old-1'), _Item(id: '3', label: 'keep-3')]);
      await s.importRecords([rec('9', 'new')], replace: true);
      expect((await s.load()).map((i) => i.id), ['9']);
    });

    test('the predicate does not affect a merge import', () async {
      final s = store();
      await s.upsertAll([_Item(id: '3', label: 'keep-3')]);
      await s.importRecords([rec('7', 'keep-7')], replace: false, replaceWhere: isOld);
      expect((await s.load()).map((i) => i.id).toSet(), {'3', '7'});
    });
  });

  group('tie-breaking, tombstone lifetime, and frozen keys', () {
    SyncedStore<_Item> store(String name,
            {String key = 'tie',
            bool Function(Record<_Item>, Record<_Item>)? prefer,
            Duration? ttl = SyncedStore.defaultTombstoneTTL,
            List<_Item> Function()? seed,
            CloudFormat format = CloudFormat.plainList}) =>
        SyncedStore<_Item>(
          filePath: '$name.items.json',
          local: backend.local('$name.items.json'),
          cloudKey: key,
          itemFromJson: _Item.fromJson,
          cloud: cloud,
          prefer: prefer,
          tombstoneTTL: ttl,
          seed: seed,
          cloudFormat: format,
        );
    final t = DateTime.utc(2030, 1, 1);
    Record<_Item> rec(String id, String label, DateTime at, {bool deleted = false}) =>
        Record<_Item>(item: _Item(id: id, label: label), order: 0, updatedAt: at, deleted: deleted);
    bool higherLabel(Record<_Item> a, Record<_Item> b) => a.item.label.compareTo(b.item.label) > 0;

    Future<String> cloudLabel(String key) async {
      final list = jsonDecode((await cloud.getString(key))!) as List<dynamic>;
      return ((list.single as Map)['item'] as Map)['label'] as String;
    }

    for (final (localLabel, cloudLabelAtStart) in [('c', 'b'), ('a', 'b')]) {
      test('prefer decides an equal-stamp tie whichever side holds the winner (local $localLabel, cloud $cloudLabelAtStart)', () async {
        final key = 'tie-$localLabel';
        await backend.overwrite('p-$localLabel.items.json', [rec('1', localLabel, t)]);
        await cloud.setString(key, jsonEncode([rec('1', cloudLabelAtStart, t).toJson()]));
        final s = store('p-$localLabel', key: key, prefer: higherLabel);
        expect((await s.load()).single.label, 'c'.compareTo(localLabel) == 0 ? 'c' : 'b');
        // The winner is what the cloud holds afterwards, also when it was the local copy.
        expect(await cloudLabel(key), localLabel == 'c' ? 'c' : 'b');
        expect(s.keyed([rec('1', 'a', t), rec('1', 'z', t), rec('1', 'm', t)]).values.single.item.label, 'z');
        expect(s.keyed([rec('1', 'z', t), rec('1', 'a', t)]).values.single.item.label, 'z');
      });
    }

    test('without prefer a tie goes to the later record, as before', () async {
      final s = store('noprefer');
      expect(s.keyed([rec('1', 'z', t), rec('1', 'a', t)]).values.single.item.label, 'a');
      expect(s.keyed([rec('1', 'a', t), rec('1', 'z', t)]).values.single.item.label, 'z');
    });

    test('absorb takes an equal-stamp record only when prefer says so', () async {
      final s = store('abs', prefer: higherLabel);
      await s.absorb([rec('1', 'm', t)]);
      expect(await s.absorb([rec('1', 'a', t)]), isFalse);
      expect(await s.absorb([rec('1', 'm', t)]), isFalse);
      expect(await s.absorb([rec('1', 'z', t)]), isTrue);
      expect((await s.load()).single.label, 'z');
      expect(await cloudLabel('tie'), 'z');
      final plain = store('abs2', key: 'tie2');
      await plain.absorb([rec('1', 'm', t)]);
      expect(await plain.absorb([rec('1', 'z', t)]), isFalse);
    });

    test('a tombstone older than the default lifetime is pruned; with a null lifetime it is kept and absorbed', () async {
      final old = DateTime.utc(2001);
      final plain = store('ttl-default', key: 'ttl-a');
      expect(await plain.absorb([rec('1', 'gone', old, deleted: true)]), isFalse);

      final keep = store('ttl-null', key: 'ttl-b', ttl: null);
      expect(await keep.absorb([rec('1', 'gone', old, deleted: true)]), isTrue);
      expect((await keep.exportRecords()).single.deleted, isTrue);
      // Seen, so an older live copy from the old key does not bring it back.
      expect(await keep.absorb([rec('1', 'back', DateTime.utc(2000))]), isFalse);
      await keep.load();
      expect((await keep.exportRecords()).single.deleted, isTrue);
      expect(await keep.load(), isEmpty);
    });

    test('an unreadable value does not trigger the seed', () async {
      await cloud.setString('frozen-seed', jsonEncode({'v': 2}));
      final s = store('seeded', key: 'frozen-seed', format: CloudFormat.envelope, seed: () => [_Item(id: 's', label: 'seed')]);
      expect(await s.load(), isEmpty);
      expect(s.cloudValueUnreadable, isTrue);
      expect(jsonDecode((await cloud.getString('frozen-seed'))!), {'v': 2});
      // A readable, empty cloud still seeds.
      final fresh = store('seeded2', key: 'fresh-seed', format: CloudFormat.envelope, seed: () => [_Item(id: 's', label: 'seed')]);
      expect((await fresh.load()).map((i) => i.id), ['s']);
    });

    test('one record that fails itemFromJson freezes the key, observably', () async {
      final good = store('writer', key: 'bad', format: CloudFormat.envelope);
      await good.upsert(_Item(id: '1', label: 'one'));
      final before = (await cloud.getString('bad'))!;
      final strict = SyncedStore<_Item>(
        filePath: 'strict.items.json',
        local: backend.local('strict.items.json'),
        cloudKey: 'bad',
        itemFromJson: (json) => json['id'] == '1' ? throw const FormatException('shape this build does not know') : _Item.fromJson(json),
        cloud: cloud,
        cloudFormat: CloudFormat.envelope,
      );
      await strict.load();
      expect(strict.cloudValueUnreadable, isTrue);
      await strict.upsert(_Item(id: '2', label: 'two'));
      expect(await cloud.getString('bad'), before);
      expect((await strict.load()).map((i) => i.id), ['2']);
    });

    test('a scoped replace leaves a record that exists only in the cloud, outside the selection, alone', () async {
      final other = store('other-device', key: 'scope');
      await other.upsertAll([_Item(id: 'k', label: 'keep-k'), _Item(id: 'o', label: 'old-o')]);
      final s = store('this-device', key: 'scope');
      bool isOld(Record<_Item> r) => r.item.label.startsWith('old');
      final result = await s.importRecords([rec('k', 'old-overwrite', t), rec('n', 'old-n', t)], replace: true, replaceWhere: isOld);
      expect(result.map((i) => '${i.id}:${i.label}').toSet(), {'k:keep-k', 'n:old-n'});
      // The selected cloud-only record is tombstoned too.
      final records = {for (final r in await s.exportRecords()) r.item.id: r};
      expect(records['o']!.deleted, isTrue);
      expect(records['k']!.deleted, isFalse);
    });
  });

  group('a store that is full', () {
    const methodChannel = MethodChannel('qima/cloud_kv');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late Map<String, String> remote;
    late SwitchableCloudKVStore switchable;
    late int quotaEvents;
    late StreamSubscription<CloudKVChangeEvent> sub;

    setUp(() {
      remote = {};
      quotaEvents = 0;
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'getString':
            return remote[(call.arguments as Map)['key'] as String];
          case 'setString':
            final args = call.arguments as Map;
            remote[args['key'] as String] = args['value'] as String;
            return null;
          case 'synchronize':
          case 'accountStatus':
            return true;
        }
        return null;
      });
      switchable = SwitchableCloudKVStore();
      sub = switchable.didChangeExternally.listen((e) {
        if (e.reason == CloudKVChangeReason.quotaViolationChange) quotaEvents++;
      });
      switchable.setEnabled(true);
    });

    tearDown(() async {
      await sub.cancel();
      await switchable.dispose();
      messenger.setMockMethodCallHandler(methodChannel, null);
    });

    SyncedStore<_Item> store() => SyncedStore<_Item>(
        filePath: 'full.items.json', local: backend.local('full.items.json'), cloudKey: 'full', itemFromJson: _Item.fromJson, cloud: switchable);

    test('a skipped write is reported once, not retried while nothing changes, and clears when a write goes through', () async {
      await switchable.setString('other', 'x' * 400000);
      final s = store();
      expect(s.cloudWriteSkipped, isFalse);
      await s.upsert(_Item(id: '1', label: 'y' * 120000));
      await pumpEventQueue();
      expect(s.cloudWriteSkipped, isTrue);
      expect(remote.containsKey('full'), isFalse);
      expect(quotaEvents, 1);

      await s.load();
      await s.load();
      await pumpEventQueue();
      expect(quotaEvents, 1);
      expect(s.cloudWriteSkipped, isTrue);
      // The record is still there locally.
      expect((await s.load()).single.id, '1');

      // Room is made and the records change: the write goes through.
      await switchable.setString('other', 'x');
      await s.upsert(_Item(id: '2', label: 'small'));
      expect(s.cloudWriteSkipped, isFalse);
      expect(remote.containsKey('full'), isTrue);
    });

    test('a skipped write is retried by the next load once another key has shrunk', () async {
      await switchable.setString('other', 'x' * 400000);
      final s = store();
      await s.upsert(_Item(id: '1', label: 'y' * 120000));
      await pumpEventQueue();
      expect(s.cloudWriteSkipped, isTrue);
      expect(quotaEvents, 1);

      await switchable.setString('other', 'x');
      await s.load();
      expect(s.cloudWriteSkipped, isFalse);
      expect(remote.containsKey('full'), isTrue);
      expect(quotaEvents, 1);
    });

    test('a shrink that frees too little is tried once, and loads after it do not report again', () async {
      await switchable.setString('other', 'x' * 400000);
      final s = store();
      await s.upsert(_Item(id: '1', label: 'y' * 120000));
      await pumpEventQueue();
      expect(s.cloudWriteSkipped, isTrue);
      expect(quotaEvents, 1);

      await switchable.setString('other', 'x' * 380000);
      await s.load();
      await pumpEventQueue();
      expect(s.cloudWriteSkipped, isTrue);
      expect(quotaEvents, 2, reason: 'the shrink was a reason to try again');

      await s.load();
      await s.load();
      await pumpEventQueue();
      expect(quotaEvents, 2, reason: 'nothing changed since that try');

      await switchable.setString('other', 'x');
      await s.load();
      expect(s.cloudWriteSkipped, isFalse);
    });

    test('a plain fake cloud never reports a skip', () async {
      final s = SyncedStore<_Item>(
          filePath: 'plain.items.json', local: backend.local('plain.items.json'), cloudKey: 'plain', itemFromJson: _Item.fromJson, cloud: cloud);
      await s.upsert(_Item(id: '1', label: 'one'));
      expect(s.cloudWriteSkipped, isFalse);
    });
  });
}
