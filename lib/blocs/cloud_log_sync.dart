import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../services/book_store.dart';
import '../services/preferences.dart';
import '../services/sync/book_sync.dart';
import '../services/sync/cloudkit_sync_transport.dart' show CloudSyncException, CloudSyncFailure;
import '../services/sync/sync_report.dart';
import '../services/sync/sync_transport.dart';
import 'cloud_log_sync_state.dart';
import 'guarded_emit.dart';

/// Makes a timer; tests give one they can advance by hand.
typedef CloudLogTimer = Timer Function(Duration after, void Function() run);

/// Runs the book's change log sync through CloudKit, for a person who turned
/// it on in Settings, beside the iCloud key-value sync, which is left alone:
/// the stores keep their cloud key-value store, and both ways of syncing
/// decide between two versions of a record by the same rule, so a device
/// that runs both ends with the same book as devices that run one (see
/// `BookSync`). The switch is a preference of this device and is off until
/// it is turned on; while it is off nothing here calls the transport.
///
/// This class owns the engine's life, which `BookStore` does not: it asks
/// for the account, binds the engine under a remote named after the account
/// (so that what the engine remembers about a remote, which is kept in the
/// book database, belongs to one account, and signing in to another starts
/// afresh instead of reusing the cursors of the first), and runs rounds.
///
/// When a round runs, one at a time and never beside a compaction:
/// - once, when the book has loaded after start-up and the switch is on;
/// - after a change made to the book here, a few seconds later, so that a
///   burst of edits is one round;
/// - when the app comes back to the foreground;
/// - every few minutes while the app is in the foreground.
/// A request that comes while a round runs makes exactly one more round
/// after it. There is no push notification here: a change made on another
/// device is seen at the next of these, not at once.
///
/// A round that ends in an error ends quietly and the next trigger tries
/// again. iCloud's `retryAfter` is honoured, and repeated failures to reach
/// iCloud are tried at growing intervals up to half an hour. Whatever the
/// person can do something about is kept in [state], which Settings shows as
/// one line; there are no dialogs.
///
/// Once a day at most, after a round that moved nothing and never on the
/// first round after the switch was turned on, the device compacts: it
/// stores a snapshot and removes from iCloud what that makes unnecessary.
///
/// What a round took in is shown through [reload], which the app points at
/// the same path a cloud change of the key-value store takes. Turning the
/// switch off stops the timers and lets a round that is running finish;
/// nothing is removed from iCloud. Closing stops everything, and a round
/// still running then neither reloads nor emits.
class CloudLogSync extends Cubit<CloudLogSyncState> with GuardedEmit<CloudLogSyncState> {
  /// How long after the last change a round starts.
  final Duration debounce;

  /// How often a round runs while the app is in the foreground.
  final Duration interval;

  /// The shortest wait after a failure to reach iCloud; each failure in a
  /// row doubles it, up to [longestBackoff].
  static const Duration firstBackoff = Duration(minutes: 1);
  static const Duration longestBackoff = Duration(minutes: 30);

  /// The least time between two compactions of this device.
  static const Duration compactionEvery = Duration(days: 1);

  final BookStore _store;
  final Future<bool> Function() _checkAvailable;
  final Future<String> Function() _account;
  final Future<void> Function() _reload;
  final DateTime Function() _now;
  final CloudLogTimer _timer;
  final BookChangeLog Function(String remote) _changeLogFor;

  Preferences? _preferences;
  bool _enabled = false;
  bool _isAvailable = false;

  /// Whether iCloud sync as a whole is on. Nothing of the person's goes to
  /// iCloud while it is off, so nothing here runs either, whatever the
  /// switch of this class says; that switch is kept as it is.
  bool _iCloudOn;
  bool _bookLoaded = false;
  bool _foreground = true;

  /// The engine, and the remote it was made for.
  BookChangeLog? _engine;
  String? _engineRemote;

  /// Not null while rounds run; completed when the last of them is over.
  Completer<void>? _running;

  /// Set when something asked for a round while one ran.
  bool _again = false;

  Timer? _debounceTimer;
  Timer? _tickTimer;
  Timer? _retryTimer;

  /// No round before this, after iCloud asked to be left alone or a failure
  /// to reach it.
  DateTime? _notBefore;
  int _failures = 0;

  /// Rounds that went through since the switch was turned on, so that the
  /// first one is known.
  int _roundsDone = 0;

  /// Set while what a round took in has not been shown yet, so that a
  /// reload that failed is made again by the next round.
  bool _reloadOwed = false;

  CloudLogSync({
    required BookStore store,
    required SyncTransport transport,
    required Future<bool> Function() available,
    required Future<String> Function() account,
    required Future<void> Function() reload,
    DateTime Function()? now,
    CloudLogTimer? timer,
    this.debounce = const Duration(seconds: 5),
    this.interval = const Duration(minutes: 5),
    bool iCloudSyncOn = true,
    @visibleForTesting BookChangeLog Function(String remote)? changeLogFor,
  })  : _iCloudOn = iCloudSyncOn,
        _store = store,
        _checkAvailable = available,
        _account = account,
        _reload = reload,
        _now = now ?? DateTime.now,
        _timer = timer ?? Timer.new,
        _changeLogFor = changeLogFor ?? ((remote) => BookSync.changeLog(transport, remote: remote).bind(store)!),
        super(const CloudLogSyncState());

