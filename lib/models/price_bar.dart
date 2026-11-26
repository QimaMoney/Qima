import 'package:equatable/equatable.dart';

import 'chart_range.dart';
import 'display_point.dart';
import 'market_hours.dart';
import 'quote.dart';

/// The span one [PriceBar] covers.
enum BarPeriod {
  halfHour,
  day,
  week,
  month,
  year;

  /// The candle a price chart draws over [range]: short enough to show the
  /// range's shape, long enough that each one is wide enough to read.
  /// History older than [QuoteSeries.intradayWindow] is one sample a day,
  /// so only a one-day chart has candles shorter than a day.
  static BarPeriod forChart(ChartRange range) => switch (range) {
        ChartRange.day1 => BarPeriod.halfHour,
        ChartRange.day3 ||
        ChartRange.day7 ||
        ChartRange.week1 ||
        ChartRange.month1 ||
        ChartRange.month3 =>
          BarPeriod.day,
        ChartRange.month6 || ChartRange.ytd || ChartRange.year1 => BarPeriod.week,
        ChartRange.year5 || ChartRange.all => BarPeriod.month,
      };

  /// The device-local start of the period [date] falls in. Weeks start on
  /// Monday.
  DateTime startOf(DateTime date) {
    final d = date.toLocal();
    return switch (this) {
      BarPeriod.halfHour => DateTime(d.year, d.month, d.day, d.hour, d.minute - d.minute % 30),
      BarPeriod.day => DateTime(d.year, d.month, d.day),
      BarPeriod.week => DateTime(d.year, d.month, d.day - (d.weekday - 1)),
      BarPeriod.month => DateTime(d.year, d.month),
      BarPeriod.year => DateTime(d.year),
    };
  }
}

/// What a price did over one period: where it opened and closed, its
/// extremes, and its average and median, all in display terms.
class PriceBar extends Equatable {
  final BarPeriod period;

  /// The device-local start of the period.
  final DateTime start;

  /// When the period's last price was recorded.
  final DateTime end;

  /// The first price of the period: the open the feed gave its first
  /// sample, else that sample's own price when the period has more than
  /// one. Null for a period known from a single price with no open.
  final double? open;
  final double high;
  final double low;
  final double close;

  /// False when the period is known from a single closing price, so [high]
  /// and [low] are only that price.
  final bool hasExtremes;

  /// The average and median of the period's prices. For a week, month or
  /// year these are over each day's closing price. For a day they are over
  /// a price every [PriceBars.daySlot], and null for a day older than
  /// [QuoteSeries.intradayWindow], which is kept as one sample.
  final double? mean;
  final double? median;

  /// The close of the period before, or null for the first one.
  final double? previousClose;

  const PriceBar({
    required this.period,
    required this.start,
    required this.end,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.hasExtremes,
    this.mean,
    this.median,
    this.previousClose,
  });

  /// The change from the previous period's close, as a fraction.
  double? get change {
    final previous = previousClose;
    return previous == null || previous == 0 ? null : close / previous - 1;
  }

  /// Where the body of this bar starts when drawn: its open, else the close
  /// before it.
  double get bodyOpen => open ?? previousClose ?? close;

  /// Whether the period closed at or above where it started.
  bool get closedUp => close >= bodyOpen;

  /// This bar as one chart sample, dated at its last price.
  DisplayPoint toPoint() => DisplayPoint(date: end, value: close, high: high, low: low, open: bodyOpen);

  @override
  List<Object?> get props => [period, start, end, open, high, low, close, hasExtremes, mean, median, previousClose];
}

/// Which day each price belongs to on a market with opening hours.
///
/// A market with sessions (a stock exchange) has one day per session,
/// looked at over the last [recent] only: its older history is one sample a
/// day, already dated on the day it traded.
///
/// A market open around the clock with a weekly close (metals, currencies)
/// keeps calendar days, over all of its history. Its week ends or starts
/// mid-day on most devices though: in Riyadh gold closes at 01:00 on
/// Saturday. Such a stretch shorter than [_fragment] beside a long closure
/// counts towards the day next to it, so that hour is the end of Friday
/// and not a Saturday of its own.
class _TradingDays {
  static const Duration recent = Duration(days: 8);

