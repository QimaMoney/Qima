import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qima/blocs/app_blocs.dart';
import 'package:qima/blocs/sync_state.dart';
import 'package:qima/models/asset.dart';
import 'package:qima/models/fx_history.dart';
import 'package:qima/models/holding_transaction.dart';
import 'package:qima/models/instrument_catalog.dart';
import 'package:qima/models/quote.dart';
import 'package:qima/models/watch_card.dart';
import 'package:qima/services/local_file_store.dart';
import 'package:qima/services/notification_service.dart';
import 'package:qima/services/price_repository.dart';
import 'package:qima/services/switchable_cloud_kv_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stands in for `PriceRepository` so nothing here hits the network — mirrors
/// `restore_from_backup_test.dart`'s `_NoopRepository`.
class _NoopRepository extends PriceRepository {
  @override
  Future<QuoteSeries> refresh(Instrument instrument, {DateTime? now}) async => QuoteSeries.empty(instrument.id);

  @override
  Future<Map<String, QuoteSeries>> refreshAll(List<Instrument> instruments, {DateTime? now}) async => {};

  @override
  Future<FXHistory> backfillFXHistory(List<String> currencies, {bool force = false, DateTime? now}) async =>
      FXHistory.empty;

  @override
  Future<Map<String, QuoteSeries>> backfillInstruments(
    List<Instrument> instruments,
    FXHistory fxHistory, {
    bool force = false,
    DateTime? now,
  }) async =>
      {};
}

/// Avoids touching the real `flutter_local_notifications` plugin (which
/// needs a registered platform instance this test's plain widget binding
/// doesn't provide) — mirrors `alerts_screen_test.dart`'s
/// `_FakeNotificationService`, but also short-circuits `init()` since these
/// tests DO run the full `AppBlocs.init()`.
class _FakeNotificationService extends NotificationService {
  @override
  Future<void> init() async {}

  @override
  Future<bool> isEnabled() async => true;
}

