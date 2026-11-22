import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../models/asset.dart';
import '../models/instrument_catalog.dart';
import '../models/instrument_presentation.dart';
import '../models/money.dart';
import '../models/quote.dart';
import '../models/watch_card.dart';
import '../models/zakat.dart';
import '../services/price_converter.dart';
import '../services/price_repository.dart';
import '../services/quote_provider.dart';
import 'guarded_emit.dart';
import 'market_state.dart';

/// Prices, exchange rates and their history. What to fetch (the watchlist
/// plus everything held) is read through callbacks at the moment a fetch
/// starts, as `MoneyCubit` reads the base currency, so this cubit knows
/// nothing of the watchlist or the holdings; what to do once prices have
/// arrived (alert evaluation, the zakat reminder) is handed in the same way.
class MarketCubit extends Cubit<MarketState> with GuardedEmit<MarketState> {
  static const _refreshFailedKey = 'error.refreshFailed';

  final PriceRepository repository;

  /// Every instrument that needs prices: the watchlist's and the held ones.
  final List<Instrument> Function() _tracked;

  /// The currencies the watchlist's cards are priced in.
  final Iterable<String> Function() _cardCurrencies;
  final String Function() _baseCurrency;

  /// Runs alert evaluation against a just-refreshed snapshot.
  final Future<void> Function(Map<String, QuoteSeries> seriesByID, FXRates rates) _evaluateAlerts;

  /// The foreground half of the hawl reminder, run after a full refresh.
  final Future<void> Function() _notifyZakatIfDue;

  MarketCubit({
    required this.repository,
    required List<Instrument> Function() tracked,
    required Iterable<String> Function() cardCurrencies,
    required String Function() baseCurrency,
    required Future<void> Function(Map<String, QuoteSeries> seriesByID, FXRates rates) evaluateAlerts,
    required Future<void> Function() notifyZakatIfDue,
  })  : _tracked = tracked,
        _cardCurrencies = cardCurrencies,
        _baseCurrency = baseCurrency,
        _evaluateAlerts = evaluateAlerts,
        _notifyZakatIfDue = notifyZakatIfDue,
        super(MarketState());

  /// Start-up: the last rates, FX history and prices kept on disk, for every
  /// tracked instrument. Never fetches.
  Future<void> loadCached() async {
    final rates = await repository.cachedRates();
    final fxHistory = await repository.cachedFXHistory();
    final seriesByID = <String, QuoteSeries>{};
    for (final instrument in _tracked()) {
      seriesByID[instrument.id] = await repository.cachedSeries(instrument);
    }
    emit(state.copyWith(rates: rates, fxHistory: fxHistory, seriesByID: seriesByID));
  }

  /// The ones of [instruments] that have no price in the state yet.
  List<Instrument> withoutPrice(Iterable<Instrument> instruments) =>
      [for (final i in instruments) if (!state.seriesByID.containsKey(i.id)) i];

  /// The cached price of each of [instruments] that has none in the state
  /// yet, not yet shown; [adoptSeries] shows them. Read before the cards or
  /// trades that need them are, so none is ever shown without its price.
  Future<Map<String, QuoteSeries>> readMissingSeries(Iterable<Instrument> instruments) async {
    final missing = <String, QuoteSeries>{};
    for (final instrument in instruments) {
      if (state.seriesByID.containsKey(instrument.id)) continue;
      missing[instrument.id] = await repository.cachedSeries(instrument);
    }
    return missing;
  }

  /// Adds the prices [readMissingSeries] read, keeping any that arrived
  /// since.
  void adoptSeries(Map<String, QuoteSeries> series) {
    if (series.isEmpty) return;
    emit(state.copyWith(seriesByID: {...series, ...state.seriesByID}));
  }

  /// Puts the cached price of [instrument] in the state, so a card or trade
  /// that was just added shows what is known before the fetch lands.
  Future<void> primeFromCache(Instrument instrument) async {
    final cached = await repository.cachedSeries(instrument);
    emit(state.copyWith(seriesByID: {...state.seriesByID, instrument.id: cached}));
  }

  /// A live price for [instrument], throwing when none can be had; used to
  /// check a custom ticker before it is kept.
  Future<Listing> probeListing(Instrument instrument) => repository.probeListing(instrument);

  /// [series] stands in for a price that is not in the state: setup's
  /// suggestions are not on the watchlist yet, so nothing has fetched them.
  InstrumentPresentation presentation(WatchCard card, {QuoteSeries? series}) {
    final instrument = card.instrument ?? InstrumentCatalog.all.first;
    final converter = PriceConverter(
      rates: state.rates,
      currencyCode: card.currency,
      unit: card.unit,
      karat: card.karat,
      history: state.fxHistory,
    );
    return InstrumentPresentation(
      instrument: instrument,
      series: state.seriesByID[instrument.id] ?? series ?? QuoteSeries.empty(instrument.id),
      converter: converter,
    );
  }

  double? latestUSD(String instrumentID) => state.seriesByID[instrumentID]?.latest?.canonicalUSD;

