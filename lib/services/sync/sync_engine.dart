import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' show sha256;

import 'package:drift/drift.dart' show Variable;

import '../../models/syncable.dart';
import '../book_db/book_database.dart';
import '../book_db/db_records.dart';
import '../synced_store.dart';
import 'sync_report.dart';
import 'sync_transport.dart';
import 'sync_wire.dart';

/// Records of one collection read from a remote, ready to be applied.
abstract class SyncIncoming {
  String get collection;
}

class _Incoming<T extends Syncable> implements SyncIncoming {
  @override
  final String collection;
  final List<Record<T>> records;

  const _Incoming(this.collection, this.records);
}

/// One collection of the book as the engine sees it: its rows, and the rule
/// that says which of two records with one id is kept.
class SyncCollection<T extends Syncable> {
  final DbRecords<T> rows;

  /// `SyncedStore.merge` of the collection's own store: the rule key-value
  /// sync uses, and the only one. The later `updatedAt` wins, a deletion is a
  /// record like any other, and the store's `prefer` decides between equal
  /// stamps.
  final List<Record<T>> Function(List<Record<T>> stored, List<Record<T>> incoming) merge;

  /// The collection [store] keeps, merged by the store's own rule.
  ///
  /// [rows] must be a store of its own, not the one [store] writes through:
  /// that one remembers what it last read, and the engine must not disturb
  /// it. It must be held to the same tie rule as [store]. And [store] must
  /// have a tie rule: without one a merge gives an equal stamp to whichever
  /// record comes second, and two devices would each take the other's record
  /// and never agree.
  SyncCollection.of(SyncedStore<T> store, this.rows) : merge = store.merge {
    if (store.prefer == null) throw ArgumentError('The store of ${rows.collection} has no tie rule (prefer), so its merge depends on the order records arrive in.');
    if (!identical(rows.prefer, store.prefer)) throw ArgumentError('The rows of ${rows.collection} are not held to the tie rule of its store.');
  }

  String get name => rows.collection;

  Future<void> prepare(BookDatabase db) => rows.prepareIn(db);

  /// The stored records as they travel, all of them or those with an id in
  /// [only]. An id with no row (it was purged here) has nothing to send, as a
  /// purge has nothing to say in a merge either.
  Future<List<Map<String, dynamic>>> state(BookDatabase db, {Set<String>? only}) async => [for (final record in await rows.storedIn(db, ids: only)) record.toJson()];

  /// Throws [FormatException] when even one record cannot be read: nothing of
  /// a body is taken unless all of it can be.
  SyncIncoming read(List<Map<String, dynamic>> records) {
    try {
      return _Incoming<T>(name, [for (final json in records) Record.fromJson<T>(json, rows.itemFromJson)]);
    } catch (e) {
      throw FormatException('a record of $name that cannot be read: $e');
    }
  }

  /// Merges [parts] into the stored rows, inside the transaction the caller
  /// holds, and returns how many rows changed. Only the rows the records name
  /// are read. A row is written only when an incoming record wins the merge,
  /// and it is logged as taken from [remote], so it is not sent back there.
  Future<int> apply(BookDatabase db, Iterable<SyncIncoming> parts, String remote) async {
    final incoming = [for (final part in parts) ...(part as _Incoming<T>).records];
    if (incoming.isEmpty) return 0;
    final held = {for (final record in await rows.storedIn(db, ids: {for (final record in incoming) record.item.id})) record.item.id: record};
    final take = [
      for (final winner in merge(held.values.toList(), incoming))
        if (!identical(winner, held[winner.item.id])) winner,
    ];
    await rows.writeIn(db, take, origin: (op: SyncEngine.opTaken, body: jsonEncode({'from': remote})));
    return take.length;
  }
}

/// Where this device stands in its own log, for one remote.
class _Out {
  /// The last row of `changes` that has been looked at for this remote.
  final int scanned;

  /// The `last` and `prev` of the newest batch this device stored there.
  final int shipped;
  final int prev;

  /// Per run of the engine on this database ([SyncEngine.writer]), the
  /// furthest `last` it has set out to store. Written before the batch is
  /// handed to the transport, so a batch under this device's id is this
  /// database's own exactly when its writer is here and it ends no further
  /// than this says. A copy of the database knows the writers of before it
  /// was copied, up to where they had come then, and nothing of what the
  /// original wrote since.
  final Map<String, int> writers;

  /// Every snapshot this database has set out to store there and not
  /// removed since, oldest first, whether the write went through or not.
  final List<SyncSnapshotRef> attempted;

  /// The newest snapshot it stored whole, with what it covers and the
  /// digest of the records it holds. Written down only once the transport
  /// has every part.
  final SyncSnapshotRef? stored;
  final Map<String, int> covers;
  final String digest;

  const _Out({
    required this.scanned,
    required this.shipped,
    required this.prev,
    this.writers = const {},
    this.attempted = const [],
    this.stored,
    this.covers = const {},
    this.digest = '',
  });

  _Out copy({int? scanned, int? shipped, int? prev, Map<String, int>? writers, List<SyncSnapshotRef>? attempted}) => _Out(
        scanned: scanned ?? this.scanned,
        shipped: shipped ?? this.shipped,
        prev: prev ?? this.prev,
        writers: writers ?? this.writers,
        attempted: attempted ?? this.attempted,
        stored: stored,
        covers: covers,
        digest: digest,
      );

