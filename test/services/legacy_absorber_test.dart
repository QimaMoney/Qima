import 'dart:collection';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/asset.dart';
import 'package:qima/models/book.dart';
import 'package:qima/models/book_account.dart';
import 'package:qima/models/book_entry.dart';
import 'package:qima/models/holding_cash_id.dart';
import 'package:qima/models/holding_entry_codec.dart';
import 'package:qima/models/holding_transaction.dart';
import 'package:qima/models/legacy_collapse.dart';
import 'package:qima/models/money_settings.dart';
import 'package:qima/models/syncable.dart';
import 'package:qima/services/book_db/ledger_plan.dart';
import 'package:qima/services/book_store.dart';
import 'package:qima/services/cloud_kv_store.dart';
import 'package:qima/services/legacy_absorber.dart';
import 'package:qima/services/synced_store.dart';

class Mem<T extends Syncable> implements LocalRecords<T> {
  List<Record<T>> held = [];
  int writes = 0;

  @override
  Future<List<Record<T>>> read() async => List.of(held);

  @override
  Future<void> write(List<Record<T>> records) async {
    writes++;
    held = List.of(records);
  }
}

/// One fake iCloud: every read and write is logged.
class Cloud implements CloudKVStore {
  final Map<String, String> values = {};
  final List<String> writes = [];
  final List<String> reads = [];

  @override
  Future<String?> getString(String key) async {
    reads.add(key);
    return values[key];
  }

  @override
  Future<void> setString(String key, String value) async {
    writes.add(key);
    values[key] = value;
  }

  @override
  Future<void> synchronize() async {}

  @override
  Future<bool> accountStatus() async => true;

  @override
  Stream<CloudKVChangeEvent> get didChangeExternally => const Stream.empty();
}

SyncedStore<T> storeOf<T extends Syncable>(String key, T Function(Map<String, dynamic>) fromJson, Cloud cloud, Mem<T> mem, {bool Function(Record<T>, Record<T>)? prefer}) {
  return SyncedStore<T>(
    filePath: '$key.json',
    cloudKey: key,
    itemFromJson: fromJson,
    cloud: cloud,
    local: mem,
    cloudFormat: CloudFormat.envelope,
    prefer: prefer,
    tombstoneTTL: null,
  );
}

/// An updated device: the four ledger stores in memory, over [cloud].
class Device {
  final Cloud cloud;
  final Mem<BookAccount> accountsMem = Mem();
  final Mem<BookEntry> entriesMem = Mem();
  final Mem<RecurringPayment> recurringMem = Mem();
  final Mem<MoneySettings> settingsMem = Mem();
  late final SyncedStore<BookAccount> accounts = storeOf(BookStore.accountsKey, BookAccount.fromJson, cloud, accountsMem);
  late final SyncedStore<BookEntry> entries = storeOf(BookStore.entriesKey, BookEntry.fromJson, cloud, entriesMem, prefer: LegacyCollapse.prefer);
  late final SyncedStore<RecurringPayment> recurring = storeOf(BookStore.recurringKey, RecurringPayment.fromJson, cloud, recurringMem);
  late final SyncedStore<MoneySettings> settings = storeOf(BookStore.settingsKey, MoneySettings.fromJson, cloud, settingsMem);
  late final LegacyAbsorber absorber;
  bool cloudOn = true;

  Device(this.cloud) {
    absorber = LegacyAbsorber(accounts: accounts, entries: entries, recurring: recurring, settings: settings, cloud: cloud, enabled: () => cloudOn);
  }

  Future<void> loadAll() async {
    await accounts.load();
    await entries.load();
    await recurring.load();
    await settings.load();
  }

  Future<String> show() async => jsonEncode({
        'accounts': _sorted(await accounts.exportRecords()),
        'entries': _sorted(await entries.exportRecords()),
        'recurring': _sorted(await recurring.exportRecords()),
        'settings': _sorted(await settings.exportRecords()),
      });
}

List<Map<String, dynamic>> _sorted<T extends Syncable>(List<Record<T>> rs) {
  final l = rs.toList()..sort((a, b) => a.item.id.compareTo(b.item.id));
  return [for (final r in l) r.toJson()];
}

final day = DateTime(2026, 3, 12);
final t0 = DateTime.utc(2026, 5, 1, 10);

