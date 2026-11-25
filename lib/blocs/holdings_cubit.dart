import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../models/asset.dart';
import '../models/fx_history.dart';
import '../models/holding.dart';
import '../models/holding_entry_codec.dart';
import '../models/holding_totals.dart';
import '../models/holding_transaction.dart';
import '../models/instrument_facts.dart';
import '../models/instrument_catalog.dart';
import '../models/ledger.dart';
import '../models/metal_breakdown.dart';
import '../models/money.dart';
import '../models/period_summary.dart';
import '../models/portfolio_history.dart';
import '../models/quote.dart';
import '../models/chart_range.dart';
import '../services/book_store.dart';
import '../services/holdings_ledger.dart';
import '../services/preferences.dart';
import 'guarded_emit.dart';
import 'holdings_state.dart';
import 'market_cubit.dart';

/// What the person holds: the trades, kept in the book as one entry each, and
/// everything derived from them. Valuing a position reads the prices in
/// [MarketCubit], so a screen that shows a value listens to both.
class HoldingsCubit extends Cubit<HoldingsState> with GuardedEmit<HoldingsState> {
  /// The trades, kept in the book as one entry each. Every write here is one
  /// record, so the cash a trade moved is never out of step with it.
  final HoldingsLedger ledgerStore;
  final MarketCubit _market;
  final String Function() _baseCurrency;

  /// Every instrument that needs prices: the watchlist's and the held ones.
  final List<Instrument> Function() _tracked;

  /// Marks that user data changed since the last backup.
  final Future<void> Function() _markDataChanged;

  /// Told after every read of the trades whether it failed, for
  /// `BookHealth.loadFailed`.
  final void Function({required bool failed}) _loadResult;

  /// Set by `MoneyCubit`'s owner: reloads the money ledger after the book
  /// changed under it. Called with [BookStore.entriesKey] after a trade is
  /// saved or deleted here, since a trade is an entry in that ledger.
  Future<void> Function(String? key)? onBookChanged;

  /// Assigned by [loadSplits], at start-up.
  Preferences? _preferences;

  HoldingsCubit({
    required this.ledgerStore,
    required MarketCubit market,
    required String Function() baseCurrency,
    required List<Instrument> Function() tracked,
    required Future<void> Function() markDataChanged,
    required void Function({required bool failed}) loadResult,
  })  : _market = market,
        _baseCurrency = baseCurrency,
        _tracked = tracked,
        _markDataChanged = markDataChanged,
        _loadResult = loadResult,
        super(HoldingsState());

  // ---------------------------------------------------------------------
  // Loading
  // ---------------------------------------------------------------------

  /// The trades, not yet shown, or null when the book could not be read;
  /// [adopt] shows them. The failure is reported for `BookHealth.loadFailed`;
  /// start-up and every reload go on with what they have rather than stop.
  Future<List<HoldingTransaction>?> read() async {
    try {
      final trades = await ledgerStore.load();
      _loadResult(failed: false);
      return trades;
    } catch (error) {
      _loadResult(failed: true);
      debugPrint('Reading the trades failed: $error');
      return null;
    }
  }

  /// Start-up: the stored trades, or none when they cannot be read.
  Future<void> load() async {
    emit(state.copyWith(transactions: await read() ?? const <HoldingTransaction>[]));
  }

  /// Shows [transactions] as read by [read] after another device (or a
  /// restore) changed the book.
  void adopt(List<HoldingTransaction> transactions) {
    if (transactions != state.transactions) emit(state.copyWith(transactions: transactions));
  }

  /// Start-up: the splits the person has answered.
  Future<void> loadSplits(Preferences preferences) async {
    _preferences = preferences;
    adoptSplits(await readSplits());
  }

  /// The answered splits as stored, after another device changed them; what
  /// is shown when start-up has not reached the preferences yet.
  Future<Set<String>> readSplits() async => await _preferences?.handledSplits ?? state.handledSplits;