  _Out storing(SyncSnapshotRef snapshot, Map<String, int> covers, String digest) =>
      _Out(scanned: scanned, shipped: shipped, prev: prev, writers: writers, attempted: attempted, stored: snapshot, covers: covers, digest: digest);

  /// Whether [ref], a batch under this device's id, is one this database
  /// set out to store.
  bool wrote(SyncBatchRef ref) => ref.last <= (writers[ref.writer] ?? 0);

  String get text => jsonEncode({
        'scanned': scanned,
        'shipped': shipped,
        'prev': prev,
        'writers': writers,
        'attempted': [for (final ref in attempted) ref.name],
        'stored': stored?.name,
        'covers': covers,
        'digest': digest,
      });

  static _Out parse(String text) {
    final json = jsonDecode(text) as Map<String, dynamic>;
    final stored = json['stored'] as String?;
    return _Out(
      scanned: json['scanned'] as int,
      shipped: json['shipped'] as int,
      prev: json['prev'] as int,
      writers: (json['writers'] as Map<String, dynamic>).cast<String, int>(),
      attempted: [for (final name in json['attempted'] as List<dynamic>) SyncSnapshotRef.parse(name as String)!],
      stored: stored == null ? null : SyncSnapshotRef.parse(stored),
      covers: (json['covers'] as Map<String, dynamic>).cast<String, int>(),
      digest: json['digest'] as String,
    );
  }
}

/// Where this device stands in the logs of the others, for one remote.
class _In {
  /// Per device, the batch that brought this device furthest: everything of
  /// that device up to `last` has been taken in.
  final Map<String, ({int prev, int last})> batches;

  /// Per device, the batches that have been applied and end after the `prev`
  /// of its place, by name ([SyncBatchRef.batch]). A listing is asked for
  /// from that `prev`, so these are the names it gives again; any other
  /// batch it gives has not been applied, whatever its numbers, and is.
  final Map<String, List<String>> recent;

  /// The snapshots that have been taken in whole, by name.
  final Set<String> taken;

  _In(this.batches, this.recent, this.taken);

  Map<String, int> get lasts => {for (final e in batches.entries) e.key: e.value.last};

  /// What a listing is asked for from, per device.
  Map<String, int> get floors => {for (final e in batches.entries) e.key: e.value.prev};

  /// Whether this stands further on than [before]: a place moved, a snapshot
  /// was taken in, or one more batch was applied at the same places. Each of
  /// those can only happen so often, which is what ends a pull.
  bool beyond(_In before) {
    int reached(_In state) => state.batches.values.fold(0, (sum, at) => sum + at.last);
    int applied(_In state) => state.recent.values.fold(0, (sum, names) => sum + names.length);
    if (reached(this) != reached(before)) return reached(this) > reached(before);
    return taken.length > before.taken.length || applied(this) > applied(before);
  }

  String get text => jsonEncode({
        'batches': {for (final e in batches.entries) e.key: [e.value.prev, e.value.last]},
        'recent': recent,
        'taken': taken.toList(),
      });

  static _In parse(String? text) {
    if (text == null) return _In({}, {}, {});
    final json = jsonDecode(text) as Map<String, dynamic>;
    return _In(
      (json['batches'] as Map<String, dynamic>).map((device, at) => MapEntry(device, (prev: (at as List<dynamic>)[0] as int, last: at[1] as int))),
      (json['recent'] as Map<String, dynamic>).map((device, names) => MapEntry(device, (names as List<dynamic>).cast<String>().toList())),
      (json['taken'] as List<dynamic>).cast<String>().toSet(),
    );
  }
}

/// What a compaction is about to store, and where things stood when it was
/// read.
class _Plan {
  /// The snapshot that is to stand: a new one, or the one stored last. Null
  /// when nothing is to be written and none of this device's stands.
  final SyncSnapshotRef? ref;
  final Map<String, int> covers;
  final String digest;

  /// The parts to store; null when [ref] is there already.
  final List<List<SyncOp>>? parts;
  final _In state;
  final _Out out;

  const _Plan(this.ref, this.covers, this.digest, this.parts, this.state, this.out);
}

/// Syncs the book from its change log: sends the records that changed here
/// since the last round and takes in the ones that changed elsewhere, through
/// a [SyncTransport]. Nothing in it depends on what the transport is.
///
/// What travels is the whole record of every id the log names, as it is now,
/// not the logged operation: a record already carries its `updatedAt`, order
/// and deleted flag, and the merge that key-value sync has always used
/// ([SyncCollection.merge]) keeps the same one of any two whatever order they
/// arrive in. So a batch can be delivered twice, late, or before an earlier
/// one, and can be built again after a stop, and the book ends the same. A
/// log row with no id (an import of an old file, a migration) stands for its
/// whole collection, so the op names the stores write need no reading at all;
/// the only ops read are the ones the engine writes itself.
///
/// That every device ends with the same book rests on one property of the
/// stores, not on anything sent: a device never keeps a record that loses the
/// merge to the one it held (`SyncedStore.stampAfter` for what the person
/// changes, `DbRecords` for every row written). The record that wins
/// everywhere was therefore logged where it was made and is in that device's
/// log, or in a snapshot written by a device that had taken it in, and a
/// device that has it never lets go of it.
///
/// Everything the engine remembers is in `meta`:
/// - `sync.device`: this device's id, made once.
/// - `sync.out.<remote>`: how far `changes` has been sent there. Moved only
///   once the transport has the batch, so a stop sends a stretch twice and
///   never skips one.
/// - `sync.in.<remote>`: per other device, how far its log has been taken in.
///   Moved in a transaction of its own after the records of the batch are in,
///   so a stop applies a batch twice and never skips one.
///
/// Every drift transaction on this database starts with `BEGIN IMMEDIATE`,
/// that is, holding the write lock. Each one here reads where things stand
/// inside it and only ever moves a position forward, so two isolates (the app
/// and the background refresh) can run the engine on one file at once.
///
/// A copy of the file on a second device (a backup of the whole device
/// restored to a new phone while the old one is still in use) has the same
/// `sync.device`, and the two would write one log between them. A database
/// that finds a batch under its own id that it did not write takes a new id
/// and sends its whole book again under it, see [_rekey]. The app's own
/// backup holds records only, never `meta`, so the id does not travel in one.
class SyncEngine implements BookChangeLog {
  static const String deviceKey = 'sync.device';