/// What a device on the earlier build holds and writes to the old keys.
class Old {
  final Cloud cloud;
  final Map<String, Record<HoldingTransaction>> ts = {};
  final Map<String, Record<BookEntry>> es = {};
  final Map<String, Record<BookAccount>> accounts = {};
  final Map<String, Record<RecurringPayment>> recurring = {};
  final Map<String, Record<MoneySettings>> settings = {};
  final Map<String, String?> account = {};
  int clockMs = 0;

  Old(this.cloud);

  DateTime now() => t0.add(Duration(milliseconds: clockMs += 5));

  void putT(String id, TransactionKind kind, double qty, double px) {
    final t = HoldingTransaction(id: id, instrumentID: 'metal.XAU', kind: kind, quantity: qty, unit: PriceUnit.gram, unitPrice: px, currency: 'USD', date: day);
    ts[id] = Record(item: t, order: ts[id]?.order ?? ts.length.toDouble(), updatedAt: now());
  }

  void delT(String id) => ts[id] = ts[id]!.copyWith(deleted: true, updatedAt: now());

  /// The cash entry the last build wrote for the trade as it stands.
  void syncCash(String id) {
    final t = ts[id]!.item;
    final acct = account[id];
    final total = switch (t.kind) {
      TransactionKind.buy => t.totalCost,
      TransactionKind.sell => t.netProceeds,
      TransactionKind.fee => t.fee,
      _ => 0.0,
    };
    final cid = holdingCashId(id);
    final held = es[cid];
    if (acct == null || total <= 0) {
      if (held != null && !held.deleted) es[cid] = held.copyWith(deleted: true, updatedAt: now());
      return;
    }
    final amount = (total * 100).round();
    final signed = t.kind == TransactionKind.sell ? amount : -amount;
    es[cid] = Record(
      item: BookEntry(id: cid, date: day, template: EntryTemplate.holdingTrade, baseCurrency: 'USD', merchant: 'Gold', lines: [
        EntryLine(accountId: acct, amount: signed, currency: 'USD', baseAmount: signed),
        EntryLine(accountId: 'system.holdings', amount: -signed, currency: 'USD', baseAmount: -signed),
      ]),
      order: held?.order ?? 100 + es.length.toDouble(),
      updatedAt: now(),
    );
  }

  void removeCash(String id) {
    final held = es[holdingCashId(id)];
    if (held != null && !held.deleted) es[holdingCashId(id)] = held.copyWith(deleted: true, updatedAt: now());
  }

  void putSpend(String id, int amount, {String from = 'acct.wallet', DateTime? stamp}) {
    es[id] = Record(
      item: BookEntry(id: id, date: day, template: EntryTemplate.spend, baseCurrency: 'USD', merchant: 'Shop $id', lines: [
        EntryLine(accountId: from, amount: -amount, currency: 'USD', baseAmount: -amount),
        EntryLine(accountId: 'cat.food', amount: amount, currency: 'USD', baseAmount: amount),
      ]),
      order: es[id]?.order ?? 200 + es.length.toDouble(),
      updatedAt: stamp ?? now(),
    );
  }

  void putAccount(String id, String name, {DateTime? stamp}) {
    accounts[id] = Record(
      item: BookAccount(id: id, name: name, side: AccountSide.own, type: AccountType.cash, currency: 'USD'),
      order: accounts[id]?.order ?? accounts.length.toDouble(),
      updatedAt: stamp ?? now(),
    );
  }

  void putRecurring(String id, String name) {
    recurring[id] = Record(
      item: RecurringPayment(id: id, name: name, amount: 1200, fromAccountId: 'acct.wallet', categoryId: 'cat.food', start: DateTime(2026, 6, 1)),
      order: recurring[id]?.order ?? recurring.length.toDouble(),
      updatedAt: now(),
    );
  }

  void putSettings(Set<MoneyFeature> features) {
    settings[MoneySettings.recordId] = Record(item: MoneySettings(features: features), order: 0, updatedAt: now());
  }

