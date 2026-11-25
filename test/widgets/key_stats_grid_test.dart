import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qima/l10n/app_localizations.dart';
import 'package:qima/models/display_point.dart';
import 'package:qima/theme/app_theme.dart';
import 'package:qima/widgets/key_stats_grid.dart';

Widget _app(List<DisplayPoint> points) => MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: KeyStatsGrid(windowed: points, changePercent: 0.123, changeIsUp: true, currencyCode: 'USD')),
    );

void main() {
  testWidgets('High and Low come from the extremes the samples carry', (tester) async {
    await tester.pumpWidget(_app([
      DisplayPoint(date: DateTime(2024, 3, 5, 9), value: 10),
      DisplayPoint(date: DateTime(2024, 3, 5, 16), value: 15, high: 25.5, low: 9.25),
      DisplayPoint(date: DateTime(2024, 3, 10, 12), value: 16),
    ]));

    expect(find.textContaining('25.50'), findsOneWidget);
    expect(find.textContaining('9.25'), findsOneWidget);
  });

  testWidgets('samples without extremes give the highest and lowest value, as before', (tester) async {
    await tester.pumpWidget(_app([
      DisplayPoint(date: DateTime(2024, 3, 5), value: 10),
      DisplayPoint(date: DateTime(2024, 3, 6), value: 15),
      DisplayPoint(date: DateTime(2024, 3, 7), value: 12),
    ]));

    expect(find.textContaining('15.00'), findsOneWidget);
    expect(find.textContaining('10.00'), findsOneWidget);
  });

  testWidgets('no samples show dashes', (tester) async {
    await tester.pumpWidget(_app(const []));
    expect(find.textContaining('—'), findsNWidgets(2));
  });
}
