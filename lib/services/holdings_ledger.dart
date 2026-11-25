import '../models/book_entry.dart';
import '../models/holding_entry_codec.dart';
import '../models/holding_transaction.dart';
import 'book_store.dart';
import 'synced_store.dart';

/// A trade that would not make a sound entry. Nothing was written.
class HoldingRejected implements Exception {
  final List<EntryIssue> issues;

  const HoldingRejected(this.issues);

  /// What to tell the person, one problem per line.
  String get message => issues.map((i) => i.detail).join('\n');

  @override
  String toString() => 'HoldingRejected: ${issues.join('; ')}';
}

/// The holdings ledger: the trades in the book, read and written as
/// [HoldingTransaction]s.
///
/// A trade is one entry (see [HoldingEntryCodec]) in the same store as the
/// rest of the book, [BookStore.entries], so a trade and the cash it moved
/// are saved, synced and deleted as one record. This class only ever reads or
/// writes records that are holding entries: whatever else is in the store
/// (spending, transfers, a `holding_trade` entry left by an earlier build) is
/// never changed, deleted or reordered through it, whatever ids are passed.
///
/// The cash side is given with each save: the account the trade was paid from
/// or into, or none. Nothing of it is carried over from an earlier version of
/// the same trade. Of the entry itself, an edit keeps what the editor does
/// not hold (see [upsert]).
class HoldingsLedger {
  /// The book the trades are kept in.
  final BookStore book;

  HoldingsLedger(this.book);

  /// The trades, in the order the book keeps them. An entry that cannot be
  /// read as a trade (a record from elsewhere that lost the facts of its
  /// line) is left out, and left as it is.
  Future<List<HoldingTransaction>> load() async => _trades(await book.entries.load());

  /// Saves [transaction] as one entry, with [cash] as its other side when it
  /// moved cash ([merchant] is the instrument's label, shown in Money).
  /// [baseCurrency] is the base currency of the entry when there is a cash
  /// leg. Throws [HoldingRejected], writing nothing, when the entry would
  /// not be sound, and [StateError] when another kind of entry already has
  /// the trade's id.
  ///
  /// Saving a trade that is already in the book is an edit by the person on
  /// this device. It keeps the stored entry's `source` (where the trade came
  /// from) and `postedDate`, which the editor does not show; the status
  /// follows this save (posted), and the `legacy` provenance of a trade that
  /// was collapsed from the old two-record form is dropped, as the entry is
  /// now this device's own version.
  Future<List<HoldingTransaction>> upsert(
    HoldingTransaction transaction, {
    CashLeg? cash,
    String? baseCurrency,
    String merchant = '',
  }) async {
    var entry = _checked(HoldingEntryCodec.toEntry(transaction, cash: cash, baseCurrency: baseCurrency, merchant: merchant));
    final taken = (await book.entries.exportRecords()).where((r) => r.item.id == entry.id).firstOrNull;
    if (taken != null && !taken.item.template.isHoldingEntry) {
      throw StateError('Entry ${entry.id} is not a holding, so a trade cannot replace it.');
    }
    if (taken != null && !taken.deleted) {
      entry = entry.copyWith(source: taken.item.source, postedDate: taken.item.postedDate);
    }
    return _trades(await book.entries.upsert(entry));
  }

  /// Adds [transactions] (new ids, no cash) in one commit, after the end of
  /// the book: a CSV import. An id the store has seen before, live or
  /// deleted, is left as it is. Throws [HoldingRejected], writing nothing,
  /// when any of them would not be sound.
  Future<List<HoldingTransaction>> addAll(List<HoldingTransaction> transactions) async {
    final entries = [for (final t in transactions) _checked(HoldingEntryCodec.toEntry(t))];
    if (entries.isNotEmpty) {
      final now = DateTime.now();
      final existing = await book.entries.exportRecords();
      var order = existing.isEmpty ? 0.0 : existing.map((r) => r.order).reduce((a, b) => a > b ? a : b) + 1;
      await book.entries.insertMissing([for (final e in entries) Record<BookEntry>(item: e, order: order++, updatedAt: now)]);
    }
    return load();
  }

  /// Deletes the trades among [ids] in one commit: undoing an import. An id
  /// that is not a trade is ignored.
  Future<List<HoldingTransaction>> deleteAll(Iterable<String> ids) async {
    final wanted = ids.toSet();
    final trades = {
      for (final r in await book.entries.exportRecords())
        if (!r.deleted && r.item.template.isHoldingEntry) r.item.id,
    };
    return _trades(await book.entries.deleteAll(wanted.intersection(trades)));
  }

  Future<List<HoldingTransaction>> delete(String id) => deleteAll([id]);

  BookEntry _checked(BookEntry entry) {
    final issues = entry.issues;
    if (issues.isNotEmpty) throw HoldingRejected(issues);
    return entry;
  }

  static List<HoldingTransaction> _trades(List<BookEntry> entries) => [
        for (final e in entries)
          if (e.template.isHoldingEntry) ?HoldingEntryCodec.tryFromEntry(e),
      ];
}
