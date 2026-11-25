import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qima/blocs/app_blocs.dart';
import 'package:qima/blocs/money_cubit.dart';
import 'package:qima/l10n/app_localizations.dart';
import 'package:qima/models/asset.dart';
import 'package:qima/models/book_account.dart';
import 'package:qima/models/fx_history.dart';
import 'package:qima/models/holding.dart';
import 'package:qima/models/instrument_catalog.dart';
import 'package:qima/models/minor_units.dart';
import 'package:qima/models/money.dart';
import 'package:qima/models/money_settings.dart';
import 'package:qima/models/quote.dart';
import 'package:qima/models/zakat_book.dart';
import 'package:qima/screens/money/home_screen.dart';
import 'package:qima/services/local_file_store.dart';
import 'package:qima/services/preferences.dart';
import 'package:qima/services/price_repository.dart';
import 'package:qima/theme/app_theme.dart';
import 'package:qima/theme/money_labels.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/app_blocs.dart';

class _OfflineRepository extends PriceRepository {
  @override
  Future<Map<String, QuoteSeries>> refreshAll(List<Instrument> instruments, {DateTime? now}) async => {};

  @override
  Future<FXHistory> backfillFXHistory(List<String> currencies, {bool force = false, DateTime? now}) async => FXHistory.empty;

  @override
  Future<Map<String, QuoteSeries>> backfillInstruments(List<Instrument> instruments, FXHistory fxHistory,
          {bool force = false, DateTime? now}) async =>
      {};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Home shows the zakat due again when the zakat choices change', (tester) async {
    late AppBlocs blocs;
    late MoneyCubit money;
    await tester.runAsync(() async {
      LocalFileStore.overrideDirectoryForTesting(await Directory.systemTemp.createTemp('qima_home_zakat'));
      SharedPreferences.setMockInitialValues({});
      blocs = AppBlocs(repository: _OfflineRepository());
      final preferences = await Preferences.create();
      blocs.settings.preferences = preferences;
      await blocs.zakat.load(preferences);
      money = MoneyCubit(store: blocs.sync.bookStore, baseCurrency: () => 'USD', rates: () => blocs.market.state.rates);
      await money.load();
      await money.markWhatsNewSeen();
      await money.addAccount(
        BookAccount(id: 'wallet', name: 'Wallet', side: AccountSide.own, type: AccountType.cash, currency: 'USD'),
        opening: MinorUnits.fromMajor(100, 'USD'),
        openedOn: DateTime(2026, 1, 1),
      );
      await money.setFeatures({MoneyFeature.zakat});
    });
    const ouncePriceUSD = 3110.34768; // $100 a gram.
    final gold = InstrumentCatalog.instrument('metal.XAU')!;
    blocs.seed(
      initialized: true,
      baseCurrency: 'USD',
      lots: [
        HoldingLot(id: 'g1', instrumentID: gold.id, quantity: 100, unit: PriceUnit.gram, unitCost: 1, costCurrency: 'USD', date: DateTime(2025)),
      ],
      seriesByID: {
        gold.id: QuoteSeries(instrumentID: gold.id, quotes: [Quote(instrumentID: gold.id, timestamp: DateTime(2026, 10, 1), canonicalUSD: ouncePriceUSD)]),
      },
      rates: FXRates(base: 'USD', rates: const {'USD': 1}, updatedAt: DateTime(2026)),
      fxHistory: FXHistory.empty,
    );
    tester.view.physicalSize = const Size(390, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MultiBlocProvider(
      providers: [...blocs.providers, BlocProvider<MoneyCubit>.value(value: money)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildTheme(Brightness.light),
        home: const HomeScreen(),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 600));
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));

    ZakatOnBook onBook() => ZakatOnBook.of(
          book: money.state.book,
          holdings: blocs.zakat.assessment,
          currency: 'USD',
          rates: blocs.market.state.rates,
        );
    String dueLine(ZakatOnBook z) => l10n.zakatDueLine(moneyText(z.due, 'USD', hidden: false));

    final before = onBook();
    expect(before.due, greaterThan(0), reason: 'the gold is above the nisab');
    expect(find.text(dueLine(before)), findsOneWidget);

    // Leaving the gold out of the zakat choices changes what is due.
    await tester.runAsync(() => blocs.zakat.setSettings(blocs.zakat.state.settings.toggleHolding(gold)));
    await tester.pump(const Duration(milliseconds: 100));

    final after = onBook();
    expect(dueLine(after), isNot(dueLine(before)));
    expect(find.text(dueLine(after)), findsOneWidget);
    expect(find.text(dueLine(before)), findsNothing);

    await tester.runAsync(() async {
      await money.close();
      await blocs.close();
    });
  });
}
