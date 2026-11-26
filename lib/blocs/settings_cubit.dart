import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../models/chart_range.dart';
import '../services/ai_assist_provider.dart';
import '../services/app_lock_service.dart';
import '../services/background_refresh.dart';
import '../services/dictation_service.dart';
import '../services/preferences.dart';
import '../services/text_recognition_service.dart';
import 'guarded_emit.dart';
import 'settings_state.dart';

/// The choices a backup restores; see [SettingsCubit.readRestored].
typedef RestoredSettings = ({
  String baseCurrency,
  AppLanguage appLanguage,
  Appearance appearance,
  ChartRange preferredChartRange,
  WidgetRefreshInterval widgetRefreshInterval,
});

/// The person's choices on this device, kept in `Preferences`, and the
/// device services some of them switch: app lock, the on-device model,
/// dictation and text recognition.
class SettingsCubit extends Cubit<SettingsState> with GuardedEmit<SettingsState> {
  final AppLockService appLockService;

  /// The OS's on-device language model (v4). Features reach it through
  /// [assist], which is the null provider unless Settings · On-device
  /// intelligence is on; every feature has a deterministic path that never
  /// consults it.
  final AiAssistProvider aiAssist;

  /// On-device speech to text for the Add field (v4 phase 4).
  final DictationService dictation;

  /// On-device text recognition for receipt scans (v4 phase 7).
  final TextRecognitionService textRecognition;

  /// Assigned by [load], at start-up.
  late Preferences preferences;

  SettingsCubit({
    required this.appLockService,
    required this.aiAssist,
    required this.dictation,
    required this.textRecognition,
  }) : super(const SettingsState());

  /// Start-up: every choice, read from [preferences].
  Future<void> load(Preferences preferences) async {
    this.preferences = preferences;
    final baseCurrency = await preferences.baseCurrency;
    final widgetRefreshInterval = await preferences.widgetRefreshInterval;
    final appLanguage = await preferences.appLanguage;
    final appearance = await preferences.appearance;
    emit(SettingsState(
      baseCurrency: baseCurrency,
      widgetRefreshInterval: widgetRefreshInterval,
      appLanguage: appLanguage,
      appearance: appearance,
      preferredChartRange: preferences.preferredChartRange,
      preferredPortfolioRange: preferences.preferredChartRange.onHome,
      candleCharts: preferences.candleCharts,
      hideBalances: preferences.hideBalances,
      appLockEnabled: preferences.appLockEnabled,
      lockGrace: preferences.lockGrace,
      plainSummaries: preferences.plainSummaries,
      speechLanguage: preferences.speechLanguage,
      onDeviceModel: preferences.onDeviceModel,
    ));
  }

  /// The choices a backup restores, read again and not yet shown; [adopt]
  /// shows them.
  Future<RestoredSettings> readRestored() async {
    final baseCurrency = await preferences.baseCurrency;
    final appLanguage = await preferences.appLanguage;
    final appearance = await preferences.appearance;
    final preferredChartRange = preferences.preferredChartRange;
    final widgetRefreshInterval = await preferences.widgetRefreshInterval;
    return (
      baseCurrency: baseCurrency,
      appLanguage: appLanguage,
      appearance: appearance,
      preferredChartRange: preferredChartRange,
      widgetRefreshInterval: widgetRefreshInterval,
    );
  }

  /// Shows what [readRestored] read, so the app reflects a restore without
  /// a restart. Only those choices change, on the settings as they are now:
  /// anything else changed since the read stays as it is.
  void adopt(RestoredSettings restored) => emit(state.copyWith(
        baseCurrency: restored.baseCurrency,
        appLanguage: restored.appLanguage,
        appearance: restored.appearance,
        preferredChartRange: restored.preferredChartRange,
        preferredPortfolioRange: restored.preferredChartRange.onHome,
        widgetRefreshInterval: restored.widgetRefreshInterval,
      ));

  Future<void> setBaseCurrency(String value) async {
    if (value == state.baseCurrency) return;
    await preferences.setBaseCurrency(value);
    emit(state.copyWith(baseCurrency: value));
  }

  Future<void> setAppLanguage(AppLanguage value) async {
    if (value == state.appLanguage) return;
    await preferences.setAppLanguage(value);
    emit(state.copyWith(appLanguage: value));
  }

  Future<void> setAppearance(Appearance value) async {
    if (value == state.appearance) return;
    await preferences.setAppearance(value);
    emit(state.copyWith(appearance: value));
  }

  Future<void> setPreferredChartRange(ChartRange value) async {
    if (value.isExtended || value == state.preferredChartRange) return;
    await preferences.setPreferredChartRange(value);
    // The charts on Home follow the default the moment it changes.
    emit(state.copyWith(preferredChartRange: value, preferredPortfolioRange: value.onHome));
  }

