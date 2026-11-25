import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qima/blocs/app_cubit.dart';
import 'package:qima/models/asset.dart';
import 'package:qima/models/holding_transaction.dart';
import 'package:qima/models/instrument_catalog.dart';
import 'package:qima/models/instrument_facts.dart';
import 'package:qima/services/cloud_kv_store.dart';
import 'package:qima/services/facts_provider.dart';
import 'package:qima/services/holdings_store.dart';
import 'package:qima/services/local_file_store.dart';
import 'package:qima/services/preferences.dart';
import 'package:qima/services/price_repository.dart';
import 'package:qima/services/transactions_store.dart';
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
        todayCalls++;
        return http.Response(_today(), 200);
      })),
    );
    final apple = InstrumentCatalog.instrument('stock.AAPL')!;
    final gold = InstrumentCatalog.instrument('metal.XAU')!;
    var facts = await repository.refreshFacts([apple, gold], const {}, now: now);
    expect(facts.keys, ['stock.AAPL']);
    expect(facts['stock.AAPL']!.dividends, hasLength(2));
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

    Future<AppCubit> cubitWith(List<HoldingTransaction> transactions) async {
      final store = TransactionsStore(legacyLots: HoldingsStore());
      await store.addAll(transactions);
      final cubit = AppCubit(transactionsStore: store);
      cubit.preferences = Preferences(cloud: LocalOnlyCloudKVStore(), local: await SharedPreferences.getInstance());
      cubit.emit(cubit.state.copyWith(
        initialized: true,
        transactions: await store.load(),
        factsByID: {apple.id: InstrumentFacts(currency: 'USD', fetchedAt: now, splits: [split])},
      ));
      return cubit;
    }

    test('only a split with trades before it is pending', () async {
      final after = await cubitWith([tx('a', TransactionKind.buy, DateTime.utc(2025, 1, 1))]);
      expect(after.pendingSplitsFor(apple), isEmpty);
      final before = await cubitWith([tx('c', TransactionKind.buy, DateTime.utc(2024, 1, 1))]);
      expect(before.pendingSplitsFor(apple), [split]);
    });

    test('adjusting restates earlier share trades and keeps each total; fees and later trades stay', () async {
      final cubit = await cubitWith([
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
      expect(await cubit.preferences.handledSplits, {split.keyFor(apple.id)});
      expect((await TransactionsStore(legacyLots: HoldingsStore()).load()).firstWhere((t) => t.id == 'a').quantity, closeTo(110, 1e-9));
    });

    test('keeping leaves the trades and clears the notice', () async {
      final cubit = await cubitWith([tx('a', TransactionKind.buy, DateTime.utc(2024, 1, 1))]);
      await cubit.keepSplit(apple, split);
      expect(cubit.state.transactions.single.quantity, 100);
      expect(cubit.pendingSplitsFor(apple), isEmpty);
    });
  });
}
