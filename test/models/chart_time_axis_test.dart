import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/chart_time_axis.dart';
import 'package:qima/models/display_point.dart';
import 'package:qima/models/market_hours.dart';

DisplayPoint _p(DateTime date, [double value = 1]) => DisplayPoint(date: date, value: value);

void main() {
  group('MarketHours.openSpans', () {
    test('a US weekday is one session, 09:30 to 16:00 New York time', () {
      final spans = MarketHours.openSpans(Market.us, DateTime.utc(2026, 11, 23), DateTime.utc(2026, 11, 24));
      expect(spans, [(DateTime.utc(2026, 11, 23, 14, 30), DateTime.utc(2026, 11, 23, 21))]);
    });

    test('spans are clipped to the window asked for', () {
      final spans = MarketHours.openSpans(Market.us, DateTime.utc(2026, 11, 23, 16), DateTime.utc(2026, 11, 23, 17));
      expect(spans, [(DateTime.utc(2026, 11, 23, 16), DateTime.utc(2026, 11, 23, 17))]);
    });

    test('a weekend has no US session, and crypto never closes', () {
      final from = DateTime.utc(2026, 11, 21), to = DateTime.utc(2026, 11, 23);
      expect(MarketHours.openSpans(Market.us, from, to), isEmpty);
      expect(MarketHours.openSpans(Market.always, from, to), [(from, to)]);
    });
  });

  group('ChartTimeAxis', () {
    test('without a market, positions are plain elapsed seconds', () {
      final start = DateTime.utc(2026, 11, 20);
      final axis = ChartTimeAxis.build([
        _p(start),
        _p(start.add(const Duration(hours: 1))),
        _p(start.add(const Duration(days: 3))),
      ]);
      expect(axis.positions, [0, 3600, 3 * 86400]);
    });

    test('a weekend takes almost no room on a US stock', () {
      // 15:00 New York time on Thursday, Friday and the next Monday.
      final axis = ChartTimeAxis.build([
        _p(DateTime.utc(2026, 11, 19, 20)),
        _p(DateTime.utc(2026, 11, 20, 20)),
        _p(DateTime.utc(2026, 11, 23, 20)),
      ], market: Market.us);
      const hour = 3600.0;
      final overnight = axis.positions[1] - axis.positions[0];
      final weekend = axis.positions[2] - axis.positions[1];
      // 6.5 open hours each time; 17.5 and 65.5 closed hours at 2%.
      expect(overnight, closeTo((6.5 + 17.5 * ChartTimeAxis.closedWeight) * hour, 1));
      expect(weekend, closeTo((6.5 + 65.5 * ChartTimeAxis.closedWeight) * hour, 1));
      expect(weekend / overnight, lessThan(1.2));
    });

    test('positions never step back, even for equal or out-of-order stamps', () {
      final t = DateTime.utc(2026, 11, 23, 15);
      final axis = ChartTimeAxis.build([
        _p(t),
        _p(t),
        _p(t.subtract(const Duration(minutes: 5))),
        _p(t.add(const Duration(hours: 1))),
      ], market: Market.us);
      for (var i = 1; i < axis.positions.length; i++) {
        expect(axis.positions[i], greaterThanOrEqualTo(axis.positions[i - 1]));
      }
    });

    test('dateAt undoes positionOf, and nearestIndex picks the closer sample', () {
      final start = DateTime.utc(2026, 11, 23, 15);
      final axis = ChartTimeAxis.build([
        for (var i = 0; i < 5; i++) _p(start.add(Duration(minutes: 30 * i))),
      ], market: Market.us);
      final middle = start.add(const Duration(minutes: 45));
      expect(axis.dateAt(axis.positionOf(middle)).isAtSameMomentAs(middle), isTrue);
      expect(axis.nearestIndex(axis.positionOf(start.add(const Duration(minutes: 40)))), 1);
      expect(axis.nearestIndex(axis.positionOf(start.add(const Duration(minutes: 50)))), 2);
      expect(axis.nearestIndex(-10), 0);
      expect(axis.nearestIndex(axis.length + 10), 4);
    });
  });
}
