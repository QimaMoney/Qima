import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/asset.dart';
import 'package:qima/models/book_entry.dart';
import 'package:qima/models/holding_cash_id.dart';
import 'package:qima/models/holding_entry_codec.dart';
import 'package:qima/models/holding_transaction.dart';
import 'package:qima/models/legacy_collapse.dart';
import 'package:qima/services/cloud_kv_store.dart';
import 'package:qima/services/synced_store.dart';

/// Real `SyncedStore`s over one fake cloud, taking what an old device keeps
/// writing, as new devices read the two old keys at different moments.

class Mem implements LocalRecords<BookEntry> {
  List<Record<BookEntry>> held = [];

  @override
  Future<List<Record<BookEntry>>> read() async => List.of(held);

  @override
  Future<void> write(List<Record<BookEntry>> records) async => held = List.of(records);
}

class Cloud implements CloudKVStore {
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

final day = DateTime(2026, 3, 12);
final t0 = DateTime.utc(2026, 5, 1, 10);

/// What an old device holds: the latest record per id, written under the
/// stamps it gives them.
class Old {
  final Map<String, Record<HoldingTransaction>> ts = {};
  final Map<String, Record<BookEntry>> es = {};
  final Map<String, String?> account = {};
  int clockMs = 0;

  DateTime now() => t0.add(Duration(milliseconds: clockMs));

  void putT(String id, TransactionKind kind, double qty, double px, {bool deleted = false}) {
    final t = HoldingTransaction(id: id, instrumentID: 'metal.XAU', kind: kind, quantity: qty, unit: PriceUnit.gram, unitPrice: px, currency: 'USD', date: day);
    ts[id] = Record(item: t, order: ts[id]?.order ?? ts.length.toDouble(), updatedAt: now(), deleted: deleted);
  }

  void delT(String id) => ts[id] = ts[id]!.copyWith(deleted: true, updatedAt: now());

  /// What the last build wrote as the cash entry for the row as it stands.
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

  /// What the person's books hold in each cash account.
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

String show(Iterable<Record<BookEntry>> rs) {
  final l = rs.toList()..sort((a, b) => a.item.id.compareTo(b.item.id));
  return jsonEncode([for (final r in l) r.toJson()]);
}

class Device {
  final Mem local = Mem();
  late final SyncedStore<BookEntry> store;
  List<Record<HoldingTransaction>> viewT = [];
  List<Record<BookEntry>> viewE = [];

  Device(String name, Cloud cloud) {
    store = SyncedStore<BookEntry>(
      filePath: '$name.json',
      cloudKey: 'v5.entries',
      itemFromJson: BookEntry.fromJson,
      cloud: cloud,
      local: local,
      cloudFormat: CloudFormat.envelope,
      prefer: LegacyCollapse.prefer,
      tombstoneTTL: null,
    );
  }

  Future<bool> intake() => store.absorb(LegacyCollapse.collapse(transactions: viewT, lots: const [], entries: viewE));

