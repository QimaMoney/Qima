import 'package:equatable/equatable.dart';

import '../models/fx_history.dart';
import '../models/money.dart';
import '../models/quote.dart';

enum RefreshPhase { idle, refreshing, failed }

/// Prices and exchange rates: what was fetched, when, and whether a fetch is
/// running. The only state that changes on every price tick.
class MarketState extends Equatable {
  final Map<String, QuoteSeries> seriesByID;
  final FXRates rates;
  final FXHistory fxHistory;
  final RefreshPhase phase;

  /// Localization key (resolved with `displayLabel`), never raw exception text.
  final String? errorMessage;
  final DateTime? lastRefresh;
  final bool isBackfilling;
  final bool isLoadingHistory;

  MarketState({
    Map<String, QuoteSeries>? seriesByID,
    FXRates? rates,
    this.fxHistory = FXHistory.empty,
    this.phase = RefreshPhase.idle,
    this.errorMessage,
    this.lastRefresh,
    this.isBackfilling = false,
    this.isLoadingHistory = false,
  })  : seriesByID = seriesByID ?? const {},
        rates = rates ?? FXRates.usdIdentity;

  MarketState copyWith({
    Map<String, QuoteSeries>? seriesByID,
    FXRates? rates,
    FXHistory? fxHistory,
    RefreshPhase? phase,
    String? errorMessage,
    bool clearError = false,
    DateTime? lastRefresh,
    bool? isBackfilling,
    bool? isLoadingHistory,
  }) {
    return MarketState(
      seriesByID: seriesByID ?? this.seriesByID,
      rates: rates ?? this.rates,
      fxHistory: fxHistory ?? this.fxHistory,
      phase: phase ?? this.phase,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      lastRefresh: lastRefresh ?? this.lastRefresh,
      isBackfilling: isBackfilling ?? this.isBackfilling,
      isLoadingHistory: isLoadingHistory ?? this.isLoadingHistory,
    );
  }

  @override
  List<Object?> get props => [seriesByID, rates, fxHistory, phase, errorMessage, lastRefresh, isBackfilling, isLoadingHistory];
}
