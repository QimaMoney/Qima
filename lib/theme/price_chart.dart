import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../l10n/app_localizations.dart';
import '../models/chart_time_axis.dart';
import '../models/display_point.dart';
import '../models/market_hours.dart';
import '../models/money.dart';
import '../models/period_summary.dart';
import '../services/chart_sampling.dart';
import '../services/scrub_resolver.dart';
import 'design_system.dart';
import 'masking.dart';
import 'qima_colors.dart';
import 'strings.dart';
import 'summaries.dart';

// Re-exported so callers only need to import price_chart.dart for the
// granularity/resolver types used alongside the chart.
export '../services/scrub_resolver.dart' show AxisGranularity, ScrubResolver;

/// Maximum points actually drawn — the visible series is first thinned via
/// [ChartSampling.thinned] (spec §3.3).
const int maxDrawnPoints = 250;

/// How far a double-tap can zoom into a range.
const double maxChartZoom = 8;

/// What a mark on the chart stands for: the person's own buy, sell, or any
/// other change to the holding.
enum ChartMarkKind { buy, sell, other }

/// Something the person did on a date, pinned to the price at that date.
class ChartMark {
  final DateTime date;
  final ChartMarkKind kind;

  /// Shown in the scrub callout when the finger rests on the mark.
  final String label;

  const ChartMark({required this.date, required this.kind, required this.label});
}

/// A second series drawn against the price, both starting from the same
/// spot at the left edge so the gap between them is the difference in
/// percentage change.
class ChartCompare {
  final String label;
  final List<DisplayPoint> points;

  const ChartCompare({required this.label, required this.points});
}

/// Price chart matching `PriceChartView.swift` (spec §3.3): an area+line
/// mark with a smooth curve, optional axes, and optional interaction.
///
/// When [isInteractive]: one finger scrubs, two fingers measure the change
/// between them, and a double-tap zooms in around the tap (again to zoom
/// further; past [maxChartZoom] it zooms back out). While zoomed a drag pans
/// and a long press scrubs.
class PriceChartView extends StatefulWidget {
  final List<DisplayPoint> points;
  final bool isTrendingUp;
  final Color accent;
  final bool showsAxes;
  final double lineWidth;
  final bool isInteractive;
  final String? currencyCode;

  /// Overrides the default up/down trend color (`context.colors.up`/`.down`)
  /// for both the line and its area gradient. Null (the default) keeps
  /// today's trend-colored behaviour.
  final Color? lineColor;

  /// Hides axis value labels and the scrub callout's price text (for the
  /// upcoming Hide balances feature). The callout date and the chart shape
  /// itself are unaffected. Defaults to false, matching current behaviour.
  final bool maskValues;

  /// Where the instrument trades. When set, time the market is closed takes
  /// almost no room on the time axis (see [ChartTimeAxis]).
  final Market? market;

  /// The person's own transactions, pinned to the price on their dates.
  final List<ChartMark> marks;

  final ChartCompare? compare;

  const PriceChartView({
    super.key,
    required this.points,
    required this.isTrendingUp,
    required this.accent,
    this.showsAxes = true,
    this.lineWidth = 2.5,
    this.isInteractive = false,
    this.currencyCode,
    this.lineColor,
    this.maskValues = false,
    this.market,
    this.marks = const [],
    this.compare,
  });

  @override
  State<PriceChartView> createState() => _PriceChartViewState();
}

/// The plot area and the slice of the time axis it shows.
class _Frame {
  final double plotWidth;
  final double plotHeight;
  final double from;
  final double to;

  const _Frame(this.plotWidth, this.plotHeight, this.from, this.to);

  double x(double position) => (position - from) / (to - from) * plotWidth;

  double positionAt(double dx) => from + (dx / plotWidth).clamp(0.0, 1.0) * (to - from);
}

class _PriceChartViewState extends State<PriceChartView> {
  ChartTimeAxis? _axis;
  Object? _axisKey;

  /// The zoomed slice of the axis; null shows all of it.
  (double, double)? _view;
  int? _scrub;
  (int, int)? _measure;
  bool _holdScrub = false;
  Offset? _doubleTapAt;
  final Map<int, Offset> _pointers = {};

  // From the last layout, for the gesture handlers.
  _Frame? _frame;
  Set<int> _notable = const {};
  (int, int) _inView = (0, 0);

