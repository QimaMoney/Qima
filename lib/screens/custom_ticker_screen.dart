import '../models/feed_symbol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../blocs/market_cubit.dart';
import '../blocs/settings_cubit.dart';
import '../blocs/watchlist_cubit.dart';
import '../l10n/app_localizations.dart';
import '../models/asset.dart';
import '../models/custom_instrument.dart';
import '../models/watch_card.dart';
import '../services/quote_provider.dart';
import '../theme/design_system.dart';
import '../theme/help_topics.dart';
import '../theme/qima_colors.dart';
import '../theme/strings.dart';
import '../widgets/help_button.dart';
import 'add_flow_navigation.dart';
import 'currency_picker.dart';

/// Add a custom stock or index/ETF ticker not in the built-in catalog.
/// Mirrors `CustomTickerView.swift`, extended with an asset-class picker
/// (spec §1.8/§4.2 — custom tickers are only allowed for the two
/// Yahoo-quote-routed classes, stock and index/ETF).
class CustomTickerScreen extends StatefulWidget {
  /// Which option the asset-class picker opens on. Defaults to stock to
  /// preserve prior behavior; the "Add custom ticker" entry point in the
  /// Index section of [AddInstrumentScreen] pre-selects [AssetClass.indices]
  /// instead.
  final AssetClass initialAssetClass;

  /// Prefills the symbol field (uppercased), e.g. when arriving here from
  /// the `Add "<query>" as a custom ticker` row in the add-instrument search.
  final String? initialSymbol;

  const CustomTickerScreen({super.key, this.initialAssetClass = AssetClass.stock, this.initialSymbol});

  @override
  State<CustomTickerScreen> createState() => _CustomTickerScreenState();
}