  /// `changes.op` of a row taken in from a remote; the body names it.
  static const String opTaken = 'sync';

  /// `changes.op` of the row written when a remote is first used, or used
  /// again under a new id: everything in the book goes to that remote once.
  static const String opAttach = 'attach';

  /// `changes.op` of the row that gives a snapshot a number of its own.
  static const String opSnapshot = 'snapshot';

  /// `changes.op` of a row that only moves the log on by one, so that a
  /// batch whose name is taken by other text goes out under another.
  static const String opAgain = 'again';

  /// How often one call stores a batch or snapshot again under a new name
  /// before it gives up and reports the transport.
  static const int _tries = 3;

  /// Names the remote in `meta` and in the log; lower case letters and digits.
  final String remote;
  final SyncTransport transport;
  final List<SyncCollection> collections;

  /// About how much JSON goes into one body, see [SyncWire.partBytes].
  final int partBytes;

  /// The name of this run of the engine in what it stores, see
  /// [SyncBatchRef.writer]: made anew for every engine, so that no two runs,
  /// on this database or on a copy of it, share one.
  final String writer;
  final Future<BookDatabase> Function() _database;

  /// Snapshots a later build wrote, by name, so one is not fetched again on
  /// every round of this run but is reported for as long as it is there. A
  /// name is stored once and never rewritten, and a body has to be whole for
  /// its version to be read at all, so this cannot go stale. Anything that is
  /// merely unreadable is read again every time: it may still be arriving.
  final Map<String, SyncProblem> _newer = {};

  SyncEngine({
    required this.remote,
    required this.transport,
    required this.collections,
    this.partBytes = SyncWire.partBytes,
    String? writer,
    Future<BookDatabase> Function()? database,
  })  : writer = writer ?? _random(4),
        _database = database ?? BookDatabase.open {
    if (!isDeviceId(remote)) throw ArgumentError.value(remote, 'remote', 'lower case letters and digits only');
    if (!isDeviceId(this.writer)) throw ArgumentError.value(writer, 'writer', 'lower case letters and digits only');
  }

  String get _outKey => 'sync.out.$remote';
  String get _inKey => 'sync.in.$remote';

  static Future<String?> _meta(BookDatabase db, String key) async {
    final rows = await db.customSelect('SELECT value FROM meta WHERE key = ?', variables: [Variable<String>(key)]).get();
    return rows.isEmpty ? null : rows.single.data['value'] as String;
  }

  static Future<void> _setMeta(BookDatabase db, String key, String value) => db.customStatement('INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)', [key, value]);

  Future<_Out> _out(BookDatabase db) async => _Out.parse((await _meta(db, _outKey))!);

  Future<_In> _in(BookDatabase db) async => _In.parse(await _meta(db, _inKey));

  Future<String> _device(BookDatabase db) async => (await _meta(db, deviceKey))!;

  /// The highest number `changes` has given out, which stays when rows are
  /// trimmed.
  static Future<int> _high(BookDatabase db) async {
    final rows = await db.customSelect("SELECT seq FROM sqlite_sequence WHERE name = 'changes'").get();
    return rows.isEmpty ? 0 : rows.single.data['seq'] as int;
  }

  static Future<void> _mark(BookDatabase db, String op, String remote) => db.customStatement(
        "INSERT INTO changes (at, collection, id, op, body) VALUES (?, '', '', ?, ?)",
        [DateTime.now().toUtc().toIso8601String(), op, jsonEncode({'remote': remote})],
      );

  /// This device's id. Made the first time the engine runs on the file, so a
  /// new file (a reinstall) is a new device.
  Future<String> deviceId() async => _device(await _ready());

  /// The database, migrated and known to this remote.
  Future<BookDatabase> _ready() async {
    final db = await _database();
    for (final collection in collections) {
      await collection.prepare(db);
    }
    if (await _meta(db, _outKey) == null) await db.transaction(() => _attach(db));
    return db;
  }

  /// First use of this remote on this file. The log may have been trimmed for
  /// other remotes and says nothing of rows an import brought, so the remote
  /// is not caught up from the log: one row says "everything", and sending
  /// starts at that row.
  Future<void> _attach(BookDatabase db) async {
    if (await _meta(db, deviceKey) == null) await _setMeta(db, deviceKey, _random(16));
    if (await _meta(db, _outKey) != null) return;
    await _mark(db, opAttach, remote);
    await _setMeta(db, _outKey, _Out(scanned: await _high(db) - 1, shipped: 0, prev: 0).text);
  }

