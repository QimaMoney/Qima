import '../services/price_converter.dart';
import '../services/quote_provider.dart';
import 'asset.dart';
import 'chart_range.dart';
import 'display_point.dart';
import 'instrument_facts.dart';
import 'metal_breakdown.dart';
import 'money.dart';
import 'quote.dart';

/// A window-scoped change figure: the absolute and percent delta over
/// exactly the window it is displayed beside (spec §8.12 — never mix an
/// all-time percent with a bounded curve).
class RangeChange {
  final double absoluteValue;
  final double percentValue;
  final bool isUp;

  const RangeChange({required this.absoluteValue, required this.percentValue, required this.isUp});
}

/// View-projection layer over an [Instrument] + [QuoteSeries] +
/// [PriceConverter]. Mirrors `InstrumentPresentation.swift`.
class InstrumentPresentation {
  final Instrument instrument;
  final QuoteSeries series;
  final PriceConverter converter;

  List<DisplayPoint>? _pointsCache;

  InstrumentPresentation({required this.instrument, required this.series, required this.converter});

  /// Lazily-memoized projected points (avoids recomputing the FX walk
  /// multiple times per render).
  List<DisplayPoint> get points => _pointsCache ??= converter.points(series);

  String get symbol => instrument.symbol;

  String get displayCurrency => converter.currencyCode;

  bool get hasData => !series.isEmpty;

  /// Trailing 3-month window used for the watchlist row sparkline.
  List<DisplayPoint> sparklinePoints(DateTime now) => ChartRange.fallbackDefault.filter(points, now);

  /// Change over [range]. Returns null when the window has fewer than 2
  /// points or a zero-valued first point (never fabricates a flat 0%).
  RangeChange? change(ChartRange range, DateTime now) {
    final window = range.filter(points, now);
    if (window.length < 2) return null;
    final first = window.first.value;
    final last = window.last.value;
    if (first == 0) return null;
    final delta = last - first;
    final fraction = delta / first;
    return RangeChange(absoluteValue: delta, percentValue: fraction, isUp: fraction >= 0);
  }

  RangeChange? sparklineChange(DateTime now) => change(ChartRange.fallbackDefault, now);

  /// [value] as the exchange quotes it in [currency] (pence included), in
  /// this presentation's currency and unit.
  Money exchangeMoney(double value, String currency) => converter.money(usdFromPrice(value, currency, converter.rates));

  /// Today's change against the exchange's previous close, the figure
  /// exchanges quote, rather than against the first price fetched today.
  /// Null without both prices, or once the price has gone stale.
  RangeChange? dayChange(InstrumentFacts? facts, DateTime now) {
    final price = facts?.price, close = facts?.previousClose;
    if (facts == null || price == null || close == null || close <= 0 || facts.isStale(now)) return null;
    final fraction = price / close - 1;
    return RangeChange(
      absoluteValue: exchangeMoney(price - close, facts.currency).amount,
      percentValue: fraction,
      isUp: fraction >= 0,
    );
  }

  /// The lowest and highest price over the year to [now] from the history
  /// held, or null when it doesn't reach back most of a year.
  (double, double)? yearRangeFromHistory(DateTime now) {
    final since = now.subtract(const Duration(days: 365));
    final window = [for (final p in points) if (!p.date.isBefore(since)) p];
    if (window.length < 2 || window.first.date.isAfter(now.subtract(const Duration(days: 300)))) return null;
    var low = window.first.value, high = low;
    for (final p in window) {
      if (p.value < low) low = p.value;
      if (p.value > high) high = p.value;
    }
    return (low, high);
  }

  /// Whole-series (unbounded) trend, used by widgets/watch complications.
  bool get isTrendingUp {
    if (points.isEmpty) return true;
    return points.last.value >= points.first.value;
  }

  bool get isAvailable => hasData && converter.canConvert;

  /// Whole-series (unbounded) percent change; 0 if the series is degenerate.
  double get percentChange {
    if (points.length < 2) return 0;
    final first = points.first.value;
    if (first == 0) return 0;
    return (points.last.value - first) / first;
  }

  String? get unitSuffix => converter.unit.abbreviationKey;

  String? get karatLabel => converter.karat?.shortLabelKey;

  /// Latest price in the display currency, or null if there's no data.
  Money? get latestMoney {
    final latest = series.latest;
    return latest == null ? null : converter.moneyForQuote(latest);
  }

  /// Latest price formatted in full or compact precision; "—" if no data.
  String get latestPrice => latestMoney?.formatted() ?? '—';

  String get compactPrice => latestMoney?.compact() ?? '—';

  /// Rows for the metal breakdown card: troy-ounce and kilogram prices,
  /// then either per-karat gram prices (gold) or a single plain gram price
  /// (other metals). Empty for non-metals or when there's no data.
  List<MetalBreakdownRow> get metalBreakdown {
    if (instrument.assetClass != AssetClass.metal || series.isEmpty) return const [];
    final latest = series.latest!;
    final rows = <MetalBreakdownRow>[];

    PriceConverter converterFor(PriceUnit unit, GoldKarat? karat) => PriceConverter(
          rates: converter.rates,
          currencyCode: converter.currencyCode,
          unit: unit,
          karat: karat,
          history: converter.history,
        );

    rows.add(MetalBreakdownRow(
      id: 'troyOunce',
      label: PriceUnit.troyOunce.labelKey,
      value: converterFor(PriceUnit.troyOunce, null).moneyForQuote(latest).formatted(),
    ));
    rows.add(MetalBreakdownRow(
      id: 'kilogram',
      label: PriceUnit.kilogram.labelKey,
      value: converterFor(PriceUnit.kilogram, null).moneyForQuote(latest).formatted(),
    ));

    if (instrument.supportedKarats.isNotEmpty) {
      for (final karat in instrument.supportedKarats) {
        rows.add(MetalBreakdownRow(
          id: 'gram-${karat.rawValue}',
          label: '${karat.shortLabelKey} ${PriceUnit.gram.abbreviationKey}',
          value: converterFor(PriceUnit.gram, karat).moneyForQuote(latest).formatted(),
        ));
      }
    } else {
      rows.add(MetalBreakdownRow(
        id: 'gram',
        label: PriceUnit.gram.labelKey,
        value: converterFor(PriceUnit.gram, null).moneyForQuote(latest).formatted(),
      ));
    }

    return rows;
  }
}
