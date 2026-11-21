import 'dart:convert';

import '../services/synced_store.dart';
import 'book_entry.dart';
import 'holding_cash_id.dart' as ids;
import 'holding.dart';
import 'holding_entry_codec.dart';
import 'holding_transaction.dart';
import 'syncable.dart';

/// Turns the old two-record form of a holdings trade into one entry.
///
/// A trade used to be a [HoldingTransaction] and, when the person picked a
/// cash account, a second entry (template `holding_trade`, id
/// `holdingCashId`) between that account and `system.holdings`. From now on
/// it is one entry with the trade's id and the cash account on the other
/// side. Everything here is a pure function of the records it is given: no
/// clock, no randomness, no input order. Devices that collapse the same old
/// data, whenever and wherever, write the same records, so the local
/// migration, the reader of old cloud keys and the restore of an old backup
/// agree.
///
/// The old data keeps changing while devices still run the old app, and a
/// device may read the two old keys at different moments. So an entry made
/// from the two halves has two versions, not one, and one `updatedAt` cannot
/// order them. Each record made here has the stamp `max` of its halves'
/// stamps, and says which versions it was made from in
/// [BookEntry.legacy]. A store takes a record with a later stamp; for an
/// equal stamp it asks [prefer], which chooses the record made from the later
/// versions. Records made from the same versions are the same record.
///
/// What is written, by what is known of an id (T is the trade record, C the
/// cash entry with id `holdingCashId(T.id)`, `u` an `updatedAt`; the
/// provenance of every record below is the stamps of T and C as far as they
/// exist, deleted or not):
///
/// | T | C | entry with T's id (order T.order) | record with C's id |
/// |---|---|---|---|
/// | live | live, sound | with the cash leg of C, stamp max(T.u, C.u) | tombstone, stamp C.u |
/// | live | live, not sound | without cash leg, stamp max(T.u, C.u) | C live, stamp C.u |
/// | live | deleted | without cash leg, stamp max(T.u, C.u) | tombstone, stamp C.u |
/// | live | none | without cash leg, stamp T.u | none |
/// | deleted | live | tombstone, stamp max(T.u, C.u) | C live, stamp C.u |
/// | deleted | deleted | tombstone, stamp max(T.u, C.u) | tombstone, stamp C.u |
/// | deleted | none | tombstone, stamp T.u | none |
/// | none | live | none | C live, stamp C.u |
/// | none | deleted | none | tombstone, stamp C.u |
///
/// C is sound when it is a posted `holding_trade` of two lines whose account
/// line moves money the way T's kind does (out for a buy or fee, in for a
/// sell) and which makes an entry that balances. A C that is not (a transfer
/// row, the other direction, pending or declined, a pair that would not
/// balance) stays its own entry beside T's: the money stays where it was.
///
/// A deletion of C is always written, so a device that took C live earlier
/// drops it when it sees T and C together or C deleted. A live lot that no
/// trade record has the id of is a trade (`HoldingTransaction.fromLot`) with
/// the lot record's order and stamp; a deleted lot, and a lot whose id a
/// trade record has (live or deleted), mean nothing, as in the migration of
/// lots the holdings ledger used to make on every load. Every other entry is
/// as it is.
abstract final class LegacyCollapse {
  /// Same as the top-level [ids.holdingCashId], which is the one to use; kept
  /// for the callers that still name it here.
  static String holdingCashId(String transactionId) => ids.holdingCashId(transactionId);

  /// The collapsed records, sorted by id.
  static List<Record<BookEntry>> collapse({
    required Iterable<Record<HoldingTransaction>> transactions,
    required Iterable<Record<HoldingLot>> lots,
    required Iterable<Record<BookEntry>> entries,
  }) {
    final trades = _newest<HoldingTransaction>(transactions, (r) => r.item.id, _compare);
    final lotById = _newest<HoldingLot>(lots, (r) => r.item.id, _compare);
    for (final l in lotById.values) {
      if (l.deleted || trades.containsKey(l.item.id)) continue;
      trades[l.item.id] = Record<HoldingTransaction>(item: HoldingTransaction.fromLot(l.item), order: l.order, updatedAt: l.updatedAt);
    }
    final byId = _newest<BookEntry>(entries, (r) => r.item.id, _order);

    final out = <String, Record<BookEntry>>{};
    final cashIds = <String>{};
    for (final t in trades.values) {
      final cashId = ids.holdingCashId(t.item.id);
      cashIds.add(cashId);
      final c = byId[cashId];
      final provenance = LegacyProvenance(trade: t.updatedAt, cash: c?.updatedAt);
      final stamp = c == null ? t.updatedAt : _later(t.updatedAt, c.updatedAt);

      final merged = !t.deleted && c != null && !c.deleted ? _withCash(t.item, c.item) : null;
      final Record<BookEntry> made = Record<BookEntry>(
        item: (merged ?? HoldingEntryCodec.toEntry(t.item)).copyWith(legacy: provenance),
        order: t.order,
        updatedAt: stamp,
        deleted: t.deleted,
      );
      // An entry already under T's id (data seen from both forms) competes
      // like any two records.
      final already = byId[t.item.id];
      out[t.item.id] = already == null || _order(made, already) > 0 ? made : already;

      if (c != null) {
        // A deleted C, and a C folded into T, are written as deletions: a
        // device that took C live earlier drops it. A live C that stays is
        // its own entry.
        final stays = !c.deleted && merged == null;
        out[cashId] = Record<BookEntry>(
          item: c.item.copyWith(legacy: provenance),
          order: c.order,
          updatedAt: c.updatedAt,
          deleted: !stays,
        );
      }
    }
    for (final e in byId.values) {
      if (out.containsKey(e.item.id)) continue;
      // A cash entry whose trade is not known: its own version only.
      final alone = e.item.template == EntryTemplate.holdingTrade && e.item.legacy == null && !cashIds.contains(e.item.id);
      out[e.item.id] = alone ? e.copyWith(item: e.item.copyWith(legacy: LegacyProvenance(cash: e.updatedAt))) : e;
    }
    return out.values.toList()..sort((a, b) => a.item.id.compareTo(b.item.id));
  }

