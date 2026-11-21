import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qima/blocs/app_cubit.dart';
import 'package:qima/l10n/app_localizations_en.dart';
import 'package:qima/blocs/money_cubit.dart';
import 'package:qima/models/backup.dart';
import 'package:qima/models/book_account.dart';
import 'package:qima/models/book_entry.dart';
import 'package:qima/models/default_categories.dart';
import 'package:qima/models/entry_builder.dart';
import 'package:qima/models/holding_transaction.dart';
import 'package:qima/models/legacy_collapse.dart';
import 'package:qima/models/syncable.dart';
import 'package:qima/models/watch_card.dart';
import 'package:qima/models/quote.dart';
import 'package:qima/models/asset.dart';
import 'package:qima/models/net_worth.dart';
import 'package:qima/models/minor_units.dart';
import 'package:qima/models/money.dart';
import 'package:qima/models/money_settings.dart';
import 'package:qima/services/alerts_store.dart';
import 'package:qima/services/backup/backup_service.dart';
import 'package:qima/services/book_store.dart';
import 'package:qima/services/cloud_kv_store.dart';
import 'package:qima/services/custom_instrument_store.dart';
import 'package:qima/services/local_file_store.dart';
import 'package:qima/services/preferences.dart';
import 'package:qima/services/price_repository.dart';
import 'package:qima/services/synced_store.dart';
import 'package:qima/services/watchlist_store.dart';
import 'package:qima/widgets/money_widgets.dart';
import '../helpers/old_trade_entry.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _OfflineRepository extends PriceRepository {
  @override
  Future<QuoteSeries> refresh(Instrument instrument, {DateTime? now}) async => QuoteSeries.empty(instrument.id);

  @override
  Future<QuoteSeries> cachedSeries(Instrument instrument) async => QuoteSeries.empty(instrument.id);
}

final rates = FXRates(base: 'SAR', rates: const {'SAR': 1, 'EGP': 13}, updatedAt: DateTime.utc(2026, 11, 7));
int sar(num major) => MinorUnits.fromMajor(major, 'SAR');

