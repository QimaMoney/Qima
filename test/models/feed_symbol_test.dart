import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/feed_symbol.dart';

void main() {
  group('a ticker as people write it becomes the feed\'s symbol', () {
    test('an exchange in front becomes the feed\'s suffix', () {
      expect(FeedSymbol.candidates('TADAWUL:2222'), ['2222.SR']);
      expect(FeedSymbol.candidates('tadawul: 2222 '), ['2222.SR']);
      expect(FeedSymbol.candidates('EGX:COMI'), ['COMI.CA']);
      expect(FeedSymbol.candidates('DFM:EMAAR'), ['EMAAR.AE']);
      expect(FeedSymbol.candidates('LSE:VOD'), ['VOD.L']);
    });

    test('exchanges of the United States have no suffix', () {
      expect(FeedSymbol.candidates('NASDAQ:AAPL'), ['AAPL']);
      expect(FeedSymbol.candidates('NYSE:KO'), ['KO']);
    });

    test('a Hong Kong code is padded to four digits', () {
      expect(FeedSymbol.candidates('HKEX:5'), ['0005.HK']);
      expect(FeedSymbol.candidates('HKEX:9988'), ['9988.HK']);
    });

    test('a code with no exchange is tried as it is, then on the exchanges of its currency', () {
      expect(FeedSymbol.candidates('2222', currency: 'SAR'), ['2222', '2222.SR']);
      expect(FeedSymbol.candidates('EMAAR', currency: 'AED'), ['EMAAR', 'EMAAR.AE', 'EMAAR.AD']);
      expect(FeedSymbol.candidates('AAPL', currency: 'USD'), ['AAPL']);
      expect(FeedSymbol.candidates('AAPL'), ['AAPL']);
    });

    test('a symbol already written the feed\'s way is left alone', () {
      expect(FeedSymbol.candidates('2222.SR', currency: 'SAR'), ['2222.SR']);
      expect(FeedSymbol.candidates('^GSPC', currency: 'SAR'), ['^GSPC']);
      expect(FeedSymbol.candidates('BRK-B', currency: 'SAR'), ['BRK-B']);
      expect(FeedSymbol.candidates('EURUSD=X', currency: 'EUR'), ['EURUSD=X']);
    });

    test('an exchange it does not know falls back to the code and the currency', () {
      expect(FeedSymbol.candidates('SOMEWHERE:ABC', currency: 'SAR'), ['ABC', 'ABC.SR']);
    });

    test('nothing typed gives nothing, and a stray colon is not an exchange', () {
      expect(FeedSymbol.candidates('  '), isEmpty);
      expect(FeedSymbol.candidates(':2222', currency: 'SAR'), [':2222', ':2222.SR']);
      expect(FeedSymbol.candidates('TADAWUL:'), ['TADAWUL:']);
    });
  });
}
