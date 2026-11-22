import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../models/asset.dart';
import '../models/custom_instrument.dart';
import '../models/instrument_catalog.dart';
import '../models/watch_card.dart';
import '../models/watchlist_sort.dart';
import '../services/custom_instrument_store.dart';
import '../services/watchlist_store.dart';
import 'guarded_emit.dart';
import 'market_cubit.dart';
import 'watchlist_state.dart';

/// The watchlist and the custom tickers it can hold. Both are synced
/// collections, so a removed custom ticker takes its cards with it.
class WatchlistCubit extends Cubit<WatchlistState> with GuardedEmit<WatchlistState> {
  final WatchlistStore watchlistStore;
  final CustomInstrumentStore customInstrumentStore;
  final MarketCubit _market;
  final String Function() _baseCurrency;

  /// Marks that user data changed since the last backup.
  final Future<void> Function() _markDataChanged;

  WatchlistCubit({
    required this.watchlistStore,
    required this.customInstrumentStore,
    required MarketCubit market,
    required String Function() baseCurrency,
    required Future<void> Function() markDataChanged,
  })  : _market = market,
        _baseCurrency = baseCurrency,
        _markDataChanged = markDataChanged,
        super(const WatchlistState());

  // ---------------------------------------------------------------------
  // Loading
  // ---------------------------------------------------------------------

  /// Start-up: the stored cards, seeding [seed] when there are none.
  Future<void> load(List<WatchCard> seed) async {
    emit(state.copyWith(cards: await _loadSeeding(seed)));
  }

  /// [WatchlistStore]'s seed callback is synchronous, but seeding the
  /// default watchlist needs the (async) base currency — so seed once here
  /// and pass the precomputed list through.
  Future<List<WatchCard>> _loadSeeding(List<WatchCard> seed) async {
    // The store was already constructed without a seed closure (it doesn't
    // know about it yet at this point in a from-scratch install); load()
    // will seed from an empty local+cloud state using whatever `seed`
    // callback it was given at construction. Since the default
    // [WatchlistStore] takes no seed, replicate the seeding here directly.
    final loaded = await watchlistStore.load();
    if (loaded.isNotEmpty) return loaded;
    if (seed.isEmpty) return loaded;
    for (final card in seed) {
      await watchlistStore.upsert(card);
    }
    return watchlistStore.load();
  }

  /// The stored cards, not yet shown; [adopt] shows them. Split so the
  /// prices they need can be in place first (see `SyncCubit`).
  Future<List<WatchCard>> read() => watchlistStore.load();

  /// Shows [cards] as read by [read].
  void adopt(List<WatchCard> cards) {
    if (cards != state.cards) emit(state.copyWith(cards: cards));
  }

  /// Makes the stored custom tickers known to [InstrumentCatalog].
  Future<void> loadCustomInstruments() async {
    final customs = await customInstrumentStore.load();
    InstrumentCatalog.reloadCustom(customs.map((c) => c.instrument).toList());
  }

  // ---------------------------------------------------------------------
  // Queries
  // ---------------------------------------------------------------------

  WatchCard? firstCard(Instrument instrument) {
    for (final card in state.cards) {
      if (card.instrumentID == instrument.id) return card;
    }
    return null;
  }

  // ---------------------------------------------------------------------
  // Watchlist mutations
  // ---------------------------------------------------------------------

  /// Adds [card] to the watchlist, unless a card with the same
  /// instrument/currency/unit/karat combo already exists — in which case the
  /// EXISTING card is returned with `created: false` instead of adding a
  /// duplicate. Callers use `created` to decide whether to show an "added"
  /// or "already in your watchlist" confirmation (see `AddFlowNavigation`).
  Future<({WatchCard card, bool created})> addCard(WatchCard card) async {
    for (final c in state.cards) {
      if (c.isSameCombo(card)) return (card: c, created: false);
    }

    final isNewInstrument = card.instrument != null && !_market.state.seriesByID.containsKey(card.instrumentID);
    final cards = await watchlistStore.upsert(card);
    emit(state.copyWith(cards: cards));
    unawaited(_markDataChanged());

    if (isNewInstrument) {
      final instrument = card.instrument!;
      await _market.primeFromCache(instrument);
      unawaited(_market.refresh(instrument));
      unawaited(_market.backfillHistoryIfNeeded());
    }
    return (card: card, created: true);
  }

