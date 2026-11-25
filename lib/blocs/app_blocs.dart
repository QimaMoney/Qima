import 'dart:async';
import 'dart:ui' show Locale;

import 'package:flutter_bloc/flutter_bloc.dart';

import '../models/asset.dart';
import '../services/ai_assist_provider.dart';
import '../services/alert_runtime_store.dart';
import '../services/alerts_store.dart';
import '../services/app_lock_service.dart';
import '../services/book_store.dart';
import '../services/custom_instrument_store.dart';
import '../services/dictation_service.dart';
import '../services/holdings_ledger.dart';
import '../services/notification_service.dart';
import '../services/platform_ai.dart';
import '../services/price_repository.dart';
import '../services/refresh_pipeline.dart';
import '../services/cloud_kv_store.dart' show platformSupportsICloud;
import '../services/switchable_cloud_kv_store.dart';
import '../services/sync/cloudkit_sync_transport.dart';
import '../services/text_recognition_service.dart';
import '../services/watchlist_store.dart';
import 'alerts_cubit.dart';
import 'app_cubit.dart';
import 'cloud_log_sync.dart';
import 'holdings_cubit.dart';
import 'market_cubit.dart';
import 'settings_cubit.dart';
import 'sync_cubit.dart';
import 'tracked_instruments.dart';
import 'watchlist_cubit.dart';
import 'widget_publisher.dart';
import 'zakat_cubit.dart';

/// The app's cubits, built over one set of stores and wired to each other.
/// Each cubit owns one concern and reads what it needs from another through
/// the constructor argument that names it; nothing reaches into another
/// cubit's private state. The wiring is all here:
///
/// - [market] knows what to fetch and what to do afterwards only through
///   callbacks, so it has no dependency on the watchlist or the holdings;
/// - [watchlist], [holdings] and [alerts] tell [sync] when data changed
///   (for the backup reminder), and [sync] tells them to read again after a
///   cloud change or a restore, in an order no listener sees a mix of old and
///   new in, with the widget publisher held until it is done;
/// - [app] runs start-up across all of them.
///
/// Stores are injectable, as they were for the single cubit this replaced,
/// so tests can run any cubit over a fake.
class AppBlocs {
  late final AppCubit app;
  late final SettingsCubit settings;
  late final MarketCubit market;
  late final WatchlistCubit watchlist;
  late final HoldingsCubit holdings;
  late final AlertsCubit alerts;
  late final ZakatCubit zakat;
  late final SyncCubit sync;
  late final CloudLogSync cloudLog;
  late final WidgetPublisher _widgets;