  void adoptSplits(Set<String> handled) {
    if (!setEquals(handled, state.handledSplits)) emit(state.copyWith(handledSplits: handled));
  }

  // ---------------------------------------------------------------------
  // Queries
  // ---------------------------------------------------------------------

  List<HoldingLot> lotsFor(Instrument instrument) {
    final list = state.lots.where((l) => l.instrumentID == instrument.id).toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    return list;
  }

  HoldingValuation? valuationFor(Instrument instrument, String currency) {
    return HoldingValuation.aggregate(
      lots: lotsFor(instrument),
      rates: _market.state.rates,
      displayCurrency: currency,
      latestUSD: _market.latestUSD,
    );
  }

  HoldingValuation? valuationForLot(HoldingLot lot, String currency) {
    return HoldingValuation.aggregate(
      lots: [lot],
      rates: _market.state.rates,
      displayCurrency: currency,
      latestUSD: _market.latestUSD,
    );
  }

  HoldingValuation? get portfolioValuation => HoldingValuation.aggregate(
        lots: state.lots,
        rates: _market.state.rates,
        displayCurrency: _baseCurrency(),
        latestUSD: _market.latestUSD,
      );

  List<HeldInstrument> get heldInstruments {
    final seen = <String>{};
    final result = <HeldInstrument>[];
    for (final lot in state.lots) {
      if (seen.contains(lot.instrumentID)) continue;
      seen.add(lot.instrumentID);
      final instrument = InstrumentCatalog.instrument(lot.instrumentID);
      if (instrument == null) continue;
      final valuation = valuationFor(instrument, _baseCurrency());
      if (valuation == null) continue;
      result.add(HeldInstrument(
        instrument: instrument,
        valuation: valuation,
        transactionCount: state.transactions.where((t) => t.instrumentID == instrument.id).length,
      ));
    }
    result.sort((a, b) => b.valuation.value.amount.compareTo(a.valuation.value.amount));
    return result;
  }

  /// Gain realised across the whole ledger, in the base currency — null
  /// when nothing has been sold or charged yet.
  Money? get portfolioRealised {
    var total = CurrencyAmounts.zero;
    var any = false;
    for (final p in state.ledger.positions.values) {
      if (p.disposals.isEmpty && p.realised.isZero) continue;
      any = true;
      total = total.add(p.realised);
    }
    return any ? total.inCurrency(_baseCurrency(), _market.state.rates) : null;
  }

  /// Realised gains and losses for each calendar year, newest first: each
  /// sale's result in the year it was sold, and each standalone fee in the
  /// year it was charged.
  List<(int, Money)> get realisedByYear {
    final byYear = <int, CurrencyAmounts>{};
    for (final t in state.transactions) {
      final CurrencyAmounts amount;
      if (t.kind == TransactionKind.fee) {
        amount = CurrencyAmounts({t.currency: -t.fee});
      } else {
        final effect = state.ledger[t.instrumentID]?.disposals[t.id];
        if (effect == null || effect.realised.isZero) continue;
        amount = effect.realised;
      }
      final year = t.date.toLocal().year;
      byYear[year] = (byYear[year] ?? CurrencyAmounts.zero).add(amount);
    }
    final years = byYear.keys.toList()..sort((a, b) => b.compareTo(a));
    return [for (final y in years) (y, byYear[y]!.inCurrency(_baseCurrency(), _market.state.rates))];
  }

  /// Instruments with transactions but nothing left held — sold or moved
  /// out entirely — with what they realised, largest result first.
  List<({Instrument instrument, Money realised})> get closedPositions {
    final result = <({Instrument instrument, Money realised})>[];
    for (final p in state.ledger.positions.values) {
      if (p.openLots.isNotEmpty) continue;
      final instrument = InstrumentCatalog.instrument(p.instrumentID);
      if (instrument == null) continue;
      result.add((instrument: instrument, realised: p.realised.inCurrency(_baseCurrency(), _market.state.rates)));
    }
    result.sort((a, b) => b.realised.amount.compareTo(a.realised.amount));
    return result;
  }

