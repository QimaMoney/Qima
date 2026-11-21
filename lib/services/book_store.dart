import '../models/book_account.dart';
import '../models/book_entry.dart';
import '../models/default_categories.dart';
import '../models/money_settings.dart';
import '../models/syncable.dart';
import 'book_records.dart';
import 'cloud_kv_store.dart';
import 'synced_store.dart';

/// The money ledger on disk: accounts, entries, recurring payments and
/// Money's settings, each a [SyncedStore] synced like every other collection.
///
/// Locally the four collections live in one SQLite file (`book.sqlite`), and
/// on web in the JSON files; the cloud copy and the merge are the same either way.
///
/// Holdings are not here. They stay in the holdings ledger
/// (`TransactionsStore`) and join the balance sheet at live prices.
class BookStore {
  static const String accountsKey = 'book.accounts';
  static const String entriesKey = 'book.entries';
  static const String recurringKey = 'book.recurring';
  static const String settingsKey = 'money.settings';

  static const String _entriesFile = 'book.entries.json';

  static const List<String> cloudKeys = [accountsKey, entriesKey, recurringKey, settingsKey];

  final SyncedStore<BookAccount> accounts;
  final SyncedStore<BookEntry> entries;
  final SyncedStore<RecurringPayment> recurring;
  final SyncedStore<MoneySettings> settings;

  BookStore({CloudKVStore? cloud})
      : accounts = _store(accountsKey, 'book.accounts.json', BookAccount.fromJson, cloud),
        entries = SyncedStore<BookEntry>(
          filePath: _entriesFile,
          cloudKey: entriesKey,
          itemFromJson: BookEntry.fromJson,
          cloud: cloud ?? LocalOnlyCloudKVStore(),
          seed: () => const [],
          local: bookEntryRecords(collection: entriesKey, filePath: _entriesFile),
        ),
        recurring = _store(recurringKey, 'book.recurring.json', RecurringPayment.fromJson, cloud),
        settings = _store(settingsKey, 'money.settings.json', MoneySettings.fromJson, cloud);

  /// A collection kept as documents. The file name is the JSON file earlier
  /// versions used, and is what the database imports from.
  static SyncedStore<T> _store<T extends Syncable>(String key, String file, T Function(Map<String, dynamic>) fromJson, CloudKVStore? cloud) {
    return SyncedStore<T>(
      filePath: file,
      cloudKey: key,
      itemFromJson: fromJson,
      cloud: cloud ?? LocalOnlyCloudKVStore(),
      seed: () => const [],
      local: bookDocumentRecords<T>(collection: key, filePath: file, itemFromJson: fromJson),
    );
  }

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
