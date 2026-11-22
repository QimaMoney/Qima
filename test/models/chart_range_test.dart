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
