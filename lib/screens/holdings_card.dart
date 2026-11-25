import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../blocs/holdings_cubit.dart';
import '../blocs/market_cubit.dart';
import '../blocs/settings_cubit.dart';
import '../l10n/app_localizations.dart';
import '../models/asset.dart';
import '../models/ledger.dart';
import '../models/money.dart';
import '../models/holding_totals.dart';
import '../models/metal_breakdown.dart';
import '../theme/design_system.dart';
import '../theme/masking.dart';
import '../theme/qima_colors.dart';
import '../theme/strings.dart';
import '../widgets/stat_pill.dart';
import 'holdings_screen.dart';

/// Compact holdings summary card on the instrument detail screen: "N
/// transactions ›" plus Value/Gain/Gain % (spec §v2-A "Instrument detail").
/// Tapping it opens the ledger on [HoldingsScreen]. Shows an "add your
/// first" prompt with no transactions, and the realised result once a
/// position has been sold off entirely.
class HoldingsCard extends StatelessWidget {
  final Instrument instrument;
  final String displayCurrency;

  /// The unit/karat of the watch card the user opened this from — used as
  /// the reference for the "Held … · avg …" line and forwarded to
  /// [HoldingsScreen] and the lot editor. Falls back to the instrument's
  /// default unit and no karat when absent.
  final PriceUnit? refUnit;
  final GoldKarat? refKarat;

  const HoldingsCard({
    super.key,
    required this.instrument,
    required this.displayCurrency,
    this.refUnit,
    this.refKarat,
  });

  @override
  Widget build(BuildContext context) {
    final holdings = context.read<HoldingsCubit>();
    final l10n = AppLocalizations.of(context)!;
    final colors = context.colors;
    final unit = refUnit ?? instrument.quotation.defaultUnit;

    // Rebuilt when the hide setting, the ledger or the rates change; not on
    // every price tick.
    final hidden = context.select<SettingsCubit, bool>((c) => c.state.hideBalances);
    final ledger = context.select<HoldingsCubit, Ledger>((c) => c.state.ledger);
    final rates = context.select<MarketCubit, FXRates>((c) => c.state.rates);
    // Recomputed on every rebuild so a saved or deleted transaction shows at
    // once.
    final lots = holdings.lotsFor(instrument);
    final transactionCount = holdings.transactionsFor(instrument).length;
    final position = ledger[instrument.id];
    final valuation = holdings.valuationFor(instrument, displayCurrency);
    final held = HoldingTotals.totalHeld(lots: lots, refUnit: unit, refKarat: refKarat);
    final averageCost = HoldingTotals.averageCost(
      lots: lots,
      refUnit: unit,
      refKarat: refKarat,
      displayCurrency: displayCurrency,
      rates: rates,
    );
    return DSCard(
      child: InkWell(
        borderRadius: BorderRadius.circular(DS.radiusCard),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => HoldingsScreen(
              instrument: instrument,
              displayCurrency: displayCurrency,
              refUnit: refUnit,
              refKarat: refKarat,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(l10n.detailHoldings,
                    style: TextStyle(color: colors.textPrimary, fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(width: DS.spaceMD),
                Text(
                  l10n.portfolioTransactionCount(transactionCount),
                  style: TextStyle(color: colors.textTertiary, fontSize: 13),
                ),
                const Spacer(),
                Icon(Icons.chevron_right, color: colors.textTertiary),
              ],
            ),
            if (valuation == null)
              Padding(
                padding: const EdgeInsets.only(top: DS.spaceSM),
                child: Text(
                  transactionCount == 0 || position == null
                      ? l10n.holdingsEmpty
                      : l10n.ledgerClosedLine(Masking.signedAmount(
                          position.realised.inCurrency(displayCurrency, rates),
                          hidden: hidden,
                          isUp: position.realised.inCurrency(displayCurrency, rates).amount >= 0,
                        )),
                  style: TextStyle(color: colors.textTertiary),
                ),
              )
            else ...[
              if (averageCost != null) ...[
                const SizedBox(height: 2),
                Text(
                  l10n.holdingsHeldLine(
                    hidden ? Masking.mask : quantityWithUnitKaratLabel(context, held, unit, refKarat),
                    Masking.amount(averageCost, hidden: hidden),
                  ),
                  style: TextStyle(color: colors.textTertiary, fontSize: 12),
                ),
              ],
              const SizedBox(height: DS.spaceSM),
              Row(
                children: [
                  Expanded(child: StatPill(title: l10n.holdingsValue, value: Masking.amount(valuation.value, hidden: hidden))),
                  const SizedBox(width: DS.spaceMD),
                  Expanded(
                    child: StatPill(
                      title: l10n.holdingsGain,
                      value: Masking.signedAmount(valuation.gain, hidden: hidden, isUp: valuation.isUp),
                      tint: QimaColors.trendColor(valuation.isUp, colors),
                    ),
                  ),
                  const SizedBox(width: DS.spaceMD),
                  Expanded(
                    child: StatPill(
                      title: l10n.holdingsGainPercent,
                      value: signedFigure('${(valuation.gainFraction * 100).toStringAsFixed(2)}%', isUp: valuation.isUp),
                      tint: QimaColors.trendColor(valuation.isUp, colors),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