  /// Total held across every lot of [instrument], expressed in [unit] at
  /// [karat]'s purity (e.g. the originating watch card's unit/karat). Each
  /// lot's own karat is applied exactly once, inside
  /// [HoldingLot.fineOunces] — [karat] only controls how that already
  /// purity-adjusted total is re-expressed for display.
  double? totalQuantity(Instrument instrument, PriceUnit unit, {GoldKarat? karat}) {
    final lots = lotsFor(instrument);
    if (lots.isEmpty) return null;
    return HoldingTotals.totalHeld(lots: lots, refUnit: unit, refKarat: karat);
  }

  /// Average cost per [unit] at [karat]'s purity, in [currency], at the
  /// live FX rate (same rule [HoldingValuation.aggregate] uses).
  Money? averageCost(Instrument instrument, String currency, PriceUnit unit, {GoldKarat? karat}) {
    final lots = lotsFor(instrument);
    return HoldingTotals.averageCost(
      lots: lots,
      refUnit: unit,
      refKarat: karat,
      displayCurrency: currency,
      rates: _market.state.rates,
    );
  }

  /// Every transaction for [instrument], newest first.
  List<HoldingTransaction> transactionsFor(Instrument instrument) =>
      Ledger.ordered(state.transactions.where((t) => t.instrumentID == instrument.id)).reversed.toList();

  /// The sale [transaction] would leave selling more than was held, or null
  /// when it's safe to save. Checked against the whole ledger: back-dating a
  /// sell, shrinking a buy or moving a buy later can all break a sale that
  /// comes after it.
  HoldingTransaction? conflictForSave(HoldingTransaction transaction) => Ledger.conflict(
        state.transactions,
        [...state.transactions.where((t) => t.id != transaction.id), transaction],
      );

  /// The sale deleting [transaction] would break, or null when it's safe.
  HoldingTransaction? conflictForDelete(HoldingTransaction transaction) => Ledger.conflict(
        state.transactions,
        state.transactions.where((t) => t.id != transaction.id),
      );

  // ---------------------------------------------------------------------
  // Mutations
  // ---------------------------------------------------------------------

  /// Tells Money the book changed under it: a trade is an entry there, so
  /// its lists, balances and analysis follow every write made here.
  Future<void> _notifyBook() async => await onBookChanged?.call(BookStore.entriesKey);

  /// Saves [transaction] unless it would break a sale; returns that sale
  /// instead of saving when it would. [cash] is the account it was paid from
  /// or into (null when no cash moved) and [label] the instrument's name as
  /// Money shows it; trade and cash are one record, so they are saved
  /// together or not at all. Throws [HoldingRejected], saving nothing, when
  /// the trade would not make a sound entry.
  Future<HoldingTransaction?> saveTransaction(HoldingTransaction transaction, {CashLeg? cash, String label = ''}) async {
    final conflict = conflictForSave(transaction);
    if (conflict != null) return conflict;
    final isNewInstrument = !_tracked().any((i) => i.id == transaction.instrumentID);
    final transactions = await ledgerStore.upsert(transaction, cash: cash, baseCurrency: _baseCurrency(), merchant: label);
    if (isClosed) return null;
    emit(state.copyWith(transactions: transactions));
    await _notifyBook();
    unawaited(_markDataChanged());
    if (isNewInstrument) {
      final instrument = InstrumentCatalog.instrument(transaction.instrumentID);
      if (instrument != null) unawaited(_market.refresh(instrument));
    }
    return null;
  }

