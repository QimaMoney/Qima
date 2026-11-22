import 'package:flutter/services.dart';

import 'sync_transport.dart';

/// Why a call to the CloudKit transport did not go through.
enum CloudSyncFailure {
  /// This platform has no CloudKit plugin (Android, Windows, Linux, web).
  unsupported('unsupported'),

  /// The build is not signed for the CloudKit container.
  unavailable('unavailable'),

  /// No iCloud account is signed in, or it is restricted.
  notSignedIn('not_signed_in'),

  /// The device is offline, or iCloud is busy or asked to be called later.
  network('network'),

  /// The person's iCloud storage is full.
  quota('quota'),

  /// The zone is gone and could not be made again.
  zoneMissing('zone_missing'),

  /// Anything else, the plugin's own mistakes included.
  other('other');

  /// The error code the plugin sends for it.
  final String code;

  const CloudSyncFailure(this.code);

  static CloudSyncFailure of(String code) => values.firstWhere((failure) => failure.code == code, orElse: () => other);
}

/// Thrown by [CloudKitSyncTransport] when a call did not go through. Nothing
/// is known then about what the call did: a store may have reached iCloud
/// although its answer was lost.
class CloudSyncException implements Exception {
  final CloudSyncFailure failure;
  final String message;

  /// How long iCloud asked to be left alone, when it said.
  final Duration? retryAfter;

  const CloudSyncException(this.failure, this.message, {this.retryAfter});

  @override
  String toString() => 'CloudSyncException(${failure.code}): $message';
}

/// A [SyncTransport] that is a zone of the person's private CloudKit
/// database: one record per part of a batch and of a snapshot, through
/// `CloudSyncPlugin.swift` (iOS and macOS) on the channel `qima/cloud_sync`.
///
/// The plugin stores text under names and no more:
/// - `available()` answers whether the build may use the container and an
///   iCloud account is signed in.
/// - `account()` answers a stable name of the iCloud account signed in now,
///   for this container: the record name of the user, which is the same on
///   every device of the account and differs between accounts.
/// - `store({kind, name, body})` answers true when the name now holds
///   `body`, false when it held other text, which is left as it is.
/// - `read({kind, name})` answers the body, or null when there is no such
///   record.
/// - `list()` answers `{batch: [names], snapshot: [names], other: [record
///   names]}`, `other` being records in the zone that are not ours.
/// - `discard({batch: [names], snapshot: [names]})` removes those records; a
///   record that is gone already is not an error.
///
/// `kind` is [batchKind] or [snapshotKind]. What a name means is decided
/// here, as it is for a folder of files: a name that is no ref goes into
/// [SyncListing.problems] and is never read or removed.
///
/// What a failure becomes. The engine takes every answer at its word: false
/// from a store makes it send the batch again under a new name, and null
/// from a read tells it the part is gone, which can make a compaction write
/// a snapshot again. An exception, though, only ends the round it is in, and
/// the next round starts from what is really there. So every failure is
/// thrown, as a [CloudSyncException], and no answer is ever made up: false
/// and null are passed on only when iCloud itself gave them. A store whose
/// answer was lost is safe to repeat, since the same body under the same
/// name answers true.
///
/// Where there is no plugin every call throws [CloudSyncFailure.unsupported]
/// and [available] answers false.
class CloudKitSyncTransport implements SyncTransport {
  static const String batchKind = 'batch';
  static const String snapshotKind = 'snapshot';
  static const String otherKind = 'other';

  static const MethodChannel _channel = MethodChannel('qima/cloud_sync');

  /// Set once the channel has been found to have nobody on the other side,
  /// which does not change while the app runs.
  bool _unsupported = false;

  /// Whether the transport can be used now. Never throws: any doubt is a no.
  Future<bool> available() async {
    try {
      return await _invoke<bool>('available') ?? false;
    } on CloudSyncException {
      return false;
    }
  }

