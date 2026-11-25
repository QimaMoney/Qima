import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../models/backup.dart';
import '../services/alerts_store.dart';
import '../services/backup/backup_service.dart';
import '../services/background_refresh.dart';
import '../services/book_store.dart';
import '../services/cloud_kv_store.dart';
import '../services/custom_instrument_store.dart';
import '../services/legacy_absorber.dart';
import '../services/preferences.dart';
import '../services/switchable_cloud_kv_store.dart';
import '../services/watchlist_store.dart';
import 'alerts_cubit.dart';
import 'guarded_emit.dart';
import 'holdings_cubit.dart';
import 'market_cubit.dart';
import 'settings_cubit.dart';
import 'sync_state.dart';
import 'tracked_instruments.dart';
import 'watchlist_cubit.dart';
import 'zakat_cubit.dart';

/// Keeping the book safe: iCloud sync, what is wrong with the book on this
/// device, and backup and restore. A cloud change or a restore can touch
/// every collection, so this is the one cubit that tells the others to read
/// their stores again.
class SyncCubit extends Cubit<SyncState> with GuardedEmit<SyncState> {
  /// Shared cloud key-value backend for every synced store + `Preferences`
  /// (spec Phase 7). Always constructed (even on platforms/tests that never
  /// enable it) so every store default-constructs against the SAME instance
  /// rather than each getting their own — turning sync on/off is then just
  /// [SwitchableCloudKVStore.setEnabled], with no store ever rebuilt. Callers
  /// that inject their own stores (most unit tests) bypass this entirely —
  /// each of those stores keeps whatever cloud backend it was given
  /// (normally none, i.e. [LocalOnlyCloudKVStore]).
  final SwitchableCloudKVStore cloudStore;

  /// The money ledger (v5). Owned here only so it shares [cloudStore] and
  /// travels in backups; `MoneyCubit` reads and writes it.
  final BookStore bookStore;

  final WatchlistStore _watchlistStore;
  final CustomInstrumentStore _customInstrumentStore;
  final AlertsStore _alertsStore;

  final WatchlistCubit _watchlist;
  final HoldingsCubit _holdings;
  final AlertsCubit _alerts;
  final ZakatCubit _zakat;
  final SettingsCubit _settings;
  final MarketCubit _market;

  /// Runs a reload of several cubits so what listens to all of them (the
  /// home-screen widgets) sees the result once, not each step.
  final Future<void> Function(Future<void> Function() body) _batch;

  /// Set by `MoneyCubit`'s owner: reloads the money ledger after another
  /// device changed [key], or every part of it when [key] is null (a
  /// restore).
  Future<void> Function(String? key)? onBookChanged;

  /// Told whenever [SyncState.iCloudSyncEnabled] changes, so that what else
  /// goes to iCloud (the CloudKit change log sync) follows the same switch.
  void Function(bool enabled)? onICloudSyncChanged;

  @override
  void onChange(Change<SyncState> change) {
    super.onChange(change);
    if (change.currentState.iCloudSyncEnabled != change.nextState.iCloudSyncEnabled) onICloudSyncChanged?.call(change.nextState.iCloudSyncEnabled);
  }

  StreamSubscription<CloudKVChangeEvent>? _cloudChangesSubscription;

  /// Cloud-change events being handled. A change this device makes itself
  /// (merging on enable) comes back as an event whose reload writes the
  /// local mirror, so whoever waits for a sync, or tears the cloud down,
  /// waits for these too.
  final Set<Future<void>> _handling = {};

  /// How long [setICloudSyncEnabled] and [disposeCloudSync] wait for those;
  /// a handler stuck on the cloud must not hold either for ever.
  @visibleForTesting
  Duration settleLimit = const Duration(seconds: 5);

  /// Set by [disposeCloudSync]: the cloud store is released, so a handler
  /// still running leaves it alone.
  bool _cloudDisposed = false;

  /// Takes what devices on an earlier build still write to the old cloud keys
  /// into the book. Only ever runs while the cloud is on.
  late final LegacyAbsorber _legacy = LegacyAbsorber.forBook(bookStore, cloudStore, enabled: () => cloudStore.enabled);

  /// What stopped the last read of the old cloud keys (an error from a store
  /// or the cloud, or an old value this build cannot read), or null. The
  /// next cloud change or start tries again.
  Object? get legacyAbsorbProblem => _legacyProblem ?? _legacy.lastProblem;
  Object? _legacyProblem;

