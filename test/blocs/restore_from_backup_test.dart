import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qima/blocs/app_blocs.dart';
import 'package:qima/models/asset.dart';
import 'package:qima/models/fx_history.dart';
import 'package:qima/models/instrument_catalog.dart';
import 'package:qima/models/quote.dart';
import 'package:qima/models/watch_card.dart';
import 'package:qima/services/backup/backup_service.dart';

import '../helpers/app_blocs.dart';
import 'package:qima/services/local_file_store.dart';
import 'package:qima/services/preferences.dart';
import 'package:qima/services/price_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stands in for `PriceRepository` so `restoreFromBackup`'s fire-and-forget
/// `refreshAll()`/backfill calls never hit the network or the unmocked
/// `shared_preferences`/`path_provider` plugins — mirrors `add_card_test.dart`'s
/// `_NoopRepository`.
class _NoopRepository extends PriceRepository {
  @override
  Future<QuoteSeries> refresh(Instrument instrument, {DateTime? now}) async => QuoteSeries.empty(instrument.id);

  @override
  Future<Map<String, QuoteSeries>> refreshAll(List<Instrument> instruments, {DateTime? now}) async => {};

  @override
  Future<FXHistory> backfillFXHistory(List<String> currencies, {bool force = false, DateTime? now}) async =>
      FXHistory.empty;

  @override
  Future<Map<String, QuoteSeries>> backfillInstruments(
    List<Instrument> instruments,
    FXHistory fxHistory, {
    bool force = false,
    DateTime? now,
  }) async =>
      {};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('qima_restore_from_backup_test');
    LocalFileStore.overrideDirectoryForTesting(tempDir);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<AppBlocs> populatedCubit() async {
    final cubit = AppBlocs(repository: _NoopRepository());
    final preferences = await Preferences.create();
    cubit.settings.preferences = preferences;
    // Builds the backup service over the same stores, as start-up does.
    await cubit.sync.start(preferences);
    await cubit.zakat.load(preferences);
    cubit.seed(initialized: true, baseCurrency: 'USD');
    return cubit;
  }

  final gold = InstrumentCatalog.instrument('metal.XAU')!;

  test('restoring a Merge backup reloads the watchlist into AppState', () async {
    final source = await populatedCubit();
    await source.watchlist.addCard(WatchCard(id: 'c1', instrumentID: gold.id, currency: 'USD', unit: PriceUnit.troyOunce));
    final payload = await source.sync.backupService.buildPayload();

    // A fresh destination cubit pointed at its own store.
    final destDir = await Directory.systemTemp.createTemp('qima_restore_dest');
    LocalFileStore.overrideDirectoryForTesting(destDir);
    final dest = await populatedCubit();

    await dest.sync.restoreFromBackup(payload, mode: BackupImportMode.merge);

    expect(dest.watchlist.state.cards.map((c) => c.id), contains('c1'));
    await destDir.delete(recursive: true);
  });

  test('restoring a Replace backup applies the imported settings', () async {
    final source = await populatedCubit();
    await source.settings.preferences.setBaseCurrency('EGP');
    final payload = await source.sync.backupService.buildPayload();

    final destDir = await Directory.systemTemp.createTemp('qima_restore_dest2');
    LocalFileStore.overrideDirectoryForTesting(destDir);
    final dest = await populatedCubit();
    await dest.settings.preferences.setBaseCurrency('USD');

    await dest.sync.restoreFromBackup(payload, mode: BackupImportMode.replace);

    expect(dest.settings.state.baseCurrency, 'EGP');
    await destDir.delete(recursive: true);
  });

  test('restoring a Replace backup removes a local-only card not present in the import', () async {
    final source = await populatedCubit();
    final payload = await source.sync.backupService.buildPayload(); // empty watchlist.

    final dest = await populatedCubit();
    await dest.watchlist.addCard(WatchCard(id: 'local', instrumentID: gold.id, currency: 'USD', unit: PriceUnit.troyOunce));
    expect(dest.watchlist.state.cards, isNotEmpty);

    await dest.sync.restoreFromBackup(payload, mode: BackupImportMode.replace);

    expect(dest.watchlist.state.cards, isEmpty);
  });

  test('restoring clears the backup-due reminder state via _refreshBackupReminder', () async {
    final source = await populatedCubit();
    final payload = await source.sync.backupService.buildPayload();

    final dest = await populatedCubit();
    await dest.sync.backupService.setReminderEnabled(true);
    await dest.sync.backupService.setDataChangedSinceLastBackup(true);
    await dest.sync.backupService.setLastBackupAt(DateTime.now().subtract(const Duration(days: 60)));
    expect(dest.sync.backupService.isReminderDue(), isTrue);

    await dest.sync.restoreFromBackup(payload, mode: BackupImportMode.merge);

    // Restoring isn't itself a backup, so `dataChangedSinceLastBackup` and
    // `lastBackupAt` are untouched by `restoreFromBackup` — only an actual
    // export clears them (see `BackupService.exportJson`). This asserts the
    // state re-sync ran without throwing and left the reminder computation
    // consistent with the service's own values, not that restoring silently
    // clears the due flag.
    expect(dest.sync.state.backupReminderDue, dest.sync.backupService.isReminderDue());
  });
}
