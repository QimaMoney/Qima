import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:qima/l10n/app_localizations.dart';
import 'package:qima/models/display_point.dart';
import 'package:qima/theme/app_theme.dart';
import 'package:qima/theme/price_chart.dart';

const double _width = 324;
const double _plotWidth = _width - 24; // the axis column on the right

final DateTime _start = DateTime(2026, 3, 1);

/// Thirty daily prices from 100, rising by 1 a day.
final List<DisplayPoint> _points = [
  for (var i = 0; i < 30; i++) DisplayPoint(date: _start.add(Duration(days: i)), value: 100.0 + i),
];

/// Text containing [s] once the direction isolates around figures are gone.
Finder _text(String s) => find.byWidgetPredicate(
      (w) => w is Text && (w.data ?? '').replaceAll(RegExp('[\u2066-\u2069]'), '').contains(s),
    );

double _xOf(int index) => index / (_points.length - 1) * _plotWidth;

Widget _app(Widget chart, {Locale locale = const Locale('en')}) => MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: Center(child: SizedBox(width: _width, height: 240, child: chart))),
    );

PriceChartView _chart({List<ChartMark> marks = const [], ChartCompare? compare, bool masked = false}) => PriceChartView(
      points: _points,
      isTrendingUp: true,
      accent: Colors.green,
      isInteractive: true,
      currencyCode: 'USD',
      marks: marks,
      compare: compare,
      maskValues: masked,
    );

void main() {
  setUpAll(() async {
    await initializeDateFormatting('ar');
    await initializeDateFormatting('fr');
  });

  test('axis and callout dates follow the locale, with Western digits', () {
    final date = DateTime(2026, 3, 5);
    final arabic = axisDateFormat(AxisGranularity.dayMonth, 'ar').format(date);
    expect(arabic, contains('مارس'));
    expect(arabic, contains('5'));
    expect(calloutDateFormat(AxisGranularity.dayMonth, 'fr').format(date), contains('mars'));
    expect(axisDateFormat(AxisGranularity.dayMonth, 'en').format(date), 'Mar 5');
  });

  testWidgets('scrubbing shows the change since the first price in view', (tester) async {
    await tester.pumpWidget(_app(_chart()));
    final origin = tester.getTopLeft(find.byType(PriceChartView));
    final gesture = await tester.startGesture(origin + Offset(_xOf(5), 120));
    await gesture.moveTo(origin + Offset(_xOf(10), 120));
    await tester.pump();

    // 110 against 100.
    expect(_text('+10%'), findsOneWidget);
    expect(_text('since'), findsOneWidget);
    await gesture.up();
    await tester.pump();
    expect(_text('since'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('resting on a transaction shows what the person did', (tester) async {
    final mark = ChartMark(date: _points[12].date, kind: ChartMarkKind.buy, label: 'Buy · 2 g');
    await tester.pumpWidget(_app(_chart(marks: [mark])));
    final origin = tester.getTopLeft(find.byType(PriceChartView));
    final gesture = await tester.startGesture(origin + Offset(_xOf(4), 120));
    await gesture.moveTo(origin + Offset(_xOf(12), 120));
    await tester.pump();
    expect(find.text('Buy · 2 g'), findsOneWidget);

    await gesture.moveTo(origin + Offset(_xOf(20), 120));
    await tester.pump();
    expect(find.text('Buy · 2 g'), findsNothing);
    await gesture.up();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('two fingers show the change between them', (tester) async {
    await tester.pumpWidget(_app(_chart()));
    final origin = tester.getTopLeft(find.byType(PriceChartView));
    final first = await tester.startGesture(origin + Offset(_xOf(0), 120));
    final second = await tester.startGesture(origin + Offset(_xOf(20), 120), pointer: 2);
    await tester.pump();

    // 100 to 120: +20.00 USD, +20%.
    expect(_text('+20%'), findsOneWidget);
    expect(_text(' – '), findsOneWidget);
    await second.up();
    await tester.pump();
    expect(_text(' – '), findsNothing);
    await first.up();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a hidden balance keeps the measured change but not the amount', (tester) async {
    await tester.pumpWidget(_app(_chart(masked: true)));
    final origin = tester.getTopLeft(find.byType(PriceChartView));
    // Hidden balances drop the axis column, so the plot is the full width.
    final first = await tester.startGesture(origin + const Offset(0, 120));
    final second = await tester.startGesture(origin + const Offset(20 / 29 * _width, 120), pointer: 2);
    await tester.pump();
    expect(_text('+20%'), findsOneWidget);
    expect(_text('USD'), findsNothing);
    expect(_text(r'$'), findsNothing);
    await second.up();
    await first.up();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a double-tap zooms in and the pill zooms back out', (tester) async {
    await tester.pumpWidget(_app(_chart()));
    final at = tester.getTopLeft(find.byType(PriceChartView)) + Offset(_xOf(15), 120);
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Reset zoom'), findsOneWidget);

    await tester.tap(find.text('Reset zoom'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Reset zoom'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the comparison shows its own change in the callout', (tester) async {
    final gold = ChartCompare(label: 'Gold', points: [
      for (var i = 0; i < 30; i++) DisplayPoint(date: _start.add(Duration(days: i)), value: 50.0 + i / 2),
    ]);
    await tester.pumpWidget(_app(_chart(compare: gold)));
    final origin = tester.getTopLeft(find.byType(PriceChartView));
    final gesture = await tester.startGesture(origin + Offset(_xOf(5), 120));
    await gesture.moveTo(origin + Offset(_xOf(10), 120));
    await tester.pump();
    // 55 against 50.
    expect(_text('Gold +10%'), findsOneWidget);
    await gesture.up();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a screen reader can step through the prices', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_app(_chart()));
    final node = tester.getSemantics(find.byType(PriceChartView));
    expect(node.getSemanticsData().hasAction(SemanticsAction.increase), isTrue);

    node.owner!.performAction(node.id, SemanticsAction.increase);
    await tester.pump();
    final value = tester.getSemantics(find.byType(PriceChartView)).getSemanticsData().value;
    expect(value, contains('2026'));
    expect(value, contains('100'));
    handle.dispose();
    await tester.pump(const Duration(seconds: 1));
  });
}