  /// Maps a `SyncedStore.cloudKey` to the reload routine for that store, so
  /// an external-change event naming that key reloads only the affected
  /// store instead of everything (spec Phase 7 "external-change event
  /// reloads the right store"). Populated in [startSync] once every store
  /// exists.
  Map<String, Future<void> Function()> _reloadByCloudKey = {};

  /// Assigned by [start], at start-up, with the preferences it needs.
  Preferences? _preferences;
  BackupService? _backupService;
  bool _iCloudAccountAvailable = true;
  bool _cloudEnabledAtStartup = false;

  /// True while the last read of the trades failed, until one succeeds.
  bool _loadFailed = false;

  SyncCubit({
    required this.cloudStore,
    required this.bookStore,
    required WatchlistStore watchlistStore,
    required CustomInstrumentStore customInstrumentStore,
    required AlertsStore alertsStore,
    required WatchlistCubit watchlist,
    required HoldingsCubit holdings,
    required AlertsCubit alerts,
    required ZakatCubit zakat,
    required SettingsCubit settings,
    required MarketCubit market,
    required Future<void> Function(Future<void> Function() body) batch,
  })  : _watchlistStore = watchlistStore,
        _customInstrumentStore = customInstrumentStore,
        _alertsStore = alertsStore,
        _watchlist = watchlist,
        _holdings = holdings,
        _alerts = alerts,
        _zakat = zakat,
        _settings = settings,
        _market = market,
        _batch = batch,
        super(const SyncState());

  // ---------------------------------------------------------------------
  // Start-up
  // ---------------------------------------------------------------------

  /// The first half of start-up: builds [backupService] and resolves (and,
  /// if applicable, enables) the cloud backend BEFORE any store's
  /// `load()`/seeding runs — critical for the "first-enable on a device that
  /// already has local data" case (spec Phase 7): if the cloud store were
  /// enabled only after seeding, a fresh device would seed its local mirror
  /// from `InstrumentCatalog.defaultWatchlist` while looking at an empty
  /// (not-yet-connected) cloud, and that seeded data would then merge back IN
  /// alongside whatever's really in the cloud instead of the cloud's real
  /// state being seen first. Enabling first means `WatchlistStore.load()`'s
  /// seed check (`local.isEmpty && cloud.isEmpty`) sees the real cloud
  /// contents, so a device joining an already-populated account merges into
  /// it instead of re-seeding defaults next to it.
  Future<void> start(Preferences preferences) async {
    _preferences = preferences;
    _backupService = BackupService(
      watchlistStore: _watchlistStore,
      customInstrumentStore: _customInstrumentStore,
      alertsStore: _alertsStore,
      bookStore: bookStore,
      preferences: preferences,
    );

    _iCloudAccountAvailable = platformSupportsICloud ? await cloudStore.accountStatus() : false;
    _cloudEnabledAtStartup = preferences.iCloudSyncEnabled && _iCloudAccountAvailable;
    cloudStore.setEnabled(_cloudEnabledAtStartup);
    if (_cloudEnabledAtStartup) {
      await cloudStore.synchronize();
      // Before the first load, so what an old device wrote is already in the
      // book when it is read.
      await _absorbLegacy();
    }
  }

  /// The second half of start-up, once the trades are loaded: the book's
  /// health and the sync and backup status.
  Future<void> load() async {
    final preferences = _preferences!;
    final iCloudSyncEnabled = preferences.iCloudSyncEnabled;
    final health = await _readHealth();
    emit(SyncState(
      backupReminderDue: backupService.isReminderDue(),
      iCloudSyncEnabled: iCloudSyncEnabled,
      iCloudAccountAvailable: _iCloudAccountAvailable,
      bookHealth: health,
      cloudSyncStatus: _settled(
        _statusFor(
          syncEnabled: iCloudSyncEnabled,
          accountAvailable: _iCloudAccountAvailable,
          platformSupported: platformSupportsICloud,
        ),
        health,
      ),
      lastCloudSyncAt: _cloudEnabledAtStartup ? DateTime.now() : null,
    ));
  }

  CloudSyncStatus _statusFor({
    required bool syncEnabled,
    required bool accountAvailable,
    required bool platformSupported,
  }) {
    if (!platformSupported || !syncEnabled) return CloudSyncStatus.disabled;
    if (!accountAvailable) return CloudSyncStatus.notSignedIn;
    return CloudSyncStatus.upToDate;
  }

