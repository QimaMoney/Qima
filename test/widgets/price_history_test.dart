import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:qima/l10n/app_localizations.dart';
import 'package:qima/models/display_point.dart';
import 'package:qima/models/price_bar.dart';
import 'package:qima/theme/app_theme.dart';
import 'package:qima/theme/price_chart.dart';
import 'package:qima/widgets/chart_style_switch.dart';
import 'package:qima/widgets/price_history.dart';

Widget _app(Widget child, {Locale locale = const Locale('en'), double width = 402}) => MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: SingleChildScrollView(child: Center(child: SizedBox(width: width, child: child))),
      ),
    );

/// Text containing [s] once the direction isolates around figures are gone.
Finder _text(String s) => find.byWidgetPredicate(
      (w) => w is Text && (w.data ?? '').replaceAll(RegExp('[\u2066-\u2069]'), '').contains(s),
    );

void main() {
  setUpAll(() async {
    await initializeDateFormatting('ar');
  });

  final now = DateTime(2026, 11, 26, 15);

  /// One sample each trading day from 1 July, rising by 1 a day from 100,
  /// each with an open 0.5 below its close and a range of 2 around it.
  final points = [
    for (var d = DateTime(2026, 7, 1), i = 0; !d.isAfter(DateTime(2026, 11, 24)); d = d.add(const Duration(days: 1)), i++)
      if (d.weekday <= 5) DisplayPoint(date: d, value: 100.0 + i, open: 99.5 + i, high: 101.0 + i, low: 99.0 + i),
  ];
  List<PriceBar> bars(BarPeriod period) => PriceBars.build(points, period, now: now);

  Widget card(BarPeriod period, {ValueChanged<BarPeriod>? onPeriod, VoidCallback? onShowAll, Locale locale = const Locale('en'), double width = 402}) => _app(
        PriceHistoryCard(
          bars: bars(period),
          period: period,
          onPeriod: onPeriod ?? (_) {},
          currencyCode: 'USD',
          now: now,
          onShowAll: onShowAll ?? () {},
        ),
        locale: locale,
        width: width,
      );

  testWidgets('the card lists the latest five months, newest first and open', (tester) async {
    await tester.pumpWidget(card(BarPeriod.month));

    expect(find.byType(PriceHistoryRow), findsNWidgets(historyCardRows));
    expect(tester.widget<PriceHistoryRow>(find.byType(PriceHistoryRow).first).bar.start, DateTime(2026, 11));
    expect(find.text('Nov 2026'), findsOneWidget);
    expect(find.text('So far'), findsOneWidget);
    expect(find.byKey(const ValueKey('historyDetails')), findsOneWidget);
    for (final title in ['OPEN', 'CLOSE', 'HIGH', 'LOW', 'AVERAGE', 'MEDIAN']) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
  });

  testWidgets('tapping a row opens it and closes the one that was open', (tester) async {
    await tester.pumpWidget(card(BarPeriod.month));
    final october = bars(BarPeriod.month).firstWhere((b) => b.start == DateTime(2026, 10));

    await tester.tap(find.text('Oct 2026'));
    await tester.pump();

    expect(find.byKey(const ValueKey('historyDetails')), findsOneWidget);
    expect(tester.widget<PriceHistoryRow>(find.byType(PriceHistoryRow).at(1)).expanded, isTrue);
    expect(_text(october.open!.toStringAsFixed(2)), findsOneWidget);
    expect(_text(october.median!.toStringAsFixed(2)), findsOneWidget);

    await tester.tap(find.text('Oct 2026'));
    await tester.pump();
    expect(find.byKey(const ValueKey('historyDetails')), findsNothing);
  });

  testWidgets('a row shows the change from the month before', (tester) async {
    await tester.pumpWidget(card(BarPeriod.month));
    final change = (bars(BarPeriod.month).last.change! * 100).toStringAsFixed(2);
    expect(_text('+$change%'), findsOneWidget);
  });

  testWidgets('an older day shows dashes for average and median, and says why', (tester) async {
    await tester.pumpWidget(card(BarPeriod.day));

    expect(find.text('—'), findsNWidgets(2));
    expect(find.textContaining('last 2 days'), findsOneWidget);
  });

  testWidgets('the switch and the show-all row report what was picked', (tester) async {
    BarPeriod? picked;
    var shown = 0;
    await tester.pumpWidget(card(BarPeriod.month, onPeriod: (p) => picked = p, onShowAll: () => shown++));

    await tester.tap(find.text('Year'));
    expect(picked, BarPeriod.year);
    await tester.tap(find.byKey(const ValueKey('historyShowAll')));
    expect(shown, 1);
  });

  testWidgets('the card lays out in Arabic at a phone width', (tester) async {
    await tester.pumpWidget(card(BarPeriod.month, locale: const Locale('ar')));
    expect(tester.takeException(), isNull);
    expect(find.text('السجل'), findsOneWidget);
  });

  testWidgets('long Arabic day names show in full, with the range bars still lined up', (tester) async {
    // The test font is far wider than the app's, so the names need more
    // room here than on a phone.
    await tester.pumpWidget(card(BarPeriod.day, locale: const Locale('ar'), width: 600));

    final rows = find.byType(PriceHistoryRow);
    expect(rows, findsNWidgets(historyCardRows));
    for (final paragraph in tester.renderObjectList<RenderParagraph>(
      find.descendant(of: rows, matching: find.byType(RichText)),
    )) {
      expect(paragraph.didExceedMaxLines, isFalse, reason: paragraph.text.toPlainText());
    }
    final widths = {for (final e in find.byType(HistoryRangeBar).evaluate()) e.size!.width};
    expect(widths, hasLength(1));
    expect(widths.single, greaterThanOrEqualTo(HistoryRangeBar.minWidth));
  });

  testWidgets('names too long for a narrow window give way to the range bar', (tester) async {
    await tester.pumpWidget(card(BarPeriod.day, locale: const Locale('ar'), width: 320));

    expect(tester.takeException(), isNull);
    for (final e in find.byType(HistoryRangeBar).evaluate()) {
      expect(e.size!.width, HistoryRangeBar.minWidth);
    }
  });

  testWidgets('the table shows every figure of each period', (tester) async {
    final rows = bars(BarPeriod.month).reversed.toList();
    await tester.pumpWidget(_app(PriceHistoryTable(bars: rows, currencyCode: 'USD', now: now), width: 900));

    expect(tester.takeException(), isNull);
    for (final title in ['PERIOD', 'OPEN', 'HIGH', 'LOW', 'CLOSE', 'AVERAGE', 'MEDIAN', 'CHANGE']) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    expect(_text(rows.first.mean!.toStringAsFixed(2)), findsOneWidget);
    // The first month has nothing before it to change from.
    expect(find.text('—'), findsOneWidget);
  });

  testWidgets('the table names today and yesterday in full under the day', (tester) async {
    final today = DateTime(2026, 11, 24, 15);
    final rows = PriceBars.build(points, BarPeriod.day, now: today).reversed.take(5).toList();
    await tester.pumpWidget(_app(PriceHistoryTable(bars: rows, currencyCode: 'USD', now: today), width: 760));

    expect(tester.takeException(), isNull);
    for (final caption in ['Today', 'Yesterday']) {
      final paragraph = tester.renderObject<RenderParagraph>(find.text(caption));
      expect(paragraph.didExceedMaxLines, isFalse, reason: caption);
    }
    expect(tester.getTopLeft(find.text('Today')).dy, greaterThan(tester.getTopLeft(find.text('Tue, Nov 24')).dy));
  });

  testWidgets('the chart style switch reports the other style and ignores the selected one', (tester) async {
    final picked = <ChartStyle>[];
    await tester.pumpWidget(_app(ChartStyleSwitch(selected: ChartStyle.line, onSelected: picked.add)));

    await tester.tap(find.byKey(const ValueKey('chartStyle.line')));
    expect(picked, isEmpty);
    await tester.tap(find.byKey(const ValueKey('chartStyle.candles')));
    expect(picked, [ChartStyle.candles]);
  });

  testWidgets('a candle chart shows open, high and low for the touched candle', (tester) async {
    final candles = [for (final bar in bars(BarPeriod.week)) bar.toPoint()];
    await tester.pumpWidget(_app(
      SizedBox(
        height: 240,
        child: PriceChartView(
          points: candles,
          isTrendingUp: true,
          accent: Colors.green,
          isInteractive: true,
          currencyCode: 'USD',
          style: ChartStyle.candles,
          compare: ChartCompare(label: 'Gold', points: points),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);

    final origin = tester.getTopLeft(find.byType(PriceChartView));
    final gesture = await tester.startGesture(origin + const Offset(60, 120));
    await gesture.moveTo(origin + const Offset(2, 120));
    await tester.pump();

    final first = candles.first;
    expect(_text('Open \$${first.open!.toStringAsFixed(2)}'), findsOneWidget);
    expect(_text('High \$${first.peak.toStringAsFixed(2)}'), findsOneWidget);
    expect(_text('Low \$${first.trough.toStringAsFixed(2)}'), findsOneWidget);
    expect(_text('Gold'), findsNothing, reason: 'no comparison over candles');
    await gesture.up();
    await tester.pump(const Duration(seconds: 1));
  });
}
