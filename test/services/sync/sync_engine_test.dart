import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/book_account.dart';
import 'package:qima/models/book_entry.dart';
import 'package:qima/services/book_db/book_database.dart';
import 'package:qima/services/book_db/db_records.dart';
import 'package:qima/services/book_store.dart';
import 'package:qima/services/cloud_kv_store.dart';
import 'package:qima/services/sync/sync_engine.dart';
import 'package:qima/services/sync/sync_report.dart';
import 'package:qima/services/sync/sync_transport.dart';
import 'package:qima/services/sync/sync_wire.dart';
import 'package:qima/services/synced_store.dart';

import 'memory_sync_transport.dart';
import 'sync_support.dart';

/// The ids a stored batch part carries, as `collection/id`.
List<String> idsIn(MemorySyncTransport remote, SyncBatchRef ref) => [
      for (final op in SyncBatch.read(ref, remote.batches[ref]!).ops) '${op.collection}/${(op.record['item'] as Map<String, dynamic>)['id']}',
    ]..sort();

/// A body as a later build would write it.
String fromALaterBuild() => jsonEncode({'v': SyncWire.version + 1, 'z': 'zstd', 'data': 'AAAA'});

/// A transport on which the first snapshot part written arrives damaged:
/// the name then holds other text than it was given.
class _DamagingFirstSnapshot extends MemorySyncTransport {
  SyncSnapshotRef? damaged;

  @override
  Future<bool> writeSnapshot(SyncSnapshotRef ref, String body) async {
    if (damaged != null) return super.writeSnapshot(ref, body);
    damaged = ref;
    snapshots[ref] = 'half a sn';
    return false;
  }
}

/// A transport whose listings never name a snapshot.
class _HidingSnapshots extends MemorySyncTransport {
  @override
  Future<SyncListing> list({required Map<String, int> after}) async => SyncListing(batches: (await super.list(after: after)).batches);
}

/// A transport that holds a damaged body under every name.
class _Refusing extends MemorySyncTransport {
  int appends = 0;

  @override
  Future<bool> append(SyncBatchRef ref, String body) async {
    appends++;
    return false;
  }

  @override
  Future<String?> read(SyncBatchRef ref) async => 'damaged';
}

/// The three devices of [life], in the order they join.
typedef Lives = ({Device a, Device b, Device c});

