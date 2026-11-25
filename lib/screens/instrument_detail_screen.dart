import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../blocs/app_cubit.dart';
import '../blocs/app_state.dart';
import '../l10n/app_localizations.dart';
import '../models/asset.dart';
import '../models/chart_range.dart';
import '../models/display_point.dart';
import '../models/holding_transaction.dart';
import '../models/instrument_catalog.dart';
import '../models/instrument_presentation.dart';
import '../models/market_hours.dart';
import '../models/watch_card.dart';
import '../theme/design_system.dart';
import '../theme/help_topics.dart';
import '../theme/instrument_theme.dart';
import '../theme/price_chart.dart';
import '../theme/qima_colors.dart';
import '../theme/strings.dart';
import '../widgets/alerts_card.dart';
import '../widgets/help_button.dart';
import '../widgets/instrument_icon.dart';
import '../widgets/key_stats_grid.dart';
import '../widgets/market_status.dart';
import '../widgets/range_selector.dart';
import '../widgets/unit_price_carousel.dart';
import 'currency_picker.dart';
import 'holdings_card.dart';
import 'holdings_screen.dart';
import 'share_asset_sheet.dart';

/// Chart-first ranges offered on the instrument detail screen. Every range
/// is always shown — none are gated behind a "load history" action; picking
/// one that needs data beyond what's cached triggers a lazy background load
/// instead (spec §v2-A "Instrument detail").
const List<ChartRange> _detailRanges = [
  ChartRange.day1,
  ChartRange.day3,
  ChartRange.day7,
  ChartRange.month1,
  ChartRange.month3,
  ChartRange.month6,
  ChartRange.ytd,
  ChartRange.year1,
  ChartRange.all,
];

/// What the price can be drawn against: gold, the US dollar (in the card's
/// currency, so a falling local currency shows) and the S&P 500.
const List<String> _benchmarkIDs = ['metal.XAU', 'fx.USD', 'index.GSPC'];

/// The main instrument screen: an open (no-card) price header, a full-width
/// chart with range chips, key stats, a price-per-unit carousel (metals
/// only), and a compact holdings summary. Mirrors
/// `InstrumentDetailView.swift`.
class InstrumentDetailScreen extends StatefulWidget {
  final WatchCard card;

  const InstrumentDetailScreen({super.key, required this.card});

  @override
  State<InstrumentDetailScreen> createState() => _InstrumentDetailScreenState();
}

class _InstrumentDetailScreenState extends State<InstrumentDetailScreen> {
  late WatchCard _card;
  late ChartRange _range;

  /// The benchmark drawn against the price, if any.
  Instrument? _compare;

  /// Benchmark history already asked for, per range, so a failed download
  /// isn't retried on every rebuild.
  final Set<String> _compareRequested = {};

