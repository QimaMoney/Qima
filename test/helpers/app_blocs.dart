import 'package:qima/blocs/app_blocs.dart';
import 'package:qima/blocs/cloud_log_sync_state.dart';
import 'package:qima/blocs/market_state.dart';
import 'package:qima/blocs/sync_state.dart';
import 'package:qima/models/fx_history.dart';
import 'package:qima/models/holding.dart';
import 'package:qima/models/holding_transaction.dart';
import 'package:qima/models/money.dart';
import 'package:qima/models/price_alert.dart';
import 'package:qima/models/quote.dart';
import 'package:qima/models/setup_answers.dart';
import 'package:qima/models/watch_card.dart';
import 'package:qima/models/zakat.dart';
import 'package:qima/models/chart_range.dart';
import 'package:qima/blocs/zakat_state.dart';
import 'package:qima/services/preferences.dart';

/// Puts values straight into the cubits, without start-up, for tests that
/// show or exercise one screen over a known state. Each argument goes to the
/// cubit that owns it; what is left out stays as it is.
extension AppBlocsSeed on AppBlocs {
  void seed({
    bool? initialized,
    bool? shouldShowOnboarding,
    SetupAnswers? setup,
    bool? getStartedDismissed,
    bool? tourRequested,
    // Settings.
    String? baseCurrency,
    WidgetRefreshInterval? widgetRefreshInterval,
    AppLanguage? appLanguage,
    Appearance? appearance,
    ChartRange? preferredChartRange,
    ChartRange? preferredPortfolioRange,
    bool? hideBalances,
    bool? appLockEnabled,
    LockGrace? lockGrace,
    bool? plainSummaries,
    String? speechLanguage,
    bool? onDeviceModel,
    // Market.
    Map<String, QuoteSeries>? seriesByID,
    FXRates? rates,
    FXHistory? fxHistory,
    RefreshPhase? phase,
    String? errorMessage,
    DateTime? lastRefresh,
    // Watchlist and holdings.
    List<WatchCard>? cards,
    List<HoldingLot>? lots,
    List<HoldingTransaction>? transactions,
    // Alerts.
    List<PriceAlert>? alerts,
    bool? deliverAlertsOnThisDevice,
    bool? notificationsEnabled,
    // Zakat.
    ZakatSettings? zakatSettings,
    // Sync.
    BookHealth? bookHealth,
    bool? iCloudSyncEnabled,
    bool? iCloudAccountAvailable,
    CloudSyncStatus? cloudSyncStatus,
    DateTime? lastCloudSyncAt,
    bool? backupReminderDue,
    CloudLogSyncState? cloudLogSync,
  }) {
    if ([initialized, shouldShowOnboarding, setup, getStartedDismissed, tourRequested].any((v) => v != null)) {
      app.emit(app.state.copyWith(
        initialized: initialized,
        shouldShowOnboarding: shouldShowOnboarding,
        setup: setup,
        getStartedDismissed: getStartedDismissed,
        tourRequested: tourRequested,
      ));
    }
    if ([baseCurrency, widgetRefreshInterval, appLanguage, appearance, preferredChartRange, preferredPortfolioRange, hideBalances, appLockEnabled, lockGrace, plainSummaries, speechLanguage, onDeviceModel].any((v) => v != null)) {
      settings.emit(settings.state.copyWith(
        baseCurrency: baseCurrency,
        widgetRefreshInterval: widgetRefreshInterval,
        appLanguage: appLanguage,
        appearance: appearance,
        preferredChartRange: preferredChartRange,
        preferredPortfolioRange: preferredPortfolioRange,
        hideBalances: hideBalances,
        appLockEnabled: appLockEnabled,
        lockGrace: lockGrace,
        plainSummaries: plainSummaries,
        speechLanguage: speechLanguage,
        onDeviceModel: onDeviceModel,
      ));
    }
    if ([seriesByID, rates, fxHistory, phase, errorMessage, lastRefresh].any((v) => v != null)) {
      market.emit(market.state.copyWith(
        seriesByID: seriesByID,
        rates: rates,
        fxHistory: fxHistory,
        phase: phase,
        errorMessage: errorMessage,
        lastRefresh: lastRefresh,
      ));
    }
    if (cards != null) watchlist.emit(watchlist.state.copyWith(cards: cards));
    if (lots != null || transactions != null) holdings.emit(holdings.state.copyWith(lots: lots, transactions: transactions));
    if ([alerts, deliverAlertsOnThisDevice, notificationsEnabled].any((v) => v != null)) {
      this.alerts.emit(this.alerts.state.copyWith(
        alerts: alerts,
        deliverAlertsOnThisDevice: deliverAlertsOnThisDevice,
        notificationsEnabled: notificationsEnabled,
      ));
    }
    if (zakatSettings != null) zakat.emit(ZakatState(settings: zakatSettings));
    if ([bookHealth, iCloudSyncEnabled, iCloudAccountAvailable, cloudSyncStatus, lastCloudSyncAt, backupReminderDue].any((v) => v != null)) {
      sync.emit(sync.state.copyWith(
        bookHealth: bookHealth,
        iCloudSyncEnabled: iCloudSyncEnabled,
        iCloudAccountAvailable: iCloudAccountAvailable,
        cloudSyncStatus: cloudSyncStatus,
        lastCloudSyncAt: lastCloudSyncAt,
        backupReminderDue: backupReminderDue,
      ));
    }
    if (cloudLogSync != null) cloudLog.emit(cloudLogSync);
  }
}