  Future<void> setCandleCharts(bool value) async {
    if (value == state.candleCharts) return;
    await preferences.setCandleCharts(value);
    emit(state.copyWith(candleCharts: value));
  }

  /// The range picked on a chart on Home or on the portfolio chart. It
  /// holds until the app is closed: those charts open on the default range
  /// in Settings, so that one setting says how every chart opens.
  Future<void> setPreferredPortfolioRange(ChartRange value) async {
    if (!ChartRange.portfolioSelectable.contains(value) || value == state.preferredPortfolioRange) return;
    emit(state.copyWith(preferredPortfolioRange: value));
  }

  Future<void> setWidgetRefreshInterval(WidgetRefreshInterval value) async {
    if (value == state.widgetRefreshInterval) return;
    await preferences.setWidgetRefreshInterval(value);
    emit(state.copyWith(widgetRefreshInterval: value));
    // Re-registering replaces the periodic task with the new cadence
    // (Android: `ExistingPeriodicWorkPolicy.update`; iOS: the next
    // BGTaskScheduler submission simply uses the new earliest-begin delay —
    // see `background_refresh.dart`), so this finally gives the setting a
    // real effect (spec Phase 5).
    unawaited(BackgroundRefresh.register(interval: value.timeInterval));
  }

  // ---------------------------------------------------------------------
  // Privacy: hide balances + app lock
  // ---------------------------------------------------------------------

  Future<void> toggleHideBalances() async {
    final value = !state.hideBalances;
    await preferences.setHideBalances(value);
    emit(state.copyWith(hideBalances: value));
  }

  Future<void> setHideBalances(bool value) async {
    if (value == state.hideBalances) return;
    await preferences.setHideBalances(value);
    emit(state.copyWith(hideBalances: value));
  }

  /// Enabling app lock requires a successful authentication first — the
  /// user proves they can actually unlock before the app starts depending on
  /// it. Returns whether the setting ended up enabled: `true` on success,
  /// `false` if authentication failed/was cancelled (the switch should
  /// bounce back to off). Disabling never needs authentication.
  Future<bool> setAppLockEnabled(bool value, {String reason = 'Confirm it\'s you to enable App lock'}) async {
    if (!value) {
      await preferences.setAppLockEnabled(false);
      emit(state.copyWith(appLockEnabled: false));
      return true;
    }
    final authenticated = await appLockService.authenticate(reason: reason);
    if (!authenticated) return false;
    await preferences.setAppLockEnabled(true);
    emit(state.copyWith(appLockEnabled: true));
    return true;
  }

  Future<void> setLockGrace(LockGrace value) async {
    if (value == state.lockGrace) return;
    await preferences.setLockGrace(value);
    emit(state.copyWith(lockGrace: value));
  }

  // ---------------------------------------------------------------------
  // Summaries, speech and the on-device model
  // ---------------------------------------------------------------------

  Future<void> setPlainSummaries(bool value) async {
    if (value == state.plainSummaries) return;
    await preferences.setPlainSummaries(value);
    emit(state.copyWith(plainSummaries: value));
  }

  Future<void> setSpeechLanguage(String languageCode) async {
    if (languageCode == state.speechLanguage) return;
    await preferences.setSpeechLanguage(languageCode);
    emit(state.copyWith(speechLanguage: languageCode));
  }

  Future<void> setOnDeviceModel(bool value) async {
    if (value == state.onDeviceModel) return;
    await preferences.setOnDeviceModel(value);
    emit(state.copyWith(onDeviceModel: value));
    if (!value) {
      if (aiAssist case final StoppableModel model) model.stop();
    }
  }

  /// The model features may consult: [aiAssist] when the user turned it on,
  /// else nothing.
  AiAssistProvider get assist => state.onDeviceModel ? aiAssist : const NullAiAssistProvider();

  final Map<String, String> _phrased = {};

  /// [sentence] reworded by the on-device model, or [sentence] itself when
  /// the model is off, unavailable, or its wording fails [acceptPhrasing].
  /// Remembered per sentence, so a rebuild never asks twice.
  Future<String> phrased(String sentence, String localeTag) async {
    if (!state.onDeviceModel) return sentence;
    final key = '$localeTag|$sentence';
    final cached = _phrased[key];
    if (cached != null) return cached;
    final candidate = await aiAssist.phrase(sentence, localeTag);
    final result =
        candidate != null && acceptPhrasing(sentence, candidate) ? restoreIsolates(sentence, candidate.trim()) : sentence;
    return _phrased[key] = result;
  }
}