/// Phase 7 "iCloud key-value sync" — exercises the whole stack (`AppBlocs` +
/// `SwitchableCloudKVStore` + `SyncedStore`/`Preferences`) against the SAME
/// mocked `qima/cloud_kv` channels `icloud_kv_store_test.dart` mocks, so two
/// [AppBlocs]s (each with its own local storage directory, sharing the one
/// mocked "cloud") stand in for two real devices sharing one iCloud account.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // `platformSupportsICloud` gates on `defaultTargetPlatform ==
  // TargetPlatform.iOS` (spec Phase 7: iCloud KVS is iOS-only for now) — the
  // test host defaults to Android, so every test in this file needs the
  // override or sync would never actually turn on.
  setUpAll(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  });
  tearDownAll(() {
    debugDefaultTargetPlatformOverride = null;
  });

  const methodChannel = MethodChannel('qima/cloud_kv');
  const eventChannel = EventChannel('qima/cloud_kv/changes');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Map<String, String> cloudValues;
  late List<void Function(Map<String, Object?>)> listeners;

  void broadcastChange(String key, {String reason = 'serverChange'}) {
    for (final listener in listeners) {
      listener({
        'keys': [key],
        'reason': reason,
      });
    }
  }

  /// Starts watching [cubit]'s state stream for a FRESH arrival at [status]
  /// — call this BEFORE triggering whatever change is expected to produce
  /// it (a broadcast cloud-change event, or a user-initiated toggle), then
  /// call the returned function to await it. Subscribing first (rather than
  /// checking `cubit.state.cloudSyncStatus == status` after the fact) is the
  /// point: the cubit is very often ALREADY sitting at [status] (e.g.
  /// `upToDate` left over from a previous cycle) at the moment a naive
  /// check would run, so a check-after-triggering shortcut is wrong here —
  /// it accepts stale state and returns immediately without ever having
  /// waited for the real `syncing` -> (reload) -> `upToDate` (or
  /// `quotaViolationChange` -> `storageFull`) cycle the trigger actually
  /// caused. This is the same class of bug as the `pumpEventQueue()` it
  /// replaces, just one level up: both accept "looks done" instead of
  /// awaiting the specific async work that was just started.
  Future<void> Function() watchForCloudSyncStatus(AppBlocs cubit, CloudSyncStatus status) {
    final completer = Completer<void>();
    final subscription = cubit.sync.stream.listen((s) {
      if (s.cloudSyncStatus == status && !completer.isCompleted) {
        completer.complete();
      }
    });
    return () async {
      try {
        await completer.future.timeout(const Duration(seconds: 5));
      } finally {
        await subscription.cancel();
      }
    };
  }

  setUp(() {
    cloudValues = {};
    listeners = [];
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      switch (call.method) {
        case 'getString':
          final key = (call.arguments as Map)['key'] as String;
          return cloudValues[key];
        case 'setString':
          final args = call.arguments as Map;
          final key = args['key'] as String;
          final value = args['value'] as String;
          final changed = cloudValues[key] != value;
          cloudValues[key] = value;
          if (changed) broadcastChange(key);
          return null;
        case 'synchronize':
          return true;
        case 'accountStatus':
          return true;
      }
      return null;
    });
    messenger.setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          listeners.add((payload) => events.success(payload));
        },
        onCancel: (arguments) {},
      ),
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methodChannel, null);
    messenger.setMockStreamHandler(eventChannel, null);
  });

  final gold = InstrumentCatalog.instrument('metal.XAU')!;
  final silver = InstrumentCatalog.instrument('metal.XAG')!;

  /// Builds a fresh [AppBlocs] pointed at its own temp local-storage
  /// directory and its own [SharedPreferences] instance (so it behaves like
  /// an independent device), sharing the mocked cloud channel above. Runs
  /// the real [AppBlocs.init] so seeding/first-enable ordering matches
  /// production.
  Future<AppBlocs> device(Directory dir, {bool iCloudSyncEnabled = true}) async {
    LocalFileStore.overrideDirectoryForTesting(dir);
    SharedPreferences.setMockInitialValues({'iCloudSyncEnabled': iCloudSyncEnabled});
    final cubit = AppBlocs(
      repository: _NoopRepository(),
      cloudStore: SwitchableCloudKVStore(),
      notificationService: _FakeNotificationService(),
    );
    await cubit.init();
    return cubit;
  }

  /// Waits for the work a cloud change started on each device. A store runs
  /// its operations in call order, so a load queued now finishes after the
  /// ones already waiting, and the directory is not deleted under them.
  Future<void> settle(List<AppBlocs> devices) async {
    for (final d in devices) {
      await d.watchlist.watchlistStore.load();
      await d.holdings.ledgerStore.load();
    }
  }

  group('two devices sharing a fake cloud', () {
    test('a card added on device A appears on device B after B enables sync', () async {
      final dirA = await Directory.systemTemp.createTemp('qima_icloud_a');
      final deviceA = await device(dirA);
      // A non-USD currency avoids colliding with the default-seeded
      // USD/troy-ounce gold card every fresh device gets — `WatchlistCubit.addCard`
      // treats a matching instrument+currency+unit+karat combo as "already
      // there" (`isSameCombo`) regardless of id, so a USD card here would
      // silently no-op against the seed instead of adding a new one.
      await deviceA.watchlist.addCard(WatchCard(id: 'c1', instrumentID: gold.id, currency: 'EGP', unit: PriceUnit.troyOunce));
      await deviceA.sync.disposeCloudSync();

      final dirB = await Directory.systemTemp.createTemp('qima_icloud_b');
      final deviceB = await device(dirB);

      expect(deviceB.watchlist.state.cards.map((c) => c.id), contains('c1'));
      await deviceB.sync.disposeCloudSync();
      await dirA.delete(recursive: true);
      await dirB.delete(recursive: true);
    });

    // Every fresh device also seeds `InstrumentCatalog.defaultWatchlist`
    // (gold/silver/BTC in USD) — these tests use EGP so the cards they add
    // are genuinely new items rather than colliding, via
    // `WatchCard.isSameCombo`, with that seed (see the comment on the first
    // test in this group).
    test('edits and deletes converge across two devices', () async {
      final dirA = await Directory.systemTemp.createTemp('qima_icloud_edit_a');
      final deviceA = await device(dirA);
      final defaultIds = deviceA.watchlist.state.cards.map((c) => c.id).toSet();
      await deviceA.watchlist.addCard(WatchCard(id: 'c1', instrumentID: gold.id, currency: 'EGP', unit: PriceUnit.troyOunce));
      await deviceA.watchlist.addCard(WatchCard(id: 'c2', instrumentID: silver.id, currency: 'EGP', unit: PriceUnit.troyOunce));

      final dirB = await Directory.systemTemp.createTemp('qima_icloud_edit_b');
      final deviceB = await device(dirB);
      expect(deviceB.watchlist.state.cards.map((c) => c.id).toSet(), {...defaultIds, 'c1', 'c2'});

      // B deletes c2; A concurrently reorders (no-op mutation on c1's data
      // isn't available directly, so use removeCard on B and re-load A).
      await deviceB.watchlist.removeCard('c2');
      final reloadedA = await deviceA.watchlist.watchlistStore.load();
      expect(reloadedA.map((c) => c.id).toSet(), {...defaultIds, 'c1'});

      await settle([deviceA, deviceB]);
      await deviceA.sync.disposeCloudSync();
      await deviceB.sync.disposeCloudSync();
      await dirA.delete(recursive: true);
      await dirB.delete(recursive: true);
    });

    test('reorder on one device is respected by the other after reload', () async {
      final dirA = await Directory.systemTemp.createTemp('qima_icloud_reorder_a');
      final deviceA = await device(dirA);
      await deviceA.watchlist.addCard(WatchCard(id: 'c1', instrumentID: gold.id, currency: 'EGP', unit: PriceUnit.troyOunce));
      await deviceA.watchlist.addCard(WatchCard(id: 'c2', instrumentID: silver.id, currency: 'EGP', unit: PriceUnit.troyOunce));

      // Reverse the whole order via `setOrder` directly, so the expected
      // result doesn't depend on reasoning about `move`'s from/to index
      // semantics — only that A's chosen order round-trips through B.
      final reversed = deviceA.watchlist.state.cards.map((c) => c.id).toList().reversed.toList();
      await deviceA.watchlist.watchlistStore.setOrder(reversed);
      final reloadedA = await deviceA.watchlist.watchlistStore.load();
      expect(reloadedA.map((c) => c.id).toList(), reversed);

      final dirB = await Directory.systemTemp.createTemp('qima_icloud_reorder_b');
      final deviceB = await device(dirB);
      expect(deviceB.watchlist.state.cards.map((c) => c.id).toList(), reversed);

      await deviceA.sync.disposeCloudSync();
      await deviceB.sync.disposeCloudSync();
      await dirA.delete(recursive: true);
      await dirB.delete(recursive: true);
    });

    test('a tombstoned delete on A is respected by B, not resurrected by an unrelated reload', () async {
      final dirA = await Directory.systemTemp.createTemp('qima_icloud_tomb_a');
      final deviceA = await device(dirA);
      final added =
          await deviceA.watchlist.addCard(WatchCard(id: 'c1', instrumentID: gold.id, currency: 'EGP', unit: PriceUnit.troyOunce));
      expect(added.created, isTrue);

      final dirB = await Directory.systemTemp.createTemp('qima_icloud_tomb_b');
      final deviceB = await device(dirB);
      expect(deviceB.watchlist.state.cards.map((c) => c.id), contains('c1'));

      await deviceA.watchlist.removeCard('c1');
      final reloadedB = await deviceB.watchlist.watchlistStore.load();
      expect(reloadedB.map((c) => c.id), isNot(contains('c1')));

      await deviceA.sync.disposeCloudSync();
      await deviceB.sync.disposeCloudSync();
      await dirA.delete(recursive: true);
      await dirB.delete(recursive: true);
    });
  });

  group('first-enable on a device that already has local data', () {
    test('local data merges with the cloud rather than being wiped', () async {
      // Device A seeds the cloud with a card.
      final dirA = await Directory.systemTemp.createTemp('qima_icloud_first_a');
      final deviceA = await device(dirA);
      await deviceA.watchlist.addCard(WatchCard(id: 'cloud-card', instrumentID: gold.id, currency: 'EGP', unit: PriceUnit.troyOunce));
      await deviceA.sync.disposeCloudSync();

      // Device B starts with sync OFF and adds its own local-only card first.
      final dirB = await Directory.systemTemp.createTemp('qima_icloud_first_b');
      final deviceB = await device(dirB, iCloudSyncEnabled: false);
      final defaultIds = deviceB.watchlist.state.cards.map((c) => c.id).toSet();
      await deviceB.watchlist.addCard(
          WatchCard(id: 'local-card', instrumentID: silver.id, currency: 'EGP', unit: PriceUnit.troyOunce));
      expect(deviceB.watchlist.state.cards.map((c) => c.id).toSet(), {...defaultIds, 'local-card'});

      // Now B turns sync on: every card (its own defaults, its local-only
      // addition, AND A's cloud addition) must still be present afterward —
      // local data is never wiped by enabling.
      await deviceB.sync.setICloudSyncEnabled(true);
      expect(deviceB.watchlist.state.cards.map((c) => c.id).toSet(), {...defaultIds, 'local-card', 'cloud-card'});
      expect(deviceB.sync.state.cloudSyncStatus, CloudSyncStatus.upToDate);

      await deviceA.sync.disposeCloudSync();
      await deviceB.sync.disposeCloudSync();
      await dirA.delete(recursive: true);
      await dirB.delete(recursive: true);
    });
  });

  group('toggling sync off/on', () {
    test('turning sync off then on again keeps local data and re-merges instead of overwriting', () async {
      final dirA = await Directory.systemTemp.createTemp('qima_icloud_toggle_a');
      final deviceA = await device(dirA);
      final defaultIds = deviceA.watchlist.state.cards.map((c) => c.id).toSet();
      // NOTE: unlike the real `NSUbiquitousKeyValueStore` (which never fires
      // `didChangeExternallyNotification` for a change this same process
      // just made), this test's mocked channel broadcasts on every
      // `setString` regardless of origin, so `addCard`'s own write loops
      // back as a (harmless, self-)external-change event here — its
      // asynchronous re-sync briefly reports `syncing` before settling back
      // to `upToDate`. Subscribe BEFORE triggering the add, so the wait
      // below can't miss (or mistake a stale prior state for) the fresh
      // reload cycle this specific write causes.
      final settled = watchForCloudSyncStatus(deviceA, CloudSyncStatus.upToDate);
      await deviceA.watchlist.addCard(WatchCard(id: 'c1', instrumentID: gold.id, currency: 'EGP', unit: PriceUnit.troyOunce));
      await settled();
      expect(deviceA.sync.state.cloudSyncStatus, CloudSyncStatus.upToDate);

      await deviceA.sync.setICloudSyncEnabled(false);
      expect(deviceA.watchlist.state.cards.map((c) => c.id), contains('c1')); // Still there locally.
      expect(deviceA.sync.state.cloudSyncStatus, CloudSyncStatus.disabled);

      // While A is off, a second device adds another card to the cloud.
      final dirB = await Directory.systemTemp.createTemp('qima_icloud_toggle_b');
      final deviceB = await device(dirB);
      await deviceB.watchlist.addCard(WatchCard(id: 'c2', instrumentID: silver.id, currency: 'EGP', unit: PriceUnit.troyOunce));
      await deviceB.sync.disposeCloudSync();

      await deviceA.sync.setICloudSyncEnabled(true);
      expect(deviceA.watchlist.state.cards.map((c) => c.id).toSet(), {...defaultIds, 'c1', 'c2'});

      await deviceA.sync.disposeCloudSync();
      await dirA.delete(recursive: true);
      await dirB.delete(recursive: true);
    });
  });

  group('quota violation', () {
    test('a quotaViolationChange event surfaces a storage-full status', () async {
      final dir = await Directory.systemTemp.createTemp('qima_icloud_quota');
      final deviceCubit = await device(dir);
      expect(deviceCubit.sync.state.cloudSyncStatus, CloudSyncStatus.upToDate);

      final settled = watchForCloudSyncStatus(deviceCubit, CloudSyncStatus.storageFull);
      broadcastChange('watchcards.records', reason: 'quotaViolationChange');
      await settled();
      expect(deviceCubit.sync.state.cloudSyncStatus, CloudSyncStatus.storageFull);

      await deviceCubit.sync.disposeCloudSync();
      await dir.delete(recursive: true);
    });
  });

  group('external-change event reloads the right store', () {
    test('a ledger.entries change event reloads the trades and the book, and not the watchlist', () async {
      final dirA = await Directory.systemTemp.createTemp('qima_icloud_targeted2_a');
      final deviceA = await device(dirA);

      final dirB = await Directory.systemTemp.createTemp('qima_icloud_targeted2_b');
      final deviceB = await device(dirB);
      final cardsIdentityBefore = deviceB.watchlist.state.cards;
      final reloadedBook = <String?>[];
      deviceB.onBookChanged = (key) async => reloadedBook.add(key);

      // A trade made on A reaches the cloud as a change of the book's entries.
      // (Only B receives the event: see the note below.)
      LocalFileStore.overrideDirectoryForTesting(dirA);
      await deviceA.holdings.saveTransaction(HoldingTransaction(
        id: 'tx1',
        instrumentID: gold.id,
        kind: TransactionKind.buy,
        quantity: 2,
        unit: PriceUnit.troyOunce,
        unitPrice: 2000,
        currency: 'USD',
        date: DateTime(2026, 1, 1),
      ));
      expect(cloudValues.keys, contains('ledger.entries'));

      // NOTE: `EventChannel.receiveBroadcastStream()` registers its message
      // handler via `binaryMessenger.setMessageHandler(name, ...)`, keyed
      // only by channel NAME — with two devices (two independent
      // `IcloudKVStore`s) both listening on the same static
      // `qima/cloud_kv/changes` channel, the second `listen()` overwrites
      // the first's handler, so only the most-recently-listening device
      // (B) actually receives a dispatched event here; A's Dart-side
      // subscription stays alive but silently never gets this one. That's a
      // limitation of two `AppBlocs`s sharing one static channel name
      // in-process — real usage never has two — so only B's reload is
      // awaited/asserted on.
      LocalFileStore.overrideDirectoryForTesting(dirB);
      final settled = watchForCloudSyncStatus(deviceB, CloudSyncStatus.upToDate);
      broadcastChange('ledger.entries');
      await settled();

      expect(deviceB.holdings.state.transactions.map((t) => t.id), ['tx1'], reason: 'the holdings side reloaded');
      expect(reloadedBook, contains('ledger.entries'), reason: 'and so did the book');
      expect(reloadedBook.toSet(), {'ledger.entries'});
      expect(deviceB.watchlist.state.cards, same(cardsIdentityBefore));

      await settle([deviceA, deviceB]);
      await deviceA.sync.disposeCloudSync();
      await deviceB.sync.disposeCloudSync();
      await dirA.delete(recursive: true);
      await dirB.delete(recursive: true);
    });

    test('the old holdings keys are no longer loaded here', () async {
      final dir = await Directory.systemTemp.createTemp('qima_icloud_old_holdings');
      final deviceB = await device(dir);
      final reloadedBook = <String?>[];
      deviceB.onBookChanged = (key) async => reloadedBook.add(key);
      final transactionsBefore = deviceB.holdings.state.transactions;

      for (final key in ['holdings.records', 'transactions.records']) {
        cloudValues[key] = '[]';
        final settled = watchForCloudSyncStatus(deviceB, CloudSyncStatus.upToDate);
        broadcastChange(key);
        await settled();
      }

      expect(deviceB.holdings.state.transactions, same(transactionsBefore));
      expect(reloadedBook, isEmpty);

      await settle([deviceB]);
      await deviceB.sync.disposeCloudSync();
      await dir.delete(recursive: true);
    });
  });

  group('preferences that must not sync stay local', () {
    test('iCloudSyncEnabled itself is never written to the cloud store', () async {
      final dir = await Directory.systemTemp.createTemp('qima_icloud_pref_local');
      final deviceCubit = await device(dir);
      await deviceCubit.sync.setICloudSyncEnabled(false);
      await deviceCubit.sync.setICloudSyncEnabled(true);

      expect(cloudValues.containsKey('iCloudSyncEnabled'), isFalse);

      await deviceCubit.sync.disposeCloudSync();
      await dir.delete(recursive: true);
    });

    test('hideBalances, appLockEnabled and lockGrace never reach the cloud store', () async {
      final dir = await Directory.systemTemp.createTemp('qima_icloud_pref_local2');
      final deviceCubit = await device(dir);
      await deviceCubit.settings.setHideBalances(true);
      await deviceCubit.settings.setLockGrace(deviceCubit.settings.state.lockGrace);

      expect(cloudValues.containsKey('hideBalances'), isFalse);
      expect(cloudValues.containsKey('appLockEnabled'), isFalse);
      expect(cloudValues.containsKey('lockGrace'), isFalse);

      await deviceCubit.sync.disposeCloudSync();
      await dir.delete(recursive: true);
    });

    test('baseCurrency (a synced preference) DOES reach the cloud store', () async {
      final dir = await Directory.systemTemp.createTemp('qima_icloud_pref_synced');
      final deviceCubit = await device(dir);
      await deviceCubit.settings.setBaseCurrency('EGP');

      expect(cloudValues['baseCurrency'], 'EGP');

      await deviceCubit.sync.disposeCloudSync();
      await dir.delete(recursive: true);
    });
  });
}
