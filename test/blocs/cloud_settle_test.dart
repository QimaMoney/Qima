import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qima/blocs/app_blocs.dart';
import 'package:qima/models/asset.dart';
import 'package:qima/models/fx_history.dart';
import 'package:qima/models/instrument_catalog.dart';
import 'package:qima/models/quote.dart';
import 'package:qima/models/watch_card.dart';
import 'package:qima/services/local_file_store.dart';
import 'package:qima/services/notification_service.dart';
import 'package:qima/services/price_repository.dart';
import 'package:qima/services/switchable_cloud_kv_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The cached price of one instrument never arrives: the cloud-change
/// handler that needs it is stuck for good.
class _StuckRepository extends PriceRepository {
  final String stuckID;
  final Completer<void> hit = Completer<void>();

  _StuckRepository(this.stuckID);

  @override
  Future<QuoteSeries> cachedSeries(Instrument instrument) async {
    if (instrument.id == stuckID) {
      if (!hit.isCompleted) hit.complete();
      await Completer<void>().future;
    }
    return super.cachedSeries(instrument);
  }

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
  const methodChannel = MethodChannel('qima/cloud_kv');
  const eventChannel = EventChannel('qima/cloud_kv/changes');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final apple = InstrumentCatalog.instrument('stock.AAPL')!;

  late List<void Function(Map<String, Object?>)> listeners;
  late _StuckRepository repository;

  setUpAll(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
  tearDownAll(() => debugDefaultTargetPlatformOverride = null);

  setUp(() {
    listeners = [];
    repository = _StuckRepository(apple.id);
    messenger.setMockMethodCallHandler(methodChannel, (call) async => switch (call.method) {
          'synchronize' || 'accountStatus' => true,
          _ => null,
        });
    messenger.setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(onListen: (arguments, events) => listeners.add(events.success)),
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methodChannel, null);
    messenger.setMockStreamHandler(eventChannel, null);
  });

  /// A device whose handler for a changed watchlist is stuck.
  Future<AppBlocs> deviceWithStuckHandler() async {
    LocalFileStore.overrideDirectoryForTesting(await Directory.systemTemp.createTemp('qima_cloud_settle'));
    SharedPreferences.setMockInitialValues({'iCloudSyncEnabled': true});
    final blocs = AppBlocs(repository: repository, cloudStore: SwitchableCloudKVStore(), notificationService: _QuietNotifications());
    await blocs.init();
    blocs.sync.settleLimit = const Duration(milliseconds: 200);
    await blocs.watchlist.watchlistStore.upsert(WatchCard(id: 'remote', instrumentID: apple.id, currency: 'USD', unit: PriceUnit.each));
    for (final listener in listeners) {
      listener({'keys': ['watchcards.records'], 'reason': 'serverChange'});
    }
    await repository.hit.future;
    return blocs;
  }

  test('closing the app is not held for ever by a handler that never returns', () async {
    final blocs = await deviceWithStuckHandler();
    await blocs.close().timeout(const Duration(seconds: 5));
  });

  test('turning sync off is not held for ever by a handler that never returns', () async {
    final blocs = await deviceWithStuckHandler();
    await blocs.sync.setICloudSyncEnabled(false).timeout(const Duration(seconds: 5));
    await blocs.close();
  });
}