  /// Registers which store to reload when an external-change event names
  /// its cloud key, and starts listening for them if this platform can
  /// support iCloud at all. Called once at the end of start-up, AFTER the
  /// cloud backend has already been enabled/synced for the startup case (see
  /// [start]) — this only wires the ongoing listener, it doesn't repeat that
  /// initial enable/merge.
  void startSync() {
    _reloadByCloudKey = {
      // First, so an event naming nothing absorbs before the ledger reloads.
      for (final key in LegacyAbsorber.keys) key: () async => _reloadAfterLegacy(await _absorbLegacy()),
      'watchcards.records': () => _serialized(_applyCards),
      'custominstruments.records': () => _watchlist.loadCustomInstruments(),
      'alerts.records': () => _serialized(_applyAlerts),
      'zakatSettings': () => _serialized(_applyZakat),
      for (final key in BookStore.cloudKeys)
        if (key != BookStore.entriesKey) key: () async => onBookChanged?.call(key),
      // The trades are entries of the book: a change there reaches both.
      BookStore.entriesKey: () async {
        await _serialized(_applyTrades);
        await onBookChanged?.call(BookStore.entriesKey);
      },
    };

    if (!platformSupportsICloud) return;
    _cloudChangesSubscription ??= cloudStore.didChangeExternally.listen(_trackCloudChange);
  }

  // ---------------------------------------------------------------------
  // iCloud sync
  // ---------------------------------------------------------------------

  /// Re-checks `accountStatus()` and reconciles [SyncState]/[cloudStore] with
  /// it, then — if both the platform, the account and the user's preference
  /// allow it — performs the actual enable/merge sync. Used by
  /// [setICloudSyncEnabled] (user flips the switch) and by
  /// [_handleCloudChange] for an `accountChange` event; [start] does its own
  /// first-enable pass directly (see the ordering comment there) rather than
  /// calling this, since this emits [CloudSyncStatus.syncing] transiently in
  /// a way that would flash before the first emit of [load].
  Future<void> _refreshICloudAvailabilityAndSync({required bool userInitiatedEnable}) async {
    if (!platformSupportsICloud) {
      cloudStore.setEnabled(false);
      if (isClosed) return;
      emit(state.copyWith(
        iCloudSyncEnabled: userInitiatedEnable,
        iCloudAccountAvailable: false,
        cloudSyncStatus: CloudSyncStatus.disabled,
      ));
      return;
    }

    final accountAvailable = await cloudStore.accountStatus();
    if (isClosed || _cloudDisposed) return;
    emit(state.copyWith(iCloudAccountAvailable: accountAvailable));

    if (!userInitiatedEnable || !accountAvailable) {
      cloudStore.setEnabled(false);
      _legacy.reset();
      if (isClosed) return;
      emit(state.copyWith(
        iCloudSyncEnabled: userInitiatedEnable,
        cloudSyncStatus: userInitiatedEnable ? CloudSyncStatus.notSignedIn : CloudSyncStatus.disabled,
      ));
      return;
    }

    if (isClosed) return;
    emit(state.copyWith(iCloudSyncEnabled: true, cloudSyncStatus: CloudSyncStatus.syncing));
    cloudStore.setEnabled(true);
    _legacy.reset();
    await adoptCloudChanges();
  }

  /// User-facing toggle for the Settings "Sync with iCloud" switch (spec
  /// Phase 7). Persists the preference (itself never synced — see
  /// `Preferences.iCloudSyncEnabled`) and, when turning ON, immediately
  /// merges — never wipes — whatever is already on this device with
  /// whatever is already in the cloud: every store's `load()` already does
  /// last-write-wins-per-item merge against the (now-enabled) cloud backend,
  /// so a device that had local-only data before enabling keeps it, folded
  /// together with anything already synced from another device. Turning OFF
  /// stops listening for external changes but leaves all local data and the
  /// last-synced cloud copy untouched — nothing is deleted either way.
  Future<void> setICloudSyncEnabled(bool value) async {
    if (value == state.iCloudSyncEnabled) return;
    await _preferences!.setICloudSyncEnabled(value);
    await _refreshICloudAvailabilityAndSync(userInitiatedEnable: value);
    await _settleCloudChanges();
  }

  void _trackCloudChange(CloudKVChangeEvent event) {
    final handling = _handleCloudChange(event);
    _handling.add(handling);
    // The error, if any, is reported once, as before it was tracked.
    unawaited(handling.whenComplete(() => _handling.remove(handling)));
  }

