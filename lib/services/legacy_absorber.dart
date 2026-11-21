import 'dart:async';
import 'dart:convert';

import '../models/book_account.dart';
import '../models/book_entry.dart';
import '../models/holding.dart';
import '../models/holding_transaction.dart';
import '../models/legacy_collapse.dart';
import '../models/money_settings.dart';
import '../models/syncable.dart';
import 'book_db/ledger_plan.dart';
import 'book_store.dart';
import 'cloud_kv_store.dart';
import 'synced_store.dart';

/// Takes what devices still on an earlier build keep writing to the old cloud
/// keys into the book's own stores. One way: the old keys are only read.
///
/// An earlier build writes plain record lists to `book.accounts`,
/// `book.entries`, `book.recurring`, `money.settings`, `transactions.records`
/// (trades) and `holdings.records` (lots). This build never writes them. The
/// copy on this device was moved once by the local migration; what an old
/// device changes after that arrives here.
///
/// What is taken, each time an old value has changed:
///
/// * Accounts and recurring payments as they are: same ids, order, stamps and
///   tombstones. A record is taken when its id was never seen here or its
///   stamp is strictly later than the stored one (see [SyncedStore.absorb]),
///   so an old build rewriting a whole collection with unchanged stamps
///   changes nothing.
/// * Settings only while the ledger holds no settings record at all, not even
///   a deleted one. After that the ledger's copy is the one the person edits.
/// * Entries, trades and lots together, always: [LegacyCollapse.collapse]
///   makes one entry of each trade and the cash it moved, the same function
///   the local migration and the restore of an old backup use, so every path
///   writes the same records. Reading them apart would collapse a trade
///   without its cash, or cash without its trade.
///
/// The order of the absorbs is accounts, recurring payments, settings, then
/// entries. They are not one atomic step: each is a commit of its own store,
/// and none needs the others to be correct. What the order buys is that
/// nobody who reads between two of them (a reload of the book, the money
/// screens) sees an entry that posts to an account which is not there yet:
/// the worst a reader sees is an account with nothing in it. A run that stops
/// halfway (an error, the app closing) is not marked as done, so the next run
/// does the rest, and every absorb is a no-op for what was already taken.
///
/// An entry from an old device that posts to an account this device deleted
/// is taken as it is. The deleted account keeps its tombstone (unless the old
/// device edited the account later than the deletion), so the entry posts to
/// an account that is not there, which the book reports as an unknown
/// account.
///
/// The other way round, an old device may remove an account as unused that
/// an updated device has since posted to. Such a tombstone is not taken while
/// any live entry of the book posts to that account.
///
/// An old trade whose id is the id of an entry that is not a holding is left
/// out, as the local migration leaves it out ([LedgerPlan.collapse]): the
/// entry stays as it is, everything else is taken, and [lastProblem] names
/// the ids.
class LegacyAbsorber {
  /// Every old key this reads (named in [LedgerNames]).
  static const List<String> keys = [
    LedgerNames.legacyAccounts,
    LedgerNames.legacyRecurring,
    LedgerNames.legacySettings,
    LedgerNames.legacyEntries,
    LedgerNames.legacyTransactions,
    LedgerNames.legacyLots,
  ];

  final SyncedStore<BookAccount> accounts;
  final SyncedStore<BookEntry> entries;
  final SyncedStore<RecurringPayment> recurring;
  final SyncedStore<MoneySettings> settings;

  /// Where the old keys are read. Never written.
  final CloudKVStore cloud;

  /// Whether the cloud is on. Nothing is read or taken while it is off.
  final bool Function()? enabled;

  LegacyAbsorber({
    required this.accounts,
    required this.entries,
    required this.recurring,
    required this.settings,
    required this.cloud,
    this.enabled,
  });

  /// The absorber of [book]'s four stores.
  LegacyAbsorber.forBook(BookStore book, CloudKVStore cloud, {bool Function()? enabled})
      : this(accounts: book.accounts, entries: book.entries, recurring: book.recurring, settings: book.settings, cloud: cloud, enabled: enabled);

  Future<void> _tail = Future<void>.value();
  Map<String, String?>? _seen;
  int _generation = 0;
  Object? _lastProblem;

  /// What the last run could not use, or null. A key whose value could not
  /// be read (not a plain list, or a record this build cannot read) and old
  /// trades left out for clashing with an entry are reported here; the run
  /// still finishes, and takes the rest.
  Object? get lastProblem => _lastProblem;

