import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qima/services/book_db/book_database.dart';
import 'package:qima/services/sync/cloudkit_sync_transport.dart';
import 'package:qima/services/sync/sync_report.dart';
import 'package:qima/services/sync/sync_transport.dart';
import 'package:qima/services/sync/sync_wire.dart';

import 'sync_support.dart';

const _a1 = SyncBatchRef(writer: 'w', device: 'aa', prev: 0, last: 3);
const _a2 = SyncBatchRef(writer: 'w', device: 'aa', prev: 3, last: 8, part: 1, parts: 2);
const _a2b = SyncBatchRef(writer: 'w', device: 'aa', prev: 3, last: 8, part: 2, parts: 2);
const _b1 = SyncBatchRef(writer: 'w', device: 'bb', prev: 0, last: 2);
const _snapshot = SyncSnapshotRef(writer: 'w', device: 'aa', seq: 8);

/// The other side of the channel, behaving as `CloudSyncPlugin.swift` is
/// meant to: text under names per kind, a name that is taken keeps its body,
/// and a record that is gone already is no error for a discard.
class FakeCloud {
  final Map<String, Map<String, String>> records = {'batch': {}, 'snapshot': {}};

  /// Record names in the zone that are not ours.
  final List<String> others = [];

  /// Whether a listing gives every name twice.
  bool twice = false;

  /// The error every call but `available` answers with, when set.
  PlatformException? failure;
  bool signedIn = true;

  /// The calls that came in, as `method` or `method kind`.
  final List<String> calls = [];

  /// What the last `discard` was asked to remove.
  Map<String, List<String>> discarded = {};