  /// Adds a batch of already-validated rows (a CSV import) and starts
  /// tracking any asset that's new to the app. Returns their ids, for undo.
  Future<List<String>> importTransactions(List<HoldingTransaction> transactions) async {
    if (transactions.isEmpty) return const [];
    final trackedBefore = _tracked().map((i) => i.id).toSet();
    final all = await ledgerStore.addAll(transactions);
    if (isClosed) return [for (final t in transactions) t.id];
    emit(state.copyWith(transactions: all));
    await _notifyBook();
    unawaited(_markDataChanged());
    final added = {for (final t in transactions) t.instrumentID}.difference(trackedBefore);
    if (added.isNotEmpty) {
      for (final id in added) {
        final instrument = InstrumentCatalog.instrument(id);
        if (instrument == null) continue;
        await _market.primeFromCache(instrument);
      }
      unawaited(_market.refreshAll(silent: true));
    }
    return [for (final t in transactions) t.id];
  }

  /// Removes everything one import added.
  Future<void> undoImport(List<String> ids) async {
    final all = await ledgerStore.deleteAll(ids);
    if (isClosed) return;
    emit(state.copyWith(transactions: all));
    await _notifyBook();
    unawaited(_markDataChanged());
  }

  /// Deletes [transaction] unless that would break a sale; returns that sale
  /// instead of deleting when it would.
  Future<HoldingTransaction?> deleteTransaction(HoldingTransaction transaction) async {
    final conflict = conflictForDelete(transaction);
    if (conflict != null) return conflict;
    final transactions = await ledgerStore.delete(transaction.id);
    if (isClosed) return null;
    emit(state.copyWith(transactions: transactions));
    await _notifyBook();
    unawaited(_markDataChanged());
    return null;
  }

  // ---------------------------------------------------------------------
  // Splits
  // ---------------------------------------------------------------------

  /// Splits of [instrument] the person hasn't answered yet that touch their
  /// trades: some share-moving transaction is dated before the split day.
  List<StockSplit> pendingSplitsFor(Instrument instrument) {
    final splits = _market.state.factsByID[instrument.id]?.splits ?? const <StockSplit>[];
    if (splits.isEmpty) return const [];
    final trades = state.transactions.where((t) => t.instrumentID == instrument.id && t.kind.movesQuantity);
    return [
      for (final split in splits)
        if (!state.handledSplits.contains(split.keyFor(instrument.id)) && trades.any((t) => t.date.isBefore(split.date)))
          split,
    ];
  }

  /// Restates every share-moving trade of [instrument] before [split] in
  /// today's shares: quantity times the ratio, price per share divided by
  /// it, so each trade's total and the cash it moved stay the same. One
  /// write, then the split is marked answered.
  Future<void> applySplit(Instrument instrument, StockSplit split) async {
    final ids = [
      for (final t in state.transactions)
        if (t.instrumentID == instrument.id && t.kind.movesQuantity && t.date.isBefore(split.date)) t.id,
    ];
    if (ids.isNotEmpty) {
      final transactions = await ledgerStore.restate(
        ids,
        (t) => t.copyWith(quantity: t.quantity * split.ratio, unitPrice: t.unitPrice / split.ratio),
      );
      if (isClosed) return;
      emit(state.copyWith(transactions: transactions));
      await _notifyBook();
      unawaited(_markDataChanged());
    }
    await _markSplitHandled(instrument, split);
  }

  /// The person's trades were already in today's shares; leaves them.
  Future<void> keepSplit(Instrument instrument, StockSplit split) => _markSplitHandled(instrument, split);

  Future<void> _markSplitHandled(Instrument instrument, StockSplit split) async {
    final handled = {...state.handledSplits, split.keyFor(instrument.id)};
    emit(state.copyWith(handledSplits: handled));
    await _preferences?.setHandledSplits(handled);
  }

  // ---------------------------------------------------------------------
  // Portfolio history (watchlist hero chart)
  // ---------------------------------------------------------------------

