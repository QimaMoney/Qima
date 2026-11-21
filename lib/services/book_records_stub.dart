import '../models/book_entry.dart';
import '../models/syncable.dart';
import 'book_db/ledger_json_migration.dart';
import 'synced_store.dart';

/// Web has no database, and its migration fails loudly on the first read, so
/// there is nothing to report here.
Future<Map<String, Object>> ledgerProblems() async => const {};

/// Web has no file system for the database, so the book stays in the JSON
/// files there, in the ledger files once `LedgerJsonMigration` has made them.
LocalRecords<BookEntry> entryRecords({required String collection, required String file, required String legacyFile}) =>
    LedgerJsonRecords<BookEntry>(file, BookEntry.fromJson);

LocalRecords<T> documentRecords<T extends Syncable>({
  required String collection,
  required String file,
  required String legacyFile,
  required T Function(Map<String, dynamic>) itemFromJson,
}) =>
    LedgerJsonRecords<T>(file, itemFromJson);