  /// The name of the remote for an iCloud [account]: lower case letters and
  /// digits only, as the engine wants, and a short hash, so that the account
  /// itself is not stored in the book database.
  static String remoteFor(String account) => 'ck${sha256.convert(utf8.encode(account)).toString().substring(0, 16)}';

  // ---------------------------------------------------------------------
  // What the app tells it
  // ---------------------------------------------------------------------

  /// Start-up, with the preferences once they exist: reads the switch,
  /// listens for changes to the book, and asks whether CloudKit can be used.
  /// A round waits for [bookLoaded] too.
  Future<void> start(Preferences preferences) async {
    if (_preferences != null || isClosed) return;
    _preferences = preferences;
    _enabled = preferences.cloudLogSyncEnabled;
    _store.onSaved = noteLocalChange;
    await _refreshAvailability();
  }

  /// The book has been read at start-up, so a round may take place.
  void bookLoaded() {
    _bookLoaded = true;
    _wake();
  }

  /// A change was made to the book on this device.
  void noteLocalChange() {
    if (!_active) return;
    _debounceTimer?.cancel();
    _debounceTimer = _timer(debounce, () {
      _debounceTimer = null;
      _request();
    });
  }

  /// The app came to the foreground.
  Future<void> resumed() async {
    _foreground = true;
    if (_preferences == null || isClosed) return;
    await _refreshAvailability();
  }

  /// The app left the foreground. A round that is running finishes, and a
  /// change made a moment ago is still sent; what stops is the clock.
  void paused() {
    _foreground = false;
    _tickTimer?.cancel();
    _tickTimer = null;
  }

  /// Told whenever iCloud sync is switched on or off, and at start-up. Off
  /// stops the timers and drops what was waiting; a round that is running
  /// finishes and shows what it took in, and nothing is called after it. On
  /// asks again whether CloudKit can be used and carries on with the same
  /// engine.
  Future<void> setICloudSyncOn(bool value) async {
    if (value == _iCloudOn || isClosed) return;
    _iCloudOn = value;
    if (!value) {
      _cancelTimers();
      _again = false;
      emit(const CloudLogSyncState());
      return;
    }
    if (_preferences != null) await _refreshAvailability();
  }

  /// The switch in Settings.
  Future<void> setEnabled(bool value) async {
    final preferences = _preferences;
    if (preferences == null || isClosed || value == _enabled) return;
    _enabled = value;
    await preferences.setCloudLogSyncEnabled(value);
    if (isClosed) return;
    if (!value) {
      _cancelTimers();
      _again = false;
      emit(const CloudLogSyncState(phase: CloudLogPhase.off));
      return;
    }
    _roundsDone = 0;
    _failures = 0;
    _notBefore = null;
    emit(const CloudLogSyncState(phase: CloudLogPhase.syncing));
    _wake();
  }

  /// Completes when no round is running or waiting to run.
  Future<void> get idle async {
    while (_running != null) {
      await _running!.future;
    }
  }

  @override
  Future<void> close() {
    _cancelTimers();
    if (_preferences != null) _store.onSaved = null;
    return super.close();
  }

  // ---------------------------------------------------------------------
  // When rounds run
  // ---------------------------------------------------------------------

  bool get _active => _enabled && _isAvailable && _iCloudOn && _bookLoaded && _preferences != null && !isClosed;

  bool get _mayRunNow => _active && (_notBefore == null || !_now().isBefore(_notBefore!));

  Future<void> _refreshAvailability() async {
    // Not even asked while iCloud sync is off.
    if (!_iCloudOn) return;
    bool available;
    try {
      available = await _checkAvailable();
    } catch (error) {
      debugPrint('Asking whether CloudKit can be used failed: $error');
      available = false;
    }
    if (isClosed || !_iCloudOn) return;
    _isAvailable = available;
    if (!available) {
      _cancelTimers();
      emit(const CloudLogSyncState());
      return;
    }
    if (state.phase == CloudLogPhase.unavailable) emit(CloudLogSyncState(phase: _enabled ? CloudLogPhase.syncing : CloudLogPhase.off));
    _wake();
  }

  /// A round now, and the clock running.
  void _wake() {
    if (!_active) return;
    _scheduleTick();
    _request();
  }

  void _scheduleTick() {
    _tickTimer?.cancel();
    _tickTimer = null;
    if (!_active || !_foreground) return;
    _tickTimer = _timer(interval, () {
      _tickTimer = null;
      _request();
      _scheduleTick();
    });
  }

  void _cancelTimers() {
    _debounceTimer?.cancel();
    _tickTimer?.cancel();
    _retryTimer?.cancel();
    _debounceTimer = _tickTimer = _retryTimer = null;
  }

