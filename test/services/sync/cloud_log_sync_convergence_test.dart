import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qima/blocs/cloud_log_sync.dart';
import 'package:qima/blocs/cloud_log_sync_state.dart';
import 'package:qima/models/money_settings.dart';
import 'package:qima/services/book_db/book_database.dart';
import 'package:qima/services/book_store.dart';
import 'package:qima/services/cloud_kv_store.dart';
import 'package:qima/services/local_file_store.dart';
import 'package:qima/services/preferences.dart';
import 'package:qima/services/sync/book_sync.dart';
import 'package:qima/services/synced_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_clock.dart';
import 'memory_sync_transport.dart';
import 'sync_support.dart';

class _Cloud implements CloudKVStore {
  final Map<String, String> values = {};

  @override
  Future<String?> getString(String key) async => values[key];

  @override
  Future<void> setString(String key, String value) async => values[key] = value;

  @override
  Future<void> synchronize() async {}

  @override
  Future<bool> accountStatus() async => true;

  @override
  Stream<CloudKVChangeEvent> get didChangeExternally => const Stream.empty();
}

/// One device: its own book directory and database, its own clock, and a
/// [CloudLogSync] over the shared transport.
class _Phone {
  final String name;
  final Directory root;
  final BookStore store;
  final FakeClock clock = FakeClock();
  int reloads = 0;
  late final CloudLogSync sync;

  _Phone(this.name, this.root, this.store);

  /// Points the app's storage at this device, as its process has it.
  void on() => LocalFileStore.overrideDirectoryForTesting(Directory('${root.path}/$name')..createSync(recursive: true));

  Future<void> start(Preferences preferences, MemorySyncTransport transport, {String Function()? account}) async {
    on();
    sync = CloudLogSync(
      store: store,
      transport: transport,
      available: () async => true,
      account: () async => account?.call() ?? 'account-one',
      reload: () async => reloads++,
      now: () => clock.now,
      timer: clock.timer,
    );
    await sync.start(preferences);
    sync.bookLoaded();
    await sync.idle;
  }

  /// What a person does and the app then sends: a change, and the debounce.
  Future<void> edit(Future<void> Function() change) async {
    on();
    await change();
    await clock.advance(const Duration(seconds: 6));
    await sync.idle;
  }