  /// Waits for the events being handled now, for at most [settleLimit];
  /// ones that arrive meanwhile are not waited for. Never called from a
  /// handler itself.
  Future<void> _settleCloudChanges() async {
    if (_handling.isEmpty) return;
    final handlers = Future.wait(_handling.toList().map((f) => f.then<void>((_) {}, onError: (Object _) {})));
    await handlers.timeout(settleLimit, onTimeout: () => const []);
  }

  /// Handles one `NSUbiquitousKeyValueStore.didChangeExternallyNotification`
  /// forwarded from the platform channel. Reloads only the store(s) named by
  /// the event's keys (spec Phase 7 "external-change event reloads the
  /// right store") — an event with no keys (iCloud sometimes omits them, and
  /// [CloudKVChangeReason.accountChange]/[CloudKVChangeReason.initialSyncChange]
  /// never carry a useful key list) reloads every synced store instead,
  /// since at that point any of them may have changed.
  Future<void> _handleCloudChange(CloudKVChangeEvent event) async {
    // `disposeCloudSync` cancels the stream subscription, but an event
    // already dispatched to this handler before that cancellation takes
    // effect can still be mid-flight across the `await`s below — guard every
    // `emit` in this method (and the reload helpers it calls) with
    // `isClosed` so a straggling event can never throw by emitting into a
    // closed `Cubit` after the owning widget/test has torn it down.
    if (isClosed || _cloudDisposed) return;
    switch (event.reason) {
      case CloudKVChangeReason.quotaViolationChange:
        emit(state.copyWith(cloudSyncStatus: CloudSyncStatus.storageFull));
        return;
      case CloudKVChangeReason.accountChange:
        // The signed-in account changed (switched or signed out) — re-check
        // rather than trust the stale `iCloudAccountAvailable`/cached data,
        // since keys now visible may belong to a different account.
        _legacy.reset();
        await _refreshICloudAvailabilityAndSync(userInitiatedEnable: state.iCloudSyncEnabled);
        return;
      case CloudKVChangeReason.serverChange:
      case CloudKVChangeReason.initialSyncChange:
      case CloudKVChangeReason.unknown:
        break;
    }

    emit(state.copyWith(cloudSyncStatus: CloudSyncStatus.syncing));
    final keysToReload = event.keys.isEmpty ? _reloadByCloudKey.keys.toList() : event.keys;
    await _batch(() async {
      for (final key in keysToReload) {
        if (isClosed || _cloudDisposed) return;
        final reload = _reloadByCloudKey[key];
        if (reload != null) await reload();
      }
    });
    await _refreshHealth();
    if (isClosed) return;
    emit(state.copyWith(cloudSyncStatus: _syncedStatus, lastCloudSyncAt: DateTime.now()));
  }

  /// Where a finished sync stands: up to date, unless a write was left out
  /// because the cloud store is full, or the book has a problem (see
  /// [_refreshHealth], which is run first).
  CloudSyncStatus get _syncedStatus => cloudStore.overLimit ? CloudSyncStatus.storageFull : _settled(CloudSyncStatus.upToDate, state.bookHealth);

  /// [status] unless it says "up to date" while [health] has a problem.
  static CloudSyncStatus _settled(CloudSyncStatus status, BookHealth health) =>
      status == CloudSyncStatus.upToDate && health.hasProblem ? CloudSyncStatus.needsAttention : status;

  /// Reads the old cloud keys into the book (see [LegacyAbsorber]) and
  /// returns the ledger keys that changed. A failure is kept in
  /// [legacyAbsorbProblem] and the next run tries again; it never stops the
  /// sync it is part of.
  Future<Set<String>> _absorbLegacy() async {
    try {
      final changed = await _legacy.absorb();
      _legacyProblem = null;
      return changed;
    } catch (error) {
      _legacyProblem = error;
      debugPrint('Reading the old cloud keys failed: $error');
      return {};
    }
  }

  /// Reloads what [changed] ledger keys (from [_absorbLegacy]) touched, the
  /// way a change of those keys by another device would: the trades and the
  /// book for entries, the book for the others. Entries last, so no entry is
  /// shown before the account it posts to.
  Future<void> _reloadAfterLegacy(Set<String> changed) async {
    for (final key in [BookStore.accountsKey, BookStore.recurringKey, BookStore.settingsKey, BookStore.entriesKey]) {
      if (isClosed) return;
      if (!changed.contains(key)) continue;
      if (key == BookStore.entriesKey) await _serialized(_applyTrades);
      await onBookChanged?.call(key);
    }
  }