  /// Whether the row [_attach] wrote has not been sent past yet.
  Future<bool> _attachPending(BookDatabase db) async {
    final rows = await db.customSelect(
      "SELECT body FROM changes WHERE seq > ? AND collection = '' AND op = ?",
      variables: [Variable<int>((await _out(db)).scanned), Variable<String>(opAttach)],
    ).get();
    return rows.any((row) => _names(row.data['body'], 'remote'));
  }

  /// [bytes] random bytes as lower case hex.
  static String _random(int bytes) {
    final random = Random.secure();
    return [for (var i = 0; i < bytes; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  }

  /// Gives this database a new device id, when it still has the id [was].
  ///
  /// Called when a batch or a snapshot under that id on the remote was
  /// written by another database: this file is a copy, or was restored from one. Two writers of
  /// one log cannot be told apart by a reader, which takes each batch as
  /// continuing the one before, so both leave it as soon as each sees the
  /// other. Under the new id the whole book is sent again (the same row that
  /// a first use writes), and nothing that was taken in is trusted to still
  /// be complete: the snapshots are read again, and the log of the old id is
  /// read from the start like any other device's, which is how this database
  /// comes by what the other one wrote under it.
  Future<bool> _rekey(BookDatabase db, String was) async {
    if (await _device(db) != was) return false;
    await _setMeta(db, deviceKey, _random(16));
    final state = await _in(db);
    await _setMeta(db, _inKey, _In(state.batches, state.recent, {}).text);
    await _mark(db, opAttach, remote);
    await _setMeta(db, _outKey, _Out(scanned: await _high(db) - 1, shipped: 0, prev: 0).text);
    return true;
  }

  /// [_rekey], if [batch] or [snapshot] really is one this database did not
  /// write. It is judged inside the transaction, because another isolate on
  /// this file may have set out to store it a moment ago.
  Future<bool> _rekeyIfForeign(BookDatabase db, {SyncBatchRef? batch, SyncSnapshotRef? snapshot}) async {
    final device = await _device(db);
    final out = await _out(db);
    if (batch != null && batch.device == device && !out.wrote(batch)) return _rekey(db, device);
    if (snapshot != null && snapshot.device == device && !out.attempted.any((own) => own.snapshot == snapshot.snapshot)) return _rekey(db, device);
    return false;
  }

  @override
  Future<SyncRound> sync() async {
    final db = await _ready();
    final first = await _pushFirst(db);
    final pulled = await _pull(db);
    return SyncRound(pulled, SyncPush(sent: first.sent + (await push()).sent));
  }

  /// Everything this device held before it knew the remote goes out before
  /// anything is taken in, so that first batch is all its own.
  Future<SyncPush> _pushFirst(BookDatabase db) async => await _attachPending(db) ? push() : const SyncPush();

  /// Sends the records that changed here since the last push, as one batch
  /// in as many parts as its size needs.
  ///
  /// The position moves only after the transport has every part. A stop in
  /// between sends the same stretch again: by this engine under the same
  /// names, by a later run under names of its own, with at least the same
  /// records either way, and a reader applies every batch it is given.
  ///
  /// A name of this engine's that holds other text than it is given was
  /// damaged where it is kept, or stored in another form of the same text.
  /// It is left as it is, and the log is moved on by one row so that the
  /// same records go out as a batch that ends one later.
  Future<SyncPush> push() async {
    final db = await _ready();
    for (var tries = 0; ; tries++) {
      final draft = await db.transaction(() => _draft(db));
      if (draft == null) return const SyncPush();
      final (ref, parts, sent) = draft;
      SyncBatchRef? taken;
      for (var i = 0; i < parts.length && taken == null; i++) {
        final part = ref.partAt(i + 1);
        if (!await transport.append(part, SyncBatch(part, parts[i]).body)) taken = part;
      }
      if (taken != null) {
        if (tries == _tries) throw StateError('The sync transport holds other contents under every name tried for a batch, last $taken.');
        await db.transaction(() => _mark(db, opAgain, remote));
        continue;
      }
      await db.transaction(() async {
        // The id may have changed while the parts were stored: the batch then
        // belongs to the old log, and the new one starts from nothing.
        if (await _device(db) != ref.device) return;
        // Another isolate may have sent further meanwhile: positions only grow.
        final out = await _out(db);
        final newest = parts.isNotEmpty && ref.last > out.shipped;
        final prev = newest ? ref.prev : out.prev;
        await _setMeta(
          db,
          _outKey,
          out.copy(
            scanned: max(out.scanned, ref.last),
            shipped: newest ? ref.last : null,
            prev: prev,
            // A listing is asked for from `prev` on, so a writer that never
            // set out to store beyond it is never asked about again.
            writers: {
              for (final e in out.writers.entries)
                if (e.value > prev || e.key == writer) e.key: e.value,
            },
          ).text,
        );
      });
      return SyncPush(sent: sent);
    }
  }

  /// The batch for the log rows not looked at yet, as its first ref, its parts
  /// and how many records they hold; null when there are no rows. Rows this
  /// remote need not hear of make a batch of no parts: nothing is stored, and
  /// the rows are still marked as looked at.
  ///
  /// Before anything is handed to the transport, how far this batch reaches
  /// is written down under this engine's name, see [_Out.writers].
  Future<(SyncBatchRef, List<List<SyncOp>>, int)?> _draft(BookDatabase db) async {
    final out = await _out(db);
    final rows = await db.customSelect('SELECT seq, collection, id, op, body FROM changes WHERE seq > ? ORDER BY seq', variables: [Variable<int>(out.scanned)]).get();
    if (rows.isEmpty) return null;
    final whole = <String>{};
    final ids = <String, Set<String>>{};
    for (final row in rows) {
      final collection = row.data['collection'] as String;
      final id = row.data['id'] as String;
      final op = row.data['op'] as String;
      if (collection.isEmpty) {
        if (op == opAttach && _names(row.data['body'], 'remote')) whole.addAll([for (final c in collections) c.name]);
      } else if (op == opTaken && _names(row.data['body'], 'from')) {
        // Taken from this remote.
      } else if (id.isEmpty) {
        whole.add(collection);
      } else {
        ids.putIfAbsent(collection, () => {}).add(id);
      }
    }
    final ops = <SyncOp>[];
    for (final collection in collections) {
      final only = whole.contains(collection.name) ? null : ids[collection.name];
      if (only == null && !whole.contains(collection.name)) continue;
      for (final record in await collection.state(db, only: only)) {
        ops.add(SyncOp(collection.name, record));
      }
    }
    final last = rows.last.data['seq'] as int;
    final parts = ops.isEmpty ? const <List<SyncOp>>[] : SyncWire.split(ops, partBytes: partBytes);
    if (parts.isNotEmpty && last > (out.writers[writer] ?? 0)) await _setMeta(db, _outKey, out.copy(writers: {...out.writers, writer: last}).text);
    return (SyncBatchRef(device: await _device(db), writer: writer, prev: out.shipped, last: last, parts: max(1, parts.length)), parts, ops.length);
  }

  /// Whether the JSON [body] of a log row has this remote under [key].
  bool _names(Object? body, String key) => body is String && (jsonDecode(body) as Map<String, dynamic>)[key] == remote;

  /// Takes in what the other devices have sent.
  ///
  /// A batch is used when all its parts are there and it starts at or before
  /// the place this device has reached in its writer's log. Its parts are
  /// read and applied one at a time, and then the place moves to its end, if
  /// that is further on. Every such batch is applied, also one that ends
  /// where the place already is or before: that is another batch for changes
  /// this device has (the same stretch stored again after a stop), or one of
  /// another database under the same id, and applying is a merge either way.
  ///
  /// A batch that starts beyond the place waits: one before it has not
  /// arrived, or has been removed after a snapshot took its place, so the
  /// snapshots this device has not taken in are read, each moving the places
  /// to what it covers. A batch with a part missing is never used and is
  /// reported, see [SyncPull.incomplete].
  Future<SyncPull> pull() async {
    final db = await _ready();
    await _pushFirst(db);
    return _pull(db);
  }

  /// [everySnapshot] reads the snapshots without waiting for a gap, for a
  /// caller about to replace them.
  Future<SyncPull> _pull(BookDatabase db, {bool everySnapshot = false}) async {
    // A snapshot is read at most once in a pull, whatever comes of it, so
    // what was wrong with one is kept for the whole pull.
    final tried = <String>{};
    final unreadable = <SyncProblem>[];
    var applied = 0;
    var rekeyed = false;
    while (true) {
      final device = await _device(db);
      final out = await _out(db);
      final state = await _in(db);
      // From the start of the batch that brought each place furthest, so
      // that every batch that ends in or after it is named again.
      final listing = await transport.list(after: {...state.floors, device: out.prev});
      final problems = [for (final text in listing.problems) SyncProblem(SyncProblemKind.unreadable, text)];

      // Anything under this device's id that this database did not set out
      // to store is another database's: a batch, or a snapshot (two copies
      // that only ever compact store no batch for the other to see).
      final own = {for (final ref in out.attempted) ref.snapshot};
      final foreign = [for (final ref in listing.batches) if (ref.device == device && !out.wrote(ref)) ref];
      final strange = [for (final ref in listing.snapshots) if (ref.device == device && !own.contains(ref.snapshot)) ref];
      if (!rekeyed && (foreign.isNotEmpty || strange.isNotEmpty) && await db.transaction(() => _rekeyIfForeign(db, batch: foreign.firstOrNull, snapshot: strange.firstOrNull))) {
        rekeyed = true;
        continue;
      }

      // Every batch of another device that is listed, by writer and by
      // batch, with the parts of it that are there.
      final listed = <String, Map<String, Map<int, SyncBatchRef>>>{};
      for (final ref in listing.batches) {
        if (ref.device != device) listed.putIfAbsent(ref.device, () => {}).putIfAbsent(ref.batch, () => {})[ref.part] = ref;
      }
      final waiting = <SyncBatchRef>[];
      final incomplete = <SyncBatchRef>[];
      for (final MapEntry(key: from, value: batches) in listed.entries) {
        bool whole(Map<int, SyncBatchRef> parts) => parts.length == parts.values.first.parts;
        // The batches this listing has no more use for: applied before it,
        // applied from it, or found unreadable.
        final settled = {...?state.recent[from]};
        var at = state.batches[from]?.last ?? 0;
        while (true) {
          // The nearest batch that starts at or before the place and has not
          // been applied. All of them are taken in turn, wherever they end.
          final usable = [
            for (final MapEntry(key: name, value: parts) in batches.entries)
              if (!settled.contains(name) && whole(parts) && parts.values.first.prev <= at) parts,
          ]..sort((a, b) => a.values.first.last != b.values.first.last ? a.values.first.last.compareTo(b.values.first.last) : a.values.first.batch.compareTo(b.values.first.batch));
          if (usable.isEmpty) break;
          final parts = usable.first;
          settled.add(parts.values.first.batch);
          // A batch that ends no further than the place holds nothing this
          // device is waiting for; if it cannot be read, that is nothing to
          // report, and it is tried again for as long as it is listed.
          final taken = await _takeBatch(db, [for (var i = 1; i <= parts.length; i++) parts[i]!], parts.values.first.last > at ? problems : []);
          if (taken == null) continue;
          applied += taken;
          at = (await _in(db)).batches[from]!.last;
        }
        for (final parts in batches.values) {
          if (parts.values.first.last > at) (whole(parts) ? waiting : incomplete).add(parts.values.first);
        }
      }

      // Every snapshot of another device.
      final snapshots = <String, Map<int, SyncSnapshotRef>>{};
      for (final ref in listing.snapshots) {
        if (ref.device != device) snapshots.putIfAbsent(ref.snapshot, () => {})[ref.part] = ref;
      }
      if (problems.isNotEmpty || waiting.isNotEmpty || incomplete.isNotEmpty || everySnapshot) {
        // (Of this round: a batch that cannot be read or is not whole, or a
        // file the transport could not name, may be what a snapshot stands
        // in for.)
        final taken = (await _in(db)).taken;
        // What a snapshot says it covers is believed only as far as the
        // remote shows a batch of that device.
        final shown = <String, int>{};
        for (final ref in listing.batches) {
          shown[ref.device] = max(shown[ref.device] ?? 0, ref.last);
        }
        final unread = [
          for (final MapEntry(key: name, value: parts) in snapshots.entries)
            if (!taken.contains(name) && !tried.contains(name) && !_newer.containsKey(name) && parts.length == parts.values.first.parts) parts,
        ]..sort((a, b) => a.values.first.seq.compareTo(b.values.first.seq));
        for (final parts in unread) {
          tried.add(parts.values.first.snapshot);
          applied += await _takeSnapshot(db, [for (var i = 1; i <= parts.length; i++) parts[i]!], shown, unreadable);
        }
      }

      // What was listed was asked for from the old places: with new ones
      // there may be more to take (a batch that waited, a next page). Only
      // real progress counts, see [_In.beyond], so this ends.
      if ((await _in(db)).beyond(state)) continue;
      problems.addAll(unreadable);
      problems.addAll([for (final name in snapshots.keys) if (_newer[name] != null) _newer[name]!]);
      return SyncPull(applied: applied, waiting: waiting, incomplete: incomplete, problems: problems, rekeyed: rekeyed);
    }
  }

  /// The records of [ops] by collection, read. A collection this build does
  /// not have makes the whole body unreadable, like a record it cannot read.
  List<SyncIncoming> _parts(List<SyncOp> ops) {
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final op in ops) {
      grouped.putIfAbsent(op.collection, () => []).add(op.record);
    }
    return [
      for (final collection in grouped.keys)
        collections.firstWhere((c) => c.name == collection, orElse: () => throw FormatException('a collection this build does not have: $collection')).read(grouped[collection]!),
    ];
  }

  Future<int> _apply(BookDatabase db, Iterable<SyncIncoming> parts) async {
    var taken = 0;
    for (final collection in collections) {
      taken += await collection.apply(db, parts.where((p) => p.collection == collection.name), remote);
    }
    return taken;
  }

  /// Reads and applies the parts of one batch, one at a time, then writes
  /// down that it was applied and moves the writer's place to its end if
  /// that is further on. Returns the rows changed, or null when a part is
  /// not there or cannot be read (which is added to [problems]): nothing is
  /// written down then, and what was applied of the other parts does no
  /// harm, since applying is a merge.
  Future<int?> _takeBatch(BookDatabase db, List<SyncBatchRef> parts, List<SyncProblem> problems) async {
    var taken = 0;
    for (final ref in parts) {
      final body = await transport.read(ref);
      if (body == null) return null;
      final List<SyncIncoming> incoming;
      try {
        incoming = _parts(SyncBatch.read(ref, body).ops);
      } on SyncNewerVersion catch (e) {
        problems.add(SyncProblem(SyncProblemKind.newerVersion, 'batch $ref: $e'));
        return null;
      } on FormatException catch (e) {
        problems.add(SyncProblem(SyncProblemKind.unreadable, 'batch $ref: ${e.message}'));
        return null;
      }
      taken += await db.transaction(() => _apply(db, incoming));
    }
    final ref = parts.first;
    await db.transaction(() async {
      // Another isolate may have taken this batch, or a further one.
      final state = await _in(db);
      var at = state.batches[ref.device] ?? (prev: 0, last: 0);
      if (ref.last > at.last) at = (prev: ref.prev, last: ref.last);
      state.batches[ref.device] = at;
      state.recent[ref.device] = [
        for (final name in {...?state.recent[ref.device], ref.batch})
          if (_lastOf(name) > at.prev) name,
      ];
      await _setMeta(db, _inKey, state.text);
    });
    return taken;
  }

  /// The `last` in a batch's name ([SyncBatchRef.batch]).
  static int _lastOf(String batch) => int.parse(batch.split('.')[3]);

  /// Reads and merges the parts of one snapshot, one at a time, then moves
  /// every place to what the snapshot covers and remembers it as taken in.
  /// Returns the rows changed.
  ///
  /// A place moves no further than [shown], the furthest batch of that
  /// device the remote lists: a compaction always leaves a device's newest
  /// batch, so an honest snapshot never covers more than that, and a damaged
  /// one cannot make this device pass over batches that are yet to be
  /// written. A snapshot held back that way is not remembered as taken in,
  /// and is read again once more of the remote is listed.
  ///
  /// The batch a place was reached by is kept as it was: what a snapshot
  /// covers says nothing of where the writer's batches begin and end, which
  /// is what [compact] needs to know before it removes any.
  Future<int> _takeSnapshot(BookDatabase db, List<SyncSnapshotRef> parts, Map<String, int> shown, List<SyncProblem> problems) async {
    final name = parts.first.snapshot;
    var taken = 0;
    Map<String, int>? covers;
    for (final ref in parts) {
      final body = await transport.readSnapshot(ref);
      if (body == null) return taken;
      final List<SyncIncoming> incoming;
      try {
        final snapshot = SyncSnapshot.read(ref, body);
        if (covers != null && !_sameCovers(covers, snapshot.covers)) throw FormatException('parts of $name that do not agree');
        covers = snapshot.covers;
        incoming = _parts(snapshot.records);
      } on SyncNewerVersion catch (e) {
        _newer[name] = SyncProblem(SyncProblemKind.newerVersion, 'snapshot $ref: $e');
        return taken;
      } on FormatException catch (e) {
        problems.add(SyncProblem(SyncProblemKind.unreadable, 'snapshot $ref: ${e.message}'));
        return taken;
      }
      taken += await db.transaction(() => _apply(db, incoming));
    }
    await db.transaction(() async {
      final device = await _device(db);
      final state = await _in(db);
      var whole = true;
      for (final MapEntry(key: from, value: seq) in covers!.entries) {
        if (from == device) continue;
        final at = state.batches[from];
        final reached = at?.last ?? 0;
        final bound = max(reached, shown[from] ?? 0);
        if (seq > bound) whole = false;
        if (min(seq, bound) > reached) state.batches[from] = (prev: at?.prev ?? 0, last: min(seq, bound));
      }
      if (whole) state.taken.add(name);
      await _setMeta(db, _inKey, state.text);
    });
    return taken;
  }

  /// Makes the remote smaller: after a full round, stores everything this
  /// device holds as one snapshot, then removes what the snapshot stands in
  /// for, then trims the local log.
  ///
  /// A snapshot is written when the book or the places differ from what the
  /// snapshot this database stored last holds, or when that one is gone and
  /// no other device has a whole one there. A snapshot counts as stored, and
  /// what it holds is written down, only once the transport has every part
  /// of it; one that was only set out to be written counts for nothing, and
  /// the next call writes again. When nothing has changed and the stored one
  /// is gone while another device's stands, that device has replaced it with
  /// its own, which holds at least as much: nothing is written and nothing
  /// removed.
  ///
  /// Nothing is removed unless this device's own snapshot, which holds all
  /// of it, is whole on the remote at that moment (it was stored by this
  /// call, or it is listed or can be read):
  /// - batches, up to the places this device had reached when the snapshot
  ///   was read, except the newest of every device: a reader that is further
  ///   behind finds that batch does not continue from its place, and that is
  ///   what sends it to the snapshots. A batch with a part missing goes with
  ///   the others, and not before;
  /// - every other snapshot this database set out to store, whole or not;
  /// - the snapshots of other devices that it has taken in: all of a device
  ///   whose id sorts before its own, and of any device all but the newest
  ///   that is whole. Two devices that compact at the same moment each hold
  ///   the other's snapshot and see their own, and without an order between
  ///   them each would remove the other's. With it, the newest snapshot of a
  ///   device can only be removed by a device further on in the order, whose
  ///   own then stays; and what a device that is gone left behind, however
  ///   far on in the order it was, comes down to its one newest snapshot.
  ///
  /// Refused, with nothing written or removed, while the remote holds
  /// anything from a later build.
  @override
  Future<SyncCompaction> compact() async {
    final db = await _ready();
    final first = await _pushFirst(db);
    final pulled = await _pull(db, everySnapshot: true);
    if (pulled.needsUpdate) return SyncCompaction(snapshot: null, refused: true, trimmed: 0, round: SyncRound(pulled, first));
    final round = SyncRound(pulled, SyncPush(sent: first.sent + (await push()).sent));

    for (var tries = 0; ; tries++) {
      final device = await _device(db);
      var listing = await transport.list(after: (await _in(db)).lasts);
      // Whether every part of a snapshot is on the remote: the listing shows
      // them, or, as a listing may leave names out, they can be read.
      Future<bool> whole(SyncSnapshotRef ref) async {
        final names = {for (final other in listing.snapshots) other.name};
        return [for (var i = 1; i <= ref.parts; i++) ref.partAt(i).name].every(names.contains) || await _reads(ref);
      }

      final current = (await _out(db)).stored;
      final there = current != null && await whole(current);
      final names = {for (final ref in listing.snapshots) ref.name};
      final others = listing.snapshots.any((ref) => ref.device != device && [for (var i = 1; i <= ref.parts; i++) ref.partAt(i).name].every(names.contains));
      final plan = await db.transaction(() => _plan(db, current: current, there: there, others: others));
      final ref = plan.ref;
      if (ref == null) return SyncCompaction(snapshot: null, trimmed: await trimLocal(), round: round);

      final parts = plan.parts;
      if (parts != null) {
        SyncSnapshotRef? taken;
        for (var i = 0; i < parts.length && taken == null; i++) {
          final part = ref.partAt(i + 1);
          if (!await transport.writeSnapshot(part, SyncSnapshot(part, plan.covers, parts[i]).body)) taken = part;
        }
        if (taken != null) {
          // As in [push]: what is there under the name is left, and the
          // snapshot is written again under its next number.
          if (tries == _tries) throw StateError('The sync transport holds other contents under every name tried for a snapshot, last $taken.');
          continue;
        }
        await db.transaction(() async {
          if (await _device(db) != ref.device) return;
          final out = await _out(db);
          if (ref.seq > (out.stored?.seq ?? 0)) await _setMeta(db, _outKey, out.storing(ref, plan.covers, plan.digest).text);
        });
        // Nothing is removed on the word of the write alone.
        listing = await transport.list(after: plan.state.lasts);
        if (!await whole(ref)) return SyncCompaction(snapshot: null, trimmed: await trimLocal(), round: round);
      }

      // The places as they were when the snapshot was read, not as they are
      // now: a batch sent or taken since then is not in the snapshot.
      final superseded = [for (final other in plan.out.attempted) if (other.snapshot != ref.snapshot) other];
      // Per device, the number of its newest snapshot that is listed whole.
      final newest = <String, int>{};
      final shown = {for (final other in listing.snapshots) other.name};
      for (final other in listing.snapshots) {
        if ([for (var i = 1; i <= other.parts; i++) other.partAt(i).name].every(shown.contains)) newest[other.device] = max(newest[other.device] ?? 0, other.seq);
      }
      await transport.discard(
        batchesThrough: {for (final e in plan.state.batches.entries) e.key: e.value.prev, ref.device: plan.out.prev},
        snapshots: [
          for (final other in superseded)
            for (var i = 1; i <= other.parts; i++) other.partAt(i),
          for (final other in listing.snapshots)
            if (plan.state.taken.contains(other.snapshot) && (other.device.compareTo(ref.device) < 0 || other.seq < (newest[other.device] ?? 0))) other,
        ],
      );
      await db.transaction(() async {
        if (await _device(db) != ref.device) return;
        final gone = {for (final other in superseded) other.snapshot};
        final out = await _out(db);
        await _setMeta(db, _outKey, out.copy(attempted: [for (final other in out.attempted) if (!gone.contains(other.snapshot)) other]).text);
        // What is no longer listed need not be remembered.
        final state = await _in(db);
        final listed = {for (final other in listing.snapshots) other.snapshot};
        await _setMeta(db, _inKey, _In(state.batches, state.recent, state.taken.intersection(listed)).text);
      });
      return SyncCompaction(snapshot: ref, trimmed: await trimLocal(), round: round);
    }
  }

  /// Whether every part of [ref] can be read from the remote, for a snapshot
  /// a listing does not show whole: a listing may leave names out.
  Future<bool> _reads(SyncSnapshotRef ref) async {
    for (var i = 1; i <= ref.parts; i++) {
      if (await transport.readSnapshot(ref.partAt(i)) == null) return false;
    }
    return true;
  }

  /// Reads what a snapshot would hold, in one transaction with the places it
  /// covers, and decides what is to stand.
  ///
  /// [current] is the snapshot this database stored last as the caller saw
  /// it, [there] whether it is still whole on the remote, and [others]
  /// whether another device has a whole one there. When the records are,
  /// record for record, what [current] holds and it covers the same, it
  /// stands if it is there, and nothing stands if it is gone and another
  /// device's is there. (The records are compared by digest, not by whether
  /// the log has grown: the log also grows by rows that change no record,
  /// such as the engine's own for another remote.)
  ///
  /// Otherwise a row of its own gives a new snapshot a number, and its name
  /// is written down as set out to be stored before anything is handed to
  /// the transport, so that whatever becomes of the write the name can be
  /// removed later.
  Future<_Plan> _plan(BookDatabase db, {required SyncSnapshotRef? current, required bool there, required bool others}) async {
    final device = await _device(db);
    final out = await _out(db);
    final state = await _in(db);
    final covers = {...state.lasts, device: out.shipped};
    final records = <SyncOp>[];
    for (final collection in collections) {
      for (final record in await collection.state(db)) {
        records.add(SyncOp(collection.name, record));
      }
    }
    final digest = sha256.convert(utf8.encode(jsonEncode([for (final op in records) op.toJson()]))).toString();
    // Another isolate may have stored a snapshot since the caller looked.
    final same = out.stored != null && out.stored == current && digest == out.digest && _sameCovers(out.covers, covers);
    if (same && there) return _Plan(out.stored, covers, digest, null, state, out);
    if (same && others) return _Plan(null, covers, digest, null, state, out);
    await _mark(db, opSnapshot, remote);
    final parts = SyncWire.split(records, partBytes: partBytes);
    final ref = SyncSnapshotRef(device: device, writer: writer, seq: await _high(db), parts: parts.length);
    await _setMeta(db, _outKey, out.copy(attempted: [...out.attempted, ref]).text);
    return _Plan(ref, covers, digest, parts, state, out);
  }

  static bool _sameCovers(Map<String, int> a, Map<String, int> b) => a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  /// Removes the rows of `changes` that every remote this file has been
  /// attached to has been sent. A row that some remote has not had stays, and
  /// with no remote at all nothing is removed.
  Future<int> trimLocal() async {
    final db = await _database();
    return db.transaction(() async {
      final rows = await db.customSelect("SELECT value FROM meta WHERE key LIKE 'sync.out.%'").get();
      if (rows.isEmpty) return 0;
      final passed = rows.map((row) => _Out.parse(row.data['value'] as String).scanned).reduce(min);
      return db.customUpdate('DELETE FROM changes WHERE seq <= ?', variables: [Variable<int>(passed)]);
    });
  }
}
