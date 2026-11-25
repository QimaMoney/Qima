import 'sync_transport.dart';

/// Why something a remote holds was not taken in.
enum SyncProblemKind {
  /// Written by a later build in a format this one does not read. It is left
  /// exactly as it is, and taken in once the app is updated.
  newerVersion,

  /// Cannot be read: cut short, damaged, or not ours. Left where it is and
  /// read again on the next round, in case it was still arriving.
  unreadable,
}

class SyncProblem {
  final SyncProblemKind kind;

  /// The batch or snapshot, or the transport's own words.
  final String what;

  const SyncProblem(this.kind, this.what);

  @override
  String toString() => '${kind.name}: $what';
}

/// What taking in the changes of the other devices did.
class SyncPull {
  /// Records that replaced or added to what this device held.
  final int applied;

  /// Whole batches that are there but cannot be used yet: one before them is
  /// missing or cannot be read. Nothing of them counts until the gap is
  /// filled, by the missing batch or by a snapshot that covers it.
  final List<SyncBatchRef> waiting;

  /// Batches of which a part is not there, beyond what this device has of
  /// their writer. Such a batch is never used. Either its writer is still
  /// storing it, or stopped half way; when it comes back it stores a whole
  /// batch for the same changes and this one is passed over. A writer that
  /// never comes back leaves it here for good, which is why it is not
  /// [waiting]: there is nothing for this device to catch up on, only
  /// something of the writer's that never arrived.
  final List<SyncBatchRef> incomplete;

  final List<SyncProblem> problems;

  /// Whether this database was found to share its device id with another
  /// (it is a restored copy, or was copied) and was given a new one. The
  /// whole book goes out again under the new id.
  final bool rekeyed;

  const SyncPull({this.applied = 0, this.waiting = const [], this.incomplete = const [], this.problems = const [], this.rekeyed = false});

  /// Whether a later build has written something this one cannot read.
  bool get needsUpdate => problems.any((p) => p.kind == SyncProblemKind.newerVersion);
}

/// What sending this device's changes did.
class SyncPush {
  /// Records sent; 0 when there was nothing new.
  final int sent;

  const SyncPush({this.sent = 0});
}

class SyncRound {
  final SyncPull pull;
  final SyncPush push;

  const SyncRound(this.pull, this.push);

  /// Whether the round moved nothing either way and left nothing undone: a
  /// device that is waiting for a batch, or could not read something, is not
  /// at rest. A batch that is [SyncPull.incomplete] does not count: its
  /// writer has more to do, this device has not.
  bool get quiet => pull.applied == 0 && push.sent == 0 && !pull.rekeyed && pull.waiting.isEmpty && pull.problems.isEmpty;
}

/// What a compaction did.
class SyncCompaction {
  /// The snapshot of this device that is whole on the remote when the call
  /// returns: the one it stored now, or the one it stored before when
  /// nothing has changed since and that one is still there. Null when the
  /// compaction was refused, and when nothing has changed since a snapshot
  /// of this device that another device has replaced with its own.
  final SyncSnapshotRef? snapshot;

  /// True when the remote holds something from a later build: nothing was
  /// written or removed.
  final bool refused;

  /// Rows removed from this device's own change log.
  final int trimmed;

  /// The round that came first.
  final SyncRound round;

  const SyncCompaction({required this.snapshot, required this.trimmed, required this.round, this.refused = false});
}

/// The book's change log sync, as the app drives it. A call the transport
/// fails throws what the transport threw; nothing is lost by it, and the next
/// call carries on from where things stand.
abstract class BookChangeLog {
  /// Takes in what the other devices sent, then sends what changed here.
  Future<SyncRound> sync();

  /// Writes a snapshot of this device's book, removes from the remote the
  /// batches and snapshots it makes unnecessary, and trims this device's own
  /// change log.
  Future<SyncCompaction> compact();
}
