import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qima/blocs/app_blocs.dart';
import 'package:qima/blocs/sync_state.dart';
import 'package:qima/models/fx_history.dart';
import 'package:qima/models/holding_transaction.dart';
import 'package:qima/models/quote.dart';
import 'package:qima/models/asset.dart';
import 'package:qima/services/backup/backup_service.dart';
import 'package:qima/services/book_db/ledger_plan.dart';
import 'package:qima/services/book_store.dart';
import 'package:qima/services/holdings_ledger.dart';
import 'package:qima/services/local_file_store.dart';
import 'package:qima/services/notification_service.dart';
import 'package:qima/services/price_repository.dart';
import 'package:qima/services/switchable_cloud_kv_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoopRepository extends PriceRepository {
  @override
  Future<QuoteSeries> refresh(Instrument instrument, {DateTime? now}) async => QuoteSeries.empty(instrument.id);

  @override
  Future<Map<String, QuoteSeries>> refreshAll(List<Instrument> instruments, {DateTime? now}) async => {};

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

/// A book whose on-device migration reports [problems].
class _MigrationBook extends BookStore {
  Map<String, Object> problems;

  _MigrationBook(this.problems);

  @override
  Future<Map<String, Object>> ledgerProblems() async => problems;
}

/// A holdings ledger that cannot read the book while [broken].
class _Holdings extends HoldingsLedger {
  bool broken = true;

  _Holdings(super.book);

  @override
  Future<List<HoldingTransaction>> load() async {
    if (broken) throw StateError('the holdings file cannot be read');
    return super.load();
  }
}

/// Start-up that never stops on a bad book, and the "book health" Settings
/// reports: what is wrong, and the sync status that must not say up to date
/// meanwhile.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
  tearDownAll(() => debugDefaultTargetPlatformOverride = null);

  const methodChannel = MethodChannel('qima/cloud_kv');
  const eventChannel = EventChannel('qima/cloud_kv/changes');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Map<String, String> cloudValues;
  late Directory dir;

  setUp(() async {
    cloudValues = {};
    dir = await Directory.systemTemp.createTemp('qima_book_health');
    LocalFileStore.overrideDirectoryForTesting(dir);
    SharedPreferences.setMockInitialValues({'iCloudSyncEnabled': true});
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      switch (call.method) {
        case 'getString':
          return cloudValues[(call.arguments as Map)['key'] as String];
        case 'setString':
          final args = call.arguments as Map;
          cloudValues[args['key'] as String] = args['value'] as String;
          return null;
        case 'synchronize':
        case 'accountStatus':
          return true;
      }
      return null;
    });
    messenger.setMockStreamHandler(eventChannel, MockStreamHandler.inline(onListen: (arguments, events) {}, onCancel: (arguments) {}));
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(methodChannel, null);
    messenger.setMockStreamHandler(eventChannel, null);
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<AppBlocs> start({BookStore? book, HoldingsLedger Function(BookStore)? holdings}) async {
    final cloud = SwitchableCloudKVStore();
    final store = book ?? BookStore(cloud: cloud);
    final cubit = AppBlocs(
      repository: _NoopRepository(),
      cloudStore: cloud,
      bookStore: store,
      holdings: holdings?.call(store),
      notificationService: _FakeNotificationService(),
    );
    addTearDown(cubit.sync.disposeCloudSync);
    await cubit.init();
    return cubit;
  }

  test('a book that is fine says nothing, and sync is up to date', () async {
    final cubit = await start();
    expect(cubit.sync.state.bookHealth, BookHealth.fine);
    expect(cubit.sync.state.bookHealth.hasProblem, isFalse);
    expect(cubit.sync.state.cloudSyncStatus, CloudSyncStatus.upToDate);
  });

  test('start-up completes when the trades cannot be read, with what there is, and records the problem', () async {
    late _Holdings broken;
    final cubit = await start(holdings: (book) => broken = _Holdings(book));
    expect(cubit.app.state.initialized, isTrue);
    expect(cubit.holdings.state.transactions, isEmpty);
    expect(cubit.sync.state.bookHealth.loadFailed, isTrue);
    expect(cubit.sync.state.cloudSyncStatus, CloudSyncStatus.needsAttention);

    // The next sync reads them, and the problem goes.
    broken.broken = false;
    await cubit.sync.adoptCloudChanges();
    expect(cubit.sync.state.bookHealth, BookHealth.fine);
    expect(cubit.sync.state.cloudSyncStatus, CloudSyncStatus.upToDate);
  });

  test('a migration step that did not finish is reported, and clears once it has', () async {
    final book = _MigrationBook({LedgerNames.flagHoldings: StateError('the holdings could not be folded in')});
    final cubit = await start(book: book);
    expect(cubit.app.state.initialized, isTrue);
    expect(cubit.sync.state.bookHealth.migrationFailed, isTrue);
    expect(cubit.sync.state.bookHealth.loadFailed, isFalse);
    expect(cubit.sync.state.cloudSyncStatus, CloudSyncStatus.needsAttention);

    book.problems = {};
    await cubit.sync.adoptCloudChanges();
    expect(cubit.sync.state.bookHealth.migrationFailed, isFalse);
    expect(cubit.sync.state.cloudSyncStatus, CloudSyncStatus.upToDate);
  });

  test('a collection written by a newer build is reported, and sync is not up to date', () async {
    cloudValues[BookStore.entriesKey] = jsonEncode({'v': 2, 'blob': 'x'});
    final cubit = await start();
    expect(cubit.sync.state.bookHealth.newerVersion, isTrue);
    expect(cubit.sync.state.cloudSyncStatus, CloudSyncStatus.needsAttention);

    // Updating is what clears it: the value is readable again.
    cloudValues.remove(BookStore.entriesKey);
    await cubit.sync.adoptCloudChanges();
    expect(cubit.sync.state.bookHealth.newerVersion, isFalse);
    expect(cubit.sync.state.cloudSyncStatus, CloudSyncStatus.upToDate);
  });

  test('an old cloud value that cannot be read is reported, and tried again by the next sync', () async {
    cloudValues[LedgerNames.legacyTransactions] = 'not json at all';
    final cubit = await start();
    expect(cubit.sync.legacyAbsorbProblem, isNotNull);
    expect(cubit.sync.state.bookHealth.legacyUnreadable, isTrue);
    expect(cubit.sync.state.cloudSyncStatus, CloudSyncStatus.needsAttention);

    cloudValues.remove(LedgerNames.legacyTransactions);
    await cubit.sync.adoptCloudChanges();
    expect(cubit.sync.legacyAbsorbProblem, isNull);
    expect(cubit.sync.state.bookHealth, BookHealth.fine);
  });

  test('a failed load made outside the cubit is recorded too', () async {
    final cubit = await start();
    await cubit.sync.noteLoadFailed();
    expect(cubit.sync.state.bookHealth.loadFailed, isTrue);
    expect(cubit.sync.state.cloudSyncStatus, CloudSyncStatus.needsAttention);
  });

  test('a restore reads the health again', () async {
    final book = _MigrationBook({LedgerNames.flagHoldings: StateError('x')});
    final cubit = await start(book: book);
    expect(cubit.sync.state.bookHealth.migrationFailed, isTrue);
    book.problems = {};
    await cubit.sync.restoreFromBackup(await cubit.sync.backupService.buildPayload(), mode: BackupImportMode.merge);
    expect(cubit.sync.state.bookHealth.migrationFailed, isFalse);
  });
}
