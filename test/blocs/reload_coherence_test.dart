import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qima/blocs/app_blocs.dart';
import 'package:qima/blocs/market_state.dart';
import 'package:qima/blocs/settings_state.dart';
import 'package:qima/models/asset.dart';
import 'package:qima/models/fx_history.dart';
import 'package:qima/models/holding_transaction.dart';
import 'package:qima/models/instrument_catalog.dart';
import 'package:qima/models/price_alert.dart';
import 'package:qima/models/quote.dart';
import 'package:qima/models/watch_card.dart';
import 'package:qima/services/backup/backup_service.dart';
import 'package:qima/services/local_file_store.dart';
import 'package:qima/services/notification_service.dart';
import 'package:qima/services/price_repository.dart';
import 'package:qima/services/widget_snapshot.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/app_blocs.dart';

/// Fetches never finish, so the only changes a test sees are the reload's.
class _StalledRepository extends PriceRepository {
  final Completer<void> never = Completer<void>();

  @override
  Future<Map<String, QuoteSeries>> refreshAll(List<Instrument> instruments, {DateTime? now}) async {
    await never.future;
    return {};
  }

  @override
  Future<QuoteSeries> refresh(Instrument instrument, {DateTime? now}) async => QuoteSeries.empty(instrument.id);

  @override
  Future<FXHistory> backfillFXHistory(List<String> currencies, {bool force = false, DateTime? now}) async => FXHistory.empty;

  @override
  Future<Map<String, QuoteSeries>> backfillInstruments(List<Instrument> instruments, FXHistory fxHistory,
          {bool force = false, DateTime? now}) async =>
      {};
}

class _QuietNotifications extends NotificationService {
  @override
  Future<void> init() async {}

  @override
  Future<bool> isEnabled() async => true;
}

/// What the app holds, as one listener sees it at the moment [cubit] emits
/// [next]: [BlocObserver.onChange] runs before the emitting cubit's own
/// `state` moves, so that cubit's part is taken from [next].
class _View {
  final String baseCurrency;
  final Set<String> cardIDs;
  final Set<String> tradeIDs;
  final Set<String> pricedIDs;

  _View(this.baseCurrency, this.cardIDs, this.tradeIDs, this.pricedIDs);

  factory _View.of(AppBlocs b, BlocBase<Object?> cubit, Object? next) => _View(
        cubit == b.settings ? (next as SettingsState).baseCurrency : b.settings.state.baseCurrency,
        {for (final c in cubit == b.watchlist ? (next as dynamic).cards as List<WatchCard> : b.watchlist.state.cards) c.id},
        {
          for (final t in cubit == b.holdings ? (next as dynamic).transactions as List<HoldingTransaction> : b.holdings.state.transactions) t.id
        },
        (cubit == b.market ? (next as MarketState).seriesByID : b.market.state.seriesByID).keys.toSet(),
      );
}

/// A cubit keeps the observer that was set when it was built, so this is set
/// before the app's cubits are, and told which of them to watch later.
class _Recorder extends BlocObserver {
  final List<_View> views = [];
  AppBlocs? watching;

