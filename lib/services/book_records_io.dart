import '../models/book_entry.dart';
import '../models/syncable.dart';
import 'book_db/book_database.dart';
import 'book_db/db_records.dart';
import 'synced_store.dart';

Future<Map<String, Object>> ledgerProblems() async => Map.of((await BookDatabase.open()).ledgerProblems);

LocalRecords<BookEntry> entryRecords({
  required String collection,
  required String file,
  required String legacyFile,
  bool Function(Record<BookEntry> incoming, Record<BookEntry> stored)? prefer,
}) =>
    EntryRecords(collection: collection, filePath: legacyFile, prefer: prefer);

LocalRecords<T> documentRecords<T extends Syncable>({
  required String collection,
  required String file,
  required String legacyFile,
  required T Function(Map<String, dynamic>) itemFromJson,
  bool Function(Record<T> incoming, Record<T> stored)? prefer,
}) =>
    DocumentRecords<T>(collection: collection, filePath: legacyFile, itemFromJson: itemFromJson, prefer: prefer);
