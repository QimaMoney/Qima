import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/asset.dart';
import 'package:qima/models/book_account.dart';
import 'package:qima/models/book_entry.dart';
import 'package:qima/models/entry_builder.dart';
import 'package:qima/models/money.dart';
import 'package:qima/models/holding_entry_codec.dart';
import 'package:qima/models/holding_transaction.dart';
import 'package:qima/models/ledger.dart';
import 'package:qima/models/metal_breakdown.dart';
import '../helpers/old_trade_entry.dart';

int bits(double d) => (ByteData(8)..setFloat64(0, d)).getInt64(0);

HoldingTransaction tx(
  String id,
  TransactionKind kind,
  double quantity,
  double price,
  DateTime date, {
  double fee = 0,
  GoldKarat? karat,
  String currency = 'USD',
  String instrument = 'metal.XAU',
  PriceUnit unit = PriceUnit.gram,
  String note = '',
}) =>
    HoldingTransaction(id: id, instrumentID: instrument, kind: kind, quantity: quantity, unit: unit, karat: karat, unitPrice: price, fee: fee, currency: currency, date: date, note: note);

/// Every field, the doubles bit for bit, and the same again after the entry
/// has been written as JSON and read back.
void expectSame(HoldingTransaction back, HoldingTransaction t) {
  expect(back, t);
  expect(bits(back.quantity), bits(t.quantity));
  expect(bits(back.unitPrice), bits(t.unitPrice));
  expect(bits(back.fee), bits(t.fee));
  expect(back.date.isUtc, t.date.isUtc);
  expect(back.date.microsecondsSinceEpoch, t.date.microsecondsSinceEpoch);
}

void expectRoundTrip(HoldingTransaction t) {
  final entry = HoldingEntryCodec.toEntry(t);
  expectSame(HoldingEntryCodec.fromEntry(entry), t);
  final stored = BookEntry.fromJson(jsonDecode(jsonEncode(entry.toJson())) as Map<String, dynamic>);
  expect(stored, entry);
  expectSame(HoldingEntryCodec.fromEntry(stored), t);
}

