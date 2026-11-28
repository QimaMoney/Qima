import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../l10n/app_localizations.dart';
import '../models/money.dart';
import '../models/price_bar.dart';
import '../models/quote.dart';
import '../theme/design_system.dart';
import '../theme/qima_colors.dart';
import '../theme/strings.dart';
import 'stat_pill.dart';

/// The periods the History card and screen list a price by.
const List<BarPeriod> historyPeriods = [BarPeriod.day, BarPeriod.month, BarPeriod.year];

/// How many rows the History card on an instrument's screen shows.
const int historyCardRows = 5;

String _periodName(AppLocalizations l10n, BarPeriod period) => switch (period) {
  BarPeriod.month => l10n.historyMonth,
  BarPeriod.year => l10n.historyYear,
  _ => l10n.historyDay,
};

DateFormat _western(DateFormat format) => format..useNativeDigits = false;

/// "Thu 26 Nov", "Nov 2026" or "2026" for [bar].
String historyPeriodLabel(BuildContext context, PriceBar bar) {
  final locale = Localizations.localeOf(context).toString();
  final format = switch (bar.period) {
    BarPeriod.month => DateFormat.yMMM(locale),
    BarPeriod.year => DateFormat.y(locale),
    _ => DateFormat.MMMEd(locale),
  };
  return _western(format).format(bar.start);
}

/// "Today", "Yesterday" or "So far" where [bar] is still under way or just
/// over, else null.
String? historyPeriodCaption(AppLocalizations l10n, PriceBar bar, DateTime now) {
  final current = bar.period.startOf(now);
  if (bar.start == current) return bar.period == BarPeriod.day ? l10n.historyToday : l10n.historySoFar;
  if (bar.period == BarPeriod.day && bar.start == BarPeriod.day.startOf(current.subtract(const Duration(hours: 12)))) {
    return l10n.historyYesterday;
  }
  return null;
}

/// "+3.53%" for [bar]'s change from the period before, or null without one.
String? historyChangeLabel(BuildContext context, PriceBar bar) {
  final change = bar.change;
  if (change == null) return null;
  final percent = double.parse((change * 100).toStringAsFixed(2));
  return signedFigure(percentLabel(context, percent), isUp: percent >= 0);
}

/// The width the longest name or caption of [bars] needs. Names differ a
/// lot by language: a day is "Thu, Nov 26" in English and twice that in
/// Arabic, so a list sizes its name column to what it holds.
double historyLabelWidth(BuildContext context, Iterable<PriceBar> bars, DateTime now) {
  final colors = context.colors;
  final l10n = AppLocalizations.of(context)!;
  final base = DefaultTextStyle.of(context).style;
  final painter = TextPainter(textDirection: Directionality.of(context), textScaler: MediaQuery.textScalerOf(context), maxLines: 1);
  var widest = 0.0;
  void measure(String? text, TextStyle style) {
    if (text == null) return;
    painter
      ..text = TextSpan(text: text, style: base.merge(style))
      ..layout();
    if (painter.width > widest) widest = painter.width;
  }

  for (final bar in bars) {
    measure(historyPeriodLabel(context, bar), _labelStyle(colors));
    measure(historyPeriodCaption(l10n, bar, now), _captionStyle(colors));
  }
  painter.dispose();
  return widest.ceilToDouble();
}

TextStyle _labelStyle(QimaColors colors) => TextStyle(color: colors.textPrimary, fontSize: 15, fontWeight: FontWeight.w600);
TextStyle _captionStyle(QimaColors colors) => TextStyle(color: colors.textTertiary, fontSize: 12);

/// A period's name over its caption ("Today"), each on one line.
class _PeriodName extends StatelessWidget {
  final PriceBar bar;
  final DateTime now;

  const _PeriodName({required this.bar, required this.now});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final caption = historyPeriodCaption(AppLocalizations.of(context)!, bar, now);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(historyPeriodLabel(context, bar), maxLines: 1, overflow: TextOverflow.ellipsis, style: _labelStyle(colors)),
        if (caption != null) Text(caption, maxLines: 1, overflow: TextOverflow.ellipsis, style: _captionStyle(colors)),
      ],
    );
  }
}

String _price(double? value, String currencyCode) => value == null ? '—' : Money(value, currencyCode).formatted();