void main() {
  late Directory root;
  late MemorySyncTransport remote;
  late Device a;
  late Device b;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('qima_sync_engine');
    remote = MemorySyncTransport();
    a = await Device.open(root, 'a', remote);
    b = await Device.open(root, 'b', remote);
  });

  tearDown(() async {
    await BookDatabase.closeAll();
    BookDatabase.executorOverride = null;
    await root.delete(recursive: true);
  });

  List<SyncBatchRef> batchesOf(String device, [MemorySyncTransport? on]) =>
      [for (final ref in (on ?? remote).batches.keys) if (ref.device == device) ref]..sort((x, y) => x.last != y.last ? x.last.compareTo(y.last) : x.part.compareTo(y.part));

  group('sending and taking in', () {
    test('a change reaches the other device, and a later round sends only what changed since', () async {
      await a.putEntry(rec(spend('s1', 100), 1));
      await a.putEntry(rec(spend('s2', 200), 2, order: 1));
      await a.putAccount(rec(account('bank', 'Bank'), 1));
      expect((await a.engine.sync()).push.sent, 3);
      expect((await b.engine.sync()).pull.applied, 3);
      expect(await b.state(), await a.state());

      await a.putEntry(rec(spend('s2', 250), 3, order: 1));
      expect((await a.engine.sync()).push.sent, 1);
      final sent = batchesOf('a');
      expect(sent, hasLength(2));
      expect(idsIn(remote, sent.last), ['ledger.entries/s2']);
      expect(sent.last.prev, sent.first.last, reason: 'each batch starts where the one before ended');

      await b.engine.sync();
      expect(await b.state(), await a.state());
      expect((await b.storedEntries()).singleWhere((r) => r.item.id == 's2').item.lines.first.amount, -250);
    });

    test('a deletion travels as a tombstone and wins over the older live record', () async {
      await a.putEntry(rec(spend('s1', 100), 1));
      await settle([a, b]);
      await b.putEntry(rec(spend('s1', 100), 2, deleted: true));
      await settle([a, b]);
      expect((await a.storedEntries()).single.deleted, isTrue);
      expect(await a.state(), await b.state());
    });

    test('several changes to one record between rounds go out as its one current state', () async {
      for (var i = 1; i <= 5; i++) {
        await a.putEntry(rec(spend('s1', 100 * i), i));
      }
      expect((await a.engine.sync()).push.sent, 1);
      await b.engine.sync();
      expect((await b.storedEntries()).single.item.lines.first.amount, -500);
    });

    test('a round with nothing new stores nothing and moves nothing', () async {
      await a.putEntry(rec(spend('s1', 100), 1));
      await settle([a, b]);
      final stored = remote.batches.length;
      final logA = await a.log();
      final logB = await b.log();
      expect((await a.engine.sync()).quiet, isTrue);
      expect((await b.engine.sync()).quiet, isTrue);
      expect(remote.batches, hasLength(stored));
      expect(await a.log(), logA);
      expect(await b.log(), logB);
    });

    test('the device id is made once, of letters and digits, and survives a restart', () async {
      final made = await Device.open(root, 'made', remote, id: null);
      final other = await Device.open(root, 'other', remote, id: null);
      final id = await made.engine.deviceId();
      expect(isDeviceId(id), isTrue);
      expect(id, hasLength(32));
      made.restart();
      expect(await made.engine.deviceId(), id);
      expect(await other.engine.deviceId(), isNot(id));
    });

    test('only the rows a round names are read from the book', () async {
      for (var i = 0; i < 40; i++) {
        await a.putEntry(rec(spend('s$i', 100 + i), 1, order: i.toDouble()));
      }
      await settle([a, b]);
      await a.putEntry(rec(spend('s7', 999), 5, order: 7));

      final selects = <String>[];
      final watched = EntryRecords.forTesting(collection: BookStore.entriesKey, filePath: 'book.entries.json', itemFromJson: (json) {
        selects.add(json['id'] as String);
        return BookEntry.fromJson(json);
      }, prefer: book.entries.prefer);
      SyncEngine watching(Device device) => SyncEngine(
            remote: 'main',
            transport: remote,
            database: () async => device.db,
            collections: [SyncCollection<BookAccount>.of(book.accounts, accountRows()), SyncCollection<BookEntry>.of(book.entries, watched)],
          );
      await watching(a).sync();
      expect(selects.toSet(), {'s7'}, reason: 'sending one record reads one row');
      selects.clear();
      await watching(b).sync();
      expect(selects.where((id) => id != 's7'), isEmpty, reason: 'taking one record in reads one row');
      expect(await b.state(), await a.state());
    });
  });

  group('parts', () {
    test('a batch too large for one body goes out in parts, and a reader uses it once all are there', () async {
      final big = await Device.open(root, 'big', remote, partBytes: 700);
      for (var i = 0; i < 9; i++) {
        await big.putEntry(rec(spend('s$i', 100 + i), 1 + i, order: i.toDouble()));
      }
      expect((await big.engine.sync()).push.sent, 9);
      final parts = batchesOf('big');
      expect(parts.length, greaterThan(2));
      expect(parts.map((ref) => ref.parts).toSet(), {parts.length});
      expect(parts.map((ref) => ref.part), [for (var i = 1; i <= parts.length; i++) i]);
      for (final ref in parts) {
        expect(SyncBatch(ref, SyncBatch.read(ref, remote.batches[ref]!).ops).body.length, lessThan(2500), reason: 'no body holds the whole batch');
      }

      remote.delayed.add(parts[1]);
      final early = await b.engine.sync();
      expect(early.pull.incomplete, [parts.first]);
      expect(early.pull.waiting, isEmpty);
      expect(early.pull.applied, 0);
      expect(await b.meta('sync.in.main'), isNull, reason: 'the place does not move for part of a batch');

      remote.delayed.clear();
      expect((await b.engine.sync()).pull.applied, 9);
      expect(await b.state(), await big.state());
    });

    test('a part that cannot be read holds its batch back and the others are read again with it', () async {
      final big = await Device.open(root, 'big', remote, partBytes: 700);
      for (var i = 0; i < 6; i++) {
        await big.putEntry(rec(spend('s$i', 100 + i), 1 + i, order: i.toDouble()));
      }
      await big.engine.sync();
      final parts = batchesOf('big');
      final whole = remote.batches[parts.last]!;
      remote.batches[parts.last] = whole.substring(0, whole.length ~/ 2);

      final round = await b.engine.sync();
      expect(round.pull.problems.single.kind, SyncProblemKind.unreadable);
      expect(await b.meta('sync.in.main'), isNull);

      remote.batches[parts.last] = whole;
      await settle([b, big]);
      expect(await b.state(), await big.state());
    });

    test('a snapshot goes out in parts too, and a new device takes all of them in', () async {
      final big = await Device.open(root, 'big', remote, partBytes: 700);
      for (var i = 0; i < 9; i++) {
        await big.putEntry(rec(spend('s$i', 100 + i), 1 + i, order: i.toDouble()));
        await big.engine.sync();
      }
      final snapshot = (await big.engine.compact()).snapshot!;
      expect(snapshot.parts, greaterThan(2));
      expect(remote.snapshots.keys.map((ref) => ref.name).toSet(), {for (var i = 1; i <= snapshot.parts; i++) snapshot.partAt(i).name});

      final fresh = await Device.open(root, 'fresh', remote);
      await settle([fresh, big]);
      expect(await fresh.state(), await big.state());

      // A snapshot of which a part has not arrived is not used at all.
      final late = await Device.open(root, 'late', remote);
      final held = remote.snapshots.remove(snapshot.partAt(2))!;
      final round = await late.engine.sync();
      expect(round.pull.waiting, isNotEmpty);
      expect(await late.meta('sync.in.main'), isNull);
      remote.snapshots[snapshot.partAt(2)] = held;
      await settle([late, big]);
      expect(await late.state(), await big.state());
    });

    test('a batch stored again by the same engine has the same name and text, and by a later one a name of its own', () async {
      await a.putEntry(rec(spend('s1', 100), 1));
      remote.onStep = (name) async {
        if (name == 'append.done') throw const SyncTransportFailure('append.done');
      };
      await expectLater(a.engine.push(), throwsA(isA<SyncTransportFailure>()));
      remote.onStep = null;
      final stored = Map.of(remote.batches);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect((await a.engine.push()).sent, 1);
      expect(remote.batches, stored, reason: 'the same engine found its own batch there, to the letter');

      // After a restart the stretch that was not acknowledged goes out again
      // under the new engine's name, and a reader takes both.
      await a.putEntry(rec(spend('s2', 200), 2));
      remote.onStep = (name) async {
        if (name == 'append.done') throw const SyncTransportFailure('append.done');
      };
      await expectLater(a.engine.push(), throwsA(isA<SyncTransportFailure>()));
      remote.onStep = null;
      a.restart();
      expect((await a.engine.push()).sent, 1);
      final twice = batchesOf('a').where((ref) => ref.prev == stored.keys.single.last).toList();
      expect(twice, hasLength(2));
      expect(twice.map((ref) => ref.writer).toSet(), hasLength(2));
      expect(remote.batches[twice[0]]!.length, remote.batches[twice[1]]!.length);
      await settle([a, b]);
      expect(await b.state(), await a.state());
      expect(await a.engine.deviceId(), 'a', reason: 'its own earlier batch is not taken for another device\'s');
    });
  });

  group('what was taken in is not sent back', () {
    test('a device that only received sends nothing, and the sender hears nothing of it', () async {
      await a.putEntry(rec(spend('s1', 100), 1));
      await a.putAccount(rec(account('bank', 'Bank'), 1));
      await a.engine.sync();

      final round = await b.engine.sync();
      expect(round.pull.applied, 2);
      expect(round.push.sent, 0);
      expect(batchesOf('b'), isEmpty, reason: 'b changed nothing of its own');
      expect((await b.log()).where((row) => row.contains(':sync:')), hasLength(2), reason: 'the rows are logged as taken from the remote');

      final back = await a.engine.sync();
      expect(back.pull.applied, 0);
      expect(back.quiet, isTrue);
      expect((await b.engine.sync()).quiet, isTrue);
    });

    test('what a device held before it joined goes out once, and what it took in while joining does not', () async {
      await a.putEntry(rec(spend('fromA', 100), 1));
      await a.engine.sync();
      await b.putEntry(rec(spend('fromB', 200), 2));

      await b.engine.sync();
      expect(idsIn(remote, batchesOf('b').single), ['ledger.entries/fromB']);
      await settle([a, b]);
      expect(await a.state(), await b.state());
      expect(batchesOf('a'), hasLength(1));
      expect(batchesOf('b'), hasLength(1));
    });

    test('a device that holds the newer of two versions sends nothing when the older one arrives', () async {
      await a.putEntry(rec(spend('s1', 100), 5));
      await b.putEntry(rec(spend('s1', 200), 9));
      await b.engine.sync();
      await a.engine.sync();
      final sent = batchesOf('b').length;
      final round = await b.engine.sync();
      expect(round.pull.applied, 0);
      expect(round.push.sent, 0);
      expect(batchesOf('b'), hasLength(sent));
      expect(await a.state(), await b.state());
    });

    test('with two remotes, what came from one is passed on to the other and not back', () async {
      final second = MemorySyncTransport();
      final c = await Device.open(root, 'c', second, remote: 'second');
      final bridge = b.newEngine(transport: second, remote: 'second');

      await a.putEntry(rec(spend('s1', 100), 1));
      await a.engine.sync();
      await b.engine.sync();
      expect(batchesOf('b'), isEmpty);

      await bridge.sync();
      await c.engine.sync();
      expect(await c.state(), await a.state());
      expect((await b.engine.sync()).push.sent, 0, reason: 'nothing goes back to where it came from');

      await c.putEntry(rec(spend('s2', 200), 2));
      await c.engine.sync();
      await bridge.sync();
      await b.engine.sync();
      await a.engine.sync();
      expect(await a.state(), await c.state());
    });
  });

  group('delivery', () {
    test('a batch that arrives before an earlier one waits, and both are applied when the earlier one comes', () async {
      await a.putEntry(rec(spend('s1', 100), 1));
      await a.engine.sync();
      await a.putEntry(rec(spend('s2', 200), 2));
      await a.engine.sync();
      final sent = batchesOf('a');
      remote.delayed.add(sent.first);

      final early = await b.engine.sync();
      expect(early.pull.applied, 0);
      expect(early.pull.waiting, [sent.last]);
      expect(early.quiet, isFalse, reason: 'a device that waits for a batch is not at rest');
      expect(await b.storedEntries(), isEmpty, reason: 'nothing of a batch is applied past a gap');

      remote.delayed.clear();
      expect((await b.engine.pull()).applied, 2);
      expect(await b.state(), await a.state());
    });

    test('batches delivered again change nothing and are not answered', () async {
      await a.putEntry(rec(spend('s1', 100), 1));
      await a.putEntry(rec(spend('s2', 200), 2));
      await settle([a, b]);
      final state = await b.state();
      final log = await b.log();
      final place = await b.meta('sync.in.main');

      remote.replay = true;
      for (var i = 0; i < 3; i++) {
        final round = await b.engine.sync();
        expect(round.quiet, isTrue);
      }
      expect(await b.state(), state);
      expect(await b.log(), log);
      expect(await b.meta('sync.in.main'), place);
    });

    test('an old batch replayed after newer ones does not bring the old record back', () async {
      await a.putEntry(rec(spend('s1', 100), 1));
      await a.engine.sync();
      final first = batchesOf('a').single;
      final old = remote.batches[first]!;
      await a.putEntry(rec(spend('s1', 999), 5));
      await settle([a, b]);

      // The same old records as a batch b has not seen, from a third device.
      const again = SyncBatchRef(writer: 'w', device: 'z', prev: 0, last: 4);
      remote.batches[again] = SyncBatch(again, SyncBatch.read(first, old).ops).body;
      final pulled = await b.engine.pull();
      expect(pulled.applied, 0);
      expect((await b.storedEntries()).single.item.lines.first.amount, -999);
    });

    test('whatever order three devices hear of the same three versions in, they keep the same one', () async {
      final c = await Device.open(root, 'c', remote);
      await a.putEntry(rec(spend('s1', 100), 3));
      await b.putEntry(rec(spend('s1', 200), 7));
      await c.putEntry(rec(spend('s1', 300), 5));
      await c.engine.sync();
      await a.engine.sync();
      await b.engine.sync();
      await settle([b, c, a]);
      for (final device in [a, b, c]) {
        expect((await device.storedEntries()).single.item.lines.first.amount, -200);
      }
    });
  });

  group('the rule is the one key-value sync uses', () {
    test('equal stamps on an entry are decided by LegacyCollapse.prefer, on every device alike', () async {
      final fromLater = rec(trade('t1', 500, tradeMs: 9, cashMs: 4), 10);
      final fromEarlier = rec(trade('t1', 700, tradeMs: 3, cashMs: 4), 10);
      await a.putEntry(fromEarlier);
      await b.putEntry(fromLater);
      await settle([a, b]);
      final expected = show(book.entries.merge([fromEarlier], [fromLater]));
      expect(show(await a.storedEntries()), expected);
      expect(show(await b.storedEntries()), expected);
      expect((await a.storedEntries()).single.item.lines.first.amount, -500);
    });

    test('equal stamps on a document are decided by the store\'s own merge, on both devices alike', () async {
      final one = rec(account('bank', 'Bank A'), 10);
      final other = rec(account('bank', 'Bank B'), 10);
      await a.putAccount(one);
      await b.putAccount(other);
      await settle([a, b]);
      expect(await a.state(), await b.state());
      expect(show(await a.storedAccounts()), show(book.accounts.merge([one], [other])));
      expect(show(book.accounts.merge([one], [other])), show(book.accounts.merge([other], [one])), reason: 'the merge does not depend on which comes first');
    });

    test('a collection whose merge depends on the order of arrival, or whose rows are not held to its rule, is refused', () {
      final bare = SyncedStore<BookAccount>(filePath: 'x.json', cloudKey: 'x', itemFromJson: BookAccount.fromJson, cloud: LocalOnlyCloudKVStore());
      expect(() => SyncCollection<BookAccount>.of(bare, accountRows()), throwsArgumentError);
      final loose = DocumentRecords<BookAccount>(collection: BookStore.accountsKey, filePath: 'book.accounts.json', itemFromJson: BookAccount.fromJson);
      expect(() => SyncCollection<BookAccount>.of(book.accounts, loose), throwsArgumentError);
    });
  });

  group('a device never keeps a record that loses to the one it held', () {
    test('a save with an older stamp than the record held is not stored, logged or sent', () async {
      await a.putEntry(rec(spend('x', 100), 10));
      await a.engine.sync();
      final log = await a.log();
      await a.putEntry(rec(spend('x', 555), 5));
      expect((await a.storedEntries()).single.item.lines.first.amount, -100);
      expect(await a.log(), log);
      expect((await a.engine.sync()).push.sent, 0);
      await settle([b, a]);
      expect(await a.state(), await b.state());
    });

    test('a save with the same stamp is stored only if it wins the tie', () async {
      final loses = rec(trade('t', 700, tradeMs: 3), 10);
      final wins = rec(trade('t', 500, tradeMs: 9), 10);
      await a.putEntry(wins);
      await a.putEntry(loses);
      expect(show(await a.storedEntries()), show([wins]));
      await b.putEntry(loses);
      await b.putEntry(wins);
      expect(show(await b.storedEntries()), show([wins]));
    });

    test('three devices with clocks that disagree and a compaction end with one book', () async {
      await a.engine.sync();
      await b.putEntry(rec(spend('x', 100), 10));
      await b.engine.sync();
      await a.engine.sync();
      await a.putEntry(rec(spend('x', 555), 5));
      await a.engine.sync();
      await a.putEntry(rec(spend('y', 1), 6));
      await a.engine.sync();
      final c = await Device.open(root, 'c', remote);
      await c.engine.sync();
      await c.engine.compact();
      await settle([b, a, c]);
      expect({await a.state(), await b.state(), await c.state()}, hasLength(1));
    });

    test('the device that wrote the newer record never syncs again, and the others still agree', () async {
      await a.engine.sync();
      await b.putEntry(rec(spend('x', 100), 10));
      await b.engine.sync();
      await a.engine.sync();
      await a.putEntry(rec(spend('x', 555), 5));
      await a.engine.sync();
      final c = await Device.open(root, 'c', remote);
      await settle([a, c]);
      expect(await a.state(), await c.state());
      expect((await c.storedEntries()).single.item.lines.first.amount, -100);
    });
  });

  group('a stop between any two steps', () {
    /// The whole life of three devices: edits, rounds, compactions and a late
    /// joiner. Each call that the transport fails is made again by a new
    /// engine, as after a restart.
    Future<Lives> life(Directory dir, MemorySyncTransport remote) async {
      Future<void> again(Device device, Future<Object?> Function(SyncEngine engine) run) async {
        for (var tries = 0; tries < 3; tries++) {
          try {
            await run(device.engine);
            return;
          } on SyncTransportFailure {
            device.restart();
          }
        }
        fail('the call failed three times');
      }

      final a = await Device.open(dir, 'a', remote, partBytes: 900);
      final b = await Device.open(dir, 'b', remote, partBytes: 900);
      await a.putEntry(rec(spend('s1', 100), 1));
      await a.putAccount(rec(account('bank', 'Bank'), 1));
      await again(a, (e) => e.sync());
      await b.putEntry(rec(spend('s2', 200), 2));
      await again(b, (e) => e.sync());
      await a.putEntry(rec(spend('s1', 150), 3));
      await a.putEntry(rec(spend('s4', 400), 3));
      await a.putEntry(rec(spend('s5', 500), 3));
      await again(a, (e) => e.sync());
      await again(b, (e) => e.sync());
      await again(a, (e) => e.compact());
      await b.putEntry(rec(spend('s2', 200), 4, deleted: true));
      await again(b, (e) => e.sync());
      await again(b, (e) => e.compact());
      final c = await Device.open(dir, 'c', remote, partBytes: 900);
      await c.putEntry(rec(spend('s3', 300), 5));
      await again(c, (e) => e.sync());
      await again(a, (e) => e.sync());
      await again(c, (e) => e.compact());
      await again(a, (e) => e.compact());
      return (a: a, b: b, c: c);
    }

    final expectedEntries = show(book.entries.merge(const [], [
      rec(spend('s1', 100), 1),
      rec(spend('s2', 200), 2),
      rec(spend('s1', 150), 3),
      rec(spend('s4', 400), 3),
      rec(spend('s5', 500), 3),
      rec(spend('s2', 200), 4, deleted: true),
      rec(spend('s3', 300), 5),
    ]));

    const steps = ['append', 'append.done', 'list', 'read', 'readSnapshot', 'writeSnapshot', 'writeSnapshot.done', 'discard', 'discard.done'];

    for (final step in steps) {
      test('at $step, every time it comes, ends where an undisturbed run ends', () async {
        var times = 0;
        final clean = MemorySyncTransport()
          ..onStep = (name) async {
            if (name == step) times++;
          };
        await life(Directory('${root.path}/clean'), clean);
        expect(times, greaterThan(2), reason: 'the script meets the step');

        for (var nth = 1; nth <= times; nth++) {
          var seen = 0;
          var stopped = false;
          final remote = MemorySyncTransport()
            ..onStep = (name) async {
              if (name == step && ++seen == nth) {
                stopped = true;
                throw SyncTransportFailure(name);
              }
            };
          final lives = await life(Directory('${root.path}/$nth'), remote);
          expect(stopped, isTrue, reason: 'time $nth');
          remote.onStep = null;
          final devices = [lives.a, lives.b, lives.c];
          await settle(devices);
          for (final device in devices) {
            expect(show(await device.storedEntries()), expectedEntries, reason: '${device.name}, time $nth');
            expect((await device.storedAccounts()).single.item.name, 'Bank', reason: '${device.name}, time $nth');
            expect(await device.engine.deviceId(), device.name, reason: 'a stop is not taken for another writer, time $nth');
          }
          final fresh = await Device.open(Directory('${root.path}/$nth'), 'fresh', remote);
          await settle([fresh, ...devices]);
          expect(show(await fresh.storedEntries()), expectedEntries, reason: 'a device that joins afterwards, time $nth');
        }
      });
    }

    test('a batch stored but not acknowledged is sent again from the same place, and read as one', () async {
      await a.putEntry(rec(spend('s1', 100), 1));
      remote.onStep = (name) async {
        if (name == 'append.done') throw const SyncTransportFailure('append.done');
      };
      await expectLater(a.engine.push(), throwsA(isA<SyncTransportFailure>()));
      remote.onStep = null;
      a.restart();
      await a.putEntry(rec(spend('s2', 200), 2));
      expect((await a.engine.push()).sent, 2, reason: 'the place did not move, so the first record goes again');
      final sent = batchesOf('a');
      expect(sent, hasLength(2));
      expect(sent.map((ref) => ref.prev).toSet(), {0});

      expect((await b.engine.pull()).applied, 2);
      expect(await b.state(), await a.state());
      await a.putEntry(rec(spend('s3', 300), 3));
      await settle([a, b]);
      expect(await b.state(), await a.state());
    });
  });

  group('a later build', () {
    test('a batch in a newer format is refused, left as it is, and holds back what follows it', () async {
      await a.putEntry(rec(spend('s1', 100), 1));
      await a.engine.sync();
      await a.putEntry(rec(spend('s2', 200), 2));
      await a.engine.sync();
      await b.putEntry(rec(spend('mine', 5), 1));
      final sent = batchesOf('a');
      final real = remote.batches[sent.first]!;
      remote.batches[sent.first] = fromALaterBuild();

      final round = await b.engine.sync();
      expect(round.pull.needsUpdate, isTrue);
      expect(round.pull.problems.single.kind, SyncProblemKind.newerVersion);
      expect(round.pull.waiting, sent);
      expect(round.pull.applied, 0);
      expect(round.quiet, isFalse);
      expect((await b.storedEntries()).map((r) => r.item.id), ['mine'], reason: 'b keeps its own data and takes nothing half read');
      expect(round.push.sent, 1, reason: 'b still sends its own changes, which removes nothing');
      expect(remote.batches[sent.first], fromALaterBuild());

      final compaction = await b.engine.compact();
      expect(compaction.refused, isTrue);
      expect(compaction.snapshot, isNull);
      expect(remote.snapshots, isEmpty);
      expect(remote.batches.keys, containsAll(sent));
      expect(await b.meta('sync.in.main'), isNull, reason: 'the place has not moved past what was not read');

      // The update arrives: the same engine reads what it could not.
      remote.batches[sent.first] = real;
      await settle([a, b]);
      expect(await b.state(), await a.state());
    });

    test('a snapshot in a newer format is refused and never removed, whoever compacts and however often', () async {
      await a.putEntry(rec(spend('s1', 100), 1));
      await a.engine.sync();
      const newer = SyncSnapshotRef(writer: 'w', device: 'a', seq: 999);
      remote.snapshots[newer] = fromALaterBuild();

      for (final device in [b, a, b]) {
        final compaction = await device.engine.compact();
        expect(compaction.refused, isTrue);
        expect(compaction.round.pull.problems.map((p) => p.kind), [SyncProblemKind.newerVersion], reason: 'it is reported for as long as it is there');
        device.restart();
      }
      expect(remote.snapshots.keys, [newer]);
      expect(remote.snapshots[newer], fromALaterBuild());
      expect(await b.state(), await a.state(), reason: 'the batches b can read are still taken in');
    });

    test('a newer snapshot beside a readable one of the same device stays when the readable one is replaced', () async {
      await a.putEntry(rec(spend('s1', 100), 1));
      await a.engine.sync();
      final snapshot = (await a.engine.compact()).snapshot!;
      final newer = SyncSnapshotRef(writer: 'w', device: 'a', seq: snapshot.seq - 1);
      remote.snapshots[newer] = fromALaterBuild();
      // b holds a newer version of the record than the snapshot does.
      await b.putEntry(rec(spend('s1', 222), 9));

      expect((await b.engine.compact()).refused, isTrue);
      b.restart();
      expect((await b.engine.compact()).refused, isTrue, reason: 'a new engine finds it again');
      expect(remote.snapshots.keys, containsAll([snapshot, newer]));

      // Once it is gone b compacts, and removes only what it has read.
      final kept = remote.snapshots.remove(newer)!;
      final done = await b.engine.compact();
      expect(done.refused, isFalse);
      remote.snapshots[newer] = kept;
      b.restart();
      expect((await b.engine.compact()).refused, isTrue);
      expect(remote.snapshots.keys, containsAll([newer, done.snapshot]));
      expect(remote.snapshots[newer], fromALaterBuild());
    });

    test('a batch that is damaged, has a record this build cannot read, or names a collection it does not have is reported and waits', () async {
      await a.putEntry(rec(spend('s1', 100), 1));
      await a.engine.sync();
      final ref = batchesOf('a').single;
      final real = remote.batches[ref]!;
      final bodies = {
        'cut short': real.substring(0, real.length ~/ 2),
        'not ours': 'hello',
        'another batch under this name': SyncBatch(const SyncBatchRef(writer: 'w', device: 'a', prev: 7, last: 9), const []).body,
        'another part under this name': SyncBatch(ref.partAt(2), const []).body,
        'a record without an item': SyncBatch(ref, [const SyncOp(BookStore.entriesKey, {'order': 0, 'updatedAt': '2026-05-01T10:00:00.000Z'})]).body,
        'an unknown collection': SyncBatch(ref, [SyncOp('ledger.budgets', rec(spend('x', 1), 1).toJson())]).body,
      };
      for (final MapEntry(key: what, value: body) in bodies.entries) {
        remote.batches[ref] = body;
        final pulled = await b.engine.pull();
        expect(pulled.problems.single.kind, SyncProblemKind.unreadable, reason: what);
        expect(pulled.needsUpdate, isFalse, reason: what);
        expect(pulled.waiting, [ref], reason: what);
        expect(await b.storedEntries(), isEmpty, reason: what);
        expect(await b.meta('sync.in.main'), isNull, reason: what);
      }
      remote.batches[ref] = real;
      expect((await b.engine.pull()).applied, 1);
    });
  });

  group('the wire', () {
    test('a small body that unpacks to more than this build reads is refused before it is unpacked whole', () {
      // A batch that is whole and well formed, with padding that packs to
      // almost nothing.
      const ref = SyncBatchRef(writer: 'w', device: 'aa', prev: 0, last: 1);
      List<int> payload(int padding) => [...utf8.encode('{"device":"aa","prev":0,"last":1,"part":1,"parts":1,"ops":[],"pad":"'), ...Uint8List(padding)..fillRange(0, padding, 0x30), ...utf8.encode('"}')];
      String body(int padding) => jsonEncode({'v': 1, 'z': 'gzip', 'data': base64Encode(gzip.encode(payload(padding)))});
      expect(SyncBatch.read(ref, body(1024)).ops, isEmpty);
      final large = body(SyncWire.maxPayloadBytes);
      expect(large.length, lessThan(100 * 1024));
      expect(() => SyncBatch.read(ref, large), throwsFormatException);
      expect(() => SyncWire.decode('x' * (SyncWire.maxBodyBytes + 1)), throwsFormatException);
    });

    test('a body cut short anywhere is damage, never a shorter batch', () {
      const ref = SyncBatchRef(writer: 'w', device: 'aa', prev: 0, last: 1);
      final body = SyncBatch(ref, [for (var i = 0; i < 50; i++) SyncOp(BookStore.entriesKey, rec(spend('s$i', i), i).toJson())]).body;
      expect(SyncBatch.read(ref, body).ops, hasLength(50));
      for (var cut = 1; cut < body.length; cut += 37) {
        expect(() => SyncBatch.read(ref, body.substring(0, cut)), throwsFormatException, reason: 'cut at $cut');
      }
    });

    test('names have one spelling, and anything else is not a name', () {
      const batch = SyncBatchRef(writer: 'w9', device: 'ab12', prev: 3, last: 8, part: 2, parts: 3);
      expect(batch.name, 'ab12.w9.3.8.2.3');
      expect(SyncBatchRef.parse(batch.name), batch);
      const snapshot = SyncSnapshotRef(writer: 'w9', device: 'ab12', seq: 0, part: 1, parts: 1);
      expect(snapshot.name, 'ab12.w9.0.1.1');
      expect(SyncSnapshotRef.parse(snapshot.name), snapshot);
      const notBatches = [
        'ab12.w9.03.8.2.3',
        'ab12.w9.3.08.2.3',
        'ab12.w9.3.8.2.03',
        'ab12.w9.3.8.02.3',
        'AB.w9.3.8.1.1',
        'ab12.W9.3.8.1.1',
        'ab12.w9.8.3.1.1',
        'ab12.w9.3.8.4.3',
        'ab12.w9.3.8.0.3',
        'ab12.w9.3.8.1',
        'ab12.3.8.1.1',
        'ab12.w9.-3.8.1.1',
        'ab12.w9.3.8.1.1.1',
        'a b.w9.3.8.1.1',
        'ab12..3.8.1.1',
      ];
      for (final name in notBatches) {
        expect(SyncBatchRef.parse(name), isNull, reason: name);
      }
      for (final name in ['ab12.w9.00.1.1', 'ab12.w9.5.01.1', 'ab12.w9.5.2.1', 'ab12.w9.5.0.1', 'ab12.w9.5.1', 'ab12.5.1.1', 'Ab.w9.5.1.1']) {
        expect(SyncSnapshotRef.parse(name), isNull, reason: name);
      }
    });

    test('records are split into parts of about the size asked for, in order, and never into none', () {
      final ops = [for (var i = 0; i < 20; i++) SyncOp(BookStore.entriesKey, rec(spend('s$i', i), i).toJson())];
      final one = jsonEncode(ops.first.toJson()).length;
      final parts = SyncWire.split(ops, partBytes: one * 3 + 10);
      expect(parts.expand((p) => p), ops);
      expect(parts.every((p) => p.isNotEmpty && p.length <= 3), isTrue);
      expect(SyncWire.split(ops, partBytes: 1).map((p) => p.length), everyElement(1), reason: 'a record larger than a part is a part alone');
      expect(SyncWire.split(const []), [isEmpty]);
    });
  });

  group('snapshots and trimming', () {
    Future<void> history() async {
      for (var i = 0; i < 6; i++) {
        await a.putEntry(rec(spend('a$i', 100 + i), 10 + i, order: i.toDouble()));
        await a.engine.sync();
        await b.putEntry(rec(spend('b$i', 200 + i), 10 + i, order: i.toDouble()));
        if (i.isEven) await b.putEntry(rec(spend('a$i', 100 + i), 30 + i, deleted: true));
        await b.engine.sync();
      }
      await b.putAccount(rec(account('bank', 'Bank'), 1));
      await settle([a, b]);
    }

    test('a new device that starts from a snapshot holds what one that replayed every batch holds', () async {
      await history();
      final replayed = await Device.open(root, 'replayed', remote);
      await replayed.engine.sync();
      expect(await replayed.state(), await a.state());

      final before = remote.batches.length;
      final compaction = await a.engine.compact();
      expect(compaction.refused, isFalse);
      expect(remote.snapshots.keys, [compaction.snapshot]);
      expect(remote.batches.length, lessThan(before));
      expect(remote.batches.length, 2, reason: 'the newest batch of each device stays, to show a late reader the gap');

      final fresh = await Device.open(root, 'fresh', remote);
      final joined = await fresh.engine.sync();
      expect(joined.pull.waiting, isEmpty);
      expect(await fresh.state(), await replayed.state());

      await a.putEntry(rec(spend('after', 1), 99));
      await settle([a, b, fresh, replayed]);
      expect(await fresh.state(), await a.state());
      expect(await replayed.state(), await a.state());
    });

    test('a device that was behind when the log was trimmed catches up from the snapshot', () async {
      await a.putEntry(rec(spend('s1', 100), 1));
      await settle([a, b]);
      for (var i = 0; i < 4; i++) {
        await a.putEntry(rec(spend('late$i', 10 + i), 20 + i));
        await a.engine.sync();
      }
      await a.engine.compact();
      expect(batchesOf('a'), hasLength(1));

      final caught = await b.engine.sync();
      expect(caught.pull.waiting, isEmpty);
      expect(await b.state(), await a.state());
    });

    test('a compaction with nothing new writes nothing, and one with something replaces the device\'s own', () async {
      await history();
      final first = (await a.engine.compact()).snapshot!;
      final stored = Map.of(remote.snapshots);
      expect((await a.engine.compact()).snapshot, first);
      expect(remote.snapshots, stored);

      await a.putEntry(rec(spend('more', 1), 99));
      final second = (await a.engine.compact()).snapshot!;
      expect(second, isNot(first));
      expect(remote.snapshots.keys, [second]);
    });

    test('a device removes another\'s snapshot only if it has taken it in, comes later in the order, and its own is there', () async {
      await history();
      final ofA = (await a.engine.compact()).snapshot!;
      // b comes after a: it replaces a's snapshot with its own.
      await b.putEntry(rec(spend('more', 1), 99));
      final ofB = (await b.engine.compact()).snapshot!;
      expect(remote.snapshots.keys, [ofB]);

      // a comes before b: it writes its own and leaves b's.
      await a.putEntry(rec(spend('again', 1), 100));
      final next = (await a.engine.compact()).snapshot!;
      expect(next, isNot(ofA));
      expect(remote.snapshots.keys.toSet(), {ofB, next});

      // b's own snapshot is not there (its write is lost on the way): it
      // removes nothing, though it has taken a's in.
      await b.putEntry(rec(spend('third', 1), 101));
      remote.onStep = (name) async {
        if (name == 'writeSnapshot.done') remote.snapshots.removeWhere((ref, _) => ref.device == 'b' && ref != ofB);
      };
      await b.engine.compact();
      remote.onStep = null;
      expect(remote.snapshots.keys.toSet(), {ofB, next});

      final fresh = await Device.open(root, 'fresh', remote);
      await settle([a, b, fresh]);
      expect(await fresh.state(), await b.state());
      expect(await a.state(), await b.state());
    });

    test('compactions in turn with nothing new never leave the remote without a snapshot', () async {
      for (var i = 0; i < 3; i++) {
        await a.putEntry(rec(spend('a$i', 100 + i), 10 + i));
        await a.engine.sync();
        await b.putEntry(rec(spend('b$i', 200 + i), 10 + i));
        await b.engine.sync();
      }
      await settle([a, b]);

      for (final order in [[b, a, b], [a, b, a], [b, b, a, a, b, a]]) {
        for (final device in order) {
          final written = remote.snapshots.length;
          await device.engine.compact();
          expect(remote.snapshots, isNotEmpty, reason: 'after ${device.name} of ${order.map((d) => d.name)}');
          expect(remote.snapshots.length, lessThanOrEqualTo(written + 1));
        }
      }
      final stored = Map.of(remote.snapshots);
      await a.engine.compact();
      await b.engine.compact();
      expect(remote.snapshots, stored, reason: 'with nothing new, nothing is written or removed');

      final fresh = await Device.open(root, 'fresh', remote);
      final joined = await fresh.engine.sync();
      expect(joined.pull.waiting, isEmpty);
      await settle([a, b, fresh]);
      expect(await fresh.state(), await a.state());
    });

    test('two devices that compact at the same moment do not remove each other\'s snapshot', () async {
      await history();
      // Each ends with a snapshot there that says all it has to say, and has
      // taken the other's in: compactions that are stopped before they
      // remove anything, until neither has anything new to write.
      remote.onStep = (name) async {
        if (name == 'discard') throw const SyncTransportFailure('discard');
      };
      for (var i = 0; i < 3; i++) {
        for (final device in [a, b]) {
          await expectLater(device.engine.compact(), throwsA(isA<SyncTransportFailure>()));
          device.restart();
        }
      }
      expect(remote.snapshots.keys.map((ref) => ref.device).toSet(), {'a', 'b'});

      // Now both compact, and neither removes anything before the other has
      // come as far as removing too.
      final bothReady = Completer<void>();
      var ready = 0;
      var written = 0;
      remote.onStep = (name) async {
        if (name == 'writeSnapshot') written++;
        if (name != 'discard') return;
        if (++ready == 2) bothReady.complete();
        await bothReady.future;
      };
      await Future.wait([a.engine.compact(), b.engine.compact()]).timeout(const Duration(seconds: 20));
      remote.onStep = null;
      expect(ready, 2, reason: 'the two compactions did overlap');
      expect(written, 0, reason: 'and each took its own snapshot to be standing');
      expect(remote.snapshots.keys.map((ref) => ref.device).toSet(), {'b'}, reason: 'the later device in the order keeps its snapshot, and replaces the other\'s');

      final fresh = await Device.open(root, 'fresh', remote);
      await settle([a, b, fresh]);
      expect(await fresh.state(), await a.state());
      expect(await b.state(), await a.state());
    });

    test('a remote that has lost every snapshot gets one again from a device with nothing new', () async {
      await history();
      final first = (await a.engine.compact()).snapshot!;
      remote.snapshots.clear();
      final again = (await a.engine.compact()).snapshot!;
      expect(again, isNot(first));
      expect(remote.snapshots.keys, [again]);
      final fresh = await Device.open(root, 'fresh', remote);
      await settle([a, b, fresh]);
      expect(await fresh.state(), await a.state());
    });

    test('a snapshot that says it covers more of a device than the remote shows is believed only that far', () async {
      await a.putEntry(rec(spend('one', 1), 1));
      await settle([a, b]);
      const bad = SyncSnapshotRef(writer: 'w', device: 'zz', seq: 1);
      remote.snapshots[bad] = SyncSnapshot(bad, const {'a': 999999999999}, const []).body;
      await b.engine.compact();
      final place = (jsonDecode((await b.meta('sync.in.main'))!) as Map<String, dynamic>)['batches'] as Map<String, dynamic>;
      expect((place['a'] as List<dynamic>)[1], batchesOf('a').last.last, reason: 'b stands where the batches of a end, not where the snapshot says');

      // Were b to believe it, a's log would have no gap for b ever again:
      // what a writes and compacts away while b is not looking would be lost
      // to b without a sign.
      for (final id in ['two', 'three', 'four']) {
        await a.putEntry(rec(spend(id, 2), 2));
        await a.engine.sync();
      }
      await a.engine.compact();
      expect(batchesOf('a'), hasLength(1));
      await settle([a, b]);
      expect((await b.storedEntries()).map((r) => r.item.id).toSet(), {'one', 'two', 'three', 'four'});
      expect(() => SyncSnapshot.read(bad, SyncSnapshot(bad, const {'a': -1}, const []).body), throwsFormatException);
    });

    test('trimming removes only the rows that were sent', () async {
      await a.putEntry(rec(spend('s1', 100), 1));
      await a.engine.sync();
      await a.putEntry(rec(spend('s2', 200), 2));
      remote.onStep = (name) async {
        if (name == 'append') throw const SyncTransportFailure('append');
      };
      await expectLater(a.engine.push(), throwsA(isA<SyncTransportFailure>()));

      final removed = await a.engine.trimLocal();
      expect(removed, greaterThan(0));
      expect((await a.log()).single, endsWith(':put:ledger.entries:s2'), reason: 'the unsent row is still in the log');
      await expectLater(a.engine.compact(), throwsA(isA<SyncTransportFailure>()));
      expect((await a.log()).where((row) => row.endsWith(':s2')), hasLength(1));

      remote.onStep = null;
      a.restart();
      await settle([a, b]);
      expect(await b.state(), await a.state());
      expect((await b.storedEntries()).map((r) => r.item.id).toSet(), {'s1', 's2'});
      await a.engine.trimLocal();
      expect(await a.log(), isEmpty);

      await a.putEntry(rec(spend('s3', 300), 3));
      await settle([a, b]);
      expect(await b.state(), await a.state(), reason: 'the log carries on after it was emptied');
    });

    test('a row is kept until every remote the file knows has been sent it', () async {
      final second = MemorySyncTransport();
      final other = a.newEngine(transport: second, remote: 'second');
      await a.putEntry(rec(spend('s1', 100), 1));
      await a.engine.sync();
      await other.deviceId();
      await a.putEntry(rec(spend('s2', 200), 2));
      await a.engine.sync();

      await a.engine.trimLocal();
      expect((await a.log()).where((row) => row.endsWith(':s2')), hasLength(1), reason: 'the second remote has not been sent it');
      await other.sync();
      await a.engine.trimLocal();
      expect(await a.log(), isEmpty);
    });

    test('with no remote nothing is trimmed, and a remote first used after a trim is still sent everything', () async {
      final c = await Device.open(root, 'c', remote);
      await c.putEntry(rec(spend('s1', 100), 1));
      final lone = SyncEngine(remote: 'main', transport: remote, collections: const [], database: () async => c.db);
      final log = await c.log();
      expect(await lone.trimLocal(), 0);
      expect(await c.log(), log);

      await a.putEntry(rec(spend('early', 100), 1));
      await settle([a, b]);
      await a.engine.trimLocal();
      final second = MemorySyncTransport();
      final joiner = await Device.open(root, 'joiner', second, remote: 'second');
      await a.newEngine(transport: second, remote: 'second').sync();
      await joiner.engine.sync();
      expect(await joiner.state(), await a.state());
    });

    test('records that came in by a whole-collection row of the log are sent', () async {
      await a.putEntry(rec(spend('s1', 100), 1));
      await settle([a, b]);
      // What an import of an old file leaves: rows with no log row of their
      // own, and one row for the collection.
      await a.db.customStatement("INSERT INTO documents (collection, id, body, sort, updated_at, deleted) VALUES ('ledger.accounts', 'old', ?, 0, '2026-05-01T10:00:00.000Z', 0)", [jsonEncode(account('old', 'Old').toJson())]);
      await a.db.customStatement("INSERT INTO changes (at, collection, id, op, body) VALUES ('2026-05-01T10:00:00.000Z', 'ledger.accounts', '', 'import', '{\"count\":1}')");
      await settle([a, b]);
      expect((await b.storedAccounts()).single.item.id, 'old');
    });
  });

  group('snapshots that cannot be read', () {
    test('a snapshot that was still arriving is read once it is whole, by the same engine', () async {
      for (var i = 0; i < 3; i++) {
        await a.putEntry(rec(spend('s$i', 100 + i), 1 + i));
        await a.engine.sync();
      }
      await b.engine.sync();
      final snapshot = (await a.engine.compact()).snapshot!;
      final whole = remote.snapshots[snapshot]!;
      remote.snapshots[snapshot] = whole.substring(0, whole.length ~/ 2);

      final fresh = await Device.open(root, 'fresh', remote);
      final first = await fresh.engine.sync();
      expect(first.pull.waiting, isNotEmpty);
      expect(first.pull.problems.single.kind, SyncProblemKind.unreadable);
      expect(first.quiet, isFalse);

      remote.snapshots[snapshot] = whole;
      final second = await fresh.engine.sync();
      expect(second.pull.problems, isEmpty);
      expect(await fresh.state(), await a.state());
    });

    test('a damaged snapshot below a readable one, with the reader ahead of both, costs one read each and no end of rounds', () async {
      await a.putEntry(rec(spend('x', 100), 1));
      await settle([a, b]);
      final snapshot = (await a.engine.compact()).snapshot!;
      await b.putEntry(rec(spend('x', 200), 2));
      remote.snapshots[SyncSnapshotRef(writer: 'w', device: 'a', seq: snapshot.seq - 1)] = 'half a fi';
      final later = SyncSnapshotRef(writer: 'w', device: 'a', seq: snapshot.seq + 5);
      final old = SyncSnapshot.read(snapshot, remote.snapshots.remove(snapshot)!);
      remote.snapshots[later] = SyncSnapshot(later, old.covers, old.records).body;

      final calls = <String, int>{};
      remote.onStep = (step) async {
        calls[step] = (calls[step] ?? 0) + 1;
        if (calls[step]! > 50) throw StateError('the engine is looping: $calls');
      };
      final log = (await b.log()).length;
      final compaction = await b.engine.compact();
      expect(compaction.refused, isFalse);
      expect(compaction.round.pull.problems.single.kind, SyncProblemKind.unreadable);
      expect(calls['readSnapshot'], 2, reason: 'each snapshot is read once');
      expect((await b.log()).length, lessThan(log + 4), reason: 'the log does not grow with every look at a snapshot');
      expect((await b.storedEntries()).single.item.lines.first.amount, -200);

      calls.clear();
      await b.engine.compact();
      expect(calls['readSnapshot'], 1, reason: 'the damaged one is read again, in case it has arrived; the one taken in is not');
      remote.onStep = null;
      expect(remote.snapshots.keys.map((ref) => ref.name), contains('a.w.${snapshot.seq - 1}.1.1'), reason: 'what was never read is never removed');
    });

    test('a pull ends even when the remote gives it nothing new to hold on to', () async {
      await a.putEntry(rec(spend('x', 100), 1));
      await a.engine.sync();
      // A snapshot that covers nothing and holds nothing, and a batch that
      // never becomes readable, both listed for ever.
      const empty = SyncSnapshotRef(writer: 'w', device: 'zz', seq: 4);
      remote.snapshots[empty] = SyncSnapshot(empty, const {}, const []).body;
      remote.batches[const SyncBatchRef(writer: 'w', device: 'q', prev: 0, last: 9)] = 'not a batch';
      var lists = 0;
      remote.onStep = (step) async {
        if (step == 'list' && ++lists > 20) throw StateError('the pull is looping');
      };
      for (var i = 0; i < 3; i++) {
        final round = await b.engine.sync();
        expect(round.pull.problems, isNotEmpty);
      }
      expect(lists, lessThan(12));
      expect((await b.storedEntries()).single.item.id, 'x');
    });
  });

  group('two databases under one device id', () {
    /// A copy of [of]'s file as a restore leaves it: the same id, the same
    /// positions, the same log.
    Future<Device> copyOf(Device of, String name) async {
      final copy = await Device.open(root, name, remote, id: null);
      await copyDatabase(of.db, copy.db);
      return copy;
    }

    Future<String> ids(Device device) async => ((await device.storedEntries()).map((r) => r.item.id).toList()..sort()).join(',');

    test('whose batches end at the same numbers both take a new id, and every save of both reaches everyone', () async {
      await a.putEntry(rec(spend('e0', 100), 1));
      await settle([a, b]);
      final copy = await copyOf(a, 'copy');
      expect(await copy.engine.deviceId(), 'a');

      // Each is used before it hears of the other: what one stores reaches
      // the other's listing late.
      Future<void> syncUnseen(Device device) async {
        await device.engine.sync();
        remote.delayed.addAll(remote.batches.keys);
      }

      remote.delayed.addAll(remote.batches.keys);
      await a.putEntry(rec(spend('e1', 101), 2));
      await syncUnseen(a);
      await copy.putEntry(rec(spend('e3', 103), 2));
      await copy.putEntry(rec(spend('e4', 104), 2));
      await syncUnseen(copy);
      await a.putEntry(rec(spend('e2', 102), 3));
      await syncUnseen(a);
      final under = batchesOf('a');
      expect(under.map((ref) => ref.last).toSet().length, lessThan(under.length), reason: 'two different batches under the id end at one number');
      remote.delayed.clear();

      await a.putEntry(rec(spend('e5', 105), 4));
      await settle([a, copy, b]);
      expect(await ids(b), 'e0,e1,e2,e3,e4,e5');
      expect(await ids(a), await ids(b));
      expect(await ids(copy), await ids(b));
      expect({await a.engine.deviceId(), await copy.engine.deviceId(), 'a'}, hasLength(3), reason: 'each saw a batch under its id that it did not write');
    });

    test('a reader applies every batch of an id, also two that cover the same numbers', () async {
      // Two files with one id and one history, each used with no round in
      // between, so neither ever hears of the other.
      final one = await Device.open(root, 'one', remote, id: 'dd');
      final two = await Device.open(root, 'two', remote, id: 'dd');
      for (final copy in [one, two]) {
        await copy.putEntry(rec(spend('e0', 100), 1));
        await copy.engine.push();
      }
      await one.putEntry(rec(spend('e1', 101), 2));
      await one.engine.push();
      await two.putEntry(rec(spend('e3', 103), 2));
      await two.putEntry(rec(spend('e4', 104), 2));
      await two.engine.push();
      await one.putEntry(rec(spend('e2', 102), 3));
      await one.engine.push();

      final round = await b.engine.sync();
      expect(round.pull.waiting, isEmpty);
      expect(round.pull.problems, isEmpty);
      expect(await ids(b), 'e0,e1,e2,e3,e4');

      // And one that arrives after the place has moved to where it ends.
      final late = await Device.open(root, 'late', remote);
      final ofTwo = batchesOf('dd').where((ref) => idsIn(remote, ref).contains('ledger.entries/e4')).single;
      remote.delayed.add(ofTwo);
      await late.engine.sync();
      expect(await ids(late), 'e0,e1,e2');
      remote.delayed.clear();
      await late.engine.sync();
      expect(await ids(late), 'e0,e1,e2,e3,e4');

      await settle([one, two, b, late]);
      expect(await ids(one), 'e0,e1,e2,e3,e4');
      expect(await ids(two), await ids(one));
    });

    test('a copy that is behind sees what the original wrote since, and takes a new id before it sends anything', () async {
      await a.putEntry(rec(spend('shared', 1), 1));
      await a.engine.sync();
      final copy = await copyOf(a, 'copy');
      await a.putEntry(rec(spend('onA1', 1), 2));
      await a.putEntry(rec(spend('onA2', 1), 3));
      await a.engine.sync();
      await copy.putEntry(rec(spend('onCopy', 2), 4));

      final pulled = await copy.engine.pull();
      expect(pulled.rekeyed, isTrue);
      expect(await copy.engine.deviceId(), isNot('a'));
      expect(batchesOf('a').length, 2, reason: 'nothing was written under the old id');
      await settle([a, copy, b]);
      expect(await ids(b), 'onA1,onA2,onCopy,shared');
      expect(await copy.state(), await b.state());
      expect(await a.state(), await b.state());
      expect(await a.engine.deviceId(), 'a', reason: 'the original never saw a batch it did not write');
    });

    test('a database restored to an earlier state reads back what it had sent, under a new id', () async {
      await a.putEntry(rec(spend('early', 1), 1));
      await a.engine.sync();
      final restored = await copyOf(a, 'restored');
      await a.putEntry(rec(spend('late', 1), 2));
      await a.engine.sync();
      // The original is gone; the restore carries on.
      final round = await restored.engine.sync();
      expect(round.pull.rekeyed, isTrue);
      await settle([restored, b]);
      expect(await ids(restored), 'early,late');
      expect(await restored.state(), await b.state());
    });

    test('a copy whose original never writes again carries on under the same id', () async {
      await a.putEntry(rec(spend('shared', 1), 1));
      await a.engine.sync();
      final copy = await copyOf(a, 'copy');
      await copy.putEntry(rec(spend('onCopy', 2), 2));
      final round = await copy.engine.sync();
      expect(round.pull.rekeyed, isFalse);
      expect(await copy.engine.deviceId(), 'a');
      await settle([copy, b]);
      expect(await copy.state(), await b.state());
    });

    test('after a new id the snapshots are read again: what the old id\'s log no longer holds is in them', () async {
      final c = await Device.open(root, 'c', remote);
      for (var i = 0; i < 4; i++) {
        await a.putEntry(rec(spend('a$i', 100 + i), 1 + i));
        await a.engine.push();
        await c.putEntry(rec(spend('c$i', 100 + i), 1 + i));
        await c.engine.sync();
      }
      // b's snapshot stands in for the batches of a and of c that it
      // removes. a had not seen c's: it finds the gap and takes the snapshot
      // in, and writes none of its own.
      await b.engine.sync();
      await b.engine.compact();
      expect(batchesOf('a'), hasLength(1));
      expect(batchesOf('a').single.prev, greaterThan(0));
      final caught = await a.engine.sync();
      expect(caught.pull.waiting, isEmpty);
      expect(await a.meta('sync.in.main'), contains(remote.snapshots.keys.single.snapshot));

      // A copy of a writes under the id; a sees it and takes a new id. The
      // log of the old id now starts with a gap for a too, and only b's
      // snapshot, which a had taken in before, covers it.
      final copy = await copyOf(a, 'copy');
      await copy.putEntry(rec(spend('onCopy', 2), 9));
      await copy.engine.push();
      final round = await a.engine.sync();
      expect(round.pull.rekeyed, isTrue);
      expect(round.pull.waiting, isEmpty);
      expect(await ids(a), 'a0,a1,a2,a3,c0,c1,c2,c3,onCopy');
      await settle([a, copy, b, c]);
      expect(await ids(b), 'a0,a1,a2,a3,c0,c1,c2,c3,onCopy');
      expect(await ids(c), await ids(b));
    });

    test('a snapshot under its id that a database did not write shows another database as a batch does', () async {
      await a.putEntry(rec(spend('shared', 1), 1));
      await settle([a, b]);
      // A copy that only ever compacts stores no batch for a to see.
      final copy = await copyOf(a, 'copy');
      final theirs = (await copy.engine.compact()).snapshot!;
      expect(theirs.device, 'a');
      expect(batchesOf('a'), hasLength(1));

      final round = await a.engine.sync();
      expect(round.pull.rekeyed, isTrue);
      expect(await a.engine.deviceId(), isNot('a'));
      expect(await copy.engine.deviceId(), 'a');
      // And two that both compact do not go on replacing each other's
      // snapshot for ever.
      for (var i = 0; i < 2; i++) {
        await a.engine.compact();
        await copy.engine.compact();
      }
      final stored = Map.of(remote.snapshots);
      await a.engine.compact();
      await copy.engine.compact();
      expect(remote.snapshots, stored);
      await settle([a, copy, b]);
      expect(await copy.state(), await a.state());
    });

    test('a batch of its own that was stored and not acknowledged, and is there in other bytes, does not make a device take a new id', () async {
      for (final restart in [true, false]) {
        final device = await Device.open(root, 'own$restart', remote);
        await device.putEntry(rec(spend('e$restart', 100), 1));
        remote.onStep = (step) async {
          if (step == 'append.done') throw const SyncTransportFailure('the app stops');
        };
        await expectLater(device.engine.sync(), throwsA(isA<SyncTransportFailure>()));
        remote.onStep = null;
        // The same payload as another build of the app packs it: the same
        // records, other text.
        final ref = batchesOf(device.name).single;
        final envelope = jsonDecode(remote.batches[ref]!) as Map<String, dynamic>;
        final payload = gzip.decode(base64Decode(envelope['data'] as String));
        remote.batches[ref] = jsonEncode({'v': 1, 'z': 'gzip', 'data': base64Encode(GZipCodec(level: 1).encode(payload))});
        expect(SyncBatch.read(ref, remote.batches[ref]!).ops, hasLength(1));

        if (restart) device.restart();
        final round = await device.engine.sync();
        expect(round.pull.rekeyed, isFalse, reason: 'restart $restart');
        expect(await device.engine.deviceId(), device.name, reason: 'restart $restart');
        await settle([device, b]);
        expect((await b.storedEntries()).map((r) => r.item.id), contains('e$restart'));
      }
    });

    Future<int> high(Device device) async => (await device.db.customSelect("SELECT seq FROM sqlite_sequence WHERE name = 'changes'").getSingle()).data['seq'] as int;

    test('a batch name of its own that holds a damaged body is left, and the batch goes out under the next number', () async {
      final engine = a.newEngine(writer: 'w');
      await a.putEntry(rec(spend('s1', 1), 1));
      await engine.sync();
      await b.engine.sync();
      for (final damage in ['half a ba', fromALaterBuild()]) {
        await a.putEntry(rec(spend('s2', 2 + damage.length), 3 + damage.length));
        final taken = SyncBatchRef(device: 'a', writer: 'w', prev: batchesOf('a').last.last, last: await high(a));
        remote.batches[taken] = damage;
        expect((await engine.push()).sent, 1, reason: damage);
        expect(await a.engine.deviceId(), 'a', reason: damage);
        expect(remote.batches[taken], damage, reason: 'what is there is left as it is');
        expect(batchesOf('a').last, SyncBatchRef(device: 'a', writer: 'w', prev: taken.prev, last: taken.last + 1));
        final round = await b.engine.sync();
        expect(round.pull.problems, isEmpty, reason: 'the batch that ends one later stands in for the damaged one');
        expect(round.pull.applied, 1);
        expect((await b.engine.sync()).quiet, isTrue, reason: 'and the damaged one holds nobody up');
      }
      expect(await b.state(), await a.state());
    });

    test('a snapshot name of its own that comes to hold a damaged body is written again under the next number, and cleared away', () async {
      final damaging = _DamagingFirstSnapshot();
      final device = await Device.open(root, 'own', damaging);
      await device.putEntry(rec(spend('s1', 1), 1));
      final compaction = await device.engine.compact();
      expect(damaging.damaged, isNotNull);
      expect(await device.engine.deviceId(), 'own');
      expect(compaction.snapshot!.seq, greaterThan(damaging.damaged!.seq));
      expect(damaging.snapshots.keys, [compaction.snapshot], reason: 'the name it set out to write and could not use goes with its older ones');
      final fresh = await Device.open(root, 'fresh', damaging);
      await fresh.engine.sync();
      expect(await fresh.state(), await device.state());
    });

    test('a transport that takes nothing under any name is reported, not tried for ever', () async {
      await a.putEntry(rec(spend('s1', 1), 1));
      final refusing = _Refusing();
      await expectLater(a.newEngine(transport: refusing).push(), throwsStateError);
      expect(refusing.appends, lessThan(8));
    });
  });

  group('a batch of which a part never arrives', () {
    test('is never used, is reported apart from what a device waits for, and goes once a later one covers it', () async {
      final big = await Device.open(root, 'big', remote, partBytes: 700);
      for (var i = 0; i < 9; i++) {
        await big.putEntry(rec(spend('s$i', 100 + i), 1 + i, order: i.toDouble()));
      }
      var appends = 0;
      remote.onStep = (step) async {
        if (step == 'append' && ++appends == 3) throw const SyncTransportFailure('the writer stops');
      };
      await expectLater(big.engine.sync(), throwsA(isA<SyncTransportFailure>()));
      remote.onStep = null;
      final partial = batchesOf('big');
      expect(partial, hasLength(2));
      expect(partial.first.parts, greaterThan(2));

      // The writer does not come back. The others are at rest, and say what
      // is there.
      for (var i = 0; i < 2; i++) {
        final round = await b.engine.sync();
        expect(round.pull.incomplete, [partial.first]);
        expect(round.pull.waiting, isEmpty);
        expect(round.pull.problems, isEmpty);
        expect(round.pull.applied, 0);
        expect(round.quiet, isTrue);
      }
      expect(await b.storedEntries(), isEmpty);
      await b.putEntry(rec(spend('mine', 1), 1));
      await b.engine.compact();
      expect(batchesOf('big'), partial, reason: 'no snapshot covers it, so it stays');

      // It does come back, as a new run of the app: the same changes go out
      // whole, and the old parts are passed over.
      big.restart();
      await big.engine.sync();
      final round = await b.engine.sync();
      expect(round.pull.applied, 9);
      expect(round.pull.incomplete, isEmpty);
      await settle([big, b]);
      expect(await b.state(), await big.state());

      // Once a place has moved on from a batch that started after them, a
      // compaction takes them with the batches its snapshot covers.
      await big.putEntry(rec(spend('later', 1), 20));
      await settle([big, b]);
      await b.engine.compact();
      expect(batchesOf('big').where(partial.contains), isEmpty);
      final fresh = await Device.open(root, 'fresh', remote);
      await settle([fresh, big, b]);
      expect(await fresh.state(), await big.state());
    });

    test('a snapshot that covers its numbers clears it for a device that joins', () async {
      await a.putEntry(rec(spend('s1', 1), 1));
      await a.engine.sync();
      final big = await Device.open(root, 'big', remote, partBytes: 700);
      for (var i = 0; i < 6; i++) {
        await big.putEntry(rec(spend('b$i', 100 + i), 1 + i, order: i.toDouble()));
      }
      await big.engine.sync();
      for (var i = 0; i < 6; i++) {
        await big.putEntry(rec(spend('c$i', 100 + i), 10 + i, order: i.toDouble()));
      }
      var appends = 0;
      remote.onStep = (step) async {
        if (step == 'append' && ++appends == 2) throw const SyncTransportFailure('the writer stops');
      };
      await expectLater(big.engine.push(), throwsA(isA<SyncTransportFailure>()));
      remote.onStep = null;
      big.restart();
      await big.engine.compact();

      final fresh = await Device.open(root, 'fresh', remote);
      final round = await fresh.engine.sync();
      expect(round.pull.incomplete, isEmpty);
      expect(round.pull.waiting, isEmpty);
      expect(await fresh.state(), await big.state());
    });
  });

  group('a snapshot write that fails', () {
    test('does not count as a snapshot: the next compaction writes one, with the book as it is', () async {
      await a.putEntry(rec(spend('e0', 100), 1));
      final first = (await a.engine.compact()).snapshot!;

      await a.putEntry(rec(spend('e1', 101), 2));
      remote.onStep = (step) async {
        if (step == 'writeSnapshot') throw const SyncTransportFailure('offline');
      };
      await expectLater(a.engine.compact(), throwsA(isA<SyncTransportFailure>()));
      remote.onStep = null;
      a.restart();

      final again = (await a.engine.compact()).snapshot!;
      expect(again, isNot(first));
      expect(remote.snapshots.keys, [again]);
      expect(SyncSnapshot.read(again, remote.snapshots[again]!).records, hasLength(2));
      final stored = Map.of(remote.snapshots);
      expect((await a.engine.compact()).snapshot, again);
      expect(remote.snapshots, stored);
    });

    test('half way through its parts leaves parts that the next compaction clears away with the older snapshot', () async {
      final big = await Device.open(root, 'big', remote, partBytes: 700);
      for (var i = 0; i < 9; i++) {
        await big.putEntry(rec(spend('s$i', 100 + i), 1 + i, order: i.toDouble()));
      }
      final first = (await big.engine.compact()).snapshot!;
      expect(first.parts, greaterThan(2));
      for (var failures = 0; failures < 3; failures++) {
        await big.putEntry(rec(spend('more$failures', 1), 30 + failures));
        var writes = 0;
        remote.onStep = (step) async {
          if (step == 'writeSnapshot' && ++writes == 2) throw const SyncTransportFailure('offline');
        };
        await expectLater(big.engine.compact(), throwsA(isA<SyncTransportFailure>()));
        remote.onStep = null;
        big.restart();
      }
      expect(remote.snapshots.keys.map((ref) => ref.snapshot).toSet(), hasLength(4), reason: 'one whole and three begun');

      final whole = (await big.engine.compact()).snapshot!;
      expect(remote.snapshots.keys.map((ref) => ref.snapshot).toSet(), {whole.snapshot});
      expect(remote.snapshots, hasLength(whole.parts));
      final fresh = await Device.open(root, 'fresh', remote);
      await settle([fresh, big]);
      expect(await fresh.state(), await big.state());
    });

    test('an older snapshot of its own does not stand in for the one a device has lost', () async {
      await a.putEntry(rec(spend('e0', 100), 1));
      final first = (await a.engine.compact()).snapshot!;
      await a.putEntry(rec(spend('e1', 101), 2));
      // The second is stored, and the first is not removed: the compaction
      // stops there.
      remote.onStep = (step) async {
        if (step == 'discard') throw const SyncTransportFailure('offline');
      };
      await expectLater(a.engine.compact(), throwsA(isA<SyncTransportFailure>()));
      remote.onStep = null;
      a.restart();
      expect(remote.snapshots, hasLength(2));
      remote.snapshots.removeWhere((ref, _) => ref != first);

      final again = (await a.engine.compact()).snapshot!;
      expect(remote.snapshots.keys, [again], reason: 'a snapshot with the book as it is, and the old one cleared away');
      expect(SyncSnapshot.read(again, remote.snapshots[again]!).records, hasLength(2));
    });

    test('what a device that is gone left of older snapshots is cleared by any other, down to its newest', () async {
      // b comes after a in the order, writes two snapshots without removing
      // the first, and is never seen again.
      await a.putEntry(rec(spend('e0', 100), 1));
      await settle([a, b]);
      final first = (await b.engine.compact()).snapshot!;
      await b.putEntry(rec(spend('e1', 101), 2));
      remote.onStep = (step) async {
        if (step == 'discard') throw const SyncTransportFailure('offline');
      };
      await expectLater(b.engine.compact(), throwsA(isA<SyncTransportFailure>()));
      remote.onStep = null;
      final ofB = remote.snapshots.keys.where((ref) => ref.device == 'b').toList();
      expect(ofB, hasLength(2));

      final mine = (await a.engine.compact()).snapshot!;
      expect(remote.snapshots.keys.toSet(), {mine, ofB.singleWhere((ref) => ref != first)}, reason: 'b\'s newest stays: a comes before b');
      final fresh = await Device.open(root, 'fresh', remote);
      await settle([a, fresh]);
      expect(await fresh.state(), await a.state());
    });

    test('a listing that leaves the snapshot out does not make a device write it again or think it gone', () async {
      final hiding = _HidingSnapshots();
      final device = await Device.open(root, 'hidden', hiding);
      await device.putEntry(rec(spend('e0', 100), 1));
      final first = (await device.engine.compact()).snapshot!;
      expect(hiding.snapshots.keys, [first]);
      for (var i = 0; i < 3; i++) {
        expect((await device.engine.compact()).snapshot, first);
      }
      expect(hiding.snapshots.keys, [first]);

      // Really gone, and no other device's there: it is written again.
      hiding.snapshots.clear();
      final again = (await device.engine.compact()).snapshot!;
      expect(again, isNot(first));
      expect(hiding.snapshots.keys, [again]);
    });
  });

  test('a remote is named in lower case letters and digits', () {
    expect(() => SyncEngine(remote: 'Main.1', transport: remote, collections: const []), throwsArgumentError);
  });

  test('a record that is purged here has nothing to send, as in a merge', () async {
    await a.putEntry(rec(spend('s1', 100), 1));
    await settle([a, b]);
    final known = {for (final r in await a.storedEntries()) r.item.id: r};
    await a.db.transaction(() => a.entries.writeIn(a.db, const <Record<BookEntry>>[], known: known));
    expect(await a.storedEntries(), isEmpty);
    expect((await a.engine.sync()).push.sent, 0);
    expect((await b.storedEntries()).single.item.id, 's1');
  });
}
