import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/book_account.dart';
import 'package:qima/models/book_entry.dart';
import 'package:qima/services/book_db/book_database.dart';
import 'package:qima/services/sync/sync_engine.dart';
import 'package:qima/services/sync/sync_report.dart';
import 'package:qima/services/sync/sync_transport.dart';
import 'package:qima/services/synced_store.dart';

import 'sync_support.dart' hide copyDatabase;

/// Devices that all act at once: each runs its own script of saves, rounds,
/// compactions, trims and restarts, and every call into the transport yields
/// to the others, may fail before or after its work, and may be given a
/// listing with batches and snapshot parts left out, repeated or shuffled.
/// So a round of one device overlaps a compaction of another at any point.
///
/// `SYNC_INTERLEAVED_OPTS` (or `REV_OPTS`) adds, joined by `+`: `clones`
/// (a device is copied, id and all, in the middle, and both go on), `hide`
/// (listings leave snapshot parts out), `retireLast` (the device last in the
/// order of ids stops for good half way), `offline` (one device is away for
/// half the run). Without it each seed draws its own. `..._COUNT` is the
/// number of seeds and `..._FROM` the first.
///
/// When all is quiet every device holds the same book, the one a merge of
/// every save gives (unless a device left with saves it had not sent); no
/// device took a new id unless one was copied; compactions in turn soon
/// change nothing more, a whole snapshot stands, snapshots have not piled
/// up, and a device that joins then is not left waiting.
class Boom implements Exception {
  final String step;
  const Boom(this.step);
  @override
  String toString() => 'Boom($step)';
}

/// Stores everything, loses nothing; every call yields to other callers, may
/// fail before or after its work, and a listing may leave out batches AND
/// snapshot parts, repeat names and shuffle.
class Chaos implements SyncTransport {
  final Map<SyncBatchRef, String> batches = {};
  final Map<SyncSnapshotRef, String> snapshots = {};
  Random? weather;
  bool hideSnapshots = false;
  double failure = 0.04;
  int maxSnapshotParts = 0;
  int maxBatchParts = 0;

  Future<void> _step(String step) async {
    final r = weather;
    if (r == null) return;
    for (var i = r.nextInt(3); i > 0; i--) {
      await Future<void>.delayed(Duration.zero);
    }
    if (r.nextDouble() < failure) throw Boom(step);
  }

  void _note() {
    maxSnapshotParts = max(maxSnapshotParts, snapshots.length);
    maxBatchParts = max(maxBatchParts, batches.length);
  }

  @override
  Future<bool> append(SyncBatchRef ref, String body) async {
    await _step('append');
    final ok = batches.putIfAbsent(ref, () => body) == body;
    _note();
    await _step('append.done');
    return ok;
  }

  @override
  Future<bool> writeSnapshot(SyncSnapshotRef ref, String body) async {
    await _step('writeSnapshot');
    final ok = snapshots.putIfAbsent(ref, () => body) == body;
    _note();
    await _step('writeSnapshot.done');
    return ok;
  }

  @override
  Future<SyncListing> list({required Map<String, int> after}) async {
    await _step('list');
    final r = weather;
    final out = <SyncBatchRef>[];
    for (final ref in batches.keys.toList()) {
      if (ref.last <= (after[ref.device] ?? 0)) continue;
      if (r != null && r.nextDouble() < 0.25) continue;
      out.add(ref);
      if (r != null && r.nextDouble() < 0.2) out.add(ref);
    }
    final snaps = <SyncSnapshotRef>[];
    for (final ref in snapshots.keys.toList()) {
      if (r != null && hideSnapshots && r.nextDouble() < 0.25) continue;
      snaps.add(ref);
    }
    if (r != null) {
      out.shuffle(r);
      snaps.shuffle(r);
    }
    return SyncListing(batches: out, snapshots: snaps);
  }

  @override
  Future<String?> read(SyncBatchRef ref) async {
    await _step('read');
    return batches[ref];
  }

  @override
  Future<String?> readSnapshot(SyncSnapshotRef ref) async {
    await _step('readSnapshot');
    return snapshots[ref];
  }

  @override
  Future<void> discard({required Map<String, int> batchesThrough, required Iterable<SyncSnapshotRef> snapshots}) async {
    await _step('discard');
    batches.removeWhere((ref, _) => ref.last <= (batchesThrough[ref.device] ?? 0));
    snapshots.toList().forEach(this.snapshots.remove);
    await _step('discard.done');
  }

