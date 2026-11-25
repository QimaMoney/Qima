import 'dart:async';
import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart' show NumberFormat;

import '../models/holding_transaction.dart';
import '../models/instrument_catalog.dart';
import '../models/price_alert.dart';
import '../models/setup_answers.dart';
import '../models/watch_card.dart';
import '../services/background_refresh.dart';
import '../services/backup/backup_service.dart';
import '../services/preferences.dart';
import '../services/refresh_pipeline.dart';
import 'alerts_cubit.dart';
import 'app_state.dart';
import 'guarded_emit.dart';
import 'holdings_cubit.dart';
import 'market_cubit.dart';
import 'settings_cubit.dart';
import 'sync_cubit.dart';
import 'watchlist_cubit.dart';
import 'zakat_cubit.dart';

/// Start-up and first run. [init] loads every other cubit in the order the
/// data needs (the cloud backend settles before any store is read, the
/// trades load before the book's health is judged) and only then marks the
/// app [AppState.initialized]; the state also holds what setup decided.
class AppCubit extends Cubit<AppState> with GuardedEmit<AppState> {
  final SettingsCubit _settings;
  final MarketCubit _market;
  final WatchlistCubit _watchlist;
  final HoldingsCubit _holdings;
  final AlertsCubit _alerts;
  final ZakatCubit _zakat;
  final SyncCubit _sync;

  /// Builds the pipeline that evaluates alerts after a refresh, once the
  /// preferences and the backup service exist.
  final RefreshPipeline Function(Preferences preferences, BackupService backupService) _pipeline;

  /// The device locale consulted for onboarding step 5's base-currency
  /// prefill (see [_deviceRegionCurrency]). Defaults to the real OS locale;
  /// overridable so tests can pin a deterministic region instead of
  /// depending on the test runner's own locale.
  final Locale? _deviceLocale;

  AppCubit({
    required SettingsCubit settings,
    required MarketCubit market,
    required WatchlistCubit watchlist,
    required HoldingsCubit holdings,
    required AlertsCubit alerts,
    required ZakatCubit zakat,
    required SyncCubit sync,
    required RefreshPipeline Function(Preferences preferences, BackupService backupService) pipeline,
    Locale? deviceLocale,
  })  : _settings = settings,
        _market = market,
        _watchlist = watchlist,
        _holdings = holdings,
        _alerts = alerts,
        _zakat = zakat,
        _sync = sync,
        _pipeline = pipeline,
        _deviceLocale = deviceLocale,
        super(const AppState());

  // ---------------------------------------------------------------------
  // Init
  // ---------------------------------------------------------------------

  Future<void> init() async {
    final preferences = await Preferences.create(cloud: _sync.cloudStore);

    // Resolves (and, if applicable, enables) the cloud backend, and builds
    // the backup service, BEFORE any store's `load()`/seeding runs below;
    // see `SyncCubit.start` for why the order matters.
    await _sync.start(preferences);

    await _watchlist.loadCustomInstruments();

    await _settings.load(preferences);
    await _zakat.load(preferences);

    final seedCards = await preferences.seedWatchcards();
    await _watchlist.load(seedCards);
    await _alerts.load(preferences: preferences, pipeline: _pipeline(preferences, _sync.backupService));

    await _holdings.load();
    await _holdings.loadSplits(preferences);
    await _sync.load();
    await _market.loadCached();

    await _alerts.initNotifications();

    // Never show the tour again once it's been completed/skipped on this
    // device, and never show it AUTOMATICALLY to an existing (pre-onboarding)
    // install that already has real user data — an upgrade from 1.x with a
    // customized watchlist, holdings, or alerts shouldn't be interrupted by
    // a first-run tour it never asked for (spec "Onboarding tour"). A
    // from-scratch install only ever has the seeded default watchlist (spec
    // Phase 1 seeding, `InstrumentCatalog.defaultWatchlist`) and no
    // lots/alerts yet, so that combination is what "no data" means here.
    final shouldShowOnboarding = !preferences.onboardingCompleted &&
        !_hasExistingUserData(_watchlist.state.cards, _holdings.state.transactions, _alerts.state.alerts);

    // Onboarding step 5's "Base currency" row prefills from the device
    // region (spec "prefilled from the device region if it maps to a
    // supported currency, otherwise the current base currency") — only for
    // a fresh install about to see the tour, and only when nothing has ever
    // explicitly set a base currency yet (never overrides a real choice,
    // including one that arrived via sync before this device's first run).
    if (shouldShowOnboarding && !preferences.baseCurrencyExplicitlySet) {
      final regionCurrency = _deviceRegionCurrency(_market.state.rates.availableCurrencies);
      if (regionCurrency != null && regionCurrency != _settings.state.baseCurrency) {
        await _settings.setBaseCurrency(regionCurrency);
      }
    }

    // Best-effort: registers the periodic background task on platforms that
    // support it (Android always; iOS opportunistically via BGTaskScheduler
    // — see `background_refresh.dart`). Never blocks/fails init.
    unawaited(BackgroundRefresh.register(interval: _settings.state.widgetRefreshInterval.timeInterval));

    emit(state.copyWith(
      initialized: true,
      shouldShowOnboarding: shouldShowOnboarding,
      setup: preferences.setupAnswers,
      getStartedDismissed: preferences.getStartedDismissed,
    ));

    _sync.startSync();
  }