  /// Memoization cache for [portfolioHistory], keyed on the exact set of
  /// inputs that can change its output. [PortfolioHistory.build] walks every
  /// tracked lot's full quote/FX series, which is too expensive to redo on
  /// every `build()` (e.g. every scrub-driven rebuild of the hero chart) —
  /// so this cubit computes it once per distinct (range, ledger, seriesByID,
  /// fxHistory, baseCurrency) tuple and reuses the result until one of those
  /// actually changes. The states are immutable/structurally-equal
  /// (`Equatable`/unmodifiable lists), so identity/equality checks here are
  /// cheap and correct.
  ChartRange? _historyCacheRange;
  Ledger? _historyCacheLedger;
  Map<String, QuoteSeries>? _historyCacheSeries;
  FXHistory? _historyCacheFxHistory;
  String? _historyCacheBaseCurrency;
  DateTime? _historyCacheDay;
  List<PortfolioHistoryPoint>? _historyCacheResult;

  /// Day-by-day portfolio value/cost for [range], computed fresh from the ledger
  /// and quote/FX history (never snapshotted — see `portfolio_history.dart`).
  /// Cheap to call repeatedly: results are memoized until holdings, prices, FX
  /// history or the base currency actually change, or a new calendar day
  /// starts (so "All"/"1Y" etc. extend to include today).
  List<PortfolioHistoryPoint> portfolioHistory(ChartRange range) {
    final market = _market.state;
    final baseCurrency = _baseCurrency();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (_historyCacheRange == range &&
        identical(_historyCacheLedger, state.ledger) &&
        identical(_historyCacheSeries, market.seriesByID) &&
        identical(_historyCacheFxHistory, market.fxHistory) &&
        _historyCacheBaseCurrency == baseCurrency &&
        _historyCacheDay == today) {
      return _historyCacheResult!;
    }

    final result = PortfolioHistory.build(
      ledger: state.ledger,
      seriesByID: market.seriesByID,
      rates: market.rates,
      fxHistory: market.fxHistory,
      baseCurrency: baseCurrency,
      range: range,
      now: now,
    );

    _historyCacheRange = range;
    _historyCacheLedger = state.ledger;
    _historyCacheSeries = market.seriesByID;
    _historyCacheFxHistory = market.fxHistory;
    _historyCacheBaseCurrency = baseCurrency;
    _historyCacheDay = today;
    _historyCacheResult = result;
    return result;
  }

  /// Change in GAIN (value − cost), not value, over [range] — so adding a
  /// new lot mid-range is never shown as if it were profit. See
  /// [PortfolioRangeChange.from].
  PortfolioRangeChange? portfolioChange(ChartRange range) =>
      PortfolioRangeChange.from(portfolioHistory(range), range);

  (Ledger, Map<String, QuoteSeries>, FXHistory, FXRates, String, DateTime)? _summaryKey;
  PeriodSummary? _summary;

  /// The past month as facts for the summary sentence (v4 phase 3), or null
  /// when nothing was held. One history walk per held instrument, so it is
  /// memoized like [portfolioHistory].
  PeriodSummary? periodSummary() {
    final market = _market.state;
    final baseCurrency = _baseCurrency();
    final now = DateTime.now();
    final key = (state.ledger, market.seriesByID, market.fxHistory, market.rates, baseCurrency, DateTime(now.year, now.month, now.day));
    final cached = _summaryKey;
    if (cached != null &&
        identical(cached.$1, key.$1) &&
        identical(cached.$2, key.$2) &&
        identical(cached.$3, key.$3) &&
        identical(cached.$4, key.$4) &&
        cached.$5 == key.$5 &&
        cached.$6 == key.$6) {
      return _summary;
    }
    _summaryKey = key;
    return _summary = PeriodSummary.build(
      ledger: state.ledger,
      transactions: state.transactions,
      seriesByID: market.seriesByID,
      rates: market.rates,
      fxHistory: market.fxHistory,
      baseCurrency: baseCurrency,
      now: now,
    );
  }
}