BookAccount account(String id, AccountType type, {AccountSide side = AccountSide.own, String ccy = 'SAR'}) =>
    BookAccount(id: id, name: id, side: side, type: type, currency: ccy);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late BookStore store;
  var ids = 0;

  MoneyCubit cubit({DateTime? now}) => MoneyCubit(
        store: store,
        baseCurrency: () => 'SAR',
        rates: () => rates,
        newId: () => 'id${++ids}',
        now: () => now ?? DateTime(2026, 11, 10),
      );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('qima_money_cubit');
    LocalFileStore.overrideDirectoryForTesting(dir);
    SharedPreferences.setMockInitialValues({});
    store = BookStore();
    ids = 0;
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('a fresh book has the default categories and no balance accounts', () async {
    final m = cubit();
    await m.load();
    expect(m.state.loaded, isTrue);
    expect(m.state.hasBook, isFalse);
    expect(m.state.categories(AccountSide.spending).map((a) => a.id), contains('category.groceries'));
    expect(m.state.categories(AccountSide.income).map((a) => a.id), contains('category.salary'));
  });

  test('a default category the person deleted stays deleted on the next load', () async {
    final m = cubit();
    await m.load();
    await m.removeAccount('category.dining');
    final again = cubit();
    await again.load();
    expect(again.state.accounts.map((a) => a.id), isNot(contains('category.dining')));
  });

  test('an account added with money in it opens with that balance, and survives a reload', () async {
    final m = cubit();
    await m.load();
    final turnedOn = await m.addAccount(account('rajhi', AccountType.debit), opening: sar(5000));
    expect(turnedOn, isNull);
    expect(m.state.book.balanceOf('rajhi'), sar(5000));
    expect(m.state.hasBook, isTrue);

    final again = cubit();
    await again.load();
    expect(again.state.book.balanceOf('rajhi'), sar(5000));
  });

  test('adding a loan turns on Loans once; adding a person turns on People', () async {
    final m = cubit();
    await m.load();
    expect(await m.addAccount(account('car', AccountType.loan, side: AccountSide.owe), opening: sar(80000)), MoneyFeature.loans);
    expect(await m.addAccount(account('car2', AccountType.loan, side: AccountSide.owe)), isNull, reason: 'already on');
    expect(m.state.settings.has(MoneyFeature.loans), isTrue);
    final p = await m.personAccount('Faisal', 'SAR', owesMe: true);
    expect(m.state.settings.has(MoneyFeature.people), isTrue);
    expect(await m.personAccount(' faisal ', 'SAR', owesMe: true), p, reason: 'the same person is reused');
    expect((await m.personAccount('Faisal', 'SAR', owesMe: false)).id, isNot(p.id), reason: 'owing them is its own account');
    expect((await m.personAccount('FAISAL', 'SAR', owesMe: false)).name, 'Faisal', reason: 'the name they were first given');
    final ahmad = await m.personAccount('أحمد', 'SAR', owesMe: true);
    expect(await m.personAccount('احمد ', 'SAR', owesMe: true), ahmad, reason: 'however the alef was typed');
  });

  test('an entry that doesn’t balance is refused and nothing is saved', () async {
    final m = cubit();
    await m.load();
    await m.addAccount(account('rajhi', AccountType.debit));
    final bad = BookEntry(
      id: 'bad',
      date: DateTime(2026, 11, 10),
      template: EntryTemplate.spend,
      baseCurrency: 'SAR',
      lines: const [
        EntryLine(accountId: 'rajhi', amount: -100, currency: 'SAR', baseAmount: -100),
        EntryLine(accountId: 'category.groceries', amount: 90, currency: 'SAR', baseAmount: 90),
      ],
    );
    await expectLater(m.saveEntry(bad), throwsA(isA<BookRejected>()));
    expect(m.state.entries, isEmpty);
    expect(await store.entries.load(), isEmpty);
  });

  test('a spend lowers the account; editing it keeps one entry; deleting it restores the balance', () async {
    final m = cubit();
    await m.load();
    final rajhi = account('rajhi', AccountType.debit);
    await m.addAccount(rajhi, opening: sar(1000));
    final groceries = m.state.book.accounts['category.groceries']!;
    final e = m.builder.spend(rajhi, groceries, sar(120), DateTime(2026, 11, 9));
    await m.saveEntry(e);
    expect(m.state.book.balanceOf('rajhi'), sar(880));
    final edited = m.builder.spend(rajhi, groceries, sar(200), DateTime(2026, 11, 9));
    await m.saveEntry(BookEntry.fromJson({...edited.toJson(), 'id': e.id}));
    expect(m.state.entries.where((x) => x.template == EntryTemplate.spend), hasLength(1));
    expect(m.state.book.balanceOf('rajhi'), sar(800));
    await m.deleteEntry(e.id);
    expect(m.state.book.balanceOf('rajhi'), sar(1000));
  });

  test('a used account is archived, an unused one deleted', () async {
    final m = cubit();
    await m.load();
    await m.addAccount(account('used', AccountType.cash), opening: sar(10));
    await m.addAccount(account('unused', AccountType.cash));
    await m.removeAccount('used');
    await m.removeAccount('unused');
    expect(m.state.accounts.singleWhere((a) => a.id == 'used').archived, isTrue);
    expect(m.state.accounts.any((a) => a.id == 'unused'), isFalse);
  });

  group('hand-valued assets', () {
    test('a new value is dated history; the same value records nothing', () async {
      final m = cubit();
      await m.load();
      final land = account('land', AccountType.asset).copyWith(assetKind: AssetKind.property);
      await m.addAccount(land, opening: sar(200000), openedOn: DateTime(2025, 1, 1));
      expect(await m.revalue(land, sar(240000), DateTime(2026, 6, 1)), isTrue);
      expect(await m.revalue(land, sar(240000), DateTime(2026, 7, 1)), isFalse);
      expect(m.state.book.balanceOf('land'), sar(240000));
      expect(m.valueHistory('land'), [(DateTime(2025, 1, 1), sar(200000)), (DateTime(2026, 6, 1), sar(240000))]);
    });

    test('a value back-dated before a later one only changes the history before it', () async {
      final m = cubit();
      await m.load();
      final car = account('car', AccountType.asset).copyWith(assetKind: AssetKind.vehicle);
      await m.addAccount(car, opening: sar(100000), openedOn: DateTime(2025, 1, 1));
      await m.revalue(car, sar(80000), DateTime(2026, 1, 1));
      await m.revalue(car, sar(90000), DateTime(2025, 6, 1));
      expect(m.valueHistory('car').map((p) => p.$2), [sar(100000), sar(90000), sar(80000)]);
    });

    test('deleting a value in the middle keeps what the later value says', () async {
      final m = cubit();
      await m.load();
      final car = account('car', AccountType.asset).copyWith(assetKind: AssetKind.vehicle);
      await m.addAccount(car, opening: sar(100000), openedOn: DateTime(2025, 1, 1));
      await m.revalue(car, sar(90000), DateTime(2025, 6, 1));
      await m.revalue(car, sar(80000), DateTime(2026, 1, 1));
      final middle = m.state.entries.firstWhere((e) => e.date == DateTime(2025, 6, 1));
      await m.deleteEntry(middle.id);
      expect(m.valueHistory('car').map((p) => p.$2), [sar(100000), sar(80000)]);
      expect(m.state.book.issues, isEmpty);
    });

    test('a value dated earlier on the same day as another still leaves the day at the latest value', () async {
      final m = cubit();
      await m.load();
      final car = account('car', AccountType.asset).copyWith(assetKind: AssetKind.vehicle);
      await m.addAccount(car, opening: sar(50), openedOn: DateTime(2026, 1, 1));
      await m.revalue(car, sar(100), DateTime(2026, 3, 5, 15));
      await m.revalue(car, sar(200), DateTime(2026, 3, 5, 9));
      expect(m.state.book.balanceOf('car'), sar(200));
      expect(m.valueHistory('car').last, (DateTime(2026, 3, 5), sar(200)));
    });

    test('a sale whose payoff the book would refuse saves nothing', () async {
      final m = cubit();
      await m.load();
      final rajhi = account('rajhi', AccountType.debit);
      final loan = account('loan', AccountType.loan, side: AccountSide.owe, ccy: 'EGP');
      final car = account('car', AccountType.asset).copyWith(assetKind: AssetKind.vehicle, securedLoanId: 'loan');
      await m.addAccount(rajhi, opening: sar(1000));
      await m.addAccount(loan, opening: MinorUnits.fromMajor(13000, 'EGP'));
      await m.addAccount(car, opening: sar(85000));
      final before = m.state.entries.length;
      await expectLater(
        m.sellAsset(car, proceeds: sar(90000), into: rajhi, date: DateTime(2026, 11, 10), payOffLoan: true),
        throwsA(anything),
      );
      expect(m.state.entries, hasLength(before));
      expect(m.state.book.accounts['car']!.archived, isFalse);
    });

    test('selling with its loan pays the loan off from the sale and archives the asset', () async {
      final m = cubit();
      await m.load();
      final rajhi = account('rajhi', AccountType.debit);
      final loan = account('loan', AccountType.loan, side: AccountSide.owe);
      final car = account('car', AccountType.asset).copyWith(assetKind: AssetKind.vehicle, securedLoanId: 'loan');
      await m.addAccount(rajhi, opening: sar(1000));
      await m.addAccount(loan, opening: sar(30000));
      await m.addAccount(car, opening: sar(85000));
      await m.sellAsset(car, proceeds: sar(90000), into: rajhi, date: DateTime(2026, 11, 10), payOffLoan: true);
      expect(m.state.book.balanceOf('car'), 0);
      expect(m.state.book.balanceOf('loan'), 0);
      expect(m.state.book.balanceOf('rajhi'), sar(1000 + 90000 - 30000));
      expect(m.state.book.accounts['car']!.archived, isTrue);
      expect(m.state.book.issues, isEmpty);
    });
  });

  test('an account whose opening the book refuses (no rate yet) isn’t saved at all', () async {
    final m = MoneyCubit(
      store: store,
      baseCurrency: () => 'SAR',
      rates: () => FXRates(base: 'SAR', rates: const {'SAR': 1}, updatedAt: DateTime(2026, 11, 7)),
      newId: () => 'id${++ids}',
    );
    await m.load();
    await expectLater(m.addAccount(account('cib', AccountType.debit, ccy: 'EGP'), opening: 100000), throwsA(anything));
    expect(m.state.accounts.any((a) => a.id == 'cib'), isFalse);
    expect((await store.accounts.load()).any((a) => a.id == 'cib'), isFalse);
  });

  test('an archived account still holding money stays in net worth', () async {
    final m = cubit();
    await m.load();
    await m.addAccount(account('wallet', AccountType.cash), opening: sar(1000));
    await m.removeAccount('wallet');
    expect(m.state.book.accounts['wallet']!.archived, isTrue);
    expect(m.state.book.netWorth('SAR', rates).amount, closeTo(1000, 1e-9));
  });

  group('one Left to spend', () {
    test('planned payments still to come this month come off it, on every screen alike', () async {
      final m = cubit(now: DateTime(2026, 11, 10));
      await m.load();
      final rajhi = account('rajhi', AccountType.debit);
      await m.addAccount(rajhi, opening: sar(5000));
      await m.setBudget('category.home', sar(4000));
      await m.saveEntry(m.builder.spend(rajhi, m.state.book.accounts['category.home']!, sar(500), DateTime(2026, 11, 2)));
      await m.saveRecurring(RecurringPayment(id: 'rent', name: 'Rent', amount: sar(3000), fromAccountId: 'rajhi', categoryId: 'category.home', start: DateTime(2026, 11, 20)));
      // Not in a budgeted category: not promised from the budget.
      await m.saveRecurring(RecurringPayment(id: 'gym', name: 'Gym', amount: sar(200), fromAccountId: 'rajhi', categoryId: 'category.health', start: DateTime(2026, 11, 20)));
      final now = m.monthAnalysis(DateTime(2026, 11, 10), currency: 'SAR', rates: rates);
      expect(now.planned, sar(3000));
      expect(now.leftToSpend, sar(500));
      // A past month has nothing still to come.
      expect(m.monthAnalysis(DateTime(2026, 10, 1), currency: 'SAR', rates: rates).planned, 0);
    });

    test('a currency with no rate is named, never silently dropped', () async {
      final m = cubit(now: DateTime(2026, 11, 10));
      await m.load();
      final usd = account('usd', AccountType.debit, ccy: 'USD');
      await m.addAccount(account('rajhi', AccountType.debit), opening: sar(100));
      await m.addAccount(usd);
      final ok = m.monthAnalysis(DateTime(2026, 11, 10), currency: 'SAR', rates: rates);
      expect(ok.complete, isTrue);
      // Spent in dollars on a day the rates had USD; today's don't.
      final withUsd = FXRates(base: 'SAR', rates: const {'SAR': 1, 'USD': 0.2667}, updatedAt: DateTime.utc(2026, 11, 7));
      final builder = EntryBuilder(baseCurrency: 'SAR', rates: withUsd, newId: () => 'id${++ids}');
      await m.saveEntry(builder.spend(usd, m.state.book.accounts['category.dining']!, 1000, DateTime(2026, 11, 3)));
      final a = m.monthAnalysis(DateTime(2026, 11, 10), currency: 'SAR', rates: rates);
      expect(a.missingRates, {'USD'});
      expect(a.complete, isFalse);
    });
  });

  group('holdings and cash', () {
    HoldingTransaction trade(TransactionKind kind, {double qty = 10, double price = 300, double fee = 0, String id = 't1'}) =>
        HoldingTransaction(id: id, instrumentID: 'gold', kind: kind, quantity: qty, unit: PriceUnit.gram, unitPrice: price, fee: fee, currency: 'SAR', date: DateTime(2026, 11, 5));

    /// The two cubits the way `main.dart` wires them: one book, and Money
    /// reloaded whenever Holdings writes.
    Future<(AppCubit, MoneyCubit)> pair() async {
      final m = cubit();
      final a = AppCubit(repository: _OfflineRepository(), bookStore: store);
      a.onBookChanged = (key) => key == null ? m.load() : m.adoptCloudChanges(key);
      a.preferences = await Preferences.create();
      a.emit(a.state.copyWith(initialized: true, baseCurrency: 'SAR', rates: rates));
      await m.load();
      a.emit(a.state.copyWith(transactions: await a.holdings.load()));
      addTearDown(a.close);
      return (a, m);
    }

    Future<void> save(AppCubit a, MoneyCubit m, HoldingTransaction t, String? accountId) async {
      expect(await a.saveTransaction(t, cash: m.cashLegFor(t, accountId), label: 'Gold'), isNull);
    }

    test('a buy paid from the bank lowers it and leaves net worth where it was', () async {
      final (a, m) = await pair();
      await m.addAccount(account('rajhi', AccountType.debit), opening: sar(10000), openedOn: DateTime(2026, 10, 1));
      final before = NetWorthSummary.of(book: m.state.book, holdingsValue: 0, currency: 'SAR', rates: rates).netWorth;
      await save(a, m, trade(TransactionKind.buy, fee: 20), 'rajhi');
      expect(m.state.book.balanceOf('rajhi'), sar(6980));
      expect(m.holdingCashAccount('t1')?.id, 'rajhi');
      final after = NetWorthSummary.of(book: m.state.book, holdingsValue: 3020, currency: 'SAR', rates: rates).netWorth;
      expect(after, before);
      // Not spending, so budgets never see it.
      expect(m.state.book.spending(from: DateTime(2026, 11), to: DateTime(2026, 12)), isEmpty);
    });

    test('a trade and its cash are one entry, and every edit replaces it', () async {
      final (a, m) = await pair();
      await m.addAccount(account('rajhi', AccountType.debit), opening: sar(10000), openedOn: DateTime(2026, 10, 1));
      await save(a, m, trade(TransactionKind.buy), 'rajhi');
      await save(a, m, trade(TransactionKind.buy, qty: 5), 'rajhi');
      expect(m.state.entries.where((e) => e.template.isHoldingEntry), hasLength(1));
      expect(m.state.entries.where((e) => e.template == EntryTemplate.holdingTrade), isEmpty);
      expect(m.state.book.balanceOf('rajhi'), sar(8500));
      final sale = trade(TransactionKind.sell, id: 't2', qty: 2, price: 320, fee: 5);
      await save(a, m, sale, 'rajhi');
      expect(m.state.book.balanceOf('rajhi'), sar(9135));
      // No account takes the cash leg away, and the trade stays.
      await save(a, m, trade(TransactionKind.buy, qty: 5), null);
      expect(m.state.book.balanceOf('rajhi'), sar(10635));
      expect(m.holdingCashAccount('t1'), isNull);
      expect(a.state.transactions.map((t) => t.id), unorderedEquals(['t1', 't2']));
      await save(a, m, trade(TransactionKind.buy, qty: 5), 'rajhi');
      // The sale is deleted first: the buy it sells from cannot go while it stands.
      expect(await a.deleteTransaction(trade(TransactionKind.buy, qty: 5)), isNotNull);
      expect(m.state.book.balanceOf('rajhi'), sar(9135));
      expect(await a.deleteTransaction(sale), isNull);
      expect(m.state.book.balanceOf('rajhi'), sar(8500));
      expect(await a.deleteTransaction(trade(TransactionKind.buy, qty: 5)), isNull);
      expect(m.state.book.balanceOf('rajhi'), sar(10000));
      expect(m.state.entries.where((e) => e.template.isHoldingEntry), isEmpty);
      expect(m.holdingCashAccount('t1'), isNull);
    });

    test('changing the cash account moves the money, and a transfer or a cost of nothing has no cash leg', () async {
      final (a, m) = await pair();
      await m.addAccount(account('rajhi', AccountType.debit), opening: sar(10000), openedOn: DateTime(2026, 10, 1));
      await m.addAccount(account('cash', AccountType.cash), opening: sar(2000), openedOn: DateTime(2026, 10, 1));
      await save(a, m, trade(TransactionKind.buy), 'rajhi');
      expect(m.state.book.balanceOf('rajhi'), sar(7000));
      await save(a, m, trade(TransactionKind.buy), 'cash');
      expect(m.state.book.balanceOf('rajhi'), sar(10000));
      expect(m.state.book.balanceOf('cash'), sar(-1000));
      expect(m.holdingCashAccount('t1')?.id, 'cash');
      expect(m.cashLegFor(trade(TransactionKind.transferIn), 'cash'), isNull);
      expect(m.cashLegFor(trade(TransactionKind.buy, price: 0), 'cash'), isNull);
      expect(m.cashLegFor(trade(TransactionKind.buy), 'nobody'), isNull);
      expect(m.cashLegFor(trade(TransactionKind.buy), null), isNull);
    });

    test('the cash leg is converted at today\'s rate when the account keeps another currency', () async {
      final (a, m) = await pair();
      await m.addAccount(account('egp', AccountType.debit, ccy: 'EGP'), opening: 100000, openedOn: DateTime(2026, 10, 1));
      final leg = m.cashLegFor(trade(TransactionKind.buy, qty: 1, price: 100), 'egp')!;
      expect(leg.currency, 'EGP');
      expect(leg.amount, MinorUnits.fromMajor(1300, 'EGP'));
      expect(leg.baseAmount, sar(100));
      await save(a, m, trade(TransactionKind.buy, qty: 1, price: 100), 'egp');
      expect(m.state.book.balanceOf('egp'), 100000 - leg.amount);
      expect(m.state.entries.firstWhere((e) => e.id == 't1').issues, isEmpty);
    });

    test('a trade is listed in Money only when it moved cash, as the cash that moved', () async {
      final (a, m) = await pair();
      await m.addAccount(account('rajhi', AccountType.debit), opening: sar(10000), openedOn: DateTime(2026, 10, 1));
      await save(a, m, trade(TransactionKind.buy, id: 'paid'), 'rajhi');
      await save(a, m, trade(TransactionKind.buy, id: 'held'), null);
      await save(a, m, trade(TransactionKind.transferIn, id: 'moved'), null);
      expect(m.state.entries.where((e) => e.template.isHoldingEntry), hasLength(3));
      // One entry for the cash, with the id the cash entry of an earlier build had.
      final cashId = LegacyCollapse.holdingCashId('paid');
      expect([for (final e in m.state.entriesNewestFirst) if (e.template == EntryTemplate.holdingTrade) e.id], [cashId]);
      expect(m.state.entriesFor('rajhi').where((e) => e.template == EntryTemplate.holdingTrade).map((e) => e.id), [cashId]);
      expect(m.state.listed.where((e) => e.template.isHoldingEntry), isEmpty, reason: 'no trade is listed as itself');
      final listed = m.state.listed.singleWhere((e) => e.template == EntryTemplate.holdingTrade);
      expect(listed.merchant, 'Gold');
      expect(listed.lines.map((l) => l.accountId), ['rajhi', 'system.holdings']);
      expect(m.state.isTradeView(listed), isTrue);
      // Presented as the cash entry was: the instrument as the title, the cash that left the bank.
      final shown = EntrySummary.of(m.state.entries.firstWhere((e) => e.id == 'paid'), m.state.book, AppLocalizationsEn());
      expect(shown.title, 'Gold');
      expect(shown.amount, sar(3000));
      expect(shown.currency, 'SAR');
      expect(shown.sign, 0);
      expect(shown.subtitle, startsWith(AppLocalizationsEn().tplHoldingTrade));
      // The same summary whether it is given the trade or what Money lists.
      final fromListed = EntrySummary.of(listed, m.state.book, AppLocalizationsEn());
      expect((fromListed.title, fromListed.amount, fromListed.currency, fromListed.sign, fromListed.subtitle), (shown.title, shown.amount, shown.currency, shown.sign, shown.subtitle));
    });

    test('the cash view of a trade is the entry an earlier build kept for it', () async {
      final (a, m) = await pair();
      await m.addAccount(account('rajhi', AccountType.debit), opening: sar(10000), openedOn: DateTime(2026, 10, 1));
      await save(a, m, trade(TransactionKind.buy, id: 'paid', fee: 20), 'rajhi');
      final bank = m.state.accounts.firstWhere((x) => x.id == 'rajhi');
      final old = oldHoldingTrade(m.builder, bank, sar(3020), DateTime(2026, 11, 5), incoming: false, id: LegacyCollapse.holdingCashId('paid'), merchant: 'Gold');
      final view = m.state.listed.singleWhere((e) => e.template == EntryTemplate.holdingTrade);
      expect(view.id, old.id);
      expect(view.merchant, old.merchant);
      expect(view.note, isEmpty);
      expect([for (final l in view.lines) (l.accountId, l.amount, l.currency, l.baseAmount)], [for (final l in old.lines) (l.accountId, l.amount, l.currency, l.baseAmount)]);
      // A stored cash entry of an earlier build is listed as it is, and is not a view.
      await a.bookStore.entries.upsert(oldHoldingTrade(m.builder, bank, sar(500), DateTime(2026, 11, 6), incoming: false, id: 'old-cash', merchant: 'Gold'));
      await m.load();
      final stored = m.state.listed.singleWhere((e) => e.id == 'old-cash');
      expect(m.state.isTradeView(stored), isFalse);
      expect(m.state.isTradeView(view), isTrue);
    });

    test('importing trades and taking the import back touches only those trades', () async {
      final (a, m) = await pair();
      // Already tracked, so the import starts no price refresh.
      a.emit(a.state.copyWith(cards: [WatchCard(id: 'c1', instrumentID: 'metal.XAU', currency: 'SAR', unit: PriceUnit.gram)]));
      HoldingTransaction gold(String id, double qty) =>
          HoldingTransaction(id: id, instrumentID: 'metal.XAU', kind: TransactionKind.buy, quantity: qty, unit: PriceUnit.gram, unitPrice: 300, currency: 'SAR', date: DateTime(2026, 11, 5));
      await m.addAccount(account('rajhi', AccountType.debit), opening: sar(10000), openedOn: DateTime(2026, 10, 1));
      await save(a, m, gold('mine', 10), 'rajhi');
      await save(a, m, gold('held', 1), null);
      final coffee = m.builder.spend(m.state.accounts.firstWhere((x) => x.id == 'rajhi'), m.state.book.accounts['category.dining']!, sar(40), DateTime(2026, 11, 3));
      await m.saveEntry(coffee);
      final before = [for (final r in await store.entries.exportRecords()) (r.item.id, r.order, r.updatedAt, r.deleted)];

      final ids = await a.importTransactions([gold('csv1', 1), gold('csv2', 2)]);
      expect(ids, ['csv1', 'csv2']);
      expect(a.state.transactions.map((t) => t.id).toSet(), {'mine', 'held', 'csv1', 'csv2'});
      expect(m.state.entries.where((e) => e.template.isHoldingEntry).map((e) => e.id).toSet(), {'mine', 'held', 'csv1', 'csv2'});
      expect(m.state.book.balanceOf('rajhi'), sar(10000 - 3000 - 40), reason: 'imported rows moved no cash');

      await a.undoImport(ids);
      expect(a.state.transactions.map((t) => t.id).toSet(), {'mine', 'held'});
      expect(m.state.entries.map((e) => e.id).toSet(), {for (final r in before) if (!r.$4) r.$1});
      final after = [for (final r in await store.entries.exportRecords()) (r.item.id, r.order, r.updatedAt, r.deleted)];
      for (final r in before) {
        expect(after.where((x) => x.$1 == r.$1).single, r, reason: '${r.$1} is as it was');
      }
      expect(m.state.book.balanceOf('rajhi'), sar(10000 - 3000 - 40));
    });

    test('a month\'s spending and income are the same with or without trades', () async {
      final (a, m) = await pair();
      await m.addAccount(account('rajhi', AccountType.debit), opening: sar(10000), openedOn: DateTime(2026, 10, 1));
      await m.saveEntry(m.builder.spend(m.state.accounts.firstWhere((x) => x.id == 'rajhi'), m.state.book.accounts['category.dining']!, sar(40), DateTime(2026, 11, 3)));
      final before = m.monthAnalysis(DateTime(2026, 11, 10), currency: 'SAR', rates: rates);
      await save(a, m, trade(TransactionKind.buy, fee: 20), 'rajhi');
      await save(a, m, trade(TransactionKind.sell, id: 't2', qty: 2, price: 320), 'rajhi');
      await save(a, m, trade(TransactionKind.buy, id: 't3'), null);
      final after = m.monthAnalysis(DateTime(2026, 11, 10), currency: 'SAR', rates: rates);
      expect(after.spent, before.spent);
      expect(after.income, before.income);
      expect(after.byCategory, before.byCategory);
      expect(m.state.uncategorized, isEmpty);
    });

    test('Money does not edit or delete a trade; Holdings does', () async {
      final (a, m) = await pair();
      await m.addAccount(account('rajhi', AccountType.debit), opening: sar(10000), openedOn: DateTime(2026, 10, 1));
      await save(a, m, trade(TransactionKind.buy), 'rajhi');
      await expectLater(m.deleteEntry('t1'), throwsStateError);
      await expectLater(m.saveEntry(m.state.entries.firstWhere((e) => e.id == 't1')), throwsStateError);
      expect(m.state.book.balanceOf('rajhi'), sar(7000));
    });

    test('a cloud change to the entries reloads Money from the store, with or without a cloud copy', () async {
      final (a, m) = await pair();
      await m.addAccount(account('rajhi', AccountType.debit), opening: sar(10000), openedOn: DateTime(2026, 10, 1));
      // Written behind Money's back, as another cubit or device would.
      await a.holdings.upsert(trade(TransactionKind.buy, id: 'other'), cash: m.cashLegFor(trade(TransactionKind.buy), 'rajhi'), baseCurrency: 'SAR');
      expect(m.state.entries.any((e) => e.id == 'other'), isFalse);
      await m.adoptCloudChanges(BookStore.entriesKey);
      expect(m.state.entries.any((e) => e.id == 'other'), isTrue);
      expect(m.state.book.balanceOf('rajhi'), sar(7000));
    });

    group('a trade made before trades were entries', () {
      /// The book as the last build wrote it: the cash half a second entry
      /// beside the trade in the holdings ledger. The first read of the book
      /// folds the two.
      Future<void> writeOldBook() async {
        final t0 = DateTime.utc(2026, 10, 1);
        final bank = account('rajhi', AccountType.debit);
        final b = EntryBuilder(baseCurrency: 'SAR', rates: rates, newId: () => 'opening');
        final opening = b.opening(bank, sar(10000), DateTime(2026, 10, 1));
        final cash = oldHoldingTrade(b, bank, sar(3000), DateTime(2026, 11, 5), incoming: false, id: LegacyCollapse.holdingCashId('t1'), merchant: 'Gold');
        Map<String, dynamic> record(Syncable item, double order, DateTime at) => Record(item: item, order: order, updatedAt: at).toJson();
        await LocalFileStore.writeJson('book.accounts.json', {'records': [record(bank, 0, t0)]});
        await LocalFileStore.writeJson('book.entries.json', {'records': [record(opening, 0, t0), record(cash, 1, t0.add(const Duration(days: 40)))]});
        await LocalFileStore.writeJson('book.recurring.json', {'records': <Object>[]});
        await LocalFileStore.writeJson('money.settings.json', {'records': <Object>[]});
        await LocalFileStore.writeJson('transactions.records.json', {'records': [record(trade(TransactionKind.buy), 0, t0.add(const Duration(days: 40)))]});
      }

      test('editing it changes the cash once, and deleting it gives the cash back', () async {
        await writeOldBook();
        final (a, m) = await pair();
        expect(m.state.book.balanceOf('rajhi'), sar(7000));
        expect(a.state.transactions.map((t) => t.id), ['t1']);
        expect(m.state.entries.where((e) => e.template.isHoldingEntry || e.template == EntryTemplate.holdingTrade).map((e) => e.id), ['t1'], reason: 'one entry, not the trade and its cash');
        expect(m.holdingCashAccount('t1')?.id, 'rajhi');

        final edited = trade(TransactionKind.buy, qty: 5);
        await save(a, m, edited, m.holdingCashAccount('t1')?.id);
        expect(m.state.book.balanceOf('rajhi'), sar(8500));
        expect(m.state.entries.where((e) => e.template.isHoldingEntry || e.template == EntryTemplate.holdingTrade), hasLength(1));

        expect(await a.deleteTransaction(edited), isNull);
        expect(m.state.book.balanceOf('rajhi'), sar(10000));
        expect(m.state.entries.where((e) => e.template.isHoldingEntry || e.template == EntryTemplate.holdingTrade), isEmpty);
      });

      test('removing or changing its cash account works the same', () async {
        await writeOldBook();
        final (a, m) = await pair();
        await m.addAccount(account('cash', AccountType.cash), opening: sar(500), openedOn: DateTime(2026, 10, 1));
        await save(a, m, trade(TransactionKind.buy), 'cash');
        expect(m.state.book.balanceOf('rajhi'), sar(10000));
        expect(m.state.book.balanceOf('cash'), sar(-2500));
        await save(a, m, trade(TransactionKind.buy), null);
        expect(m.state.book.balanceOf('cash'), sar(500));
        expect(m.holdingCashAccount('t1'), isNull);
        expect(a.state.transactions.single.id, 't1');
      });
    });
  });

  group('recurring payments', () {
    test('paying before it is due books today, not the due day', () async {
      final m = cubit(now: DateTime(2026, 11, 10, 9));
      await m.load();
      await m.addAccount(account('rajhi', AccountType.debit), opening: sar(5000));
      await m.saveRecurring(RecurringPayment(id: 'gym', name: 'Gym', amount: sar(200), fromAccountId: 'rajhi', categoryId: 'category.health', start: DateTime(2026, 11, 20)));
      await m.payRecurring(m.state.recurring.single);
      expect(m.state.entries.last.date, DateTime(2026, 11, 10, 9));
      expect(m.state.recurring.single.nextDue(DateTime(2026, 11, 10)), DateTime(2026, 12, 20));
    });

    test('paying records the spend and moves it to next month', () async {
      final m = cubit(now: DateTime(2026, 11, 10));
      await m.load();
      final rajhi = account('rajhi', AccountType.debit);
      await m.addAccount(rajhi, opening: sar(5000));
      final rent = RecurringPayment(id: 'rent', name: 'Rent', amount: sar(3000), fromAccountId: 'rajhi', categoryId: 'category.home', start: DateTime(2026, 11, 12));
      await m.saveRecurring(rent);
      expect(m.state.settings.has(MoneyFeature.recurring), isTrue);
      expect(m.comingUp().single.$2, DateTime(2026, 11, 12));
      await m.payRecurring(m.state.recurring.single);
      expect(m.state.book.balanceOf('rajhi'), sar(2000));
      expect(m.state.entries.last.date, DateTime(2026, 11, 10), reason: 'paid two days early');
      expect(m.state.recurring.single.nextDue(DateTime(2026, 11, 10)), DateTime(2026, 12, 12));
      expect(m.comingUp(), isEmpty, reason: 'December 12 is more than 14 days away');
    });

    test('planned income records income into the account; skipping records nothing', () async {
      final m = cubit(now: DateTime(2026, 11, 10));
      await m.load();
      await m.addAccount(account('rajhi', AccountType.debit), opening: sar(1000));
      await m.saveRecurring(RecurringPayment(id: 'pay', name: 'Salary', amount: sar(18000), fromAccountId: 'rajhi', categoryId: 'category.salary', start: DateTime(2026, 11, 27), incoming: true));
      expect(m.comingUp(days: 30).single.$1.incoming, isTrue);
      expect(m.plannedOutThisMonth(), isEmpty, reason: 'income is not spending');
      await m.payRecurring(m.state.recurring.single);
      expect(m.state.book.balanceOf('rajhi'), sar(19000));
      final entries = m.state.entries.length;
      await m.skipRecurring(m.state.recurring.single);
      expect(m.state.entries, hasLength(entries));
      expect(m.state.recurring.single.next, DateTime(2027, 1, 27));
    });

    test('what is still planned this month counts each weekly payment, overdue ones too, and stops when a plan ends', () async {
      final m = cubit(now: DateTime(2026, 11, 10));
      await m.load();
      await m.addAccount(account('rajhi', AccountType.debit), opening: sar(5000));
      // Due Nov 3 (overdue), 10, 17, 24; December's are not this month.
      await m.saveRecurring(RecurringPayment(id: 'w', name: 'Cleaner', amount: sar(150), fromAccountId: 'rajhi', categoryId: 'category.home', repeat: PlanRepeat.weekly, start: DateTime(2026, 11, 3)));
      // Two payments left, one this month.
      await m.saveRecurring(RecurringPayment(id: 't', name: 'Tabby', amount: sar(250), fromAccountId: 'rajhi', categoryId: 'category.shopping', start: DateTime(2026, 9, 20), times: 4, paid: 2));
      final planned = m.plannedOutThisMonth();
      expect([for (final (r, d) in planned) if (r.id == 'w') d], [DateTime(2026, 11, 3), DateTime(2026, 11, 10), DateTime(2026, 11, 17), DateTime(2026, 11, 24)]);
      expect([for (final (r, d) in planned) if (r.id == 't') d], [DateTime(2026, 11, 20)]);
      final tabby = m.state.recurring.firstWhere((r) => r.id == 't');
      await m.payRecurring(tabby);
      await m.payRecurring(m.state.recurring.firstWhere((r) => r.id == 't'));
      expect(m.state.recurring.firstWhere((r) => r.id == 't').finished, isTrue);
      expect(m.comingUp(days: 365).where((e) => e.$1.id == 't'), isEmpty);
    });
  });

  group('settings', () {
    test('a budget turns Budget on, and zero removes the line', () async {
      final m = cubit();
      await m.load();
      await m.setBudget('category.dining', sar(600));
      expect(m.state.settings.has(MoneyFeature.budget), isTrue);
      expect(m.state.settings.budgets, {'category.dining': sar(600)});
      expect(m.state.settings.budgetCurrency, 'SAR');
      await m.setBudget('category.dining', 0);
      expect(m.state.settings.budgets, isEmpty);
    });

    test('budgets set before the base currency changed are converted, not relabelled', () async {
      var base = 'SAR';
      final both = FXRates(base: 'SAR', rates: const {'SAR': 1, 'EGP': 13}, updatedAt: DateTime(2026, 11, 7));
      final m = MoneyCubit(store: store, baseCurrency: () => base, rates: () => both, newId: () => 'id${++ids}');
      await m.load();
      await m.setBudget('category.groceries', sar(1000));
      base = 'EGP';
      await m.setBudget('category.dining', MinorUnits.fromMajor(500, 'EGP'));
      expect(m.state.settings.budgetCurrency, 'EGP');
      expect(m.state.settings.budgets['category.groceries'], MinorUnits.fromMajor(13000, 'EGP'));
      expect(m.state.settings.budgets['category.dining'], MinorUnits.fromMajor(500, 'EGP'));
    });

    test('moving and hiding Home cards persists', () async {
      final m = cubit();
      await m.load();
      await m.moveCard(HomeCard.assets, 0);
      await m.setCardHidden(HomeCard.holdings, true);
      expect(m.state.settings.visibleCards.first, HomeCard.assets);
      expect(m.state.settings.visibleCards, isNot(contains(HomeCard.holdings)));
      expect(() => m.setCardHidden(HomeCard.needsReview, true), throwsArgumentError);
      final again = cubit();
      await again.load();
      expect(again.state.settings.visibleCards.first, HomeCard.assets);
      expect(again.state.settings.hiddenCards, {HomeCard.holdings});
    });

    test('moving a card past a hidden one keeps the hidden one where it was', () async {
      final m = cubit();
      await m.load();
      await m.setCardHidden(HomeCard.holdings, true);
      // Visible: needsReview, comingUp, accounts, assets. Move assets to 2.
      await m.moveCard(HomeCard.assets, 2);
      expect(m.state.settings.visibleCards, [HomeCard.needsReview, HomeCard.comingUp, HomeCard.assets, HomeCard.accounts]);
      await m.setCardHidden(HomeCard.holdings, false);
      expect(m.state.settings.visibleCards.indexOf(HomeCard.holdings), lessThan(m.state.settings.visibleCards.indexOf(HomeCard.accounts)));
    });
  });

  group('backup', () {
    Future<BackupService> service(BookStore book) async {
      final kv = LocalOnlyCloudKVStore();
      return BackupService(
        watchlistStore: WatchlistStore(cloud: kv),
        customInstrumentStore: CustomInstrumentStore(cloud: kv),
        alertsStore: AlertsStore(cloud: kv),
        bookStore: book,
        preferences: await Preferences.create(cloud: kv),
      );
    }

    test('the book, its recurring payments and settings round-trip through a replace', () async {
      final m = cubit();
      await m.load();
      final rajhi = account('rajhi', AccountType.debit);
      await m.addAccount(rajhi, opening: sar(5000));
      await m.saveRecurring(RecurringPayment(id: 'r', name: 'Gym', amount: sar(200), fromAccountId: 'rajhi', categoryId: 'category.health', start: DateTime(2026, 11, 1)));
      await m.setBudget('category.dining', sar(600));
      final payload = await (await service(store)).buildPayload();
      expect(payload.book, isNotNull);

      final other = await Directory.systemTemp.createTemp('qima_money_restore');
      LocalFileStore.overrideDirectoryForTesting(other);
      try {
        final target = BookStore();
        final t = await service(target);
        // Something on the target the backup doesn't have goes on a replace.
        await target.accounts.upsert(account('stray', AccountType.cash));
        await t.import(payload, mode: BackupImportMode.replace);
        store = target;
        final restored = cubit();
        await restored.load();
        expect(restored.state.book.balanceOf('rajhi'), sar(5000));
        expect(restored.state.accounts.any((a) => a.id == 'stray'), isFalse);
        expect(restored.state.recurring.single.name, 'Gym');
        expect(restored.state.settings.budgets, {'category.dining': sar(600)});
        expect(restored.state.categories(AccountSide.spending), isNotEmpty);
      } finally {
        LocalFileStore.overrideDirectoryForTesting(dir);
        await other.delete(recursive: true);
      }
    });

    test('a backup made before money was ever opened still restores the default categories', () async {
      final payload = await (await service(store)).buildPayload();
      final other = await Directory.systemTemp.createTemp('qima_money_restore2');
      LocalFileStore.overrideDirectoryForTesting(other);
      try {
        store = BookStore();
        final m = cubit();
        await m.load();
        await (await service(store)).import(payload, mode: BackupImportMode.replace);
        await m.load();
        expect(m.state.accounts.map((a) => a.id), containsAll(DefaultCategories.all.map((a) => a.id)));
      } finally {
        LocalFileStore.overrideDirectoryForTesting(dir);
        await other.delete(recursive: true);
      }
    });

    test('a backup from before v5 leaves the book alone', () async {
      final m = cubit();
      await m.load();
      await m.addAccount(account('rajhi', AccountType.debit), opening: sar(5000));
      final old = BackupPayload(
        watchcards: const [],
        holdings: const [],
        transactions: const [],
        customInstruments: const [],
        alerts: const [],
        settings: const BackupSettings(baseCurrency: 'SAR', appLanguage: 'system', appearance: 'system', preferredChartRange: 'month1', widgetRefreshInterval: 15),
      );
      expect(old.book, isNull);
      await (await service(store)).import(old, mode: BackupImportMode.replace);
      await m.load();
      expect(m.state.book.balanceOf('rajhi'), sar(5000));
    });
  });
}