  /// The app coming back to the foreground.
  Future<void> foreground() async {
    on();
    await sync.resumed();
    await sync.idle;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Preferences preferences;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('qima_cloud_log_sync');
    SharedPreferences.setMockInitialValues({});
    preferences = await Preferences.create();
    await preferences.setCloudLogSyncEnabled(true);
  });

  tearDown(() async {
    await BookDatabase.closeAll();
    await root.delete(recursive: true);
  });

  Future<List<String>> held(BookStore store) async =>
      [show(await store.accounts.exportRecords()), show(await store.entries.exportRecords()), show(await store.recurring.exportRecords()), show(await store.settings.exportRecords())];

  for (final withKeyValue in [false, true]) {
    group(withKeyValue ? 'with key-value sync on beside it' : 'with key-value sync off', () {
      test('two devices that edit on both sides end with one book, and the rounds come to rest', () async {
        final log = MemorySyncTransport();
        final cloud = withKeyValue ? _Cloud() : null;
        final a = _Phone('a', root, BookStore(cloud: cloud));
        final b = _Phone('b', root, BookStore(cloud: cloud));
        addTearDown(() async {
          await a.sync.close();
          await b.sync.close();
        });
        await a.start(preferences, log);
        await b.start(preferences, log);

        await a.edit(() async {
          await a.store.accounts.upsert(account('acct.bank', 'Bank'));
          await a.store.entries.upsert(spend('coffee', 450));
          await a.store.entries.upsert(spend('lunch', 1200));
        });
        expect(log.batches, isNotEmpty, reason: 'it went through the change log');

        await b.foreground();
        b.on();
        expect((await b.store.entries.load()).map((e) => e.id).toSet(), {'coffee', 'lunch'});
        expect(b.reloads, greaterThan(0), reason: 'what it took in was shown');

        await b.edit(() async {
          await b.store.entries.delete('coffee');
          await b.store.entries.upsert(spend('lunch', 1350));
          await b.store.recurring.upsert(RecurringPayment(id: 'rent', name: 'Rent', amount: 100000, fromAccountId: 'acct.bank', categoryId: 'category.rent', repeat: PlanRepeat.monthly, start: DateTime(2026, 1, 1)));
          await b.store.settings.upsert(const MoneySettings(valueReviewMonths: 9));
        });

        // Meanwhile a makes another change of its own.
        await a.edit(() async => a.store.entries.upsert(spend('dinner', 800)));
        await b.foreground();
        await a.foreground();
        await b.foreground();

        for (final phone in [a, b]) {
          phone.on();
          for (final store in [phone.store.accounts, phone.store.entries, phone.store.recurring, phone.store.settings]) {
            await (store as SyncedStore).load();
          }
        }
        a.on();
        final onA = await held(a.store);
        b.on();
        expect(await held(b.store), onA);
        a.on();
        final entries = await a.store.entries.load();
        expect(entries.map((e) => e.id).toSet(), {'lunch', 'dinner'});
        expect(entries.firstWhere((e) => e.id == 'lunch').lines.first.amount, -1350);
        expect((await a.store.settings.load()).single.valueReviewMonths, 9);

        // At rest: another round of each moves nothing.
        final batches = log.batches.length;
        for (final phone in [a, b]) {
          await phone.foreground();
        }
        expect(log.batches, hasLength(batches));
        expect(a.sync.state.phase, CloudLogPhase.upToDate);
        expect(b.sync.state.phase, CloudLogPhase.upToDate);
      });
    });
  }

  test('what the engine remembers is kept per account: another account starts as a new remote and the first one keeps its cursors', () async {
    final log = MemorySyncTransport();
    var who = 'account-one';
    final a = _Phone('a', root, BookStore());
    addTearDown(() => a.sync.close());
    await a.start(preferences, log, account: () => who);
    await a.edit(() async => a.store.entries.upsert(spend('coffee', 450)));

    final one = CloudLogSync.remoteFor('account-one');
    final two = CloudLogSync.remoteFor('account-two');
    final db = await BookDatabase.open();
    Future<String?> meta(String key) async {
      final rows = await db.customSelect("SELECT value FROM meta WHERE key = '$key'").get();
      return rows.isEmpty ? null : rows.single.data['value'] as String;
    }

    final cursorOne = await meta('sync.out.$one');
    expect(cursorOne, isNotNull);
    expect(await meta('sync.out.$two'), isNull);

    final before = log.batches.length;
    who = 'account-two';
    await a.foreground();
    expect(await meta('sync.out.$two'), isNotNull, reason: 'a remote of its own');
    expect(await meta('sync.out.$one'), cursorOne, reason: 'the first account\'s cursors are left as they were');
    expect(log.batches.length, greaterThan(before), reason: 'what the book holds goes to the new remote from the start');
  });

  test('switching off and on again over a real book continues without sending the book again', () async {
    final log = MemorySyncTransport();
    final a = _Phone('a', root, BookStore());
    addTearDown(() => a.sync.close());
    await a.start(preferences, log);
    await a.edit(() async => a.store.entries.upsert(spend('coffee', 450)));
    final sent = log.batches.length;
    await a.sync.setEnabled(false);
    await a.sync.setEnabled(true);
    await a.sync.idle;
    expect(log.batches, hasLength(sent));
    expect(a.sync.state.phase, CloudLogPhase.upToDate);
  });

  test('a book store built for key-value sync only, as the app builds it, is not touched when the switch is off', () async {
    final log = MemorySyncTransport();
    await preferences.setCloudLogSyncEnabled(false);
    final a = _Phone('a', root, BookStore());
    addTearDown(() => a.sync.close());
    await a.start(preferences, log);
    await a.edit(() async => a.store.entries.upsert(spend('coffee', 450)));
    expect(log.batches, isEmpty);
    expect(log.snapshots, isEmpty);
    expect(a.store.sync, same(BookSync.keyValue));
    final db = await BookDatabase.open();
    expect(await db.customSelect("SELECT 1 FROM meta WHERE key LIKE 'sync.%'").get(), isEmpty);
  });
}
