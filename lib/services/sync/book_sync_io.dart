import '../../models/book_account.dart';
import '../../models/book_entry.dart';
import '../../models/money_settings.dart';
import '../book_db/db_records.dart';
import '../book_db/ledger_plan.dart';
import '../book_store.dart';
import 'sync_engine.dart';
import 'sync_report.dart';
import 'sync_transport.dart';

/// The engine over the four collections of [store]. Each is merged by its
/// store's own rule and read and written through rows of the engine's own.
BookChangeLog changeLog(BookStore store, SyncTransport transport, String remote) => SyncEngine(
      remote: remote,
      transport: transport,
      collections: [
        SyncCollection<BookAccount>.of(
          store.accounts,
          DocumentRecords<BookAccount>(collection: BookStore.accountsKey, filePath: LedgerNames.legacyAccountsFile, itemFromJson: BookAccount.fromJson, prefer: store.accounts.prefer),
        ),
        SyncCollection<BookEntry>.of(store.entries, EntryRecords(collection: BookStore.entriesKey, filePath: LedgerNames.legacyEntriesFile, prefer: store.entries.prefer)),
        SyncCollection<RecurringPayment>.of(
          store.recurring,
          DocumentRecords<RecurringPayment>(collection: BookStore.recurringKey, filePath: LedgerNames.legacyRecurringFile, itemFromJson: RecurringPayment.fromJson, prefer: store.recurring.prefer),
        ),
        SyncCollection<MoneySettings>.of(
          store.settings,
          DocumentRecords<MoneySettings>(collection: BookStore.settingsKey, filePath: LedgerNames.legacySettingsFile, itemFromJson: MoneySettings.fromJson, prefer: store.settings.prefer),
        ),
      ],
    );
