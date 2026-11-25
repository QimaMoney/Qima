import '../models/book_account.dart';
import '../models/book_entry.dart';
import '../models/default_categories.dart';
import '../models/money_settings.dart';
import '../models/legacy_collapse.dart';
import '../models/syncable.dart';
import 'book_db/ledger_plan.dart';
import 'book_records.dart';
import 'cloud_kv_store.dart';
import 'sync/book_sync.dart';
import 'sync/sync_report.dart';
import 'synced_store.dart';

/// The money ledger on disk: accounts, entries, recurring payments and
/// Money's settings, each a [SyncedStore] synced like every other collection.
///
/// The four live under the cloud keys `ledger.*`, in the envelope format, and
/// keep their tombstones for ever. Those keys are only ever opened by these
/// stores. The keys earlier builds used (`book.accounts`, `book.entries`,
/// `book.recurring`, `money.settings`, plain lists) are not read or written by
/// this build; their names are in [LedgerNames], for the reader of old cloud data.
///
/// Locally the four collections live in one SQLite file (`book.sqlite`), and
/// on web in JSON files; the cloud copy and the merge are the same either way.
/// The first use of any of them moves what an earlier build kept to the ledger
/// names (see `LedgerMigration`).
///
/// A holdings trade is an entry here too (see `HoldingsLedger`); its
/// holding account is not counted in the balance sheet, and holdings join
/// net worth at live prices.
class BookStore {
  static const String accountsKey = LedgerNames.accounts;
  static const String entriesKey = LedgerNames.entries;
  static const String recurringKey = LedgerNames.recurring;
  static const String settingsKey = LedgerNames.settings;

  static const List<String> cloudKeys = [accountsKey, entriesKey, recurringKey, settingsKey];

  final SyncedStore<BookAccount> accounts;
  final SyncedStore<BookEntry> entries;
  final SyncedStore<RecurringPayment> recurring;
  final SyncedStore<MoneySettings> settings;

  /// How the book is synced. Key-value storage, as always, unless whoever
  /// builds the store chooses otherwise.
  final BookSync sync;

  /// The change log sync of this book, for the caller that runs it; null
  /// with key-value sync.
  late final BookChangeLog? changeLog = sync.bind(this);

  BookStore({CloudKVStore? cloud, this.sync = BookSync.keyValue})
      : accounts = _store(accountsKey, LedgerNames.accountsFile, LedgerNames.legacyAccountsFile, BookAccount.fromJson, cloud),
        entries = SyncedStore<BookEntry>(
          filePath: LedgerNames.entriesFile,
          cloudKey: entriesKey,
          itemFromJson: BookEntry.fromJson,
          cloud: cloud ?? LocalOnlyCloudKVStore(),
          seed: () => const [],
          local: bookEntryRecords(collection: entriesKey, file: LedgerNames.entriesFile, legacyFile: LedgerNames.legacyEntriesFile, prefer: LegacyCollapse.prefer),
          cloudFormat: CloudFormat.envelope,
          prefer: LegacyCollapse.prefer,
          tombstoneTTL: null,
        ),
        recurring = _store(recurringKey, LedgerNames.recurringFile, LedgerNames.legacyRecurringFile, RecurringPayment.fromJson, cloud),
        settings = _store(settingsKey, LedgerNames.settingsFile, LedgerNames.legacySettingsFile, MoneySettings.fromJson, cloud);

  /// Told after every change made through the four stores, see
  /// [SyncedStore.onSaved].
  set onSaved(void Function()? listener) {
    accounts.onSaved = listener;
    entries.onSaved = listener;
    recurring.onSaved = listener;
    settings.onSaved = listener;
  }

  /// A collection kept as documents. [legacyFile] is the JSON file earlier
  /// versions used, and is what the database imports from.
  ///
  /// Two different records with one id and one stamp are settled by
  /// [LegacyCollapse.settles], the same way on every device and whichever
  /// way they reach it (the cloud key, the change log, an old key): a rule
  /// that depended on the order of arrival would have two devices, or two
  /// ways of syncing on one device, keep exchanging the two for ever. The
  /// default categories are such records: every device adds them with one
  /// fixed stamp, and builds need not agree on what they hold.
  static SyncedStore<T> _store<T extends Syncable>(String key, String file, String legacyFile, T Function(Map<String, dynamic>) fromJson, CloudKVStore? cloud) {
    return SyncedStore<T>(
      filePath: file,
      cloudKey: key,
      itemFromJson: fromJson,
      cloud: cloud ?? LocalOnlyCloudKVStore(),
      seed: () => const [],
      local: bookDocumentRecords<T>(collection: key, file: file, legacyFile: legacyFile, itemFromJson: fromJson, prefer: LegacyCollapse.settles),
      cloudFormat: CloudFormat.envelope,
      prefer: LegacyCollapse.settles,
      tombstoneTTL: null,
    );
  }

  /// A step of the ledger migration that did not finish this run, and why;
  /// empty when none failed. A trade is in the book only once the step that
  /// folds the holdings ledger into it is done, so a screen that finds
  /// holdings empty where the person had some can say that it will be tried
  /// again on the next start. Call it after the book has loaded.
  Future<Map<String, Object>> ledgerProblems() => bookLedgerProblems();

  /// Adds the default categories that aren't there yet. Fixed ids and
  /// an old timestamp make it safe on every device: a category the person
  /// renamed or archived always wins over the seed.
  Future<List<BookAccount>> loadAccounts() async {
    await accounts.insertMissing([
      for (final (i, a) in DefaultCategories.all.indexed)
        Record<BookAccount>(item: a, order: -1000.0 + i, updatedAt: DateTime.utc(2000)),
    ]);
    return accounts.load();
  }

  Future<MoneySettings> loadSettings() async {
    final list = await settings.load();
    return list.isEmpty ? const MoneySettings() : list.first;
  }
}
