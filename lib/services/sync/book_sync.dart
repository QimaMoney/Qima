import '../book_store.dart';
import 'book_sync_stub.dart' if (dart.library.io) 'book_sync_io.dart' as platform;
import 'sync_report.dart';
import 'sync_transport.dart';

/// How the money book reaches the person's other devices. This is the one
/// place that chooses; `BookStore` is given the choice when it is built.
///
/// [keyValue] is what the app does and the default: each collection whole in
/// the cloud key-value store, through the `SyncedStore`s. [BookSync.changeLog]
/// adds the change log engine over a transport; the stores keep whatever
/// cloud store they are given, so a caller passes none to leave key-value
/// sync behind, or the real one to run both while devices move over. Both
/// decide between two records by the store's own `merge`, tie rule included,
/// so a device that runs both, and devices that run one each, end with the
/// same book.
///
/// The change log needs the book database, which the web build does not have
/// (its JSON files keep no log of changes): choosing it there throws.
class BookSync {
  final SyncTransport? transport;

  /// Names the remote in what the engine remembers; see `SyncEngine.remote`.
  final String remote;

  const BookSync._(this.transport, this.remote);

  static const BookSync keyValue = BookSync._(null, '');

  const BookSync.changeLog(SyncTransport transport, {String remote = 'main'}) : this._(transport, remote);

  /// The engine for [store]; null for [keyValue].
  BookChangeLog? bind(BookStore store) => transport == null ? null : platform.changeLog(store, transport!, remote);
}