  ChartTimeAxis get _timeAxis {
    final points = widget.points;
    final key = (points.length, points.first.date, points.last.date, widget.market);
    if (_axis == null || _axisKey != key) {
      _axis = ChartTimeAxis.build(points, market: widget.market);
      _axisKey = key;
    }
    return _axis!;
  }

  @override
  void didUpdateWidget(covariant PriceChartView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new quote extends the series and keeps what's on screen; a new range,
    // instrument or market starts over.
    final before = oldWidget.points, after = widget.points;
    final sameSeries =
        before.isNotEmpty && after.isNotEmpty && before.first.date == after.first.date && oldWidget.market == widget.market;
    if (!sameSeries) {
      _view = null;
      _scrub = null;
      _measure = null;
    } else {
      if (_scrub != null && _scrub! >= after.length) _scrub = null;
      if (_measure != null && _measure!.$2 >= after.length) _measure = null;
    }
  }

  bool get _zoomed => _view != null;
  bool get _measuring => _measure != null || _pointers.length >= 2;

  void _scrubAt(Offset local) {
    final frame = _frame;
    if (frame == null || frame.plotWidth <= 0 || _measuring) return;
    final index = _timeAxis.nearestIndex(frame.positionAt(local.dx));
    if (index == _scrub) return;
    if (_scrub == null || _notable.contains(index)) HapticFeedback.selectionClick();
    setState(() => _scrub = index);
  }

  void _endScrub() {
    if (_scrub != null) setState(() => _scrub = null);
  }

  void _pan(double dx) {
    final frame = _frame, view = _view;
    if (frame == null || view == null || frame.plotWidth <= 0 || _measuring) return;
    final span = view.$2 - view.$1;
    final from = (view.$1 - dx / frame.plotWidth * span).clamp(0.0, _timeAxis.length - span);
    setState(() {
      _view = (from, from + span);
      _scrub = null;
    });
  }

  void _zoomAt(Offset local) {
    final frame = _frame, axis = _timeAxis;
    final length = axis.length;
    if (frame == null || frame.plotWidth <= 0 || length <= 0) return;
    final zoom = _view == null ? 1.0 : length / (_view!.$2 - _view!.$1);
    final span = length / (zoom * 2);
    final t = (local.dx / frame.plotWidth).clamp(0.0, 1.0);
    final from = (frame.positionAt(local.dx) - t * span).clamp(0.0, length - span);
    // Past the deepest zoom, or so close in that a few samples would fill
    // the width, a double-tap zooms back out instead.
    final tooFew = axis.nearestIndex(from + span) - axis.nearestIndex(from) < 4;
    HapticFeedback.lightImpact();
    setState(() {
      _view = zoom * 2 > maxChartZoom + 0.01 || tooFew ? null : (from, from + span);
      _scrub = null;
      _measure = null;
    });
  }

  void _resetZoom() {
    HapticFeedback.lightImpact();
    setState(() => _view = null);
  }

