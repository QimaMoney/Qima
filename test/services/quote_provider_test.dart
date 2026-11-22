import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qima/models/asset.dart';
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
