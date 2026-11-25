import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/chart_range.dart';
import 'package:qima/models/display_point.dart';

void main() {
  test('available() falls back to a single chip when fewer than 2 points exist', () {
    final now = DateTime(2024, 6, 1);
    expect(ChartRange.available(const [], now), [ChartRange.day1]);
    expect(
      ChartRange.available([DisplayPoint(date: now, value: 1)], now),
      [ChartRange.day1],
    );
  });

  test('available() only offers ranges the series actually reaches back to', () {
    final now = DateTime(2024, 6, 10);
    // Data only reaches 5 days back: day1/day3 fit (their start is within the
    // data), but day7 (needs 7 days of history) and month3 do not.
    final points = [
      DisplayPoint(date: now.subtract(const Duration(days: 5)), value: 1),
      DisplayPoint(date: now, value: 2),
    ];
    final available = ChartRange.available(points, now);
    expect(available.contains(ChartRange.day3), isTrue);
    expect(available.contains(ChartRange.day7), isFalse);
    expect(available.contains(ChartRange.month3), isFalse);
  });

  test('available(includeExtended: true) with degenerate data returns [.all]', () {
    final now = DateTime(2024, 6, 10);
    expect(ChartRange.available(const [], now, includeExtended: true), [ChartRange.all]);
  });

  group('one day is the last day the price moved', () {
    DisplayPoint at(DateTime t, double v) => DisplayPoint(date: t, value: v);

    test('while the market moves, it is the last 24 hours', () {
      final now = DateTime(2026, 3, 11, 15);
      final points = [at(DateTime(2026, 3, 9, 15), 10), at(DateTime(2026, 3, 10, 16), 11), at(DateTime(2026, 3, 11, 14, 45), 12)];
      expect(ChartRange.day1.filter(points, now).map((p) => p.value), [11, 12]);
    });

    test('over a weekend the repeated price is not the day: the last session is, from the close before it', () {
      // Thursday's close, Friday's session, then the same price repeated.
      final points = [
        at(DateTime(2026, 3, 5, 21), 100),
        at(DateTime(2026, 3, 6, 14, 30), 101),
        at(DateTime(2026, 3, 6, 18), 97),
        at(DateTime(2026, 3, 6, 21), 98),
        at(DateTime(2026, 3, 7, 9), 98),
        at(DateTime(2026, 3, 8, 9), 98),
      ];
      final window = ChartRange.day1.filter(points, DateTime(2026, 3, 8, 10));
      expect(window.first.value, 100);
      expect(window.map((p) => p.value), [100, 101, 97, 98, 98, 98]);
    });

    test('a price that has stood still for longer than a long weekend is simply flat', () {
      final now = DateTime(2026, 3, 20, 10);
      final points = [at(DateTime(2026, 3, 1), 3.75), at(DateTime(2026, 3, 2), 3.76), at(DateTime(2026, 3, 19, 12), 3.76), at(DateTime(2026, 3, 20, 9), 3.76)];
      expect(ChartRange.day1.filter(points, now).map((p) => p.date.day), [19, 20]);
    });

    test('other ranges still count back from now', () {
      final now = DateTime(2026, 3, 8, 10);
      final points = [at(DateTime(2026, 2, 28), 1), at(DateTime(2026, 3, 6, 21), 2), at(DateTime(2026, 3, 8, 9), 2)];
      expect(ChartRange.day3.filter(points, now).map((p) => p.value), [2, 2]);
    });

    test('no points, or one, is no day at all', () {
      final now = DateTime(2026, 3, 8, 10);
      expect(ChartRange.day1.filter(const [], now), isEmpty);
      expect(ChartRange.day1.filter([at(DateTime(2026, 3, 8, 9), 5)], now), hasLength(1));
    });
  });

  test('charts open on one day until the person picks a default, and sparklines keep three months', () {
    expect(ChartRange.fallbackDefault, ChartRange.day1);
    expect(ChartRange.portfolioDefault, ChartRange.day1);
    expect(ChartRange.sparklineRange, ChartRange.month3);
  });

  test('every default in Settings has a range on Home, never a shorter one', () {
    final now = DateTime(2026, 11, 22);
    for (final range in ChartRange.defaultSelectable) {
      final home = range.onHome;
      expect(ChartRange.portfolioSelectable, contains(home), reason: range.name);
      final asked = range.startDate(now)!, shown = home.startDate(now);
      expect(shown == null || !shown.isAfter(asked), isTrue, reason: '${range.name} opens on ${home.name}');
    }
    expect(ChartRange.day1.onHome, ChartRange.day1);
    expect(ChartRange.day7.onHome, ChartRange.week1);
    expect(ChartRange.ytd.onHome, ChartRange.year1);
  });
}