  /// The snapshots of which every part is stored.
  Set<String> get whole {
    final by = <String, Set<int>>{};
    final want = <String, int>{};
    for (final ref in snapshots.keys) {
      by.putIfAbsent(ref.snapshot, () => {}).add(ref.part);
      want[ref.snapshot] = ref.parts;
    }
    return {for (final e in by.entries) if (e.value.length == want[e.key]) e.key};
  }
}

class Actor {
  final Device device;
  SyncEngine engine;
  int clock;
  bool retired = false;
  bool offline = false;
  final Map<String, String> places = {};
  Actor(this.device, this.clock) : engine = device.engine;
  void restart() => engine = device.newEngine();
}

const _tables = ['meta', 'documents', 'entries', 'entry_lines', 'changes'];

Future<void> copyDatabase(BookDatabase from, BookDatabase to) async {
  for (final table in _tables) {
    await to.customStatement('DELETE FROM $table');
    final rows = await from.customSelect('SELECT * FROM $table').get();
    for (final row in rows) {
      final cols = row.data.keys.toList();
      await to.customStatement('INSERT INTO $table (${cols.join(', ')}) VALUES (${List.filled(cols.length, '?').join(', ')})', [for (final c in cols) row.data[c]]);
    }
  }
  final seq = await from.customSelect("SELECT seq FROM sqlite_sequence WHERE name = 'changes'").get();
  await to.customStatement("DELETE FROM sqlite_sequence WHERE name = 'changes'");
  if (seq.isNotEmpty) await to.customStatement("INSERT INTO sqlite_sequence (name, seq) VALUES ('changes', ?)", [seq.single.data['seq']]);
}

class Opts {
  final bool clones;
  final bool hideSnapshots;
  final bool retireLast;
  final bool offline;
  const Opts({this.clones = false, this.hideSnapshots = false, this.retireLast = false, this.offline = false});
  @override
  String toString() => [if (clones) 'clones', if (hideSnapshots) 'hide', if (retireLast) 'retireLast', if (offline) 'offline'].join('+');
}

class Stats {
  int rekeys = 0, booms = 0, snapshots = 0, waits = 0, clones = 0, maxSnap = 0, maxBatch = 0, finalSnap = 0, finalBatch = 0, runs = 0;
  @override
  String toString() => 'runs $runs rekeys $rekeys booms $booms snapshots $snapshots waits $waits clones $clones maxSnapParts $maxSnap maxBatchParts $maxBatch finalSnapParts(sum) $finalSnap finalBatchParts(sum) $finalBatch';
}

class World {
  final Random random;
  final Opts opts;
  final String tag;
  final Directory root;
  final Stats stats;
  final Chaos remote = Chaos();
  final List<Actor> actors = [];
  final List<Future<void>> running = [];
  final List<Record<BookEntry>> entrySaves = [];
  final List<Record<BookAccount>> accountSaves = [];
  final List<String> trace = [];
  int made = 0;
  int tick = 0;
  final int steps;

  World(int seed, this.opts, this.root, this.stats, this.steps) : random = Random(seed), tag = 'seed $seed opts $opts';

  void say(String s) {
    trace.add(s);
    if (trace.length > 400) trace.removeAt(0);
  }

  T pick<T>(List<T> from) => from[random.nextInt(from.length)];

  Future<Actor> add({Actor? cloneOf}) async {
    final name = 'd${made++}';
    final device = await Device.open(root, name, remote, partBytes: 900, id: cloneOf == null ? '' : null);
    if (cloneOf != null) {
      await copyDatabase(cloneOf.device.db, device.db);
      stats.clones++;
    }
    final actor = Actor(device, cloneOf?.clock ?? random.nextInt(6));
    actors.add(actor);
    return actor;
  }

