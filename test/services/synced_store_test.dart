import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/syncable.dart';
import 'package:qima/services/book_db/book_database.dart';
import 'package:qima/services/book_db/db_records.dart';
import 'package:qima/services/cloud_kv_store.dart';
import 'package:qima/services/local_file_store.dart';
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
    (filePath, records) => DocumentRecords<_Item>(collection: filePath, filePath: filePath, itemFromJson: _Item.fromJson).write(records),
  ),
];

void main() {
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
}
