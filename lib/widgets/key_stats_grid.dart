import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/display_point.dart';
import '../models/money.dart';
import '../theme/design_system.dart';
import '../theme/qima_colors.dart';
import '../theme/strings.dart';
import 'stat_pill.dart';

/// A low-to-high span with where the price sits in it, all in one currency.
class PriceSpan {
  final double low;
  final double high;
  final double current;

  const PriceSpan({required this.low, required this.high, required this.current});

  /// Where [current] sits, from 0 at [low] to 1 at [high].
  double get position => high <= low ? 0.5 : ((current - low) / (high - low)).clamp(0.0, 1.0);
}

/// "Key stats" on the instrument detail screen: the change, high and low
/// over the selected range, plus what the exchange adds for a stock or
/// index — the previous close, the dividend yield, and where today's price
/// sits in the day's and the year's ranges (spec §v2-A "Instrument
/// detail").
class KeyStatsGrid extends StatelessWidget {
  final List<DisplayPoint> windowed;
  final double? changePercent;
  final bool? changeIsUp;
  final String currencyCode;
  final double? previousClose;
  final double? dividendYield;
  final PriceSpan? daySpan;
  final PriceSpan? yearSpan;

  const KeyStatsGrid({
    super.key,
    required this.windowed,
    required this.changePercent,
    required this.changeIsUp,
    required this.currencyCode,
    this.previousClose,
    this.dividendYield,
    this.daySpan,
    this.yearSpan,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.colors;
    final high = windowed.isEmpty ? null : windowed.map((p) => p.value).reduce((a, b) => a > b ? a : b);
    final low = windowed.isEmpty ? null : windowed.map((p) => p.value).reduce((a, b) => a < b ? a : b);
    String price(double? v) => v == null ? '—' : Money(v, currencyCode).formatted();

    final pills = [
      StatPill(
        title: l10n.statChange,
        value: changePercent == null
            ? '—'
            : signedFigure('${(changePercent! * 100).toStringAsFixed(2)}%', isUp: changeIsUp ?? true),
        tint: changePercent == null ? null : QimaColors.trendColor(changeIsUp ?? true, colors),
      ),
      if (previousClose != null) StatPill(title: l10n.statPreviousClose, value: price(previousClose)),
      StatPill(title: l10n.statHigh, value: price(high)),
      StatPill(title: l10n.statLow, value: price(low)),
      if (dividendYield != null) StatPill(title: l10n.statDividendYield, value: '${(dividendYield! * 100).toStringAsFixed(2)}%'),
    ];

    return DSCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.detailKeyStats, style: TextStyle(color: colors.textPrimary, fontWeight: FontWeight.w700)),
          const SizedBox(height: DS.spaceSM),
          GridView(
            shrinkWrap: true,
            // Without this the grid inherits the screen's safe-area inset as
            // bottom padding, leaving an empty band at the foot of the card.
            padding: EdgeInsets.zero,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              // Room for Arabic's taller small text (Almarai) as well as SF.
              mainAxisExtent: 52,
              mainAxisSpacing: DS.spaceSM,
              crossAxisSpacing: DS.spaceMD,
            ),
            children: pills,
          ),
          if (daySpan case final span?) ...[
            const SizedBox(height: DS.spaceSM),
            _SpanBar(key: const ValueKey('daySpan'), title: l10n.statDayRange, span: span, format: price),
          ],
          if (yearSpan case final span?) ...[
            const SizedBox(height: DS.spaceSM),
            _SpanBar(key: const ValueKey('yearSpan'), title: l10n.statYearRange, span: span, format: price),
          ],
        ],
      ),
    );
  }
}

/// A titled track from low to high with a dot where the price is.
class _SpanBar extends StatelessWidget {
  final String title;
  final PriceSpan span;
  final String Function(double?) format;

  const _SpanBar({super.key, required this.title, required this.span, required this.format});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final small = TextStyle(color: colors.textTertiary, fontSize: 11);
    return Semantics(
      label: '$title: ${format(span.low)} – ${format(span.high)}',
      value: format(span.current),
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: TextStyle(color: colors.textSecondary, fontSize: 12)),
          const SizedBox(height: 6),
          // Low to high reads left to right in every language, like the chart.
          Directionality(
            textDirection: TextDirection.ltr,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 10,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final x = span.position * (constraints.maxWidth - 10);
                      return Stack(
                        children: [
                          Positioned(
                            left: 0,
                            right: 0,
                            top: 4,
                            child: Container(
                              height: 2,
                              decoration: BoxDecoration(color: colors.hairlineStrong, borderRadius: BorderRadius.circular(1)),
                            ),
                          ),
                          Positioned(
                            left: x,
                            top: 0,
                            child: Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(color: colors.brand, shape: BoxShape.circle),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(child: Text(format(span.low), style: small)),
                    Text(format(span.high), style: small),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
