import 'package:equatable/equatable.dart';

/// Where the CloudKit change log sync stands, as Settings tells it.
enum CloudLogPhase {
  /// This build or this device cannot use CloudKit, or the check is not done
  /// yet: Settings does not offer the switch.
  unavailable,

  /// Offered, and not turned on.
  off,

  /// On, and a round is running or about to.
  syncing,

  /// The last round finished and left nothing undone, at [CloudLogSyncState.at].
  upToDate,

  /// The last round finished, but another device has sent something that is
  /// not complete yet. It is taken in on a later round.
  waiting,

  /// The last round did not go through; see [CloudLogSyncState.problem].
  problem,
}

/// Why a round did not go through, as far as the person can do something
/// about it or should know.
enum CloudLogProblem {
  /// The person's iCloud storage is full.
  quota,

  /// No iCloud account is signed in.
  notSignedIn,

  /// This build is not signed for CloudKit.
  unavailable,

  /// The synced data is gone from iCloud and could not be made again.
  zoneMissing,

  /// Another device runs a later build and wrote what this one cannot read.
  newerVersion,

  /// iCloud could not be reached; it is tried again by itself.
  offline,

  /// Anything else; it is tried again by itself.
  other,
}

/// Immutable, so that only what shows it rebuilds when it changes.
class CloudLogSyncState extends Equatable {
  final CloudLogPhase phase;

  /// When the last round left things up to date; set with
  /// [CloudLogPhase.upToDate].
  final DateTime? at;

  /// Set with [CloudLogPhase.problem].
  final CloudLogProblem? problem;

  const CloudLogSyncState({this.phase = CloudLogPhase.unavailable, this.at, this.problem});

  /// Whether Settings offers the switch.
  bool get offered => phase != CloudLogPhase.unavailable;

  /// Whether the switch is on.
  bool get enabled => offered && phase != CloudLogPhase.off;

  @override
  List<Object?> get props => [phase, at, problem];
}