  @override
  void initState() {
    super.initState();
    _card = widget.card;
    final cubit = context.read<AppCubit>();
    final preferred = cubit.state.preferredChartRange;
    _range = _detailRanges.contains(preferred) ? preferred : ChartRange.fallbackDefault;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final presentation = cubit.presentation(_card);
      if (presentation.series.isEmpty) {
        cubit.refresh(presentation.instrument);
      }
      _ensureHistoryFor(_range);
    });
  }

  /// Triggers a lazy history backfill the first time a range that needs
  /// data older than what's cached is selected — the replacement for the
  /// old explicit "Load history" button. Cheap to call repeatedly:
  /// `AppCubit.loadHistory` itself no-ops while already loading, and this
  /// only fires when the currently available points don't reach back far
  /// enough for the requested range.
  void _ensureHistoryFor(ChartRange range) {
    final cubit = context.read<AppCubit>();
    final presentation = cubit.presentation(_card);
    final now = DateTime.now();
    final points = presentation.points;
    final start = range.startDate(now);
    final reachesBack = points.length >= 2 &&
        (start == null ? true : !points.first.date.isAfter(start));
    if (reachesBack) return;
    cubit.loadHistory(presentation.instrument, _card.currency);
  }

  void _select(ChartRange range) {
    setState(() => _range = range);
    if (!range.isExtended) {
      context.read<AppCubit>().setPreferredChartRange(range);
    }
    _ensureHistoryFor(range);
  }

  List<Instrument> _benchmarks(Instrument instrument) => [
        for (final id in _benchmarkIDs)
          if (InstrumentCatalog.instrument(id) case final benchmark?)
            if (benchmark.id != instrument.id && !(benchmark.id == 'fx.USD' && _card.currency == 'USD')) benchmark,
      ];

  /// [benchmark]'s prices in the card's currency.
  List<DisplayPoint> _comparePoints(AppCubit cubit, Instrument benchmark) => cubit
      .presentation(WatchCard(
        id: 'compare.${benchmark.id}',
        instrumentID: benchmark.id,
        currency: _card.currency,
        unit: benchmark.quotation.defaultUnit,
      ))
      .points;

  /// Downloads the benchmark's history once per range when what's cached
  /// doesn't reach back far enough. Waits while another download runs, since
  /// the cubit takes one at a time.
  void _ensureCompareHistory() {
    final benchmark = _compare;
    if (benchmark == null || !mounted) return;
    final cubit = context.read<AppCubit>();
    if (cubit.state.isLoadingHistory) return;
    final points = _comparePoints(cubit, benchmark);
    final start = _range.startDate(DateTime.now());
    final reachesBack = points.length >= 2 && (start == null || !points.first.date.isAfter(start));
    if (reachesBack || !_compareRequested.add('${benchmark.id}|${_range.name}')) return;
    cubit.loadHistory(benchmark, _card.currency);
  }

  void _setCompare(Instrument? benchmark) {
    setState(() => _compare = benchmark);
    _ensureCompareHistory();
  }

  /// The person's own transactions on this instrument, for the chart.
  List<ChartMark> _marks(BuildContext context, AppCubit cubit, Instrument instrument) {
    final l10n = AppLocalizations.of(context)!;
    return [
      for (final t in cubit.transactionsFor(instrument))
        ChartMark(
          date: t.date,
          kind: switch (t.kind) {
            TransactionKind.buy => ChartMarkKind.buy,
            TransactionKind.sell => ChartMarkKind.sell,
            _ => ChartMarkKind.other,
          },
          label: t.kind.movesQuantity
              ? '${transactionKindLabel(l10n, t.kind)} · ${quantityWithUnitKaratLabel(context, t.quantity, t.unit, t.karat)}'
              : transactionKindLabel(l10n, t.kind),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<AppCubit>();
    final l10n = AppLocalizations.of(context)!;
    final colors = context.colors;

    return BlocBuilder<AppCubit, AppState>(
      builder: (context, state) {
        final presentation = cubit.presentation(_card);
        final instrument = presentation.instrument;
        final now = DateTime.now();
        final windowChange = presentation.change(_range, now);
        final accent = InstrumentTheme.accentColor(instrument, colors);
        final lastQuoteTime = presentation.series.latest?.timestamp.toLocal();
        if (_compare != null && !state.isLoadingHistory) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _ensureCompareHistory());
        }

        return ScreenBackground(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              title: Text(displayLabel(context, instrument.nameKey)),
              actions: [
                const HelpButton(topic: HelpTopicId.assetDetail),
                if (presentation.hasData)
                  IconButton(
                    icon: Icon(Icons.adaptive.share),
                    tooltip: l10n.shareAction,
                    onPressed: () => ShareAssetSheet.show(context, card: _card, range: _range),
                  ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.tune),
                  onSelected: (value) async {
                    if (value == 'currency') {
                      final selected = await CurrencyPicker.show(
                        context,
                        selected: _card.currency,
                        currencies: state.rates.availableCurrencies,
                      );
                      if (selected != null) {
                        final updated = _card.copyWith(currency: selected);
                        setState(() => _card = updated);
                        await cubit.updateCard(updated);
                      }
                    } else if (value.startsWith('compare:')) {
                      _setCompare(InstrumentCatalog.instrument(value.substring(8)));
                    } else if (value.startsWith('unit:')) {
                      final unit = PriceUnit.values.byName(value.substring(5));
                      final updated = _card.copyWith(unit: unit);
                      setState(() => _card = updated);
                      await cubit.updateCard(updated);
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(value: 'currency', child: Text(l10n.detailChangeCurrency)),
                    for (final unit in instrument.supportedUnits)
                      PopupMenuItem(
                        value: 'unit:${unit.name}',
                        child: Text(l10n.detailShowPerUnit(displayLabel(context, unit.labelKey))),
                      ),
                    if (presentation.hasData) ...[
                      const PopupMenuDivider(),
                      for (final benchmark in _benchmarks(instrument))
                        // A plain item, so its text lines up with the ones above.
                        PopupMenuItem(
                          value: 'compare:${benchmark.id}',
                          child: Row(
                            children: [
                              Expanded(child: Text(l10n.chartCompareWith(displayLabel(context, benchmark.nameKey)))),
                              if (_compare?.id == benchmark.id) Icon(Icons.check, size: 18, color: colors.textSecondary),
                            ],
                          ),
                        ),
                      if (_compare != null) PopupMenuItem(value: 'compare:', child: Text(l10n.chartStopComparing)),
                    ],
                  ],
                ),
                // Alerts are added from the Alerts card's +, and prices refresh
                // by pulling down, so the bar keeps just help and display
                // options.
              ],
            ),
            body: RefreshIndicator(
              onRefresh: () => cubit.refresh(instrument),
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: DS.spaceMD, vertical: DS.spaceSM),
                children: [
                  // Open header — no card background, per spec: icon, name,
                  // symbol/unit line, big price, change pill.
                  Row(
                    children: [
                      InstrumentIcon(instrument: instrument, size: 40),
                      const SizedBox(width: DS.spaceSM),
                      Expanded(
                        child: Text(
                          '${presentation.symbol} · ${presentation.displayCurrency}'
                          '${presentation.unitSuffix != null ? ' / ${displayLabel(context, presentation.unitSuffix!)}' : ''}',
                          style: TextStyle(color: colors.textTertiary, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: DS.spaceSM),
                  Text(
                    presentation.latestPrice,
                    style: TextStyle(color: colors.textPrimary, fontSize: DS.figureDisplay, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: DS.spaceXS),
                  Row(
                    children: [
                      if (windowChange != null)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: DS.spaceSM, vertical: 4),
                          decoration: BoxDecoration(
                            color: QimaColors.trendColor(windowChange.isUp, colors).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(DS.radiusPill),
                          ),
                          child: Text(
                            signedFigure('${(windowChange.percentValue * 100).toStringAsFixed(2)}%', isUp: windowChange.isUp),
                            style: TextStyle(
                              color: QimaColors.trendColor(windowChange.isUp, colors),
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                        )
                      else if (!presentation.hasData)
                        Text(l10n.pricePullToRefresh, style: TextStyle(color: colors.textTertiary, fontSize: 12)),
                      const SizedBox(width: DS.spaceSM),
                      Expanded(
                        child: Text(
                          lastQuoteTime == null
                              ? ''
                              : '${displayLabel(context, _range.labelKey)} · ${l10n.detailUpdatedAt(_updatedLabel(context, lastQuoteTime, now))}',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: colors.textTertiary, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: DS.spaceXS),
                  MarketStatusLine(instrument: instrument, now: now),
                  const SizedBox(height: DS.spaceMD),
                  AlertsCard(card: _card),
                  const SizedBox(height: DS.spaceMD),
                  RangeSelector(
                    ranges: _detailRanges,
                    selected: _range,
                    onSelected: _select,
                    accent: accent,
                  ),
                  const SizedBox(height: DS.spaceSM),
                  SizedBox(
                    height: 260,
                    child: KeyedSubtree(
                      key: ValueKey(_range),
                      child: _buildChart(context, colors, presentation, _range, now, windowChange, accent, state),
                    ),
                  ),
                  if (_compare case final benchmark?)
                    _CompareLegend(
                      name: displayLabel(context, benchmark.nameKey),
                      change: _windowChange(_range.filter(_comparePoints(cubit, benchmark), now)),
                      onClose: () => _setCompare(null),
                    ),
                  const SizedBox(height: DS.spaceMD),
                  KeyStatsGrid(
                    windowed: _range.filter(presentation.points, now),
                    changePercent: windowChange?.percentValue,
                    changeIsUp: windowChange?.isUp,
                  ),
                  if (instrument.assetClass == AssetClass.metal) ...[
                    const SizedBox(height: DS.spaceMD),
                    UnitPriceCarousel(rows: presentation.metalBreakdown),
                  ],
                  const SizedBox(height: DS.spaceMD),
                  HoldingsCard(
                    instrument: instrument,
                    displayCurrency: _card.currency,
                    refUnit: _card.unit,
                    refKarat: _card.karat,
                  ),
                  if (state.phase == RefreshPhase.failed && state.errorMessage != null) ...[
                    const SizedBox(height: DS.spaceMD),
                    DSCard(
                      child: Text(
                        displayLabel(context, state.errorMessage!),
                        style: TextStyle(color: colors.down),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// "14:32" for a quote from today, "Sep 25, 14:32" for an older one, so a
  /// stale price never reads as fresh.
  String _updatedLabel(BuildContext context, DateTime time, DateTime now) {
    final locale = Localizations.localeOf(context).toString();
    final isToday = time.year == now.year && time.month == now.month && time.day == now.day;
    final format = isToday ? DateFormat.Hm(locale) : DateFormat.MMMd(locale).add_Hm();
    return format.format(time);
  }

  Widget _buildChart(
    BuildContext context,
    QimaColors colors,
    InstrumentPresentation presentation,
    ChartRange range,
    DateTime now,
    RangeChange? windowChange,
    Color accent,
    AppState state,
  ) {
    final windowed = range.filter(presentation.points, now);
    if (windowed.length < 2) {
      if (state.isLoadingHistory) {
        return const Center(child: CircularProgressIndicator());
      }
      final l10n = AppLocalizations.of(context)!;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.show_chart, color: colors.textTertiary, size: 32),
            const SizedBox(height: DS.spaceSM),
            Text(l10n.detailNoHistoryTitle, style: TextStyle(color: colors.textSecondary)),
            const SizedBox(height: 2),
            Text(l10n.detailNoHistoryMessage, style: TextStyle(color: colors.textTertiary, fontSize: 12)),
          ],
        ),
      );
    }
    final cubit = context.read<AppCubit>();
    final benchmark = _compare;
    final chart = PriceChartView(
      points: windowed,
      isTrendingUp: windowChange?.isUp ?? presentation.isTrendingUp,
      accent: QimaColors.trendColor(windowChange?.isUp ?? presentation.isTrendingUp, colors),
      isInteractive: true,
      currencyCode: presentation.displayCurrency,
      market: MarketHours.marketOf(presentation.instrument),
      marks: _marks(context, cubit, presentation.instrument),
      compare: benchmark == null
          ? null
          : ChartCompare(label: displayLabel(context, benchmark.nameKey), points: _comparePoints(cubit, benchmark)),
    );
    if (!state.isLoadingHistory) return chart;
    // What's cached shows at once; a thin bar says older prices are on the way.
    return Stack(
      children: [
        Positioned.fill(child: chart),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Semantics(
            label: AppLocalizations.of(context)!.chartLoadingOlder,
            child: LinearProgressIndicator(minHeight: 2, color: accent, backgroundColor: Colors.transparent),
          ),
        ),
      ],
    );
  }

  /// The change across [points], or null with fewer than two.
  static double? _windowChange(List<DisplayPoint> points) {
    if (points.length < 2 || points.first.value == 0) return null;
    return points.last.value / points.first.value - 1;
  }
}

/// The key under the chart while a benchmark is drawn: a dashed swatch like
/// its line, its name and change over the range, and a button to remove it.
class _CompareLegend extends StatelessWidget {
  final String name;
  final double? change;
  final VoidCallback onClose;

  const _CompareLegend({required this.name, required this.change, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = AppLocalizations.of(context)!;
    final change = this.change;
    return Padding(
      padding: const EdgeInsets.only(top: DS.spaceXS),
      child: Row(
        children: [
          for (var i = 0; i < 3; i++)
            Container(
              width: 4,
              height: 1.5,
              margin: const EdgeInsetsDirectional.only(end: 2),
              color: colors.textSecondary,
            ),
          const SizedBox(width: DS.spaceXS),
          Expanded(
            child: Text(
              change == null
                  ? name
                  : '$name ${signedFigure(percentLabel(context, double.parse((change * 100).toStringAsFixed(2))), isUp: change >= 0)}',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.textSecondary, fontSize: 12),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            tooltip: l10n.chartStopComparing,
            icon: Icon(Icons.close, color: colors.textTertiary),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}
