import 'dart:math';

import 'package:qima/services/sync/sync_transport.dart';

/// Thrown by a [MemorySyncTransport] that was told to fail.
class SyncTransportFailure implements Exception {
  final String step;

  const SyncTransportFailure(this.step);

  @override
  String toString() => 'SyncTransportFailure: $step';
}

/// A [SyncTransport] that lives in memory. One instance is the shared place:
/// every device is given the same one.
///
/// It can behave as badly as a real remote is allowed to. With [weather] set,
/// a call fails before or after it did its work ([failure]), and a listing
/// leaves names out for now ([hidden], which is how a late or out of order
/// arrival looks to a reader), gives some twice ([repeated]) and in any
/// order. It never loses what it has stored: a remote that did would lose
/// data whatever the engine does.
class MemorySyncTransport implements SyncTransport {
  final Map<SyncBatchRef, String> batches = {};
  final Map<SyncSnapshotRef, String> snapshots = {};

  /// The source of the bad behaviour; null behaves perfectly.
  Random? weather;
  double failure = 0.05;
  double hidden = 0.3;
  double repeated = 0.3;

  /// Batches a listing leaves out until they are taken from this set: a late
  /// arrival, at a moment a test chooses.
  final Set<SyncBatchRef> delayed = {};

  /// Whether a listing names every batch there is, whatever the reader said
  /// it already has.
  bool replay = false;

  /// Called at the start of every call with its name (`append`, `list`,
  /// `read`, `readSnapshot`, `writeSnapshot`, `discard`) and, for a call
  /// that stores or removes, again once it has, with `.done` added. Whatever
  /// it throws is what the caller gets: from the second call, the work is
  /// done and the caller does not know. It may wait, to hold a call back.
  Future<void> Function(String step)? onStep;

  Future<void> _step(String step) async {
    await onStep?.call(step);
    final random = weather;
    if (random != null && random.nextDouble() < failure) throw SyncTransportFailure(step);
  }

  @override
  Future<bool> append(SyncBatchRef ref, String body) async {
    await _step('append');
    final stored = batches.putIfAbsent(ref, () => body) == body;
    await _step('append.done');
    return stored;
  }

  @override
  Future<bool> writeSnapshot(SyncSnapshotRef ref, String body) async {
    await _step('writeSnapshot');
    final stored = snapshots.putIfAbsent(ref, () => body) == body;
    await _step('writeSnapshot.done');
    return stored;
  }

  @override
  Future<SyncListing> list({required Map<String, int> after}) async {
    await _step('list');
    final random = weather;
    final out = <SyncBatchRef>[];
    for (final ref in batches.keys) {
      if (delayed.contains(ref)) continue;
      if (!replay && ref.last <= (after[ref.device] ?? 0)) continue;
      if (random != null && random.nextDouble() < hidden) continue;
      out.add(ref);
      if (random != null && random.nextDouble() < repeated) out.add(ref);
    }
    if (random != null) out.shuffle(random);
    return SyncListing(batches: out, snapshots: snapshots.keys.toList());
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
}