  /// Writes every old key as the earlier build does: a plain record list.
  void flush() {
    String list<T extends Syncable>(Iterable<Record<T>> rs) => jsonEncode([for (final r in rs) r.toJson()]);
    cloud.values[LedgerNames.legacyAccounts] = list(accounts.values);
    cloud.values[LedgerNames.legacyEntries] = list(es.values);
    cloud.values[LedgerNames.legacyRecurring] = list(recurring.values);
    cloud.values[LedgerNames.legacySettings] = list(settings.values);
    cloud.values[LedgerNames.legacyTransactions] = list(ts.values);
    cloud.values[LedgerNames.legacyLots] = '[]';
    cloud.writes.clear();
  }

  Map<String, int> money() => moneyOf(es.values);
}

Map<String, int> moneyOf(Iterable<Record<BookEntry>> rs) {
  final out = SplayTreeMap<String, int>();
  for (final r in rs) {
    if (r.deleted || !r.item.counts) continue;
    for (final l in r.item.lines) {
      if (l.accountId.startsWith('acct.')) out[l.accountId] = (out[l.accountId] ?? 0) + l.amount;
    }
  }
  out.removeWhere((k, v) => v == 0);
  return out;
}

Future<Record<BookEntry>?> entryOf(Device d, String id) async => (await d.entries.exportRecords()).where((r) => r.item.id == id).firstOrNull;