  /// Runs a full first-enable/merge pass across every synced store — each
  /// store's `load()` merges local+cloud last-write-wins-per-item (spec
  /// Phase 7 "first-enable on a device that already has local data"), so
  /// this can never wipe local data, only fold it together with the cloud's
  /// copy. Also starts the underlying `NSUbiquitousKeyValueStore.synchronize()`
  /// pass so a prompt round-trip is more likely.
  Future<void> adoptCloudChanges() async {
    if (!state.iCloudSyncEnabled) return;
    await cloudStore.synchronize();
    // Before the loads below, which then include what it took.
    await _absorbLegacy();
    await _batch(() => _serialized(_reloadCollections));
    await onBookChanged?.call(null);
    await _refreshHealth();
    if (isClosed) return;
    emit(state.copyWith(cloudSyncStatus: _syncedStatus, lastCloudSyncAt: DateTime.now()));
  }

  /// Shows what the CloudKit change log sync took into the book: the trades
  /// and the whole money ledger are read again, the way a cloud change of
  /// every key would. It runs on the same queue as the other reloads, so it
  /// never interleaves with one, and does nothing once this cubit is closed
  /// or the cloud is released.
  Future<void> reloadAfterLogSync() async {
    if (isClosed || _cloudDisposed) return;
    await _batch(() => _serialized(() async {
          if (isClosed || _cloudDisposed) return;
          await _applyTrades();
          await onBookChanged?.call(null);
        }));
    await _refreshHealth();
  }

  /// Cancels the cloud-change subscription — called from tests/teardown or
  /// when the owning widget is disposed, so no native event listener
  /// outlives this cubit. Closing the cubit does not do it (flutter_bloc's
  /// `Cubit.close()` doesn't know about this subscription), so callers that
  /// construct a long-lived [SyncCubit] and later discard it should call this
  /// explicitly.
  Future<void> disposeCloudSync() async {
    await _cloudChangesSubscription?.cancel();
    _cloudChangesSubscription = null;
    await _settleCloudChanges();
    _cloudDisposed = true;
    await cloudStore.dispose();
  }

  // ---------------------------------------------------------------------
  // Book health
  // ---------------------------------------------------------------------

  /// Told after every read of the trades whether it failed; the failure
  /// stays in [BookHealth.loadFailed] until a read succeeds.
  void tradesLoaded({required bool failed}) => _loadFailed = failed;

  /// Records that a load made outside this cubit (the money ledger, at
  /// start-up) failed, so Settings says so.
  Future<void> noteLoadFailed() async {
    _loadFailed = true;
    await _refreshHealth();
  }

  /// What is wrong with the book now: the migration steps that did not
  /// finish, an unreadable old cloud value, a collection written by a newer
  /// build, a failed load. Never throws.
  Future<BookHealth> _readHealth() async {
    var migrationFailed = false;
    try {
      migrationFailed = (await bookStore.ledgerProblems()).isNotEmpty;
    } catch (error) {
      debugPrint('Reading the migration state failed: $error');
    }
    return BookHealth(
      migrationFailed: migrationFailed,
      legacyUnreadable: legacyAbsorbProblem != null,
      newerVersion: [bookStore.accounts, bookStore.entries, bookStore.recurring, bookStore.settings].any((s) => s.cloudValueUnreadable),
      loadFailed: _loadFailed,
    );
  }

  /// Reads [BookHealth] again and, when it changed, publishes it with the
  /// sync status that goes with it.
  Future<void> _refreshHealth() async {
    final health = await _readHealth();
    if (isClosed || health == state.bookHealth) return;
    final status = state.cloudSyncStatus == CloudSyncStatus.needsAttention ? CloudSyncStatus.upToDate : state.cloudSyncStatus;
    emit(state.copyWith(bookHealth: health, cloudSyncStatus: _settled(status, health)));
  }

  // ---------------------------------------------------------------------
  // Backup & restore (spec Phase 6)
  // ---------------------------------------------------------------------

  /// The backup service, assigned by [start] — a handful of unit tests
  /// construct the cubits directly and call a mutator without ever starting
  /// up, so [backupServiceOrNull] is what callers that may run that early
  /// read.
  BackupService get backupService => _backupService!;

  /// Null-safe access to [backupService] for callers that may run before
  /// [start] has finished (or, in tests, before it's called at all) — it
  /// assigns [backupService] only after the async-created [Preferences] it
  /// depends on, so it's genuinely unavailable for a brief window rather
  /// than merely inconvenient to check. UI that wants to show backup status
  /// (see `SettingsScreen`'s `_BackupSection`) reads through this rather than
  /// the getter directly, so it degrades to an empty state instead of
  /// crashing when rendered that early.
  BackupService? get backupServiceOrNull => _backupService;

