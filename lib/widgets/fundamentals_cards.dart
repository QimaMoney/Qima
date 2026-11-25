import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../models/instrument_fundamentals.dart';
import '../theme/design_system.dart';
import '../theme/figure_format.dart';
import '../theme/qima_colors.dart';
import 'key_stats_grid.dart';
import 'stat_pill.dart';

/// How the market values a stock: market cap, enterprise value, the price
/// ratios and beta, each shown only when the exchange publishes it.
class ValuationCard extends StatelessWidget {
  final InstrumentFundamentals fundamentals;

  const ValuationCard({super.key, required this.fundamentals});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final locale = Localizations.localeOf(context).toString();
    final f = fundamentals;
    return _FiguresCard(
      key: const ValueKey('valuationCard'),
      title: l10n.valuationTitle,
      pills: [
        if (f.marketCap case final v?) StatPill(title: l10n.statMarketCap, value: reportedMoney(v, locale)),
        if (f.enterpriseValue case final v?) StatPill(title: l10n.statEnterpriseValue, value: reportedMoney(v, locale)),
        if (f.peRatio case final v?) StatPill(title: l10n.statPeRatio, value: ratioFigure(v)),
        if (f.forwardPe case final v?) StatPill(title: l10n.statForwardPe, value: ratioFigure(v)),
        if (f.pegRatio case final v?) StatPill(title: l10n.statPegRatio, value: ratioFigure(v)),
        if (f.priceToSales case final v?) StatPill(title: l10n.statPriceToSales, value: ratioFigure(v)),
        if (f.priceToBook case final v?) StatPill(title: l10n.statPriceToBook, value: ratioFigure(v)),
        if (f.evToEbitda case final v?) StatPill(title: l10n.statEvToEbitda, value: ratioFigure(v)),
        if (f.beta case final v?) StatPill(title: l10n.statBeta, value: ratioFigure(v)),
      ],
    );
  }
}

/// The company's latest reported results: the year's revenue, profit and
/// cash flow, and the balance sheet at the quarter's end.
class FinancialsCard extends StatelessWidget {
  final InstrumentFundamentals fundamentals;

  const FinancialsCard({super.key, required this.fundamentals});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final locale = Localizations.localeOf(context).toString();
    final f = fundamentals;
    final reported = f.reportedAt;
    return _FiguresCard(
      key: const ValueKey('financialsCard'),
      title: l10n.financialsTitle,
      subtitle: reported == null ? null : l10n.financialsAsOf((DateFormat.yMMMd(locale)..useNativeDigits = false).format(reported)),
      pills: [
        if (f.revenue case final v?) StatPill(title: l10n.statRevenue, value: reportedMoney(v, locale)),
        if (f.netIncome case final v?) StatPill(title: l10n.statNetIncome, value: reportedMoney(v, locale)),
        if (f.profitMargin case final v?) StatPill(title: l10n.statProfitMargin, value: percentFigure(v)),
        if (f.eps case final v?) StatPill(title: l10n.statEps, value: reportedMoney(v, locale)),
        if (f.returnOnEquity case final v?) StatPill(title: l10n.statReturnOnEquity, value: percentFigure(v)),
        if (f.returnOnAssets case final v?) StatPill(title: l10n.statReturnOnAssets, value: percentFigure(v)),
        if (f.cash case final v?) StatPill(title: l10n.statCash, value: reportedMoney(v, locale)),
        if (f.debtToEquity case final v?) StatPill(title: l10n.statDebtToEquity, value: percentFigure(v)),
        if (f.freeCashFlow case final v?) StatPill(title: l10n.statFreeCashFlow, value: reportedMoney(v, locale)),
      ],
    );
  }
}

class _FiguresCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> pills;

  const _FiguresCard({super.key, required this.title, this.subtitle, required this.pills});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DSCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: TextStyle(color: colors.textPrimary, fontWeight: FontWeight.w700)),
          if (subtitle != null) Text(subtitle!, style: TextStyle(color: colors.textTertiary, fontSize: 12)),
          const SizedBox(height: DS.spaceSM),
          StatGrid(pills: pills),
        ],
      ),
    );
  }
}
