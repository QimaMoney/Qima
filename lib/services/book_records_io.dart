import '../models/book_entry.dart';
import '../models/syncable.dart';
import 'book_db/db_records.dart';
import 'synced_store.dart';

LocalRecords<BookEntry> entryRecords({required String collection, required String filePath}) =>
    EntryRecords(collection: collection, filePath: filePath);

LocalRecords<T> documentRecords<T extends Syncable>({
  required String collection,
  required String filePath,
  required T Function(Map<String, dynamic>) itemFromJson,
}) =>
    DocumentRecords<T>(collection: collection, filePath: filePath, itemFromJson: itemFromJson);
