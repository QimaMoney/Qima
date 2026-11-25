import 'dart:io';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qima/blocs/app_blocs.dart';
import 'package:qima/blocs/guarded_emit.dart';
import 'package:qima/models/asset.dart';
import 'package:qima/models/fx_history.dart';
import 'package:qima/models/instrument_catalog.dart';
import 'package:qima/models/quote.dart';
import 'package:qima/models/watch_card.dart';
import 'package:qima/services/local_file_store.dart';
import 'package:qima/services/notification_service.dart';
import 'package:qima/services/price_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _OfflineRepository extends PriceRepository {
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

/// The app closes its cubits when it is disposed while work started without
/// waiting for it (a price fetch after a trade is saved, the backup reminder
/// after any change) can still be running; what it finishes with must not
/// throw.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final gold = InstrumentCatalog.instrument('metal.XAU')!;

  Future<AppBlocs> started() async {
    SharedPreferences.setMockInitialValues({});
    LocalFileStore.overrideDirectoryForTesting(await Directory.systemTemp.createTemp('qima_closed_cubits'));
    final blocs = AppBlocs(repository: _OfflineRepository(), notificationService: _QuietNotifications());
    await blocs.init();
    return blocs;
  }

  test('every cubit drops a late emit instead of throwing', () async {
    final blocs = await started();
    await blocs.close();

    final cubits = <Cubit<Object?>>[blocs.app, blocs.settings, blocs.market, blocs.watchlist, blocs.holdings, blocs.alerts, blocs.zakat, blocs.sync];
    for (final cubit in cubits) {
      expect(cubit.isClosed, isTrue);
      expect(() => cubit.emit(cubit.state), returnsNormally, reason: '${cubit.runtimeType}');
    }
  });

  test('work left running when the cubits close finishes quietly', () async {
    final blocs = await started();
    final backup = blocs.sync.backupService;
    await backup.setReminderEnabled(true);
    await backup.setDataChangedSinceLastBackup(true);
    await backup.setLastBackupAt(DateTime.now().subtract(const Duration(days: 60)));
    expect(backup.isReminderDue(), isTrue);
    expect(blocs.sync.state.backupReminderDue, isFalse);

    await blocs.close();

    // Each of these emits as it starts or as it ends.
    await blocs.sync.refreshBackupReminder();
    await blocs.market.refresh(gold);
    await blocs.market.refreshAll();
    await blocs.market.backfillHistoryIfNeeded();
    await blocs.market.loadHistory(gold, 'USD');
    await blocs.watchlist.addCard(WatchCard(id: 'c1', instrumentID: gold.id, currency: 'EGP', unit: PriceUnit.troyOunce));
    await blocs.settings.setBaseCurrency('EGP');
    await blocs.alerts.refreshNotificationStatus();
  });

  group('GuardedEmit', () {
    test('emits while open, drops the emit after close, and still lets an error through', () async {
      final counter = _Counter();
      await counter.bump();
      expect(counter.state, 1);

      await counter.close();
      await counter.bump();
      expect(counter.state, 1);

      await expectLater(counter.bump(fail: true), throwsA(isA<StateError>()));
    });
  });
}

class _Counter extends Cubit<int> with GuardedEmit<int> {
  _Counter() : super(0);

  Future<void> bump({bool fail = false}) async {
    await Future<void>.value();
    if (fail) throw StateError('failed');
    emit(state + 1);
  }
}
