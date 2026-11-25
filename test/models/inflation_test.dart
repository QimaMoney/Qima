import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/inflation.dart';

void main() {
  group('InflationPeriod', () {
    test('reads the feed\'s period names and writes them back', () {
      for (final key in ['2024', '2024-Q1', '2024-Q4', '2024-M01', '2024-M12']) {
        expect(InflationPeriod.tryParse(key)?.key, key);
      }
      expect(InflationPeriod.tryParse('2024-M01'), const InflationPeriod.month(2024, 1));
      expect(InflationPeriod.tryParse('2024-Q3'), const InflationPeriod.quarter(2024, 3));
      expect(InflationPeriod.tryParse('2024'), const InflationPeriod.year(2024));
    });

    test('refuses names that are not a real month, quarter or year', () {
      for (final key in ['', '24', '2024-M13', '2024-M00', '2024-Q5', '2024-W10', '2024-01', '2024-S1']) {
        expect(InflationPeriod.tryParse(key), isNull, reason: key);
      }
    });

    test('steps back across a year boundary', () {
      expect(const InflationPeriod.month(2024, 1).previous, const InflationPeriod.month(2023, 12));
      expect(const InflationPeriod.quarter(2024, 1).previous, const InflationPeriod.quarter(2023, 4));
      expect(const InflationPeriod.year(2024).previous, const InflationPeriod.year(2023));
      expect(const InflationPeriod.month(2024, 2).yearBefore, const InflationPeriod.month(2023, 2));
      expect(const InflationPeriod.quarter(2024, 3).yearBefore, const InflationPeriod.quarter(2023, 3));
      expect(const InflationPeriod.year(2024).yearBefore, const InflationPeriod.year(2023));
    });

    test('finds the period a date falls in', () {
      final date = DateTime(2024, 8, 17);
      expect(InflationPeriod.containing(InflationFrequency.monthly, date), const InflationPeriod.month(2024, 8));
      expect(InflationPeriod.containing(InflationFrequency.quarterly, date), const InflationPeriod.quarter(2024, 3));
      expect(InflationPeriod.containing(InflationFrequency.annual, date), const InflationPeriod.year(2024));
    });

    test('starts on the first day of its first month', () {
      expect(const InflationPeriod.month(2024, 8).start, DateTime.utc(2024, 8));
      expect(const InflationPeriod.quarter(2024, 3).start, DateTime.utc(2024, 7));
      expect(const InflationPeriod.year(2024).start, DateTime.utc(2024));
    });

    test('sorts oldest first', () {
      final periods = [
        const InflationPeriod.month(2024, 2),
        const InflationPeriod.month(2023, 12),
        const InflationPeriod.month(2024, 1),
      ]..sort();
      expect(periods.map((p) => p.key), ['2023-M12', '2024-M01', '2024-M02']);
    });
  });

  group('InflationSeries', () {
    final fetchedAt = DateTime.utc(2026, 11, 25);
    final series = InflationSeries(
      country: 'EGY',
      index: {
        InflationPeriod.month(2023, 9): 100,
        InflationPeriod.month(2023, 10): 102,
        InflationPeriod.month(2024, 9): 125,
        InflationPeriod.month(2024, 10): 127.5,
        InflationPeriod.quarter(2023, 3): 100,
        InflationPeriod.quarter(2024, 2): 118,
        InflationPeriod.quarter(2024, 3): 120,
        InflationPeriod.year(2023): 100,
        InflationPeriod.year(2024): 128,
      },
      annualRates: const {2022: 0.139, 2023: 0.339, 2024: 0.283},
      fetchedAt: fetchedAt,
    );

    test('gives the yearly rate for a month, a quarter and a year from the index', () {
      expect(series.rate(const InflationPeriod.month(2024, 10)), closeTo(0.25, 1e-9));
      expect(series.rate(const InflationPeriod.quarter(2024, 3)), closeTo(0.20, 1e-9));
      expect(series.rate(const InflationPeriod.year(2024)), closeTo(0.28, 1e-9));
    });

    test('gives the change from the period before', () {
      expect(series.changeFromPrevious(const InflationPeriod.month(2024, 10)), closeTo(0.02, 1e-9));
      expect(series.changeFromPrevious(const InflationPeriod.quarter(2024, 3)), closeTo(120 / 118 - 1, 1e-9));
    });

    test('gives the change between any two periods of one frequency', () {
      expect(series.change(const InflationPeriod.month(2023, 9), const InflationPeriod.month(2024, 10)), closeTo(0.275, 1e-9));
      expect(series.change(const InflationPeriod.month(2023, 9), const InflationPeriod.quarter(2024, 3)), isNull);
    });

    test('has no rate where a level is missing', () {
      expect(series.rate(const InflationPeriod.month(2024, 8)), isNull);
      expect(series.rate(const InflationPeriod.month(2023, 9)), isNull);
      expect(series.changeFromPrevious(const InflationPeriod.month(2024, 9)), isNull);
    });

    test('uses the yearly rates for the years the index does not reach', () {
      expect(series.rate(const InflationPeriod.year(2023)), 0.339);
      expect(series.rate(const InflationPeriod.year(2022)), 0.139);
      expect(series.rate(const InflationPeriod.year(2021)), isNull);
    });

    test('lists history oldest first, with only the periods that have a rate', () {
      expect(series.history(InflationFrequency.monthly).map((p) => p.period.key), ['2024-M09', '2024-M10']);
      expect(series.history(InflationFrequency.quarterly).map((p) => p.period.key), ['2024-Q3']);
      final years = series.history(InflationFrequency.annual);
      expect(years.map((p) => p.period.key), ['2022', '2023', '2024']);
      expect(years.last.rate, closeTo(0.28, 1e-9));
      expect(series.latest(InflationFrequency.monthly)?.period, const InflationPeriod.month(2024, 10));
    });

    test('names the shortest period a country publishes', () {
      expect(series.finestFrequency, InflationFrequency.monthly);
      final quarterly = InflationSeries(
        country: 'NZL',
        index: {InflationPeriod.quarter(2023, 3): 100, InflationPeriod.quarter(2024, 3): 102},
        fetchedAt: fetchedAt,
      );
      expect(quarterly.finestFrequency, InflationFrequency.quarterly);
      final yearly = InflationSeries(country: 'TWN', annualRates: const {2024: 0.02}, fetchedAt: fetchedAt);
      expect(yearly.finestFrequency, InflationFrequency.annual);
      expect(InflationSeries(country: 'XXX', fetchedAt: fetchedAt).finestFrequency, isNull);
    });

    test('never divides by a level of zero', () {
      final broken = InflationSeries(
        country: 'EGY',
        index: {InflationPeriod.month(2023, 1): 0, InflationPeriod.month(2024, 1): 110},
        fetchedAt: fetchedAt,
      );
      expect(broken.rate(const InflationPeriod.month(2024, 1)), isNull);
    });

    test('survives a round trip through JSON', () {
      expect(InflationSeries.fromJson('EGY', series.toJson()), series);
    });

    test('leaves out saved entries it cannot read and keeps the rest', () {
      final read = InflationSeries.fromJson('EGY', {
        'index': {'2024-M01': 110.5, '2024-M13': 1, 'soon': 2, '2024-M02': 'high'},
        'annualRates': {'2024': 0.28, 'last year': 0.3, '2023': null},
        'fetchedAt': '2026-11-25T00:00:00.000Z',
      });
      expect(read.index, {InflationPeriod.month(2024, 1): 110.5});
      expect(read.annualRates, const {2024: 0.28});
    });
  });
}
