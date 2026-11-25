import 'dart:async';

import 'app_cubit.dart';
import 'holdings_cubit.dart';
import 'market_cubit.dart';
import 'settings_cubit.dart';
import 'watchlist_cubit.dart';
import '../services/home_widget_service.dart';
import '../services/widget_snapshot.dart';

/// Republishes the home-screen widget data whenever something a widget shows
/// changes (a price tick, an FX rate refresh, a watchlist or holdings edit,
/// the base currency, hide balances) — see [HomeWidgetService] for the
/// payload shape and the "first card stands in for the configured
/// instrument" limitation. This is the single choke point for that fan-out
/// so no individual mutator needs to remember to call it. Nothing is
/// published before start-up has finished, and nothing while a [batch] runs:
/// a restore or a cloud reload changes several cubits one after another, and
/// the widgets should get the result once, not each half-way state.
class WidgetPublisher {
  final AppCubit _app;
  final SettingsCubit _settings;
  final MarketCubit _market;
  final WatchlistCubit _watchlist;
  final HoldingsCubit _holdings;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  /// What was last seen of each thing a widget shows, to tell a change from
  /// an emit that only moved something else.
  bool _initialized;
  Object? _seriesByID;
  Object? _rates;
  Object? _fxHistory;
  Object? _cards;
  Object? _lots;
  String _baseCurrency;
  bool _hideBalances;

  /// Nested [batch] runs in flight.
  int _batches = 0;

  bool _closed = false;

  WidgetPublisher({
    required AppCubit app,
    required SettingsCubit settings,
    required MarketCubit market,
    required WatchlistCubit watchlist,
    required HoldingsCubit holdings,
  })  : _app = app,
        _settings = settings,
        _market = market,
        _watchlist = watchlist,
        _holdings = holdings,
        _initialized = app.state.initialized,
        _seriesByID = market.state.seriesByID,
        _rates = market.state.rates,
        _fxHistory = market.state.fxHistory,
        _cards = watchlist.state.cards,
        _lots = holdings.state.lots,
        _baseCurrency = settings.state.baseCurrency,
        _hideBalances = settings.state.hideBalances {
    // Every cubit's emit comes here and the cubits are read as they are now,
    // so an event that arrives after the change it reports was already
    // handled (a batch ends first) finds nothing new.
    for (final stream in [app.stream, market.stream, watchlist.stream, holdings.stream, settings.stream]) {
      _subscriptions.add(stream.listen((_) => _changed()));
    }
  }

  void _changed() {
    if (_closed || _batches > 0) return;
    final market = _market.state;
    final settings = _settings.state;
    // The first publish, when start-up finishes, sends what the widgets
    // would otherwise only get at the first later change: fresher than what
    // they hold from the last session, never staler.
    final started = !_initialized && _app.state.initialized;
    final changed = started ||
        _seriesByID != market.seriesByID ||
        _rates != market.rates ||
        _fxHistory != market.fxHistory ||
        _cards != _watchlist.state.cards ||
        _lots != _holdings.state.lots ||
        _baseCurrency != settings.baseCurrency ||
        _hideBalances != settings.hideBalances;
    _initialized = _app.state.initialized;
    _seriesByID = market.seriesByID;
    _rates = market.rates;
    _fxHistory = market.fxHistory;
    _cards = _watchlist.state.cards;
    _lots = _holdings.state.lots;
    _baseCurrency = settings.baseCurrency;
    _hideBalances = settings.hideBalances;
    if (changed) _publish();
  }

  /// Runs [body], then publishes once if anything a widget shows changed
  /// during it. Publishes even when [body] throws, since what it changed
  /// before throwing is already shown.
  Future<void> batch(Future<void> Function() body) async {
    _batches++;
    try {
      await body();
    } finally {
      _batches--;
      _changed();
    }
  }

  void _publish() {
    if (!_app.state.initialized) return;
    final market = _market.state;
    unawaited(HomeWidgetService.publish(WidgetData(
      cards: _watchlist.state.cards,
      ledger: _holdings.state.ledger,
      seriesByID: market.seriesByID,
      rates: market.rates,
      fxHistory: market.fxHistory,
      lastRefresh: market.lastRefresh,
      hideBalances: _settings.state.hideBalances,
      baseCurrency: _settings.state.baseCurrency,
    )));
  }

  Future<void> close() async {
    _closed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
  }
}