  /// The device region's default currency (via `intl`'s per-locale currency
  /// table), kept only if it's one the price feed actually quotes.
  /// `PlatformDispatcher.instance.locale` mirrors how the rest of the app
  /// resolves the device's own locale for background/system work (see
  /// `RefreshPipeline`/`BackupReminderNotifier`).
  /// [_deviceRegionCurrency] against the currencies loaded now, for setup's
  /// "From your region" label.
  String? get deviceRegionCurrency => _deviceRegionCurrency(_market.state.rates.availableCurrencies);

  String? _deviceRegionCurrency(List<String> available) {
    final locale = _deviceLocale ?? PlatformDispatcher.instance.locale;
    final code = NumberFormat.simpleCurrency(locale: locale.toString()).currencyName;
    if (code == null || !available.contains(code)) return null;
    return code;
  }

  /// "Already onboarded" for an existing (pre-onboarding-tour) install: any
  /// watchlist card beyond the seeded defaults, any holding lot, or any
  /// price alert. A brand-new install only ever has
  /// [InstrumentCatalog.defaultWatchlist]'s seeded cards and nothing else at
  /// this point in [init], so it reads as "no data" and the tour shows.
  bool _hasExistingUserData(List<WatchCard> cards, List<HoldingTransaction> transactions, List<PriceAlert> alerts) {
    if (transactions.isNotEmpty || alerts.isNotEmpty) return true;
    final defaultIDs = InstrumentCatalog.defaultWatchlist.toSet();
    if (cards.length != defaultIDs.length) return true;
    return cards.any((card) => !defaultIDs.contains(card.instrumentID));
  }

  // ---------------------------------------------------------------------
  // First run
  // ---------------------------------------------------------------------

  /// Marks first-launch setup as finished (either completed or skipped) so
  /// it never shows automatically again on this device. "Run setup again"
  /// in Settings pushes `SetupFlowScreen` directly instead of going through
  /// this flag.
  Future<void> completeOnboarding() async {
    await _settings.preferences.setOnboardingCompleted(true);
    if (!state.shouldShowOnboarding) return;
    emit(state.copyWith(shouldShowOnboarding: false));
  }

  /// Keeps the setup answers on this device and brings Home's Get started
  /// card back for them (running setup again is asking for it again).
  Future<void> saveSetup(SetupAnswers answers) async {
    await _settings.preferences.setSetupAnswers(answers);
    await _settings.preferences.setGetStartedDismissed(false);
    emit(state.copyWith(setup: answers, getStartedDismissed: false));
  }

  /// Asks the home shell to run the guided tour; it starts once the shell is
  /// on screen and clears the request with [tourStarted].
  void requestTour() {
    if (!state.tourRequested) emit(state.copyWith(tourRequested: true));
  }

  void tourStarted() {
    if (state.tourRequested) emit(state.copyWith(tourRequested: false));
  }

  Future<void> dismissGetStarted() async {
    if (state.getStartedDismissed) return;
    await _settings.preferences.setGetStartedDismissed(true);
    emit(state.copyWith(getStartedDismissed: true));
  }
}