  /// For a store to call when [incoming] and [stored] have the same `updatedAt`:
  /// whether [incoming] is the one to keep.
  ///
  /// The record made from the later versions of the old halves wins (a half
  /// that is present is later than one that is absent). The answer never
  /// depends on which of the two is [incoming]: of two different records
  /// exactly one wins, so every device keeps the same one, and a record never
  /// beats itself. Versions that cannot be ordered, and records with no
  /// provenance, are told apart by a fixed order: the trade's version, then
  /// the cash's, a record with no provenance last, then a deletion over a
  /// live record, then the text of the record.
  static bool prefer(Record<BookEntry> incoming, Record<BookEntry> stored) => _order(incoming, stored) > 0;

  /// Newest stamp first, then [_provenanceOrder], then a deletion over a live
  /// record, then the text of the record: a total order.
  static int _order(Record<BookEntry> a, Record<BookEntry> b) {
    var c = a.updatedAt.compareTo(b.updatedAt);
    if (c != 0) return c;
    c = _provenanceOrder(a.item.legacy, b.item.legacy);
    if (c != 0) return c;
    c = (a.deleted ? 1 : 0) - (b.deleted ? 1 : 0);
    if (c != 0) return c;
    return jsonEncode(a.toJson()).compareTo(jsonEncode(b.toJson()));
  }

  /// A total order that agrees with "each half at least as late, and one
  /// later": the trade's stamp first, then the cash's; absent before present;
  /// no provenance before any.
  static int _provenanceOrder(LegacyProvenance? a, LegacyProvenance? b) {
    if (a == null || b == null) return (a == null ? 0 : 1) - (b == null ? 0 : 1);
    final c = _stampOrder(a.trade, b.trade);
    return c != 0 ? c : _stampOrder(a.cash, b.cash);
  }

  static int _stampOrder(DateTime? a, DateTime? b) {
    if (a == null || b == null) return (a == null ? 0 : 1) - (b == null ? 0 : 1);
    return a.compareTo(b);
  }

  /// [t] with the cash side taken from [c], or null when that cannot be done
  /// without changing what the money did.
  static BookEntry? _withCash(HoldingTransaction t, BookEntry c) {
    if (c.template != EntryTemplate.holdingTrade || c.status != EntryStatus.posted || c.lines.length != 2) return null;
    final leg = HoldingEntryCodec.cashLegOf(c);
    if (leg == null || leg.amount == 0) return null;
    final direction = switch (t.kind) {
      TransactionKind.buy || TransactionKind.fee => -1,
      TransactionKind.sell => 1,
      TransactionKind.transferIn || TransactionKind.transferOut => 0,
    };
    if (direction == 0 || leg.amount.sign != direction) return null;
    final merged = HoldingEntryCodec.toEntry(
      t,
      cash: CashLeg(accountId: leg.accountId, currency: leg.currency, amount: leg.amount.abs(), baseAmount: leg.baseAmount.abs()),
      baseCurrency: c.baseCurrency,
      merchant: c.merchant,
    );
    return merged.issues.isEmpty ? merged : null;
  }

  static Map<String, Record<T>> _newest<T extends Syncable>(Iterable<Record<T>> records, String Function(Record<T>) idOf, int Function(Record<T>, Record<T>) order) {
    final out = <String, Record<T>>{};
    for (final r in records) {
      final id = idOf(r);
      final held = out[id];
      if (held == null || order(r, held) > 0) out[id] = r;
    }
    return out;
  }

  /// Newest stamp first, then a deletion over a live record, then order, then
  /// the text of the record: a total order, so duplicates settle the same way
  /// whichever comes first.
  static int _compare(Record<Syncable> a, Record<Syncable> b) {
    var c = a.updatedAt.compareTo(b.updatedAt);
    if (c != 0) return c;
    c = (a.deleted ? 1 : 0) - (b.deleted ? 1 : 0);
    if (c != 0) return c;
    c = a.order.compareTo(b.order);
    if (c != 0) return c;
    return jsonEncode(a.item.toJson()).compareTo(jsonEncode(b.item.toJson()));
  }

  static DateTime _later(DateTime a, DateTime b) => a.isAfter(b) ? a : b;
}