  /// Forgets what was read last, so the next [absorb] reads everything again.
  /// For the cloud being switched on or off, or another account signing in.
  void reset() {
    _generation++;
    _seen = null;
  }

  /// Takes what changed in the old keys since the last run, and returns the
  /// ledger keys ([BookStore.cloudKeys]) whose records changed, empty when
  /// nothing did. Runs one after another when called again before it
  /// finishes; the second then finds nothing changed and returns at once.
  ///
  /// Throws what a store or the cloud throws. The run is then not marked as
  /// done, so the next call tries again.
  Future<Set<String>> absorb() {
    final run = _tail.then((_) => _run());
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  Future<Set<String>> _run() async {
    if (enabled != null && !enabled!()) {
      _seen = null;
      return {};
    }
    final generation = _generation;
    final raw = <String, String?>{};
    for (final key in keys) {
      raw[key] = await cloud.getString(key);
    }
    final seen = _seen;
    if (seen != null && keys.every((k) => seen[k] == raw[k])) return {};

    final problems = <String>[];
    final changed = <String>{};
    final book = await entries.exportRecords();

    final oldAccounts = _decode<BookAccount>(raw[LedgerNames.legacyAccounts], LedgerNames.legacyAccounts, BookAccount.fromJson, problems);
    if (oldAccounts != null && oldAccounts.isNotEmpty) {
      final used = {
        for (final r in book)
          if (!r.deleted)
            for (final line in r.item.lines) line.accountId,
      };
      final taken = [
        for (final r in oldAccounts)
          if (!(r.deleted && used.contains(r.item.id))) r,
      ];
      if (taken.isNotEmpty && await accounts.absorb(taken)) changed.add(BookStore.accountsKey);
    }

    final oldRecurring = _decode<RecurringPayment>(raw[LedgerNames.legacyRecurring], LedgerNames.legacyRecurring, RecurringPayment.fromJson, problems);
    if (oldRecurring != null && oldRecurring.isNotEmpty && await recurring.absorb(oldRecurring)) changed.add(BookStore.recurringKey);

    final oldSettings = _decode<MoneySettings>(raw[LedgerNames.legacySettings], LedgerNames.legacySettings, MoneySettings.fromJson, problems);
    if (oldSettings != null && oldSettings.isNotEmpty && (await settings.exportRecords()).isEmpty && await settings.absorb(oldSettings)) {
      changed.add(BookStore.settingsKey);
    }

    final oldEntries = _decode<BookEntry>(raw[LedgerNames.legacyEntries], LedgerNames.legacyEntries, BookEntry.fromJson, problems);
    final oldTrades = _decode<HoldingTransaction>(raw[LedgerNames.legacyTransactions], LedgerNames.legacyTransactions, HoldingTransaction.fromJson, problems);
    final oldLots = _decode<HoldingLot>(raw[LedgerNames.legacyLots], LedgerNames.legacyLots, HoldingLot.fromJson, problems);
    // The three are collapsed together or not at all: with one of them
    // missing, a trade would be written without its cash (or the cash without
    // its trade) and be corrected only when the value becomes readable.
    if (oldEntries != null && oldTrades != null && oldLots != null) {
      final plan = LedgerPlan.collapse(oldEntries, LedgerSources(oldTrades, oldLots), alsoInBook: book);
      final conflict = plan.conflict;
      if (conflict != null) problems.add('old trades left out, their id is the id of an entry that is not a holding: ${conflict.ids.join(', ')}');
      if (plan.records.isNotEmpty && await entries.absorb(plan.records)) changed.add(BookStore.entriesKey);
    }

    _lastProblem = problems.isEmpty ? null : 'Old cloud values this build cannot use: ${problems.join('; ')}';
    if (generation == _generation) _seen = raw;
    return changed;
  }

  /// The records of [raw]: none when it is absent or empty, null when it is
  /// there but is not a plain list of records this build can read (an
  /// envelope, another shape, a record that fails to decode), which is noted
  /// in [problems].
  static List<Record<T>>? _decode<T extends Syncable>(String? raw, String key, T Function(Map<String, dynamic>) fromJson, List<String> problems) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List<dynamic>) {
        problems.add(key);
        return null;
      }
      return [for (final e in decoded) Record.fromJson<T>(e as Map<String, dynamic>, fromJson)];
    } catch (_) {
      problems.add(key);
      return null;
    }
  }
}
