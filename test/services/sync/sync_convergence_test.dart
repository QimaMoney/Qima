import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/book_account.dart';
import 'package:qima/models/book_entry.dart';
import 'package:qima/models/syncable.dart';
import 'package:qima/services/book_db/book_database.dart';
import 'package:qima/services/sync/sync_engine.dart';
import 'package:qima/services/sync/sync_report.dart';
import 'package:qima/services/sync/sync_transport.dart';
import 'package:qima/services/synced_store.dart';

import 'memory_sync_transport.dart';
import 'sync_support.dart';

/// Real engines on real book databases, over a remote that fails calls,
/// names things late, twice and out of order. Devices save, delete and sync
/// in a random interleaving, stop in the middle of a call and start again,
/// compact often, and one joins late. When the weather clears and every
/// device has had its rounds, all hold the same records, and those are the
/// records `SyncedStore.merge` makes of every save that was ever tried.
///
/// Every device stamps its saves from its own clock, which agrees with no
/// other and does not only run forward: it stands still and steps back too.
/// A save that would lose to the record the device holds is not stored (that
/// is the property the stores keep), so it loses in the merge of all saves as
/// well.
///
/// What a run adds to that is in [Mode]. `SYNC_FUZZ_MODE` picks one mode for
/// every run (`mixed`, the default, draws a new one per seed),
/// `SYNC_FUZZ_COUNT` the number of seeds per size, `SYNC_FUZZ_FROM` the first
/// seed, and `SYNC_FUZZ_ONLY=size:seed` runs one case and prints what it does.
class Mode {
  /// A device stops syncing half way and is never seen again.
  final bool retire;

  /// Two devices are also joined through a second remote.
  final bool second;

  /// Two engines run on one database at the same moment, with a save.
  final bool twins;

  /// The device that joins late has records of its own.
  final bool preload;

  /// Stored bodies are cut short, or replaced by one from a later build, for
  /// a while.
  final bool damage;

  const Mode({this.retire = false, this.second = false, this.twins = false, this.preload = false, this.damage = false});

  static const Map<String, Mode> named = {
    'plain': Mode(),
    'retire': Mode(retire: true),
    'second': Mode(second: true),
    'twins': Mode(twins: true),
    'preload': Mode(preload: true),
    'damage': Mode(damage: true),
    'all': Mode(second: true, twins: true, preload: true, damage: true),
  };

  static Mode drawn(Random random) => Mode(retire: random.nextInt(4) == 0, second: random.nextInt(3) == 0, twins: random.nextInt(3) == 0, preload: random.nextBool(), damage: random.nextInt(3) == 0);

  @override
  String toString() => [if (retire) 'retire', if (second) 'second', if (twins) 'twins', if (preload) 'preload', if (damage) 'damage'].join('+');
}

const _entryIds = ['e0', 'e1', 'e2', 'e3'];
const _tradeIds = ['t0', 't1'];
const _accountIds = ['a0', 'a1', 'a2'];

/// What the runs of one test met, so a run that never met the hard cases
/// (because the script or the engine changed) does not pass for one that did.
class Met {
  int failures = 0;
  int waits = 0;
  int problems = 0;
  int snapshots = 0;
  int ties = 0;
  int back = 0;
  int refused = 0;
  int twins = 0;
}

/// A device and its engines, one per remote it is joined to.
class Dev {
  final Device device;
  final List<SyncEngine> engines = [];
  final List<MemorySyncTransport> transports = [];
  final List<String> remotes = [];
  final Map<String, String> places = {};
  bool retired = false;
  int clock;

  Dev(this.device, this.clock);

  void join(MemorySyncTransport transport, String remote) {
    transports.add(transport);
    remotes.add(remote);
    engines.add(device.newEngine(transport: transport, remote: remote));
  }

  /// A new engine in place of [i]: what a restart of the app leaves.
  void restart(int i) => engines[i] = device.newEngine(transport: transports[i], remote: remotes[i]);
}

