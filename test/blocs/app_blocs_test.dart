import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qima/blocs/alerts_cubit.dart';
import 'package:qima/blocs/app_blocs.dart';
import 'package:qima/blocs/app_cubit.dart';
import 'package:qima/blocs/holdings_cubit.dart';
import 'package:qima/blocs/market_cubit.dart';
import 'package:qima/blocs/market_state.dart';
import 'package:qima/blocs/settings_cubit.dart';
import 'package:qima/blocs/sync_cubit.dart';
import 'package:qima/blocs/watchlist_cubit.dart';
import 'package:qima/blocs/zakat_cubit.dart';
import 'package:qima/models/asset.dart';
import 'package:qima/models/fx_history.dart';
import 'package:qima/models/holding.dart';
import 'package:qima/models/holding_transaction.dart';
import 'package:qima/models/instrument_catalog.dart';
import 'package:qima/models/money.dart';
import 'package:qima/models/quote.dart';
import 'package:qima/models/watch_card.dart';
import 'package:qima/services/local_file_store.dart';
import 'package:qima/services/notification_service.dart';
import 'package:qima/services/price_repository.dart';
import 'package:qima/services/widget_snapshot.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/app_blocs.dart';

/// Answers every fetch with one quote per instrument asked for, and counts
/// what was asked, so a test can see which cubit triggered which fetch.
class _CountingRepository extends PriceRepository {
  final List<String> refreshed = [];
  int refreshAllCalls = 0;
  bool returnNothing = false;

  QuoteSeries _series(Instrument i) =>
      QuoteSeries(instrumentID: i.id, quotes: [Quote(instrumentID: i.id, timestamp: DateTime(2024, 6, 10), canonicalUSD: 100)]);

  @override
  Future<QuoteSeries> refresh(Instrument instrument, {DateTime? now}) async {
    refreshed.add(instrument.id);
    return _series(instrument);
  }

  @override
  Future<Map<String, QuoteSeries>> refreshAll(List<Instrument> instruments, {DateTime? now}) async {
    refreshAllCalls++;
    if (returnNothing) return {};
    return {for (final i in instruments) i.id: _series(i)};
  }

  @override
  Future<FXHistory> backfillFXHistory(List<String> currencies, {bool force = false, DateTime? now}) async => FXHistory.empty;

  @override
  Future<Map<String, QuoteSeries>> backfillInstruments(List<Instrument> instruments, FXHistory fxHistory, {bool force = false, DateTime? now}) async => {};
}

class _FakeNotificationService extends NotificationService {
  @override
  Future<void> init() async {}

  @override
  Future<bool> isEnabled() async => true;
}

/// Records every state change of every cubit, in the order they happen.
class _Recorder extends BlocObserver {
  final List<(Type, Object?)> changes = [];

