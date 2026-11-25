import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../models/alert_runtime_state.dart';
import '../models/fx_history.dart';
import '../models/money.dart';
import '../models/price_alert.dart';
import '../models/quote.dart';
import '../models/watch_card.dart';
import '../services/alert_runtime_store.dart';
import '../services/alerts_store.dart';
import '../services/notification_service.dart';
import '../services/preferences.dart';
import '../services/refresh_pipeline.dart';
import 'alerts_state.dart';
import 'guarded_emit.dart';

/// Price alerts and the notifications they (and the reminders) depend on.
class AlertsCubit extends Cubit<AlertsState> with GuardedEmit<AlertsState> {
  final AlertsStore alertsStore;
  final AlertRuntimeStore alertRuntimeStore;
  final NotificationService notificationService;

  /// Marks that user data changed since the last backup.
  final Future<void> Function() _markDataChanged;

  /// Assigned at start-up, with the preferences it reads.
  Preferences? _preferences;
  RefreshPipeline? _pipeline;

  AlertsCubit({
    required this.alertsStore,
    required this.alertRuntimeStore,
    required this.notificationService,
    required Future<void> Function() markDataChanged,
  })  : _markDataChanged = markDataChanged,
        super(const AlertsState());

  /// Start-up: the stored alerts and this device's delivery choice, and the
  /// pipeline that evaluates them after a refresh.
  Future<void> load({required Preferences preferences, required RefreshPipeline pipeline}) async {
    _preferences = preferences;
    _pipeline = pipeline;
    emit(state.copyWith(
      alerts: await alertsStore.load(),
      deliverAlertsOnThisDevice: preferences.deliverAlertsOnThisDevice,
    ));
  }

  /// Start-up: brings the notification plugin up and reads whether the OS
  /// lets Qima notify.
  Future<void> initNotifications() async {
    await notificationService.init();
    emit(state.copyWith(notificationsEnabled: await notificationService.isEnabled()));
  }

  /// The stored alerts, not yet shown; [adopt] shows them.
  Future<List<PriceAlert>> read() => alertsStore.load();

  /// Shows [alerts] as read by [read] after another device (or a restore)
  /// changed them.
  void adopt(List<PriceAlert> alerts) {
    if (alerts != state.alerts) emit(state.copyWith(alerts: alerts));
  }

  /// Runs alert evaluation for the alerts currently in state against a
  /// just-refreshed price snapshot, via the same [RefreshPipeline] the
  /// background task uses (spec Phase 5) — then reloads alerts from disk in
  /// case a one-off alert just disabled itself, so the UI reflects it
  /// immediately without waiting for the next unrelated state change.
  Future<void> evaluateAfterRefresh({
    required List<WatchCard> cards,
    required Map<String, QuoteSeries> seriesByID,
    required FXRates rates,
    required FXHistory fxHistory,
  }) async {
    final pipeline = _pipeline;
    if (pipeline == null || state.alerts.isEmpty) return;
    try {
      await pipeline.evaluateAndNotify(
        alerts: state.alerts,
        cards: cards,
        seriesByID: seriesByID,
        rates: rates,
        fxHistory: fxHistory,
      );
      final reloaded = await alertsStore.load();
      if (reloaded != state.alerts) {
        emit(state.copyWith(alerts: reloaded));
      }
    } catch (e, st) {
      debugPrint('AlertsCubit: alert evaluation failed: $e\n$st');
    }
  }

  List<PriceAlert> alertsFor(String cardID) => state.alerts.where((a) => a.cardID == cardID).toList();

  Future<void> saveAlert(PriceAlert alert) async {
    final alerts = await alertsStore.upsert(alert);
    emit(state.copyWith(alerts: alerts));
    unawaited(_markDataChanged());
  }

  Future<void> deleteAlert(PriceAlert alert) async {
    final alerts = await alertsStore.delete(alert.id);
    emit(state.copyWith(alerts: alerts));
    unawaited(_markDataChanged());
  }

  Future<void> setAlertEnabled(PriceAlert alert, bool enabled) async {
    if (alert.enabled == enabled) return;
    await saveAlert(alert.copyWith(enabled: enabled));
  }

  /// The alert's per-device runtime state (last fired time, armed) — read
  /// straight from [alertRuntimeStore] since it's deliberately not part of
  /// [AlertsState]/[PriceAlert] (never synced, see `alert_runtime_state.dart`).
  Future<AlertRuntimeState> runtimeStateFor(String alertId) async {
    final all = await alertRuntimeStore.loadAll();
    return alertRuntimeStore.stateFor(all, alertId);
  }

  Future<void> setDeliverAlertsOnThisDevice(bool value) async {
    if (value == state.deliverAlertsOnThisDevice) return;
    await _preferences!.setDeliverAlertsOnThisDevice(value);
    emit(state.copyWith(deliverAlertsOnThisDevice: value));
  }

  /// Requests OS notification permission (Android 13+, iOS/macOS) and
  /// refreshes [AlertsState.notificationsEnabled] from the result, so the
  /// Alerts/Settings screens' "Notifications are off" banner updates
  /// immediately rather than waiting for the next unrelated rebuild.
  Future<bool> requestNotificationPermission() async {
    final granted = await notificationService.requestPermission();
    await refreshNotificationStatus();
    return granted;
  }

  Future<void> refreshNotificationStatus() async {
    final enabled = await notificationService.isEnabled();
    if (enabled != state.notificationsEnabled) {
      emit(state.copyWith(notificationsEnabled: enabled));
    }
  }
}
