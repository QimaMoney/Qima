import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/chart_range.dart';
import 'package:qima/models/display_point.dart';
import 'package:qima/models/market_hours.dart';
import 'package:qima/models/price_bar.dart';

void main() {
  // A Thursday.
  final now = DateTime(2026, 11, 26, 15);

  DisplayPoint day(DateTime date, double close, {double? open, double? high, double? low}) =>
      DisplayPoint(date: date, value: close, open: open, high: high, low: low);

  group('a month of daily samples', () {
    final points = [
      day(DateTime(2026, 9, 29), 98, open: 97, high: 99, low: 96),
      day(DateTime(2026, 9, 30), 100, open: 98, high: 101, low: 97),
      day(DateTime(2026, 10, 1), 102, open: 100.5, high: 104, low: 100),
      day(DateTime(2026, 10, 2), 110, open: 102, high: 111, low: 101),
      day(DateTime(2026, 10, 5), 106, open: 110, high: 112, low: 105),
      day(DateTime(2026, 10, 6), 104, open: 106, high: 107, low: 99),
    ];
    final bars = PriceBars.build(points, BarPeriod.month, now: now);

    test('is one bar per month, oldest first', () {
      expect(bars.map((b) => b.start), [DateTime(2026, 9), DateTime(2026, 10)]);
    });

    test('opens at its first day\'s open and closes at its last day\'s close', () {
      expect(bars.last.open, 100.5);
      expect(bars.last.close, 104);
      expect(bars.last.end, DateTime(2026, 10, 6));
    });

    test('takes the highest high and the lowest low of its days', () {
      expect(bars.last.high, 112);
      expect(bars.last.low, 99);
      expect(bars.last.hasExtremes, isTrue);
    });

    test('averages and takes the median of its daily closes', () {
      expect(bars.last.mean, closeTo((102 + 110 + 106 + 104) / 4, 1e-9));
      expect(bars.last.median, 105);
      expect(bars.first.median, 99, reason: 'two closes: halfway between them');
    });

    test('changes from the close of the month before, and the first has no change', () {
      expect(bars.first.previousClose, isNull);
      expect(bars.first.change, isNull);
      expect(bars.last.change, closeTo(104 / 100 - 1, 1e-9));
    });

    test('a year takes them all', () {
      final year = PriceBars.build(points, BarPeriod.year, now: now).single;
      expect(year.start, DateTime(2026));
      expect(year.open, 97);
      expect(year.close, 104);
      expect(year.high, 112);
      expect(year.low, 96);
      expect(year.median, 103);
    });
  });

  group('a day', () {
    test('older than the intraday window has no average or median', () {
      final bar = PriceBars.build([day(DateTime(2026, 11, 20, 14), 50, open: 49, high: 52, low: 48)], BarPeriod.day, now: now).single;
      expect(bar.open, 49);
      expect(bar.high, 52);
      expect(bar.mean, isNull);
      expect(bar.median, isNull);
    });

    test('known from one closing price has no open and no extremes of its own', () {
      final bar = PriceBars.build([day(DateTime(2026, 11, 20), 3.75)], BarPeriod.day, now: now).single;
      expect(bar.open, isNull);
      expect(bar.hasExtremes, isFalse);
      expect(bar.high, 3.75);
      expect(bar.low, 3.75);
    });

    test('inside the window is measured over one price per quarter hour', () {
      final start = DateTime(2026, 11, 26, 9);
      final points = [
        day(start, 10, open: 9, high: 11, low: 8),
        // Three live quotes in one quarter hour count once, as the last.
        day(start.add(const Duration(minutes: 15)), 50),
        day(start.add(const Duration(minutes: 16)), 60),
        day(start.add(const Duration(minutes: 17)), 20),
        day(start.add(const Duration(minutes: 30)), 30),
        day(start.add(const Duration(minutes: 45)), 40),
      ];
      final bar = PriceBars.build(points, BarPeriod.day, now: now).single;
      expect(bar.open, 9);
      expect(bar.close, 40);
      expect(bar.high, 60);
      expect(bar.low, 8);
      expect(bar.mean, closeTo((10 + 20 + 30 + 40) / 4, 1e-9));
      expect(bar.median, 25);
    });

    test('with too few prices yet is not measured', () {
      final start = DateTime(2026, 11, 26, 9);
      final points = [for (var i = 0; i < PriceBars.minDaySlots - 1; i++) day(start.add(Duration(minutes: 15 * i)), 10.0 + i)];
      expect(PriceBars.build(points, BarPeriod.day, now: now).single.mean, isNull);
    });

    test('with no open from the feed opens at its first price', () {
      final start = DateTime(2026, 11, 26, 9);
      final bar = PriceBars.build([day(start, 10), day(start.add(const Duration(hours: 1)), 12)], BarPeriod.day, now: now).single;
      expect(bar.open, 10);
    });

    test('yesterday is inside the window and the day before is not', () {
      List<DisplayPoint> quarterHours(DateTime start) => [for (var i = 0; i < 8; i++) day(start.add(Duration(minutes: 15 * i)), 10.0 + i)];
      final bars = PriceBars.build(
        [...quarterHours(DateTime(2026, 11, 24, 9)), ...quarterHours(DateTime(2026, 11, 25, 9))],
        BarPeriod.day,
        now: now,
      );
      expect(bars.first.mean, isNull);
      expect(bars.last.mean, isNotNull);
    });
  });

  group('periods', () {
    test('a week starts on Monday', () {
      expect(BarPeriod.week.startOf(DateTime(2026, 11, 26, 15)), DateTime(2026, 11, 23));
      expect(BarPeriod.week.startOf(DateTime(2026, 11, 1, 8)), DateTime(2026, 10, 26), reason: 'a Sunday belongs to the week before');
    });

    test('a half hour starts on the hour or at half past', () {
      expect(BarPeriod.halfHour.startOf(DateTime(2026, 11, 26, 15, 44, 12)), DateTime(2026, 11, 26, 15, 30));
    });

    test('a half-hour bar is never measured', () {
      final start = DateTime(2026, 11, 26, 9);
      final bar = PriceBars.build([for (var i = 0; i < 20; i++) day(start.add(Duration(minutes: i)), 10.0 + i)], BarPeriod.halfHour, now: now).single;
      expect(bar.mean, isNull);
      expect(bar.close, 29);
    });

    test('every chart range has a candle period, shorter than a day only on one day', () {
      for (final range in ChartRange.values) {
        final period = BarPeriod.forChart(range);
        expect(period == BarPeriod.halfHour, range == ChartRange.day1, reason: range.name);
      }
      expect(BarPeriod.forChart(ChartRange.month1), BarPeriod.day);
      expect(BarPeriod.forChart(ChartRange.year1), BarPeriod.week);
      expect(BarPeriod.forChart(ChartRange.all), BarPeriod.month);
    });
  });

  group('drawing as candles', () {
    test('needs bars with an open and a range of their own', () {
      final full = PriceBars.build(
        [for (var i = 0; i < 5; i++) day(DateTime(2026, 11, 2 + i), 10.0 + i, open: 9.0 + i, high: 12.0 + i, low: 8.0 + i)],
        BarPeriod.day,
        now: now,
      );
      final closesOnly = PriceBars.build([for (var i = 0; i < 5; i++) day(DateTime(2026, 11, 2 + i), 10.0 + i)], BarPeriod.day, now: now);
      expect(PriceBars.drawable(full), isTrue);
      expect(PriceBars.drawable(closesOnly), isFalse);
      expect(PriceBars.drawable(full.take(1).toList()), isFalse);
    });

    test('a bar with no open starts its body at the close before', () {
      final bars = PriceBars.build([day(DateTime(2026, 11, 2), 10), day(DateTime(2026, 11, 3), 12)], BarPeriod.day, now: now);
      expect(bars.last.bodyOpen, 10);
      expect(bars.last.closedUp, isTrue);
      expect(bars.first.bodyOpen, 10, reason: 'nothing before it: its own close');
    });

    test('a bar becomes one chart sample dated at its last price', () {
      final bar = PriceBars.build(
        [day(DateTime(2026, 11, 2, 10), 10, open: 9, high: 12, low: 8), day(DateTime(2026, 11, 2, 16), 11)],
        BarPeriod.day,
        now: DateTime(2026, 11, 2, 17),
      ).single;
      expect(bar.toPoint(), DisplayPoint(date: DateTime(2026, 11, 2, 16), value: 11, open: 9, high: 12, low: 8));
    });
  });

  group('a market with opening hours', () {
    // Thanksgiving: New York is closed all day.
    final holiday = DateTime.utc(2026, 11, 26, 13);
    final wednesdayOpen = DateTime.utc(2026, 11, 25, 14, 30);
    final wednesday = BarPeriod.day.startOf(wednesdayOpen);

    /// Wednesday's session in quarter hours, rising by 1 from 100.
    final session = [
      for (var i = 0; i < 26; i++)
        DisplayPoint(date: wednesdayOpen.add(Duration(minutes: 15 * i)), value: 100.0 + i, open: 99.5 + i, high: 101.0 + i, low: 99.0 + i),
    ];

    test('a price fetched while it is closed counts towards the day it last traded', () {
      final points = [
        ...session,
        // The closing bar and two quotes on the holiday repeat the close.
        DisplayPoint(date: DateTime.utc(2026, 11, 25, 21), value: 125),
        DisplayPoint(date: DateTime.utc(2026, 11, 26, 9), value: 125),
        DisplayPoint(date: DateTime.utc(2026, 11, 26, 12), value: 125),
      ];

      final bar = PriceBars.build(points, BarPeriod.day, now: holiday, market: Market.us).single;

      expect(bar.start, wednesday);
      expect(bar.open, 99.5);
      expect(bar.close, 125);
      // The session's 26 quarter hours and its closing bar; not the holiday's repeats.
      expect(bar.mean, closeTo((2925 + 125) / 27, 1e-9));
      expect(PriceBars.build(points, BarPeriod.day, now: holiday).length, greaterThan(1), reason: 'without the market, the holiday is a day');
    });

    test('a session is one day wherever midnight falls on this device', () {
      final bars = PriceBars.build(session, BarPeriod.day, now: holiday, market: Market.us);
      expect(bars.single.start, wednesday);
    });

    test('half-hour candles keep their own times', () {
      final bars = PriceBars.build(session, BarPeriod.halfHour, now: holiday, market: Market.us);
      expect(bars, hasLength(13));
    });

    test('a weekend quote for a metal counts towards the day it closed on', () {
      // Metals close on Friday at 17:00 New York time, 22:00 UTC, and open
      // again late on Sunday.
      final sunday = DateTime.utc(2026, 11, 22, 12);
      final close = DateTime.utc(2026, 11, 20, 22);
      // Where that close falls in the small hours, it is the end of Friday.
      var closedOn = BarPeriod.day.startOf(close.subtract(const Duration(minutes: 1)));
      if (close.difference(closedOn) < const Duration(hours: 8)) closedOn = DateTime(closedOn.year, closedOn.month, closedOn.day - 1);
      final bars = PriceBars.build(
        [
          DisplayPoint(date: DateTime.utc(2026, 11, 20, 21, 30), value: 4000),
          DisplayPoint(date: DateTime.utc(2026, 11, 21, 12), value: 4001),
          DisplayPoint(date: DateTime.utc(2026, 11, 22, 10), value: 4002),
        ],
        BarPeriod.day,
        now: sunday,
        market: Market.metals,
      );
      expect(bars.single.start, closedOn);
      expect(bars.single.close, 4002);
    });

    test('a metal trading around the clock keeps calendar days', () {
      final now = DateTime.utc(2026, 11, 19, 12);
      final bars = PriceBars.build(
        [
          DisplayPoint(date: DateTime(2026, 11, 17, 12), value: 4000),
          DisplayPoint(date: DateTime(2026, 11, 18, 12), value: 4010),
        ],
        BarPeriod.day,
        now: now,
        market: Market.metals,
      );
      expect(bars.map((b) => b.start), [DateTime(2026, 11, 17), DateTime(2026, 11, 18)]);
    });

    test('the last hours of a week past midnight are the end of the day before, in old history too', () {
      // Metals closed on Friday 13 November 2026 at 17:00 New York time,
      // 22:00 UTC. A day before that close, and half an hour before it.
      final close = DateTime.utc(2026, 11, 13, 22);
      final before = close.subtract(const Duration(hours: 24, minutes: 30));
      final last = close.subtract(const Duration(minutes: 30));
      final lastDay = BarPeriod.day.startOf(last);
      final folds = lastDay != BarPeriod.day.startOf(before) && close.difference(lastDay) < const Duration(hours: 8);

      final bars = PriceBars.build(
        [DisplayPoint(date: before, value: 4000), DisplayPoint(date: last, value: 4010)],
        BarPeriod.day,
        now: holiday,
        market: Market.metals,
      );

      expect(bars, hasLength(folds ? 1 : 2));
      expect(bars.last.close, 4010);
      if (folds) expect(bars.single.start, BarPeriod.day.startOf(before));
    });

    test('the first hours of a week before midnight are the start of the day after', () {
      // Metals opened on Sunday 15 November 2026 at 18:00 New York time,
      // 23:00 UTC.
      final open = DateTime.utc(2026, 11, 15, 23);
      final first = open.add(const Duration(minutes: 30));
      final after = open.add(const Duration(hours: 24, minutes: 30));
      final firstDay = BarPeriod.day.startOf(first);
      final nextDay = DateTime(firstDay.year, firstDay.month, firstDay.day + 1);
      final folds = nextDay.difference(open) < const Duration(hours: 8);

      final bars = PriceBars.build(
        [DisplayPoint(date: first, value: 4000), DisplayPoint(date: after, value: 4010)],
        BarPeriod.day,
        now: holiday,
        market: Market.metals,
      );

      expect(bars.first.start, folds ? nextDay : firstDay);
      expect(bars.last.close, 4010);
    });

    test('a market that never closes keeps calendar days', () {
      final points = [DisplayPoint(date: DateTime(2026, 11, 21, 0, 30), value: 1), DisplayPoint(date: DateTime(2026, 11, 20, 23, 30).add(const Duration(days: 1)), value: 2)];
      expect(PriceBars.build(points, BarPeriod.day, now: holiday, market: Market.always).single.start, DateTime(2026, 11, 21));
    });

    test('history older than the last week is left on its own dates', () {
      final old = [DisplayPoint(date: DateTime(2026, 7, 4, 12), value: 10), DisplayPoint(date: DateTime(2026, 7, 5, 12), value: 11)];
      expect(PriceBars.build(old, BarPeriod.day, now: holiday, market: Market.us), hasLength(2));
    });
  });
}
