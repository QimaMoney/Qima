import '../book_store.dart';
import 'sync_report.dart';
import 'sync_transport.dart';

/// Web keeps the book in JSON files, which have no change log to sync from.
BookChangeLog changeLog(BookStore store, SyncTransport transport, String remote) =>
    throw UnsupportedError('The change log sync needs the book database, which is not available on web.');