  void _pointerDown(PointerDownEvent event) {
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length == 2) {
      HapticFeedback.selectionClick();
      _updateMeasure();
    }
  }

  void _pointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length == 2) _updateMeasure();
  }

  void _pointerUp(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.length < 2 && _measure != null) setState(() => _measure = null);
  }

  void _updateMeasure() {
    final frame = _frame;
    if (frame == null || frame.plotWidth <= 0) return;
    final ends = [for (final at in _pointers.values.take(2)) _timeAxis.nearestIndex(frame.positionAt(at.dx))]..sort();
    final measure = (ends[0], ends[1]);
    if (measure == _measure && _scrub == null) return;
    setState(() {
      _measure = measure;
      _scrub = null;
    });
  }

  /// Moves the screen reader's place through about twenty stops of what's in
  /// view.
  void _step(int direction) => setState(() => _scrub = _stepTarget(direction));

  int _stepTarget(int direction) {
    final (first, last) = _inView;
    final stride = math.max(1, (last - first) ~/ 20);
    final from = _scrub ?? (direction > 0 ? first - stride : last + stride);
    return (from + direction * stride).clamp(first, last);
  }

  @override
  Widget build(BuildContext context) {
    final points = widget.points;
    if (points.length < 2) return const SizedBox.shrink();
    final colors = context.colors;
    final color = widget.lineColor ?? QimaColors.trendColor(widget.isTrendingUp, colors);
    final axis = _timeAxis;
    final interactive = widget.isInteractive;

    final chart = LayoutBuilder(
      builder: (context, constraints) {
        final scene = _Scene.of(
          context,
          widget,
          axis,
          Size(constraints.maxWidth, constraints.maxHeight),
          view: _view,
          scrub: _scrub,
          measure: _measure,
          color: color,
        );
        _frame = scene.frame;
        _notable = scene.notable;
        _inView = scene.inView;

        Widget plot = CustomPaint(size: scene.size, painter: scene.painter);
        if (interactive) {
          plot = Listener(
            onPointerDown: _pointerDown,
            onPointerMove: _pointerMove,
            onPointerUp: _pointerUp,
            onPointerCancel: _pointerUp,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: (d) {
                if (!_zoomed) _scrubAt(d.localPosition);
              },
              onHorizontalDragUpdate: (d) {
                if (_zoomed) {
                  _pan(d.delta.dx);
                } else {
                  _scrubAt(d.localPosition);
                }
              },
              onHorizontalDragEnd: (_) {
                if (!_zoomed) _endScrub();
              },
              onHorizontalDragCancel: () {
                if (!_zoomed) _endScrub();
              },
              onTapDown: (d) => _scrubAt(d.localPosition),
              onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
              onDoubleTap: () {
                final at = _doubleTapAt;
                if (at != null) _zoomAt(at);
              },
              onLongPressStart: _zoomed
                  ? (d) {
                      _holdScrub = true;
                      _scrubAt(d.localPosition);
                    }
                  : null,
              onLongPressMoveUpdate: _zoomed
                  ? (d) {
                      if (_holdScrub) _scrubAt(d.localPosition);
                    }
                  : null,
              onLongPressEnd: _zoomed
                  ? (_) {
                      _holdScrub = false;
                      _endScrub();
                    }
                  : null,
              child: plot,
            ),
          );
        }

        final callout = scene.callout(context);
        return Stack(
          children: [
            Positioned.fill(child: plot),
            if (callout != null)
              PositionedDirectional(top: 0, start: 0, end: 0, child: IgnorePointer(child: callout)),
            if (_zoomed && callout == null) PositionedDirectional(top: 0, end: 0, child: _ResetZoomPill(onTap: _resetZoom)),
          ],
        );
      },
    );

    final facts = ChartFacts.of(points);
    // An adjustable node gives its value with the values either side, or
    // none of them before the first step.
    final scrubbed = interactive && _scrub != null && _scrub! < points.length;
    String stop(int index) => _pointLabel(context, points[index.clamp(0, points.length - 1)]);
    return Semantics(
      label: facts == null
          ? null
          : chartDescription(context, facts, currencyCode: widget.currencyCode, hidden: widget.maskValues),
      value: scrubbed ? stop(_scrub!) : null,
      increasedValue: scrubbed ? stop(_stepTarget(1)) : null,
      decreasedValue: scrubbed ? stop(_stepTarget(-1)) : null,
      onIncrease: interactive ? () => _step(1) : null,
      onDecrease: interactive ? () => _step(-1) : null,
      child: chart,
    );
  }

  String _pointLabel(BuildContext context, DisplayPoint point) {
    final date = dateWithYear(context, point.date);
    if (widget.maskValues) return date;
    return '$date, ${_valueLabel(point.value, widget.currencyCode)}';
  }
}

String _valueLabel(double value, String? currencyCode) =>
    currencyCode != null ? Money(value, currencyCode).formatted() : value.toStringAsFixed(2);

/// "+2.1%" in the app's locale.
String _signedPercent(BuildContext context, double fraction) {
  final percent = double.parse((fraction * 100).toStringAsFixed(2));
  return '${percent >= 0 ? '+' : ''}${percentLabel(context, percent)}';
}

/// Everything one layout of the chart draws, worked out from the widget, the
/// zoom and the finger positions.
class _Scene {
  final Size size;
  final _Frame frame;
  final _PriceChartPainter painter;
  final Set<int> notable;
  final (int, int) inView;
  final Widget? Function(BuildContext) callout;

  _Scene(this.size, this.frame, this.painter, this.notable, this.inView, this.callout);

