import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/holding_transaction.dart';
import 'package:qima/models/holding_return.dart';
import 'package:qima/models/instrument_facts.dart';
import 'package:qima/models/ledger.dart';
import 'package:qima/models/asset.dart';

void main() {
  final now = DateTime.utc(2026, 11, 25, 12);

  InstrumentFacts facts({DateTime? lastTraded, List<Dividend> dividends = const [], double? price = 100}) => InstrumentFacts(
        currency: 'SAR',
        fetchedAt: now,
        name: 'Example Company',
        price: price,
        previousClose: 98,
        lastTraded: lastTraded ?? now,
        dividends: dividends,
        splits: [StockSplit(date: DateTime.utc(2024, 7, 1), numerator: 11, denominator: 10)],
      );

  group('InstrumentFacts', () {
    test('round-trips through JSON', () {
      final f = facts(dividends: [Dividend(date: DateTime.utc(2026, 5, 1), amount: 1.5)]);
      expect(InstrumentFacts.fromJson(f.toJson()), f);
    });

    test('a price untraded for over a week is stale', () {
      expect(facts(lastTraded: now.subtract(const Duration(days: 6))).isStale(now), isFalse);
      expect(facts(lastTraded: now.subtract(const Duration(days: 8))).isStale(now), isTrue);
    });

    test('the yield counts only the past year of dividends', () {
      final f = facts(dividends: [
        Dividend(date: DateTime.utc(2025, 6, 1), amount: 9),
        Dividend(date: DateTime.utc(2026, 3, 1), amount: 2),
        Dividend(date: DateTime.utc(2026, 9, 1), amount: 3),
      ]);
      expect(f.trailingDividends(now), closeTo(5, 1e-9));
      expect(f.yieldOn(now), closeTo(0.05, 1e-9));
      expect(facts(price: null).yieldOn(now), isNull);
    });

    test('a split is keyed by instrument and day, and states its ratio', () {
      final s = StockSplit(date: DateTime.utc(2024, 7, 1, 6), numerator: 11, denominator: 10);
      expect(s.keyFor('stock.X'), 'stock.X@2024-07-01');
      expect(s.ratio, closeTo(1.1, 1e-12));
    });
  });

  group('HoldingReturn', () {
    HoldingTransaction tx(String id, TransactionKind kind, double qty, double price, DateTime date, {double fee = 0}) => HoldingTransaction(
          id: id,
          instrumentID: 'stock.X',
          kind: kind,
          quantity: qty,
          unit: PriceUnit.each,
          unitPrice: price,
          fee: fee,
          currency: 'USD',
          date: date,
        );
    double same(double amount, String currency) => amount;

    test('a doubling over two years is about 41% a year', () {
      final buy = tx('a', TransactionKind.buy, 10, 100, DateTime.utc(2024, 11, 25, 12));
      final position = Ledger.derive([buy])['stock.X'];
      final r = HoldingReturn.of(
        transactions: [buy],
        position: position,
        dividends: const [],
        dividendCurrency: 'USD',
        value: 2000,
        now: now,
        toDisplay: same,
      )!;
      expect(r.total, closeTo(1000, 1e-9));
      expect(r.fraction, closeTo(1, 1e-9));
      expect(r.yearly, closeTo(0.4142, 1e-3));
    });

    test('dividends count on the shares held before each ex-date; fees count against', () {
      final buy = tx('a', TransactionKind.buy, 10, 100, DateTime.utc(2025, 1, 10), fee: 5);
      final more = tx('b', TransactionKind.buy, 10, 100, DateTime.utc(2025, 8, 1));
      final position = Ledger.derive([buy, more])['stock.X'];
      final r = HoldingReturn.of(
        transactions: [buy, more],
        position: position,
        dividends: [
          Dividend(date: DateTime.utc(2024, 12, 1), amount: 50), // before any were held
          Dividend(date: DateTime.utc(2025, 6, 1), amount: 1), // on 10 shares
          Dividend(date: DateTime.utc(2025, 9, 1), amount: 1), // on 20 shares
        ],
        dividendCurrency: 'USD',
        value: 2000,
        now: now,
        toDisplay: same,
      )!;
      expect(r.dividends, closeTo(30, 1e-9));
      expect(r.paidIn, closeTo(2005, 1e-9));
      expect(r.total, closeTo(2000 + 30 - 2005, 1e-9));
    });

    test('no yearly rate for a short holding or one moved in without a price', () {
      final recent = tx('a', TransactionKind.buy, 1, 100, now.subtract(const Duration(days: 30)));
      expect(
        HoldingReturn.of(
          transactions: [recent],
          position: Ledger.derive([recent])['stock.X'],
          dividends: const [],
          dividendCurrency: 'USD',
          value: 110,
          now: now,
          toDisplay: same,
        )!.yearly,
        isNull,
      );
      final old = tx('a', TransactionKind.buy, 1, 100, DateTime.utc(2023, 1, 1));
      final moved = tx('b', TransactionKind.transferIn, 1, 0, DateTime.utc(2023, 6, 1));
      final r = HoldingReturn.of(
        transactions: [old, moved],
        position: Ledger.derive([old, moved])['stock.X'],
        dividends: const [],
        dividendCurrency: 'USD',
        value: 300,
        now: now,
        toDisplay: same,
      )!;
      expect(r.yearly, isNull);
      expect(r.total, closeTo(200, 1e-9));
    });

    test('xirr needs money both ways', () {
      expect(HoldingReturn.xirr([(date: now, amount: -1)]), isNull);
      expect(HoldingReturn.xirr([(date: DateTime.utc(2025, 11, 25, 12), amount: -100), (date: now, amount: 110)]), closeTo(0.1, 1e-3));
    });
  });
}
