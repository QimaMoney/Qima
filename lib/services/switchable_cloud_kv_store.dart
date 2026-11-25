import 'dart:async';
import 'dart:convert';

import 'cloud_kv_store.dart';
import 'icloud_kv_store.dart';

/// Forwards to either a real [IcloudKVStore] or [LocalOnlyCloudKVStore]
/// depending on [enabled], without ever changing identity — every
/// `SyncedStore`/`Preferences` instance is constructed once against a single
/// [SwitchableCloudKVStore], so turning iCloud sync on/off in Settings never
/// requires rebuilding any store, and in-flight reads mid-toggle still
/// resolve against a consistent backend rather than a half-swapped one.
///
/// [enabled] starts `false` (local-only) until [SyncCubit] explicitly turns it
/// on after reading the user's `iCloudSyncEnabled` preference — this class
/// itself has no opinion on defaults.
class SwitchableCloudKVStore implements CloudKVStore {
  final IcloudKVStore _icloud;
  final LocalOnlyCloudKVStore _local = LocalOnlyCloudKVStore();
  bool _enabled = false;

  /// Bytes the app believes each cloud key occupies, for every key it has
  /// read or written through the real iCloud backend this session. The
  /// plugin has no key-listing call, so keys that exist in the cloud but were
  /// never touched here are not counted: the total is a lower bound, which is
  /// why [maxTrackedBytes] sits well below the 1 MB system limit.
  final Map<String, int> _trackedBytes = {};
  int _trackedTotal = 0;

  /// Size of the last value known to have landed, per key.
  final Map<String, int> _landed = {};

  /// Writes issued but not yet completed, oldest first, per key. While any is
  /// pending a key's tracked size is the largest of them and the last landed
  /// value (any could be the one that ends up stored); with none pending it
  /// is the last value that landed. A failed write only drops its own entry.
  final Map<String, List<int>> _pending = {};

  /// Keys whose last write was skipped by the guard and has not since landed.
  final Set<String> _skipped = {};

  /// Bumped whenever tracking is reset, so reads and writes that began before
  /// the reset do not write stale sizes back afterwards.
  int _generation = 0;

  /// The most bytes this store lets the tracked keys reach (the system limit
  /// is 1 MB for the whole store; the margin covers keys this process never
  /// saw and per-key overhead).
  static const int maxTrackedBytes = 900000;

  final StreamController<CloudKVChangeEvent> _changesController = StreamController<CloudKVChangeEvent>.broadcast();
  StreamSubscription<CloudKVChangeEvent>? _icloudSubscription;

  SwitchableCloudKVStore({IcloudKVStore? icloud}) : _icloud = icloud ?? IcloudKVStore();

  bool get enabled => _enabled;

  /// Whether any write was skipped by the size guard and has not since been
  /// followed by a landed write of the same key. While true, the cloud copy
  /// of those keys is out of date; the app can use this to keep a
  /// storage-full status instead of reporting up to date.
  bool get overLimit => _skipped.isNotEmpty;

  /// The keys behind [overLimit].
  Set<String> get skippedKeys => Set.unmodifiable(_skipped);

  /// Forgets every tracked size and skipped key. Done automatically when the
  /// store is enabled or disabled and when an `accountChange` event arrives
  /// (the cloud may now hold different data); call it directly for any other
  /// reason the cloud's contents may have changed underneath.
  void resetTracking() {
    _generation++;
    _trackedBytes.clear();
    _landed.clear();
    _pending.clear();
    _skipped.clear();
    _trackedTotal = 0;
  }

  /// Total bytes currently tracked for the cloud store (see [_trackedBytes]).
  int get trackedBytes => _trackedTotal;

  CloudKVStore get _active => _enabled ? _icloud : _local;