/// The Day / Month / Year switch.
class HistoryPeriodSwitch extends StatelessWidget {
  final BarPeriod selected;
  final ValueChanged<BarPeriod> onSelected;

  const HistoryPeriodSwitch({super.key, required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SegmentedButton<BarPeriod>(
      key: const ValueKey('historyPeriodSwitch'),
      segments: [for (final period in historyPeriods) ButtonSegment(value: period, label: Text(_periodName(l10n, period)))],
      selected: {selected},
      onSelectionChanged: (selection) => onSelected(selection.first),
      showSelectedIcon: false,
      style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
    );
  }
}

/// The lowest low and highest high of [bars]: the scale their range bars
/// share, so a list of them reads like a chart.
(double, double) historyScale(Iterable<PriceBar> bars) {
  var low = double.infinity, high = double.negativeInfinity;
  for (final bar in bars) {
    if (bar.drawnLow < low) low = bar.drawnLow;
    if (bar.drawnHigh > high) high = bar.drawnHigh;
  }
  return (low, high);
}

/// One period drawn as a lying-down candle: a thin line from its low to its
/// high and a thick part from where the period before closed to its own
/// close (`PriceBar.bodyOpen`), on [scale]. As wide as its parent lets it be.
class HistoryRangeBar extends StatelessWidget {
  final PriceBar bar;
  final (double, double) scale;

  const HistoryRangeBar({super.key, required this.bar, required this.scale});

  /// The narrowest the bar still reads at, kept free beside a long name.
  static const double minWidth = 48;

  /// The widest it grows in a roomy row, where it sits beside the figures.
  static const double maxWidth = 160;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ExcludeSemantics(
      child: CustomPaint(
        size: const Size(double.infinity, 12),
        painter: _RangeBarPainter(bar: bar, scale: scale, track: colors.hairlineStrong, body: QimaColors.trendColor(bar.closedUp, colors)),
      ),
    );
  }
}

class _RangeBarPainter extends CustomPainter {
  final PriceBar bar;
  final (double, double) scale;
  final Color track;
  final Color body;

  _RangeBarPainter({required this.bar, required this.scale, required this.track, required this.body});

  @override
  void paint(Canvas canvas, Size size) {
    final (lo, hi) = scale;
    // Low to high reads left to right in every language, like the chart.
    double x(double value) => hi <= lo ? size.width / 2 : (value - lo) / (hi - lo) * size.width;
    final mid = size.height / 2;
    final low = x(bar.drawnLow), high = x(bar.drawnHigh);
    if (high - low >= 2) {
      canvas.drawRRect(RRect.fromLTRBR(low, mid - 1, high, mid + 1, const Radius.circular(1)), Paint()..color = track);
    }
    final a = x(bar.bodyOpen), b = x(bar.close);
    var left = a < b ? a : b, right = a < b ? b : a;
    if (right - left < 4) {
      final centre = ((left + right) / 2).clamp(2.0, size.width - 2);
      left = centre - 2;
      right = centre + 2;
    }
    canvas.drawRRect(RRect.fromLTRBR(left, mid - 3, right, mid + 3, const Radius.circular(3)), Paint()..color = body);
  }

  @override
  bool shouldRepaint(covariant _RangeBarPainter old) => old.bar != bar || old.scale != scale || old.track != track || old.body != body;
}

/// One period of the History list: its name, range bar, close and change,
/// and when [expanded] its open, close, high, low, average and median.
class PriceHistoryRow extends StatelessWidget {
  final PriceBar bar;
  final (double, double) scale;
  final String currencyCode;
  final DateTime now;
  final bool expanded;
  final VoidCallback onTap;

  /// The width of the name column, the same on every row of a list so
  /// their range bars line up on the shared scale.
  final double labelWidth;

  const PriceHistoryRow({
    super.key,
    required this.bar,
    required this.scale,
    required this.labelWidth,
    required this.currencyCode,
    required this.now,
    required this.expanded,
    required this.onTap,
  });

