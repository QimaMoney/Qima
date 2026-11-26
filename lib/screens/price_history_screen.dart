import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../blocs/market_cubit.dart';
import '../blocs/market_state.dart';
import '../l10n/app_localizations.dart';
import '../models/market_hours.dart';
import '../models/price_bar.dart';
import '../models/watch_card.dart';
import '../theme/design_system.dart';
import '../theme/qima_colors.dart';
import '../theme/strings.dart';
import '../widgets/price_history.dart';
import '../widgets/section_header.dart';

/// What a price did each day, month or year, as far back as its history
/// goes: open, close, high, low, average and median, in the card's
/// currency and unit. A wide window shows a table instead of rows.
class PriceHistoryScreen extends StatefulWidget {
  final WatchCard card;
  final BarPeriod initialPeriod;

  const PriceHistoryScreen({super.key, required this.card, this.initialPeriod = BarPeriod.month});

  @override
  State<PriceHistoryScreen> createState() => _PriceHistoryScreenState();
}

class _PriceHistoryScreenState extends State<PriceHistoryScreen> {
  late BarPeriod _period = widget.initialPeriod;

  /// History the screen wants reaching back at least this far before it
  /// asks for the full download.
  static const Duration _wantedDepth = Duration(days: 300);

  @override
  void initState() {
    super.initState();
    // Once per visit: a listing younger than the wanted depth never reaches
    // back that far, and must not be downloaded again on every rebuild.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final cubit = context.read<MarketCubit>();
      final presentation = cubit.presentation(widget.card);
      final points = presentation.points;
      final deep = points.length >= 2 && !points.first.date.isAfter(DateTime.now().subtract(_wantedDepth));
      if (!deep) cubit.loadHistory(presentation.instrument, widget.card.currency);
    });
  }

  /// [bars] (oldest first) newest first, in groups under a heading: days by
  /// month, months by year, and years in one group with none.
  List<(String?, List<PriceBar>)> _groups(BuildContext context, List<PriceBar> bars) {
    if (_period == BarPeriod.year) return [(null, bars.reversed.toList())];
    final locale = Localizations.localeOf(context).toString();
    final within = _period == BarPeriod.day ? BarPeriod.month : BarPeriod.year;
    final format = (within == BarPeriod.month ? DateFormat.yMMMM(locale) : DateFormat.y(locale))..useNativeDigits = false;
    final groups = <(String?, List<PriceBar>)>[];
    DateTime? current;
    for (final bar in bars.reversed) {
      final start = within.startOf(bar.start);
      if (start != current) {
        current = start;
        groups.add((format.format(start), []));
      }
      groups.last.$2.add(bar);
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.colors;
    final cubit = context.read<MarketCubit>();

    return BlocBuilder<MarketCubit, MarketState>(
      builder: (context, state) {
        final presentation = cubit.presentation(widget.card);
        final instrument = presentation.instrument;
        final now = DateTime.now();
        final currency = presentation.displayCurrency;
        final groups = _groups(
          context,
          PriceBars.build(presentation.points, _period, now: now, market: MarketHours.marketOf(instrument)),
        );
        final unit = presentation.unitSuffix;
        final subtitle = '${displayLabel(context, instrument.nameKey)} · $currency'
            '${unit != null ? ' / ${displayLabel(context, unit)}' : ''}';

        return ScreenBackground(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              title: Text(l10n.historyTitle),
              bottom: state.isLoadingHistory
                  ? PreferredSize(
                      preferredSize: const Size.fromHeight(2),
                      child: Semantics(
                        label: l10n.chartLoadingOlder,
                        child: LinearProgressIndicator(minHeight: 2, color: colors.brand, backgroundColor: Colors.transparent),
                      ),
                    )
                  : null,
            ),
            body: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= PriceHistoryTable.minWidth + 2 * DS.spaceMD;
                return ListView.builder(
                  padding: EdgeInsets.fromLTRB(
                    DS.spaceMD,
                    DS.spaceSM,
                    DS.spaceMD,
                    DS.spaceMD + MediaQuery.paddingOf(context).bottom,
                  ),
                  // The heading, then one card per group, built as it scrolls
                  // into view: five years of days is some sixty cards.
                  itemCount: groups.isEmpty ? 2 : groups.length + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(subtitle, style: TextStyle(color: colors.textSecondary, fontSize: 13)),
                          const SizedBox(height: DS.spaceSM),
                          Align(
                            alignment: wide ? AlignmentDirectional.centerStart : Alignment.center,
                            child: SizedBox(
                              width: wide ? 320 : double.infinity,
                              child: HistoryPeriodSwitch(
                                selected: _period,
                                onSelected: (period) => setState(() => _period = period),
                              ),
                            ),
                          ),
                          const SizedBox(height: DS.spaceMD),
                        ],
                      );
                    }
                    if (groups.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.only(top: DS.spaceXL),
                        child: state.isLoadingHistory
                            ? const Center(child: CircularProgressIndicator())
                            : Text(
                                l10n.detailNoHistoryTitle,
                                textAlign: TextAlign.center,
                                style: TextStyle(color: colors.textSecondary),
                              ),
                      );
                    }
                    final (heading, bars) = groups[index - 1];
                    return Padding(
                      // Keyed by period and heading so an open row never
                      // carries over to another list.
                      key: ValueKey('historyGroup.${_period.name}.$heading'),
                      padding: const EdgeInsets.only(bottom: DS.spaceMD),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (heading != null) SectionHeader(heading),
                          DSCard(
                            padding: const EdgeInsets.symmetric(horizontal: DS.spaceMD, vertical: DS.spaceXS),
                            child: wide
                                ? PriceHistoryTable(bars: bars, currencyCode: currency, now: now)
                                : PriceHistoryRows(
                                    bars: bars,
                                    currencyCode: currency,
                                    now: now,
                                    startsOpen: index == 1,
                                  ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }
}