class World {
  final Met met;
  final Random random;
  final Mode mode;
  final String tag;
  final bool trace;
  final MemorySyncTransport main = MemorySyncTransport();
  final MemorySyncTransport second = MemorySyncTransport();
  final List<Dev> devs = [];
  final List<Record<BookEntry>> entrySaves = [];
  final List<Record<BookAccount>> accountSaves = [];

  /// Bodies that were damaged, with what they held.
  final Map<SyncBatchRef, String> cutBatches = {};
  final Map<SyncSnapshotRef, String> cutSnapshots = {};

  /// Counts down the transport calls to the one that fails; idle below 1.
  int stopIn = -1;

  World(int seed, this.mode, this.met, this.tag, {this.trace = false}) : random = Random(seed) {
    for (final transport in [main, second]) {
      transport.onStep = (step) async {
        if (stopIn > 0 && --stopIn == 0) throw SyncTransportFailure('stopped at $step');
      };
    }
  }

  void say(String Function() what) {
    // ignore: avoid_print
    if (trace) print(what());
  }

  List<Dev> get live => [for (final d in devs) if (!d.retired) d];

  Future<Dev> add(Directory root, {bool both = false}) async {
    final dev = Dev(await Device.open(root, 'd${devs.length}', main, partBytes: 1500), random.nextInt(6));
    dev.join(main, 'main');
    if (both) dev.join(second, 'second');
    devs.add(dev);
    return dev;
  }

  T pick<T>(List<T> from) => from[random.nextInt(from.length)];

  Future<void> save(Dev d) async {
    final move = random.nextInt(10);
    if (move < 6) {
      d.clock += 1 + random.nextInt(2);
    } else if (move >= 8) {
      d.clock = max(0, d.clock - random.nextInt(4));
      met.back++;
    }
    final deleted = random.nextInt(4) == 0;
    final order = random.nextInt(2).toDouble();
    final kind = random.nextInt(10);
    final before = await d.device.state();
    if (kind < 7) {
      // Versions of an old trade: the stamp alone often cannot order them.
      final item = kind < 4
          ? spend(pick(_entryIds), 100 + random.nextInt(3), merchant: pick(const ['Cafe', 'Shop']))
          : trade(pick(_tradeIds), 500 + random.nextInt(2), tradeMs: random.nextBool() ? random.nextInt(3) : null, cashMs: random.nextBool() ? random.nextInt(3) : null);
      final record = rec(item, d.clock, order: order, deleted: deleted);
      entrySaves.add(record);
      await d.device.putEntry(record);
      say(() => '  save ${d.device.name} ${item.id} @${d.clock} deleted $deleted');
    } else {
      final record = rec(account(pick(_accountIds), pick(const ['Bank', 'Cash'])), d.clock, order: order, deleted: deleted);
      accountSaves.add(record);
      await d.device.putAccount(record);
      say(() => '  save ${d.device.name} ${record.item.id} @${d.clock} deleted $deleted');
    }
    if (await d.device.state() == before) met.refused++;
  }

  void note(Object? result) {
    final pull = switch (result) { SyncRound round => round.pull, SyncPull pull => pull, SyncCompaction compaction => compaction.round.pull, _ => null };
    if (pull != null && pull.waiting.isNotEmpty) met.waits++;
    if (pull != null && pull.problems.isNotEmpty) met.problems++;
    if (result is SyncCompaction && result.snapshot != null) met.snapshots++;
    say(() => switch (result) {
          SyncRound x => '  -> applied ${x.pull.applied} sent ${x.push.sent} waiting ${x.pull.waiting} problems ${x.pull.problems}',
          SyncPull x => '  -> applied ${x.applied} waiting ${x.waiting} problems ${x.problems}',
          SyncPush x => '  -> sent ${x.sent}',
          SyncCompaction x => '  -> snapshot ${x.snapshot} refused ${x.refused}',
          _ => '  -> $result',
        });
  }