class _CustomTickerScreenState extends State<CustomTickerScreen> {
  final _symbolController = TextEditingController();
  final _nameController = TextEditingController();
  String _currency = 'USD';
  late AssetClass _assetClass;
  bool _isSubmitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _currency = context.read<SettingsCubit>().state.baseCurrency;
    _assetClass = widget.initialAssetClass;
    if (widget.initialSymbol != null) {
      _symbolController.text = widget.initialSymbol!.toUpperCase();
    }
  }

  /// The symbol the feed knows [typed] by: the first of the ways it could be
  /// written there that the feed answers for. A ticker copied with its
  /// exchange in front ("TADAWUL:2222") or typed without one ("2222", in
  /// SAR) is found this way, and comes back with what the feed says it is.
  /// Throws what the last check threw when none is.
  Future<(String, Listing)> _feedSymbol(WatchlistCubit cubit, String typed) async {
    Object? failure;
    for (final candidate in FeedSymbol.candidates(typed, currency: _currency)) {
      try {
        return (candidate, await cubit.lookUpCustomTicker(candidate, assetClass: _assetClass));
      } catch (error) {
        failure = error;
      }
    }
    throw failure ?? StateError('no symbol');
  }

  /// Shows what the feed has under [symbol] and asks whether that is the
  /// one meant. The feed answers for any symbol it knows, and a short one
  /// can be a different company on another exchange ("SR" is not a Saudi
  /// share), so nothing is added on the symbol alone.
  Future<bool> _confirm(String symbol, Listing listing) async {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.colors;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('customTickerConfirm'),
        title: Text(listing.name ?? symbol),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text([symbol, listing.exchange, listing.currency].nonNulls.join(' · '), style: TextStyle(color: colors.textPrimary)),
            const SizedBox(height: DS.spaceSM),
            Text(l10n.addCustomTickerConfirmBody, style: TextStyle(color: colors.textSecondary)),
          ],
        ),
        actions: [
          TextButton(
            key: const ValueKey('customTickerConfirmNo'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.addCustomTickerConfirmNo),
          ),
          FilledButton(
            key: const ValueKey('customTickerConfirmYes'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.addCustomTickerSubmit),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    final typed = _symbolController.text.trim();
    if (typed.isEmpty) {
      setState(() => _error = l10n.addCustomTickerSymbolRequired);
      return;
    }
    // The keyboard goes with the form: the fields keep focus through the
    // navigation that follows, and it would stay up over the asset's page.
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _isSubmitting = true;
      _error = null;
    });
    final cubit = context.read<WatchlistCubit>();
    try {
      final (symbol, listing) = await _feedSymbol(cubit, typed);
      if (!mounted) return;
      if (listing.isDescribed && !await _confirm(symbol, listing)) return;
      final typedName = _nameController.text.trim();
      final name = typedName.isEmpty ? listing.name : typedName;
      // Checked BEFORE addCustomTicker (which would make it true
      // unconditionally) so we can tell "this ticker already existed" apart
      // from "this flow just created it" — only the latter should be undone
      // by Undo removing the ticker itself, not just the watchlist card.
      final candidateID = CustomInstrument(symbol: symbol, assetClass: _assetClass).instrumentID;
      final tickerAlreadyExisted = cubit.isCustom(candidateID);
      final instrument = await cubit.addCustomTicker(symbol, name, assetClass: _assetClass);
      final card = WatchCard(
        id: const Uuid().v4(),
        instrumentID: instrument.id,
        currency: _currency,
        unit: instrument.quotation.defaultUnit,
      );
      final result = await cubit.addCard(card);
      if (mounted) {
        completeAdd(
          context,
          result.card,
          created: result.created,
          customInstrumentID: tickerAlreadyExisted ? null : instrument.id,
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = l10n.addCustomTickerError;
        });
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.colors;

    return ScreenBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: Text(l10n.addCustomTickerTitle),
          actions: const [HelpButton(topic: HelpTopicId.customTicker)],
        ),
        body: ListView(
          padding: const EdgeInsets.all(DS.spaceMD),
          children: [
            DSCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _symbolController,
                    textCapitalization: TextCapitalization.characters,
                    autocorrect: false,
                    style: TextStyle(color: colors.textPrimary),
                    decoration: InputDecoration(
                      labelText: l10n.addCustomTickerSymbol,
                      hintText: l10n.addCustomTickerHint,
                      labelStyle: TextStyle(color: colors.textTertiary),
                      filled: true,
                      fillColor: colors.tileTop,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(DS.radiusTile), borderSide: BorderSide.none),
                    ),
                  ),
                  const SizedBox(height: DS.spaceSM),
                  TextField(
                    controller: _nameController,
                    style: TextStyle(color: colors.textPrimary),
                    decoration: InputDecoration(
                      labelText: l10n.addCustomTickerName,
                      labelStyle: TextStyle(color: colors.textTertiary),
                      filled: true,
                      fillColor: colors.tileTop,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(DS.radiusTile), borderSide: BorderSide.none),
                    ),
                  ),
                  const SizedBox(height: DS.spaceSM),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: SegmentedButton<AssetClass>(
                      segments: [
                        ButtonSegment(
                          value: AssetClass.stock,
                          label: Text(displayLabel(context, AssetClass.stock.titleKey)),
                        ),
                        ButtonSegment(
                          value: AssetClass.indices,
                          label: Text(displayLabel(context, AssetClass.indices.titleKey)),
                        ),
                      ],
                      selected: {_assetClass},
                      onSelectionChanged: (s) => setState(() => _assetClass = s.first),
                      showSelectedIcon: false,
                    ),
                  ),
                  const SizedBox(height: DS.spaceSM),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.commonCurrency, style: TextStyle(color: colors.textPrimary)),
                    trailing: Text(_currency, style: TextStyle(color: colors.textSecondary)),
                    onTap: () async {
                      final selected = await CurrencyPicker.show(
                        context,
                        selected: _currency,
                        currencies: context.read<MarketCubit>().state.rates.availableCurrencies,
                      );
                      if (selected != null) setState(() => _currency = selected);
                    },
                  ),
                ],
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: DS.spaceSM),
              Text(_error!, style: TextStyle(color: colors.down)),
            ],
            const SizedBox(height: DS.spaceLG),
            FilledButton(
              onPressed: _isSubmitting ? null : _submit,
              child: _isSubmitting
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(l10n.addCustomTickerSubmit),
            ),
          ],
        ),
      ),
    );
  }
}