  /// Switches the active backend. Turning ON subscribes to the real iCloud
  /// change stream (so external-change events start flowing); turning OFF
  /// unsubscribes so no more events arrive from a backend the app is no
  /// longer treating as authoritative — callers that already merged local
  /// data into the cloud before disabling don't need to worry about a event
  /// arriving after the fact and re-triggering a reload from a store nothing
  /// reads anymore.
  void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    resetTracking();
    if (value) {
      _icloudSubscription ??= _icloud.didChangeExternally.listen(
        _forward,
        onError: _changesController.addError,
      );
    } else {
      unawaited(_icloudSubscription?.cancel());
      _icloudSubscription = null;
    }
  }

  void _forward(CloudKVChangeEvent event) {
    if (event.reason == CloudKVChangeReason.accountChange) resetTracking();
    _changesController.add(event);
  }

  @override
  Future<String?> getString(String key) async {
    if (!_enabled) return _local.getString(key);
    final generation = _generation;
    final value = await _icloud.getString(key);
    // A read racing an in-flight write may return the value from before it.
    if (generation == _generation && !_pending.containsKey(key)) {
      if (value == null) {
        _landed.remove(key);
      } else {
        _landed[key] = _sizeOf(key, value);
      }
      _retrack(key);
    }
    return value;
  }

  @override
  Future<void> setString(String key, String value) async {
    await trySetString(key, value);
  }

  /// Like [setString], but reports whether the write was performed. When the
  /// tracked total would pass [maxTrackedBytes] the write is skipped, nothing
  /// is stored, and a [CloudKVChangeReason.quotaViolationChange] event is
  /// emitted on [didChangeExternally] (once per skipped write), so the app
  /// shows its storage-full status at once instead of waiting for the system
  /// to drop the write. A write that does not grow its key is never skipped.
  /// Nothing is ever deleted to make room. Always `true` while disabled.
  Future<bool> trySetString(String key, String value) async {
    if (!_enabled) {
      await _local.setString(key, value);
      return true;
    }
    final previous = _trackedBytes[key];
    final size = _sizeOf(key, value);
    final projected = _trackedTotal - (previous ?? 0) + size;
    if (projected > maxTrackedBytes && size > (previous ?? 0)) {
      _skipped.add(key);
      if (!_changesController.isClosed) {
        _changesController.add(CloudKVChangeEvent(keys: [key], reason: CloudKVChangeReason.quotaViolationChange));
      }
      return false;
    }
    // Reserve synchronously so concurrent writes see each other's size.
    final generation = _generation;
    final queue = _pending.putIfAbsent(key, () => []);
    queue.add(size);
    _retrack(key);
    var landed = false;
    try {
      await _icloud.setString(key, value);
      landed = true;
    } finally {
      if (generation == _generation) {
        queue.remove(size);
        if (queue.isEmpty) _pending.remove(key);
        if (landed) {
          _landed[key] = size;
          _skipped.remove(key);
        }
        _retrack(key);
      }
    }
    return true;
  }

  void _retrack(String key) {
    final queue = _pending[key];
    var bytes = _landed[key];
    for (final pending in queue ?? const <int>[]) {
      if (bytes == null || pending > bytes) bytes = pending;
    }
    final old = _trackedBytes[key] ?? 0;
    if (bytes == null) {
      _trackedBytes.remove(key);
    } else {
      _trackedBytes[key] = bytes;
    }
    _trackedTotal += (bytes ?? 0) - old;
  }

  /// Apple does not document whether the quota counts UTF-8 or UTF-16, so
  /// this takes the larger of the two for the key and the value.
  static int _sizeOf(String key, String value) => _bytesOf(key) + _bytesOf(value);

  static int _bytesOf(String s) {
    final utf8Length = utf8.encode(s).length;
    final utf16Length = s.length * 2;
    return utf8Length > utf16Length ? utf8Length : utf16Length;
  }

  @override
  Future<void> synchronize() => _active.synchronize();

  @override
  Future<bool> accountStatus() => _icloud.accountStatus();

  @override
  Stream<CloudKVChangeEvent> get didChangeExternally => _changesController.stream;

  /// Releases the underlying event subscription and closes the forwarded
  /// stream — call once when the owner (normally a single app-lifetime
  /// [SyncCubit]) is done with this store, so no native event channel
  /// listener outlives it.
  Future<void> dispose() async {
    await _icloudSubscription?.cancel();
    _icloudSubscription = null;
    await _changesController.close();
    _icloud.dispose();
  }
}