  /// A call into engine [i] of [d]. One the transport fails is like a stop of
  /// the app at that point: the next call is made by a new engine.
  Future<void> attempt(Dev d, int i, Future<Object?> Function(SyncEngine engine) run) async {
    try {
      note(await run(d.engines[i]));
    } on SyncTransportFailure catch (e) {
      say(() => '  -> $e');
      met.failures++;
      d.restart(i);
    }
    stopIn = -1;
  }

  /// Cuts a stored body short or swaps in one from a later build, or puts
  /// back what was damaged before.
  void damage() {
    if (random.nextBool() && (cutBatches.isNotEmpty || cutSnapshots.isNotEmpty)) return repair();
    final batches = main.batches.keys.where((ref) => !cutBatches.containsKey(ref)).toList();
    final snapshots = main.snapshots.keys.where((ref) => !cutSnapshots.containsKey(ref)).toList();
    if (batches.isNotEmpty && (snapshots.isEmpty || random.nextBool())) {
      final ref = pick(batches);
      cutBatches[ref] = main.batches[ref]!;
      main.batches[ref] = random.nextBool() ? cutBatches[ref]!.substring(0, cutBatches[ref]!.length ~/ 2) : jsonEncode({'v': 2, 'z': 'zstd', 'data': ''});
      say(() => '  damage batch $ref');
    } else if (snapshots.isNotEmpty) {
      // A snapshot only ever arrives late: a name whose body is from a later
      // build keeps that body, which the engine relies on.
      final ref = pick(snapshots);
      cutSnapshots[ref] = main.snapshots[ref]!;
      main.snapshots[ref] = cutSnapshots[ref]!.substring(0, cutSnapshots[ref]!.length ~/ 2);
      say(() => '  damage snapshot $ref');
    }
  }

  /// Puts back every damaged body that is still stored.
  void repair() {
    cutBatches.forEach((ref, body) {
      if (main.batches.containsKey(ref)) main.batches[ref] = body;
    });
    cutSnapshots.forEach((ref, body) {
      if (main.snapshots.containsKey(ref)) main.snapshots[ref] = body;
    });
    cutBatches.clear();
    cutSnapshots.clear();
    say(() => '  repair');
  }

  /// Positions only move forward, and a device keeps its id: nothing in a
  /// run gives it cause to think another writes under it.
  Future<void> watch(Dev d) async {
    final rows = await d.device.db.customSelect("SELECT key, value FROM meta WHERE key LIKE 'sync.%'").get();
    for (final row in rows) {
      final key = row.data['key'] as String;
      final value = row.data['value'] as String;
      final before = d.places[key];
      d.places[key] = value;
      if (key == SyncEngine.deviceKey) {
        if (value != d.device.name) fail('$tag ${d.device.name} took a new id');
      } else if (before != null && key.startsWith('sync.out.')) {
        final was = jsonDecode(before) as Map<String, dynamic>;
        final now = jsonDecode(value) as Map<String, dynamic>;
        for (final field in ['scanned', 'shipped']) {
          if ((now[field] as int) < (was[field] as int)) fail('$tag ${d.device.name} $key $field went back: $before -> $value');
        }
      } else if (before != null && key.startsWith('sync.in.')) {
        final was = (jsonDecode(before) as Map<String, dynamic>)['batches'] as Map<String, dynamic>;
        final now = (jsonDecode(value) as Map<String, dynamic>)['batches'] as Map<String, dynamic>;
        for (final writer in was.keys) {
          if (((now[writer] as List<dynamic>?)?[1] as int? ?? -1) < ((was[writer] as List<dynamic>)[1] as int)) fail('$tag ${d.device.name} $key went back for $writer: $before -> $value');
        }
      }
    }
  }