  factory _Scene.of(
    BuildContext context,
    PriceChartView widget,
    ChartTimeAxis axis,
    Size size, {
    required (double, double)? view,
    required int? scrub,
    required (int, int)? measure,
    required Color color,
  }) {
    final colors = context.colors;
    final locale = Localizations.localeOf(context).toString();
    final points = widget.points;
    final n = points.length;
    final showsAxes = widget.showsAxes && !widget.maskValues;
    final plotWidth = math.max(0.0, size.width - (showsAxes ? 24.0 : 0.0));
    final plotHeight = math.max(0.0, size.height - (showsAxes ? 18.0 : 0.0));

    final length = axis.length > 0 ? axis.length : 1.0;
    final (from, to) = view ?? (0.0, length);
    final frame = _Frame(plotWidth, plotHeight, from, to > from ? to : from + 1);

    // One sample either side of the view, so the line runs to both edges.
    final first = view == null ? 0 : math.max(0, axis.nearestIndex(from) - 1);
    final last = view == null ? n - 1 : math.min(n - 1, axis.nearestIndex(to) + 1);
    var inFirst = first, inLast = last;
    while (inFirst < inLast && axis.positions[inFirst] < from) {
      inFirst++;
    }
    while (inLast > inFirst && axis.positions[inLast] > to) {
      inLast--;
    }
    final visible = view == null ? points : points.sublist(first, last + 1);
    final base = points[inFirst];

    var high = inFirst, low = inFirst;
    for (var i = inFirst; i <= inLast; i++) {
      if (points[i].value > points[high].value) high = i;
      if (points[i].value < points[low].value) low = i;
    }

    // The comparison, scaled to start where the price starts in view.
    var compare = const <DisplayPoint>[];
    double? Function(DateTime)? compareChangeAt;
    final source = widget.compare;
    if (source != null && base.value != 0) {
      final end = points[inLast].date;
      DisplayPoint? anchor;
      final inside = <DisplayPoint>[];
      for (final c in source.points) {
        if (c.date.isAfter(end)) break;
        if (c.date.isAfter(base.date)) {
          inside.add(c);
        } else {
          anchor = c;
        }
      }
      anchor ??= inside.isEmpty ? null : inside.first;
      if (anchor != null && anchor.value != 0 && inside.isNotEmpty) {
        final start = anchor.value;
        compare = [
          DisplayPoint(date: base.date, value: base.value),
          for (final c in inside) DisplayPoint(date: c.date, value: base.value * c.value / start),
        ];
        compareChangeAt = (date) {
          var value = start;
          for (final c in inside) {
            if (c.date.isAfter(date)) break;
            value = c.value;
          }
          return value / start - 1;
        };
      }
    }

    var lo = double.infinity, hi = double.negativeInfinity;
    for (final p in visible) {
      lo = math.min(lo, p.value);
      hi = math.max(hi, p.value);
    }
    for (final p in compare) {
      lo = math.min(lo, p.value);
      hi = math.max(hi, p.value);
    }
    final pad = (hi - lo) * 0.15 > hi.abs() * 0.002 ? (hi - lo) * 0.15 : hi.abs() * 0.002;
    final domainLo = lo - pad, domainHi = hi + pad;
    double y(double value) {
      final range = domainHi - domainLo;
      if (range <= 0) return plotHeight / 2;
      return plotHeight - (value - domainLo) / range * plotHeight;
    }

    Offset at(int i) => Offset(frame.x(axis.positions[i]), y(points[i].value));
    List<Offset> coords(List<DisplayPoint> series) => [
          for (final p in ChartSampling.thinned(series, maxDrawnPoints))
            Offset(frame.x(axis.positionOf(p.date)), y(p.value)),
        ];

    final granularity = AxisGranularity.forSpan(points[inLast].date.difference(base.date));
    final ticks = <(double, String)>[];
    if (showsAxes) {
      final format = axisDateFormat(granularity, locale);
      final count = granularity.tickCount;
      for (var i = 0; i < count; i++) {
        final t = count == 1 ? 0.0 : i / (count - 1);
        ticks.add((t * plotWidth, format.format(axis.dateAt(frame.from + t * (frame.to - frame.from)))));
      }
    }

    // Marks sit on the sample nearest their date; one from after the last
    // sample (today, before a fresh quote) still shows at the end.
    final marksAt = <int, List<ChartMark>>{};
    final lastDay = points.last.date.add(const Duration(days: 1));
    for (final mark in widget.marks) {
      if (mark.date.isBefore(points.first.date) || mark.date.isAfter(lastDay)) continue;
      marksAt.putIfAbsent(axis.nearestIndex(axis.positionOf(mark.date)), () => []).add(mark);
    }
    final markDots = <(Offset, ChartMarkKind)>[
      for (final MapEntry(key: i, value: marks) in marksAt.entries)
        if (i >= inFirst && i <= inLast)
          (at(i), marks.every((m) => m.kind == marks.first.kind) ? marks.first.kind : ChartMarkKind.other),
    ];

    final scrubIndex = scrub != null && scrub < n ? scrub : null;
    final measured = measure != null && measure.$2 < n ? measure : null;
    final showExtremes = showsAxes && scrubIndex == null && measured == null && points[high].value != points[low].value;

    final painter = _PriceChartPainter(
      line: coords(visible),
      compare: compare.length >= 2 ? coords(compare) : const [],
      plot: Size(plotWidth, plotHeight),
      zoomed: view != null,
      color: color,
      compareColor: colors.textSecondary,
      textTertiary: colors.textTertiary,
      textSecondary: colors.textSecondary,
      up: colors.up,
      down: colors.down,
      ring: colors.surfaceTop,
      lineWidth: widget.lineWidth,
      textDirection: Directionality.of(context),
      ticks: ticks,
      extremes: showExtremes
          ? [
              (at(high), _valueLabel(points[high].value, widget.currencyCode), true),
              (at(low), _valueLabel(points[low].value, widget.currencyCode), false),
            ]
          : const [],
      marks: markDots,
      scrub: scrubIndex == null ? null : at(scrubIndex),
      measure: measured == null ? null : (at(measured.$1), at(measured.$2)),
    );

    Widget? callout(BuildContext context) {
      final l10n = AppLocalizations.of(context)!;
      final dateFormat = calloutDateFormat(granularity, locale);
      if (measured != null) {
        final a = points[measured.$1], b = points[measured.$2];
        final change = a.value == 0 ? 0.0 : b.value / a.value - 1;
        final delta = b.value - a.value;
        final trend = QimaColors.trendColor(delta >= 0, colors);
        final amount = widget.maskValues || widget.currencyCode == null
            ? null
            : Masking.signedAmount(Money(delta.abs(), widget.currencyCode!), hidden: false, isUp: delta >= 0);
        return _Callout(
          color: trend,
          title: '${dateFormat.format(a.date)} – ${dateFormat.format(b.date)}',
          headline: amount == null ? _signedPercent(context, change) : '$amount (${_signedPercent(context, change)})',
          headlineColor: trend,
        );
      }
      if (scrubIndex == null) return null;
      final p = points[scrubIndex];
      final since = base.value == 0 || scrubIndex == inFirst ? null : p.value / base.value - 1;
      final compareChange = compareChangeAt?.call(p.date);
      return _Callout(
        color: color,
        title: dateFormat.format(p.date),
        headline: widget.maskValues ? Masking.mask : _valueLabel(p.value, widget.currencyCode),
        lines: [
          if (since != null) l10n.chartSince(_signedPercent(context, since), dateFormat.format(base.date)),
          if (compareChange != null) '${source!.label} ${_signedPercent(context, compareChange)}',
          for (final mark in marksAt[scrubIndex] ?? const <ChartMark>[]) mark.label,
        ],
      );
    }

    return _Scene(size, frame, painter, {high, low, ...marksAt.keys}, (inFirst, inLast), callout);
  }
}

