import 'package:equatable/equatable.dart';

/// Status of the iCloud key-value sync backend, for the Settings "iCloud
/// sync" status line (spec Phase 7). [disabled] covers both "the user turned
/// it off" and "not offered on this platform/no iCloud account" — the UI
/// that decides whether to show the section at all is what distinguishes
/// those, this just reflects whether the switch is effectively on.
enum CloudSyncStatus {
  disabled,
  syncing,
  upToDate,

  /// No iCloud account is signed in on this device (`accountStatus()` was
  /// false, or an `accountChange` event fired and the recheck came back
  /// false).
  notSignedIn,

  /// The iCloud KVS quota (1 MB total, 1024 keys) was exceeded on a write —
  /// local data stays authoritative; the write is simply not reflected in
  /// the cloud until something is freed up (spec Phase 7 "Size guard").
  storageFull,

  /// A sync finished, but something about the book is not right (see
  /// [BookHealth]); the Settings card says what.
  needsAttention;
}

/// What is wrong with the book on this device, if anything. Each flag is one
/// kind of problem with its own row in Settings; none stops the app.
class BookHealth extends Equatable {
  /// A step of the on-device migration to the ledger did not finish: the
  /// trades from before the update are still stored, and are tried again on
  /// the next start.
  final bool migrationFailed;

  /// A value in the old cloud keys could not be read this time; the next
  /// cloud change or start tries again.
  final bool legacyUnreadable;

  /// A collection of the book was written to the cloud by a newer build, so
  /// its sync is paused until this app is updated.
  final bool newerVersion;

  /// Loading the trades or the book failed, so what is shown may be missing
  /// some of what is stored.
  final bool loadFailed;

  const BookHealth({this.migrationFailed = false, this.legacyUnreadable = false, this.newerVersion = false, this.loadFailed = false});

  static const BookHealth fine = BookHealth();

  bool get hasProblem => migrationFailed || legacyUnreadable || newerVersion || loadFailed;

  @override
  List<Object?> get props => [migrationFailed, legacyUnreadable, newerVersion, loadFailed];
}

/// How the book is kept safe: iCloud sync, what is wrong with the book on
/// this device, and the backup reminder.
class SyncState extends Equatable {
  /// What is wrong with the book on this device; see [BookHealth].
  final BookHealth bookHealth;

  /// Whether the user has iCloud sync turned on (spec Phase 7) — mirrors
  /// `Preferences.iCloudSyncEnabled`, a local-only setting never itself
  /// synced through the store it controls.
  final bool iCloudSyncEnabled;

  /// Whether iCloud sync is offered on this device at all: iOS only, and
  /// (once checked) an iCloud account must be signed in. Starts `true`
  /// (platform-gated already by [iCloudSyncEnabled]'s default and by
  /// `SettingsScreen` only building the section on iOS) so the section
  /// doesn't flash away before the first `accountStatus()` check resolves;
  /// [SyncCubit.start] corrects it promptly.
  final bool iCloudAccountAvailable;

  final CloudSyncStatus cloudSyncStatus;

  /// Last time a full sync round-trip (local+cloud merge) completed
  /// successfully, for the "Up to date · 14:32" status line.
  final DateTime? lastCloudSyncAt;

  /// Whether the Settings/Backup "Time for a backup" reminder card should
  /// show right now (spec Phase 6): reminder enabled, data changed since the
  /// last backup, and more than 30 days since the last backup (or never
  /// backed up). Recomputed from `BackupService.isReminderDue` — see
  /// `SyncCubit.refreshBackupReminder`.
  final bool backupReminderDue;

  const SyncState({
    this.bookHealth = BookHealth.fine,
    this.iCloudSyncEnabled = false,
    this.iCloudAccountAvailable = true,
    this.cloudSyncStatus = CloudSyncStatus.disabled,
    this.lastCloudSyncAt,
    this.backupReminderDue = false,
  });

  SyncState copyWith({
    BookHealth? bookHealth,
    bool? iCloudSyncEnabled,
    bool? iCloudAccountAvailable,
    CloudSyncStatus? cloudSyncStatus,
    DateTime? lastCloudSyncAt,
    bool clearLastCloudSyncAt = false,
    bool? backupReminderDue,
  }) {
    return SyncState(
      bookHealth: bookHealth ?? this.bookHealth,
      iCloudSyncEnabled: iCloudSyncEnabled ?? this.iCloudSyncEnabled,
      iCloudAccountAvailable: iCloudAccountAvailable ?? this.iCloudAccountAvailable,
      cloudSyncStatus: cloudSyncStatus ?? this.cloudSyncStatus,
      lastCloudSyncAt: clearLastCloudSyncAt ? null : (lastCloudSyncAt ?? this.lastCloudSyncAt),
      backupReminderDue: backupReminderDue ?? this.backupReminderDue,
    );
  }

  @override
  List<Object?> get props => [bookHealth, iCloudSyncEnabled, iCloudAccountAvailable, cloudSyncStatus, lastCloudSyncAt, backupReminderDue];
}
