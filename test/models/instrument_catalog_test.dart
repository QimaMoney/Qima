import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/asset.dart';
import 'package:qima/l10n/app_localizations.dart';
import 'package:qima/models/custom_instrument.dart';
import 'package:qima/models/instrument_catalog.dart';
import 'package:qima/models/market_hours.dart';
import 'package:qima/models/market_listings.dart';
import 'package:qima/theme/strings.dart';

void main() {
  test('instruments(ids:) drops unresolvable ids while preserving order (TC-I4)', () {
    final result = InstrumentCatalog.instruments(['metal.XAU', 'bogus.ID', 'crypto.BTC', 'metal.XAG']);
    expect(result.map((i) => i.id).toList(), ['metal.XAU', 'crypto.BTC', 'metal.XAG']);
  });

  test('instruments(ids:) never throws on all-unresolvable input', () {
    expect(() => InstrumentCatalog.instruments(['nope', 'also.nope']), returnsNormally);
    expect(InstrumentCatalog.instruments(['nope']), isEmpty);
  });

  test('built-ins win on id clash with custom instruments', () {
    InstrumentCatalog.reloadCustom([
      InstrumentCatalog.metals.first.copyWith(nameKey: 'hijacked'),
    ]);
    addTearDown(() => InstrumentCatalog.reloadCustom(const []));
    final resolved = InstrumentCatalog.instrument('metal.XAU');
    expect(resolved!.nameKey, 'asset.gold');
  });

  group('market listings', () {
    final listings = [
      ...MarketListings.usStocks,
      ...MarketListings.saudiStocks,
      ...MarketListings.egyptStocks,
      ...MarketListings.usIndices,
      ...MarketListings.saudiIndices,
      ...MarketListings.egyptIndices,
    ];

    test('Saudi and Egyptian shares and indices, and more of Nasdaq, are built in', () {
      const ids = ['stock.2222.SR', 'stock.COMI.CA', 'stock.NFLX', 'index.^TASI.SR', 'index.^CASE30', 'index.^NDX'];
      final builtIn = InstrumentCatalog.builtIn.map((i) => i.id).toSet();
      expect(ids.where((id) => !builtIn.contains(id)), isEmpty);
    });

    test('no two built-ins share an id or a feed symbol', () {
      final all = InstrumentCatalog.builtIn;
      expect(all.map((i) => i.id).toSet(), hasLength(all.length));
      final quoted = all.where((i) => i.assetClass == AssetClass.stock || i.assetClass == AssetClass.indices);
      expect(quoted.map((i) => i.sourceSymbol).toSet(), hasLength(quoted.length));
    });

    test('a listing takes the id a custom ticker for its symbol has, so one added by hand carries over', () {
      for (final listing in listings) {
        final custom = CustomInstrument(symbol: listing.sourceSymbol, assetClass: listing.assetClass);
        expect(listing.id, custom.instrumentID, reason: listing.nameKey);
      }
    });

    test('each trades on its own market', () {
      Set<Market?> marketsOf(List<Instrument> list) => list.map(MarketHours.marketOf).toSet();
      expect(marketsOf([...MarketListings.usStocks, ...MarketListings.usIndices]), {Market.us});
      expect(marketsOf([...MarketListings.saudiStocks, ...MarketListings.saudiIndices]), {Market.tadawul});
      expect(marketsOf([...MarketListings.egyptStocks, ...MarketListings.egyptIndices]), {Market.egx});
    });

    test('every listing has an Arabic name and reads in English elsewhere', () {
      final names = listings.map((i) => i.nameKey).toSet();
      expect(names, hasLength(listings.length));
      expect(MarketListings.arabicNames.keys.toSet(), names);
      expect(displayLabelFor(lookupAppLocalizations(const Locale('ar')), 'Saudi Aramco'), 'أرامكو السعودية');
      expect(displayLabelFor(lookupAppLocalizations(const Locale('fr')), 'Saudi Aramco'), 'Saudi Aramco');
      expect(labelsInAllLocales('Fawry'), unorderedEquals(['Fawry', 'فوري']));
    });
  });
}