  Future<void> step(Dev d) async {
    final roll = random.nextInt(100);
    final i = random.nextInt(d.engines.length);
    if (random.nextInt(6) == 0) stopIn = 1 + random.nextInt(6);
    say(() => 'step ${d.device.name} roll $roll on ${d.remotes[i]} stop in $stopIn');
    if (roll < 38) {
      stopIn = -1;
      await save(d);
    } else if (roll < 60) {
      await attempt(d, i, (e) => e.sync());
    } else if (roll < 66) {
      await attempt(d, i, (e) => e.push());
    } else if (roll < 72) {
      await attempt(d, i, (e) => e.pull());
    } else if (roll < 86) {
      // Often, and now and then several times in a row.
      for (var times = random.nextInt(4) == 0 ? 3 : 1; times > 0; times--) {
        await attempt(d, i, (e) => e.compact());
      }
    } else if (roll < 90) {
      stopIn = -1;
      await d.engines[i].trimLocal();
    } else if (roll < 95 && mode.damage) {
      stopIn = -1;
      damage();
    } else if (mode.twins) {
      final twin = d.device.newEngine(transport: d.transports[i], remote: d.remotes[i]);
      stopIn = -1;
      met.twins++;
      try {
        await Future.wait([
          d.engines[i].sync().then(note),
          (random.nextBool() ? twin.compact() : twin.sync()).then(note),
          if (random.nextBool()) save(d),
        ]);
      } on SyncTransportFailure {
        met.failures++;
        d.restart(i);
      }
    } else {
      d.restart(i);
    }
    stopIn = -1;
    await watch(d);
  }

  Future<void> settleAll(int rounds) async {
    SyncRound? last;
    for (var r = 0; r < rounds; r++) {
      var quiet = true;
      for (final d in live) {
        for (final engine in d.engines) {
          last = await engine.sync();
          note(last);
          if (!last.quiet) quiet = false;
        }
      }
      if (quiet) return;
    }
    fail('$tag did not settle in $rounds rounds: waiting ${last?.pull.waiting}, problems ${last?.pull.problems}');
  }

  Future<void> same(String when) async {
    final states = <String, List<String>>{};
    for (final d in live) {
      states.putIfAbsent(await d.device.state(), () => []).add(d.device.name);
    }
    if (states.length != 1) fail('$tag differ $when: ${states.values.toList()}\n${states.keys.join('\n---\n')}');
  }
}

