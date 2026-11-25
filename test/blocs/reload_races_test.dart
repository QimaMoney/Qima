import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qima/blocs/app_blocs.dart';
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
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/app_blocs.dart';

/// Holds the cached price of one instrument until released, and says when it
/// was asked for: the time a reload spends reading prices, in which the
/// person can still change something.
class _GatedRepository extends PriceRepository {
  final String gatedID;
  final Completer<void> gate = Completer<void>();
  final Completer<void> hit = Completer<void>();

  _GatedRepository(this.gatedID);

  @override
  Future<QuoteSeries> cachedSeries(Instrument instrument) async {
    if (instrument.id == gatedID) {
      if (!hit.isCompleted) hit.complete();
      await gate.future;
    }
    return super.cachedSeries(instrument);
  }

  @override
  Future<QuoteSeries> refresh(Instrument instrument, {DateTime? now}) async => QuoteSeries.empty(instrument.id);

  @override
  Future<Map<String, QuoteSeries>> refreshAll(List<Instrument> instruments, {DateTime? now}) async => {};

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final apple = InstrumentCatalog.instrument('stock.AAPL')!;
  final microsoft = InstrumentCatalog.instrument('stock.MSFT')!;
  final tesla = InstrumentCatalog.instrument('stock.TSLA')!;

  late _GatedRepository repository;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repository = _GatedRepository(apple.id);
  });

  Future<AppBlocs> started(String name, [PriceRepository? prices]) async {
    LocalFileStore.overrideDirectoryForTesting(await Directory.systemTemp.createTemp(name));
    final blocs = AppBlocs(repository: prices ?? repository, notificationService: _QuietNotifications());
    await blocs.init();
    return blocs;
  }

  HoldingTransaction buy(String id, Instrument instrument) => HoldingTransaction(
        id: id,
        instrumentID: instrument.id,
        kind: TransactionKind.buy,
        quantity: 1,
        unit: PriceUnit.each,
        unitPrice: 10,
        currency: 'USD',
        date: DateTime(2025, 1, 1),
      );

  /// Another device added an Apple card, so a reload has a price to read.
  Future<AppBlocs> withRemoteCard(String name) async {
    final blocs = await started(name);
    await blocs.watchlist.watchlistStore.upsert(WatchCard(id: 'remote', instrumentID: apple.id, currency: 'USD', unit: PriceUnit.each));
    blocs.seed(iCloudSyncEnabled: true);
    return blocs;
  }

  group('a local change made while a reload reads prices', () {
    test('a card added is still shown', () async {
      final blocs = await withRemoteCard('qima_race_card');
      final reload = blocs.sync.adoptCloudChanges();
      await repository.hit.future;

      await blocs.watchlist.addCard(WatchCard(id: 'local', instrumentID: microsoft.id, currency: 'USD', unit: PriceUnit.each));
      repository.gate.complete();
      await reload;

      expect(blocs.watchlist.state.cards.map((c) => c.id), containsAll(['remote', 'local']));
      await blocs.close();
    });

    test('an alert saved is still shown', () async {
      final blocs = await withRemoteCard('qima_race_alert');
      final reload = blocs.sync.adoptCloudChanges();
      await repository.hit.future;

      await blocs.alerts.saveAlert(PriceAlert(id: 'a1', cardID: 'remote', kind: AlertKind.above, target: 1, createdAt: DateTime(2025)));
      repository.gate.complete();
      await reload;

      expect(blocs.alerts.state.alerts.map((a) => a.id), contains('a1'));
      await blocs.close();
    });

    test('a trade saved is still shown', () async {
      final blocs = await withRemoteCard('qima_race_trade');
      final reload = blocs.sync.adoptCloudChanges();
      await repository.hit.future;

      await blocs.holdings.saveTransaction(buy('t1', tesla));
      repository.gate.complete();
      await reload;

      expect(blocs.holdings.state.transactions.map((t) => t.id), contains('t1'));
      await blocs.close();
    });

    test('during a restore, a trade saved is still shown', () async {
      final source = await started('qima_race_restore_source', _GatedRepository(''));
      await source.watchlist.addCard(WatchCard(id: 'remote', instrumentID: apple.id, currency: 'USD', unit: PriceUnit.each));
      final payload = await source.sync.backupService.buildPayload();
      await source.close();

      final blocs = await started('qima_race_restore');
      final restore = blocs.sync.restoreFromBackup(payload, mode: BackupImportMode.replace);
      await repository.hit.future;

      await blocs.holdings.saveTransaction(buy('t1', tesla));
      repository.gate.complete();
      await restore;

      expect(blocs.watchlist.state.cards.map((c) => c.id), contains('remote'));
      expect(blocs.holdings.state.transactions.map((t) => t.id), contains('t1'));
      await blocs.close();
    });

    test('a restore changes only the choices a backup holds', () async {
      final blocs = await started('qima_race_settings');
      final read = await blocs.settings.readRestored();

      await blocs.settings.setHideBalances(true);
      blocs.settings.adopt(read);

      expect(blocs.settings.state.hideBalances, isTrue);
    });
  });

  test('reloads run one after another', () async {
    final blocs = await withRemoteCard('qima_race_order');
    final order = <String>[];
    final first = blocs.sync.adoptCloudChanges().then((_) => order.add('first'));
    await repository.hit.future;
    final second = blocs.sync.adoptCloudChanges().then((_) => order.add('second'));
    await pumpEventQueue();
    expect(order, isEmpty, reason: 'the second waits for the first, which waits for the price');

    repository.gate.complete();
    await Future.wait([first, second]);

    expect(order, ['first', 'second']);
    await blocs.close();
  });
}