  Future<void> save(Actor a) async {
    final move = random.nextInt(10);
    if (move < 6) {
      a.clock += 1 + random.nextInt(2);
    } else if (move >= 8) {
      a.clock = max(0, a.clock - random.nextInt(4));
    }
    final deleted = random.nextInt(4) == 0;
    final order = random.nextInt(2).toDouble();
    final kind = random.nextInt(10);
    if (kind < 7) {
      final item = kind < 4
          ? spend(pick(const ['e0', 'e1', 'e2', 'e3', 'e4', 'e5']), 100 + random.nextInt(3), merchant: pick(const ['Cafe', 'Shop', 'A much longer merchant name to make bodies larger than one part of nine hundred bytes']))
          : trade(pick(const ['t0', 't1']), 500 + random.nextInt(2), tradeMs: random.nextBool() ? random.nextInt(3) : null, cashMs: random.nextBool() ? random.nextInt(3) : null);
      final record = rec(item, a.clock, order: order, deleted: deleted);
      entrySaves.add(record);
      await a.device.putEntry(record);
      say('${a.device.name} save ${item.id}@${a.clock}');
    } else {
      final record = rec(account(pick(const ['a0', 'a1', 'a2']), pick(const ['Bank', 'Cash'])), a.clock, order: order, deleted: deleted);
      accountSaves.add(record);
      await a.device.putAccount(record);
      say('${a.device.name} save ${record.item.id}@${a.clock}');
    }
  }

  void note(Actor a, Object? result) {
    final pull = switch (result) { SyncRound r => r.pull, SyncPull p => p, SyncCompaction c => c.round.pull, _ => null };
    if (pull != null && pull.rekeyed) {
      stats.rekeys++;
      if (!opts.clones) fail('$tag ${a.device.name} re-keyed though no database was ever copied\n${trace.join('\n')}');
    }
    if (pull != null && pull.waiting.isNotEmpty) stats.waits++;
    if (result is SyncCompaction && result.snapshot != null) stats.snapshots++;
  }

  Future<void> attempt(Actor a, String what, Future<Object?> Function(SyncEngine e) run) async {
    say('${a.device.name} $what ...');
    try {
      final result = await run(a.engine).timeout(const Duration(seconds: 30), onTimeout: () => fail('$tag ${a.device.name} $what did not end\n${trace.join('\n')}'));
      note(a, result);
      say('${a.device.name} $what done ${switch (result) { SyncRound r => 'applied ${r.pull.applied} sent ${r.push.sent} waiting ${r.pull.waiting} rekeyed ${r.pull.rekeyed}', SyncCompaction c => 'snapshot ${c.snapshot} trimmed ${c.trimmed}', SyncPull p => 'applied ${p.applied} waiting ${p.waiting}', SyncPush p => 'sent ${p.sent}', _ => '' }}');
    } on Boom catch (e) {
      stats.booms++;
      say('${a.device.name} $what $e');
      a.restart();
    }
  }

  Future<void> watch(Actor a) async {
    final db = a.device.db;
    final rows = await db.customSelect("SELECT key, value FROM meta WHERE key LIKE 'sync.%'").get();
    final now = {for (final row in rows) row.data['key'] as String: row.data['value'] as String};
    final rekeyed = a.places[SyncEngine.deviceKey] != null && a.places[SyncEngine.deviceKey] != now[SyncEngine.deviceKey];
    for (final e in now.entries) {
      final before = a.places[e.key];
      if (before != null && !rekeyed && e.key.startsWith('sync.out.')) {
        final was = jsonDecode(before) as Map<String, dynamic>;
        final is_ = jsonDecode(e.value) as Map<String, dynamic>;
        for (final f in ['scanned', 'shipped']) {
          if ((is_[f] as int) < (was[f] as int)) fail('$tag ${a.device.name} ${e.key} $f went back $before -> ${e.value}');
        }
      } else if (before != null && e.key.startsWith('sync.in.')) {
        final was = (jsonDecode(before) as Map<String, dynamic>)['batches'] as Map<String, dynamic>;
        final is_ = (jsonDecode(e.value) as Map<String, dynamic>)['batches'] as Map<String, dynamic>;
        for (final w in was.keys) {
          if (((is_[w] as List<dynamic>?)?[1] as int? ?? -1) < ((was[w] as List<dynamic>)[1] as int)) fail('$tag ${a.device.name} ${e.key} went back for $w: $before -> ${e.value}');
        }
      }
    }
    a.places
      ..clear()
      ..addAll(now);
  }

  /// A trim must leave every row that has not been looked at for the remote.
  Future<void> trim(Actor a) async {
    final db = a.device.db;
    final out = await a.device.meta('sync.out.main');
    if (out == null) return;
    final scanned = (jsonDecode(out) as Map<String, dynamic>)['scanned'] as int;
    final pending = [for (final r in await db.customSelect('SELECT seq FROM changes ORDER BY seq').get()) if ((r.data['seq'] as int) > scanned) r.data['seq'] as int];
    await a.engine.trimLocal();
    final after = {for (final r in await db.customSelect('SELECT seq FROM changes ORDER BY seq').get()) r.data['seq'] as int};
    if (!pending.every(after.contains)) fail('$tag ${a.device.name} trim removed unsent rows');
  }

