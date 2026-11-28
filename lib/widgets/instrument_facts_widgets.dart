import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../models/instrument_facts.dart';
import '../theme/design_system.dart';
import '../theme/qima_colors.dart';

/// "1,234.5" without trailing zeros: a split's 11 and 10, or 1.5.
String _ratioPart(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

/// Asks how trades before a split should read: restated in today's shares,
/// or already in them. Shown until answered on any device.
class SplitNoticeCard extends StatelessWidget {
  final StockSplit split;
  final VoidCallback onAdjust;
  final VoidCallback onKeep;

  const SplitNoticeCard({super.key, required this.split, required this.onAdjust, required this.onKeep});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.colors;
    final locale = Localizations.localeOf(context).toString();
    final ratio = l10n.splitRatio(_ratioPart(split.numerator), _ratioPart(split.denominator));
    final date = DateFormat.yMMMd(locale).format(split.date.toLocal());
    return DSCard(
      key: const ValueKey('splitNotice'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.call_split, size: 18, color: colors.brandText),
              const SizedBox(width: DS.spaceSM),
              Expanded(
                child: Text(l10n.splitTitle(ratio, date), style: TextStyle(color: colors.textPrimary, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: DS.spaceXS),
          Text(l10n.splitBody, style: TextStyle(color: colors.textSecondary, fontSize: 13)),
          const SizedBox(height: DS.spaceSM),
          Wrap(
            spacing: DS.spaceSM,
            runSpacing: DS.spaceXS,
            children: [
              FilledButton(key: const ValueKey('splitAdjust'), onPressed: onAdjust, child: Text(l10n.splitAdjust)),
              TextButton(key: const ValueKey('splitKeep'), onPressed: onKeep, child: Text(l10n.splitAlreadyAdjusted)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Says when the exchange last traded a price that has gone stale, so it
/// never reads as today's.
class StaleQuoteLine extends StatelessWidget {
  final DateTime lastTraded;

  const StaleQuoteLine({super.key, required this.lastTraded});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.colors;
    final date = DateFormat.yMMMd(Localizations.localeOf(context).toString()).format(lastTraded.toLocal());
    return Row(
      key: const ValueKey('staleQuote'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(Icons.warning_amber_rounded, size: 14, color: colors.down),
        ),
        const SizedBox(width: 4),
        Expanded(child: Text(l10n.factsStale(date), style: TextStyle(color: colors.down, fontSize: 12))),
      ],
    );
  }
}
