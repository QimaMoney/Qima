import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../blocs/settings_cubit.dart';
import '../models/chart_range.dart';

import '../l10n/app_localizations.dart';
import '../models/instrument_presentation.dart';
import '../models/market_hours.dart';
import '../theme/design_system.dart';
import '../theme/price_chart.dart';
import '../theme/qima_colors.dart';
import '../theme/strings.dart';
import 'instrument_icon.dart';
import 'market_status.dart';

/// Watchlist row: icon, name/detail line, a small non-interactive sparkline,
/// and price + windowed change. Mirrors `InstrumentRow.swift`.
class InstrumentRow extends StatelessWidget {
  final InstrumentPresentation presentation;
  final VoidCallback? onTap;

  const InstrumentRow({super.key, required this.presentation, this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final now = DateTime.now();
    // The period is the default chart range from Settings, the same one the
    // charts open on, and it is named beside the change: a percentage with
    // no period says nothing.
    final range = context.select<SettingsCubit, ChartRange>((c) => c.state.preferredChartRange);
    final change = presentation.sparklineChange(now, range: range);
    final sparkline = presentation.sparklinePoints(now, range: range);
    final unitSuffix = presentation.unitSuffix != null ? ' ${displayLabel(context, presentation.unitSuffix!)}' : '';
    final karat = presentation.karatLabel != null ? ' · ${displayLabel(context, presentation.karatLabel!)}' : '';

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(DS.radiusTile),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: DS.spaceSM, horizontal: DS.spaceXS),
        child: Row(
          children: [
            InstrumentIcon(instrument: presentation.instrument),
            const SizedBox(width: DS.spaceSM),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayLabel(context, presentation.instrument.nameKey),
                    style: TextStyle(color: colors.textPrimary, fontSize: 15, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  InstrumentDetailLine(
                    text: '${presentation.symbol} · ${presentation.displayCurrency}$unitSuffix$karat',
                    closed: MarketClosedMark.closed(presentation.instrument, now),
                    style: TextStyle(color: colors.textTertiary, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: DS.spaceSM),
            SizedBox(
              width: 64,
              height: 34,
              child: sparkline.length >= 2
                  ? PriceChartView(
                      points: sparkline,
                      isTrendingUp: change?.isUp ?? presentation.isTrendingUp,
                      accent: QimaColors.trendColor(change?.isUp ?? presentation.isTrendingUp, colors),
                      showsAxes: false,
                      lineWidth: 1.5,
                      market: MarketHours.marketOf(presentation.instrument),
                    )
                  : const SizedBox.shrink(),
            ),
            const SizedBox(width: DS.spaceSM),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  presentation.latestPrice,
                  style: TextStyle(color: colors.textPrimary, fontSize: 15, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                if (change != null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        change.isUp ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                        color: QimaColors.trendColor(change.isUp, colors),
                        size: 16,
                      ),
                      Text(
                        '${(change.percentValue.abs() * 100).toStringAsFixed(2)}%',
                        style: TextStyle(
                            color: QimaColors.trendColor(change.isUp, colors), fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(width: 4),
                      Text(displayLabel(context, range.labelKey), style: TextStyle(color: colors.textTertiary, fontSize: 11)),
                    ],
                  )
                else
                  Text('—', style: TextStyle(color: colors.textTertiary, fontSize: 12)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The symbol line. When "· (moon) Closed" would not fit, the word goes
/// and the moon stays, so the symbol and currency are never cut short.
class InstrumentDetailLine extends StatelessWidget {
  final String text;
  final bool closed;
  final TextStyle style;

  const InstrumentDetailLine({super.key, required this.text, required this.closed, required this.style});

  @override
  Widget build(BuildContext context) {
    Widget line({required bool label}) => Text.rich(
          TextSpan(children: [
            TextSpan(text: text),
            if (closed) ...MarketClosedMark.spans(context, label: label),
          ]),
          style: style,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
    if (!closed) return line(label: false);
    return LayoutBuilder(builder: (context, constraints) {
      final painter = TextPainter(
        text: TextSpan(text: '$text ·    ${AppLocalizations.of(context)!.marketClosed}', style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final fits = painter.width + style.fontSize! <= constraints.maxWidth;
      painter.dispose();
      return line(label: fits);
    });
  }
}
