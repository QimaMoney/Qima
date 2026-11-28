import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qima/blocs/money_cubit.dart';
import 'package:qima/l10n/app_localizations.dart';
import 'package:qima/mcp/qima_tools.dart';
import 'package:qima/models/ai_snapshot.dart';
import 'package:qima/models/asset.dart';
import 'package:qima/models/book.dart';
import 'package:qima/models/book_account.dart';
import 'package:qima/models/book_entry.dart';
import 'package:qima/models/chart_range.dart';
import 'package:qima/models/fx_history.dart';
import 'package:qima/models/holding_cash_id.dart';
import 'package:qima/models/holding_entry_codec.dart';
import 'package:qima/models/holding_transaction.dart';
import 'package:qima/models/instrument_catalog.dart';
import 'package:qima/models/money.dart';
import 'package:qima/models/money_settings.dart';
import 'package:qima/models/net_worth.dart';
import 'package:qima/models/net_worth_history.dart';
import 'package:qima/models/zakat.dart';
import 'package:qima/models/zakat_book.dart';
import 'package:qima/theme/money_labels.dart';
import 'package:qima/theme/strings.dart';
import 'package:qima/widgets/money_widgets.dart';

import 'book_test.dart' show builder, cib, dining, egp, groceries, rajhi, rates, salary, sar, visa;

