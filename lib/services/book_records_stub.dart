import '../models/book_entry.dart';
import '../models/syncable.dart';
import 'synced_store.dart';

/// Web has no file system for the database, so the book stays in the JSON
/// files there.
LocalRecords<BookEntry> entryRecords({required String collection, required String filePath}) =>
    JsonFileRecords<BookEntry>(filePath, BookEntry.fromJson);

LocalRecords<T> documentRecords<T extends Syncable>({
  required String collection,
  required String filePath,
  required T Function(Map<String, dynamic>) itemFromJson,
}) =>
    JsonFileRecords<T>(filePath, itemFromJson);