  /// A stable name of the signed-in iCloud account for this container, which
  /// the caller can tell accounts apart by. Throws like every other call.
  Future<String> account() async {
    final name = await _invoke<String>('account');
    if (name == null || name.isEmpty) throw const CloudSyncException(CloudSyncFailure.other, 'The CloudKit plugin gave no account name.');
    return name;
  }

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? arguments]) async {
    if (_unsupported) throw const CloudSyncException(CloudSyncFailure.unsupported, 'CloudKit sync is not available on this platform.');
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      _unsupported = true;
      throw const CloudSyncException(CloudSyncFailure.unsupported, 'CloudKit sync is not available on this platform.');
    } on PlatformException catch (e) {
      final details = e.details;
      final wait = details is Map ? details['retryAfter'] : null;
      throw CloudSyncException(
        CloudSyncFailure.of(e.code),
        e.message ?? e.code,
        retryAfter: wait is num ? Duration(milliseconds: (wait * 1000).round()) : null,
      );
    }
  }

  Future<bool> _store(String kind, String name, String body) async {
    final stored = await _invoke<bool>('store', {'kind': kind, 'name': name, 'body': body});
    // No answer is not a no: a false would send the batch out again under
    // another name.
    if (stored == null) throw CloudSyncException(CloudSyncFailure.other, 'The CloudKit plugin gave no answer for storing $kind $name.');
    return stored;
  }

  @override
  Future<bool> append(SyncBatchRef ref, String body) => _store(batchKind, ref.name, body);

  @override
  Future<bool> writeSnapshot(SyncSnapshotRef ref, String body) => _store(snapshotKind, ref.name, body);

  @override
  Future<String?> read(SyncBatchRef ref) => _invoke<String>('read', {'kind': batchKind, 'name': ref.name});

  @override
  Future<String?> readSnapshot(SyncSnapshotRef ref) => _invoke<String>('read', {'kind': snapshotKind, 'name': ref.name});

  /// Every name the zone holds, per kind, as the plugin gives them.
  Future<Map<String, List<String>>> _names() async {
    final raw = await _invoke<Map<Object?, Object?>>('list');
    if (raw == null) throw const CloudSyncException(CloudSyncFailure.other, 'The CloudKit plugin gave no listing.');
    return {
      for (final kind in const [batchKind, snapshotKind, otherKind]) kind: [for (final name in raw[kind] as List<Object?>? ?? const []) '$name'],
    };
  }

  @override
  Future<SyncListing> list({required Map<String, int> after}) async {
    final names = await _names();
    final batches = <SyncBatchRef>[];
    final snapshots = <SyncSnapshotRef>[];
    final problems = <String>[];
    for (final name in names[batchKind]!) {
      final ref = SyncBatchRef.parse(name);
      if (ref == null) {
        problems.add('the record $batchKind.$name is not named like a batch');
      } else if (ref.last > (after[ref.device] ?? 0)) {
        batches.add(ref);
      }
    }
    for (final name in names[snapshotKind]!) {
      final ref = SyncSnapshotRef.parse(name);
      if (ref == null) {
        problems.add('the record $snapshotKind.$name is not named like a snapshot');
      } else {
        snapshots.add(ref);
      }
    }
    for (final name in names[otherKind]!) {
      problems.add('the record $name is not one of ours');
    }
    return SyncListing(batches: batches, snapshots: snapshots, problems: problems);
  }

  @override
  Future<void> discard({required Map<String, int> batchesThrough, required Iterable<SyncSnapshotRef> snapshots}) async {
    // Only what is listed now is removed: a batch that shows up later is
    // left for the next compaction. Names that are no refs are left alone,
    // as nobody can say what they cover.
    final batches = <String>{};
    if (batchesThrough.isNotEmpty) {
      for (final name in (await _names())[batchKind]!) {
        final ref = SyncBatchRef.parse(name);
        if (ref != null && ref.last <= (batchesThrough[ref.device] ?? 0)) batches.add(name);
      }
    }
    final parts = {for (final ref in snapshots) ref.name};
    if (batches.isEmpty && parts.isEmpty) return;
    await _invoke<void>('discard', {batchKind: batches.toList(), snapshotKind: parts.toList()});
  }
}