  AppBlocs({
    PriceRepository? repository,
    WatchlistStore? watchlistStore,
    // The store of the trades; the cubit over it is [HoldingsCubit].
    HoldingsLedger? holdings,
    CustomInstrumentStore? customInstrumentStore,
    AppLockService? appLockService,
    AlertsStore? alertsStore,
    AlertRuntimeStore? alertRuntimeStore,
    NotificationService? notificationService,
    SwitchableCloudKVStore? cloudStore,
    BookStore? bookStore,
    CloudLogSync? cloudLog,
    AiAssistProvider? aiAssist,
    DictationService? dictation,
    TextRecognitionService? textRecognition,
    Locale? deviceLocale,
  }) {
    // Built once up front so every default-constructed store below shares
    // the exact same backend — see `SyncCubit.cloudStore`.
    final cloud = cloudStore ?? SwitchableCloudKVStore();
    final book = bookStore ?? BookStore(cloud: cloud);
    final prices = repository ?? PriceRepository();
    final watchlistStore_ = watchlistStore ?? WatchlistStore(cloud: cloud);
    final ledgerStore = holdings ?? HoldingsLedger(book);
    final customs = customInstrumentStore ?? CustomInstrumentStore(cloud: cloud);
    final alertsStore_ = alertsStore ?? AlertsStore(cloud: cloud);
    final alertRuntime = alertRuntimeStore ?? AlertRuntimeStore();
    final notifications = notificationService ?? NotificationService();

    List<Instrument> tracked() => trackedInstrumentsFor(watchlist.state.cards, this.holdings.state.transactions);
    String baseCurrency() => settings.state.baseCurrency;
    Future<void> markDataChanged() => sync.markDataChanged();

    settings = SettingsCubit(
      appLockService: appLockService ?? AppLockService(),
      aiAssist: aiAssist ?? platformAiAssist(),
      dictation: dictation ?? const PlatformDictation(),
      textRecognition: textRecognition ?? const PlatformTextRecognition(),
    );
    market = MarketCubit(
      repository: prices,
      tracked: tracked,
      cardCurrencies: () => watchlist.state.cards.map((c) => c.currency),
      baseCurrency: baseCurrency,
      evaluateAlerts: (seriesByID, rates) => alerts.evaluateAfterRefresh(
        cards: watchlist.state.cards,
        seriesByID: seriesByID,
        rates: rates,
        fxHistory: market.state.fxHistory,
      ),
      notifyZakatIfDue: () => zakat.notifyIfDue(),
    );
    watchlist = WatchlistCubit(
      watchlistStore: watchlistStore_,
      customInstrumentStore: customs,
      market: market,
      baseCurrency: baseCurrency,
      markDataChanged: markDataChanged,
    );
    this.holdings = HoldingsCubit(
      ledgerStore: ledgerStore,
      market: market,
      baseCurrency: baseCurrency,
      tracked: tracked,
      markDataChanged: markDataChanged,
      loadResult: ({required bool failed}) => sync.tradesLoaded(failed: failed),
    );
    alerts = AlertsCubit(
      alertsStore: alertsStore_,
      alertRuntimeStore: alertRuntime,
      notificationService: notifications,
      markDataChanged: markDataChanged,
    );
    zakat = ZakatCubit(
      holdings: this.holdings,
      market: market,
      alerts: alerts,
      notificationService: notifications,
      baseCurrency: baseCurrency,
      markDataChanged: markDataChanged,
    );
    sync = SyncCubit(
      cloudStore: cloud,
      bookStore: book,
      watchlistStore: watchlistStore_,
      customInstrumentStore: customs,
      alertsStore: alertsStore_,
      watchlist: watchlist,
      holdings: this.holdings,
      alerts: alerts,
      zakat: zakat,
      settings: settings,
      market: market,
      batch: holdWidgets,
    );
    this.cloudLog = cloudLog ?? _cloudKitLog(book);
    sync.onICloudSyncChanged = (on) => unawaited(this.cloudLog.setICloudSyncOn(on));
    app = AppCubit(
      settings: settings,
      market: market,
      watchlist: watchlist,
      holdings: this.holdings,
      alerts: alerts,
      zakat: zakat,
      sync: sync,
      pipeline: (preferences, backupService) => RefreshPipeline(
        repository: prices,
        watchlistStore: watchlistStore_,
        holdings: ledgerStore,
        customInstrumentStore: customs,
        alertsStore: alertsStore_,
        alertRuntimeStore: alertRuntime,
        notificationService: notifications,
        preferences: preferences,
        backupService: backupService,
      ),
      deviceLocale: deviceLocale,
    );
    _widgets = WidgetPublisher(app: app, settings: settings, market: market, watchlist: watchlist, holdings: this.holdings);
  }

  /// The change log sync through CloudKit, off until the person turns it on,
  /// and used only where the build and the platform have CloudKit. A change
  /// it takes in reaches the rest of the app by the path cloud changes take.
  CloudLogSync _cloudKitLog(BookStore book) {
    final transport = CloudKitSyncTransport();
    return CloudLogSync(
      store: book,
      transport: transport,
      available: () async => platformSupportsICloud && await transport.available(),
      account: transport.account,
      reload: () => sync.reloadAfterLogSync(),
      iCloudSyncOn: false,
    );
  }

  /// One provider per cubit, for `MultiBlocProvider`.
  List<BlocProvider<StateStreamableSource<Object?>>> get providers => [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<SettingsCubit>.value(value: settings),
        BlocProvider<MarketCubit>.value(value: market),
        BlocProvider<WatchlistCubit>.value(value: watchlist),
        BlocProvider<HoldingsCubit>.value(value: holdings),
        BlocProvider<AlertsCubit>.value(value: alerts),
        BlocProvider<ZakatCubit>.value(value: zakat),
        BlocProvider<SyncCubit>.value(value: sync),
        BlocProvider<CloudLogSync>.value(value: cloudLog),
      ];

  /// Set by the owner of `MoneyCubit`: reloads the money ledger after the
  /// book changed under it by a trade saved here ([HoldingsCubit]) or by
  /// another device or a restore ([SyncCubit]); a null key means every part
  /// of it.
  set onBookChanged(Future<void> Function(String? key)? value) {
    holdings.onBookChanged = value;
    sync.onBookChanged = value;
  }

  /// Runs [body] with the home-screen widget publisher held, so what several
  /// cubits change in it is published once, when it is done.
  Future<void> holdWidgets(Future<void> Function() body) => _widgets.batch(body);

  /// Start-up; see [AppCubit.init].
  Future<void> init() async {
    await app.init();
    // Not awaited: asking CloudKit is a call to the system, and nothing
    // waits for the answer. The first round waits for it, and for the book.
    unawaited(cloudLog.start(settings.preferences));
  }

  /// Stops listening to the cloud and closes every cubit.
  Future<void> close() async {
    await _widgets.close();
    await cloudLog.close();
    await sync.disposeCloudSync();
    for (final cubit in [app, settings, market, watchlist, holdings, alerts, zakat, sync]) {
      await cubit.close();
    }
  }
}
