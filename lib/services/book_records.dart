import '../models/book_entry.dart';
import '../models/syncable.dart';
import 'book_records_stub.dart' if (dart.library.io) 'book_records_io.dart' as platform;
import 'synced_store.dart';

/// Where the money book keeps its local copy: the database where there is a
/// file system, the JSON files on web. The choice is a conditional import so
/// nothing that needs `dart:ffi` is reachable from the web build.
///
/// [collection] names the rows in the database and [file] is the JSON file on
/// web. [legacyFile] is the file an earlier build kept the collection in,
/// which the database imports from. [prefer] is the tie rule of the store
/// that writes through the records, which the database rows are held to.
LocalRecords<BookEntry> bookEntryRecords({
  required String collection,
  required String file,
  required String legacyFile,
  bool Function(Record<BookEntry> incoming, Record<BookEntry> stored)? prefer,
}) =>
    platform.entryRecords(collection: collection, file: file, legacyFile: legacyFile, prefer: prefer);

/// The steps of the ledger migration that did not finish this run, by name,
/// with the error. Empty when all did, and always on web. Read it after the
/// book has loaded (the migration runs on its first read).
Future<Map<String, Object>> bookLedgerProblems() => platform.ledgerProblems();

LocalRecords<T> bookDocumentRecords<T extends Syncable>({
  required String collection,
  required String file,
  required String legacyFile,
  required T Function(Map<String, dynamic>) itemFromJson,
  bool Function(Record<T> incoming, Record<T> stored)? prefer,
}) =>
    platform.documentRecords<T>(collection: collection, file: file, legacyFile: legacyFile, itemFromJson: itemFromJson, prefer: prefer);
