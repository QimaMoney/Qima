import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/asset.dart';
import 'package:qima/models/book_entry.dart';
import 'package:qima/models/holding.dart';
import 'package:qima/models/holding_cash_id.dart';
import 'package:qima/models/holding_entry_codec.dart';
import 'package:qima/models/holding_transaction.dart';
import 'package:qima/models/legacy_collapse.dart';
import 'package:qima/services/synced_store.dart';

final day = DateTime(2026, 3, 12);
final t0 = DateTime.utc(2026, 5, 1, 10);
DateTime at(int s) => t0.add(Duration(seconds: s));

/// [r] as it was before provenance was written on it.
Record<BookEntry> plain(Record<BookEntry> r) => Record(item: BookEntry.fromJson({...r.item.toJson()}..remove('legacy')), order: r.order, updatedAt: r.updatedAt, deleted: r.deleted);

LegacyProvenance prov({int? t, int? c}) => LegacyProvenance(trade: t == null ? null : at(t), cash: c == null ? null : at(c));

String cashId(String id) => holdingCashId(id);

HoldingTransaction trade(String id, TransactionKind kind, {double qty = 10, double px = 50, double fee = 0, String currency = 'USD'}) => HoldingTransaction(
      id: id,
      instrumentID: 'metal.XAU',
      kind: kind,
      quantity: kind == TransactionKind.fee ? 0 : qty,
      unit: PriceUnit.gram,
      unitPrice: kind == TransactionKind.fee ? 0 : px,
      fee: kind == TransactionKind.fee && fee == 0 ? 3 : fee,
      currency: currency,
      date: day,
      note: 'n-$id',
    );

Record<HoldingTransaction> tr(HoldingTransaction t, int stamp, {double order = 1, bool deleted = false}) =>
    Record(item: t, order: order, updatedAt: at(stamp), deleted: deleted);

/// What the cash entry used to look like: the account against Holdings.
Record<BookEntry> cash(String tradeId, int amount, int stamp,
    {String account = 'acct.bank', String currency = 'USD', int? base, bool deleted = false, double order = 5, EntryStatus status = EntryStatus.posted}) {
  final b = base ?? amount;
  return Record(
    item: BookEntry(
      id: cashId(tradeId),
      date: day,
      template: EntryTemplate.holdingTrade,
      baseCurrency: 'USD',
      status: status,
      merchant: 'Gold',
      lines: [
        EntryLine(accountId: account, amount: amount, currency: currency, baseAmount: b),
        EntryLine(accountId: 'system.holdings', amount: -amount, currency: currency, baseAmount: -b),
      ],
    ),
    order: order,
    updatedAt: at(stamp),
    deleted: deleted,
  );
}

Record<BookEntry> other(String id, int stamp, {int amount = 700}) => Record(
      item: BookEntry(id: id, date: day, template: EntryTemplate.spend, baseCurrency: 'USD', lines: [
        EntryLine(accountId: 'acct.bank', amount: -amount, currency: 'USD', baseAmount: -amount),
        EntryLine(accountId: 'category.food', amount: amount, currency: 'USD', baseAmount: amount),
      ]),
      order: 9,
      updatedAt: at(stamp),
    );

Record<HoldingLot> lot(String id, int stamp, {double order = 3, bool deleted = false}) => Record(
      item: HoldingLot(id: id, instrumentID: 'metal.XAU', quantity: 4, unit: PriceUnit.gram, unitCost: 60, costCurrency: 'USD', date: day),
      order: order,
      updatedAt: at(stamp),
      deleted: deleted,
    );

List<Record<BookEntry>> run({List<Record<HoldingTransaction>> ts = const [], List<Record<HoldingLot>> lots = const [], List<Record<BookEntry>> es = const []}) =>
    LegacyCollapse.collapse(transactions: ts, lots: lots, entries: es);

String show(Iterable<Record<BookEntry>> rs) => jsonEncode([for (final r in rs) r.toJson()]);

Record<BookEntry> byId(List<Record<BookEntry>> rs, String id) => rs.singleWhere((r) => r.item.id == id);

