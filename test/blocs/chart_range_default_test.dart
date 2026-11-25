import 'package:flutter_test/flutter_test.dart';
import 'package:qima/blocs/app_blocs.dart';
import 'package:qima/models/chart_range.dart';
import 'package:qima/services/preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the default chart range', () {
    test('a new install opens charts on one day, on an asset and on Home', () async {
      SharedPreferences.setMockInitialValues({});
      final blocs = AppBlocs();
      await blocs.settings.load(await Preferences.create());
      expect(blocs.settings.state.preferredChartRange, ChartRange.day1);
      expect(blocs.settings.state.preferredPortfolioRange, ChartRange.day1);
    });

    test('Home follows the default in Settings, the moment it changes and after a restart', () async {
      SharedPreferences.setMockInitialValues({});
      final blocs = AppBlocs();
      await blocs.settings.load(await Preferences.create());
      await blocs.settings.setPreferredChartRange(ChartRange.month3);
      expect(blocs.settings.state.preferredPortfolioRange, ChartRange.month3);
      await blocs.settings.setPreferredChartRange(ChartRange.ytd);
      expect(blocs.settings.state.preferredPortfolioRange, ChartRange.year1);

      final again = AppBlocs();
      await again.settings.load(await Preferences.create());
      expect(again.settings.state.preferredChartRange, ChartRange.ytd);
      expect(again.settings.state.preferredPortfolioRange, ChartRange.year1);
    });

    test('a range picked on Home holds until the app is closed, and never changes the default', () async {
      SharedPreferences.setMockInitialValues({});
      final blocs = AppBlocs();
      await blocs.settings.load(await Preferences.create());
      await blocs.settings.setPreferredPortfolioRange(ChartRange.all);
      expect(blocs.settings.state.preferredPortfolioRange, ChartRange.all);
      expect(blocs.settings.state.preferredChartRange, ChartRange.day1);

      final again = AppBlocs();
      await again.settings.load(await Preferences.create());
      expect(again.settings.state.preferredPortfolioRange, ChartRange.day1);
    });

    test('a range Home remembered under an earlier build no longer overrides the default', () async {
      SharedPreferences.setMockInitialValues({'preferredPortfolioRange': 'all'});
      final blocs = AppBlocs();
      await blocs.settings.load(await Preferences.create());
      expect(blocs.settings.state.preferredPortfolioRange, ChartRange.day1);
    });
  });
}
