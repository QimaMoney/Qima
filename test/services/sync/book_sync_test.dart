import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/book_account.dart';
import 'package:qima/models/book_entry.dart';
import 'package:qima/models/default_categories.dart';
import 'package:qima/models/money_settings.dart';
import 'package:qima/models/syncable.dart';
import 'package:qima/services/alerts_store.dart';
import 'package:qima/services/backup/backup_codec.dart';
import 'package:qima/services/backup/backup_service.dart';
import 'package:qima/services/book_db/book_database.dart';
import 'package:qima/services/book_store.dart';
import 'package:qima/services/cloud_kv_store.dart';
import 'package:qima/services/custom_instrument_store.dart';
import 'package:qima/services/local_file_store.dart';
import 'package:qima/services/preferences.dart';
import 'package:qima/services/sync/book_sync.dart';
import 'package:qima/services/sync/directory_sync_transport.dart';
import 'package:qima/services/sync/sync_engine.dart';
import 'package:qima/services/synced_store.dart';
import 'package:qima/services/watchlist_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'memory_sync_transport.dart';
import 'sync_support.dart';

class _Cloud implements CloudKVStore {
  final Map<String, String> values = {};
  int writes = 0;

  @override
  Future<String?> getString(String key) async => values[key];

  @override
  Future<void> setString(String key, String value) async {
    writes++;
    values[key] = value;
  }

  @override
  Future<void> synchronize() async {}

  @override
  Future<bool> accountStatus() async => true;

  @override
  Stream<CloudKVChangeEvent> get didChangeExternally => const Stream.empty();
}

RecurringPayment _rent(String name) => RecurringPayment(id: 'rent', name: name, amount: 100000, fromAccountId: 'acct.bank', categoryId: 'category.rent', repeat: PlanRepeat.monthly, start: DateTime(2026, 1, 1));

