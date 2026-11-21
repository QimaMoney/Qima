import '../models/book_entry.dart';
import '../models/syncable.dart';
import 'book_records_stub.dart' if (dart.library.io) 'book_records_io.dart' as platform;
import 'synced_store.dart';

/// Where the money book keeps its local copy: the database where there is a
/// file system, the JSON files on web. The choice is a conditional import so
/// nothing that needs `dart:ffi` is reachable from the web build.
LocalRecords<BookEntry> bookEntryRecords({required String collection, required String filePath}) =>
    platform.entryRecords(collection: collection, filePath: filePath);

LocalRecords<T> bookDocumentRecords<T extends Syncable>({
  required String collection,
  required String filePath,
  required T Function(Map<String, dynamic>) itemFromJson,
}) =>
    platform.documentRecords<T>(collection: collection, filePath: filePath, itemFromJson: itemFromJson);