void main() {
  final d = DateTime(2026, 3, 12);
  const goldId = 'holding.metal.XAU';

  group('posting', () {
    test('a buy puts quantity and cost on the holding and the cost against Holdings', () {
      final e = HoldingEntryCodec.toEntry(tx('b1', TransactionKind.buy, 100, 71.2, d, fee: 18, karat: GoldKarat.k21, note: 'jeweller'));
      expect(e.id, 'b1');
      expect(e.template, EntryTemplate.holdingBuy);
      expect(e.baseCurrency, 'USD');
      expect(e.note, 'jeweller');
      expect(e.issues, isEmpty);
      final [holding, cash] = e.lines;
      expect((holding.accountId, holding.amount, holding.baseAmount, holding.currency), (goldId, 713800, 713800, 'USD'));
      expect((holding.quantity, holding.commodity, holding.unit, holding.karat, holding.unitPrice, holding.fee), (10000000000, 'metal.XAU', PriceUnit.gram, 21, 71.2, 18.0));
      expect((cash.accountId, cash.amount, cash.quantity, cash.commodity), ('system.holdings', -713800, null, null));
    });

    test('a sell takes the net proceeds out of the holding and puts them in Holdings', () {
      final e = HoldingEntryCodec.toEntry(tx('s1', TransactionKind.sell, 20, 83.6, d, fee: 18));
      expect(e.template, EntryTemplate.holdingSell);
      expect(e.issues, isEmpty);
      final [holding, cash] = e.lines;
      expect((holding.accountId, holding.amount, holding.quantity), (goldId, -165400, -2000000000));
      expect((cash.accountId, cash.amount), ('system.holdings', 165400));
    });

    test('a transfer in carries its cost, or stands alone as a quantity when it has none', () {
      final carried = HoldingEntryCodec.toEntry(tx('i1', TransactionKind.transferIn, 10, 60, d));
      expect(carried.template, EntryTemplate.holdingIn);
      expect(carried.lines.map((l) => (l.accountId, l.amount)), [(goldId, 60000), ('system.holdings', -60000)]);
      expect(carried.issues, isEmpty);

      final unknown = HoldingEntryCodec.toEntry(tx('i2', TransactionKind.transferIn, 10, 0, d));
      expect(unknown.lines, hasLength(1));
      expect((unknown.lines.single.amount, unknown.lines.single.quantity, unknown.lines.single.unitPrice), (0, 1000000000, 0.0));
      expect(unknown.issues, isEmpty);
    });

    test('a transfer out is one line that moves quantity and keeps its fee as a fact', () {
      final e = HoldingEntryCodec.toEntry(tx('o1', TransactionKind.transferOut, 5, 0, d, fee: 2));
      expect(e.template, EntryTemplate.holdingOut);
      expect(e.lines, hasLength(1));
      final line = e.lines.single;
      expect((line.accountId, line.amount, line.baseAmount, line.quantity, line.fee, line.unitPrice), (goldId, 0, 0, -500000000, 2.0, null));
      expect(e.issues, isEmpty);
    });

    test('a fee puts its amount on the holding and against Holdings, with no quantity', () {
      final e = HoldingEntryCodec.toEntry(tx('f1', TransactionKind.fee, 0, 0, d, fee: 12.5));
      expect(e.template, EntryTemplate.holdingFee);
      expect(e.lines.map((l) => (l.accountId, l.amount, l.quantity)), [(goldId, 1250, null), ('system.holdings', -1250, null)]);
      expect(e.lines.first.fee, 12.5);
      expect(e.issues, isEmpty);
    });

    test('a cost in a three-digit or no-digit currency is counted in that currency’s minor units', () {
      expect(HoldingEntryCodec.toEntry(tx('k', TransactionKind.buy, 2, 10.5, d, currency: 'KWD')).lines.first.amount, 21000);
      expect(HoldingEntryCodec.toEntry(tx('j', TransactionKind.buy, 2, 1050, d, currency: 'JPY')).lines.first.amount, 2100);
    });

    test('a buy whose cost rounds to nothing stands alone as a quantity', () {
      final e = HoldingEntryCodec.toEntry(tx('z', TransactionKind.buy, 1, 0, d));
      expect(e.lines, hasLength(1));
      expect(e.issues, isEmpty);
    });

    test('a row that moves nothing has no valid entry, and says so', () {
      final e = HoldingEntryCodec.toEntry(tx('n', TransactionKind.fee, 0, 0, d, fee: 0.001));
      expect(e.issues.map((i) => i.problem), [EntryProblem.zeroLine, EntryProblem.zeroLine]);
      expectRoundTrip(tx('n', TransactionKind.fee, 0, 0, d, fee: 0.001));
    });

    test('a holding entry is only a holding template, and the reader refuses the rest', () {
      final money = BookEntry(id: 'm', date: d, template: EntryTemplate.holdingTrade, baseCurrency: 'USD', lines: const []);
      expect(HoldingEntryCodec.isHoldingEntry(money), isFalse);
      expect(() => HoldingEntryCodec.fromEntry(money), throwsArgumentError);
      expect(HoldingEntryCodec.isHoldingEntry(HoldingEntryCodec.toEntry(tx('b', TransactionKind.buy, 1, 1, d))), isTrue);
    });
  });

  group('round trip', () {
    final rows = <String, HoldingTransaction>{
      'buy': tx('b1', TransactionKind.buy, 100, 71.2, d),
      'buy with a karat, a fee and a note': tx('b2', TransactionKind.buy, 62.5, 78.4, d, fee: 18.25, karat: GoldKarat.k18, note: 'ring'),
      'buy at a time of day': tx('b3', TransactionKind.buy, 3, 9.99, DateTime(2026, 5, 6, 14, 30, 15, 123, 456)),
      'buy in another currency and unit': tx('b4', TransactionKind.buy, 1.5, 2400.75, d, currency: 'SAR', unit: PriceUnit.troyOunce, instrument: 'metal.XAG'),
      'buy of an instrument with no unit but each': tx('b5', TransactionKind.buy, 12, 33.1, d, instrument: 'stock.TEST', unit: PriceUnit.each),
      'sell': tx('s1', TransactionKind.sell, 20, 83.6, d, fee: 18),
      'sell at a karat': tx('s2', TransactionKind.sell, 7.5, 80, d, karat: GoldKarat.k22),
      'transfer in with a cost': tx('i1', TransactionKind.transferIn, 10, 60.5, d),
      'transfer in with no cost': tx('i2', TransactionKind.transferIn, 10, 0, d),
      'transfer in with a fee and no cost': tx('i3', TransactionKind.transferIn, 10, 0, d, fee: 4),
      'transfer out': tx('o1', TransactionKind.transferOut, 5, 0, d),
      'transfer out with a fee': tx('o2', TransactionKind.transferOut, 5, 0, d, fee: 2.5, karat: GoldKarat.k24),
      'transfer out that remembers a price': tx('o3', TransactionKind.transferOut, 5, 66.6, d),
      'fee': tx('f1', TransactionKind.fee, 0, 0, d, fee: 12.5),
      'fee that remembers a quantity and a price': tx('f2', TransactionKind.fee, 3.25, 9.5, d, fee: 12.5),
      'quantity not exact at 1e-8 (0.1 + 0.2)': tx('q1', TransactionKind.buy, 0.1 + 0.2, 50, d),
      'quantity not exact at 1e-8 (a third)': tx('q2', TransactionKind.sell, 1 / 3, 50, d),
      'quantity smaller than 1e-8': tx('q3', TransactionKind.buy, 3e-9, 50, d),
      'quantity whose count is past 2^53 but fits 64 bits': tx('q4', TransactionKind.buy, 9.1e10 + 0.123456789, 1, d),
      'quantity too small to count, moved out': tx('q6', TransactionKind.transferOut, 4.9e-9, 0, d),
      'cost too large to hold in minor units': tx('c1', TransactionKind.buy, 1e7, 1e300, d, fee: 1e300),
      'sell too large to hold in minor units': tx('c2', TransactionKind.sell, 1e7, 1e300, d),
      'quantity beyond a 64-bit count': tx('q5', TransactionKind.buy, 1e12, 1e-6, d),
      'price that is not exact in decimals': tx('p1', TransactionKind.buy, 3, 0.1 + 0.2, d, fee: 0.1 + 0.7),
    };

    for (final e in rows.entries) {
      test(e.key, () => expectRoundTrip(e.value));
    }

    test('an exact quantity writes no qtyRaw, an inexact one does', () {
      expect(HoldingEntryCodec.toEntry(rows['buy']!).lines.first.quantityRaw, isNull);
      expect(HoldingEntryCodec.toEntry(rows['quantity not exact at 1e-8 (0.1 + 0.2)']!).lines.first.quantityRaw, 0.1 + 0.2);
      expect(HoldingEntryCodec.toEntry(rows['quantity not exact at 1e-8 (0.1 + 0.2)']!).lines.first.quantity, 30000000);
    });

    test('a quantity whose count is past 2^53 keeps the count and the number as entered', () {
      final line = HoldingEntryCodec.toEntry(rows['quantity whose count is past 2^53 but fits 64 bits']!).lines.first;
      expect(line.quantity, isNotNull);
      expect(line.quantityRaw, 9.1e10 + 0.123456789);
    });

    test('a quantity too small to count is a valid row that moves its raw quantity', () {
      final e = HoldingEntryCodec.toEntry(rows['quantity too small to count, moved out']!);
      expect((e.lines.single.quantity, e.lines.single.quantityRaw), (0, 4.9e-9));
      expect(e.issues, isEmpty);
    });

    test('a cost no count can hold is held at the largest count, and the entry still balances', () {
      final e = HoldingEntryCodec.toEntry(rows['cost too large to hold in minor units']!);
      expect(e.lines.first.amount, 9200000000000000000);
      expect(e.lines.first.amount + e.lines.last.amount, 0);
      expect(e.issues, isEmpty);
    });

    test('a price or fee that is not a number does not stop the row being written', () {
      final e = HoldingEntryCodec.toEntry(tx('c3', TransactionKind.buy, 2, double.nan, d, fee: 1));
      expect(e.lines.first.amount, 0);
      expect(e.lines.first.unitPrice, isNaN);
      expect(HoldingEntryCodec.toEntry(tx('c4', TransactionKind.fee, 0, 0, d, fee: double.infinity)).lines.first.amount, 9200000000000000000);
    });

    test('a negative zero comes back as zero: equal, not the same bits', () {
      final t = tx('z', TransactionKind.buy, 1, -0.0, d, fee: -0.0);
      final back = HoldingEntryCodec.fromEntry(HoldingEntryCodec.toEntry(t));
      expect(back, t);
      expect(back.unitPrice.isNegative, isFalse);
      expect(back.fee.isNegative, isFalse);
    });

    test('every row in one list decodes to the same rows in any order', () {
      final entries = [for (final t in rows.values) HoldingEntryCodec.toEntry(t)].reversed;
      expect({for (final e in entries) e.id: HoldingEntryCodec.fromEntry(e)}, {for (final t in rows.values) t.id: t});
    });
  });

  group('the ledger from entries', () {
    Ledger viaEntries(List<HoldingTransaction> ts) => ledgerOfEntries([for (final t in ts) HoldingEntryCodec.toEntry(t)]);

    void expectSameLedger(List<HoldingTransaction> ts) {
      expect(viaEntries(ts), Ledger.derive(ts));
      expect(ledgerOfEntries([for (final t in ts) BookEntry.fromJson(jsonDecode(jsonEncode(HoldingEntryCodec.toEntry(t).toJson())) as Map<String, dynamic>)]), Ledger.derive(ts));
    }

    test('two buys and a sell with a commission', () {
      expectSameLedger([
        tx('b1', TransactionKind.buy, 100, 71.2, DateTime(2026, 3, 12)),
        tx('b2', TransactionKind.buy, 62, 78.4, DateTime(2026, 6, 4)),
        tx('s1', TransactionKind.sell, 20, 83.6, DateTime(2026, 8, 18), fee: 18),
      ]);
    });

    test('karats, transfers, a fee and a second instrument', () {
      expectSameLedger([
        tx('b1', TransactionKind.buy, 50, 70, DateTime(2026, 1, 3), karat: GoldKarat.k21, fee: 5),
        tx('b2', TransactionKind.buy, 25, 72, DateTime(2026, 1, 9), karat: GoldKarat.k18),
        tx('i1', TransactionKind.transferIn, 10, 0, DateTime(2026, 2, 1)),
        tx('i2', TransactionKind.transferIn, 4, 68, DateTime(2026, 2, 2), currency: 'SAR'),
        tx('f1', TransactionKind.fee, 0, 0, DateTime(2026, 2, 3), fee: 3),
        tx('o1', TransactionKind.transferOut, 12, 0, DateTime(2026, 2, 4), fee: 1),
        tx('s1', TransactionKind.sell, 30.3, 80, DateTime(2026, 2, 5), karat: GoldKarat.k21),
        tx('v1', TransactionKind.buy, 7, 19.9, DateTime(2026, 2, 5), instrument: 'metal.XAG', unit: PriceUnit.troyOunce),
      ]);
    });

    test('a sale of more than was held, and a same-day round trip', () {
      expectSameLedger([
        tx('b1', TransactionKind.buy, 10, 50, DateTime(2026, 4, 1)),
        tx('s1', TransactionKind.sell, 10, 55, DateTime(2026, 4, 1)),
        tx('s2', TransactionKind.sell, 3, 55, DateTime(2026, 4, 2)),
      ]);
    });

    test('a holding entry that lost its facts is left out, and the rest still derive', () {
      final good = tx('b1', TransactionKind.buy, 10, 50, d);
      final bare = BookEntry(
        id: 'lost',
        date: d,
        template: EntryTemplate.holdingBuy,
        baseCurrency: 'USD',
        lines: const [
          EntryLine(accountId: 'holding.metal.XAU', amount: 5, currency: 'USD', baseAmount: 5),
          EntryLine(accountId: 'system.holdings', amount: -5, currency: 'USD', baseAmount: -5),
        ],
      );
      final noUnit = HoldingEntryCodec.toEntry(good).copyWith(lines: [
        for (final l in HoldingEntryCodec.toEntry(good).lines) l.commodity == null ? l : EntryLine.fromJson({...l.toJson()..remove('unit')}),
      ]);
      expect(HoldingEntryCodec.tryFromEntry(bare), isNull);
      expect(HoldingEntryCodec.tryFromEntry(noUnit), isNull);
      expect(() => HoldingEntryCodec.fromEntry(bare), throwsArgumentError);
      expect(ledgerOfEntries([bare, noUnit, HoldingEntryCodec.toEntry(good)]), Ledger.derive([good]));
    });

    test('entries that are not holdings, and declined ones, are left out', () {
      final money = BookEntry(
        id: 'm',
        date: d,
        template: EntryTemplate.spend,
        baseCurrency: 'USD',
        lines: const [
          EntryLine(accountId: 'a', amount: 5, currency: 'USD', baseAmount: 5),
          EntryLine(accountId: 'b', amount: -5, currency: 'USD', baseAmount: -5),
        ],
      );
      final bought = HoldingEntryCodec.toEntry(tx('b1', TransactionKind.buy, 10, 50, d));
      expect(ledgerOfEntries([money, bought, bought.copyWith(status: EntryStatus.declined)]), Ledger.derive([tx('b1', TransactionKind.buy, 10, 50, d)]));
      expect(ledgerOfEntries([money]), Ledger.empty);
      expect(ledgerOfEntries([bought.copyWith(status: EntryStatus.declined)]), Ledger.empty);
    });

  });

  group('with a cash leg', () {
    const bank = 'acct.bank';

    // One row of each kind that moves cash, with its cost in minor units of
    // its own currency: buy 10 at 50.25 with 5 fee = 50750, sell 4 at 80 with
    // a fee of 2 = 31800 net, fee of 12.50 = 1250.
    HoldingTransaction buy(String currency) => tx('b1', TransactionKind.buy, 10, 50.25, d, fee: 5, currency: currency);
    HoldingTransaction sell(String currency) => tx('s1', TransactionKind.sell, 4, 80, d, fee: 2, currency: currency);
    HoldingTransaction fee(String currency) => tx('f1', TransactionKind.fee, 0, 0, d, fee: 12.5, currency: currency);
    final amounts = {'b1': 50750, 's1': 31800, 'f1': 1250};

    void expectBalancedRoundTrip(HoldingTransaction t, CashLeg leg, {String? base}) {
      final e = HoldingEntryCodec.toEntry(t, cash: leg, baseCurrency: base, merchant: 'Gold');
      expect(e.issues, isEmpty, reason: e.issues.join('; '));
      expect(e.id, t.id);
      expect(e.merchant, 'Gold');
      expect(e.baseCurrency, base ?? t.currency);
      expectSame(HoldingEntryCodec.fromEntry(e), t);
      final stored = BookEntry.fromJson(jsonDecode(jsonEncode(e.toJson())) as Map<String, dynamic>);
      expect(stored, e);
      expectSame(HoldingEntryCodec.fromEntry(stored), t);
      final line = HoldingEntryCodec.cashLegOf(e);
      expect(line, isNotNull);
      expect(line!.accountId, leg.accountId);
      expect(line.currency, leg.currency);
      expect(line.amount.abs(), leg.amount);
      expect(e.lines.where((l) => l.accountId == 'system.holdings').length, lessThanOrEqualTo(1));
    }

    test('cash in the trade currency, which is the base: the cash is the other side', () {
      for (final t in [buy('USD'), sell('USD'), fee('USD')]) {
        final x = amounts[t.id]!;
        final e = HoldingEntryCodec.toEntry(t, cash: CashLeg(accountId: bank, currency: 'USD', amount: x, baseAmount: x), baseCurrency: 'USD');
        final sign = t.kind == TransactionKind.sell ? 1 : -1;
        expect(e.lines, hasLength(2));
        expect((e.lines[1].accountId, e.lines[1].amount, e.lines[1].baseAmount), (bank, sign * x, sign * x));
        expect(e.lines[0].amount, -sign * x);
        expectBalancedRoundTrip(t, CashLeg(accountId: bank, currency: 'USD', amount: x, baseAmount: x), base: 'USD');
      }
    });

    test('a trade with no base given is in its own currency', () {
      final e = HoldingEntryCodec.toEntry(buy('USD'), cash: const CashLeg(accountId: bank, currency: 'USD', amount: 50750, baseAmount: 50750));
      expect(e.baseCurrency, 'USD');
      expect(e.issues, isEmpty);
    });

    test('cash in the base currency for a trade in another: the base amounts come from the cash', () {
      // 50750 minor units of SAR bought with 13533 cents.
      final e = HoldingEntryCodec.toEntry(buy('SAR'), cash: const CashLeg(accountId: bank, currency: 'USD', amount: 13533, baseAmount: 13533), baseCurrency: 'USD');
      expect(e.baseCurrency, 'USD');
      expect(e.lines.map((l) => (l.accountId, l.amount, l.currency, l.baseAmount)), [(goldId, 50750, 'SAR', 13533), (bank, -13533, 'USD', -13533)]);
      expect(e.issues, isEmpty);
      for (final t in [buy('SAR'), sell('SAR'), fee('SAR')]) {
        expectBalancedRoundTrip(t, const CashLeg(accountId: bank, currency: 'USD', amount: 13533, baseAmount: 13533), base: 'USD');
      }
    });

    test('a trade in the base currency paid from another currency: the base amounts come from the trade', () {
      final e = HoldingEntryCodec.toEntry(buy('USD'), cash: const CashLeg(accountId: bank, currency: 'SAR', amount: 190313, baseAmount: 50700), baseCurrency: 'USD');
      expect(e.lines.map((l) => (l.accountId, l.amount, l.baseAmount)), [(goldId, 50750, 50750), (bank, -190313, -50750)]);
      expect(e.issues, isEmpty);
      for (final t in [buy('USD'), sell('USD'), fee('USD')]) {
        expectBalancedRoundTrip(t, const CashLeg(accountId: bank, currency: 'SAR', amount: 190313, baseAmount: 50700), base: 'USD');
      }
    });

    test('a third currency: the base amounts come from the cash side', () {
      final e = HoldingEntryCodec.toEntry(buy('SAR'), cash: const CashLeg(accountId: bank, currency: 'EGP', amount: 648000, baseAmount: 13500), baseCurrency: 'USD');
      expect(e.lines.map((l) => (l.accountId, l.amount, l.currency, l.baseAmount)), [(goldId, 50750, 'SAR', 13500), (bank, -648000, 'EGP', -13500)]);
      expect(e.issues, isEmpty);
      for (final t in [buy('SAR'), sell('SAR'), fee('SAR')]) {
        expectBalancedRoundTrip(t, const CashLeg(accountId: bank, currency: 'EGP', amount: 648000, baseAmount: 13500), base: 'USD');
      }
    });

    test('the same third currency on both sides', () {
      for (final t in [buy('SAR'), sell('SAR'), fee('SAR')]) {
        final x = amounts[t.id]!;
        expectBalancedRoundTrip(t, CashLeg(accountId: bank, currency: 'SAR', amount: x, baseAmount: 1000), base: 'USD');
        expectBalancedRoundTrip(t, CashLeg(accountId: bank, currency: 'SAR', amount: x + 30, baseAmount: 1000), base: 'USD');
      }
    });

    test('cash that differs from the cost in one currency leaves the difference on Holdings', () {
      final more = HoldingEntryCodec.toEntry(buy('USD'), cash: const CashLeg(accountId: bank, currency: 'USD', amount: 50800, baseAmount: 50800), baseCurrency: 'USD');
      expect(more.lines.map((l) => (l.accountId, l.amount, l.baseAmount)), [(goldId, 50750, 50750), (bank, -50800, -50800), ('system.holdings', 50, 50)]);
      expect(more.issues, isEmpty);
      final less = HoldingEntryCodec.toEntry(sell('USD'), cash: const CashLeg(accountId: bank, currency: 'USD', amount: 31700, baseAmount: 31700), baseCurrency: 'USD');
      expect(less.lines.map((l) => (l.accountId, l.amount)), [(goldId, -31800), (bank, 31700), ('system.holdings', 100)]);
      expect(less.issues, isEmpty);
      expectSame(HoldingEntryCodec.fromEntry(more), buy('USD'));
      expectSame(HoldingEntryCodec.fromEntry(less), sell('USD'));
      // In a third currency the residual carries no base amount, and the base amounts still balance.
      final third = HoldingEntryCodec.toEntry(buy('SAR'), cash: const CashLeg(accountId: bank, currency: 'SAR', amount: 50800, baseAmount: 13500), baseCurrency: 'USD');
      expect(third.lines.last.baseAmount, 0);
      expect(third.lines.fold<int>(0, (a, l) => a + l.baseAmount), 0);
      expect(third.issues, isEmpty);
    });

    test('a card and an ordinary account take the same signs as the cash entry always did', () {
      final builder = EntryBuilder(baseCurrency: 'USD', rates: FXRates.usdIdentity, newId: () => 'x');
      const card = BookAccount(id: 'acct.card', name: 'Card', side: AccountSide.owe, type: AccountType.credit, currency: 'USD');
      const debit = BookAccount(id: bank, name: 'Bank', side: AccountSide.own, type: AccountType.debit, currency: 'USD');
      for (final account in [card, debit]) {
        for (final t in [buy('USD'), sell('USD'), fee('USD')]) {
          final x = amounts[t.id]!;
          final old = oldHoldingTrade(builder, account, x, d, incoming: t.kind == TransactionKind.sell, id: 'c');
          final now = HoldingEntryCodec.toEntry(t, cash: CashLeg(accountId: account.id, currency: 'USD', amount: x, baseAmount: x), baseCurrency: 'USD');
          final oldCash = old.lines.firstWhere((l) => l.accountId == account.id);
          final newCash = HoldingEntryCodec.cashLegOf(now)!;
          expect((newCash.accountId, newCash.amount, newCash.currency, newCash.baseAmount), (oldCash.accountId, oldCash.amount, oldCash.currency, oldCash.baseAmount));
          expect(now.issues, isEmpty);
        }
      }
    });

    test('a transfer takes no cash leg', () {
      for (final t in [tx('i1', TransactionKind.transferIn, 10, 60, d), tx('o1', TransactionKind.transferOut, 5, 0, d)]) {
        const leg = CashLeg(accountId: bank, currency: 'USD', amount: 100, baseAmount: 100);
        expect(HoldingEntryCodec.toEntry(t, cash: leg), HoldingEntryCodec.toEntry(t));
        expect(HoldingEntryCodec.cashLegOf(HoldingEntryCodec.toEntry(t, cash: leg)), isNull);
      }
    });

    test('without a cash leg the base currency given is not used', () {
      final e = HoldingEntryCodec.toEntry(buy('SAR'), baseCurrency: 'USD');
      expect(e.baseCurrency, 'SAR');
      expect(e.issues, isEmpty);
    });

    test('cashLegOf finds the account line and nothing else', () {
      expect(HoldingEntryCodec.cashLegOf(HoldingEntryCodec.toEntry(buy('USD'))), isNull);
      final e = HoldingEntryCodec.toEntry(buy('USD'), cash: const CashLeg(accountId: bank, currency: 'USD', amount: 50800, baseAmount: 50800));
      expect(HoldingEntryCodec.cashLegOf(e)!.accountId, bank);
      expect(HoldingEntryCodec.cashLegOf(e.copyWith(lines: [e.lines.first, e.lines.last])), isNull);
    });

    test('a cash leg with no cost: the trade is a quantity and the cash is the residual', () {
      final t = tx('z', TransactionKind.buy, 1, 0, d);
      final e = HoldingEntryCodec.toEntry(t, cash: const CashLeg(accountId: bank, currency: 'USD', amount: 500, baseAmount: 500), baseCurrency: 'USD');
      expect(e.issues, isEmpty);
      expectSame(HoldingEntryCodec.fromEntry(e), t);
    });

    test('the cases that cannot balance say so', () {
      // Nothing to put against cash in another currency.
      final free = HoldingEntryCodec.toEntry(tx('z', TransactionKind.buy, 1, 0, d, currency: 'SAR'), cash: const CashLeg(accountId: bank, currency: 'USD', amount: 500, baseAmount: 500), baseCurrency: 'USD');
      expect(free.issues, isNotEmpty);
      // A commission that passes the proceeds, with cash in another currency.
      final loss = HoldingEntryCodec.toEntry(tx('y', TransactionKind.sell, 1, 1, d, fee: 5, currency: 'SAR'), cash: const CashLeg(accountId: bank, currency: 'USD', amount: 100, baseAmount: 100), baseCurrency: 'USD');
      expect(loss.issues.map((i) => i.problem), contains(EntryProblem.baseSignMismatch));
    });
  });
}