  /// What a row has beside its name and range bar: the figures column,
  /// the chevron and the gaps between them.
  static const double _figuresWidth = 104;
  static const double fixedWidth = _figuresWidth + 20 + 2 * DS.spaceSM + DS.spaceXS;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = AppLocalizations.of(context)!;
    final label = historyPeriodLabel(context, bar);
    final caption = historyPeriodCaption(l10n, bar, now);
    final change = historyChangeLabel(context, bar);
    final close = _price(bar.close, currencyCode);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: expanded,
          label: [label, ?caption, '${l10n.statClose} $close', ?change].join(', '),
          hint: expanded ? null : l10n.historyRowHint,
          excludeSemantics: true,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(DS.radiusTile),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: DS.spaceSM),
                child: Row(
                  children: [
                    SizedBox(
                      width: labelWidth,
                      child: _PeriodName(bar: bar, now: now),
                    ),
                    const SizedBox(width: DS.spaceSM),
                    Expanded(
                      child: Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: HistoryRangeBar.maxWidth),
                          child: HistoryRangeBar(bar: bar, scale: scale),
                        ),
                      ),
                    ),
                    const SizedBox(width: DS.spaceSM),
                    SizedBox(
                      width: _figuresWidth,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: AlignmentDirectional.centerEnd,
                            child: Text(close, maxLines: 1, style: _labelStyle(colors)),
                          ),
                          if (change != null)
                            Text(
                              change,
                              style: TextStyle(
                                color: QimaColors.trendColor(bar.change! >= 0, colors),
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: DS.spaceXS),
                    Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 20, color: colors.textTertiary),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (expanded) _Details(bar: bar, currencyCode: currencyCode, now: now),
      ],
    );
  }
}

class _Details extends StatelessWidget {
  final PriceBar bar;
  final String currencyCode;
  final DateTime now;

  const _Details({required this.bar, required this.currencyCode, required this.now});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.colors;
    String price(double? value) => _price(value, currencyCode);
    Widget row(List<(String, double?)> cells) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (title, value) in cells)
          Expanded(
            child: StatPill(title: title, value: price(value)),
          ),
      ],
    );
    // A day older than the intraday window is one stored price.
    final dayTooOld = bar.period == BarPeriod.day && bar.mean == null && bar.start.isBefore(now.subtract(QuoteSeries.intradayWindow));
    return Padding(
      key: const ValueKey('historyDetails'),
      padding: const EdgeInsets.only(bottom: DS.spaceSM),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          row([(l10n.statOpen, bar.open), (l10n.statHigh, bar.hasExtremes ? bar.high : null), (l10n.statAverage, bar.mean)]),
          const SizedBox(height: DS.spaceXS),
          row([(l10n.statClose, bar.close), (l10n.statLow, bar.hasExtremes ? bar.low : null), (l10n.statMedian, bar.median)]),
          if (dayTooOld) ...[
            const SizedBox(height: DS.spaceXS),
            Text(l10n.historyDayAverageNote, style: TextStyle(color: colors.textTertiary, fontSize: 12)),
          ],
        ],
      ),
    );
  }
}

/// [bars] as rows on one shared scale, newest first, with hairlines between
/// them. At most one row is open at a time; the newest starts open.
class PriceHistoryRows extends StatefulWidget {
  /// Newest first.
  final List<PriceBar> bars;
  final String currencyCode;
  final DateTime now;
  final bool startsOpen;

  const PriceHistoryRows({super.key, required this.bars, required this.currencyCode, required this.now, this.startsOpen = true});

  @override
  State<PriceHistoryRows> createState() => _PriceHistoryRowsState();
}

class _PriceHistoryRowsState extends State<PriceHistoryRows> {
  /// The start of the open row's period, so it stays open as prices arrive.
  DateTime? _open;

