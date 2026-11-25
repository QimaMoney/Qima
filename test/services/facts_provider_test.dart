import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qima/blocs/holdings_cubit.dart';
import 'package:qima/blocs/market_cubit.dart';
import 'package:qima/models/asset.dart';
import 'package:qima/models/holding_entry_codec.dart';
import 'package:qima/models/holding_transaction.dart';
import 'package:qima/models/instrument_catalog.dart';
import 'package:qima/models/instrument_facts.dart';
import 'package:qima/models/instrument_fundamentals.dart';
import 'package:qima/services/book_store.dart';
import 'package:qima/services/cloud_kv_store.dart';
import 'package:qima/services/facts_provider.dart';
import 'package:qima/services/holdings_ledger.dart';
import 'package:qima/services/local_file_store.dart';
import 'package:qima/services/preferences.dart';
import 'package:qima/services/price_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

int _s(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

String _today() => jsonEncode({
      'chart': {
        'result': [
          {
            'meta': {
              'currency': 'SAR',
              'longName': ' Example Company ',
              'regularMarketPrice': 25.5,
              'chartPreviousClose': 25.0,
              'regularMarketDayHigh': 25.8,
              'regularMarketDayLow': 25.1,
              'fiftyTwoWeekHigh': 30.0,
              'fiftyTwoWeekLow': 20.0,
              'regularMarketTime': _s(DateTime.utc(2026, 11, 25, 11)),
              'currentTradingPeriod': {
                'regular': {'start': _s(DateTime.utc(2026, 11, 25, 7)), 'end': _s(DateTime.utc(2026, 11, 25, 12))},
              },
            },
          },
        ],
      },
    });

String _events() => jsonEncode({
      'chart': {
        'result': [
          {
            'meta': {'currency': 'SAR'},
            'events': {
              'dividends': {
                '2': {'amount': 0.5, 'date': _s(DateTime.utc(2026, 8, 1))},
                '1': {'amount': 0.4, 'date': _s(DateTime.utc(2026, 2, 1))},
                '0': {'amount': 0, 'date': _s(DateTime.utc(2025, 2, 1))},
              },
              'splits': {
                '1': {'numerator': 11, 'denominator': 10, 'date': _s(DateTime.utc(2024, 7, 1))},
                '0': {'numerator': 1, 'denominator': 1, 'date': _s(DateTime.utc(2023, 7, 1))},
              },
            },
          },
        ],
      },
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('qima_facts_test');
    LocalFileStore.overrideDirectoryForTesting(dir);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  final now = DateTime.utc(2026, 11, 25, 11, 30);

  test('reads the day, the session and the name from a one-day chart', () async {
    final provider = YahooFactsProvider(client: MockClient((r) async {
      expect(r.url.query, contains('range=1d'));
      expect(r.headers['User-Agent'], isNotEmpty);
      return http.Response(_today(), 200);
    }));
    final f = (await provider.today('2222.SR', now))!;
    expect(f.name, 'Example Company');
    expect(f.previousClose, 25.0);
    expect(f.yearLow, 20.0);
    expect(f.sessionEnd, DateTime.utc(2026, 11, 25, 12));
    expect(f.isStale(now), isFalse);
  });

  test('keeps paid dividends and real splits, oldest first; null on failure', () async {
    final provider = YahooFactsProvider(client: MockClient((_) async => http.Response(_events(), 200)));
    final events = (await provider.events('2222.SR'))!;
    expect(events.dividends.map((d) => d.amount), [0.4, 0.5]);
    expect(events.splits.single.ratio, closeTo(1.1, 1e-12));
    final failing = YahooFactsProvider(client: MockClient((_) async => http.Response('', 429)));
    expect(await failing.events('2222.SR'), isNull);
    expect(await failing.today('2222.SR', now), isNull);
  });

  test('refreshes stocks only, the day every 15 minutes and events once a day', () async {
    var todayCalls = 0, eventCalls = 0;
    final repository = PriceRepository(
      factsProvider: YahooFactsProvider(client: MockClient((r) async {
        if (r.url.query.contains('events')) {
          eventCalls++;
          return http.Response(_events(), 200);
        }
        if (r.url.query.contains('range=1d')) {
          todayCalls++;
          return http.Response(_today(), 200);
        }
        // Fundamentals: nothing to give.
        return http.Response('', 404);
      })),
    );
    final apple = InstrumentCatalog.instrument('stock.AAPL')!;
    final gold = InstrumentCatalog.instrument('metal.XAU')!;
    var facts = await repository.refreshFacts([apple, gold], const {}, now: now);
    expect(facts.keys, ['stock.AAPL']);
    expect(facts['stock.AAPL']!.dividends, hasLength(2));
    expect(facts['stock.AAPL']!.fundamentals?.hasValuation, isFalse, reason: 'an empty record marks it asked');
    expect((todayCalls, eventCalls), (1, 1));

    facts = await repository.refreshFacts([apple], facts, now: now.add(const Duration(minutes: 5)));
    expect((todayCalls, eventCalls), (1, 1));

    facts = await repository.refreshFacts([apple], facts, now: now.add(const Duration(minutes: 20)));
    expect((todayCalls, eventCalls), (2, 1));
    expect(facts['stock.AAPL']!.dividends, hasLength(2), reason: 'events carried over between daily fetches');

    facts = await repository.refreshFacts([apple], facts, now: now.add(const Duration(hours: 25)));
    expect((todayCalls, eventCalls), (3, 2));
    expect(await repository.cachedFacts(), facts);
  });

  group('fundamentals', () {
    String series(String type, double value, String date, [String? currency]) => jsonEncode({
          'meta': {
            'symbol': ['X'],
            'type': [type],
          },
          type: [
            {'asOfDate': '2025-01-01', 'reportedValue': {'raw': 1}},
            {'asOfDate': date, 'currencyCode': ?currency, 'reportedValue': {'raw': value}},
          ],
        });
    final timeseries = '{"timeseries":{"result":[${[
      series('trailingPeRatio', 38.87, '2026-11-23'),
      series('trailingMarketCap', 5.07e12, '2026-11-23'),
      series('trailingTotalRevenue', 400e9, '2026-09-30', 'TWD'),
      series('trailingNetIncome', 100e9, '2026-09-30', 'TWD'),
      series('quarterlyTotalDebt', 80e9, '2026-09-30', 'TWD'),
      series('quarterlyStockholdersEquity', 100e9, '2026-09-30', 'TWD'),
    ].join(',')}]}}';
    final threeMonths = jsonEncode({
      'chart': {
        'result': [
          {
            'meta': {'currency': 'USD'},
            'indicators': {
              'quote': [
                {
                  'volume': [100, null, 300, 0],
                },
              ],
            },
          },
        ],
      },
    });
    String summary() => jsonEncode({
          'quoteSummary': {
            'result': [
              {
                'summaryDetail': {'beta': {'raw': 1.09}},
                'defaultKeyStatistics': {'trailingEps': {'raw': 8.98}},
                'financialData': {
                  'returnOnEquity': {'raw': 1.42},
                  'returnOnAssets': {'raw': 0.26},
                  'debtToEquity': {'raw': 84.29},
                  'financialCurrency': 'USD',
                },
                'calendarEvents': {
                  'earnings': {
                    'earningsDate': [
                      {'raw': _s(DateTime.utc(2027, 1, 28))},
                    ],
                    'isEarningsDateEstimate': true,
                  },
                },
              },
            ],
          },
        });

    test('reads valuation, financials, volume and the summary through a session', () async {
      var crumbs = 0, summaries = 0;
      final provider = YahooFactsProvider(client: MockClient((r) async {
        if (r.url.host == 'fc.yahoo.com') {
          return http.Response('', 404, headers: {'set-cookie': 'A3=abc; Expires=Fri, 23 Oct 2027 10:00:00 GMT; Path=/, B=x; Path=/'});
        }
        final path = r.url.path;
        if (path.contains('timeseries')) return http.Response(timeseries, 200);
        if (path.contains('/v8/finance/chart')) return http.Response(threeMonths, 200);
        if (path.contains('getcrumb')) {
          crumbs++;
          expect(r.headers['Cookie'], 'A3=abc; B=x');
          return http.Response('crumb$crumbs', 200);
        }
        if (path.contains('quoteSummary')) {
          summaries++;
          // The first token has gone stale.
          if (r.url.queryParameters['crumb'] == 'crumb1') return http.Response('', 401);
          return http.Response(summary(), 200);
        }
        return http.Response('', 404);
      }));
      final f = (await provider.fundamentals('TSM', 'USD', now))!;
      expect(f.peRatio, 38.87);
      expect(f.marketCap, const ReportedAmount(5.07e12, 'USD'), reason: 'market values in the trading currency');
      expect(f.revenue, const ReportedAmount(400e9, 'TWD'));
      expect(f.profitMargin, closeTo(0.25, 1e-12));
      expect(f.debtToEquity, closeTo(0.8429, 1e-12), reason: 'the summary’s figure, leases included');
      expect(f.eps, const ReportedAmount(8.98, 'USD'));
      expect(f.reportedAt, DateTime.utc(2026, 9, 30));
      expect(f.averageVolume, 200);
      expect(f.beta, 1.09);
      expect(f.returnOnEquity, 1.42);
      expect(f.nextEarnings, DateTime.utc(2027, 1, 28));
      expect(f.earningsEstimated, isTrue);
      expect((crumbs, summaries), (2, 2));
      expect(InstrumentFundamentals.fromJson(f.toJson()), f);
    });

    test('without a session the rest still comes back', () async {
      final provider = YahooFactsProvider(client: MockClient((r) async {
        if (r.url.path.contains('timeseries')) return http.Response(timeseries, 200);
        return http.Response('', 404);
      }));
      final f = (await provider.fundamentals('COMI.CA', 'EGP', now))!;
      expect(f.peRatio, 38.87);
      expect(f.beta, isNull);
      expect(f.debtToEquity, closeTo(0.8, 1e-12), reason: 'worked out from the series');
      expect(f.nextEarnings, isNull);
    });

    test('nothing at all is null', () async {
      final provider = YahooFactsProvider(client: MockClient((_) async => http.Response('', 500)));
      expect(await provider.fundamentals('X', 'USD', now), isNull);
    });

    test('the cookie header keeps name=value pairs across commas in dates', () {
      expect(YahooFundamentals.cookieHeader('A3=d=1&S=2; Expires=Fri, 23 Oct 2027 10:00:00 GMT; Secure, B=x'), 'A3=d=1&S=2; B=x');
      expect(YahooFundamentals.cookieHeader(null), isNull);
    });
  });

  group('splits', () {
    final apple = InstrumentCatalog.instrument('stock.AAPL')!;
    final split = StockSplit(date: DateTime.utc(2024, 7, 1), numerator: 11, denominator: 10);
    HoldingTransaction tx(String id, TransactionKind kind, DateTime date) => HoldingTransaction(
          id: id,
          instrumentID: apple.id,
          kind: kind,
          quantity: 100,
          unit: PriceUnit.each,
          unitPrice: 33,
          fee: 2,
          currency: 'USD',
          date: date,
        );

    Future<(HoldingsCubit, HoldingsLedger, Preferences)> cubitWith(List<HoldingTransaction> transactions, {CashLeg? cash}) async {
      final ledger = HoldingsLedger(BookStore());
      for (final t in transactions) {
        await ledger.upsert(t, cash: t.kind == TransactionKind.buy ? cash : null, baseCurrency: 'USD');
      }
      final market = MarketCubit(
        repository: PriceRepository(),
        tracked: () => [apple],
        cardCurrencies: () => const [],
        baseCurrency: () => 'USD',
        evaluateAlerts: (_, _) async {},
        notifyZakatIfDue: () async {},
      );
      market.emit(market.state.copyWith(factsByID: {apple.id: InstrumentFacts(currency: 'USD', fetchedAt: now, splits: [split])}));
      final cubit = HoldingsCubit(
        ledgerStore: ledger,
        market: market,
        baseCurrency: () => 'USD',
        tracked: () => [apple],
        markDataChanged: () async {},
        loadResult: ({required bool failed}) {},
      );
      await cubit.load();
      final preferences = Preferences(cloud: LocalOnlyCloudKVStore(), local: await SharedPreferences.getInstance());
      await cubit.loadSplits(preferences);
      return (cubit, ledger, preferences);
    }

    test('only a split with trades before it is pending', () async {
      final (after, _, _) = await cubitWith([tx('a', TransactionKind.buy, DateTime.utc(2025, 1, 1))]);
      expect(after.pendingSplitsFor(apple), isEmpty);
      final (before, _, _) = await cubitWith([tx('c', TransactionKind.buy, DateTime.utc(2024, 1, 1))]);
      expect(before.pendingSplitsFor(apple), [split]);
    });

    test('adjusting restates earlier share trades and keeps each total; fees and later trades stay', () async {
      final (cubit, ledger, preferences) = await cubitWith([
        tx('a', TransactionKind.buy, DateTime.utc(2024, 1, 1)),
        tx('f', TransactionKind.fee, DateTime.utc(2024, 2, 1)),
        tx('b', TransactionKind.buy, DateTime.utc(2025, 1, 1)),
      ]);
      await cubit.applySplit(apple, split);
      final byID = {for (final t in cubit.state.transactions) t.id: t};
      expect(byID['a']!.quantity, closeTo(110, 1e-9));
      expect(byID['a']!.quantity * byID['a']!.unitPrice, closeTo(3300, 1e-9));
      expect(byID['f']!.quantity, 100);
      expect(byID['b']!.quantity, 100);
      expect(cubit.pendingSplitsFor(apple), isEmpty);
      expect(await preferences.handledSplits, {split.keyFor(apple.id)});
      expect((await ledger.load()).firstWhere((t) => t.id == 'a').quantity, closeTo(110, 1e-9));
    });

    test('adjusting keeps the cash each trade moved', () async {
      const cash = CashLeg(accountId: 'asset.bank', currency: 'USD', amount: 330200, baseAmount: 330200);
      final (cubit, ledger, _) = await cubitWith([tx('a', TransactionKind.buy, DateTime.utc(2024, 1, 1))], cash: cash);
      final before = (await ledger.book.entries.load()).single;
      await cubit.applySplit(apple, split);
      final after = (await ledger.book.entries.load()).single;
      expect(HoldingEntryCodec.cashLegOf(after)?.accountId, 'asset.bank');
      expect(HoldingEntryCodec.cashLegOf(after)?.amount, HoldingEntryCodec.cashLegOf(before)?.amount);
      expect(after.lines.first.amount, before.lines.first.amount, reason: 'the cost is unchanged');
    });

    test('keeping leaves the trades and clears the notice', () async {
      final (cubit, _, _) = await cubitWith([tx('a', TransactionKind.buy, DateTime.utc(2024, 1, 1))]);
      await cubit.keepSplit(apple, split);
      expect(cubit.state.transactions.single.quantity, 100);
      expect(cubit.pendingSplitsFor(apple), isEmpty);
    });
  });
}
