import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qima/models/asset.dart';
import 'package:qima/models/money.dart';
import 'package:qima/services/quote_provider.dart';

void main() {
  const gold = Instrument(id: 'metal.XAU', symbol: 'XAU', assetClass: AssetClass.metal, nameKey: 'asset.gold');

  group('GoldAPIProvider', () {
    test('sends a browser User-Agent, since gold-api.com rate-limits the Dart default', () async {
      String? userAgent;
      final client = MockClient((request) async {
        userAgent = request.headers['User-Agent'];
        return http.Response('{"price": 4153.0}', 200);
      });

      final price = await GoldAPIProvider(client: client).canonicalUSDPrice(gold);

      expect(price, 4153.0);
      expect(userAgent, isNotNull);
      expect(userAgent, isNot(startsWith('Dart/')));
    });

    test('throws on a 429 so the refresh records no stale price', () async {
      final client = MockClient((_) async => http.Response('Too Many Requests', 429));

      expect(
        GoldAPIProvider(client: client).canonicalUSDPrice(gold),
        throwsA(isA<PriceError>().having((e) => e.kind, 'kind', 'invalidResponse')),
      );
    });
  });

  group('YahooQuoteProvider.listing', () {
    const share = Instrument(id: 'stock.ZD', symbol: 'ZD', assetClass: AssetClass.stock, nameKey: 'ZD', sourceSymbol: 'ZD');

    Future<Listing> read(String meta) {
      final client = MockClient((request) async => http.Response('{"chart":{"result":[{"meta":$meta}]}}', 200));
      return YahooQuoteProvider(FXRates(base: 'USD', rates: const {'SAR': 4.0}, updatedAt: DateTime.utc(2026)), client: client).listing(share);
    }

    test('says what the feed has under a symbol: its name, exchange and currency', () async {
      final listing = await read(
        '{"regularMarketPrice":50.0,"currency":"USD","shortName":"Zed Utilities Inc.","longName":"Zed Utilities Incorporated","fullExchangeName":"Northport","exchangeName":"NPT"}',
      );
      expect(listing.canonicalUSD, 50.0);
      expect(listing.name, 'Zed Utilities Inc.');
      expect(listing.exchange, 'Northport');
      expect(listing.currency, 'USD');
      expect(listing.isDescribed, isTrue);
    });

    test('prices a share in another currency in dollars and still names that currency', () async {
      final listing = await read('{"regularMarketPrice":20.0,"currency":"SAR","longName":"Dune Oil Company","exchangeName":"DNE"}');
      expect(listing.canonicalUSD, 5.0);
      expect(listing.name, 'Dune Oil Company');
      expect(listing.exchange, 'DNE');
      expect(listing.currency, 'SAR');
    });

    test('a feed that names nothing gives a price alone', () async {
      final listing = await read('{"regularMarketPrice":50.0,"currency":"USD","shortName":" "}');
      expect(listing.isDescribed, isFalse);
    });

    Future<Listing> readChart(String result, {String symbol = 'COMI.CA'}) {
      final client = MockClient((request) async => http.Response('{"chart":{"result":[$result]}}', 200));
      final rates = FXRates(base: 'USD', rates: const {'EGP': 50.0}, updatedAt: DateTime.utc(2026));
      return YahooQuoteProvider(rates, client: client)
          .listing(Instrument(id: 'stock.$symbol', symbol: symbol, assetClass: AssetClass.stock, nameKey: symbol));
    }

    test('a headline price older than the last daily close gives way to the close', () async {
      final listing = await readChart(
        '{"meta":{"regularMarketPrice":80.0,"regularMarketTime":1721764800,"currency":"EGP"},'
        '"timestamp":[1795420800,1795507200,1795593600],"indicators":{"quote":[{"close":[126.5,125.0,null]}]}}',
      );
      expect(listing.canonicalUSD, 2.5);
    });

    test('a live headline price stands over the bar of the session it belongs to', () async {
      final listing = await readChart(
        '{"meta":{"regularMarketPrice":100.0,"regularMarketTime":1795609199,"currency":"EGP"},'
        '"timestamp":[1795507200,1795593600],"indicators":{"quote":[{"close":[125.0,99.0]}]}}',
      );
      expect(listing.canonicalUSD, 2.0);
    });

    test('a listing the feed gives no currency is priced in its exchange currency', () async {
      final listing = await readChart('{"meta":{"regularMarketPrice":150.0,"regularMarketTime":1795609199,"currency":null}}');
      expect(listing.canonicalUSD, 3.0);
      expect(listing.currency, 'EGP');
    });

    test('no currency and no exchange to read one from is not a price', () {
      expect(
        readChart('{"meta":{"regularMarketPrice":150.0}}', symbol: 'ZD'),
        throwsA(isA<PriceError>().having((e) => e.kind, 'kind', 'decodingFailed')),
      );
    });
  });

  group('YahooHistoryProvider.bars', () {
    String chart({required String quote}) =>
        '{"chart":{"result":[{"meta":{"currency":"USD"},"timestamp":[1700000000,1700000900,1700001800],"indicators":{"quote":[$quote]}}]}}';

    Future<List<Bar>> read(String quote) {
      final client = MockClient((request) async => http.Response(chart(quote: quote), 200));
      return YahooHistoryProvider(client: client).bars('ZZTEST');
    }

    test('reads each bar\'s high and low beside its close', () async {
      final bars = await read('{"close":[10.0,12,11.5],"high":[10.0,14,12.5],"low":[10.0,9.5,11]}');
      expect(bars.map((b) => b.close), [10.0, 12.0, 11.5]);
      expect(bars.map((b) => b.high), [10.0, 14.0, 12.5]);
      expect(bars.map((b) => b.low), [10.0, 9.5, 11.0]);
    });

    test('reads the feed\'s own latest price and when it traded, when it gives them', () async {
      const body = '{"chart":{"result":[{"meta":{"currency":"USD","regularMarketPrice":3698.1,"regularMarketTime":1700009000},'
          '"timestamp":[1700000000],"indicators":{"quote":[{"close":[3620.4]}]}}]}}';
      final provider = YahooHistoryProvider(client: MockClient((request) async => http.Response(body, 200)));
      final history = await provider.history('ZZTEST');
      expect(history.bars.single.close, 3620.4);
      expect(history.latest!.close, 3698.1);
      expect(history.latest!.date, DateTime.fromMillisecondsSinceEpoch(1700009000 * 1000, isUtc: true));

      final without = YahooHistoryProvider(client: MockClient((request) async => http.Response(chart(quote: '{"close":[1,2,3]}'), 200)));
      expect((await without.history('ZZTEST')).latest, isNull);
    });

    test('missing high and low arrays, or null entries, give null', () async {
      final without = await read('{"close":[10.0,12,11.5]}');
      expect(without.map((b) => b.high), [null, null, null]);
      expect(without.map((b) => b.low), [null, null, null]);

      final partial = await read('{"close":[10.0,12,11.5],"high":[10.0,null],"low":[null,9.5,11]}');
      expect(partial.map((b) => b.high), [10.0, null, null]);
      expect(partial.map((b) => b.low), [null, 9.5, 11.0]);
    });

    test('a bar with no close is skipped, whatever its high and low', () async {
      final bars = await read('{"close":[10.0,null,11.5],"high":[10.0,99,12.5],"low":[10.0,1,11]}');
      expect(bars, hasLength(2));
      expect(bars.map((b) => b.high), [10.0, 12.5]);
    });
  });
}