  /// Recomputes [SyncState.backupReminderDue] from [BackupService] — called
  /// after any user-collection mutation (which marks
  /// `dataChangedSinceLastBackup`) and after a successful export/import, so
  /// the Settings/Backup reminder card appears and disappears immediately
  /// rather than waiting for the next unrelated rebuild.
  Future<void> refreshBackupReminder() async {
    final service = _backupService;
    if (service == null) return;
    final due = service.isReminderDue();
    if (due != state.backupReminderDue) {
      emit(state.copyWith(backupReminderDue: due));
    }
  }

  /// Marks that user data changed since the last backup — called by every
  /// watchlist/holdings/custom-ticker/alert mutator so the Phase 6 backup
  /// reminder only fires when there's actually something new to protect.
  /// Tolerates an un-started cubit by treating it as "nothing to do yet"
  /// rather than throwing.
  Future<void> markDataChanged() async {
    final service = _backupService;
    if (service == null) return;
    await service.setDataChangedSinceLastBackup(true);
    await refreshBackupReminder();
  }

  /// Applies an already-decoded, already-decrypted [payload] to every store
  /// in [mode] via [BackupService.import], then reloads every store and
  /// preference back into the app — so it reflects the restored data
  /// immediately rather than requiring a restart. Called only after
  /// `ImportPreviewScreen` has a fully validated [BackupPayload] in hand
  /// (see `BackupCodec.decodePayload`), so nothing here can partially apply
  /// a corrupt/mistyped file.
  Future<void> restoreFromBackup(BackupPayload payload, {required BackupImportMode mode}) async {
    await backupService.import(payload, mode: mode);
    await _batch(() => _serialized(() => _reloadCollections(settings: true)));
    unawaited(_market.refreshAll());
    unawaited(BackgroundRefresh.register(interval: _settings.state.widgetRefreshInterval.timeInterval));
    await onBookChanged?.call(null);
    await _refreshHealth();
    await refreshBackupReminder();
  }

  /// Reloads run one at a time, so two of them (an event while a restore is
  /// running, two events) never show what they read out of order.
  Future<void> _reloading = Future.value();

  Future<void> _serialized(Future<void> Function() reload) {
    final run = _reloading.then((_) => reload());
    _reloading = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// Re-reads every synced collection (and, for a restore, the preferences a
  /// backup holds) from disk and shows them, in an order in which no
  /// listener sees data valued with settings or prices it was not read
  /// with: the settings first, then each collection with the cached prices
  /// of what it tracks already in place. Safe to call any time local storage
  /// might have changed out from under the in-memory state.
  ///
  /// Every collection is shown the moment it is read, with nothing awaited
  /// in between, so what is shown is the store as of then: a change made
  /// while an earlier step waited (a card added, an alert saved) is in the
  /// store and so in what is read, never overwritten by an older read.
  Future<void> _reloadCollections({bool settings = false}) async {
    // Before the cards, which may name a custom ticker.
    await _watchlist.loadCustomInstruments();
    if (settings) _settings.adopt(await _settings.readRestored());
    await _applyCards();
    await _applyTrades();
    await _applyAlerts();
    await _applyZakat();
  }

  /// Shows the stored cards with the cached prices of what they track. Prices
  /// still missing are read first, then the cards are read again, since
  /// reading the prices takes time in which the cards may have changed.
  Future<void> _applyCards() async {
    while (true) {
      final cards = await _watchlist.read();
      final missing = _market.withoutPrice(trackedInstrumentsFor(cards, _holdings.state.transactions));
      if (missing.isEmpty) return _watchlist.adopt(cards);
      _market.adoptSeries(await _market.readMissingSeries(missing));
    }
  }

  /// The same for the trades, which are left as they are when unreadable.
  Future<void> _applyTrades() async {
    while (true) {
      final transactions = await _holdings.read();
      if (transactions == null) return;
      final missing = _market.withoutPrice(trackedInstrumentsFor(_watchlist.state.cards, transactions));
      if (missing.isEmpty) return _holdings.adopt(transactions);
      _market.adoptSeries(await _market.readMissingSeries(missing));
    }
  }

  Future<void> _applyAlerts() async => _alerts.adopt(await _alerts.read());

  Future<void> _applyZakat() async => _zakat.adopt(await _zakat.read());
}