class _Callout extends StatelessWidget {
  final Color color;
  final String title;
  final String headline;
  final Color? headlineColor;
  final List<String> lines;

  const _Callout({
    required this.color,
    required this.title,
    required this.headline,
    this.headlineColor,
    this.lines = const [],
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Align(
      alignment: AlignmentDirectional.topStart,
      child: Container(
        margin: const EdgeInsets.only(bottom: DS.spaceXS),
        padding: const EdgeInsets.symmetric(horizontal: DS.spaceSM, vertical: DS.spaceXS),
        decoration: BoxDecoration(
          gradient: DS.tileFill(colors),
          borderRadius: BorderRadius.circular(DS.radiusTile),
          border: Border.all(color: color.withValues(alpha: 0.35), width: 1),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(color: colors.textTertiary, fontSize: 11)),
            Text(
              headline,
              style: TextStyle(color: headlineColor ?? colors.textPrimary, fontSize: 14, fontWeight: FontWeight.w700),
            ),
            for (final line in lines) Text(line, style: TextStyle(color: colors.textSecondary, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

class _ResetZoomPill extends StatelessWidget {
  final VoidCallback onTap;

  const _ResetZoomPill({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final label = AppLocalizations.of(context)!.chartResetZoom;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        key: const ValueKey('chartResetZoom'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: DS.spaceSM, vertical: 4),
          decoration: BoxDecoration(
            gradient: DS.tileFill(colors),
            borderRadius: BorderRadius.circular(DS.radiusPill),
            border: Border.all(color: colors.hairlineStrong),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.zoom_out_map, size: 14, color: colors.textSecondary),
              const SizedBox(width: 4),
              Text(label, style: TextStyle(color: colors.textSecondary, fontSize: 11, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tick-label formatter for a given axis granularity, in [locale] with
/// Western digits like the rest of the app's dates.
DateFormat axisDateFormat(AxisGranularity granularity, [String? locale]) {
  final format = switch (granularity) {
    AxisGranularity.time => DateFormat.Hm(locale),
    AxisGranularity.dayMonth => DateFormat.MMMd(locale),
    AxisGranularity.month => DateFormat.MMM(locale),
    AxisGranularity.monthYear => DateFormat('MMM yy', locale),
    AxisGranularity.year => DateFormat.y(locale),
  };
  return format..useNativeDigits = false;
}

/// Richer scrub-callout formatter, in [locale] with Western digits.
DateFormat calloutDateFormat(AxisGranularity granularity, [String? locale]) {
  final format = granularity == AxisGranularity.time ? DateFormat.MMMd(locale).add_Hm() : DateFormat.yMMMd(locale);
  return format..useNativeDigits = false;
}

class _PriceChartPainter extends CustomPainter {
  final List<Offset> line;
  final List<Offset> compare;
  final Size plot;

  /// A zoomed line runs one sample past each edge, so it's cut at the plot.
  final bool zoomed;
  final Color color;
  final Color compareColor;

  /// Passed in rather than read from `DS` since a [CustomPainter] has no
  /// [BuildContext] to resolve the current theme.
  final Color textTertiary;
  final Color textSecondary;
  final Color up;
  final Color down;
  final Color ring;
  final double lineWidth;
  final TextDirection textDirection;
  final List<(double, String)> ticks;
  final List<(Offset, String, bool)> extremes;
  final List<(Offset, ChartMarkKind)> marks;
  final Offset? scrub;
  final (Offset, Offset)? measure;

  _PriceChartPainter({
    required this.line,
    required this.compare,
    required this.plot,
    required this.zoomed,
    required this.color,
    required this.compareColor,
    required this.textTertiary,
    required this.textSecondary,
    required this.up,
    required this.down,
    required this.ring,
    required this.lineWidth,
    required this.textDirection,
    required this.ticks,
    required this.extremes,
    required this.marks,
    required this.scrub,
    required this.measure,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (line.length < 2) return;
    final plotHeight = plot.height;

    canvas.save();
    // Room for round caps and mark dots, except at the sides of a zoomed plot.
    final side = zoomed ? 0.0 : 6.0;
    canvas.clipRect(Rect.fromLTRB(-side, -6, plot.width + side, plotHeight + 6));

    if (measure case (final a, final b)) {
      canvas.drawRect(Rect.fromLTRB(a.dx, 0, b.dx, plotHeight), Paint()..color = color.withValues(alpha: 0.08));
    }

    final linePath = _smoothPath(line);
    final areaPath = Path.from(linePath)
      ..lineTo(line.last.dx, plotHeight)
      ..lineTo(line.first.dx, plotHeight)
      ..close();
    canvas.drawPath(
      areaPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.35), color.withValues(alpha: 0.0)],
        ).createShader(Rect.fromLTWH(0, 0, plot.width, plotHeight)),
    );

    if (compare.length >= 2) {
      canvas.drawPath(
        _dashed(_smoothPath(compare)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..strokeCap = StrokeCap.round
          ..color = compareColor.withValues(alpha: 0.8),
      );
    }

    canvas.drawPath(
      linePath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = lineWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );

    for (final (center, kind) in marks) {
      final fill = switch (kind) {
        ChartMarkKind.buy => up,
        ChartMarkKind.sell => down,
        ChartMarkKind.other => textSecondary,
      };
      canvas.drawCircle(center, 5, Paint()..color = ring);
      canvas.drawCircle(center, 3.5, Paint()..color = fill);
    }
    canvas.restore();

    for (final (x, label) in ticks) {
      final tp = _text(label, TextStyle(color: textTertiary, fontSize: 10));
      tp.paint(canvas, Offset((x - tp.width / 2).clamp(0.0, math.max(0.0, size.width - tp.width)), plotHeight + 4));
    }

    for (final (center, label, above) in extremes) {
      canvas.drawCircle(center, 3, Paint()..color = color);
      final tp = _text(label, TextStyle(color: textSecondary, fontSize: 10, fontWeight: FontWeight.w600));
      final dx = (center.dx - tp.width / 2).clamp(0.0, math.max(0.0, size.width - tp.width)).toDouble();
      final dy = above ? center.dy - tp.height - 4 : center.dy + 4;
      tp.paint(canvas, Offset(dx, dy.clamp(0.0, math.max(0.0, plotHeight - tp.height))));
    }

    if (measure case (final a, final b)) {
      _rule(canvas, a.dx, plotHeight);
      _rule(canvas, b.dx, plotHeight);
      _dot(canvas, a);
      _dot(canvas, b);
    }

    if (scrub case final point?) {
      _rule(canvas, point.dx, plotHeight);
      _dot(canvas, point);
    }
  }

  TextPainter _text(String text, TextStyle style) =>
      TextPainter(text: TextSpan(text: text, style: style), textDirection: textDirection)..layout();

  void _rule(Canvas canvas, double x, double height) {
    final paint = Paint()
      ..color = textSecondary.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    const dash = 4.0, gap = 3.0;
    for (var y = 0.0; y < height; y += dash + gap) {
      canvas.drawLine(Offset(x, y), Offset(x, math.min(y + dash, height)), paint);
    }
  }

  void _dot(Canvas canvas, Offset center) {
    canvas.drawCircle(center, 5, Paint()..color = color);
    canvas.drawCircle(
      center,
      5,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  /// [path] drawn as 5pt dashes with 4pt gaps.
  Path _dashed(Path path) {
    final out = Path();
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 9) {
        out.addPath(metric.extractPath(d, math.min(d + 5, metric.length)), Offset.zero);
      }
    }
    return out;
  }

  /// Builds a smooth path through [points] via monotone cubic (Fritsch-Carlson)
  /// interpolation (Swift Charts' `.monotone`). Unlike uniform Catmull-Rom it
  /// respects uneven x spacing, so it never overshoots a point or loops back
  /// where samples are irregularly spaced in time.
  Path _smoothPath(List<Offset> points) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    final n = points.length;
    if (n == 2) {
      path.lineTo(points[1].dx, points[1].dy);
      return path;
    }

    // Secant slope of each segment; a zero-width segment counts as flat.
    final secants = List<double>.generate(n - 1, (i) {
      final dx = points[i + 1].dx - points[i].dx;
      return dx == 0 ? 0 : (points[i + 1].dy - points[i].dy) / dx;
    });

    // Tangent at each point: zero at local extrema, harmonic mean of the
    // neighbouring secants (weighted by segment width) elsewhere.
    final tangents = List<double>.filled(n, 0);
    tangents[0] = secants.first;
    tangents[n - 1] = secants.last;
    for (var i = 1; i < n - 1; i++) {
      final s0 = secants[i - 1];
      final s1 = secants[i];
      if (s0 * s1 <= 0) continue;
      final h0 = points[i].dx - points[i - 1].dx;
      final h1 = points[i + 1].dx - points[i].dx;
      final w0 = 2 * h1 + h0;
      final w1 = h1 + 2 * h0;
      tangents[i] = (w0 + w1) / (w0 / s0 + w1 / s1);
    }

    for (var i = 0; i < n - 1; i++) {
      final p1 = points[i];
      final p2 = points[i + 1];
      final third = (p2.dx - p1.dx) / 3;
      path.cubicTo(
        p1.dx + third,
        p1.dy + tangents[i] * third,
        p2.dx - third,
        p2.dy - tangents[i + 1] * third,
        p2.dx,
        p2.dy,
      );
    }
    return path;
  }

  // Rebuilt only when the chart's widget rebuilds, and cheap to draw.
  @override
  bool shouldRepaint(covariant _PriceChartPainter oldDelegate) => true;
}