  Future<void> act(Actor a) async {
    for (var i = 0; i < steps; i++) {
      tick++;
      for (var y = random.nextInt(3); y > 0; y--) {
        await Future<void>.delayed(Duration.zero);
      }
      if (a.retired) return;
      if (a.offline) continue;
      final roll = random.nextInt(100);
      if (roll < 34) {
        await save(a);
      } else if (roll < 54) {
        await attempt(a, 'sync', (e) => e.sync());
      } else if (roll < 60) {
        await attempt(a, 'push', (e) => e.push());
      } else if (roll < 66) {
        await attempt(a, 'pull', (e) => e.pull());
      } else if (roll < 88) {
        for (var times = random.nextInt(4) == 0 ? 3 : 1; times > 0; times--) {
          await attempt(a, 'compact', (e) => e.compact());
        }
      } else if (roll < 92) {
        await trim(a);
      } else if (roll < 95 && opts.clones && made < 7) {
        final copy = await add(cloneOf: a);
        say('${copy.device.name} is a copy of ${a.device.name}');
        running.add(act(copy));
      } else {
        a.restart();
      }
      await watch(a);
    }
  }

  List<Actor> get live => [for (final a in actors) if (!a.retired) a];

  Future<void> settle(int rounds) async {
    SyncRound? last;
    for (var r = 0; r < rounds; r++) {
      var quiet = true;
      for (final a in live) {
        last = await a.engine.sync();
        note(a, last);
        say('${a.device.name} settle applied ${last.pull.applied} sent ${last.push.sent} waiting ${last.pull.waiting} problems ${last.pull.problems} rekeyed ${last.pull.rekeyed}');
        if (!last.quiet) quiet = false;
      }
      if (quiet) return;
    }
    fail('$tag did not settle: waiting ${last?.pull.waiting} problems ${last?.pull.problems} | batches ${remote.batches.keys.toList()} | retired ${[for (final a in actors) if (a.retired) a.device.name]} | ${trace.where((t) => t.contains('push') || t.contains('retire') || t.contains('Boom')).toList().reversed.take(12).toList()}');
  }

  Future<void> same(String when) async {
    final states = <String, List<String>>{};
    for (final a in live) {
      states.putIfAbsent(await a.device.state(), () => []).add(a.device.name);
    }
    if (states.length != 1) fail('$tag differ $when: ${states.values.toList()}\n${states.keys.join('\n---\n')}\nremote batches ${remote.batches.keys.toList()}\nsnapshots ${remote.snapshots.keys.toList()}\n${Platform.environment['REV_TRACE'] != null ? trace.join('\n') : ''}');
  }
}

