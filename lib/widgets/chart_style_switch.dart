import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/price_chart.dart';
import '../theme/qima_colors.dart';

/// The line / candles switch beside a price chart.
class ChartStyleSwitch extends StatelessWidget {
  final ChartStyle selected;
  final ValueChanged<ChartStyle> onSelected;

  const ChartStyleSwitch({super.key, required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.colors;
    Widget segment(ChartStyle style, IconData icon, String label) {
      final isSelected = style == selected;
      return Semantics(
        button: true,
        selected: isSelected,
        label: label,
        excludeSemantics: true,
        child: Tooltip(
          message: label,
          child: GestureDetector(
            key: ValueKey('chartStyle.${style.name}'),
            behavior: HitTestBehavior.opaque,
            onTap: isSelected ? null : () => onSelected(style),
            child: Container(
              width: 44,
              height: 36,
              decoration: BoxDecoration(
                color: isSelected ? colors.segmentThumb : null,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Icon(icon, size: 18, color: isSelected ? colors.textPrimary : colors.textSecondary),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: colors.bg1, borderRadius: BorderRadius.circular(9)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          segment(ChartStyle.line, Icons.show_chart, l10n.chartStyleLine),
          segment(ChartStyle.candles, Icons.candlestick_chart, l10n.chartStyleCandles),
        ],
      ),
    );
  }
}