  @override
  void initState() {
    super.initState();
    if (widget.startsOpen && widget.bars.isNotEmpty) _open = widget.bars.first.start;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final scale = historyScale(widget.bars);
    final widest = historyLabelWidth(context, widget.bars, widget.now);
    return LayoutBuilder(
      builder: (context, constraints) {
        // The names in full where they fit; in a narrow window they give
        // way so the range bar keeps its least width.
        final room = constraints.maxWidth - PriceHistoryRow.fixedWidth - HistoryRangeBar.minWidth;
        final labelWidth = room < widest ? (room < 0 ? 0.0 : room) : widest;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, bar) in widget.bars.indexed) ...[
              if (i > 0) Divider(height: 1, thickness: 1, color: colors.hairline),
              PriceHistoryRow(
                key: ValueKey('historyRow.${bar.start.toIso8601String()}'),
                bar: bar,
                scale: scale,
                labelWidth: labelWidth,
                currencyCode: widget.currencyCode,
                now: widget.now,
                expanded: _open == bar.start,
                onTap: () => setState(() => _open = _open == bar.start ? null : bar.start),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// The History card on an instrument's screen: the latest few days, months
/// or years, and a way to the full list.
class PriceHistoryCard extends StatelessWidget {
  /// Oldest first, as [PriceBars.build] gives them.
  final List<PriceBar> bars;
  final BarPeriod period;
  final ValueChanged<BarPeriod> onPeriod;
  final String currencyCode;
  final DateTime now;
  final VoidCallback onShowAll;

  const PriceHistoryCard({
    super.key,
    required this.bars,
    required this.period,
    required this.onPeriod,
    required this.currencyCode,
    required this.now,
    required this.onShowAll,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.colors;
    final latest = bars.reversed.take(historyCardRows).toList();
    return DSCard(
      key: const ValueKey('historyCard'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.historyTitle,
                  style: TextStyle(color: colors.textPrimary, fontWeight: FontWeight.w700),
                ),
              ),
              HistoryPeriodSwitch(selected: period, onSelected: onPeriod),
            ],
          ),
          const SizedBox(height: DS.spaceXS),
          PriceHistoryRows(key: ValueKey(period), bars: latest, currencyCode: currencyCode, now: now),
          Divider(height: 1, thickness: 1, color: colors.hairline),
          InkWell(
            key: const ValueKey('historyShowAll'),
            onTap: onShowAll,
            borderRadius: BorderRadius.circular(DS.radiusTile),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.historyShowAll,
                      style: TextStyle(color: colors.brandText, fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 20, color: colors.brandText),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// [bars] as a table with every figure in view, for a wide window.
class PriceHistoryTable extends StatelessWidget {
  /// Newest first.
  final List<PriceBar> bars;
  final String currencyCode;
  final DateTime now;

  const PriceHistoryTable({super.key, required this.bars, required this.currencyCode, required this.now});

  /// The narrowest width the table's eight columns fit in.
  static const double minWidth = 720;

  /// The least and the largest share of the table its name column takes.
  static const double _minNameWidth = 72;
  static const double _maxNameShare = 0.3;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.colors;
    final header = DS.overline(context, color: colors.textTertiary, fontSize: 11, fontWeight: FontWeight.w600);
    final figure = TextStyle(color: colors.textPrimary, fontSize: 15);
    Widget cell(String text, TextStyle style) => Expanded(
      child: Text(text, textAlign: TextAlign.end, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
    );
    String price(double? value) => _price(value, currencyCode);

    final widest = historyLabelWidth(context, bars, now);
    return LayoutBuilder(
      builder: (context, constraints) {
        final nameWidth = widest.clamp(_minNameWidth, constraints.maxWidth * _maxNameShare).toDouble();
        return Column(
          key: const ValueKey('historyTable'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: DS.spaceSM),
              child: Row(
                children: [
                  SizedBox(
                    width: nameWidth,
                    child: Text(l10n.historyPeriod.toUpperCase(), maxLines: 1, style: header),
                  ),
                  for (final title in [
                    l10n.statOpen,
                    l10n.statHigh,
                    l10n.statLow,
                    l10n.statClose,
                    l10n.statAverage,
                    l10n.statMedian,
                    l10n.statChange,
                  ])
                    cell(title.toUpperCase(), header),
                ],
              ),
            ),
            for (final bar in bars) ...[
              Divider(height: 1, thickness: 1, color: colors.hairline),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Row(
                  children: [
                    SizedBox(
                      width: nameWidth,
                      child: _PeriodName(bar: bar, now: now),
                    ),
                    cell(price(bar.open), figure),
                    cell(price(bar.hasExtremes ? bar.high : null), figure),
                    cell(price(bar.hasExtremes ? bar.low : null), figure),
                    cell(price(bar.close), figure.copyWith(fontWeight: FontWeight.w600)),
                    cell(price(bar.mean), figure),
                    cell(price(bar.median), figure),
                    cell(
                      historyChangeLabel(context, bar) ?? '—',
                      figure.copyWith(
                        fontWeight: FontWeight.w500,
                        color: bar.change == null ? colors.textTertiary : QimaColors.trendColor(bar.change! >= 0, colors),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