Future<void> run(Directory root, int seed, int size, Opts opts, Stats stats) async {
  final world = World(seed, opts, root, stats, 45);
  stats.runs++;
  for (var i = 0; i < size; i++) {
    await world.add();
  }
  world.remote.weather = world.random;
  world.remote.hideSnapshots = opts.hideSnapshots;
  for (final a in world.actors.toList()) {
    world.running.add(world.act(a));
  }
  // Someone to drive what happens to devices from outside.
  var done = false;
  final driver = () async {
    final sleeper = opts.offline ? world.actors[world.random.nextInt(size)] : null;
    var slept = false, woke = false, retired = false;
    while (!done) {
      await Future<void>.delayed(Duration.zero);
      final t = world.tick / (size * 45);
      if (sleeper != null && !slept && t > 0.2) {
        sleeper.offline = true;
        slept = true;
        world.say('${sleeper.device.name} goes offline');
      }
      if (sleeper != null && !woke && t > 0.7) {
        sleeper.offline = false;
        woke = true;
        world.say('${sleeper.device.name} is back');
      }
      if (opts.retireLast && !retired && t > 0.5) {
        final last = world.actors.sublist(0, size).reduce((a, b) => a.device.name.compareTo(b.device.name) > 0 ? a : b);
        last.retired = true;
        retired = true;
        world.say('${last.device.name} retires');
      }
    }
  }();
  var waited = 0;
  while (waited < world.running.length) {
    await world.running[waited++];
  }
  done = true;
  await driver;
  for (final a in world.actors) {
    a.offline = false;
  }
  world.remote.weather = null;
  for (final a in world.live) {
    a.restart();
  }
  stats.maxSnap = max(stats.maxSnap, world.remote.maxSnapshotParts);
  stats.maxBatch = max(stats.maxBatch, world.remote.maxBatchParts);
  await world.settle(30);
  await world.same('after settling');
  if (!opts.retireLast) {
    final entries = show(book.entries.merge(const [], world.entrySaves..shuffle(world.random)));
    final accounts = show(book.accounts.merge(const [], world.accountSaves..shuffle(world.random)));
    final held = world.live.first.device;
    if (show(await held.storedEntries()) != entries || show(await held.storedAccounts()) != accounts) {
      fail('${world.tag} agree, but not on the merge of every save\nheld: ${await held.state()}\nwant: $accounts\n$entries');
    }
  }
  // Every device compacts in turn until a whole turn changes nothing on the
  // remote. The first turns clear up after each other (a device further on
  // in the order of ids removes the snapshot one before it wrote a moment
  // ago, which then has nothing new to write); it must not go on.
  String stored() => '${world.remote.snapshots.keys.toList()} ${world.remote.batches.keys.toList()}';
  var turns = 0;
  for (var before = ''; before != stored(); turns++) {
    if (turns == 5) fail('${world.tag} compactions with nothing new keep changing the remote\nfrom $before\n  to ${stored()}\nids ${[for (final a in world.live) '${a.device.name}=${await a.engine.deviceId()}']}');
    before = stored();
    for (final a in world.live) {
      world.note(a, await a.engine.compact());
    }
  }
  if (world.remote.whole.isEmpty) fail('${world.tag} no whole snapshot is left: ${world.remote.snapshots.keys.toList()}');
  stats.finalSnap += world.remote.snapshots.length;
  stats.finalBatch += world.remote.batches.length;
  if (world.remote.whole.length > world.actors.length + 1) fail('${world.tag} snapshots pile up: ${world.remote.snapshots.keys.toList()} for ${world.actors.length} databases');
  final joiner = await world.add();
  await world.settle(30);
  await world.same('after compaction and a joiner');
  if ((await joiner.engine.sync()).pull.waiting.isNotEmpty) fail('${world.tag} the joiner is left waiting');
}

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('rev_b_fuzz'));
  tearDown(() async {
    await BookDatabase.closeAll();
    BookDatabase.executorOverride = null;
    await root.delete(recursive: true);
  });

  final env = Platform.environment;
  String? setting(String name) => env['SYNC_INTERLEAVED_$name'] ?? env['REV_$name'];
  final from = int.parse(setting('FROM') ?? '0');
  final count = int.parse(setting('COUNT') ?? '32');
  final given = setting('OPTS')?.split('+').toSet();
  Opts optsOf(int seed) {
    final random = Random(seed * 31 + 7);
    bool has(String name) => given == null ? random.nextInt(3) == 0 : given.contains(name);
    return Opts(clones: has('clones'), hideSnapshots: has('hide'), retireLast: has('retireLast'), offline: has('offline'));
  }

  test('devices that act at once end with one book (${given == null ? 'what each seed draws' : given.join('+')})', () async {
    final stats = Stats();
    final failures = <String>[];
    for (var seed = from; seed < from + count; seed++) {
      final size = 2 + seed % 3;
      try {
        await run(Directory('${root.path}/$seed'), seed, size, optsOf(seed), stats);
      } on TestFailure catch (e) {
        failures.add('${e.message}');
      } catch (e, stack) {
        failures.add('seed $seed threw $e\n$stack');
      }
      await BookDatabase.closeAll();
    }
    final first = failures.isEmpty ? '' : failures.first;
    expect(failures, isEmpty, reason: '${failures.length} of $count seeds failed ($stats), the first:\n${first.length > 3000 ? first.substring(0, 3000) : first}');
    // The counts below hold for the default run; a longer or narrower one
    // is judged by its failures alone.
    if (env.keys.any((key) => key.startsWith('SYNC_INTERLEAVED_') || key.startsWith('REV_'))) return;
    expect(stats.booms, greaterThan(20), reason: 'calls the transport failed');
    expect(stats.snapshots, greaterThan(20), reason: 'compactions that left a snapshot');
    expect(stats.clones, greaterThan(2), reason: 'databases that were copied');
    expect(stats.rekeys, greaterThan(0), reason: 'copies that took a new id');
  }, timeout: const Timeout(Duration(minutes: 30)));
}
