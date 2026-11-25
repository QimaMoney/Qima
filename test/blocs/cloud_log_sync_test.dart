import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:qima/blocs/app_blocs.dart';
import 'package:qima/blocs/cloud_log_sync.dart';
import 'package:qima/blocs/cloud_log_sync_state.dart';
import 'package:qima/services/book_store.dart';
import 'package:qima/services/preferences.dart';
import 'package:qima/services/sync/cloudkit_sync_transport.dart';
import 'package:qima/services/sync/sync_report.dart';
import 'package:qima/services/sync/sync_transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/app_blocs.dart';
import '../helpers/fake_clock.dart';
import '../services/sync/memory_sync_transport.dart';

SyncRound round({int applied = 0, int sent = 0, bool rekeyed = false, List<SyncBatchRef> waiting = const [], List<SyncProblem> problems = const []}) =>
    SyncRound(SyncPull(applied: applied, rekeyed: rekeyed, waiting: waiting, problems: problems), SyncPush(sent: sent));

/// An engine that does what a test tells it and records when it was called.
class FakeLog implements BookChangeLog {
  final FakeClock clock;
  final String remote;
  final List<DateTime> syncs = [];
  final List<DateTime> compactions = [];
  int running = 0;
  int mostAtOnce = 0;

  /// What the next calls do; the last entry is kept for the calls after it.
  final List<Future<SyncRound> Function()> script = [];

  FakeLog(this.clock, this.remote);

  @override
  Future<SyncRound> sync() async {
    syncs.add(clock.now);
    running++;
    if (running > mostAtOnce) mostAtOnce = running;
    try {
      final step = script.length > 1 ? script.removeAt(0) : (script.isEmpty ? () async => round() : script.first);
      return await step();
    } finally {
      running--;
    }
  }

  @override
  Future<SyncCompaction> compact() async {
    compactions.add(clock.now);
    running++;
    if (running > mostAtOnce) mostAtOnce = running;
    try {
      await Future<void>.delayed(Duration.zero);
      return SyncCompaction(snapshot: null, trimmed: 0, round: round());
    } finally {
      running--;
    }
  }
}

CloudSyncException failure(CloudSyncFailure kind, {Duration? retryAfter}) => CloudSyncException(kind, 'test', retryAfter: retryAfter);

late FakeClock clock;
late Preferences preferences;
late BookStore store;
late Map<String, FakeLog> logs;
late int reloads;
late int accountCalls;
late int availableCalls;
late String account;
late bool available;
late CloudLogSync sync;
Future<void> Function() reloadBody = () async {};
late List<CloudLogSyncState> states;