void main() {
  group('trades', () {
    test('a trade with cash made on an old device appears as one entry', () async {
      final cloud = Cloud();
      final old = Old(cloud);
      final d = Device(cloud);
      old.account['a'] = 'acct.bank';
      old.putT('a', TransactionKind.buy, 10, 50);
      old.syncCash('a');
      old.flush();

      expect(await d.absorber.absorb(), {BookStore.entriesKey});

      final records = await d.entries.exportRecords();
      final live = records.where((r) => !r.deleted).toList();
      expect(live.map((r) => r.item.id), ['a']);
      final trade = HoldingEntryCodec.fromEntry(live.single.item);
      expect(trade.quantity, 10);
      expect(HoldingEntryCodec.cashLegOf(live.single.item)?.accountId, 'acct.bank');
      expect(moneyOf(records), {'acct.bank': -50000});
      // The cash half is its own record only as a deletion.
      expect(records.firstWhere((r) => r.item.id == holdingCashId('a')).deleted, isTrue);
    });

    test('an edit on the old device updates it, a delete removes it with no cash left', () async {
      final cloud = Cloud();
      final old = Old(cloud);
      final d = Device(cloud);
      old.account['a'] = 'acct.bank';
      old.putT('a', TransactionKind.buy, 10, 50);
      old.syncCash('a');
      old.flush();
      await d.absorber.absorb();

      old.putT('a', TransactionKind.buy, 4, 50);
      old.syncCash('a');
      old.flush();
      expect(await d.absorber.absorb(), {BookStore.entriesKey});
      var records = await d.entries.exportRecords();
      expect(HoldingEntryCodec.fromEntry(records.firstWhere((r) => r.item.id == 'a').item).quantity, 4);
      expect(moneyOf(records), {'acct.bank': -20000});

      old.delT('a');
      old.removeCash('a');
      old.flush();
      expect(await d.absorber.absorb(), {BookStore.entriesKey});
      records = await d.entries.exportRecords();
      expect(records.firstWhere((r) => r.item.id == 'a').deleted, isTrue);
      expect(moneyOf(records), isEmpty);
      expect(await d.entries.load(), isEmpty);
    });

    test('a trade of lots only (no trade record) is taken as a buy', () async {
      final cloud = Cloud();
      final d = Device(cloud);
      cloud.values[LedgerNames.legacyLots] = jsonEncode([
        {
          'item': {'id': 'lot1', 'instrumentID': 'metal.XAU', 'quantity': 3.0, 'unit': PriceUnit.gram.name, 'unitCost': 40.0, 'costCurrency': 'USD', 'date': day.toIso8601String()},
          'order': 0.0,
          'updatedAt': t0.toIso8601String(),
          'deleted': false,
        }
      ]);
      await d.absorber.absorb();
      final r = await entryOf(d, 'lot1');
      expect(r, isNotNull);
      expect(HoldingEntryCodec.fromEntry(r!.item).quantity, 3);
    });
  });

  group('the rest of the book', () {
    test('a plain entry, an account and a recurring payment appear', () async {
      final cloud = Cloud();
      final old = Old(cloud);
      final d = Device(cloud);
      old.putAccount('acct.wallet', 'Wallet');
      old.putSpend('e1', 500);
      old.putRecurring('r1', 'Rent');
      old.flush();

      expect(await d.absorber.absorb(), {BookStore.accountsKey, BookStore.entriesKey, BookStore.recurringKey});
      expect((await d.accounts.load()).map((a) => a.id), contains('acct.wallet'));
      expect((await d.entries.load()).map((e) => e.id), ['e1']);
      expect((await d.recurring.load()).map((r) => r.id), ['r1']);
      // Same stamps and order as the old device wrote.
      final r = (await d.entries.exportRecords()).single;
      expect(r.updatedAt, old.es['e1']!.updatedAt);
      expect(r.order, old.es['e1']!.order);
    });

    test('old settings are taken when the ledger has none, ignored once it has one', () async {
      final cloud = Cloud();
      final old = Old(cloud);
      old.putSettings({MoneyFeature.budget});
      old.flush();

      final fresh = Device(cloud);
      expect(await fresh.absorber.absorb(), {BookStore.settingsKey});
      expect((await fresh.settings.load()).single.features, {MoneyFeature.budget});

      final cloud2 = Cloud();
      final old2 = Old(cloud2);
      final own = Device(cloud2);
      await own.settings.upsert(const MoneySettings(features: {MoneyFeature.zakat}));
      old2.putSettings({MoneyFeature.budget});
      old2.flush();
      expect(await own.absorber.absorb(), isEmpty);
      expect((await own.settings.load()).single.features, {MoneyFeature.zakat});

      // A deleted settings record counts as one too.
      final cloud3 = Cloud();
      final old3 = Old(cloud3);
      final gone = Device(cloud3);
      await gone.settings.upsert(const MoneySettings());
      await gone.settings.delete(MoneySettings.recordId);
      old3.putSettings({MoneyFeature.budget});
      old3.flush();
      expect(await gone.absorber.absorb(), isEmpty);
    });

    test('an old rewrite of whole collections with unchanged stamps changes nothing after a newer edit here', () async {
      final cloud = Cloud();
      final old = Old(cloud);
      final d = Device(cloud);
      old.putAccount('acct.wallet', 'Wallet');
      old.putSpend('e1', 500);
      old.flush();
      await d.absorber.absorb();

      // The updated device edits the entry and renames the account.
      final edited = old.es['e1']!.item.copyWith(merchant: 'Edited here');
      await d.entries.upsert(edited);
      await d.accounts.upsert(old.accounts['acct.wallet']!.item.copyWith(name: 'Renamed here'));

      // The old device rewrites every collection (records and stamps as they
      // were) and adds one new entry.
      old.putSpend('e2', 700);
      old.flush();
      expect(await d.absorber.absorb(), {BookStore.entriesKey});
      final all = await d.entries.load();
      expect(all.firstWhere((e) => e.id == 'e1').merchant, 'Edited here');
      expect(all.map((e) => e.id), containsAll(['e1', 'e2']));
      expect((await d.accounts.load()).firstWhere((a) => a.id == 'acct.wallet').name, 'Renamed here');
    });
  });

  group('safety', () {
    test('an undecodable, absent or envelope value is harmless', () async {
      final cloud = Cloud();
      final old = Old(cloud);
      final d = Device(cloud);
      old.putAccount('acct.wallet', 'Wallet');
      old.putSpend('e1', 500);
      old.flush();
      cloud.values[LedgerNames.legacyEntries] = '{"v":1,"z":"gzip","data":"AAAA"}';
      cloud.values[LedgerNames.legacyRecurring] = 'not json at all';
      cloud.values.remove(LedgerNames.legacyLots);

      expect(await d.absorber.absorb(), {BookStore.accountsKey});
      expect(d.absorber.lastProblem, isNotNull);
      expect(await d.entries.load(), isEmpty);
      expect(await d.recurring.load(), isEmpty);

      // A list whose record cannot be read is unusable as a whole.
      cloud.values[LedgerNames.legacyEntries] = '[{"item": 3}]';
      cloud.values[LedgerNames.legacyTransactions] = '[]';
      expect(await d.absorber.absorb(), isEmpty);
      expect(await d.entries.load(), isEmpty);
    });

    test('with one of entries, trades and lots unreadable none of the three is taken, and the value is retried when it changes', () async {
      final cloud = Cloud();
      final old = Old(cloud);
      final d = Device(cloud);
      old.account['a'] = 'acct.bank';
      old.putT('a', TransactionKind.buy, 10, 50);
      old.syncCash('a');
      old.flush();
      final goodEntries = cloud.values[LedgerNames.legacyEntries]!;
      cloud.values[LedgerNames.legacyEntries] = '[1]';
      expect(await d.absorber.absorb(), isEmpty);
      expect(await d.entries.exportRecords(), isEmpty);

      cloud.values[LedgerNames.legacyEntries] = goodEntries;
      expect(await d.absorber.absorb(), {BookStore.entriesKey});
      expect(moneyOf(await d.entries.exportRecords()), {'acct.bank': -50000});
      expect(d.absorber.lastProblem, isNull);
    });

    test('nothing is ever written to an old key, and old values stay as they were', () async {
      final cloud = Cloud();
      final old = Old(cloud);
      final d = Device(cloud);
      old.account['a'] = 'acct.bank';
      old.putT('a', TransactionKind.buy, 10, 50);
      old.syncCash('a');
      old.putAccount('acct.wallet', 'Wallet');
      old.putSpend('e1', 500);
      old.putRecurring('r1', 'Rent');
      old.putSettings({MoneyFeature.budget});
      old.flush();
      final before = Map.of(cloud.values);

      await d.absorber.absorb();
      await d.loadAll();
      old.delT('a');
      old.removeCash('a');
      old.flush();
      final after = Map.of(cloud.values);
      cloud.writes.clear();
      await d.absorber.absorb();
      await d.loadAll();

      expect(cloud.writes.where(LegacyAbsorber.keys.contains), isEmpty);
      for (final k in LegacyAbsorber.keys) {
        expect(cloud.values[k], after[k], reason: k);
      }
      // The new keys were written, so the writes above are not vacuous.
      expect(cloud.writes, isNotEmpty);
      expect(before.keys.toSet(), containsAll(LegacyAbsorber.keys));
    });

    test('an unchanged old value is not read into the stores again, until reset', () async {
      final cloud = Cloud();
      final old = Old(cloud);
      final d = Device(cloud);
      old.putSpend('e1', 500);
      old.flush();
      await d.absorber.absorb();
      final writes = d.entriesMem.writes;

      expect(await d.absorber.absorb(), isEmpty);
      expect(d.entriesMem.writes, writes);

      // Reset reads again; nothing is new, so nothing changes.
      d.absorber.reset();
      cloud.reads.clear();
      expect(await d.absorber.absorb(), isEmpty);
      expect(cloud.reads.where(LegacyAbsorber.keys.contains).toSet(), LegacyAbsorber.keys.toSet());
      expect(d.entriesMem.writes, writes);
    });

    test('two runs at once take it once and leave no duplicates', () async {
      final cloud = Cloud();
      final old = Old(cloud);
      final d = Device(cloud);
      old.account['a'] = 'acct.bank';
      old.putT('a', TransactionKind.buy, 10, 50);
      old.syncCash('a');
      old.putSpend('e1', 500);
      old.flush();

      final results = await Future.wait([d.absorber.absorb(), d.absorber.absorb(), d.absorber.absorb()]);
      expect(results.where((r) => r.isNotEmpty), hasLength(1));
      final records = await d.entries.exportRecords();
      expect(records.map((r) => r.item.id).toSet().length, records.length);
    });

    test('while the cloud is off nothing is read or taken; switching it on takes it', () async {
      final cloud = Cloud();
      final old = Old(cloud);
      final d = Device(cloud)..cloudOn = false;
      old.putSpend('e1', 500);
      old.flush();

      expect(await d.absorber.absorb(), isEmpty);
      expect(cloud.reads, isEmpty);
      expect(await d.entries.exportRecords(), isEmpty);

      d.cloudOn = true;
      expect(await d.absorber.absorb(), {BookStore.entriesKey});
    });

    test('an error from a store is thrown, the run is not marked done, and the next run does it', () async {
      final cloud = Cloud();
      final old = Old(cloud);
      old.putSpend('e1', 500);
      old.flush();
      var fail = true;
      final d = Device(cloud);
      final flaky = LegacyAbsorber(
        accounts: d.accounts,
        entries: d.entries,
        recurring: d.recurring,
        settings: d.settings,
        cloud: _Failing(cloud, () => fail),
      );
      await expectLater(flaky.absorb(), throwsA(isA<StateError>()));
      expect(await d.entries.exportRecords(), isEmpty);
      fail = false;
      expect(await flaky.absorb(), {BookStore.entriesKey});
    });
  });

  group('accounts the new device deleted', () {
    test('an entry posting to a deleted account is taken; the account stays deleted and the book reports it', () async {
      final cloud = Cloud();
      final old = Old(cloud);
      final d = Device(cloud);
      old.putAccount('acct.old', 'Old wallet');
      old.putSpend('e1', 500, from: 'acct.old');
      old.flush();
      await d.absorber.absorb();
      expect((await d.accounts.load()).map((a) => a.id), contains('acct.old'));

      // This device deletes the account (stamped now, later than the old ones).
      await d.accounts.delete('acct.old');
      // The old device posts a new entry to it.
      old.putSpend('e2', 300, from: 'acct.old');
      old.flush();
      await d.absorber.absorb();

      final live = await d.accounts.load();
      expect(live.map((a) => a.id), isNot(contains('acct.old')));
      final entries = await d.entries.load();
      expect(entries.map((e) => e.id), containsAll(['e1', 'e2']));
      final issues = Book([...live, BookAccount(id: 'cat.food', name: 'Food', side: AccountSide.spending, type: AccountType.category)], entries).issues;
      expect(issues.where((i) => i.problem == EntryProblem.unknownAccount).map((i) => i.id).toSet(), {'e1', 'e2'});
    });

    test('an old edit of the account made after the deletion brings it back', () async {
      final cloud = Cloud();
      final old = Old(cloud);
      final d = Device(cloud);
      old.putAccount('acct.old', 'Old wallet');
      old.flush();
      await d.absorber.absorb();
      await d.accounts.delete('acct.old');

      old.putAccount('acct.old', 'Old wallet, renamed', stamp: DateTime.utc(2099));
      old.flush();
      expect(await d.absorber.absorb(), {BookStore.accountsKey});
      expect((await d.accounts.load()).map((a) => a.id), contains('acct.old'));
    });
  });

  group('accounts an old device removed', () {
    BookEntry income(String id, String account) => BookEntry(id: id, date: day, template: EntryTemplate.income, baseCurrency: 'USD', merchant: 'Pay', lines: [
          EntryLine(accountId: account, amount: 900, currency: 'USD', baseAmount: 900),
          const EntryLine(accountId: 'cat.salary', amount: -900, currency: 'USD', baseAmount: -900),
        ]);

    test('a tombstone is not taken while a live entry posts to the account, and the entry has no unknown account', () async {
      final cloud = Cloud();
      final old = Old(cloud);
      final d = Device(cloud);
      old.putAccount('acct.spare', 'Spare');
      old.flush();
      await d.absorber.absorb();

      // The updated device posts to the account; the old one, which does not
      // know of that, removes it as unused with a later stamp.
      await d.entries.upsert(income('pay', 'acct.spare'));
      old.accounts['acct.spare'] = old.accounts['acct.spare']!.copyWith(deleted: true, updatedAt: DateTime.utc(2099));
      old.flush();
      await d.absorber.absorb();

      final live = await d.accounts.load();
      expect(live.map((a) => a.id), contains('acct.spare'));
      final issues = Book([...live, BookAccount(id: 'cat.salary', name: 'Salary', side: AccountSide.income, type: AccountType.category)], await d.entries.load()).issues;
      expect(issues.where((i) => i.problem == EntryProblem.unknownAccount), isEmpty);
    });

    test('a tombstone of an account nothing posts to is taken, and so is one only a deleted entry posts to', () async {
      final cloud = Cloud();
      final old = Old(cloud);
      final d = Device(cloud);
      old.putAccount('acct.spare', 'Spare');
      old.putAccount('acct.unused', 'Unused');
      old.flush();
      await d.absorber.absorb();
      await d.entries.upsert(income('pay', 'acct.spare'));
      await d.entries.delete('pay');

      old.accounts['acct.spare'] = old.accounts['acct.spare']!.copyWith(deleted: true, updatedAt: DateTime.utc(2099));
      old.accounts['acct.unused'] = old.accounts['acct.unused']!.copyWith(deleted: true, updatedAt: DateTime.utc(2099));
      old.flush();
      expect(await d.absorber.absorb(), {BookStore.accountsKey});
      final live = (await d.accounts.load()).map((a) => a.id);
      expect(live, isNot(contains('acct.unused')));
      expect(live, isNot(contains('acct.spare')));
    });

    test('the other accounts of the same value are still taken', () async {
      final cloud = Cloud();
      final old = Old(cloud);
      final d = Device(cloud);
      old.putAccount('acct.spare', 'Spare');
      old.flush();
      await d.absorber.absorb();
      await d.entries.upsert(income('pay', 'acct.spare'));
      old.accounts['acct.spare'] = old.accounts['acct.spare']!.copyWith(deleted: true, updatedAt: DateTime.utc(2099));
      old.putAccount('acct.new', 'New');
      old.flush();
      expect(await d.absorber.absorb(), {BookStore.accountsKey});
      expect((await d.accounts.load()).map((a) => a.id), containsAll(['acct.spare', 'acct.new']));
    });
  });

  group('a trade whose id is an entry that is not a holding', () {
    BookEntry spend(String id, int amount) => BookEntry(id: id, date: day, template: EntryTemplate.spend, baseCurrency: 'USD', merchant: 'Mine', lines: [
          EntryLine(accountId: 'acct.wallet', amount: -amount, currency: 'USD', baseAmount: -amount),
          EntryLine(accountId: 'cat.food', amount: amount, currency: 'USD', baseAmount: amount),
        ]);

    test('is left out whether the old stamp is later or earlier, the rest is taken, and the ids are named', () async {
      final cloud = Cloud();
      final old = Old(cloud);
      final d = Device(cloud);
      await d.entries.upsert(spend('x', 111));
      await d.entries.upsert(spend('y', 222));
      final mine = {for (final r in await d.entries.exportRecords()) r.item.id: r};

      old.putT('x', TransactionKind.buy, 10, 50); // stamped after the entry
      old.ts['x'] = old.ts['x']!.copyWith(updatedAt: DateTime.utc(2099));
      old.putT('y', TransactionKind.buy, 10, 50); // stamped before it
      old.ts['y'] = old.ts['y']!.copyWith(updatedAt: DateTime.utc(2001));
      old.account['ok'] = 'acct.bank';
      old.putT('ok', TransactionKind.buy, 2, 50);
      old.syncCash('ok');
      old.flush();

      expect(await d.absorber.absorb(), {BookStore.entriesKey});
      final after = {for (final r in await d.entries.exportRecords()) r.item.id: r};
      for (final id in ['x', 'y']) {
        expect(jsonEncode(after[id]!.toJson()), jsonEncode(mine[id]!.toJson()), reason: '$id stays the money entry');
        expect(after[id]!.item.template, EntryTemplate.spend);
      }
      expect(after['ok']!.item.template.isHoldingEntry, isTrue);
      expect(d.absorber.lastProblem.toString(), allOf(contains('x, y'), contains('left out')));
    });

    test('an old entry with the id of an old trade counts as a clash too', () async {
      final cloud = Cloud();
      final old = Old(cloud);
      final d = Device(cloud);
      old.putSpend('z', 300);
      old.putT('z', TransactionKind.buy, 1, 50);
      old.putT('w', TransactionKind.buy, 1, 50);
      old.flush();

      await d.absorber.absorb();
      final after = {for (final r in await d.entries.exportRecords()) r.item.id: r};
      expect(after['z']!.item.template, EntryTemplate.spend);
      expect(after['w']!.item.template.isHoldingEntry, isTrue);
      expect(d.absorber.lastProblem.toString(), contains('z'));
    });

    test('a trade that clashes with nothing leaves no problem', () async {
      final cloud = Cloud();
      final old = Old(cloud);
      final d = Device(cloud);
      await d.entries.upsert(spend('x', 111));
      old.putT('t', TransactionKind.buy, 10, 50);
      old.flush();
      await d.absorber.absorb();
      expect(d.absorber.lastProblem, isNull);
    });
  });

  group('every path agrees', () {
    /// The old device writes in steps; devices read at different moments.
    Future<void> step(Old old, void Function() w) async {
      w();
      old.flush();
    }

    test('two updated devices absorbing at different moments hold the same records as a fresh one', () async {
      final cloud = Cloud();
      final old = Old(cloud);
      final a = Device(cloud), b = Device(cloud);
      old.account['t'] = 'acct.bank';

      await step(old, () {
        old.putAccount('acct.bank', 'Bank');
        old.putT('t', TransactionKind.buy, 10, 50);
        old.syncCash('t');
        old.putSpend('e1', 500);
      });
      await a.absorber.absorb();
      await step(old, () {
        old.putT('t', TransactionKind.buy, 6, 50);
        old.syncCash('t');
        old.putRecurring('r1', 'Rent');
      });
      await b.absorber.absorb();
      await a.loadAll();
      await step(old, () {
        old.delT('t');
        old.removeCash('t');
        old.putSpend('e1', 650);
      });
      await a.absorber.absorb();
      await b.absorber.absorb();
      await a.loadAll();
      await b.loadAll();
      await a.loadAll();

      final fresh = Device(Cloud());
      fresh.cloud.values.addAll({for (final k in LegacyAbsorber.keys) k: cloud.values[k]!});
      await fresh.absorber.absorb();

      final truth = await fresh.show();
      expect(await a.show(), truth);
      expect(await b.show(), truth);
      expect(moneyOf(await a.entries.exportRecords()), old.money());
    });

    test('a device whose local copy came from the migration merges with the new keys with no duplicates', () async {
      final cloud = Cloud();
      final old = Old(cloud);
      final a = Device(cloud), m = Device(cloud);
      old.account['t'] = 'acct.bank';
      old.account['u'] = null;

      await step(old, () {
        old.putAccount('acct.bank', 'Bank');
        old.putT('t', TransactionKind.buy, 10, 50);
        old.syncCash('t');
        old.putT('u', TransactionKind.buy, 2, 70);
        old.syncCash('u');
        old.putSpend('e1', 500);
      });
      // Device a absorbed at this moment, and the new keys now hold it.
      await a.absorber.absorb();
      await a.loadAll();

      // Device m migrated its own local copy at this moment, with the very
      // function the migration uses.
      m.entriesMem.held = LedgerPlan.collapse(old.es.values.toList(), LedgerSources(old.ts.values.toList(), const [])).records;
      m.accountsMem.held = old.accounts.values.toList();

      // The old device carries on.
      await step(old, () {
        old.putT('t', TransactionKind.sell, 3, 80);
        old.syncCash('t');
        old.delT('u');
        old.removeCash('u');
      });
      await m.loadAll(); // merges the local migration result with the new keys
      var records = await m.entries.exportRecords();
      expect(records.map((r) => r.item.id).toSet().length, records.length);
      await m.absorber.absorb();
      await a.absorber.absorb();
      await m.loadAll();
      await a.loadAll();
      await m.loadAll();

      final fresh = Device(Cloud());
      fresh.cloud.values.addAll({for (final k in LegacyAbsorber.keys) k: cloud.values[k]!});
      await fresh.absorber.absorb();
      final truth = await fresh.show();
      expect(await a.show(), truth);
      expect(await m.show(), truth);
      records = await m.entries.exportRecords();
      expect(moneyOf(records), old.money());
      expect(records.map((r) => r.item.id).toSet().length, records.length);
    });
  });
}

/// Reads fail while [failing] says so.
class _Failing implements CloudKVStore {
  final Cloud inner;
  final bool Function() failing;

  _Failing(this.inner, this.failing);

  @override
  Future<String?> getString(String key) async {
    if (failing()) throw StateError('cloud unavailable');
    return inner.getString(key);
  }

  @override
  Future<void> setString(String key, String value) => inner.setString(key, value);

  @override
  Future<void> synchronize() => inner.synchronize();

  @override
  Future<bool> accountStatus() => inner.accountStatus();

  @override
  Stream<CloudKVChangeEvent> get didChangeExternally => inner.didChangeExternally;
}
