import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/inflation.dart';
import 'package:qima/services/inflation_provider.dart';

// Asks the real feeds, to catch a change in what they send. Skipped unless
// QIMA_LIVE_INFLATION is set.
void main() {
  final skip = Platform.environment['QIMA_LIVE_INFLATION'] == null ? 'set QIMA_LIVE_INFLATION' : false;

  test('the IMF sends monthly, quarterly and yearly levels for Egypt', () async {
    final index = await ImfCpiProvider().index('EGY');
    for (final frequency in InflationFrequency.values) {
      expect(index.keys.where((period) => period.frequency == frequency).length, greaterThan(10), reason: frequency.name);
    }
    final series = InflationSeries(country: 'EGY', index: index, fetchedAt: DateTime.now());
    expect(series.latest(InflationFrequency.monthly)!.rate, inInclusiveRange(-0.5, 5));
  }, skip: skip);

  test('the IMF has only quarters and years for New Zealand, and nothing for Taiwan', () async {
    final newZealand = await ImfCpiProvider().index('NZL');
    expect(newZealand.keys.where((period) => period.frequency == InflationFrequency.quarterly), isNotEmpty);
    expect(newZealand.keys.where((period) => period.frequency == InflationFrequency.monthly), isEmpty);
    expect(await ImfCpiProvider().index('TWN'), isEmpty);
  }, skip: skip);

  test('the World Bank sends decades of yearly rates for Egypt, and nothing for an unknown code', () async {
    final rates = await WorldBankInflationProvider().annualRates('EGY');
    expect(rates.length, greaterThan(50));
    expect(rates[2024], closeTo(0.283, 0.01));
    expect(await WorldBankInflationProvider().annualRates('XXX'), isEmpty);
  }, skip: skip);
}