FakeLog get log => logs.values.last;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();


  /// A CloudLogSync over fake engines, started with the switch [on].
  Future<void> build({bool on = true, bool loaded = true}) async {
    reloadBody = () async {};
    SharedPreferences.setMockInitialValues({});
    preferences = await Preferences.create();
    if (on) await preferences.setCloudLogSyncEnabled(true);
    clock = FakeClock();
    store = BookStore();
    logs = {};
    reloads = 0;
    accountCalls = 0;
    availableCalls = 0;
    account = 'account-one';
    available = true;
    sync = CloudLogSync(
      store: store,
      transport: MemorySyncTransport(),
      available: () async {
        availableCalls++;
        return available;
      },
      account: () async {
        accountCalls++;
        return account;
      },
      reload: () async {
        await reloadBody();
        reloads++;
      },
      now: () => clock.now,
      timer: clock.timer,
      changeLogFor: (remote) => logs[remote] = FakeLog(clock, remote),
    );
    states = [];
    sync.stream.listen(states.add);
    await sync.start(preferences);
    if (loaded) sync.bookLoaded();
    await pumpEventQueue();
  }

  tearDown(() async {
    await sync.close();
  });

  group('whether it runs at all', () {
    test('it is off by default, and then nothing is called: no transport, no account, no engine', () async {
      final transport = _CountingTransport();
      SharedPreferences.setMockInitialValues({});
      preferences = await Preferences.create();
      expect(preferences.cloudLogSyncEnabled, isFalse);
      clock = FakeClock();
      var asked = 0;
      var named = 0;
      sync = CloudLogSync(
        store: BookStore(),
        transport: transport,
        available: () async {
          asked++;
          return true;
        },
        account: () async {
          named++;
          return 'account-one';
        },
        reload: () async => fail('nothing was taken in'),
        now: () => clock.now,
        timer: clock.timer,
      );
      await sync.start(preferences);
      sync.bookLoaded();
      sync.noteLocalChange();
      await sync.resumed();
      await clock.advance(const Duration(hours: 3));
      sync.paused();
      await sync.resumed();
      await clock.advance(const Duration(hours: 3));

      expect(transport.calls, isEmpty);
      expect(named, 0);
      expect(clock.pending, 0, reason: 'no timer is left running');
      expect(sync.state.phase, CloudLogPhase.off);
      expect(sync.state.offered, isTrue);
      expect(sync.state.enabled, isFalse);
      expect(asked, greaterThan(0), reason: 'the switch is offered only where CloudKit can be used');
    });

    test('where CloudKit cannot be used the switch is not offered and nothing runs, even when the preference is on', () async {
      await build(on: false);
      await sync.close();
      SharedPreferences.setMockInitialValues({});
      preferences = await Preferences.create();
      await preferences.setCloudLogSyncEnabled(true);
      clock = FakeClock();
      logs = {};
      sync = CloudLogSync(
        store: BookStore(),
        transport: MemorySyncTransport(),
        available: () async => false,
        account: () async => fail('no account is asked for'),
        reload: () async => fail('nothing is reloaded'),
        now: () => clock.now,
        timer: clock.timer,
        changeLogFor: (remote) => logs[remote] = FakeLog(clock, remote),
      );
      await sync.start(preferences);
      sync.bookLoaded();
      await sync.resumed();
      await clock.advance(const Duration(hours: 1));
      expect(sync.state.phase, CloudLogPhase.unavailable);
      expect(sync.state.offered, isFalse);
      expect(logs, isEmpty);
    });

    test('an availability check that throws counts as unavailable', () async {
      SharedPreferences.setMockInitialValues({});
      preferences = await Preferences.create();
      clock = FakeClock();
      sync = CloudLogSync(
        store: BookStore(),
        transport: MemorySyncTransport(),
        available: () async => throw StateError('no binding'),
        account: () async => 'x',
        reload: () async {},
        now: () => clock.now,
        timer: clock.timer,
      );
      await sync.start(preferences);
      expect(sync.state.phase, CloudLogPhase.unavailable);
    });
  });

  group('when a round runs', () {
    test('once after start-up when the book has loaded and the switch is on, and not before the book has loaded', () async {
      await build(loaded: false);
      expect(logs, isEmpty);
      expect(clock.pending, 0);
      sync.bookLoaded();
      await sync.idle;
      expect(log.syncs, hasLength(1));
      expect(sync.state.phase, CloudLogPhase.upToDate);
      expect(sync.state.at, clock.now);
    });

    test('after a change to the book, five seconds after the last of a burst, as one round', () async {
      await build();
      await sync.idle;
      expect(log.syncs, hasLength(1));
      for (var i = 0; i < 4; i++) {
        sync.noteLocalChange();
        await clock.advance(const Duration(seconds: 3));
      }
      expect(log.syncs, hasLength(1), reason: 'each change moves the round further off');
      await clock.advance(const Duration(seconds: 3));
      expect(log.syncs, hasLength(2));
      await clock.advance(const Duration(seconds: 20));
      expect(log.syncs, hasLength(2), reason: 'a burst is one round');
    });

    test('a change reported by the store reaches it', () async {
      await build();
      await sync.idle;
      store.entries.onSaved!();
      await clock.advance(const Duration(seconds: 6));
      expect(log.syncs, hasLength(2));
    });

    test('when the app returns to the foreground, and the clock only runs while it is there', () async {
      await build();
      await sync.idle;
      sync.paused();
      await clock.advance(const Duration(minutes: 20));
      expect(log.syncs, hasLength(1), reason: 'nothing runs in the background');
      await sync.resumed();
      await sync.idle;
      expect(log.syncs, hasLength(2));
      await clock.advance(const Duration(minutes: 5));
      expect(log.syncs, hasLength(3));
    });

    test('every five minutes in the foreground', () async {
      await build();
      await sync.idle;
      await clock.advance(const Duration(minutes: 4, seconds: 59));
      expect(log.syncs, hasLength(1));
      await clock.advance(const Duration(seconds: 1));
      expect(log.syncs, hasLength(2));
      await clock.advance(const Duration(minutes: 10));
      expect(log.syncs, hasLength(4));
    });

    test('never two at once, and requests during a round make exactly one more', () async {
      await build();
      await sync.idle;
      final gate = Completer<void>();
      log.script
        ..clear()
        ..add(() async {
          await gate.future;
          return round();
        })
        ..add(() async => round());
      sync.noteLocalChange();
      await clock.advance(const Duration(seconds: 6));
      expect(log.running, 1);
      // Three more requests while it runs.
      sync.noteLocalChange();
      await clock.advance(const Duration(seconds: 6));
      await sync.resumed();
      sync.noteLocalChange();
      await clock.advance(const Duration(seconds: 6));
      expect(log.syncs, hasLength(2), reason: 'the first round and nothing else yet');
      gate.complete();
      await sync.idle;
      expect(log.syncs, hasLength(3), reason: 'one more, not three');
      expect(log.mostAtOnce, 1);
    });

    test('a compaction is never beside a round', () async {
      await build();
      await sync.idle;
      await clock.advance(const Duration(minutes: 5));
      await sync.idle;
      expect(log.compactions, hasLength(1));
      expect(log.mostAtOnce, 1);
    });

    test('the state tells what it is doing', () async {
      await build();
      await sync.idle;
      expect(states.map((s) => s.phase), [CloudLogPhase.syncing, CloudLogPhase.upToDate]);
      expect(states.last, CloudLogSyncState(phase: CloudLogPhase.upToDate, at: clock.now));
    });

    test('a round that leaves something of another device undone is waiting, not up to date', () async {
      await build();
      await sync.idle;
      log.script
        ..clear()
        ..add(() async => round(waiting: [const SyncBatchRef(writer: 'w', device: 'aa', prev: 3, last: 8)]));
      await sync.resumed();
      await sync.idle;
      expect(sync.state.phase, CloudLogPhase.waiting);
    });

    test('a later build on another device is a problem to update for', () async {
      await build();
      await sync.idle;
      log.script
        ..clear()
        ..add(() async => round(problems: [const SyncProblem(SyncProblemKind.newerVersion, 'x')]));
      await sync.resumed();
      await sync.idle;
      expect(sync.state, const CloudLogSyncState(phase: CloudLogPhase.problem, problem: CloudLogProblem.newerVersion));
    });
  });

  group('what a round took in', () {
    test('the book is reloaded only when something was applied or the device was given a new id', () async {
      await build();
      await sync.idle;
      expect(reloads, 0);
      await sync.resumed();
      await sync.idle;
      expect(reloads, 0, reason: 'a round that sent something took nothing in');
      log.script
        ..clear()
        ..add(() async => round(sent: 3))
        ..add(() async => round(applied: 2))
        ..add(() async => round(rekeyed: true))
        ..add(() async => round());
      for (final expected in [0, 1, 2, 2]) {
        await sync.resumed();
        await sync.idle;
        expect(reloads, expected);
      }
    });

    test('a reload that failed is made again after the next round, though that round took in nothing', () async {
      await build();
      await sync.idle;
      var failing = true;
      reloadBody = () async {
        if (failing) throw StateError('reload');
      };
      log.script
        ..clear()
        ..add(() async => round(applied: 1))
        ..add(() async => round());
      await sync.resumed();
      await sync.idle;
      expect(sync.state.problem, CloudLogProblem.other, reason: 'said, not swallowed');
      expect(reloads, 0);
      failing = false;
      await clock.advance(const Duration(minutes: 5));
      await sync.idle;
      expect(reloads, 1, reason: 'owed, and made though this round moved nothing');
      await clock.advance(const Duration(minutes: 5));
      await sync.idle;
      expect(reloads, 1);
    });
  });

  group('when it fails', () {
    test('a failure to reach iCloud ends the round quietly, and the next trigger tries again', () async {
      await build();
      await sync.idle;
      log.script
        ..clear()
        ..add(() async => throw failure(CloudSyncFailure.network))
        ..add(() async => round());
      sync.noteLocalChange();
      await clock.advance(const Duration(seconds: 6));
      await sync.idle;
      expect(sync.state, const CloudLogSyncState(phase: CloudLogPhase.problem, problem: CloudLogProblem.offline));
      await clock.advance(const Duration(minutes: 1));
      await sync.idle;
      expect(sync.state.phase, CloudLogPhase.upToDate);
    });

    test('retryAfter is honoured: no round before it has passed, whatever asks', () async {
      await build();
      await sync.idle;
      log.script
        ..clear()
        ..add(() async => throw failure(CloudSyncFailure.network, retryAfter: const Duration(minutes: 12)))
        ..add(() async => round());
      final failedAt = clock.now.add(const Duration(minutes: 5));
      await clock.advance(const Duration(minutes: 5));
      await sync.idle;
      expect(log.syncs.last, failedAt);
      final count = log.syncs.length;
      sync.noteLocalChange();
      await clock.advance(const Duration(seconds: 6));
      await sync.resumed();
      await clock.advance(const Duration(minutes: 5));
      expect(log.syncs, hasLength(count), reason: 'asked three ways, and still waiting');
      await clock.advance(const Duration(minutes: 7));
      await sync.idle;
      expect(log.syncs, hasLength(count + 1));
      expect(log.syncs.last, failedAt.add(const Duration(minutes: 12)));
    });

    test('repeated failures to reach iCloud are tried at doubling intervals, up to half an hour', () async {
      await build();
      await sync.idle;
      log.script
        ..clear()
        ..add(() async => throw failure(CloudSyncFailure.network));
      final start = clock.now;
      sync.noteLocalChange();
      await clock.advance(const Duration(hours: 5));
      final tries = log.syncs.where((t) => t.isAfter(start)).toList();
      final gaps = [for (var i = 1; i < tries.length; i++) tries[i].difference(tries[i - 1]).inSeconds];
      expect(gaps.take(7), [60, 120, 240, 480, 960, 1800, 1800]);
      expect(gaps.every((g) => g <= 1800), isTrue);
    });

    test('a success ends the back-off, and the next failure starts from the first interval again', () async {
      await build();
      await sync.idle;
      log.script
        ..clear()
        ..add(() async => throw failure(CloudSyncFailure.network))
        ..add(() async => throw failure(CloudSyncFailure.network))
        ..add(() async => round())
        ..add(() async => throw failure(CloudSyncFailure.network))
        ..add(() async => round());
      final start = clock.now;
      sync.noteLocalChange();
      await clock.advance(const Duration(minutes: 4));
      expect(log.syncs.where((t) => t.isAfter(start)), hasLength(3), reason: 'failed, failed after a minute, went through after two more');
      sync.noteLocalChange();
      await clock.advance(const Duration(seconds: 6));
      await sync.idle;
      final failed = log.syncs.last;
      await clock.advance(const Duration(seconds: 58));
      expect(log.syncs.last, failed);
      await clock.advance(const Duration(seconds: 2));
      expect(log.syncs.last.difference(failed), const Duration(minutes: 1));
    });

    for (final (kind, problem) in [
      (CloudSyncFailure.quota, CloudLogProblem.quota),
      (CloudSyncFailure.notSignedIn, CloudLogProblem.notSignedIn),
      (CloudSyncFailure.unavailable, CloudLogProblem.unavailable),
      (CloudSyncFailure.zoneMissing, CloudLogProblem.zoneMissing),
      (CloudSyncFailure.other, CloudLogProblem.other),
    ]) {
      test('${kind.name} is kept as a status the settings row shows, with no dialog and no other effect', () async {
        await build();
        await sync.idle;
        log.script
          ..clear()
          ..add(() async => throw failure(kind));
        sync.noteLocalChange();
        await clock.advance(const Duration(seconds: 6));
        await sync.idle;
        expect(sync.state, CloudLogSyncState(phase: CloudLogPhase.problem, problem: problem));
        expect(reloads, 0);
      });
    }

    test('an error that is not iCloud\'s is a status too, not silence', () async {
      await build();
      await sync.idle;
      log.script
        ..clear()
        ..add(() async => throw StateError('the engine'));
      sync.noteLocalChange();
      await clock.advance(const Duration(seconds: 6));
      await sync.idle;
      expect(sync.state.problem, CloudLogProblem.other);
    });

    test('a failure to name the account ends the round like any other', () async {
      await build();
      await sync.idle;
      await sync.close();
      sync = CloudLogSync(
        store: BookStore(),
        transport: MemorySyncTransport(),
        available: () async => true,
        account: () async => throw failure(CloudSyncFailure.notSignedIn),
        reload: () async {},
        now: () => clock.now,
        timer: clock.timer,
        changeLogFor: (remote) => fail('no engine without an account'),
      );
      await sync.start(preferences);
      sync.bookLoaded();
      await sync.idle;
      expect(sync.state.problem, CloudLogProblem.notSignedIn);
    });
  });

  group('compaction', () {
    test('never on the first round after the switch is turned on, then at most once a day, and only after a quiet round', () async {
      await build();
      await sync.idle;
      expect(log.compactions, isEmpty, reason: 'the first round');
      await clock.advance(const Duration(minutes: 5));
      await sync.idle;
      expect(log.compactions, hasLength(1));
      for (var i = 0; i < 20; i++) {
        await clock.advance(const Duration(minutes: 5));
      }
      expect(log.compactions, hasLength(1), reason: 'not twice in a day');
      expect(preferences.cloudLogCompactedAt, isNotNull);
      await clock.advance(const Duration(hours: 24));
      await sync.idle;
      expect(log.compactions, hasLength(2));
    });

    test('not after a round that moved something, and when it is due the next quiet round does it', () async {
      await build();
      await sync.idle;
      log.script
        ..clear()
        ..add(() async => round(sent: 1))
        ..add(() async => round(applied: 1))
        ..add(() async => round(waiting: [const SyncBatchRef(writer: 'w', device: 'aa', prev: 3, last: 8)]))
        ..add(() async => round());
      for (var i = 0; i < 3; i++) {
        await clock.advance(const Duration(minutes: 5));
        await sync.idle;
      }
      expect(log.compactions, isEmpty);
      await clock.advance(const Duration(minutes: 5));
      await sync.idle;
      expect(log.compactions, hasLength(1));
    });

    test('turning the switch off and on again makes the next round a first round', () async {
      await build();
      await sync.idle;
      await clock.advance(const Duration(minutes: 5));
      expect(log.compactions, hasLength(1));
      await preferences.setCloudLogCompactedAt(clock.now.subtract(const Duration(days: 3)));
      await sync.setEnabled(false);
      await sync.setEnabled(true);
      await sync.idle;
      expect(log.compactions, hasLength(1), reason: 'the first round since it was turned on');
      await clock.advance(const Duration(minutes: 5));
      await sync.idle;
      expect(log.compactions, hasLength(2));
    });

    test('the time of the last one is kept in the preferences of this device', () async {
      await build();
      await sync.idle;
      await clock.advance(const Duration(minutes: 5));
      await sync.idle;
      expect(preferences.cloudLogCompactedAt, clock.now);
    });
  });

  group('switching off and closing', () {
    test('switching off stops the timers and lets a running round finish, which takes in what it was sent but shows no result', () async {
      await build();
      await sync.idle;
      final gate = Completer<void>();
      log.script
        ..clear()
        ..add(() async {
          await gate.future;
          return round(applied: 4);
        });
      await sync.resumed();
      await pumpEventQueue();
      expect(log.running, 1);
      await sync.setEnabled(false);
      expect(preferences.cloudLogSyncEnabled, isFalse);
      expect(sync.state.phase, CloudLogPhase.off);
      expect(clock.pending, 0);
      gate.complete();
      await sync.idle;
      expect(reloads, 1, reason: 'what it took in is shown');
      expect(sync.state.phase, CloudLogPhase.off, reason: 'and the round does not turn the row back on');
      final count = log.syncs.length;
      sync.noteLocalChange();
      await clock.advance(const Duration(hours: 1));
      expect(log.syncs, hasLength(count));
      expect(clock.pending, 0);
    });

    test('a request that arrived during that round does not make another once it is off', () async {
      await build();
      await sync.idle;
      final gate = Completer<void>();
      log.script
        ..clear()
        ..add(() async {
          await gate.future;
          return round();
        });
      await sync.resumed();
      await pumpEventQueue();
      await sync.resumed();
      await sync.setEnabled(false);
      gate.complete();
      await sync.idle;
      expect(log.syncs, hasLength(2));
    });

    test('switching on again continues from where the engine left off, with the same engine', () async {
      await build();
      await sync.idle;
      await sync.setEnabled(false);
      expect(preferences.cloudLogSyncEnabled, isFalse);
      await sync.setEnabled(true);
      await sync.idle;
      expect(preferences.cloudLogSyncEnabled, isTrue);
      expect(logs, hasLength(1), reason: 'one engine, which remembers its cursors');
      expect(log.syncs, hasLength(2));
      expect(sync.state.phase, CloudLogPhase.upToDate);
    });

    test('closing mid-round leaves no timer, and the round neither reloads nor emits', () async {
      await build();
      await sync.idle;
      final gate = Completer<void>();
      log.script
        ..clear()
        ..add(() async {
          await gate.future;
          return round(applied: 1);
        });
      sync.noteLocalChange();
      await clock.advance(const Duration(seconds: 6));
      expect(log.running, 1);
      final seen = states.length;
      await sync.close();
      expect(clock.pending, 0);
      gate.complete();
      await sync.idle;
      await clock.advance(const Duration(hours: 1));
      expect(reloads, 0);
      expect(states, hasLength(seen));
      expect(store.entries.onSaved, isNull);
      expect(log.syncs, hasLength(2));
    });

    test('a change to the book after closing starts nothing', () async {
      await build();
      await sync.idle;
      await sync.close();
      sync.noteLocalChange();
      await sync.resumed();
      expect(clock.pending, 0);
    });
  });

  group('while iCloud sync is off', () {
    test('nothing is called after it goes off, not by a pending change, the clock, or the foreground, and the preference is kept', () async {
      await build();
      await sync.idle;
      final syncs = log.syncs.length;
      final asked = availableCalls;
      final named = accountCalls;
      sync.noteLocalChange();
      await sync.setICloudSyncOn(false);
      expect(clock.pending, 0, reason: 'the pending change and the clock are gone');
      expect(sync.state.offered, isFalse);
      expect(preferences.cloudLogSyncEnabled, isTrue);
      await clock.advance(const Duration(hours: 1));
      await sync.resumed();
      sync.noteLocalChange();
      await clock.advance(const Duration(hours: 1));
      expect(log.syncs, hasLength(syncs));
      expect(accountCalls, named);
      expect(availableCalls, asked, reason: 'CloudKit is not even asked');
      expect(log.compactions, isEmpty);
      expect(preferences.cloudLogSyncEnabled, isTrue);
    });

    test('when it comes back on, with the preference still on, it resumes with the same engine', () async {
      await build();
      await sync.idle;
      await sync.setICloudSyncOn(false);
      await sync.setICloudSyncOn(true);
      await sync.idle;
      expect(logs, hasLength(1));
      expect(log.syncs, hasLength(2));
      expect(sync.state.phase, CloudLogPhase.upToDate);
      await clock.advance(const Duration(minutes: 5));
      expect(log.syncs, hasLength(3), reason: 'and the clock runs again');
    });

    test('a round running at that moment finishes and shows what it took in, and starts no other', () async {
      await build();
      await sync.idle;
      final gate = Completer<void>();
      log.script
        ..clear()
        ..add(() async {
          await gate.future;
          return round(applied: 2);
        });
      await sync.resumed();
      await pumpEventQueue();
      await sync.resumed();
      expect(log.running, 1);
      await sync.setICloudSyncOn(false);
      gate.complete();
      await sync.idle;
      expect(reloads, 1);
      expect(log.syncs, hasLength(2));
      expect(sync.state.offered, isFalse);
      await clock.advance(const Duration(hours: 1));
      expect(log.syncs, hasLength(2));
    });

    test('the app tells it when the iCloud switch changes, from the sync cubit\'s own state', () async {
      await build(on: false);
      final blocs = AppBlocs(bookStore: store, cloudLog: sync);
      addTearDown(() => blocs.sync.close());
      await sync.setEnabled(true);
      await pumpEventQueue();
      expect(sync.state.offered, isTrue);
      blocs.seed(iCloudSyncEnabled: true);
      blocs.seed(iCloudSyncEnabled: false);
      await pumpEventQueue();
      expect(sync.state.offered, isFalse);
      blocs.seed(iCloudSyncEnabled: true);
      await pumpEventQueue();
      expect(sync.state.offered, isTrue);
    });

    test('turned on while the CloudKit switch is off, it stays off', () async {
      await build(on: false);
      await sync.setICloudSyncOn(false);
      await sync.setICloudSyncOn(true);
      expect(sync.state.phase, CloudLogPhase.off);
      expect(logs, isEmpty);
    });
  });

  group('when CloudKit stops being available', () {
    test('found on returning to the foreground, rounds and timers stop, and when it is back they resume', () async {
      await build();
      await sync.idle;
      final syncs = log.syncs.length;
      sync.paused();
      available = false;
      sync.noteLocalChange();
      await sync.resumed();
      expect(sync.state.offered, isFalse);
      expect(clock.pending, 0);
      await clock.advance(const Duration(hours: 1));
      expect(log.syncs, hasLength(syncs));
      available = true;
      await sync.resumed();
      await sync.idle;
      expect(log.syncs, hasLength(syncs + 1));
      expect(sync.state.phase, CloudLogPhase.upToDate);
      await clock.advance(const Duration(minutes: 5));
      expect(log.syncs, hasLength(syncs + 2));
    });
  });

  group('accounts', () {
    test('the remote is named after the account in lower case letters and digits, and differs between accounts', () {
      final one = CloudLogSync.remoteFor('account-one');
      final two = CloudLogSync.remoteFor('account-two');
      expect(isDeviceId(one), isTrue);
      expect(isDeviceId(two), isTrue);
      expect(one, isNot(two));
      expect(CloudLogSync.remoteFor('account-one'), one);
      expect(one, isNot(contains('account')));
    });

    test('signing in to another account binds a new engine under another remote, and back again binds one more', () async {
      await build();
      await sync.idle;
      final first = logs.keys.single;
      account = 'account-two';
      await sync.resumed();
      await sync.idle;
      expect(logs.keys, hasLength(2));
      final second = logs.keys.last;
      expect(second, isNot(first));
      expect(logs[second]!.syncs, hasLength(1));
      await sync.resumed();
      await sync.idle;
      expect(logs, hasLength(2), reason: 'the same account keeps its engine');
      expect(logs[second]!.syncs, hasLength(2));
    });
  });
}

/// A transport that counts every call and does nothing else.
class _CountingTransport implements SyncTransport {
  final List<String> calls = [];

  @override
  Future<bool> append(SyncBatchRef ref, String body) async => throw StateError('append ${calls..add('append')}');

  @override
  Future<bool> writeSnapshot(SyncSnapshotRef ref, String body) async => throw StateError('writeSnapshot ${calls..add('writeSnapshot')}');

  @override
  Future<SyncListing> list({required Map<String, int> after}) async => throw StateError('list ${calls..add('list')}');

  @override
  Future<String?> read(SyncBatchRef ref) async => throw StateError('read ${calls..add('read')}');

  @override
  Future<String?> readSnapshot(SyncSnapshotRef ref) async => throw StateError('readSnapshot ${calls..add('readSnapshot')}');

  @override
  Future<void> discard({required Map<String, int> batchesThrough, required Iterable<SyncSnapshotRef> snapshots}) async => throw StateError('discard ${calls..add('discard')}');
}