Future<void> run(Directory root, int size, int seed, Mode? fixed, Met met, {bool trace = false}) async {
  final mode = fixed ?? Mode.drawn(Random(seed));
  final world = World(seed, mode, met, 'size $size seed $seed mode $mode', trace: trace);
  // With more than two, the last device joins once the others have a
  // history, part of which has been compacted away by then.
  final early = size > 2 ? size - 1 : size;
  for (var i = 0; i < early; i++) {
    await world.add(root, both: mode.second && i < 2);
  }
  for (final transport in [world.main, world.second]) {
    transport.weather = world.random;
  }
  const steps = 90;
  for (var i = 0; i < steps; i++) {
    if (i == steps * 2 ~/ 3 && early < size) {
      final joiner = await world.add(root);
      for (var k = mode.preload ? 3 : 0; k > 0; k--) {
        await world.save(joiner);
      }
    }
    if (mode.retire && i == steps ~/ 2 && world.live.length > 2) world.pick(world.live).retired = true;
    await world.step(world.pick(world.live));
  }

  for (final transport in [world.main, world.second]) {
    transport.weather = null;
  }
  world.repair();
  for (final d in world.live) {
    for (var i = 0; i < d.engines.length; i++) {
      d.restart(i);
    }
  }
  await world.settleAll(25);
  await world.same('after settling');

  final stamps = <String>{};
  for (final saved in <Record<Syncable>>[...world.entrySaves, ...world.accountSaves]) {
    if (!stamps.add('${saved.item.id} ${saved.updatedAt}')) met.ties++;
  }
  // A device that left took the saves it had not sent with it.
  if (!mode.retire) {
    final entries = show(book.entries.merge(const [], world.entrySaves..shuffle(world.random)));
    final accounts = show(book.accounts.merge(const [], world.accountSaves..shuffle(world.random)));
    final held = world.live.first.device;
    if (show(await held.storedEntries()) != entries || show(await held.storedAccounts()) != accounts) {
      fail('${world.tag} agree, but not on the merge of every save\nheld: ${await held.state()}\nwant: $accounts\n$entries');
    }
  }

  // Every engine compacts in turn until a whole turn changes nothing on the
  // remotes, which must be soon: the first turns clear up after each other
  // (a device further on in the order of ids removes the snapshot one before
  // it wrote a moment ago, which then has nothing new to write). A device
  // that joins after that holds the same.
  String stored() => '${world.main.snapshots.keys.toList()} ${world.main.batches.keys.toList()} ${world.second.snapshots.keys.toList()} ${world.second.batches.keys.toList()}';
  var turns = 0;
  for (var before = ''; before != stored(); turns++) {
    if (turns == 5) fail('${world.tag} compactions with nothing new keep changing the remote\nfrom $before\n  to ${stored()}');
    before = stored();
    for (final d in world.live) {
      for (final engine in d.engines) {
        world.note(await engine.compact());
      }
    }
  }
  if (world.main.snapshots.isEmpty) fail('${world.tag} no snapshot is left');
  final joiner = await world.add(root);
  await world.settleAll(25);
  await world.same('after compaction and a joiner');
  for (final d in world.live) {
    await world.watch(d);
  }
  if ((await joiner.device.engine.sync()).pull.waiting.isNotEmpty) fail('${world.tag} the joiner is left waiting');
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('qima_sync_convergence');
  });

  tearDown(() async {
    await BookDatabase.closeAll();
    BookDatabase.executorOverride = null;
    await root.delete(recursive: true);
  });

  final environment = Platform.environment;
  final from = int.parse(environment['SYNC_FUZZ_FROM'] ?? '0');
  final count = int.parse(environment['SYNC_FUZZ_COUNT'] ?? '24');
  final modeName = environment['SYNC_FUZZ_MODE'] ?? 'mixed';
  final fixed = modeName == 'mixed' ? null : (Mode.named[modeName] ?? (throw ArgumentError('SYNC_FUZZ_MODE: one of mixed, ${Mode.named.keys.join(', ')}')));
  final only = environment['SYNC_FUZZ_ONLY'];

  if (only != null) {
    test('the one case $only', () async {
      final [size, seed] = only.split(':').map(int.parse).toList();
      await run(Directory('${root.path}/one'), size, seed, fixed, Met(), trace: true);
    });
    return;
  }

  for (final size in [2, 3, 4, 5]) {
    test('$size devices end with the same book, the one a merge of every save gives ($modeName)', () async {
      final met = Met();
      final failures = <String>[];
      for (var seed = from; seed < from + count; seed++) {
        try {
          await run(Directory('${root.path}/$size-$seed'), size, seed * 11 + size, fixed, met);
        } on TestFailure catch (e) {
          failures.add('${e.message}');
        } catch (e, stack) {
          failures.add('size $size seed ${seed * 11 + size} threw $e\n$stack');
        }
        await BookDatabase.closeAll();
      }
      expect(failures, isEmpty, reason: '${failures.length} of $count runs failed; SYNC_FUZZ_ONLY=size:seed runs one of them again');
      // The counts below hold for the default run; a longer or narrower one
      // is judged by its failures alone.
      if (environment.keys.any((key) => key.startsWith('SYNC_FUZZ_'))) return;
      expect(met.failures, greaterThan(20), reason: 'calls the transport failed');
      expect(met.waits, greaterThan(5), reason: 'rounds that left a batch waiting');
      expect(met.problems, greaterThan(3), reason: 'rounds that met a body they could not read');
      expect(met.snapshots, greaterThan(40), reason: 'compactions that left a snapshot');
      expect(met.ties, greaterThan(40), reason: 'saves of one record with one stamp');
      expect(met.back, greaterThan(40), reason: 'saves made after a clock stepped back');
      expect(met.refused, greaterThan(40), reason: 'saves that lost to the record held and were not stored');
      expect(met.twins, greaterThan(5), reason: 'two engines at once on one database');
    }, timeout: const Timeout(Duration(minutes: 30)));
  }
}