  @override
  void onChange(BlocBase<dynamic> bloc, Change<dynamic> change) {
    super.onChange(bloc, change);
    final blocs = watching;
    if (blocs != null) views.add(_View.of(blocs, bloc, change.nextState));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const widgetChannel = MethodChannel('home_widget');

  final apple = InstrumentCatalog.instrument('stock.AAPL')!;
  final tesla = InstrumentCatalog.instrument('stock.TSLA')!;

  late int published;
  late _StalledRepository repository;
  late BlocObserver previousObserver;
  late _Recorder recorder;

  setUp(() {
    published = 0;
    repository = _StalledRepository();
    previousObserver = Bloc.observer;
    Bloc.observer = recorder = _Recorder();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(widgetChannel, (call) async {
      if (call.method == 'saveWidgetData') {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        if (args['id'] == WidgetSnapshot.storageKey) {
          jsonDecode(args['data'] as String);
          published++;
        }
        return true;
      }
      return null;
    });
  });

  tearDown(() {
    Bloc.observer = previousObserver;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(widgetChannel, null);
  });

  Future<AppBlocs> started(String name) async {
    LocalFileStore.overrideDirectoryForTesting(await Directory.systemTemp.createTemp(name));
    final blocs = AppBlocs(repository: repository, notificationService: _QuietNotifications());
    await blocs.init();
    return blocs;
  }

  HoldingTransaction buy(String id, Instrument instrument) => HoldingTransaction(
        id: id,
        instrumentID: instrument.id,
        kind: TransactionKind.buy,
        quantity: 2,
        unit: PriceUnit.each,
        unitPrice: 100,
        currency: 'EGP',
        date: DateTime(2025, 1, 1),
      );

  test('a restore never shows new cards or trades with the old base currency or without their prices, and the widgets are told once', () async {
    SharedPreferences.setMockInitialValues({});
    final source = await started('qima_reload_source');
    await source.settings.setBaseCurrency('EGP');
    await source.watchlist.addCard(WatchCard(id: 'c1', instrumentID: apple.id, currency: 'EGP', unit: PriceUnit.each));
    await source.alerts.saveAlert(PriceAlert(id: 'a1', cardID: 'c1', kind: AlertKind.above, target: 1, createdAt: DateTime(2025)));
    await source.holdings.saveTransaction(buy('t1', tesla));
    final payload = await source.sync.backupService.buildPayload();
    await source.settings.setBaseCurrency('USD');

    final dest = await started('qima_reload_dest');
    expect(dest.settings.state.baseCurrency, 'USD');
    expect(dest.market.state.seriesByID, isNot(contains(apple.id)));
    expect(dest.market.state.seriesByID, isNot(contains(tesla.id)));
    await pumpEventQueue();
    final publishedBefore = published;

    recorder.watching = dest;
    await dest.sync.restoreFromBackup(payload, mode: BackupImportMode.replace);
    recorder.watching = null;
    await pumpEventQueue();

    expect(dest.watchlist.state.cards.map((c) => c.id), contains('c1'));
    expect(dest.holdings.state.transactions.map((t) => t.id), contains('t1'));
    expect(dest.settings.state.baseCurrency, 'EGP');

    final seenNew = recorder.views.where((v) => v.cardIDs.contains('c1') || v.tradeIDs.contains('t1')).toList();
    expect(seenNew, isNotEmpty);
    for (final view in seenNew) {
      expect(view.baseCurrency, 'EGP', reason: 'restored cards and trades are never valued in the old base currency');
      if (view.cardIDs.contains('c1')) expect(view.pricedIDs, contains(apple.id));
      if (view.tradeIDs.contains('t1')) expect(view.pricedIDs, contains(tesla.id));
    }
    expect(published - publishedBefore, 1, reason: 'one snapshot for the whole restore');
    expect(published, greaterThan(publishedBefore));

    await source.close();
    await dest.close();
  });

  test('a reload that takes several steps tells the widgets once, when it is done', () async {
    SharedPreferences.setMockInitialValues({});
    final blocs = await started('qima_reload_steps');
    await pumpEventQueue();
    final publishedBefore = published;

    await blocs.holdWidgets(() async {
      blocs.seed(cards: [WatchCard(id: 'c1', instrumentID: apple.id, currency: 'USD', unit: PriceUnit.each)]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      blocs.seed(transactions: [buy('t1', tesla)]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      blocs.seed(baseCurrency: 'EGP');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(published, publishedBefore, reason: 'nothing goes out half-way');
    });
    await pumpEventQueue();

    expect(published - publishedBefore, 1);
    await blocs.close();
  });

  test('a reload that ends after the app is closed does not publish', () async {
    SharedPreferences.setMockInitialValues({});
    final blocs = await started('qima_reload_closed');
    await pumpEventQueue();
    final finish = Completer<void>();
    final publishedBefore = published;

    final held = blocs.holdWidgets(() async {
      blocs.seed(cards: [WatchCard(id: 'c1', instrumentID: apple.id, currency: 'USD', unit: PriceUnit.each)]);
      await finish.future;
    });
    await blocs.close();
    finish.complete();
    await held;
    await pumpEventQueue();

    expect(published, publishedBefore);
  });

  test('a cloud reload shows new cards and trades with their prices and tells the widgets once', () async {
    SharedPreferences.setMockInitialValues({});
    final blocs = await started('qima_reload_cloud');
    await pumpEventQueue();
    // What another device wrote, now in the local stores.
    await blocs.watchlist.watchlistStore.upsert(WatchCard(id: 'c1', instrumentID: apple.id, currency: 'USD', unit: PriceUnit.each));
    await blocs.holdings.ledgerStore.upsert(buy('t1', tesla), baseCurrency: 'USD');
    blocs.seed(iCloudSyncEnabled: true);
    final publishedBefore = published;

    recorder.watching = blocs;
    await blocs.sync.adoptCloudChanges();
    recorder.watching = null;
    await pumpEventQueue();

    expect(blocs.watchlist.state.cards.map((c) => c.id), contains('c1'));
    expect(blocs.holdings.state.transactions.map((t) => t.id), contains('t1'));
    for (final view in recorder.views) {
      if (view.cardIDs.contains('c1')) expect(view.pricedIDs, contains(apple.id));
      if (view.tradeIDs.contains('t1')) expect(view.pricedIDs, contains(tesla.id));
    }
    expect(published - publishedBefore, 1);

    await blocs.close();
  });
}