  @override
  void onChange(BlocBase<dynamic> bloc, Change<dynamic> change) {
    super.onChange(bloc, change);
    changes.add((bloc.runtimeType, change.nextState));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  final gold = InstrumentCatalog.instrument('metal.XAU')!;
  final silver = InstrumentCatalog.instrument('metal.XAG')!;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('qima_app_blocs_test');
    LocalFileStore.overrideDirectoryForTesting(tempDir);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('start-up', () {
    test('the app is marked initialized only after every other cubit has loaded', () async {
      final recorder = _Recorder();
      final previous = Bloc.observer;
      Bloc.observer = recorder;
      addTearDown(() => Bloc.observer = previous);

      final blocs = AppBlocs(repository: _CountingRepository(), notificationService: _FakeNotificationService());
      await blocs.init();

      final initializedAt = recorder.changes.indexWhere((c) => c.$1 == AppCubit && (c.$2 as dynamic).initialized == true);
      expect(initializedAt, greaterThanOrEqualTo(0));
      for (final loaded in [SettingsCubit, ZakatCubit, WatchlistCubit, AlertsCubit, HoldingsCubit, SyncCubit, MarketCubit]) {
        final at = recorder.changes.indexWhere((c) => c.$1 == loaded);
        expect(at, inInclusiveRange(0, initializedAt - 1), reason: '$loaded must emit its loaded state before the app is initialized');
      }
      await blocs.close();
    });

    test('the cloud settles and the backup service exists before any store is read', () async {
      final blocs = AppBlocs(repository: _CountingRepository(), notificationService: _FakeNotificationService());
      expect(blocs.sync.backupServiceOrNull, isNull);
      await blocs.init();
      expect(blocs.sync.backupServiceOrNull, isNotNull);
      // The seeded default watchlist comes from the loaded preferences.
      expect(blocs.watchlist.state.cards, isNotEmpty);
      await blocs.close();
    });
  });

  group('MarketCubit callbacks', () {
    MarketCubit make(
      _CountingRepository repository, {
      List<Instrument> tracked = const [],
      void Function(Map<String, QuoteSeries>, FXRates)? onAlerts,
      void Function()? onZakat,
    }) =>
        MarketCubit(
          repository: repository,
          tracked: () => tracked,
          cardCurrencies: () => const ['USD'],
          baseCurrency: () => 'USD',
          evaluateAlerts: (series, rates) async => onAlerts?.call(series, rates),
          notifyZakatIfDue: () async => onZakat?.call(),
        );

    test('a refresh that brings prices evaluates alerts on them and runs the zakat reminder', () async {
      Map<String, QuoteSeries>? seen;
      var zakat = 0;
      final market = make(_CountingRepository(), tracked: [gold], onAlerts: (series, _) => seen = series, onZakat: () => zakat++);

      await market.refreshAll();

      expect(seen?.keys, contains(gold.id));
      expect(seen, market.state.seriesByID);
      expect(zakat, 1);
      await market.close();
    });

    test('a refresh that brings nothing evaluates no alerts', () async {
      var evaluated = false;
      final repository = _CountingRepository()..returnNothing = true;
      final market = make(repository, tracked: [gold], onAlerts: (_, _) => evaluated = true);

      await market.refreshAll();

      expect(evaluated, isFalse);
      expect(market.state.phase, RefreshPhase.failed);
      await market.close();
    });

    test('refreshing one instrument evaluates alerts too', () async {
      var evaluated = 0;
      final market = make(_CountingRepository(), onAlerts: (_, _) => evaluated++);

      await market.refresh(gold);

      expect(evaluated, 1);
      await market.close();
    });
  });

  group('holdings and the prices', () {
    HoldingTransaction buy(Instrument instrument) => HoldingTransaction.fromLot(HoldingLot(
          id: 'l-${instrument.id}',
          instrumentID: instrument.id,
          quantity: 1,
          unit: PriceUnit.troyOunce,
          unitCost: 10,
          costCurrency: 'USD',
          date: DateTime(2024, 1, 1),
        ));

    test('a trade in an instrument nothing tracks yet fetches its price; one in a tracked instrument does not', () async {
      final repository = _CountingRepository();
      final blocs = AppBlocs(repository: repository, notificationService: _FakeNotificationService());
      blocs.seed(cards: [WatchCard(id: 'c1', instrumentID: gold.id, currency: 'USD', unit: PriceUnit.troyOunce)]);

      await blocs.holdings.saveTransaction(buy(gold));
      await pumpEventQueue();
      expect(repository.refreshed, isEmpty, reason: 'gold is on the watchlist, so it is refreshed with the rest');

      await blocs.holdings.saveTransaction(buy(silver));
      await pumpEventQueue();
      expect(repository.refreshed, [silver.id]);
      await blocs.close();
    });

    test('adding a card for a new instrument puts its cached price in the market state and fetches it', () async {
      final repository = _CountingRepository();
      final blocs = AppBlocs(repository: repository, notificationService: _FakeNotificationService());

      await blocs.watchlist.addCard(WatchCard(id: 'c1', instrumentID: silver.id, currency: 'USD', unit: PriceUnit.troyOunce));
      await pumpEventQueue();

      expect(blocs.market.state.seriesByID, contains(silver.id));
      expect(repository.refreshed, contains(silver.id));
      await blocs.close();
    });
  });

  group('home-screen widgets', () {
    const channel = MethodChannel('home_widget');
    var published = 0;
    Map<String, dynamic>? last;

    setUp(() {
      published = 0;
      last = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'saveWidgetData') {
          final args = Map<String, dynamic>.from(call.arguments as Map);
          if (args['id'] == WidgetSnapshot.storageKey) {
            published++;
            last = jsonDecode(args['data'] as String) as Map<String, dynamic>;
          }
          return true;
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    test('nothing is published before start-up finishes, then every change a widget shows is, and only those', () async {
      final blocs = AppBlocs(repository: _CountingRepository(), notificationService: _FakeNotificationService());

      blocs.market.emit(blocs.market.state.copyWith(rates: FXRates(base: 'USD', rates: const {'USD': 1, 'EGP': 48}, updatedAt: DateTime(2024, 6, 10))));
      await pumpEventQueue();
      expect(published, 0);

      blocs.app.emit(blocs.app.state.copyWith(initialized: true));
      await pumpEventQueue();
      expect(published, 1);
      expect((last!['currencies'] as Map).keys, contains('EGP'));

      // A refresh phase change is not something a widget shows.
      blocs.market.emit(blocs.market.state.copyWith(phase: RefreshPhase.refreshing));
      await pumpEventQueue();
      expect(published, 1);

      blocs.seed(hideBalances: true);
      await pumpEventQueue();
      expect(published, 2);
      expect(last!['hideBalances'], isTrue);

      blocs.seed(cards: [WatchCard(id: 'c1', instrumentID: gold.id, currency: 'USD', unit: PriceUnit.troyOunce)]);
      await pumpEventQueue();
      expect(published, 3);
      await blocs.close();
    });
  });
}
