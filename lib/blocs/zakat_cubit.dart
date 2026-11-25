import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../models/instrument_catalog.dart';
import '../models/zakat.dart';
import '../services/notification_service.dart';
import '../services/preferences.dart';
import '../services/zakat_reminder_notifier.dart';
import 'alerts_cubit.dart';
import 'guarded_emit.dart';
import 'holdings_cubit.dart';
import 'market_cubit.dart';
import 'zakat_state.dart';

/// The zakat choices and the calculation they feed. The calculation reads
/// what is held ([HoldingsCubit]) and its prices ([MarketCubit]).
class ZakatCubit extends Cubit<ZakatState> with GuardedEmit<ZakatState> {
  final HoldingsCubit _holdings;
  final MarketCubit _market;
  final AlertsCubit _alerts;
  final NotificationService _notificationService;
  final String Function() _baseCurrency;

  /// Marks that user data changed since the last backup.
  final Future<void> Function() _markDataChanged;

  /// Assigned at start-up.
  Preferences? _preferences;

  ZakatCubit({
    required HoldingsCubit holdings,
    required MarketCubit market,
    required AlertsCubit alerts,
    required NotificationService notificationService,
    required String Function() baseCurrency,
    required Future<void> Function() markDataChanged,
  })  : _holdings = holdings,
        _market = market,
        _alerts = alerts,
        _notificationService = notificationService,
        _baseCurrency = baseCurrency,
        _markDataChanged = markDataChanged,
        super(const ZakatState());

  /// Start-up: the stored choices.
  Future<void> load(Preferences preferences) async {
    _preferences = preferences;
    emit(ZakatState(settings: await preferences.zakatSettings));
  }

  /// The stored choices, not yet shown; [adopt] shows them.
  Future<ZakatSettings> read() => _preferences!.zakatSettings;

  /// Shows [settings] as read by [read] after another device (or a restore)
  /// changed them.
  void adopt(ZakatSettings settings) {
    if (settings != state.settings) emit(ZakatState(settings: settings));
  }

  /// Today's zakat calculation over every held lot. Pure and cheap (one
  /// valuation per held asset), so screens call it on every rebuild.
  ZakatAssessment get assessment => ZakatAssessment.compute(
        lots: _holdings.state.lots,
        settings: state.settings,
        rates: _market.state.rates,
        baseCurrency: _baseCurrency(),
        latestUSD: _market.latestUSD,
        resolve: InstrumentCatalog.instrument,
      );

  /// Applies [change] to the settings as they are now, so callers never
  /// write back a stale copy captured at build time.
  Future<void> updateSettings(ZakatSettings Function(ZakatSettings current) change) => setSettings(change(state.settings));

  Future<void> setSettings(ZakatSettings settings) async {
    if (settings == state.settings) return;
    final turnedOnReminder = settings.remind && !state.settings.remind;
    emit(ZakatState(settings: settings));
    await _preferences!.setZakatSettings(settings);
    unawaited(_markDataChanged());
    if (turnedOnReminder) {
      await _alerts.requestNotificationPermission();
      unawaited(notifyIfDue());
    }
  }

  /// The foreground half of the hawl reminder; the background task runs the
  /// same notifier from `RefreshPipeline.run`. Once per completion per
  /// device either way (see [ZakatReminderNotifier]).
  Future<void> notifyIfDue() async {
    // Start-up has not reached the preferences yet.
    final preferences = _preferences;
    if (preferences == null || !state.settings.remind) return;
    try {
      await ZakatReminderNotifier(preferences: preferences, notificationService: _notificationService).notifyIfDue();
    } catch (e, st) {
      debugPrint('ZakatCubit: zakat reminder failed: $e\n$st');
    }
  }
}