  /// How far past now the spans reach, to know whether the market is about
  /// to close for long: a weekend with a holiday on either side.
  static const Duration _ahead = Duration(days: 4);

  /// A market open for less than this at a stretch has sessions, each a
  /// day's trading. One open longer trades around the clock.
  static const Duration _longestSession = Duration(hours: 20);

  /// A closure at least this long ends a trading week; a shorter one is a
  /// daily break.
  static const Duration _longClosure = Duration(hours: 4);

  /// The longest stretch of trading on one calendar day, beside a long
  /// closure, that counts towards the neighbouring day.
  static const Duration _fragment = Duration(hours: 8);

  final List<(DateTime, DateTime)> _spans;
  final bool _aroundClock;
  final DateTime _from;
  final DateTime _until;

  _TradingDays._(this._spans, this._aroundClock, this._from, this._until);

  /// The latest one made per market open around the clock: a chart, a card
  /// and a list ask for the same days on every rebuild, and years of spans
  /// are not worth working out each time.
  static final Map<Market, _TradingDays> _latest = {};

  /// The days of [market] for prices from [earliest] to [now].
  factory _TradingDays.of(Market market, DateTime now, DateTime earliest) {
    final recentFrom = now.subtract(recent);
    final cached = _latest[market];
    if (cached != null &&
        !cached._until.isBefore(now.add(_ahead - const Duration(days: 1))) &&
        !cached._from.isAfter(earliest.isBefore(recentFrom) ? earliest : recentFrom)) {
      return cached;
    }
    final until = now.add(_ahead);
    final spans = MarketHours.openSpans(market, recentFrom, until);
    if (!spans.any((span) => span.$2.difference(span.$1) >= _longestSession)) {
      return _TradingDays._(spans, false, recentFrom, until);
    }
    final from = (earliest.isBefore(recentFrom) ? earliest : recentFrom).subtract(const Duration(days: 2));
    return _latest[market] = _TradingDays._(MarketHours.openSpans(market, from, until), true, from, until);
  }

  /// The index of the last span that had opened by [date], or -1 when
  /// [date] is from before the spans looked at.
  int _indexAt(DateTime date) {
    var low = 0, high = _spans.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_spans[mid].$1.isAfter(date)) {
        high = mid;
      } else {
        low = mid + 1;
      }
    }
    return low - 1;
  }

  bool wasOpen(DateTime date) {
    final i = _indexAt(date);
    return i < 0 || !date.isAfter(_spans[i].$2);
  }

  /// A moment on the day [date]'s price counts towards.
  DateTime dayOf(DateTime date) {
    final i = _indexAt(date);
    if (i < 0) return date;
    final (start, end) = _spans[i];
    if (!_aroundClock) return start;
    // Its own day while open, else the day it closed on.
    final at = date.isAfter(end) ? end.subtract(const Duration(minutes: 1)) : date;
    final day = BarPeriod.day.startOf(at);
    final nextDay = DateTime(day.year, day.month, day.day + 1);
    final closesForLong = i + 1 < _spans.length && _spans[i + 1].$1.difference(end) >= _longClosure;
    if (closesForLong && !end.isAfter(nextDay) && end.difference(day) < _fragment) {
      return day.subtract(const Duration(minutes: 1));
    }
    final openedAfterLong = i > 0 && start.difference(_spans[i - 1].$2) >= _longClosure;
    if (openedAfterLong && !start.isBefore(day) && nextDay.difference(start) < _fragment) return nextDay;
    return at;
  }
}

/// Builds [PriceBar]s from a series of display points.
abstract final class PriceBars {
  /// How far apart the prices a day's average and median are taken over
  /// sit: the spacing of the feed's intraday bars. Live quotes arrive every
  /// minute while the app is open, and counting each would weigh the
  /// minutes the app was open more than the rest of the day.
  static const Duration daySlot = Duration(minutes: 15);

  /// The fewest [daySlot] prices a day's average and median are worked out
  /// from.
  static const int minDaySlots = 4;