  /// Puts the prices picked in setup on the watchlist. The three seeded
  /// cards (see `Preferences.seedWatchcards`) were never the person's
  /// choice, so they make way for the picks, but only while the watchlist is
  /// still exactly the seed: once the person has added or removed anything,
  /// the picks are added next to what is there.
  Future<void> adoptSetupWatchlist(List<WatchCard> picks) async {
    if (picks.isEmpty) return;
    final seedIDs = {
      for (final id in InstrumentCatalog.defaultWatchlist)
        if (InstrumentCatalog.instrument(id) case final instrument?)
          WatchCard.seed(instrumentID: id, currency: _baseCurrency(), unit: instrument.quotation.defaultUnit),
    };
    final untouched = state.cards.length == seedIDs.length && state.cards.every((c) => seedIDs.contains(c.id));
    final replaced = untouched ? [for (final c in state.cards) if (!picks.any(c.isSameCombo)) c.id] : const <String>[];
    for (final card in picks) {
      await addCard(card);
    }
    for (final id in replaced) {
      await removeCard(id);
    }
  }

  /// Reverses a just-completed add-instrument flow: removes [card] from the
  /// watchlist, and — if [customInstrumentID] is given (the ticker was
  /// created fresh in that same flow, not a pre-existing custom ticker) —
  /// also removes the custom instrument itself, but only when no other
  /// watchlist card still references it (a user could have added the same
  /// freshly-created ticker at two currencies before hitting Undo on one).
  Future<void> undoAdd(WatchCard card, {String? customInstrumentID}) async {
    await removeCard(card.id);
    if (customInstrumentID == null) return;
    final stillUsed = state.cards.any((c) => c.instrumentID == customInstrumentID);
    if (!stillUsed) {
      await removeCustomInstrument(customInstrumentID);
    }
  }

  Future<void> updateCard(WatchCard card) async {
    final cards = await watchlistStore.upsert(card);
    emit(state.copyWith(cards: cards));
    unawaited(_markDataChanged());
  }

  Future<void> removeCard(String id) async {
    final cards = await watchlistStore.delete(id);
    emit(state.copyWith(cards: cards));
    unawaited(_markDataChanged());
  }

  Future<void> removeAt(int index) async {
    if (index < 0 || index >= state.cards.length) return;
    await removeCard(state.cards[index].id);
  }

  Future<void> move(int fromIndex, int toIndex) async {
    final cards = List.of(state.cards);
    final item = cards.removeAt(fromIndex);
    cards.insert(toIndex > fromIndex ? toIndex - 1 : toIndex, item);
    await _saveOrder(cards);
  }

  /// Rewrites the watchlist order by [sort]. [nameOf] is the localized row
  /// name, which only the UI can resolve.
  Future<void> sortWatchlist(WatchlistSort sort, {required String Function(WatchCard) nameOf}) async {
    final now = DateTime.now();
    final cards = sortWatchCards(
      state.cards,
      sort,
      nameOf: nameOf,
      changeOf: (card) => _market.presentation(card).sparklineChange(now)?.percentValue,
      assetClassOf: (card) => _market.presentation(card).instrument.assetClass,
    );
    await _saveOrder(cards);
  }

  Future<void> _saveOrder(List<WatchCard> cards) async {
    emit(state.copyWith(cards: cards));
    await watchlistStore.setOrder(cards.map((c) => c.id).toList());
    unawaited(_markDataChanged());
  }

  // ---------------------------------------------------------------------
  // Custom tickers
  // ---------------------------------------------------------------------

  Future<List<CustomInstrument>> customInstruments() => customInstrumentStore.load();

  bool isCustom(String instrumentID) {
    final builtInIds = InstrumentCatalog.builtIn.map((i) => i.id).toSet();
    final resolved = InstrumentCatalog.instrument(instrumentID) != null;
    return resolved && !builtInIds.contains(instrumentID);
  }

  Future<Instrument> validateCustomTicker(String symbol, String? name, {AssetClass assetClass = AssetClass.stock}) async {
    final candidate = CustomInstrument(symbol: symbol, name: name, assetClass: assetClass);
    await _market.probePrice(candidate.instrument);
    return candidate.instrument;
  }

  Future<Instrument> addCustomTicker(String symbol, String? name, {AssetClass assetClass = AssetClass.stock}) async {
    final candidate = CustomInstrument(symbol: symbol, name: name, assetClass: assetClass);
    await customInstrumentStore.upsert(candidate);
    await loadCustomInstruments();
    unawaited(_markDataChanged());
    return candidate.instrument;
  }

  Future<void> removeCustomInstrument(String instrumentID) async {
    final customs = await customInstrumentStore.load();
    CustomInstrument? match;
    for (final c in customs) {
      if (c.instrumentID == instrumentID) {
        match = c;
        break;
      }
    }
    if (match != null) {
      await customInstrumentStore.delete(match.id);
      unawaited(_markDataChanged());
      await loadCustomInstruments();
    }
    final toRemove = state.cards.where((c) => c.instrumentID == instrumentID).map((c) => c.id).toList();
    for (final id in toRemove) {
      await removeCard(id);
    }
  }
}