/// A book with ordinary money entries and holdings trades in two
/// instruments and two currencies, with and without a cash account on the
/// other side, next to the same book as it was before holdings moved in:
/// the money entries and, for each trade paid from an account, the cash
/// entry it used to leave (cash against Holdings).
void main() {
  final now = DateTime(2026, 11, 17, 15);
  DateTime ago(int days) => DateTime(2026, 11, 17 - days, 10);

  const gold = 'holding.metal.XAU';
  const silver = 'holding.metal.XAG';

  HoldingTransaction tx(String id, TransactionKind kind, String instrument, double qty, double price, String currency, DateTime date) =>
      HoldingTransaction(id: id, instrumentID: instrument, kind: kind, quantity: qty, unit: PriceUnit.gram, unitPrice: price, currency: currency, date: date);

  CashLeg leg(String account, String currency, int amount, int baseAmount) => CashLeg(accountId: account, currency: currency, amount: amount, baseAmount: baseAmount);

  // The cash entry a trade paid from an account left before: the cash
  // against Holdings, with nothing of the holding on it, under the id the
  // cash half always had.
  BookEntry legacy(BookEntry trade, CashLeg cash) {
    final line = trade.lines.firstWhere((l) => l.accountId == cash.accountId);
    return BookEntry(
      id: holdingCashId(trade.id),
      date: trade.date,
      template: EntryTemplate.holdingTrade,
      baseCurrency: trade.baseCurrency,
      lines: [line, EntryLine(accountId: SystemAccount.holdings.id, amount: -line.amount, currency: line.currency, baseAmount: -line.baseAmount)],
    );
  }

  final x = builder();
  final money = <BookEntry>[
    x.opening(rajhi, sar(10000), ago(12)),
    x.opening(cib, egp(1300), ago(12)),
    x.opening(visa, sar(400), ago(12)),
    x.income(rajhi, salary, sar(8000), ago(9), merchant: 'Employer'),
    x.spend(rajhi, groceries, sar(300), ago(7), merchant: 'Panda'),
    x.spend(visa, dining, sar(120), ago(2), merchant: 'Cafe'),
  ];

  // No cash account: gold bought in two currencies, silver once.
  final goldUsd = HoldingEntryCodec.toEntry(tx('t1', TransactionKind.buy, 'metal.XAU', 10, 70, 'USD', ago(8)));
  final goldEgp = HoldingEntryCodec.toEntry(tx('t2', TransactionKind.buy, 'metal.XAU', 5, 2000, 'EGP', ago(6)));
  final silverUsd = HoldingEntryCodec.toEntry(tx('t3', TransactionKind.buy, 'metal.XAG', 100, 1, 'USD', ago(5)));
  // Paid from an account: a buy from a riyal account, a sell into it, a buy
  // from the Egyptian account.
  final buyCash = leg('rajhi', 'SAR', sar(375), sar(375));
  final sellCash = leg('rajhi', 'SAR', sar(800), sar(800));
  final egpCash = leg('cib', 'EGP', egp(260), sar(20));
  final silverPaid = HoldingEntryCodec.toEntry(tx('t4', TransactionKind.buy, 'metal.XAG', 100, 1, 'USD', ago(4)), cash: buyCash, baseCurrency: 'SAR');
  final goldSold = HoldingEntryCodec.toEntry(tx('t5', TransactionKind.sell, 'metal.XAU', 3, 75, 'USD', ago(3)), cash: sellCash, baseCurrency: 'SAR');
  final goldPaidEgp = HoldingEntryCodec.toEntry(tx('t6', TransactionKind.buy, 'metal.XAU', 2, 70, 'USD', ago(1)), cash: egpCash, baseCurrency: 'SAR');
  final transferOut = HoldingEntryCodec.toEntry(tx('t7', TransactionKind.transferOut, 'metal.XAU', 1, 0, 'USD', ago(1)));

  final trades = [goldUsd, goldEgp, silverUsd, silverPaid, goldSold, goldPaidEgp, transferOut];
  final accounts = [rajhi, cib, visa, dining, groceries, salary];

  final mixed = Book(accounts, [...money, ...trades]);
  final before = Book(accounts, [
    ...money,
    legacy(silverPaid, buyCash),
    legacy(goldSold, sellCash),
    legacy(goldPaidEgp, egpCash),
  ]);

  List<(String, int)> lines(Iterable<BalanceSheetLine> ls) => [for (final l in ls) (l.account.id, l.amount)];

  group('the book', () {
    test('holds the holdings, with cost in several currencies, beside the money', () {
      expect(mixed.accounts[gold]!.isHolding, isTrue);
      expect(mixed.accounts[silver]!.isHolding, isTrue);
      final cost = mixed.balances()[gold]!;
      expect(cost.keys, containsAll(['USD', 'EGP']));
    });

    test('balanceOf reads zero on a holding that has several currencies, and throws on nothing', () {
      expect(mixed.balanceOf(gold), 0);
      expect(mixed.balanceOf(silver), 0);
      expect(mixed.balanceOf(gold, asOf: ago(5)), 0);
      expect(mixed.balanceOf('holding.metal.XPT'), 0);
    });

    test('every money account reads as it did before', () {
      for (final a in before.accounts.values.where((a) => a.onMoneySheet)) {
        expect(mixed.balanceOf(a.id), before.balanceOf(a.id), reason: a.id);
        expect(mixed.balanceOf(a.id, asOf: ago(5)), before.balanceOf(a.id, asOf: ago(5)), reason: a.id);
      }
    });

    test('the balance sheet and net worth are those of the book before', () {
      for (final day in [null, ago(5), ago(1)]) {
        final a = mixed.balanceSheet(asOf: day), b = before.balanceSheet(asOf: day);
        expect(lines(a.own), lines(b.own));
        expect(lines(a.owe), lines(b.owe));
        expect(a.owned, b.owned);
        expect(a.owed, b.owed);
        expect(mixed.netWorth('SAR', rates, asOf: day).amount, before.netWorth('SAR', rates, asOf: day).amount);
      }
      expect([...mixed.balanceSheet().own, ...mixed.balanceSheet().owe].any((l) => l.account.isHolding), isFalse);
    });

    test('the summary and its groups match', () {
      final a = NetWorthSummary.of(book: mixed, holdingsValue: 2500, currency: 'SAR', rates: rates);
      final b = NetWorthSummary.of(book: before, holdingsValue: 2500, currency: 'SAR', rates: rates);
      expect(a.netWorth, b.netWorth);
      expect([for (final g in a.groups) g.amount], [for (final g in b.groups) g.amount]);
      expect(a.missingRates, b.missingRates);
    });
  });

  group('net worth history', () {
    test('does not add cost on top of the live holdings', () {
      for (final range in [ChartRange.all, ChartRange.month1]) {
        List<(DateTime, double)> build(Book book) => [
              for (final p in NetWorthHistory.build(book: book, holdings: const [], currency: 'SAR', rates: rates, fxHistory: FXHistory.empty, range: range, now: now)) (p.date, p.value),
            ];
        expect(build(mixed), build(before));
      }
    });
  });

  group('zakat on the book', () {
    test('counts cash, debts and what is owed as before, never holding cost', () {
      final assessment = ZakatAssessment(
        lines: const [],
        base: const Money(3000, 'SAR'),
        threshold: const Money(1000, 'SAR'),
        otherThreshold: null,
        due: const Money(0, 'SAR'),
        status: NisabStatus.noHoldings,
        basis: NisabBasis.gold,
      );
      final a = ZakatOnBook.of(book: mixed, holdings: assessment, currency: 'SAR', rates: rates);
      final b = ZakatOnBook.of(book: before, holdings: assessment, currency: 'SAR', rates: rates);
      expect(a.parts, b.parts);
      expect(a.base, b.base);
      expect(a.missingRates, b.missingRates);
    });
  });

  group('the assistant\'s helper', () {
    final rateTable = rates;
    AiSnapshot snapshot(Iterable<BookEntry> entries, {bool filtered = true}) {
      if (!filtered) {
        return AiSnapshot(writtenAt: now, baseCurrency: 'SAR', rates: rateTable, accounts: accounts, entries: entries.toList());
      }
      return AiSnapshot.build(now: now, baseCurrency: 'SAR', rates: rateTable, accounts: accounts, entries: entries, planned: const [], settings: const MoneySettings());
    }

    Map<String, dynamic> run(String tool, AiSnapshot s, [Map<String, dynamic> args = const {}]) => QimaTools.named(tool)!.run(s, args, now);

    // What is written to disk, and what the tools read when handed a book
    // that still has the holding lines in it.
    final written = snapshot([...money, ...trades]);
    final snapshots = {
      'written': (written, holdingCashId),
      'unfiltered': (snapshot([...money, ...trades], filtered: false), (String id) => id),
    };
    final reference = snapshot(before.entries);

    for (final e in snapshots.entries) {
      group(e.key, () {
        final (s, idOf) = e.value;

        test('net worth and accounts are those of the book before', () {
          expect(run('get_net_worth', s), run('get_net_worth', reference));
          expect(run('list_accounts', s), run('list_accounts', reference));
          expect(run('list_accounts', s, {'include_categories': true, 'include_archived': true}), run('list_accounts', reference, {'include_categories': true, 'include_archived': true}));
        });

        test('spending and people are those of the book before', () {
          expect(run('get_spending', s, {'month': '2026-11'}), run('get_spending', reference, {'month': '2026-11'}));
          expect(run('list_people', s), run('list_people', reference));
        });

        test('no output names a holding account, a quantity or an instrument', () {
          for (final out in [
            run('list_accounts', s, {'include_categories': true, 'include_archived': true}),
            run('list_transactions', s, {'limit': 500}),
            run('list_transactions', s, {'kind': 'holding_trade'}),
            run('get_net_worth', s),
          ]) {
            final text = jsonEncode(out);
            expect(text, isNot(contains('holding.')));
            expect(text, isNot(contains('metal.')));
            expect(text, isNot(contains('qty')));
            expect(text, isNot(contains('holding_buy')));
            expect(text, isNot(contains('holding_sell')));
            expect(text, isNot(contains('holding_out')));
          }
        });

        test('a trade paid from an account is its cash, as a holdings trade; one with no cash is left out', () {
          final out = run('list_transactions', s, {'limit': 500});
          final ids = [for (final t in out['transactions'] as List) (t as Map)['id']];
          expect(ids, containsAll([idOf('t4'), idOf('t5'), idOf('t6')]));
          expect(ids.toSet().intersection({for (final id in ['t1', 't2', 't3', 't7']) idOf(id)}), isEmpty);
          final sold = (out['transactions'] as List).cast<Map>().firstWhere((t) => t['id'] == idOf('t5'));
          expect(sold['kind'], 'holding_trade');
          expect(
            [for (final l in sold['lines'] as List) if ((l as Map)['account_id'] == 'rajhi') l['change']],
            [800.0],
          );
          expect(run('list_transactions', s, {'kind': 'holding_trade'})['count'], 3);
        });

        test('a holding account cannot be asked for', () {
          expect(() => run('list_transactions', s, {'account': gold}), throwsA(isA<ToolInputError>()));
          expect(() => run('list_transactions', s, {'account': 'metal.XAU'}), throwsA(isA<ToolInputError>()));
        });
      });
    }

    test('what is written leaves out quantities, holding accounts and trades that moved no cash', () {
      final text = jsonEncode(written.toJson());
      expect(text, isNot(contains('"qty')));
      expect(text, isNot(contains('commodity')));
      expect(text, isNot(contains('holding.')));
      final ids = [for (final e in written.entries) e.id];
      expect(ids.toSet().intersection({for (final id in ['t1', 't2', 't3', 't7']) holdingCashId(id)}), isEmpty);
      expect(ids.length, money.length + 3);
    });

    test('what is written lists transactions exactly as before', () {
      expect(run('list_transactions', written, {'limit': 500}), run('list_transactions', reference, {'limit': 500}));
    });
  });

  group('an entry row', () {
    late AppLocalizations l10n;
    setUpAll(() async => l10n = await AppLocalizations.delegate.load(const Locale('en')));

    void same(EntrySummary a, EntrySummary b) {
      expect(a.title, b.title);
      expect(a.subtitle, b.subtitle);
      expect(a.amount, b.amount);
      expect(a.currency, b.currency);
      expect(a.sign, b.sign);
    }

    test('of a trade paid from an account shows the cash, as the cash entry did', () {
      for (final (trade, cash) in [(silverPaid, buyCash), (goldSold, sellCash), (goldPaidEgp, egpCash)]) {
        final row = EntrySummary.of(trade, mixed, l10n);
        same(row, EntrySummary.of(legacy(trade, cash), before, l10n));
        expect(row.subtitle, isNot(contains('Gold')));
        expect(row.subtitle, isNot(contains('metal')));
        same(EntrySummary.of(trade, mixed, l10n, forAccount: cash.accountId), EntrySummary.of(legacy(trade, cash), before, l10n, forAccount: cash.accountId));
      }
    });

    test('of a trade with no cash or one with no money does not throw and shows no holding', () {
      for (final trade in [goldUsd, goldEgp, silverUsd, transferOut]) {
        final row = EntrySummary.of(trade, mixed, l10n);
        expect(row.subtitle, isNot(contains('metal')));
        expect(row.amount, greaterThanOrEqualTo(0));
      }
      expect(EntrySummary.of(goldUsd, mixed, l10n).amount, goldUsd.lines.firstWhere((l) => l.accountId == SystemAccount.holdings.id).amount.abs());
    });
  });

  group('lists of accounts', () {
    test('a holding is never an account to pick', () {
      final state = MoneyState(loaded: true, accounts: [rajhi, cib, BookAccount.holding('metal.XAU')]);
      expect([for (final a in state.balanceAccounts) a.id], ['rajhi', 'cib']);
    });

    test('the predicate: money you own or owe, not a holding', () {
      expect(rajhi.onMoneySheet, isTrue);
      expect(visa.onMoneySheet, isTrue);
      expect(dining.onMoneySheet, isFalse);
      expect(SystemAccount.holdings.account.onMoneySheet, isFalse);
      expect(BookAccount.holding('metal.XAU').onMoneySheet, isFalse);
    });
  });

  group('a holding\'s name', () {
    late AppLocalizations l10n;
    setUpAll(() async => l10n = await AppLocalizations.delegate.load(const Locale('en')));
    tearDown(() => InstrumentCatalog.reloadCustom(const []));

    test('is its instrument\'s, in the person\'s language', () {
      expect(l10n.accountName(mixed.accounts[gold]!), 'Gold');
      expect(l10n.accountName(mixed.accounts[gold]!), displayLabelFor(l10n, 'asset.gold'));
    });

    test('is a custom instrument\'s own name, and the instrument id when it is not known', () {
      InstrumentCatalog.reloadCustom(const [Instrument(id: 'stock.ZZZ', symbol: 'ZZZ', assetClass: AssetClass.stock, nameKey: 'Index fund')]);
      expect(l10n.accountName(BookAccount.holding('stock.ZZZ')), 'Index fund');
      expect(l10n.accountName(BookAccount.holding('stock.ZZNONE')), 'stock.ZZNONE');
    });
  });
}
