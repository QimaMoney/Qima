import 'package:equatable/equatable.dart';

import '../models/chart_range.dart';
import '../services/preferences.dart';

/// What the person chose on this device: currency, language, look, privacy
/// and the on-device model. Everything here is read from `Preferences`.
class SettingsState extends Equatable {
  final String baseCurrency;
  final WidgetRefreshInterval widgetRefreshInterval;
  final AppLanguage appLanguage;
  final Appearance appearance;
  final ChartRange preferredChartRange;
  final ChartRange preferredPortfolioRange;

  /// Local-only privacy settings (spec Phase 4 "Hide balances + App lock") —
  /// never synced, see `Preferences`.
  final bool hideBalances;
  final bool appLockEnabled;
  final LockGrace lockGrace;

  /// v4: whether Portfolio shows the past month as a sentence.
  final bool plainSummaries;

  /// v5: the language speech is heard in on New transaction, as a language
  /// code ("ar"). Null until the person picks one: the app's language.
  final String? speechLanguage;

  /// v4: whether the on-device model may help (Settings · On-device
  /// intelligence).
  final bool onDeviceModel;

  const SettingsState({
    this.baseCurrency = 'USD',
    this.widgetRefreshInterval = WidgetRefreshInterval.defaultValue,
    this.appLanguage = AppLanguage.system,
    this.appearance = Appearance.system,
    this.preferredChartRange = ChartRange.fallbackDefault,
    this.preferredPortfolioRange = ChartRange.portfolioDefault,
    this.hideBalances = false,
    this.appLockEnabled = false,
    this.lockGrace = LockGrace.defaultValue,
    this.plainSummaries = false,
    this.speechLanguage,
    this.onDeviceModel = false,
  });

  SettingsState copyWith({
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
  }) {
    return SettingsState(
      baseCurrency: baseCurrency ?? this.baseCurrency,
      widgetRefreshInterval: widgetRefreshInterval ?? this.widgetRefreshInterval,
      appLanguage: appLanguage ?? this.appLanguage,
      appearance: appearance ?? this.appearance,
      preferredChartRange: preferredChartRange ?? this.preferredChartRange,
      preferredPortfolioRange: preferredPortfolioRange ?? this.preferredPortfolioRange,
      hideBalances: hideBalances ?? this.hideBalances,
      appLockEnabled: appLockEnabled ?? this.appLockEnabled,
      lockGrace: lockGrace ?? this.lockGrace,
      plainSummaries: plainSummaries ?? this.plainSummaries,
      speechLanguage: speechLanguage ?? this.speechLanguage,
      onDeviceModel: onDeviceModel ?? this.onDeviceModel,
    );
  }

  @override
  List<Object?> get props => [
        baseCurrency,
        widgetRefreshInterval,
        appLanguage,
        appearance,
        preferredChartRange,
        preferredPortfolioRange,
        hideBalances,
        appLockEnabled,
        lockGrace,
        plainSummaries,
        speechLanguage,
        onDeviceModel,
      ];
}