void main() {
  late Directory root;

  /// Points the app's storage at the directory of one device, as that
  /// device's process has it for its whole life.
  void on(String device) => LocalFileStore.overrideDirectoryForTesting(Directory('${root.path}/$device')..createSync());

  Future<List<String>> held(BookStore store) async =>
      [show(await store.accounts.exportRecords()), show(await store.entries.exportRecords()), show(await store.recurring.exportRecords()), show(await store.settings.exportRecords())];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('qima_book_sync');
  });

  tearDown(() async {
    await BookDatabase.closeAll();
    await root.delete(recursive: true);
  });

  test('a book store built as the app builds it syncs through the key-value store and has no change log engine', () async {
    on('phone');
    final cloud = _Cloud();
    final store = BookStore(cloud: cloud);
    expect(store.sync, same(BookSync.keyValue));
    expect(store.changeLog, isNull);
    expect(BookStore().sync, same(BookSync.keyValue));

    await store.entries.upsert(spend('s1', 100));
    expect(cloud.values.keys, [BookStore.entriesKey]);
    expect((jsonDecode(cloud.values[BookStore.entriesKey]!) as Map<String, dynamic>)['z'], 'gzip');
    final db = await BookDatabase.open();
    expect(await db.customSelect("SELECT 1 FROM meta WHERE key LIKE 'sync.%'").get(), isEmpty);
    expect(await db.customSelect("SELECT 1 FROM changes WHERE op IN ('sync', 'attach', 'snapshot', 'again')").get(), isEmpty);
  });

  test('with the change log chosen, three devices keep one book through a folder, with no key-value store at all', () async {
    final folder = DirectorySyncTransport(Directory('${root.path}/shared'));
    BookStore store() => BookStore(sync: BookSync.changeLog(folder));

    // The phone has a book from an earlier build: an account in the old file.
    on('phone');
    File('${root.path}/phone/book.accounts.json').writeAsStringSync(jsonEncode({
      'records': [rec(account('acct.bank', 'Bank'), 1).toJson()],
    }));
    final phone = store();
    await phone.loadAccounts();
    await phone.entries.upsert(spend('coffee', 450));
    await phone.entries.upsert(spend('lunch', 1200));
    await phone.recurring.upsert(_rent('Rent'));
    await phone.changeLog!.sync();

    on('laptop');
    final laptop = store();
    await laptop.loadAccounts();
    await laptop.changeLog!.sync();
    expect((await laptop.entries.load()).map((e) => e.id).toSet(), {'coffee', 'lunch'});
    final accounts = await laptop.accounts.load();
    expect(accounts.singleWhere((a) => a.id == 'acct.bank').name, 'Bank', reason: 'what the phone imported from its old file is sent too');
    expect(accounts.length, DefaultCategories.all.length + 1);

    await laptop.entries.delete('coffee');
    await laptop.entries.upsert(spend('lunch', 1350));
    await laptop.recurring.upsert(_rent('Rent, flat'));
    await laptop.settings.upsert((await laptop.loadSettings()).copyWith(valueReviewMonths: 9));
    await laptop.changeLog!.sync();

    on('phone');
    await phone.changeLog!.sync();
    final entries = await phone.entries.load();
    expect(entries.single.id, 'lunch');
    expect(entries.single.lines.first.amount, -1350);
    expect((await phone.recurring.load()).single.name, 'Rent, flat');
    expect((await phone.loadSettings()).valueReviewMonths, 9);
    final compaction = await phone.changeLog!.compact();
    expect(compaction.refused, isFalse);
    final onPhone = await held(phone);

    on('tablet');
    final tablet = store();
    await tablet.changeLog!.sync();
    expect(await held(tablet), onPhone);
    expect((await tablet.entries.exportRecords()).singleWhere((r) => r.item.id == 'coffee').deleted, isTrue);

    on('laptop');
    await laptop.changeLog!.sync();
    expect(await held(laptop), onPhone);
  });

  test('a correction made on a device whose clock is behind is kept, by that device and by all', () async {
    final log = MemorySyncTransport();
    BookStore store() => BookStore(sync: BookSync.changeLog(log));
    on('a');
    final a = store();
    await a.changeLog!.sync();

    // b's clock runs a minute fast: its save carries a stamp a minute ahead.
    on('b');
    final b = store();
    await b.entries.importRecords([Record<BookEntry>(item: spend('x', 100), order: 0, updatedAt: DateTime.now().add(const Duration(minutes: 1)))], replace: false);
    await b.changeLog!.sync();

    on('a');
    await a.changeLog!.sync();
    expect((await a.entries.load()).single.lines.first.amount, -100);
    await a.entries.upsert(spend('x', 555));
    expect((await a.entries.load()).single.lines.first.amount, -555, reason: 'the person sees what they saved');
    await a.changeLog!.sync();
    await a.entries.upsert(spend('y', 1));
    await a.changeLog!.sync();

    on('c');
    final c = store();
    await c.changeLog!.sync();
    await c.changeLog!.compact();

    for (var i = 0; i < 3; i++) {
      for (final (name, device) in [('b', b), ('a', a), ('c', c)]) {
        on(name);
        await device.changeLog!.sync();
      }
    }
    for (final (name, device) in [('a', a), ('b', b), ('c', c)]) {
      on(name);
      expect((await device.entries.load()).singleWhere((e) => e.id == 'x').lines.first.amount, -555, reason: name);
    }
  });

  group('key-value sync and the change log together, while devices move over', () {
    test('a record of every collection made on either side reaches the other', () async {
      final cloud = _Cloud();
      final log = MemorySyncTransport();
      on('old');
      final old = BookStore(cloud: cloud);
      await old.entries.upsert(spend('fromOld', 100));
      await old.accounts.upsert(account('acct.old', 'Old'));
      await old.recurring.upsert(_rent('Rent'));

      on('both');
      final both = BookStore(cloud: cloud, sync: BookSync.changeLog(log));
      expect((await both.entries.load()).single.id, 'fromOld');
      await both.accounts.load();
      await both.recurring.load();
      await both.settings.load();
      await both.changeLog!.sync();

      on('new');
      final logOnly = BookStore(sync: BookSync.changeLog(log));
      await logOnly.changeLog!.sync();
      expect((await logOnly.entries.load()).single.id, 'fromOld');
      expect((await logOnly.accounts.load()).single.name, 'Old');
      expect((await logOnly.recurring.load()).single.name, 'Rent');
      await logOnly.entries.upsert(spend('fromNew', 200));
      await logOnly.accounts.upsert(account('acct.new', 'New'));
      await logOnly.recurring.upsert(_rent('Rent, raised'));
      await logOnly.settings.upsert(const MoneySettings(valueReviewMonths: 3));
      await logOnly.changeLog!.sync();
      final wanted = await held(logOnly);

      on('both');
      await both.changeLog!.sync();
      for (final store in [both.accounts, both.entries, both.recurring, both.settings]) {
        await (store as SyncedStore<Syncable>).load();
      }
      expect(await held(both), wanted);

      on('old');
      for (final store in [old.accounts, old.entries, old.recurring, old.settings]) {
        await (store as SyncedStore<Syncable>).load();
      }
      expect(await held(old), wanted);
    });

    test('two versions of a record with one stamp settle on one, in every collection, and the rounds come to rest', () async {
      final cloud = _Cloud();
      final log = MemorySyncTransport();
      final stamp = DateTime.utc(2000);
      Record<T> at<T extends Syncable>(T item) => Record<T>(item: item, order: 0, updatedAt: stamp);

      // A device on key-value sync only holds one version of each record.
      on('old');
      final old = BookStore(cloud: cloud);
      await old.accounts.insertMissing([at(account('acct.x', 'Aaa'))]);
      await old.recurring.insertMissing([at(_rent('Aaa'))]);
      await old.settings.insertMissing([at(const MoneySettings(valueReviewMonths: 3))]);

      // A device on the change log only holds another, with the same stamp.
      on('new');
      final logOnly = BookStore(sync: BookSync.changeLog(log));
      await logOnly.accounts.insertMissing([at(account('acct.x', 'Zzz'))]);
      await logOnly.recurring.insertMissing([at(_rent('Zzz'))]);
      await logOnly.settings.insertMissing([at(const MoneySettings(valueReviewMonths: 9))]);
      await logOnly.changeLog!.sync();

      // A device that runs both.
      on('both');
      final both = BookStore(cloud: cloud, sync: BookSync.changeLog(log));
      final seen = <String>{};
      var moving = 0;
      for (var i = 0; i < 8; i++) {
        on('both');
        // What a cloud change notification or a start does.
        await both.accounts.load();
        await both.recurring.load();
        await both.settings.load();
        seen.add((await held(both)).join());
        final here = await both.changeLog!.sync();
        seen.add((await held(both)).join());
        on('new');
        final there = await logOnly.changeLog!.sync();
        if (!here.quiet || !there.quiet) moving = i + 1;
      }
      expect(moving, lessThan(3), reason: 'the rounds stop moving anything');
      final writes = cloud.writes;
      on('both');
      await both.accounts.load();
      await both.recurring.load();
      await both.settings.load();
      expect(cloud.writes, writes, reason: 'and the cloud keys are not written again');
      expect(seen.length, lessThanOrEqualTo(2), reason: 'the device that runs both changes its mind at most once');

      final wanted = await held(both);
      on('new');
      expect(await held(logOnly), wanted);
      on('old');
      await old.accounts.load();
      await old.recurring.load();
      await old.settings.load();
      expect(await held(old), wanted);
      expect(show(await old.accounts.exportRecords()), show(old.accounts.merge([at(account('acct.x', 'Aaa'))], [at(account('acct.x', 'Zzz'))])));
    });
  });

  test('the accounts of two devices that each added the default categories are the same records, sent once each way', () async {
    final log = MemorySyncTransport();
    on('one');
    final one = BookStore(sync: BookSync.changeLog(log));
    await one.loadAccounts();
    await one.accounts.upsert(const BookAccount(id: 'acct.cash', name: 'Cash', side: AccountSide.own, type: AccountType.cash, currency: 'USD'));
    await one.changeLog!.sync();

    on('two');
    final two = BookStore(sync: BookSync.changeLog(log));
    await two.loadAccounts();
    final round = await two.changeLog!.sync();
    expect(round.pull.applied, 1, reason: 'only the account the other device made is new here');

    on('one');
    final back = await one.changeLog!.sync();
    expect(back.pull.applied, 0);
    expect((await one.changeLog!.sync()).quiet, isTrue);
  });

  test('the device id is not in a backup, and restoring one on another device leaves that device its own id', () async {
    SharedPreferences.setMockInitialValues({});
    final log = MemorySyncTransport();
    Future<(BookStore, BackupService)> device() async {
      final cloud = LocalOnlyCloudKVStore();
      final store = BookStore(sync: BookSync.changeLog(log));
      return (
        store,
        BackupService(
          watchlistStore: WatchlistStore(cloud: cloud),
          bookStore: store,
          customInstrumentStore: CustomInstrumentStore(cloud: cloud),
          alertsStore: AlertsStore(cloud: cloud),
          preferences: await Preferences.create(cloud: cloud),
        ),
      );
    }

    on('phone');
    final (phone, phoneBackup) = await device();
    await phone.entries.upsert(spend('coffee', 450));
    await phone.changeLog!.sync();
    final phoneId = await (phone.changeLog! as SyncEngine).deviceId();
    final backup = await phoneBackup.buildJson();
    expect(backup, isNot(contains(phoneId)));
    expect(backup, isNot(contains('sync.')));

    on('laptop');
    final (laptop, laptopBackup) = await device();
    await laptop.changeLog!.sync();
    final laptopId = await (laptop.changeLog! as SyncEngine).deviceId();
    await laptopBackup.import(await BackupCodec.decodePayload(BackupCodec.parseEnvelope(backup)), mode: BackupImportMode.replace);
    final round = await laptop.changeLog!.sync();
    expect(round.pull.rekeyed, isFalse);
    expect(await (laptop.changeLog! as SyncEngine).deviceId(), laptopId);
    expect(laptopId, isNot(phoneId));

    on('phone');
    final back = await phone.changeLog!.sync();
    expect(back.pull.rekeyed, isFalse);
    expect(await (phone.changeLog! as SyncEngine).deviceId(), phoneId);
    expect((await phone.entries.load()).single.id, 'coffee');
  });
}