/// What each cash account holds, from entries that count.
Map<String, int> money(Iterable<Record<BookEntry>> rs) {
  final out = <String, int>{};
  for (final r in rs) {
    if (r.deleted || !r.item.counts) continue;
    for (final l in r.item.lines) {
      if (l.accountId.startsWith('acct.')) out[l.accountId] = (out[l.accountId] ?? 0) + l.amount;
    }
  }
  return out;
}

List<Record<BookEntry>> readRecords(String s) =>
    [for (final j in jsonDecode(s) as List) Record.fromJson<BookEntry>((j as Map).cast<String, dynamic>(), BookEntry.fromJson)];

void main() {
  group('the table', () {
    test('T live, C live: one entry with the cash leg at the later stamp, and a deletion of C', () {
      final t = trade('a', TransactionKind.buy, fee: 5);
      final out = run(ts: [tr(t, 10, order: 2)], es: [cash('a', -50500, 20)]);
      expect(out, hasLength(2));
      final r = byId(out, 'a');
      expect((r.item.id, r.order, r.deleted, r.updatedAt), ('a', 2.0, false, at(20)));
      expect(r.item.legacy, prov(t: 10, c: 20));
      expect(r.item.issues, isEmpty);
      expect(r.item.merchant, 'Gold');
      expect(r.item.template, EntryTemplate.holdingBuy);
      expect(HoldingEntryCodec.fromEntry(r.item), t);
      final leg = HoldingEntryCodec.cashLegOf(r.item)!;
      expect((leg.accountId, leg.amount), ('acct.bank', -50500));
      final gone = byId(out, cashId('a'));
      expect((gone.deleted, gone.updatedAt, gone.order, gone.item.legacy), (true, at(20), 5.0, prov(t: 10, c: 20)));
      expect(gone.item.issues, isEmpty);
    });

    test('the later stamp is T when T is the later half', () {
      final out = run(ts: [tr(trade('a', TransactionKind.buy), 30)], es: [cash('a', -500, 20)]);
      expect(byId(out, 'a').updatedAt, at(30));
      expect(byId(out, cashId('a')).updatedAt, at(20));
    });

    test('T live, no C: the entry without a cash leg, at T stamp and order', () {
      final out = run(ts: [tr(trade('a', TransactionKind.sell), 10, order: 4)]);
      final r = out.single;
      expect((r.item.id, r.order, r.updatedAt, r.deleted), ('a', 4.0, at(10), false));
      expect(HoldingEntryCodec.cashLegOf(r.item), isNull);
      expect(r.item, HoldingEntryCodec.toEntry(trade('a', TransactionKind.sell)).copyWith(legacy: prov(t: 10)));
    });

    test('T live, C deleted: no cash leg, at the later stamp, and C written as deleted', () {
      final out = run(ts: [tr(trade('a', TransactionKind.buy), 10)], es: [cash('a', -500, 20, deleted: true)]);
      expect(out, hasLength(2));
      final r = byId(out, 'a');
      expect((r.updatedAt, r.deleted), (at(20), false));
      expect(HoldingEntryCodec.cashLegOf(r.item), isNull);
      expect(byId(out, cashId('a')).deleted, isTrue);
      expect(byId(out, cashId('a')).updatedAt, at(20));
      expect(byId(run(ts: [tr(trade('a', TransactionKind.buy), 30)], es: [cash('a', -500, 20, deleted: true)]), 'a').updatedAt, at(30));
    });

    test('T deleted: a well-formed tombstone at the later stamp; a live C is kept as it was', () {
      final t = trade('a', TransactionKind.buy, fee: 5);
      final out = run(ts: [tr(t, 10, order: 2, deleted: true)], es: [cash('a', -500, 20)]);
      expect(out, hasLength(2));
      final tomb = byId(out, 'a');
      expect((tomb.deleted, tomb.updatedAt, tomb.order), (true, at(20), 2.0));
      expect(tomb.item.issues, isEmpty);
      expect(HoldingEntryCodec.fromEntry(tomb.item), t);
      expect(byId(out, cashId('a')).deleted, isFalse);
      expect(show([plain(byId(out, cashId('a')))]), show([cash('a', -500, 20)]));
      expect(byId(out, cashId('a')).item.legacy, prov(t: 10, c: 20));
    });

    test('T deleted, C deleted or absent: a tombstone alone', () {
      final dead = run(ts: [tr(trade('a', TransactionKind.buy), 10, deleted: true)], es: [cash('a', -500, 5, deleted: true)]);
      expect(dead.map((r) => (r.item.id == 'a', r.deleted, r.updatedAt)).toSet(), {(true, true, at(10)), (false, true, at(5))});
      final none = run(ts: [tr(trade('a', TransactionKind.buy), 10, deleted: true)]);
      expect(none.map((r) => (r.item.id, r.deleted, r.updatedAt)), [('a', true, at(10))]);
    });

    test('C live, no T known: kept, with its own version as provenance', () {
      final c = cash('gone', -500, 20);
      final out = run(es: [c]);
      expect(show(out.map(plain)), show([c]));
      expect(out.single.item.legacy, prov(c: 20));
    });

    test('C deleted, no T known: the deletion is kept', () {
      final c = cash('gone', -500, 20, deleted: true);
      final out = run(es: [c]);
      expect((out.single.deleted, out.single.updatedAt, out.single.item.legacy), (true, at(20), prov(c: 20)));
    });

    test('a live lot with no T becomes a buy with the lot record order and stamp', () {
      final l = lot('l1', 7, order: 3.5);
      final r = run(lots: [l]).single;
      expect(r.item.legacy, prov(t: 7));
      expect((r.item.id, r.order, r.updatedAt, r.deleted), ('l1', 3.5, at(7), false));
      expect(HoldingEntryCodec.fromEntry(r.item), HoldingTransaction.fromLot(l.item));
    });

    test('a lot with a cash entry: the lot is the T', () {
      final out = run(lots: [lot('l1', 7)], es: [cash('l1', -240, 9)]);
      expect(out, hasLength(2));
      expect(HoldingEntryCodec.cashLegOf(byId(out, 'l1').item)!.amount, -240);
    });

    test('a deleted lot means nothing; a lot whose id a T has (live or deleted) is ignored', () {
      expect(run(lots: [lot('l1', 7, deleted: true)]), isEmpty);
      final t = trade('l2', TransactionKind.sell);
      final live = run(ts: [tr(t, 1)], lots: [lot('l2', 99)]);
      expect(live.single.item, HoldingEntryCodec.toEntry(t).copyWith(legacy: prov(t: 1)));
      expect(live.single.updatedAt, at(1));
      final dead = run(ts: [tr(t, 1, deleted: true)], lots: [lot('l2', 99)]);
      expect((dead.single.deleted, dead.single.updatedAt), (true, at(1)));
      expect(live.single.item.legacy, prov(t: 1));
    });

    test('any other entry is unchanged', () {
      final o = other('o1', 3);
      expect(show(run(es: [o])), show([o]));
    });
  });

  group('cash that cannot be folded in is kept', () {
    test('a transfer, the other direction, a pending entry and an entry of nothing keep their money', () {
      final cases = {
        'transfer': (trade('a', TransactionKind.transferIn), cash('a', -500, 20)),
        'a buy paid with money in': (trade('a', TransactionKind.buy), cash('a', 500, 20)),
        'a pending cash entry': (trade('a', TransactionKind.buy), cash('a', -500, 20, status: EntryStatus.pending)),
        'a cash entry of nothing': (trade('a', TransactionKind.buy), cash('a', 0, 20)),
      };
      for (final e in cases.entries) {
        final (t, c) = e.value;
        final out = run(ts: [tr(t, 10)], es: [c]);
        expect(out, hasLength(2), reason: e.key);
        expect(HoldingEntryCodec.cashLegOf(byId(out, 'a').item), isNull, reason: e.key);
        expect(show([plain(byId(out, cashId('a')))]), show([c]), reason: e.key);
        expect(byId(out, cashId('a')).deleted, isFalse, reason: e.key);
        expect(money(out), money([c]), reason: e.key);
      }
    });
  });

  group('cash in other currencies', () {
    test('a sell into a card in the base currency keeps its base amounts and balances', () {
      final t = trade('a', TransactionKind.sell, currency: 'SAR', qty: 4, px: 80);
      final c = cash('a', 8500, 20, account: 'acct.card');
      final out = run(ts: [tr(t, 10)], es: [c]);
      expect(byId(out, 'a').item.issues, isEmpty);
      expect(byId(out, 'a').item.baseCurrency, 'USD');
      expect(HoldingEntryCodec.fromEntry(byId(out, 'a').item), t);
      expect(money(out), money([c]));
    });

    test('a cash entry that would not balance with the trade is kept apart', () {
      // A cost of nothing in another currency has no entry that balances.
      final t = trade('a', TransactionKind.buy, px: 0, currency: 'SAR');
      final c = cash('a', -500, 20);
      final out = run(ts: [tr(t, 10)], es: [c]);
      expect(out, hasLength(2));
      expect(money(out), money([c]));
    });
  });

  group('invariants', () {
    final kinds = TransactionKind.values;

    ({List<Record<HoldingTransaction>> ts, List<Record<HoldingLot>> lots, List<Record<BookEntry>> es}) randomSet(Random rnd) {
      final ts = <Record<HoldingTransaction>>[];
      final lots = <Record<HoldingLot>>[];
      final es = <Record<BookEntry>>[];
      final n = 1 + rnd.nextInt(8);
      for (var i = 0; i < n; i++) {
        final id = 'id$i';
        final kind = kinds[rnd.nextInt(kinds.length)];
        final t = trade(id, kind, qty: 1 + rnd.nextInt(20).toDouble(), px: 10 + rnd.nextInt(90).toDouble(), fee: rnd.nextInt(3).toDouble());
        if (rnd.nextInt(5) == 4) {
          lots.add(lot(id, rnd.nextInt(30), deleted: rnd.nextInt(4) == 0, order: rnd.nextInt(50).toDouble()));
          if (rnd.nextBool()) ts.add(tr(t, rnd.nextInt(30), deleted: rnd.nextBool()));
        } else {
          ts.add(tr(t, rnd.nextInt(30), order: rnd.nextInt(50).toDouble(), deleted: rnd.nextInt(3) == 0));
          if (rnd.nextInt(5) == 0) ts.add(tr(t.copyWith(note: 'dup'), rnd.nextInt(30), deleted: rnd.nextBool()));
        }
        final cashRoll = rnd.nextInt(6);
        if (cashRoll > 0) {
          final amount = (rnd.nextBool() ? -1 : 1) * (100 + rnd.nextInt(5000));
          es.add(cash(id, amount, rnd.nextInt(30),
              account: rnd.nextBool() ? 'acct.bank' : 'acct.card', deleted: cashRoll == 1, status: cashRoll == 2 ? EntryStatus.pending : EntryStatus.posted));
        }
        if (rnd.nextInt(4) == 0) es.add(other('o$i', rnd.nextInt(30)));
      }
      return (ts: ts, lots: lots, es: es);
    }

    test('any order of the same records gives the same records', () {
      final rnd = Random(20260521);
      for (var i = 0; i < 400; i++) {
        final s = randomSet(rnd);
        final first = show(run(ts: s.ts, lots: s.lots, es: s.es));
        for (var k = 0; k < 4; k++) {
          final again = show(run(ts: [...s.ts]..shuffle(rnd), lots: [...s.lots]..shuffle(rnd), es: [...s.es]..shuffle(rnd)));
          expect(again, first, reason: 'set $i');
        }
      }
    });

    test('collapsing its own output changes nothing', () {
      final rnd = Random(77);
      for (var i = 0; i < 400; i++) {
        final s = randomSet(rnd);
        final once = run(ts: s.ts, lots: s.lots, es: s.es);
        expect(show(run(es: once)), show(once), reason: 'set $i');
      }
    });

    test('each cash account holds the same money before and after, and every live holding entry balances', () {
      final rnd = Random(5150);
      for (var i = 0; i < 400; i++) {
        final s = randomSet(rnd);
        final out = run(ts: s.ts, lots: s.lots, es: s.es);
        // Only the cash entries and other entries count before (a trade has no
        // account line); the same set after must hold the same money.
        expect(money(out), money(s.es), reason: 'set $i');
        for (final r in out) {
          if (!r.deleted && HoldingEntryCodec.isHoldingEntry(r.item)) expect(r.item.issues, isEmpty, reason: 'set $i ${r.item.id}');
        }
      }
    });

    test('a pair never counts cash twice', () {
      final rnd = Random(9);
      for (var i = 0; i < 400; i++) {
        final s = randomSet(rnd);
        final out = run(ts: s.ts, lots: s.lots, es: s.es);
        for (final r in out) {
          if (r.deleted || !HoldingEntryCodec.isHoldingEntry(r.item) || HoldingEntryCodec.cashLegOf(r.item) == null) continue;
          final twin = out.where((e) => e.item.id == cashId(r.item.id)).firstOrNull;
          expect(twin == null || twin.deleted, isTrue, reason: 'set $i');
        }
      }
    });
  });

  group('prefer', () {
    final t = trade('a', TransactionKind.buy, fee: 5);
    Record<BookEntry> made(int tStamp, int cStamp, {bool withCash = true}) =>
        byId(run(ts: [tr(t, tStamp)], es: withCash ? [cash('a', -50500, cStamp)] : []), 'a');

    test('the record made from the later versions wins, whichever side is incoming', () {
      final stale = made(100, 205);
      final truth = made(200, 205);
      expect(stale.updatedAt, truth.updatedAt);
      expect(LegacyCollapse.prefer(truth, stale), isTrue);
      expect(LegacyCollapse.prefer(stale, truth), isFalse);
      // an absent half is earlier than a present one
      final noCash = made(200, 0, withCash: false);
      final withCash = Record<BookEntry>(item: truth.item.copyWith(legacy: prov(t: 200, c: 150)), order: truth.order, updatedAt: noCash.updatedAt);
      expect(LegacyCollapse.prefer(withCash, noCash), isTrue);
      expect(LegacyCollapse.prefer(noCash, withCash), isFalse);
    });

    test('a record never beats itself, and of two different records exactly one wins', () {
      final rnd = Random(3);
      final pool = <Record<BookEntry>>[];
      for (var i = 0; i < 60; i++) {
        final tStamp = [null, 5, 6][rnd.nextInt(3)], cStamp = [null, 5, 6][rnd.nextInt(3)];
        if (tStamp == null && cStamp == null) continue;
        final base = other('x', 10 + rnd.nextInt(2));
        pool.add(Record(
          item: base.item.copyWith(legacy: prov(t: tStamp, c: cStamp), note: 'n${rnd.nextInt(3)}'),
          order: 1,
          updatedAt: at(10),
          deleted: rnd.nextBool(),
        ));
        if (rnd.nextInt(4) == 0) pool.add(base.copyWith(updatedAt: at(10), deleted: rnd.nextBool()));
      }
      for (final a in pool) {
        expect(LegacyCollapse.prefer(a, a), isFalse);
        for (final b in pool) {
          if (show([a]) == show([b])) continue;
          expect(LegacyCollapse.prefer(a, b) != LegacyCollapse.prefer(b, a), isTrue);
        }
      }
      // transitive: sorting any shuffle by the rule gives the same winner
      final winners = {
        for (var k = 0; k < 20; k++) show([([...pool]..shuffle(rnd)).reduce((a, b) => LegacyCollapse.prefer(b, a) ? b : a)]),
      };
      expect(winners, hasLength(1));
    });

    test('a deletion beats a live record when nothing else tells them apart', () {
      final live = made(100, 105);
      final dead = Record<BookEntry>(item: live.item, order: live.order, updatedAt: live.updatedAt, deleted: true);
      expect(LegacyCollapse.prefer(dead, live), isTrue);
      expect(LegacyCollapse.prefer(live, dead), isFalse);
    });
  });

  group('provenance on an entry', () {
    test('a money entry writes no legacy key, and one with provenance writes it and reads it back', () {
      expect(other('o', 1).item.toJson().containsKey('legacy'), isFalse);
      final e = other('o', 1).item.copyWith(legacy: LegacyProvenance(trade: at(3).add(const Duration(microseconds: 7)), cash: null));
      final json = jsonDecode(jsonEncode(e.toJson())) as Map<String, dynamic>;
      expect(json['legacy'], {'t': '2026-05-01T10:00:03.000007Z'});
      final back = BookEntry.fromJson(json);
      expect(back, e);
      expect(back.legacy!.trade!.isUtc, isTrue);
    });

    test('a legacy value this build cannot read is left out, not thrown on', () {
      final json = other('o', 1).item.toJson();
      for (final bad in [5, 'x', <String, dynamic>{}, {'t': 4}, {'c': 'not a time'}]) {
        expect(BookEntry.fromJson({...json, 'legacy': bad}).legacy, isNull, reason: '$bad');
      }
    });
  });
}
