import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qima/l10n/app_localizations.dart';
import 'package:qima/models/display_point.dart';
import 'package:qima/models/instrument_catalog.dart';
import 'package:qima/models/instrument_facts.dart';
import 'package:qima/widgets/instrument_facts_widgets.dart';
import 'package:qima/widgets/key_stats_grid.dart';
import 'package:qima/widgets/market_status.dart';

Widget _app(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  final apple = InstrumentCatalog.instrument('stock.AAPL')!;

  test('the exchange’s session wins over the built-in hours while current', () {
    // A Friday holiday: the built-in hours say open, the exchange says the
    // next session starts Monday.
    final now = DateTime.utc(2026, 11, 27, 16);
    final monday = (DateTime.utc(2026, 11, 30, 14, 30), DateTime.utc(2026, 11, 30, 21));
    expect(MarketStatusLine.statusFor(apple, now, monday)?.open, isFalse);
    expect(MarketStatusLine.statusFor(apple, now, monday)?.next, monday.$1);
    // A past session falls back to the built-in hours.
    final past = (DateTime.utc(2026, 11, 20, 14, 30), DateTime.utc(2026, 11, 20, 21));
    expect(MarketStatusLine.statusFor(apple, now, past), MarketStatusLine.statusFor(apple, now, null));
  });

  testWidgets('key stats show the previous close, yield and both ranges in the currency', (tester) async {
    final now = DateTime(2026, 11, 25);
    await tester.pumpWidget(_app(KeyStatsGrid(
      windowed: [DisplayPoint(date: now.subtract(const Duration(days: 1)), value: 98), DisplayPoint(date: now, value: 102)],
      changePercent: 0.02,
      changeIsUp: true,
      currencyCode: 'USD',
      previousClose: 99,
      dividendYield: 0.031,
      daySpan: const PriceSpan(low: 97, high: 103, current: 102),
      yearSpan: const PriceSpan(low: 80, high: 120, current: 102),
    )));
    expect(find.text('PREVIOUS CLOSE'), findsOneWidget);
    expect(find.text('3.10%'), findsOneWidget);
    expect(find.byKey(const ValueKey('daySpan')), findsOneWidget);
    expect(find.byKey(const ValueKey('yearSpan')), findsOneWidget);
    expect(find.textContaining('120.00'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('without exchange figures the grid keeps change, high and low', (tester) async {
    final now = DateTime(2026, 11, 25);
    await tester.pumpWidget(_app(KeyStatsGrid(
      windowed: [DisplayPoint(date: now, value: 5)],
      changePercent: null,
      changeIsUp: null,
      currencyCode: 'USD',
    )));
    expect(find.text('PREVIOUS CLOSE'), findsNothing);
    expect(find.byKey(const ValueKey('yearSpan')), findsNothing);
    expect(find.text('HIGH'), findsOneWidget);
  });

  testWidgets('the split notice states the ratio and offers both answers', (tester) async {
    var adjusted = 0, kept = 0;
    await tester.pumpWidget(_app(SplitNoticeCard(
      split: StockSplit(date: DateTime(2024, 7, 1, 12), numerator: 11, denominator: 10),
      onAdjust: () => adjusted++,
      onKeep: () => kept++,
    )));
    expect(find.textContaining('11-for-10 split'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('splitAdjust')));
    await tester.tap(find.byKey(const ValueKey('splitKeep')));
    expect((adjusted, kept), (1, 1));
  });

  testWidgets('the split notice fits in Arabic', (tester) async {
    await tester.pumpWidget(_app(
      SplitNoticeCard(split: StockSplit(date: DateTime(2024, 7, 1, 12), numerator: 11, denominator: 10), onAdjust: () {}, onKeep: () {}),
      locale: const Locale('ar'),
    ));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('11 مقابل 10'), findsOneWidget);
  });

  testWidgets('a stale price says when it last traded', (tester) async {
    await tester.pumpWidget(_app(StaleQuoteLine(lastTraded: DateTime(2024, 7, 21, 12))));
    expect(find.textContaining('Last traded Jul 21, 2024'), findsOneWidget);
  });
}
