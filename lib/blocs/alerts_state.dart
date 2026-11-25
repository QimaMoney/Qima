import 'package:equatable/equatable.dart';

import '../models/price_alert.dart';

class AlertsState extends Equatable {
  /// Price alert definitions (spec Phase 5) — synced like the watchlist.
  final List<PriceAlert> alerts;

  /// Local-only (never synced), like hide balances and app lock: whether
  /// this device delivers alert notifications at all.
  final bool deliverAlertsOnThisDevice;

  /// Best-effort OS notification-permission status, refreshed whenever the
  /// Alerts/Settings screens check it — drives the "Notifications are off"
  /// banner. Defaults to true (no banner) until the first check resolves, so
  /// the banner doesn't flash on before settling.
  final bool notificationsEnabled;

  const AlertsState({
    this.alerts = const [],
    this.deliverAlertsOnThisDevice = true,
    this.notificationsEnabled = true,
  });

  AlertsState copyWith({
    List<PriceAlert>? alerts,
    bool? deliverAlertsOnThisDevice,
    bool? notificationsEnabled,
  }) {
    return AlertsState(
      alerts: alerts ?? this.alerts,
      deliverAlertsOnThisDevice: deliverAlertsOnThisDevice ?? this.deliverAlertsOnThisDevice,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
    );
  }

  @override
  List<Object?> get props => [alerts, deliverAlertsOnThisDevice, notificationsEnabled];
}
