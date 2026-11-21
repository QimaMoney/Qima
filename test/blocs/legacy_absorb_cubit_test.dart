import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qima/blocs/app_cubit.dart';
import 'package:qima/models/asset.dart';
import 'package:qima/models/book_entry.dart';
import 'package:qima/models/fx_history.dart';
import 'package:qima/models/holding_cash_id.dart';
import 'package:qima/models/holding_transaction.dart';
import 'package:qima/models/quote.dart';
import 'package:qima/models/syncable.dart';
import 'package:qima/services/book_db/ledger_plan.dart';
import 'package:qima/services/book_store.dart';
import 'package:qima/services/legacy_absorber.dart';
import 'package:qima/services/local_file_store.dart';
import 'package:qima/services/notification_service.dart';
import 'package:qima/services/price_repository.dart';
import 'package:qima/services/switchable_cloud_kv_store.dart';
import 'package:qima/services/synced_store.dart';
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

/// An old device's writes reaching an updated one through the cloud key-value
/// channel, and what the updated device does with them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
  tearDownAll(() => debugDefaultTargetPlatformOverride = null);

  const methodChannel = MethodChannel('qima/cloud_kv');
  const eventChannel = EventChannel('qima/cloud_kv/changes');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Map<String, String> cloudValues;
  late List<void Function(Map<String, Object?>)> listeners;
  late List<String> oldReads;
  late List<String> oldWrites;

  void broadcastChange(String key) {
    for (final listener in listeners) {
      listener({'keys': [key], 'reason': 'serverChange'});
    }
  }

  setUp(() {
    cloudValues = {};
    listeners = [];
    oldReads = [];
    oldWrites = [];
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      switch (call.method) {
        case 'getString':
          final key = (call.arguments as Map)['key'] as String;
          if (LegacyAbsorber.keys.contains(key)) oldReads.add(key);
          return cloudValues[key];
        case 'setString':
          final args = call.arguments as Map;
          final key = args['key'] as String;
          final value = args['value'] as String;
          if (LegacyAbsorber.keys.contains(key)) oldWrites.add(key);
          final changed = cloudValues[key] != value;
          cloudValues[key] = value;
          if (changed) broadcastChange(key);
          return null;
        case 'synchronize':
          return true;
        case 'accountStatus':
          return true;
      }
      return null;
    });
    messenger.setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(onListen: (arguments, events) => listeners.add((payload) => events.success(payload)), onCancel: (arguments) {}),
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methodChannel, null);
    messenger.setMockStreamHandler(eventChannel, null);
  });

  Future<AppCubit> device(Directory dir, {bool sync = true}) async {
    LocalFileStore.overrideDirectoryForTesting(dir);
    SharedPreferences.setMockInitialValues({'iCloudSyncEnabled': sync});
    final cubit = AppCubit(repository: _NoopRepository(), cloudStore: SwitchableCloudKVStore(), notificationService: _FakeNotificationService());
    await cubit.init();
    return cubit;
  }

  Future<void> until(bool Function() ok) async {
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) fail('timed out waiting');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  final stamp = DateTime.utc(2026, 5, 1, 10).toIso8601String();

  String list<T extends Syncable>(Iterable<Record<T>> rs) => jsonEncode([for (final r in rs) r.toJson()]);

  Record<HoldingTransaction> trade(String id, double qty) => Record(
        item: HoldingTransaction(id: id, instrumentID: 'metal.XAU', kind: TransactionKind.buy, quantity: qty, unit: PriceUnit.gram, unitPrice: 50, currency: 'USD', date: DateTime(2026, 3, 12)),
        order: 0,
        updatedAt: DateTime.parse(stamp),
      );

  Record<BookEntry> spend(String id) => Record(
        item: BookEntry(id: id, date: DateTime(2026, 3, 12), template: EntryTemplate.spend, baseCurrency: 'USD', merchant: 'Shop', lines: const [
          EntryLine(accountId: 'acct.wallet', amount: -500, currency: 'USD', baseAmount: -500),
          EntryLine(accountId: 'cat.food', amount: 500, currency: 'USD', baseAmount: 500),
        ]),
        order: 300,
        updatedAt: DateTime.parse(stamp),
      );

  Future<void> cleanUp(AppCubit c, Directory d) async {
    await c.disposeCloudSync();
    await d.delete(recursive: true);
  }

  test('a change of transactions.records reaches the trades and the book', () async {
    final dir = await Directory.systemTemp.createTemp('qima_legacy_a');
    final cubit = await device(dir);
    final reloaded = <String?>[];
    cubit.onBookChanged = (key) async => reloaded.add(key);
    expect(cubit.state.transactions, isEmpty);

    cloudValues[LedgerNames.legacyTransactions] = list([trade('t1', 4)]);
    broadcastChange(LedgerNames.legacyTransactions);
    await until(() => cubit.state.transactions.isNotEmpty);

    expect(cubit.state.transactions.single.id, 't1');
    expect(cubit.state.transactions.single.quantity, 4);
    expect(reloaded, contains(BookStore.entriesKey));
    expect(oldWrites, isEmpty);

    // An edit on the old device arrives the same way.
    cloudValues[LedgerNames.legacyTransactions] = list([trade('t1', 9).copyWith(updatedAt: DateTime.parse(stamp).add(const Duration(minutes: 1)))]);
    broadcastChange(LedgerNames.legacyTransactions);
    await until(() => cubit.state.transactions.isNotEmpty && cubit.state.transactions.single.quantity == 9);
    expect(oldWrites, isEmpty);
    await cleanUp(cubit, dir);
  });

  test('a change of book.entries reaches the money book', () async {
    final dir = await Directory.systemTemp.createTemp('qima_legacy_b');
    final cubit = await device(dir);
    final reloaded = <String?>[];
    cubit.onBookChanged = (key) async => reloaded.add(key);

    cloudValues[LedgerNames.legacyEntries] = list([spend('e1')]);
    broadcastChange(LedgerNames.legacyEntries);
    await until(() => reloaded.contains(BookStore.entriesKey));

    expect((await cubit.bookStore.entries.load()).map((e) => e.id), ['e1']);
    await cleanUp(cubit, dir);
  });

  test('two old keys changed together are absorbed once, with the trade and its cash as one entry', () async {
    final dir = await Directory.systemTemp.createTemp('qima_legacy_c');
    final cubit = await device(dir);
    final reloaded = <String?>[];
    cubit.onBookChanged = (key) async => reloaded.add(key);

    final cash = Record<BookEntry>(
      item: BookEntry(id: holdingCashId('t1'), date: DateTime(2026, 3, 12), template: EntryTemplate.holdingTrade, baseCurrency: 'USD', merchant: 'Gold', lines: const [
        EntryLine(accountId: 'acct.bank', amount: -20000, currency: 'USD', baseAmount: -20000),
        EntryLine(accountId: 'system.holdings', amount: 20000, currency: 'USD', baseAmount: 20000),
      ]),
      order: 100,
      updatedAt: DateTime.parse(stamp),
    );
    cloudValues[LedgerNames.legacyEntries] = list([cash]);
    cloudValues[LedgerNames.legacyTransactions] = list([trade('t1', 4)]);
    broadcastChange(LedgerNames.legacyEntries);
    broadcastChange(LedgerNames.legacyTransactions);
    await until(() => cubit.state.transactions.isNotEmpty);
    await cubit.bookStore.entries.load();

    final live = (await cubit.bookStore.entries.load());
    expect(live.map((e) => e.id), ['t1']);
    expect(reloaded.where((k) => k == BookStore.entriesKey), isNotEmpty);
    await cleanUp(cubit, dir);
  });

  test('what an old device wrote before this one started is in the first load', () async {
    cloudValues[LedgerNames.legacyTransactions] = list([trade('t1', 4)]);
    final dir = await Directory.systemTemp.createTemp('qima_legacy_d');
    final cubit = await device(dir);
    expect(cubit.state.transactions.map((t) => t.id), ['t1']);
    expect(cubit.legacyAbsorbProblem, isNull);
    await cleanUp(cubit, dir);
  });

  test('turning the cloud on mid-session takes what the old keys hold', () async {
    cloudValues[LedgerNames.legacyTransactions] = list([trade('t1', 4)]);
    final dir = await Directory.systemTemp.createTemp('qima_legacy_e');
    final cubit = await device(dir, sync: false);
    expect(cubit.state.transactions, isEmpty);
    expect(oldReads, isEmpty);

    await cubit.setICloudSyncEnabled(true);
    expect(cubit.state.transactions.map((t) => t.id), ['t1']);
    expect(oldWrites, isEmpty);
    await cleanUp(cubit, dir);
  });

  test('with the cloud off the old keys are neither read nor taken', () async {
    cloudValues[LedgerNames.legacyTransactions] = list([trade('t1', 4)]);
    cloudValues[LedgerNames.legacyEntries] = list([spend('e1')]);
    final dir = await Directory.systemTemp.createTemp('qima_legacy_f');
    final cubit = await device(dir, sync: false);
    broadcastChange(LedgerNames.legacyTransactions);
    await cubit.adoptCloudChanges();
    await cubit.holdings.load();

    expect(cubit.state.transactions, isEmpty);
    expect(await cubit.bookStore.entries.load(), isEmpty);
    expect(oldReads, isEmpty);

    // Switching it off again stops it too.
    await cubit.setICloudSyncEnabled(true);
    expect(cubit.state.transactions, isNotEmpty);
    await cubit.setICloudSyncEnabled(false);
    oldReads.clear();
    cloudValues[LedgerNames.legacyTransactions] = list([trade('t1', 4), trade('t2', 1)]);
    await cubit.adoptCloudChanges();
    expect(oldReads, isEmpty);
    expect(cubit.state.transactions.map((t) => t.id), ['t1']);
    await cleanUp(cubit, dir);
  });
}