  Future<Object?> handle(MethodCall call) async {
    final arguments = (call.arguments as Map<Object?, Object?>?) ?? const {};
    calls.add([call.method, if (arguments['kind'] != null) arguments['kind']].join(' '));
    if (call.method == 'available') return signedIn;
    if (failure != null) throw failure!;
    switch (call.method) {
      case 'store':
        return records[arguments['kind']]!.putIfAbsent(arguments['name']! as String, () => arguments['body']! as String) == arguments['body'];
      case 'read':
        return records[arguments['kind']]![arguments['name']];
      case 'list':
        return {
          for (final kind in records.keys) kind: [...records[kind]!.keys, if (twice) ...records[kind]!.keys],
          'other': others,
        };
      case 'discard':
        discarded = {for (final kind in records.keys) kind: (arguments[kind]! as List<Object?>).cast<String>()};
        for (final kind in records.keys) {
          discarded[kind]!.forEach(records[kind]!.remove);
        }
        return null;
    }
    throw MissingPluginException();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('qima/cloud_sync');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late FakeCloud cloud;
  late CloudKitSyncTransport remote;

  setUp(() {
    cloud = FakeCloud();
    messenger.setMockMethodCallHandler(channel, cloud.handle);
    remote = CloudKitSyncTransport();
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  List<String> names(String kind) => cloud.records[kind]!.keys.toList()..sort();

  group('as a store of batches and snapshots', () {
    test('an empty zone lists nothing, reads nothing, and a discard there asks for nothing', () async {
      final listing = await remote.list(after: const {});
      expect(listing.batches, isEmpty);
      expect(listing.snapshots, isEmpty);
      expect(listing.problems, isEmpty);
      expect(await remote.read(_a1), isNull);
      expect(await remote.readSnapshot(_snapshot), isNull);
      await remote.discard(batchesThrough: const {'aa': 9}, snapshots: const []);
      await remote.discard(batchesThrough: const {}, snapshots: const []);
      expect(cloud.calls, ['list', 'read batch', 'read snapshot', 'list'], reason: 'nothing to remove is not worth a call, and no places means no listing');

      expect(await remote.append(_a1, 'one'), isTrue);
      expect(names('batch'), ['aa.w.0.3.1.1']);
    });

    test('a listing names what is beyond the reader\'s places, and a body is read by its name', () async {
      await remote.append(_a1, 'one');
      await remote.append(_a2, 'two');
      await remote.append(_a2b, 'two more');
      await remote.append(_b1, 'three');
      await remote.writeSnapshot(_snapshot, 'all');

      final all = await remote.list(after: const {});
      expect(all.batches.toSet(), {_a1, _a2, _a2b, _b1});
      expect(all.snapshots, [_snapshot]);
      expect(all.problems, isEmpty);
      expect((await remote.list(after: const {'aa': 3, 'bb': 2})).batches.toSet(), {_a2, _a2b});
      expect(await remote.read(_a2b), 'two more');
      expect(await remote.readSnapshot(_snapshot), 'all');
      expect(await remote.read(const SyncBatchRef(writer: 'w', device: 'aa', prev: 8, last: 9)), isNull);
    });

    test('a name that is there keeps its body, and the answer says whether it is the one given', () async {
      expect(await remote.append(_a1, 'first'), isTrue);
      expect(await remote.append(_a1, 'first'), isTrue);
      expect(await remote.append(_a1, 'second'), isFalse);
      expect(await remote.read(_a1), 'first');
      expect(await remote.writeSnapshot(_snapshot, 'whole'), isTrue);
      expect(await remote.writeSnapshot(_snapshot, 'whole'), isTrue);
      expect(await remote.writeSnapshot(_snapshot, 'other'), isFalse);
      expect(await remote.readSnapshot(_snapshot), 'whole');
      expect(names('batch'), ['aa.w.0.3.1.1']);
      expect(names('snapshot'), ['aa.w.8.1.1']);
    });

    test('a batch and a snapshot are told apart by their kind, whatever their names', () async {
      await remote.append(_a1, 'a batch');
      await remote.writeSnapshot(_snapshot, 'a snapshot');
      expect(cloud.calls, ['store batch', 'store snapshot']);
      cloud.records['snapshot']!['aa.w.0.3.1.1'] = 'not the batch';
      expect(await remote.read(_a1), 'a batch');
    });

    test('a listing may name things twice, and each is handed on', () async {
      await remote.append(_a1, 'one');
      await remote.writeSnapshot(_snapshot, 'all');
      cloud.twice = true;
      final listing = await remote.list(after: const {});
      expect(listing.batches, [_a1, _a1]);
      expect(listing.snapshots, [_snapshot, _snapshot]);
    });

    test('discard removes the batches up to the places it is given and the snapshots it names, and nothing else', () async {
      await remote.append(_a1, 'one');
      await remote.append(_a2, 'two');
      await remote.append(_a2b, 'two more');
      await remote.append(_b1, 'three');
      await remote.writeSnapshot(_snapshot, 'old');
      await remote.writeSnapshot(const SyncSnapshotRef(writer: 'w', device: 'bb', seq: 2), 'kept');
      cloud.others.add('notes');

      await remote.discard(batchesThrough: const {'aa': 3}, snapshots: const [_snapshot, SyncSnapshotRef(writer: 'w', device: 'cc', seq: 1)]);
      expect(names('batch'), ['aa.w.3.8.1.2', 'aa.w.3.8.2.2', 'bb.w.0.2.1.1']);
      expect(names('snapshot'), ['bb.w.2.1.1']);
      expect(cloud.discarded, {
        'batch': ['aa.w.0.3.1.1'],
        'snapshot': ['aa.w.8.1.1', 'cc.w.1.1.1'],
      });

      cloud.twice = true;
      await remote.discard(batchesThrough: const {'aa': 8, 'bb': 2}, snapshots: const []);
      expect(names('batch'), isEmpty);
      expect(cloud.discarded['batch'], hasLength(3), reason: 'a name listed twice is asked for once');
      expect(names('snapshot'), ['bb.w.2.1.1']);
    });

    test('snapshots are removed by name alone, without a listing', () async {
      await remote.writeSnapshot(_snapshot, 'old');
      cloud.calls.clear();
      await remote.discard(batchesThrough: const {}, snapshots: const [_snapshot]);
      expect(cloud.calls, ['discard']);
      expect(names('snapshot'), isEmpty);
    });

    test('records that are not ours, and ones that only look like ours, are reported and never handed over or removed', () async {
      await remote.append(_a1, 'one');
      const strayBatches = ['aa.w.9.4.1.1', 'AA.w.1.2.1.1', 'aa.w.00.07.1.1', 'aa.w.5.7.01.1', 'aa.w.5.7', 'aa.5.7.1.1', 'aa.w.0.3.1.1 2'];
      const straySnapshots = ['aa.w', 'aa.w.08.1.1', 'aa.8.1.1'];
      for (final name in strayBatches) {
        cloud.records['batch']![name] = 'x';
      }
      for (final name in straySnapshots) {
        cloud.records['snapshot']![name] = 'x';
      }
      cloud.others.addAll(['readme', 'batch.aa.w.0.9.1.1']);

      final listing = await remote.list(after: const {});
      expect(listing.batches, [_a1]);
      expect(listing.snapshots, isEmpty);
      expect(listing.problems, hasLength(strayBatches.length + straySnapshots.length + 2));
      final problems = listing.problems.join('\n');
      for (final name in strayBatches) {
        expect(problems, contains('batch.$name is not named like a batch'));
      }
      for (final name in straySnapshots) {
        expect(problems, contains('snapshot.$name is not named like a snapshot'));
      }
      expect(problems, contains('readme is not one of ours'));

      await remote.discard(batchesThrough: const {'aa': 99}, snapshots: const []);
      expect(names('batch'), [...strayBatches]..sort(), reason: 'what could not be named is not removed either');
      expect(names('snapshot'), [...straySnapshots]..sort());
    });
  });

  group('when a call does not go through', () {
    test('available passes on what the plugin says', () async {
      expect(await remote.available(), isTrue);
      cloud.signedIn = false;
      expect(await remote.available(), isFalse);
    });

    test('every error code of the plugin is thrown as its own failure, by every call, and never becomes an answer', () async {
      const codes = {
        'unavailable': CloudSyncFailure.unavailable,
        'not_signed_in': CloudSyncFailure.notSignedIn,
        'network': CloudSyncFailure.network,
        'quota': CloudSyncFailure.quota,
        'zone_missing': CloudSyncFailure.zoneMissing,
        'other': CloudSyncFailure.other,
        'bad_args': CloudSyncFailure.other,
        'something new': CloudSyncFailure.other,
      };
      await remote.append(_a1, 'one');
      final calls = <String, Future<Object?> Function()>{
        'append': () => remote.append(_a1, 'one'),
        'writeSnapshot': () => remote.writeSnapshot(_snapshot, 'all'),
        'read': () => remote.read(_a1),
        'readSnapshot': () => remote.readSnapshot(_snapshot),
        'list': () => remote.list(after: const {}),
        'discard by places': () => remote.discard(batchesThrough: const {'aa': 3}, snapshots: const []),
        'discard by name': () => remote.discard(batchesThrough: const {}, snapshots: const [_snapshot]),
      };
      for (final MapEntry(key: code, value: failure) in codes.entries) {
        cloud.failure = PlatformException(code: code, message: 'the words of $code');
        for (final MapEntry(key: name, value: call) in calls.entries) {
          await expectLater(
            call,
            throwsA(isA<CloudSyncException>().having((e) => e.failure, 'failure', failure).having((e) => e.message, 'message', 'the words of $code')),
            reason: '$name with $code',
          );
        }
      }
      cloud.failure = null;
      expect(names('batch'), ['aa.w.0.3.1.1'], reason: 'a discard whose listing failed removed nothing');
      expect(await remote.read(_a1), 'one');
    });

    test('how long iCloud asked to be left alone is passed on', () async {
      cloud.failure = PlatformException(code: 'network', message: 'busy', details: {'retryAfter': 2.5});
      await expectLater(() => remote.list(after: const {}), throwsA(isA<CloudSyncException>().having((e) => e.retryAfter, 'retryAfter', const Duration(milliseconds: 2500))));
      cloud.failure = PlatformException(code: 'network', message: 'offline');
      await expectLater(() => remote.list(after: const {}), throwsA(isA<CloudSyncException>().having((e) => e.retryAfter, 'retryAfter', isNull)));
    });

    test('a store that gets no answer is a failure, not a name that is taken', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      await expectLater(() => remote.append(_a1, 'one'), throwsA(isA<CloudSyncException>().having((e) => e.failure, 'failure', CloudSyncFailure.other)));
      await expectLater(() => remote.list(after: const {}), throwsA(isA<CloudSyncException>()));
    });

    test('where there is no plugin, available is false and every call says the platform is not supported', () async {
      messenger.setMockMethodCallHandler(channel, null);
      final unsupported = throwsA(isA<CloudSyncException>().having((e) => e.failure, 'failure', CloudSyncFailure.unsupported));
      expect(await remote.available(), isFalse);
      await expectLater(() => remote.append(_a1, 'one'), unsupported);
      await expectLater(() => remote.writeSnapshot(_snapshot, 'all'), unsupported);
      await expectLater(() => remote.read(_a1), unsupported);
      await expectLater(() => remote.readSnapshot(_snapshot), unsupported);
      await expectLater(() => remote.list(after: const {}), unsupported);
      await expectLater(() => remote.discard(batchesThrough: const {'aa': 3}, snapshots: const [_snapshot]), unsupported);

      // It is not asked again: a plugin does not appear while the app runs.
      messenger.setMockMethodCallHandler(channel, cloud.handle);
      expect(await remote.available(), isFalse);
      expect(cloud.calls, isEmpty);
      expect(await CloudKitSyncTransport().available(), isTrue);
    });
  });

  group('under the engine', () {
    late Directory root;

    setUp(() async => root = await Directory.systemTemp.createTemp('qima_sync_cloudkit'));

    tearDown(() async {
      await BookDatabase.closeAll();
      BookDatabase.executorOverride = null;
      await root.delete(recursive: true);
    });

    test('devices that save, sync and compact through the channel end with the same book', () async {
      final a = await Device.open(root, 'a', remote);
      final b = await Device.open(root, 'b', remote);
      await a.putAccount(rec(account('cash', 'Cash'), 1));
      await a.putEntry(rec(spend('fromA', 100), 2));
      await b.putEntry(rec(spend('fromB', 200), 3));
      await settle([a, b]);
      expect(await b.state(), await a.state());

      await a.putEntry(rec(spend('fromA', 150), 4));
      await b.putEntry(rec(spend('gone', 50), 5));
      await b.putEntry(rec(spend('gone', 50), 6, deleted: true));
      final compaction = await a.engine.compact();
      expect(compaction.refused, isFalse);
      expect(names('snapshot'), contains(compaction.snapshot!.name));
      await settle([a, b]);
      await b.engine.compact();

      final c = await Device.open(root, 'c', CloudKitSyncTransport());
      await settle([a, b, c]);
      expect(await c.state(), await a.state());
      expect(await b.state(), await a.state());
      expect((await c.storedEntries()).where((r) => !r.deleted).map((r) => r.item.id).toSet(), {'fromA', 'fromB'});
    });

    test('a round that fails changes nothing, and the next one carries on from what is there', () async {
      final a = await Device.open(root, 'a', remote);
      final b = await Device.open(root, 'b', remote);
      await a.putEntry(rec(spend('s1', 100), 1));
      cloud.failure = PlatformException(code: 'network', message: 'offline');
      await expectLater(() => a.engine.sync(), throwsA(isA<CloudSyncException>()));
      await expectLater(() => b.engine.sync(), throwsA(isA<CloudSyncException>()));
      expect(names('batch'), isEmpty);

      cloud.failure = null;
      await settle([a, b]);
      expect(names('batch'), hasLength(1), reason: 'the batch went out once, under its first name');
      expect(await b.state(), await a.state());
    });

    test('a book in parts goes through the channel whole, and a damaged body is reported and read again once it is whole', () async {
      final a = await Device.open(root, 'a', remote, partBytes: 800);
      for (var i = 0; i < 12; i++) {
        await a.putEntry(rec(spend('s$i', 100 + i), 1 + i, order: i.toDouble()));
      }
      await a.engine.sync();
      expect(names('batch').length, greaterThan(2));

      final damaged = names('batch').first;
      final whole = cloud.records['batch']![damaged]!;
      cloud.records['batch']![damaged] = whole.substring(0, whole.length ~/ 2);
      expect(() => SyncWire.decode(cloud.records['batch']![damaged]!), throwsFormatException);
      final b = await Device.open(root, 'b', remote, partBytes: 800);
      final round = await b.engine.sync();
      expect(round.pull.problems.single.kind, SyncProblemKind.unreadable);
      expect(round.quiet, isFalse);
      expect(cloud.records['batch']![damaged], hasLength(whole.length ~/ 2), reason: 'the record is left as it was found');

      cloud.records['batch']![damaged] = whole;
      await settle([a, b]);
      expect(await b.state(), await a.state());

      await a.engine.compact();
      expect(names('snapshot').length, greaterThan(2));
      final c = await Device.open(root, 'c', remote, partBytes: 800);
      await settle([a, b, c]);
      expect(await c.state(), await a.state());
    });
  });
}
