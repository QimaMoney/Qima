import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:qima/services/book_db/book_database.dart';
import 'package:qima/services/book_store.dart';
import 'package:qima/services/local_file_store.dart';
import 'package:qima/services/sync/book_sync.dart';
import 'package:qima/services/sync/directory_sync_transport.dart';
import 'package:qima/services/sync/sync_engine.dart';
import 'package:qima/services/sync/sync_report.dart';
import 'package:qima/services/sync/sync_transport.dart';
import 'package:qima/services/sync/sync_wire.dart';

import 'memory_sync_transport.dart';
import 'sync_support.dart';

const _a1 = SyncBatchRef(writer: 'w', device: 'aa', prev: 0, last: 3);
const _a2 = SyncBatchRef(writer: 'w', device: 'aa', prev: 3, last: 8, part: 1, parts: 2);
const _a2b = SyncBatchRef(writer: 'w', device: 'aa', prev: 3, last: 8, part: 2, parts: 2);
const _b1 = SyncBatchRef(writer: 'w', device: 'bb', prev: 0, last: 2);
const _snapshot = SyncSnapshotRef(writer: 'w', device: 'aa', seq: 8);

void main() {
  late Directory root;
  late Directory folder;
  late DirectorySyncTransport remote;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('qima_sync_directory');
    folder = Directory('${root.path}/remote');
    remote = DirectorySyncTransport(folder);
  });

  tearDown(() async {
    await BookDatabase.closeAll();
    BookDatabase.executorOverride = null;
    await root.delete(recursive: true);
  });

  List<String> files() => [for (final f in folder.listSync()) f.uri.pathSegments.last]..sort();

  group('as a store of batches and snapshots', () {
    test('a folder that is not there yet is empty, and is made by the first write', () async {
      final listing = await remote.list(after: const {});
      expect(listing.batches, isEmpty);
      expect(listing.snapshots, isEmpty);
      expect(await remote.read(_a1), isNull);
      expect(await remote.readSnapshot(_snapshot), isNull);
      await remote.discard(batchesThrough: const {'aa': 9}, snapshots: const [_snapshot]);
      expect(folder.existsSync(), isFalse);

      expect(await remote.append(_a1, 'one'), isTrue);
      expect(files(), ['batch.aa.w.0.3.1.1.json']);
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
      expect(await remote.writeSnapshot(_snapshot, 'other'), isFalse);
      expect(await remote.readSnapshot(_snapshot), 'whole');
      expect(files(), ['batch.aa.w.0.3.1.1.json', 'snapshot.aa.w.8.1.1.json']);
    });

    test('discard removes the batches up to the places it is given and the snapshots it names, and nothing else', () async {
      await remote.append(_a1, 'one');
      await remote.append(_a2, 'two');
      await remote.append(_a2b, 'two more');
      await remote.append(_b1, 'three');
      await remote.writeSnapshot(_snapshot, 'old');
      await remote.writeSnapshot(const SyncSnapshotRef(writer: 'w', device: 'bb', seq: 2), 'kept');
      File('${folder.path}/notes.txt').writeAsStringSync('not ours');

      await remote.discard(batchesThrough: const {'aa': 3}, snapshots: const [_snapshot, SyncSnapshotRef(writer: 'w', device: 'cc', seq: 1)]);
      expect(files(), ['batch.aa.w.3.8.1.2.json', 'batch.aa.w.3.8.2.2.json', 'batch.bb.w.0.2.1.1.json', 'notes.txt', 'snapshot.bb.w.2.1.1.json']);
    });

    test('files that are not ours are left alone, and one that only looks like ours is reported and never handed over', () async {
      await remote.append(_a1, 'one');
      File('${folder.path}/.DS_Store').writeAsStringSync('x');
      File('${folder.path}/.batch.aa.w.3.8.1.1.json.icloud').writeAsStringSync('x');
      File('${folder.path}/readme.json').writeAsStringSync('{}');
      Directory('${folder.path}/batch.aa.20.30.1.1.json').createSync();
      const strays = [
        'batch.aa.w.9.4.1.1.json',
        'batch.AA.w.1.2.1.1.json',
        'batch.aa.w.00.07.1.1.json',
        'batch.aa.w.5.7.01.1.json',
        'batch.aa.w.5.7.json',
        'batch.aa.5.7.1.1.json',
        'batch.aa.w.0.3.1.1 2.json',
        'snapshot.aa.w.json',
        'snapshot.aa.w.08.1.1.json',
        'snapshot.aa.8.1.1.json',
      ];
      for (final name in strays) {
        File('${folder.path}/$name').writeAsStringSync('x');
      }

      final listing = await remote.list(after: const {});
      expect(listing.batches, [_a1]);
      expect(listing.snapshots, isEmpty);
      expect(listing.problems, hasLength(strays.length));
      for (final name in strays) {
        expect(listing.problems.join('\n'), contains(name));
      }
      await remote.discard(batchesThrough: const {'aa': 99}, snapshots: const []);
      expect(files(), containsAll(strays), reason: 'what could not be named is not removed either');
    });

    test('a file larger than the engine reads is not loaded, and is handed over as damage', () async {
      await remote.append(_a1, 'one');
      final file = File('${folder.path}/batch.aa.w.0.3.1.1.json');
      final handle = file.openSync(mode: FileMode.write);
      handle.truncateSync(SyncWire.maxBodyBytes + 1);
      handle.closeSync();
      final body = await remote.read(_a1);
      expect(body!.length, lessThan(100));
      expect(() => SyncBatch.read(_a1, body), throwsFormatException);
    });
  });

  group('writes are all or nothing', () {
    test('a write leaves the whole file under its name and nothing else', () async {
      final body = 'x' * 500000;
      await remote.append(_a1, body);
      await remote.writeSnapshot(_snapshot, body);
      expect(files(), ['batch.aa.w.0.3.1.1.json', 'snapshot.aa.w.8.1.1.json']);
      expect(File('${folder.path}/batch.aa.w.0.3.1.1.json').readAsStringSync(), body);
    });

    test('what a write that stopped half way left behind is never read as a batch, and is cleared away once it is old', () async {
      await remote.append(_a1, 'one');
      final fresh = File('${folder.path}/.batch.aa.w.3.8.1.1.json.123.456.tmp')..writeAsStringSync('half of a bo');
      final old = File('${folder.path}/.snapshot.aa.w.8.1.1.json.123.789.tmp')..writeAsStringSync('half of a sn');
      old.setLastModifiedSync(DateTime.now().subtract(DirectorySyncTransport.staleAfter + const Duration(minutes: 1)));
      final theirs = File('${folder.path}/.other.tmp')..writeAsStringSync('not ours');
      theirs.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 30)));

      final listing = await remote.list(after: const {});
      expect(listing.batches, [_a1]);
      expect(listing.snapshots, isEmpty);
      expect(listing.problems, isEmpty);

      await remote.discard(batchesThrough: const {}, snapshots: const []);
      expect(fresh.existsSync(), isTrue, reason: 'it may be a write that is going on');
      expect(old.existsSync(), isFalse);
      expect(theirs.existsSync(), isTrue);
      expect(await remote.append(const SyncBatchRef(writer: 'w', device: 'aa', prev: 3, last: 8), 'two'), isTrue);
    });

    test('isolates storing the same names at once leave whole files and no others', () async {
      final path = folder.path;
      final results = await Future.wait([
        for (var writer = 0; writer < 4; writer++)
          Isolate.run(() async {
            final transport = DirectorySyncTransport(Directory(path));
            final body = '$writer' * 200000;
            var kept = 0;
            for (var i = 0; i < 20; i++) {
              if (await transport.append(SyncBatchRef(writer: 'w', device: 'aa', prev: i, last: i + 1), body)) kept++;
            }
            return (body, kept);
          }),
      ]);
      expect(files(), hasLength(20));
      final bodies = [for (final (body, _) in results) body];
      for (final ref in (await remote.list(after: const {})).batches) {
        expect(bodies, contains(await remote.read(ref)), reason: '$ref is one writer\'s whole body');
      }
    });
  });

  group('under the engine', () {
    test('a file that is cut short or damaged is reported and skipped, the rest is taken in, and it is read once it is whole', () async {
      final a = await Device.open(root, 'a', remote);
      final b = await Device.open(root, 'b', remote);
      final c = await Device.open(root, 'c', remote);
      await a.putEntry(rec(spend('fromA', 100), 1));
      await a.engine.sync();
      await b.putEntry(rec(spend('fromB', 200), 2));
      await b.engine.sync();

      final ofA = folder.listSync().whereType<File>().singleWhere((f) => f.path.contains('batch.a.'));
      final whole = ofA.readAsBytesSync();
      for (final damage in [whole.sublist(0, whole.length ~/ 2), [0xff, 0xfe, 0x00, 0x80], <int>[]]) {
        ofA.writeAsBytesSync(damage);
        final round = await c.engine.sync();
        expect(round.pull.problems.single.kind, SyncProblemKind.unreadable);
        expect(round.pull.problems.single.what, contains('batch a.'));
        expect(round.quiet, isFalse);
        expect((await c.storedEntries()).map((r) => r.item.id), ['fromB'], reason: 'the other device\'s batch is taken in');
        expect(ofA.readAsBytesSync(), damage, reason: 'the file is left as it was found');
      }

      ofA.writeAsBytesSync(whole);
      final round = await c.engine.sync();
      expect(round.pull.problems, isEmpty);
      expect(round.pull.applied, 1);
      await settle([a, b, c]);
      expect(await c.state(), await a.state());
      expect(await b.state(), await a.state());
    });

    test('a damaged snapshot is reported, kept, and does not stop a compaction from writing a good one', () async {
      final a = await Device.open(root, 'a', remote);
      final b = await Device.open(root, 'b', remote);
      await a.putEntry(rec(spend('s1', 100), 1));
      await settle([a, b]);
      File('${folder.path}/snapshot.cc.5.1.1.json').writeAsStringSync('{"v":1,"z":"gzip","data":"!!"}');

      final compaction = await a.engine.compact();
      expect(compaction.refused, isFalse);
      expect(compaction.round.pull.problems.single.kind, SyncProblemKind.unreadable);
      expect(files(), containsAll(['snapshot.cc.5.1.1.json', 'snapshot.${compaction.snapshot!.name}.json']));
      expect(SyncSnapshot.read(compaction.snapshot!, (await remote.readSnapshot(compaction.snapshot!))!).records, hasLength(1));
      await b.engine.compact();
      expect(files(), contains('snapshot.cc.5.1.1.json'), reason: 'b comes after a in the order, and still removes only what it has read');
    });

    test('a book in parts goes through the folder whole', () async {
      final a = await Device.open(root, 'a', remote, partBytes: 800);
      for (var i = 0; i < 12; i++) {
        await a.putEntry(rec(spend('s$i', 100 + i), 1 + i, order: i.toDouble()));
      }
      await a.engine.sync();
      await a.engine.compact();
      expect(files().where((f) => f.startsWith('snapshot.')).length, greaterThan(2));
      final b = await Device.open(root, 'b', remote, partBytes: 800);
      await settle([a, b]);
      expect(await b.state(), await a.state());
    });
  });

  group('two connections on one book file', () {
    test('engines and saves on both at once lose nothing and never see the other as a stranger', () async {
      // The same file through two paths is two entries in the registry of
      // open databases, each with a connection of its own on an isolate of
      // its own: the write lock is all that orders them.
      final real = Directory('${root.path}/real')..createSync();
      final link = Link('${root.path}/link')..createSync(real.path);
      final shared = MemorySyncTransport();
      BookDatabase.executorOverride = (file) => BookDatabase.executorFor(file, inBackground: true);
      LocalFileStore.overrideDirectoryForTesting(real);
      final first = await BookDatabase.open();
      LocalFileStore.overrideDirectoryForTesting(Directory(link.path));
      final second = await BookDatabase.open();
      expect(identical(first, second), isFalse);
      final other = await Device.open(root, 'other', shared);

      final engines = [engineOn(first, shared), engineOn(second, shared)];
      final rows = [entryRows(), entryRows()];
      await rows[0].prepareIn(first);
      await rows[1].prepareIn(second);
      final id = await engines[0].deviceId();
      final errors = <String>[];
      Future<void> guard(String what, Future<Object?> Function() run) async {
        try {
          final result = await run();
          final pull = switch (result) { SyncRound round => round.pull, SyncPull pull => pull, SyncCompaction compaction => compaction.round.pull, _ => null };
          if (pull != null && pull.rekeyed) errors.add('$what took a new id');
        } catch (e) {
          errors.add('$what: ${'$e'.split('\n').first}');
        }
      }

      var saved = 0;
      Future<void> save(int on, int stamp) {
        final db = on == 0 ? first : second;
        return db.transaction(() => rows[on].writeIn(db, [rec(spend('mine${saved++}', 1), stamp)]));
      }

      for (var i = 0; i < 20; i++) {
        for (var k = 0; k < 10; k++) {
          await other.putEntry(rec(spend('other$i-$k', 5), 1000 + i));
        }
        await other.engine.sync();
        await Future.wait([
          guard('sync 1', () => engines[0].sync()),
          guard('sync 2', () => engines[1].sync()),
          guard('save 1', () => save(0, 2000 + i)),
          guard('save 2', () => save(1, 2000 + i)),
          guard('compact 2', () => engines[1].compact()),
          guard('save 1', () => save(0, 2000 + i)),
          guard('pull 1', () => engines[0].pull()),
          guard('push 2', () => engines[1].push()),
          guard('compact 1', () => engines[0].compact()),
        ]);
      }
      expect(errors, isEmpty);
      expect(await engines[1].deviceId(), id);

      for (var i = 0; i < 10; i++) {
        final here = await engines[0].sync();
        final there = await other.engine.sync();
        if (here.quiet && there.quiet) break;
      }
      final mine = await first.transaction(() => rows[0].storedIn(first));
      expect(mine.length, saved + 200);
      expect(show(mine), show(await other.storedEntries()));
      final fresh = await Device.open(root, 'fresh', shared);
      await settle([fresh, other]);
      expect(show(await fresh.storedEntries()), show(mine));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('the app and a second isolate sync the same book through a folder at once', () async {
      BookDatabase.executorOverride = null;
      final home = Directory('${root.path}/home')..createSync();
      final away = Directory('${root.path}/away')..createSync();
      LocalFileStore.overrideDirectoryForTesting(home);
      final app = BookStore(sync: BookSync.changeLog(remote));
      await app.entries.load();
      final id = await (app.changeLog! as SyncEngine).deviceId();
      final homePath = home.path;
      final remotePath = folder.path;
      const each = 25;

      final background = Isolate.run(() async {
        LocalFileStore.overrideDirectoryForTesting(Directory(homePath));
        final store = BookStore(sync: BookSync.changeLog(DirectorySyncTransport(Directory(remotePath))));
        for (var i = 0; i < each; i++) {
          await store.entries.upsert(spend('background$i', 100 + i));
          await store.changeLog!.sync();
        }
        await store.changeLog!.compact();
        await BookDatabase.closeAll();
      });
      for (var i = 0; i < each; i++) {
        await app.entries.upsert(spend('app$i', 200 + i));
        await app.changeLog!.sync();
      }
      await background;
      await app.changeLog!.sync();
      expect(await (app.changeLog! as SyncEngine).deviceId(), id, reason: 'the two isolates are one device');

      LocalFileStore.overrideDirectoryForTesting(away);
      final other = BookStore(sync: BookSync.changeLog(remote));
      final round = await other.changeLog!.sync();
      expect(round.pull.waiting, isEmpty);
      expect(round.pull.problems, isEmpty);
      final received = (await other.entries.load()).map((e) => e.id).toSet();
      expect(received, {for (var i = 0; i < each; i++) ...['app$i', 'background$i']});
      final there = show(await other.entries.exportRecords());

      LocalFileStore.overrideDirectoryForTesting(home);
      expect(show(await app.entries.exportRecords()), there);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