  /// One bar per [period] that has a price in [points], oldest first.
  /// [points] must be in date order, as a converter gives them.
  ///
  /// With [market], a price recorded while it was closed counts towards
  /// the day it last traded, a session counts as the day it opened on, and
  /// the last hours of a trading week past midnight count towards the day
  /// before (see [_TradingDays]). Without that, a closing price that
  /// lands after midnight on this device, or a quote fetched on a holiday,
  /// would make a day of its own on which nothing happened.
  static List<PriceBar> build(List<DisplayPoint> points, BarPeriod period, {required DateTime now, Market? market}) {
    final intradaySince = now.subtract(QuoteSeries.intradayWindow);
    // A market that never closes has calendar days and nothing to remap.
    final days = period == BarPeriod.halfHour || market == null || market == Market.always || points.isEmpty
        ? null
        : _TradingDays.of(market, now, points.first.date);
    DateTime startAt(int index) => period.startOf(days?.dayOf(points[index].date) ?? points[index].date);
    final bars = <PriceBar>[];
    double? previousClose;
    var i = 0;
    while (i < points.length) {
      final start = startAt(i);
      var j = i;
      while (j < points.length && startAt(j) == start) {
        j++;
      }
      final bar = _bar(points, i, j, period, start, previousClose, intradaySince, days);
      bars.add(bar);
      previousClose = bar.close;
      i = j;
    }
    return bars;
  }

  static PriceBar _bar(
    List<DisplayPoint> points,
    int from,
    int to,
    BarPeriod period,
    DateTime start,
    double? previousClose,
    DateTime intradaySince,
    _TradingDays? days,
  ) {
    final first = points[from], last = points[to - 1];
    final count = to - from;
    var high = first.peak, low = first.trough;
    var hasExtremes = count > 1;
    // The last price in each slot, in date order: a quarter hour of a day,
    // or a trading day of a longer period. A price repeated while the
    // market was closed is no part of a day's average.
    final slots = <DateTime, double>{};
    for (var k = from; k < to; k++) {
      final p = points[k];
      if (p.peak > high) high = p.peak;
      if (p.trough < low) low = p.trough;
      if (p.high != null && p.low != null) hasExtremes = true;
      switch (period) {
        case BarPeriod.halfHour:
          break;
        case BarPeriod.day:
          if (days == null || days.wasOpen(p.date)) slots[_daySlotOf(p.date)] = p.value;
        default:
          slots[BarPeriod.day.startOf(days?.dayOf(p.date) ?? p.date)] = p.value;
      }
    }

    // A day older than the intraday window is one stored sample (two on a
    // series' first day), which says nothing of the prices within it.
    final measurable = switch (period) {
      BarPeriod.halfHour => false,
      BarPeriod.day => !start.isBefore(intradaySince) && slots.length >= minDaySlots,
      _ => slots.isNotEmpty,
    };
    final values = measurable ? (slots.values.toList()..sort()) : const <double>[];

    return PriceBar(
      period: period,
      start: start,
      end: last.date,
      open: first.open ?? (count > 1 ? first.value : null),
      high: high,
      low: low,
      close: last.value,
      hasExtremes: hasExtremes,
      mean: values.isEmpty ? null : values.reduce((a, b) => a + b) / values.length,
      median: values.isEmpty ? null : _median(values),
      previousClose: previousClose,
    );
  }

  static DateTime _daySlotOf(DateTime date) {
    final d = date.toLocal();
    final minutes = daySlot.inMinutes;
    return DateTime(d.year, d.month, d.day, d.hour, d.minute - d.minute % minutes);
  }

  static double _median(List<double> sorted) {
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  /// Whether [bars] say enough to draw as candles: at least two, most of
  /// them with an open and extremes of their own. A series of closing
  /// prices alone (a currency) would draw as flat boxes.
  static bool drawable(List<PriceBar> bars) {
    if (bars.length < 2) return false;
    final full = bars.where((b) => b.open != null && b.hasExtremes && b.high > b.low).length;
    return full * 2 >= bars.length;
  }
}