  /// Asks for a round: it starts now, or after the one that is running, or
  /// when the wait after a failure is over.
  void _request() {
    if (!_active) return;
    if (_running != null) {
      _again = true;
      return;
    }
    final until = _notBefore;
    if (until != null && _now().isBefore(until)) {
      _retryTimer ??= _timer(until.difference(_now()), () {
        _retryTimer = null;
        _request();
      });
      return;
    }
    _running = Completer<void>();
    unawaited(_loop());
  }

  Future<void> _loop() async {
    try {
      do {
        _again = false;
        await _round();
      } while (_again && _mayRunNow);
    } finally {
      // Nothing is awaited between deciding to stop and this, so a request
      // cannot slip in unseen.
      final done = _running!;
      _running = null;
      if (_again) {
        _again = false;
        _request();
      }
      done.complete();
    }
  }

  // ---------------------------------------------------------------------
  // A round
  // ---------------------------------------------------------------------

  /// The engine for [remote], kept while the account is the same.
  BookChangeLog _engineFor(String remote) {
    if (_engineRemote != remote) {
      _engine = _changeLogFor(remote);
      _engineRemote = remote;
    }
    return _engine!;
  }

  Future<void> _round() async {
    final preferences = _preferences!;
    // A round that only confirms what is shown does not flash "syncing".
    if (_enabled && state.phase != CloudLogPhase.syncing && state.phase != CloudLogPhase.upToDate && state.phase != CloudLogPhase.waiting) {
      emit(const CloudLogSyncState(phase: CloudLogPhase.syncing));
    }
    try {
      final engine = _engineFor(remoteFor(await _account()));
      final round = await engine.sync();
      var newer = round.pull.needsUpdate;
      await _show(round.pull.applied > 0 || round.pull.rekeyed);

      // Only after a round that moved nothing, not on the first one since
      // the switch was turned on, and not twice in a day.
      final compactedAt = preferences.cloudLogCompactedAt;
      final due = compactedAt == null || !_now().isBefore(compactedAt.add(compactionEvery));
      if (round.quiet && _roundsDone > 0 && due && !isClosed) {
        final compaction = await engine.compact();
        await preferences.setCloudLogCompactedAt(_now());
        newer = newer || compaction.refused || compaction.round.pull.needsUpdate;
        await _show(compaction.round.pull.applied > 0 || compaction.round.pull.rekeyed);
      }

      _failures = 0;
      _notBefore = null;
      _roundsDone++;
      if (!_enabled || !_isAvailable || !_iCloudOn) return;
      if (newer) {
        emit(const CloudLogSyncState(phase: CloudLogPhase.problem, problem: CloudLogProblem.newerVersion));
      } else if (round.pull.waiting.isNotEmpty || round.pull.problems.isNotEmpty) {
        emit(const CloudLogSyncState(phase: CloudLogPhase.waiting));
      } else {
        emit(CloudLogSyncState(phase: CloudLogPhase.upToDate, at: _now()));
      }
    } on CloudSyncException catch (error) {
      _failed(error.failure, error.retryAfter, error);
    } catch (error, stack) {
      debugPrint('A CloudKit sync round failed: $error\n$stack');
      _failed(null, null, error);
    }
  }

  /// Shows what a round took in, through the app's own reload; remembers
  /// that it is owed when it fails, and does nothing once closed.
  Future<void> _show(bool tookIn) async {
    if (tookIn) _reloadOwed = true;
    if (!_reloadOwed || isClosed) return;
    await _reload();
    _reloadOwed = false;
  }

  void _failed(CloudSyncFailure? failure, Duration? retryAfter, Object error) {
    debugPrint('A CloudKit sync round did not go through: $error');
    // Failing to reach iCloud, and what is not understood, is tried again at
    // growing intervals; the rest waits for the next trigger.
    final retries = failure == null || failure == CloudSyncFailure.network || failure == CloudSyncFailure.other;
    Duration? wait = retryAfter;
    if (retries) {
      _failures++;
      final backoff = firstBackoff * pow(2, min(_failures - 1, 10)).toInt();
      final capped = backoff > longestBackoff ? longestBackoff : backoff;
      if (wait == null || capped > wait) wait = capped;
    } else {
      _failures = 0;
    }
    _notBefore = wait == null ? null : _now().add(wait);
    // What changed meanwhile is sent when the wait is over, not only at the
    // next turn of the clock.
    _retryTimer?.cancel();
    _retryTimer = null;
    if (wait != null && _active) {
      _retryTimer = _timer(wait, () {
        _retryTimer = null;
        _request();
      });
    }
    if (!_enabled || !_isAvailable || !_iCloudOn) return;
    emit(CloudLogSyncState(phase: CloudLogPhase.problem, problem: _problemFor(failure)));
  }

  static CloudLogProblem _problemFor(CloudSyncFailure? failure) => switch (failure) {
        CloudSyncFailure.quota => CloudLogProblem.quota,
        CloudSyncFailure.notSignedIn => CloudLogProblem.notSignedIn,
        CloudSyncFailure.unavailable || CloudSyncFailure.unsupported => CloudLogProblem.unavailable,
        CloudSyncFailure.zoneMissing => CloudLogProblem.zoneMissing,
        CloudSyncFailure.network => CloudLogProblem.offline,
        CloudSyncFailure.other || null => CloudLogProblem.other,
      };
}
