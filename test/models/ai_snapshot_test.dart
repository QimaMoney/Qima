import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/ai_snapshot.dart';
import 'package:qima/models/asset.dart';
import 'package:qima/models/book.dart';
import 'package:qima/models/book_account.dart';
import 'package:qima/models/book_entry.dart';
import 'package:qima/models/entry_builder.dart';
import 'package:qima/models/holding_cash_id.dart';
import 'package:qima/models/holding_entry_codec.dart';
import 'package:qima/models/holding_transaction.dart';
import 'package:qima/models/minor_units.dart';
import 'package:qima/models/money.dart';
import 'package:qima/models/money_settings.dart';

BookAccount own(String id, String name, String ccy) =>
    BookAccount(id: id, name: name, side: AccountSide.own, type: AccountType.debit, currency: ccy);

final bank = own('bank', 'Bank', 'SAR');
final usd = own('usd', 'Dollar account', 'USD');
final rates = FXRates(base: 'SAR', rates: const {'SAR': 1, 'USD': 0.25}, updatedAt: DateTime.utc(2026, 11, 14, 6));
final now = DateTime(2026, 11, 14, 12);
final builder = EntryBuilder(baseCurrency: 'SAR', rates: rates, newId: () => 'unused');

HoldingTransaction trade(String id, TransactionKind kind, double qty, double px, DateTime date, {String currency = 'SAR', double fee = 0}) =>
    HoldingTransaction(
        id: id, instrumentID: 'metal.XAU', kind: kind, quantity: qty, unit: PriceUnit.gram, unitPrice: px, fee: fee, currency: currency, date: date, note: 'private note');

CashLeg leg(BookAccount a, int amount, int base) => CashLeg(accountId: a.id, currency: a.currency!, amount: amount, baseAmount: base);

AiSnapshot snapshotOf(List<BookEntry> entries) => AiSnapshot.build(
      now: now,
      baseCurrency: 'SAR',
      rates: rates,
      accounts: [bank, usd],
      entries: entries,
      planned: const [],
      settings: const MoneySettings(),
    );

void walk(Object? node, void Function(String key, Object? value) visit) {
  if (node is Map) {
    node.forEach((k, v) {
      visit(k as String, v);
      walk(v, visit);
    });
  } else if (node is List) {
    for (final v in node) {
      walk(v, visit);
    }
  } else {
    visit('', node);
  }
}

void main() {
  final d = DateTime(2026, 11, 5);
  final money = [
    builder.opening(bank, MinorUnits.fromMajor(10000, 'SAR'), DateTime(2026, 10, 1)),
    builder.opening(usd, MinorUnits.fromMajor(500, 'USD'), DateTime(2026, 10, 1)),
  ];
  // Two with cash (one in the base currency, one in dollars), two without.
  final buySar = HoldingEntryCodec.toEntry(trade('t1', TransactionKind.buy, 2.5, 100, d, fee: 5), cash: leg(bank, 25500, 25500), baseCurrency: 'SAR', merchant: 'Gold');
  final sellUsd = HoldingEntryCodec.toEntry(trade('t2', TransactionKind.sell, 1, 30, d, currency: 'USD'),
      cash: leg(usd, 3000, 12000), baseCurrency: 'SAR', merchant: 'Gold');
  final moveIn = HoldingEntryCodec.toEntry(trade('t3', TransactionKind.transferIn, 3, 80, d));
  final moveOut = HoldingEntryCodec.toEntry(trade('t4', TransactionKind.transferOut, 1, 0, d));
  final all = [...money, buySar, sellUsd, moveIn, moveOut];

  test('no holding fact or holding account reaches the file, in either form', () {
    for (final json in [snapshotOf(all).toJson(), jsonDecode(jsonEncode(snapshotOf(all).toJson()))]) {
      const forbidden = {'qty', 'commodity', 'unit', 'karat', 'px', 'fee', 'qtyRaw'};
      var seen = 0;
      walk(json, (key, value) {
        seen++;
        expect(forbidden.contains(key), isFalse, reason: key);
        if (value is String) {
          expect(value.startsWith('holding.'), isFalse, reason: value);
          expect(value.contains('holding.'), isFalse, reason: value);
        }
      });
      expect(seen, greaterThan(50));
    }
    expect(jsonEncode(snapshotOf(all).toJson()), isNot(contains('private note')));
    final templates = [for (final e in snapshotOf(all).entries) e.template.wireName];
    expect(templates.where((t) => t.startsWith('holding_') && t != 'holding_trade'), isEmpty);
  });

  test('trades without a cash leg are dropped, those with one stay as one entry', () {
    final s = snapshotOf(all);
    expect(s.entries, hasLength(4));
    expect({for (final e in s.entries) e.id}, containsAll([holdingCashId('t1'), holdingCashId('t2')]));
  });

  test('the cash-account balances are the book\'s', () {
    final s = snapshotOf(all);
    final book = Book([bank, usd], all);
    for (final a in [bank, usd]) {
      expect(s.book.balanceOf(a.id), book.balanceOf(a.id), reason: a.id);
    }
    expect(s.book.balanceOf('bank'), 1000000 - 25500);
    expect(s.book.balanceOf('usd'), 50000 + 3000);
  });

  test('a trade with cash is what the two-record form showed', () {
    BookEntry cash(String id, BookAccount account, int amount, int base) => BookEntry(id: id, date: d, template: EntryTemplate.holdingTrade, baseCurrency: 'SAR', merchant: 'Gold', lines: [
          EntryLine(accountId: account.id, amount: amount, currency: account.currency!, baseAmount: base),
          EntryLine(accountId: 'system.holdings', amount: -amount, currency: account.currency!, baseAmount: -base),
        ]);
    final oldBuy = cash(holdingCashId('t1'), bank, -25500, -25500);
    final oldSell = cash(holdingCashId('t2'), usd, 3000, 12000);
    final s = snapshotOf(all);
    final before = snapshotOf([...money, oldBuy, oldSell]);
    expect(jsonEncode([for (final e in s.entries) e.toJson()]), jsonEncode([for (final e in before.entries) e.toJson()]));
    expect(jsonEncode(s.toJson()['accounts']), jsonEncode(before.toJson()['accounts']));
  });
}