  Future<void> refreshIfStale({Duration minInterval = const Duration(seconds: 120)}) async {
    final last = state.lastRefresh;
    if (last == null || DateTime.now().difference(last) > minInterval) {
      await refreshAll();
    }
  }

  Future<void> refreshAll({bool silent = false}) async {
    final instruments = _tracked();
    if (!silent) emit(state.copyWith(phase: RefreshPhase.refreshing, clearError: true));
    try {
      final updated = await repository.refreshAll(instruments);
      final rates = await repository.cachedRates();
      if (isClosed) return;
      final merged = {...state.seriesByID, ...updated};
      if (updated.isEmpty && instruments.isNotEmpty) {
        emit(state.copyWith(
          phase: RefreshPhase.failed,
          errorMessage: _refreshFailedKey,
          rates: rates,
          seriesByID: merged,
        ));
      } else {
        emit(state.copyWith(
          phase: RefreshPhase.idle,
          clearError: true,
          rates: rates,
          seriesByID: merged,
          lastRefresh: DateTime.now(),
        ));
        if (updated.isNotEmpty) {
          await _evaluateAlerts(merged, rates);
        }
      }
    } catch (e, st) {
      debugPrint('MarketCubit: refreshAll failed: $e\n$st');
      if (isClosed) return;
      emit(state.copyWith(phase: RefreshPhase.failed, errorMessage: _refreshFailedKey));
    }
    // Fire-and-forget: history is larger and shouldn't block live prices.
    unawaited(backfillHistoryIfNeeded());
    unawaited(_notifyZakatIfDue());
  }

  Future<void> backfillHistoryIfNeeded() async {
    if (state.isBackfilling) return;
    emit(state.copyWith(isBackfilling: true));
    try {
      final currencies = <String>{
        ..._cardCurrencies(),
        ...InstrumentCatalog.fiat.map((i) => i.symbol),
        _baseCurrency(),
      };
      final fxHistory = await repository.backfillFXHistory(currencies.toList());
      final updated = await repository.backfillInstruments(_tracked(), fxHistory);
      if (isClosed) return;
      if (updated.isNotEmpty || fxHistory != state.fxHistory) {
        emit(state.copyWith(
          fxHistory: fxHistory,
          seriesByID: {...state.seriesByID, ...updated},
        ));
      }
    } finally {
      emit(state.copyWith(isBackfilling: false));
    }
  }

  Future<void> loadHistory(Instrument instrument, String currency) async {
    if (state.isLoadingHistory) return;
    emit(state.copyWith(isLoadingHistory: true));
    try {
      final currencies = <String>{currency, _baseCurrency()};
      if (instrument.assetClass == AssetClass.fiat) currencies.add(instrument.symbol);
      final fxHistory = await repository.backfillFXHistory(currencies.toList(), force: true);
      final result = await repository.backfillInstruments([instrument], fxHistory, force: true);
      if (isClosed) return;
      emit(state.copyWith(
        fxHistory: fxHistory,
        seriesByID: {...state.seriesByID, ...result},
      ));
    } finally {
      emit(state.copyWith(isLoadingHistory: false));
    }
  }

  Future<void> refresh(Instrument instrument) async {
    emit(state.copyWith(phase: RefreshPhase.refreshing, clearError: true));
    try {
      final series = await repository.refresh(instrument);
      final rates = await repository.cachedRates();
      if (isClosed) return;
      final merged = {...state.seriesByID, instrument.id: series};
      emit(state.copyWith(
        phase: RefreshPhase.idle,
        clearError: true,
        rates: rates,
        seriesByID: merged,
        lastRefresh: DateTime.now(),
      ));
      await _evaluateAlerts(merged, rates);
    } catch (e, st) {
      debugPrint('MarketCubit: refresh(${instrument.id}) failed: $e\n$st');
      if (isClosed) return;
      emit(state.copyWith(phase: RefreshPhase.failed, errorMessage: _refreshFailedKey));
    }
  }

  /// The nisab is priced off gold and silver even for someone who holds
  /// and watches neither, so the zakat screen fetches whichever of the two
  /// isn't already part of the regular refresh. Quiet: never touches
  /// [MarketState.phase] or the refresh error banner.
  Future<void> ensureNisabPrices() async {
    final tracked = _tracked().map((i) => i.id).toSet();
    for (final basis in NisabBasis.values) {
      if (tracked.contains(basis.instrumentID) && latestUSD(basis.instrumentID) != null) continue;
      final instrument = InstrumentCatalog.instrument(basis.instrumentID);
      if (instrument == null) continue;
      QuoteSeries series;
      try {
        series = await repository.refresh(instrument);
      } catch (e) {
        // Offline: the last cached price still beats an unknown threshold.
        debugPrint('MarketCubit: nisab price for ${instrument.id} failed: $e');
        series = await repository.cachedSeries(instrument);
      }
      if (isClosed) return;
      emit(state.copyWith(seriesByID: {...state.seriesByID, instrument.id: series}));
    }
  }
}
