import 'display_point.dart';
import 'market_hours.dart';

/// Where each sample of a chart sits along its time axis.
///
/// For something that trades in sessions, time the market is closed takes up
/// almost no room, so a week of a stock reads as five trading days instead of
/// flat lines across nights and the weekend. Without a market, or for one
/// that never closes, positions are plain elapsed time. Positions are in
/// seconds of (weighted) time from the first sample, always increasing.
class ChartTimeAxis {
  /// The share of its real length that closed time keeps. Above zero so every
  /// sample still gets its own place, even one stamped while closed.
  static const double closedWeight = 0.02;

  final List<DateTime> dates;
  final List<double> positions;

  ChartTimeAxis._(this.dates, this.positions);

  factory ChartTimeAxis.build(List<DisplayPoint> points, {Market? market}) {
    final dates = [for (final p in points) p.date];
    if (dates.isEmpty) return ChartTimeAxis._(dates, const []);
    final start = dates.first;
    double seconds(DateTime a, DateTime b) => b.difference(a).inMicroseconds / Duration.microsecondsPerSecond;

    if (market == null || market == Market.always || dates.length < 2) {
      return ChartTimeAxis._(dates, [for (final d in dates) seconds(start, d)]);
    }

    // Open time before each sample, walking the sessions once.
    final spans = MarketHours.openSpans(market, start, dates.last);
    final positions = <double>[];
    var span = 0;
    var openBefore = 0.0; // open seconds in spans wholly before `span`
    for (final date in dates) {
      while (span < spans.length && !spans[span].$2.isAfter(date)) {
        openBefore += seconds(spans[span].$1, spans[span].$2);
        span++;
      }
      var open = openBefore;
      if (span < spans.length && date.isAfter(spans[span].$1)) open += seconds(spans[span].$1, date);
      final elapsed = seconds(start, date);
      final position = open + closedWeight * (elapsed - open);
      // Out-of-order or equal stamps never step backwards.
      positions.add(positions.isEmpty || position > positions.last ? position : positions.last);
    }
    return ChartTimeAxis._(dates, positions);
  }

  /// Every sample one step from the last, whatever its date: for samples
  /// that each stand for a whole period (candles), which are as wide as
  /// one another. A period's last price can be minutes or days after the
  /// one before it, and by time its candle would sit against a neighbour
  /// or far from it.
  factory ChartTimeAxis.even(List<DisplayPoint> points) =>
      ChartTimeAxis._([for (final p in points) p.date], [for (var i = 0; i < points.length; i++) i.toDouble()]);

  double get length => positions.isEmpty ? 0 : positions.last;

  /// The position of [date], between the samples around it.
  double positionOf(DateTime date) {
    if (positions.isEmpty) return 0;
    if (!date.isAfter(dates.first)) return 0;
    if (!date.isBefore(dates.last)) return length;
    var lo = 0, hi = dates.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (dates[mid].isAfter(date)) {
        hi = mid;
      } else {
        lo = mid;
      }
    }
    final span = dates[hi].difference(dates[lo]).inMicroseconds;
    if (span <= 0) return positions[lo];
    final t = date.difference(dates[lo]).inMicroseconds / span;
    return positions[lo] + t * (positions[hi] - positions[lo]);
  }

  /// The date at [position], between the samples around it.
  DateTime dateAt(double position) {
    if (positions.isEmpty) return DateTime.fromMillisecondsSinceEpoch(0);
    if (position <= 0) return dates.first;
    if (position >= length) return dates.last;
    final hi = _firstAtOrAfter(position);
    final lo = hi - 1;
    final width = positions[hi] - positions[lo];
    if (width <= 0) return dates[hi];
    final t = (position - positions[lo]) / width;
    final micros = dates[hi].difference(dates[lo]).inMicroseconds;
    return dates[lo].add(Duration(microseconds: (micros * t).round()));
  }

  /// The sample nearest [position].
  int nearestIndex(double position) {
    if (positions.length < 2) return 0;
    if (position <= 0) return 0;
    if (position >= length) return positions.length - 1;
    final hi = _firstAtOrAfter(position);
    final lo = hi - 1;
    return position - positions[lo] <= positions[hi] - position ? lo : hi;
  }

  /// The first sample from [position] on, and from 1 so there's one before.
  int _firstAtOrAfter(double position) {
    var lo = 1, hi = positions.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (positions[mid] < position) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}