  Future<List<Record<BookEntry>>> records() => store.exportRecords();
}

/// Settles every device on [old] as it is now and returns why not, if it did not.
Future<String?> settleAndCheck(Old old, List<Device> devices) async {
  final finalT = old.ts.values.toList(), finalE = old.es.values.toList();
  final fresh = Device('fresh', Cloud())
    ..viewT = finalT
    ..viewE = finalE;
  await fresh.intake();
  final truth = show(await fresh.records());
  for (var round = 0; round < 3; round++) {
    for (final d in devices) {
      d.viewT = finalT;
      d.viewE = finalE;
      await d.intake();
    }
    for (final d in devices) {
      await d.store.load();
    }
  }
  for (var i = 0; i < devices.length; i++) {
    final got = await devices[i].records();
    if (show(got) != truth) return 'device $i differs from a fresh device:\n${show(got)}\nfresh:\n$truth';
    if (moneyOf(got).toString() != old.money().toString()) return 'device $i holds ${moneyOf(got)}, the old device ${old.money()}';
    for (final t in old.ts.values) {
      final r = got.where((r) => r.item.id == t.item.id).firstOrNull;
      if (r == null) return 'device $i has no record of ${t.item.id}';
      if (r.deleted != t.deleted) return 'device $i: ${t.item.id} deleted=${r.deleted}, old ${t.deleted}';
      if (!t.deleted && HoldingEntryCodec.tryFromEntry(r.item) != t.item) return 'device $i: ${t.item.id} reads ${HoldingEntryCodec.tryFromEntry(r.item)}, old ${t.item}';
    }
    // Cash entries that are not deleted must be ones the old device still has live.
    for (final r in got) {
      if (!r.deleted && r.item.template == EntryTemplate.holdingTrade && !(old.es[r.item.id]?.deleted == false)) return 'device $i keeps a cash entry ${r.item.id} the old device deleted';
    }
  }
  // Quiet: nothing more to take, and loading changes nothing.
  for (final d in devices) {
    if (await d.intake()) return 'a device still took records from the final state';
    await d.store.load();
    if (show(await d.records()) != truth) return 'a further load changed a device';
  }
  return null;
}

/// One random history: an old device writing, new devices reading.
Future<String?> runSeed(int seed, {required bool keysApart}) async {
  final rnd = Random(seed);
  final old = Old();
  final cloud = Cloud();
  final devices = [for (var i = 0; i < 1 + rnd.nextInt(3); i++) Device('d$i', cloud)];
  final ids = ['a', 'b'].sublist(0, 1 + rnd.nextInt(2));
  final kinds = [TransactionKind.buy, TransactionKind.sell, TransactionKind.fee, TransactionKind.transferIn];
  final pending = <void Function()>[];

  void write(void Function() w) => pending.add(() {
        old.clockMs += 2 + rnd.nextInt(7);
        w();
      });

  TransactionKind pickKind() => kinds[rnd.nextInt(kinds.length)];
  String? pickAccount() => [null, 'acct.bank', 'acct.card'][rnd.nextInt(3)];

  void newAction() {
    final id = ids[rnd.nextInt(ids.length)];
    final held = old.ts[id];
    if (held == null || held.deleted) {
      // add, or add again under the same id
      final kind = pickKind();
      final qty = 1 + rnd.nextInt(9).toDouble(), px = 10 + rnd.nextInt(90).toDouble();
      final acct = pickAccount();
      write(() {
        old.account[id] = acct;
        old.putT(id, kind, qty, px);
      });
      write(() => old.syncCash(id));
      return;
    }
    switch (rnd.nextInt(4)) {
      case 0: // edit the trade
        final kind = rnd.nextBool() ? held.item.kind : pickKind();
        final qty = 1 + rnd.nextInt(9).toDouble(), px = 10 + rnd.nextInt(90).toDouble();
        write(() => old.putT(id, kind, qty, px));
        write(() => old.syncCash(id));
      case 1: // pay from another account
        final acct = pickAccount();
        write(() {
          old.account[id] = acct;
          old.putT(id, held.item.kind, held.item.quantity, held.item.unitPrice);
        });
        write(() => old.syncCash(id));
      case 2: // take the cash off
        write(() {
          old.account[id] = null;
          old.putT(id, held.item.kind, held.item.quantity, held.item.unitPrice);
        });
        write(() => old.syncCash(id));
      default: // delete the trade
        write(() => old.delT(id));
        write(() => old.removeCash(id));
    }
  }

  Future<void> deviceEvent() async {
    final d = devices[rnd.nextInt(devices.length)];
    switch (rnd.nextInt(keysApart ? 5 : 3)) {
      case 0:
        d.viewT = old.ts.values.toList();
        d.viewE = old.es.values.toList();
        await d.intake();
      case 1:
        await d.store.load();
      case 2:
        await d.intake();
      case 3:
        d.viewT = old.ts.values.toList();
      default:
        d.viewE = old.es.values.toList();
    }
  }

  for (var step = 0; step < 36; step++) {
    if (rnd.nextInt(100) < 55) {
      if (pending.isEmpty) newAction();
      pending.removeAt(0)();
    } else {
      await deviceEvent();
    }
  }
  while (pending.isNotEmpty) {
    pending.removeAt(0)();
  }
  return settleAndCheck(old, devices);
}

void main() {
  for (final keysApart in [false, true]) {
    test('${keysApart ? 'the two keys read at different moments' : 'both keys read together'}: every device settles on what a fresh device holds', () async {
      for (var seed = 0; seed < 320; seed++) {
        final why = await runSeed(seed, keysApart: keysApart);
        if (why != null) fail('seed $seed (keysApart: $keysApart): $why');
      }
    });
  }

  group('ordered sequences of old-device writes', () {
    Future<void> expectSettled(Old old, List<Device> devices) async {
      final why = await settleAndCheck(old, devices);
      expect(why, isNull);
    }

    test('deleting the trade, read between its two writes, leaves no cash behind', () async {
      final cloud = Cloud();
      final d = Device('d', cloud), e = Device('e', cloud);
      final old = Old();
      old.account['a'] = 'acct.bank';
      old.clockMs = 100;
      old.putT('a', TransactionKind.buy, 10, 50);
      old.clockMs = 105;
      old.syncCash('a');
      old.clockMs = 200;
      old.delT('a');
      // a device reads between the trade write and the cash delete
      d.viewT = old.ts.values.toList();
      d.viewE = old.es.values.toList();
      await d.intake();
      expect(moneyOf(await d.records()), {'acct.bank': -50000});
      old.clockMs = 205;
      old.removeCash('a');
      await expectSettled(old, [d, e]);
      expect(moneyOf(await d.records()), isEmpty);
    });

    test('the cash key read before the trade key, then the cash removed', () async {
      final cloud = Cloud();
      final d = Device('d', cloud);
      final old = Old();
      old.account['a'] = 'acct.bank';
      old.clockMs = 100;
      old.putT('a', TransactionKind.buy, 10, 50);
      old.clockMs = 105;
      old.syncCash('a');
      d.viewE = old.es.values.toList(); // only the cash key
      await d.intake();
      old.clockMs = 200;
      old.account['a'] = null;
      old.putT('a', TransactionKind.buy, 10, 50);
      old.clockMs = 205;
      old.syncCash('a');
      await expectSettled(old, [d]);
      expect(moneyOf(await d.records()), isEmpty);
    });

    test('a cash key that is ahead of the trade key does not hide the trade edit', () async {
      final cloud = Cloud();
      final d = Device('d', cloud);
      final old = Old();
      old.account['a'] = 'acct.bank';
      old.clockMs = 100;
      old.putT('a', TransactionKind.buy, 10, 50);
      old.clockMs = 105;
      old.syncCash('a');
      d.viewT = old.ts.values.toList();
      d.viewE = old.es.values.toList();
      await d.intake();
      final staleT = old.ts.values.toList();
      old.clockMs = 200;
      old.putT('a', TransactionKind.buy, 2, 50);
      old.clockMs = 205;
      old.syncCash('a');
      d.viewT = staleT;
      d.viewE = old.es.values.toList(); // new cash, old trade
      await d.intake();
      await expectSettled(old, [d]);
      expect(HoldingEntryCodec.fromEntry((await d.records()).firstWhere((r) => r.item.id == 'a').item).quantity, 2);
    });

    test('a stale live cash entry beside a newer trade does not outrank the entry with the cash taken off', () async {
      final cloud = Cloud();
      final d = Device('d', cloud);
      final old = Old();
      old.account['a'] = 'acct.bank';
      old.clockMs = 100;
      old.putT('a', TransactionKind.buy, 10, 50);
      old.clockMs = 105;
      old.syncCash('a');
      final staleE = old.es.values.toList();
      old.clockMs = 200;
      old.account['a'] = null;
      old.putT('a', TransactionKind.buy, 10, 50);
      old.clockMs = 205;
      old.syncCash('a');
      old.clockMs = 300;
      old.putT('a', TransactionKind.buy, 3, 50);
      d.viewT = old.ts.values.toList();
      d.viewE = staleE; // the new trade key, the old cash key
      await d.intake();
      await expectSettled(old, [d]);
      expect(moneyOf(await d.records()), isEmpty);
    });

    test('an unfoldable cash entry kept beside a trade is dropped when it is deleted', () async {
      final cloud = Cloud();
      final d = Device('d', cloud);
      final old = Old();
      old.account['a'] = 'acct.bank';
      old.clockMs = 100;
      old.putT('a', TransactionKind.buy, 10, 50);
      old.clockMs = 105;
      old.syncCash('a');
      // the trade becomes a transfer; the cash entry is stale for a moment
      old.clockMs = 200;
      old.putT('a', TransactionKind.transferIn, 10, 50);
      d.viewT = old.ts.values.toList();
      d.viewE = old.es.values.toList();
      await d.intake();
      expect(moneyOf(await d.records()), {'acct.bank': -50000});
      old.clockMs = 205;
      old.syncCash('a');
      await expectSettled(old, [d]);
      expect(moneyOf(await d.records()), isEmpty);
    });
  });
}
