import '../../models/book_entry.dart';
import '../../models/holding.dart';
import '../../models/holding_transaction.dart';
import '../../models/legacy_collapse.dart';
import '../../models/syncable.dart';
import '../local_file_store.dart';
import '../synced_store.dart';

/// The names the ledger migration moves between, and the parts of it that do
/// not depend on where the book is kept. Plain Dart, so the web build can use
/// it as well as the database one.
abstract final class LedgerNames {
  /// The cloud keys and local collections of the book, in the envelope format.
  static const String accounts = 'ledger.accounts';
  static const String entries = 'ledger.entries';
  static const String recurring = 'ledger.recurring';
  static const String settings = 'ledger.settings';

  /// The keys earlier builds used, in the plain format. Nothing writes them
  /// any more; a reader of old cloud data names them here.
  static const String legacyAccounts = 'book.accounts';
  static const String legacyEntries = 'book.entries';
  static const String legacyRecurring = 'book.recurring';
  static const String legacySettings = 'money.settings';

  /// The cloud keys of the old holdings ledger: trades, and the lots they
  /// replaced.
  static const String legacyTransactions = 'transactions.records';
  static const String legacyLots = 'holdings.records';

  /// The JSON files earlier builds kept those collections in: the key and
  /// `.json`.
  static const String legacyAccountsFile = '$legacyAccounts.json';
  static const String legacyEntriesFile = '$legacyEntries.json';
  static const String legacyRecurringFile = '$legacyRecurring.json';
  static const String legacySettingsFile = '$legacySettings.json';

  /// The JSON files of the web build (no database there).
  static const String accountsFile = 'ledger.accounts.json';
  static const String entriesFile = 'ledger.entries.json';
  static const String recurringFile = 'ledger.recurring.json';
  static const String settingsFile = 'ledger.settings.json';

  /// The holdings ledger the trades are collapsed from. Read only, and never
  /// written by the migration.
  static const String transactionsFile = '$legacyTransactions.json';
  static const String lotsFile = '$legacyLots.json';

  /// Step A (the old collections become the ledger ones) is done.
  static const String flagBook = 'migrated.ledger.book';

  /// Step B (the trades are one entry each) is done.
  static const String flagHoldings = 'migrated.ledger.holdings';

  /// Web markers for the same two steps.
  static const String markerBookFile = 'ledger.migrated.book.json';
  static const String markerHoldingsFile = 'ledger.migrated.holdings.json';

  /// The pairs step A relabels, old collection first.
  static const List<(String, String)> collections = [
    (legacyAccounts, accounts),
    (legacyEntries, entries),
    (legacyRecurring, recurring),
    (legacySettings, settings),
  ];

  static bool isLedger(String collection) => collection.startsWith('ledger.');
}

/// Old holdings trades whose id is the id of an entry that is not a holding.
/// Such a trade is left out of the book (see [LedgerPlan.collapse]); this
/// names them, so the migration and the reader of old cloud data report the
/// same thing.
class LedgerConflict implements Exception {
  /// The ids, sorted.
  final List<String> ids;

  LedgerConflict(Iterable<String> ids) : ids = (ids.toSet().toList()..sort());

  @override
  String toString() => 'LedgerConflict: old holdings trades left out, their id is the id of an entry that is not a holding: ${ids.join(', ')}';
}

/// A source file of the migration is there but cannot be read.
class LedgerSourceUnreadable implements Exception {
  final String file;
  final Object cause;

  const LedgerSourceUnreadable(this.file, this.cause);

  @override
  String toString() => 'LedgerSourceUnreadable: $file cannot be read ($cause)';
}

/// The holdings ledger as the migration reads it.
class LedgerSources {
  final List<Record<HoldingTransaction>> transactions;
  final List<Record<HoldingLot>> lots;

  const LedgerSources(this.transactions, this.lots);

  /// Reads `transactions.records.json` and `holdings.records.json`: a file
  /// that is not there has no records, one that is there and cannot be read
  /// throws [LedgerSourceUnreadable].
  static Future<LedgerSources> read() async => LedgerSources(
        await _records(LedgerNames.transactionsFile, HoldingTransaction.fromJson),
        await _records(LedgerNames.lotsFile, HoldingLot.fromJson),
      );

  static Future<List<Record<T>>> _records<T extends Syncable>(String file, T Function(Map<String, dynamic>) fromJson) async {
    try {
      final json = await LocalFileStore.readJsonStrict(file);
      if (json == null) return const [];
      final raw = json['records'] as List<dynamic>? ?? const [];
      return [for (final e in raw) Record.fromJson<T>(e as Map<String, dynamic>, fromJson)];
    } catch (e) {
      throw LedgerSourceUnreadable(file, e);
    }
  }
}

/// What [LedgerPlan.collapse] made.
class LedgerCollapse {
  /// The records to write.
  final List<Record<BookEntry>> records;

  /// The ids of the old trades that were left out, sorted; empty when none.
  final List<String> leftOut;

  const LedgerCollapse(this.records, this.leftOut);

  /// The clash as an error to report, or null when nothing was left out.
  LedgerConflict? get conflict => leftOut.isEmpty ? null : LedgerConflict(leftOut);
}

/// Step B as a pure function of what is stored and what the holdings files
/// hold. The reader of old cloud data (`LegacyAbsorber`) uses the same
/// function, so every path leaves the same trades out.
abstract final class LedgerPlan {
  /// The ids of the old trades and live lots in [sources] that are the id of
  /// an entry in [entries] that is not a holding. Collapsing such a trade
  /// would replace one person's record with another's.
  static List<String> clashes(Iterable<Record<BookEntry>> entries, LedgerSources sources) {
    final tradeIds = <String>{
      for (final t in sources.transactions) t.item.id,
      for (final l in sources.lots)
        if (!l.deleted) l.item.id,
    };
    return ({
      for (final r in entries)
        if (tradeIds.contains(r.item.id) && !r.item.template.isHoldingEntry) r.item.id,
    }.toList()
      ..sort());
  }

  /// The records [LegacyCollapse.collapse] makes of [stored] (the entries now
  /// in the book) and [sources].
  ///
  /// A trade (or live lot) whose id is the id of an entry that is not a
  /// holding is left out, and every other trade is collapsed as usual: the
  /// money entry stays as it is and the clash is named in
  /// [LedgerCollapse.leftOut]. [alsoInBook] are entries that are in the book
  /// but not in [stored] (when [stored] is what an old device sent); they
  /// count for the clash too. An entry that is a holding under a trade's id
  /// is that trade's own (an earlier collapse, or another device's) and
  /// competes in the collapse like any two records, except that a stored
  /// record made from the same versions of the old halves as the one the
  /// collapse would make is kept as it is: the collapse is not run over its
  /// own output, where the cash it folded in is already a tombstone.
  static LedgerCollapse collapse(
    List<Record<BookEntry>> stored,
    LedgerSources sources, {
    Iterable<Record<BookEntry>> alsoInBook = const [],
  }) {
    final leftOut = clashes([...stored, ...alsoInBook], sources);
    final skip = leftOut.toSet();
    final kept = LedgerSources(
      [for (final t in sources.transactions) if (!skip.contains(t.item.id)) t],
      [for (final l in sources.lots) if (!skip.contains(l.item.id)) l],
    );
    final storedById = {for (final r in stored) r.item.id: r};
    return LedgerCollapse([
      for (final r in LegacyCollapse.collapse(transactions: kept.transactions, lots: kept.lots, entries: stored))
        if (r.item.legacy != null && storedById[r.item.id]?.item.legacy == r.item.legacy) storedById[r.item.id]! else r,
    ], leftOut);
  }
}
