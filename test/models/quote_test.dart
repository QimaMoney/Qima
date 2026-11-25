import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/quote.dart';

void main() {
  group('QuoteSeries.appending per-minute dedup (spec §8.5 / TC-Q4)', () {
    test('two quotes 30 seconds apart in the same minute collapse, newest wins', () {
      var series = QuoteSeries.empty('metal.XAU');
      final base = DateTime(2024, 1, 1, 12, 30, 0);
      series = series.appending(Quote(instrumentID: 'metal.XAU', timestamp: base, canonicalUSD: 100));
      series = series.appending(
        Quote(instrumentID: 'metal.XAU', timestamp: base.add(const Duration(seconds: 30)), canonicalUSD: 101),
      );
      expect(series.quotes.length, 1);
      expect(series.quotes.single.canonicalUSD, 101);
    });

    test('quotes in different minutes are both kept', () {
      var series = QuoteSeries.empty('metal.XAU');
      final base = DateTime(2024, 1, 1, 12, 30, 0);
      series = series.appending(Quote(instrumentID: 'metal.XAU', timestamp: base, canonicalUSD: 100));
      series = series.appending(
        Quote(instrumentID: 'metal.XAU', timestamp: base.add(const Duration(minutes: 1)), canonicalUSD: 101),
      );
      expect(series.quotes.length, 2);
    });
  });

  group('QuoteSeries.appending daily collapse (long-history survival)', () {
    test('minute-resolution samples older than 2 days collapse to one per day as new quotes arrive', () {
      // Simulate 3 days of one-minute-resolution foreground refreshes.
      var series = QuoteSeries.empty('metal.XAU');
      final start = DateTime(2024, 1, 1, 0, 0, 0);
      var t = start;
      for (var i = 0; i < 3 * 24 * 60; i++) {
        series = series.appending(Quote(instrumentID: 'metal.XAU', timestamp: t, canonicalUSD: 100 + i.toDouble()));
        t = t.add(const Duration(minutes: 1));
      }
      // The most recent 2 days stay at one-minute resolution; everything
      // before that collapses to (at most) one point per calendar day.
      final now = series.quotes.last.timestamp;
      final intradayCutoff = now.subtract(const Duration(days: 2));
      final old = series.quotes.where((q) => q.timestamp.isBefore(intradayCutoff)).toList();
      final recent = series.quotes.where((q) => !q.timestamp.isBefore(intradayCutoff)).toList();
      expect(old.length, lessThanOrEqualTo(2)); // at most the leading partial + one full day.
      expect(recent.length, greaterThan(60)); // still minute-resolution.
    });

    test('a 5Y-old quote survives many days of intermittent one-minute foreground refreshes', () {
      // Simulates the actual failure mode the spec describes: the app is
      // opened in the foreground for a while (60s refresh cadence) on each
      // of many separate days, well within the 2000-sample cap for any one
      // day, but enough elapsed real time that pre-fix behaviour (a flat
      // recency cap with no collapsing) would have pushed 5-year-old daily
      // history out entirely.
      var series = QuoteSeries(
        instrumentID: 'metal.XAU',
        quotes: [Quote(instrumentID: 'metal.XAU', timestamp: DateTime(2019, 1, 1), canonicalUSD: 50)],
      );
      var day = DateTime(2024, 1, 1);
      for (var d = 0; d < 200; d++) {
        // 30 minutes of one-minute-resolution refreshes per day.
        var t = day;
        for (var m = 0; m < 30; m++) {
          series = series.appending(Quote(instrumentID: 'metal.XAU', timestamp: t, canonicalUSD: 100 + m.toDouble()));
          t = t.add(const Duration(minutes: 1));
        }
        day = day.add(const Duration(days: 1));
      }
      expect(series.quotes.length, lessThanOrEqualTo(2000));
      expect(series.quotes.any((q) => q.timestamp.year == 2019), isTrue);
    });

    test('a same-day tie keeps the newer sample (greater timestamp wins)', () {
      final now = DateTime(2024, 6, 10);
      final day = DateTime(2024, 1, 1);
      // An earlier day holds the series' start, which keeps its own first
      // sample; the day under test is a later one.
      var series = QuoteSeries(
        instrumentID: 'metal.XAU',
        quotes: [
          Quote(instrumentID: 'metal.XAU', timestamp: DateTime(2023, 12, 1), canonicalUSD: 90),
          Quote(instrumentID: 'metal.XAU', timestamp: day.add(const Duration(hours: 1)), canonicalUSD: 100),
        ],
      );
      series = series.appending(
        Quote(instrumentID: 'metal.XAU', timestamp: day.add(const Duration(hours: 20)), canonicalUSD: 110),
        now: now,
      );
      final dayQuotes = series.quotes.where((q) => q.timestamp.year == 2024 && q.timestamp.month == 1 && q.timestamp.day == 1);
      expect(dayQuotes.length, 1);
      expect(dayQuotes.single.canonicalUSD, 110);
    });

    test('an empty series collapses to just the new quote', () {
      final series = QuoteSeries.empty('metal.XAU').appending(
        Quote(instrumentID: 'metal.XAU', timestamp: DateTime(2024, 1, 1), canonicalUSD: 42),
      );
      expect(series.quotes.length, 1);
      expect(series.quotes.single.canonicalUSD, 42);
    });
  });

  group('QuoteSeries.merging backfill keying (spec §8.5 / TC-Q6)', () {
    test('samples within 2 days of now key per-minute; ties keep greatest timestamp', () {
      final now = DateTime(2024, 6, 1, 12, 0, 0);
      final minute = DateTime(2024, 6, 1, 10, 15, 0);
      final existing = QuoteSeries(
        instrumentID: 'metal.XAU',
        quotes: [Quote(instrumentID: 'metal.XAU', timestamp: minute, canonicalUSD: 100)],
      );
      final merged = existing.merging(
        [Quote(instrumentID: 'metal.XAU', timestamp: minute.add(const Duration(seconds: 10)), canonicalUSD: 105)],
        now,
      );
      expect(merged.quotes.length, 1);
      expect(merged.quotes.single.canonicalUSD, 105);
    });

    test('samples older than 2 days collapse to one per calendar day', () {
      final now = DateTime(2024, 6, 10);
      final day = DateTime(2024, 1, 1);
      // The earliest day also keeps its first sample, so the day under test
      // is a later one.
      final existing = QuoteSeries(
        instrumentID: 'metal.XAU',
        quotes: [
          Quote(instrumentID: 'metal.XAU', timestamp: DateTime(2023, 12, 1), canonicalUSD: 90),
          Quote(instrumentID: 'metal.XAU', timestamp: day.add(const Duration(hours: 1)), canonicalUSD: 100),
        ],
      );
      final merged = existing.merging(
        [Quote(instrumentID: 'metal.XAU', timestamp: day.add(const Duration(hours: 20)), canonicalUSD: 110)],
        now,
      );
      expect(merged.quotes.length, 2);
      expect(merged.quotes.last.canonicalUSD, 110);
    });
  });

  group('QuoteSeries.merging replacing a span', () {
    test('a re-fetched sample replaces the stored copy at the same time', () {
      final now = DateTime(2024, 6, 10);
      final day = DateTime(2024, 1, 1, 5);
      final existing = QuoteSeries(instrumentID: 'metal.XAU', quotes: [Quote(instrumentID: 'metal.XAU', timestamp: day, canonicalUSD: 100)]);
      final merged = existing.merging([Quote(instrumentID: 'metal.XAU', timestamp: day, canonicalUSD: 120)], now);
      expect(merged.quotes.single.canonicalUSD, 120);
    });

    test('drops every stored sample inside the span, and keeps those outside it', () {
      final now = DateTime(2024, 6, 10, 12);
      Quote at(int hour, int minute, double value) =>
          Quote(instrumentID: 'metal.XAU', timestamp: DateTime(2024, 6, 10, hour, minute), canonicalUSD: value);
      final existing = QuoteSeries(instrumentID: 'metal.XAU', quotes: [at(8, 59, 1), at(9, 7, 2), at(9, 22, 3), at(11, 40, 4)]);
      final merged = existing.merging(
        [at(9, 0, 10), at(9, 15, 11), at(9, 30, 12)],
        now,
        replacing: (from: DateTime(2024, 6, 10, 9), to: DateTime(2024, 6, 10, 9, 30)),
      );
      expect(merged.quotes.map((q) => q.canonicalUSD), [1, 10, 11, 12, 4]);
    });
  });

  group('Quote JSON', () {
    test('a file written before extremes existed still reads, with none', () {
      final quote = Quote.fromJson({
        'instrumentID': 'stock.ZZTEST',
        'timestamp': '2024-03-05T09:00:00.000Z',
        'canonicalUSD': 12.5,
      });
      expect(quote.canonicalUSD, 12.5);
      expect(quote.high, isNull);
      expect(quote.low, isNull);
    });

    test('a quote with extremes round-trips', () {
      final quote = Quote(
        instrumentID: 'stock.ZZTEST',
        timestamp: DateTime.utc(2024, 3, 5, 9),
        canonicalUSD: 12.5,
        high: 20,
        low: 11.25,
      );
      expect(Quote.fromJson(quote.toJson()), quote);
    });

    test('a quote without extremes writes no extreme keys', () {
      final json = Quote(instrumentID: 'stock.ZZTEST', timestamp: DateTime.utc(2024, 3, 5, 9), canonicalUSD: 12.5).toJson();
      expect(json.keys, ['instrumentID', 'timestamp', 'canonicalUSD']);
    });

    test('extremes take part in equality', () {
      final a = Quote(instrumentID: 'x', timestamp: DateTime.utc(2024), canonicalUSD: 1, high: 2, low: 0);
      final b = Quote(instrumentID: 'x', timestamp: DateTime.utc(2024), canonicalUSD: 1);
      expect(a, isNot(b));
    });
  });

  group('older days keep the extremes and the start of the series', () {
    const id = 'stock.ZZTEST';
    final now = DateTime(2024, 3, 10, 12);
    final earlierDay = DateTime(2024, 3, 1, 9);
    final day = DateTime(2024, 3, 5);

    Quote bar(DateTime at, double close, {double? high, double? low}) =>
        Quote(instrumentID: id, timestamp: at, canonicalUSD: close, high: high, low: low);

    /// One day of 15 minute bars: a reference price first, then trading.
    List<Quote> trading() => [
          bar(day.add(const Duration(hours: 9)), 10, high: 10, low: 10),
          bar(day.add(const Duration(hours: 11, minutes: 15)), 18, high: 25, low: 14),
          bar(day.add(const Duration(hours: 13)), 12, high: 19, low: 9),
          bar(day.add(const Duration(hours: 16)), 15, high: 16, low: 12),
        ];

    // An earlier single-sample day, so [day] is not the earliest one.
    Quote before() => bar(earlierDay, 8);

    test('a day older than the window becomes one sample with the true high and low', () {
      final series = QuoteSeries(instrumentID: id, quotes: [before()]).merging(trading(), now);

      final kept = series.quotes.where((q) => q.timestamp.isAfter(earlierDay)).toList();
      expect(kept, hasLength(1));
      expect(kept.single.timestamp, day.add(const Duration(hours: 16)));
      expect(kept.single.canonicalUSD, 15, reason: 'the same sample as before extremes existed');
      expect(kept.single.high, 25);
      expect(kept.single.low, 9);
    });

    test('a sample without extremes counts by its price', () {
      final series = QuoteSeries(instrumentID: id, quotes: [before()]).merging([
        bar(day.add(const Duration(hours: 10)), 30),
        bar(day.add(const Duration(hours: 12)), 5),
        bar(day.add(const Duration(hours: 15)), 20),
      ], now);

      final kept = series.quotes.last;
      expect(kept.canonicalUSD, 20);
      expect(kept.high, 30);
      expect(kept.low, 5);
    });

    test('a day of one sample is left exactly as stored', () {
      final single = bar(day.add(const Duration(hours: 16)), 15);
      final series = QuoteSeries(instrumentID: id, quotes: [before()]).merging([single], now);
      expect(series.quotes.last, same(single));
    });

    test('a mis-dated daily bar loses as the price but widens the range', () {
      var series = QuoteSeries(instrumentID: id, quotes: [before()]).merging(trading(), now);
      // Stamped at the open, carrying the day close with the day high and low.
      final daily = bar(day.add(const Duration(hours: 8)), 14, high: 30, low: 7);
      series = series.merging([daily], now);

      final kept = series.quotes.last;
      expect(kept.timestamp, day.add(const Duration(hours: 16)));
      expect(kept.canonicalUSD, 15);
      expect(kept.high, 30);
      expect(kept.low, 7);
    });

    test('merging the same bars again changes nothing', () {
      final once = QuoteSeries(instrumentID: id, quotes: [before()]).merging(trading(), now);
      expect(once.merging(trading(), now), once);
    });

    test('the earliest day also keeps its first sample', () {
      final series = QuoteSeries.empty(id).merging(trading(), now);

      expect(series.quotes, hasLength(2));
      expect(series.quotes.first.timestamp, day.add(const Duration(hours: 9)));
      expect(series.quotes.first.canonicalUSD, 10, reason: 'the price the listing started at');
      expect(series.quotes.last.canonicalUSD, 15);
      expect(series.quotes.last.high, 25);
      expect(series.quotes.last.low, 9);
    });

    test('an earliest day with one sample gains nothing', () {
      final series = QuoteSeries(instrumentID: id, quotes: [before()]).merging(trading(), now);
      expect(series.quotes.first, before());
    });

    test('a backfill in front drops the extra first sample of the former first day', () {
      var series = QuoteSeries.empty(id).merging(trading(), now);
      expect(series.quotes, hasLength(2));

      series = series.merging([before()], now);

      expect(series.quotes.map((q) => q.timestamp), [earlierDay, day.add(const Duration(hours: 16))]);
      expect(series.quotes.last.high, 25, reason: 'its extremes survive the collapse');
      expect(series.quotes.last.low, 9);
    });

    test('a live quote appended later keeps the start and the extremes', () {
      var series = QuoteSeries.empty(id).merging(trading(), now);
      series = series.appending(bar(now, 16), now: now);

      expect(series.quotes.map((q) => q.canonicalUSD), [10, 15, 16]);
      expect(series.quotes[1].high, 25);
      expect(series.quotes[1].low, 9);
    });

    test('samples dropped by replacing do not contribute extremes', () {
      var series = QuoteSeries(instrumentID: id, quotes: [before()]).merging(trading(), now);
      // The stored day sample (16:00, high 25, low 9) lies in the replaced
      // span, so only the new bars speak for the day.
      series = series.merging(
        [
          bar(day.add(const Duration(hours: 10)), 11, high: 12, low: 10),
          bar(day.add(const Duration(hours: 17)), 13, high: 14, low: 11),
        ],
        now,
        replacing: (from: day.add(const Duration(hours: 9)), to: day.add(const Duration(hours: 17))),
      );

      final kept = series.quotes.last;
      expect(kept.canonicalUSD, 13);
      expect(kept.high, 14);
      expect(kept.low, 10);
    });

    test('samples inside the window keep their minute and their own extremes', () {
      final recent = bar(now.subtract(const Duration(hours: 3)), 9, high: 11, low: 8);
      final series = QuoteSeries(instrumentID: id, quotes: [before()]).merging([recent], now);
      expect(series.quotes.last, same(recent));
    });
  });
}
