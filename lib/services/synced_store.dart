import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../models/syncable.dart';
import 'cloud_kv_store.dart';
import 'local_file_store.dart';
import 'switchable_cloud_kv_store.dart';

/// A single synced record: the item plus merge metadata. [order] is
/// fractional so items can be inserted between two others without
/// renumbering the whole list. [deleted] is a soft-delete tombstone.
class Record<T extends Syncable> {
  final T item;
  final double order;
  final DateTime updatedAt;
  final bool deleted;

  const Record({required this.item, required this.order, required this.updatedAt, this.deleted = false});

  Record<T> copyWith({T? item, double? order, DateTime? updatedAt, bool? deleted}) {
    return Record<T>(
      item: item ?? this.item,
      order: order ?? this.order,
      updatedAt: updatedAt ?? this.updatedAt,
      deleted: deleted ?? this.deleted,
    );
  }

  Map<String, dynamic> toJson() => {
        'item': item.toJson(),
        'order': order,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'deleted': deleted,
      };

  static Record<T> fromJson<T extends Syncable>(Map<String, dynamic> json, T Function(Map<String, dynamic>) itemFromJson) {
    return Record<T>(
      item: itemFromJson(json['item'] as Map<String, dynamic>),
      order: (json['order'] as num).toDouble(),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      deleted: json['deleted'] as bool? ?? false,
    );
  }
}

/// Callbacks waiting to run one after another.
class _OperationQueue {
  final Queue<void Function()> pending = Queue<void Function()>();
  bool running = false;

  void startNext() {
    if (pending.isEmpty) {
      running = false;
      return;
    }
    running = true;
    pending.removeFirst()();
  }
}

/// Where a [SyncedStore] keeps its local copy of the records. The merge with
/// the cloud lives in the store; a backend only reads and writes the whole
/// set, so a collection can change where it is kept without touching the
/// merge.
abstract class LocalRecords<T extends Syncable> {
  Future<List<Record<T>>> read();

  Future<void> write(List<Record<T>> records);
}

/// A backend that holds its rows to the merge rule, and so may keep a stored
/// record in place of the one it is given (another isolate stored a record
/// that wins, after this store read).
abstract class GuardedRecords<T extends Syncable> implements LocalRecords<T> {
  /// [write], returning [records] as they are now stored: where a stored
  /// record was kept, that record.
  Future<List<Record<T>>> writeGuarded(List<Record<T>> records);
}

/// The local copy as one JSON file holding every record, `{"records": [...]}`.
class JsonFileRecords<T extends Syncable> implements LocalRecords<T> {
  final String filePath;
  final T Function(Map<String, dynamic>) itemFromJson;

  const JsonFileRecords(this.filePath, this.itemFromJson);

  @override
  Future<List<Record<T>>> read() async {
    final json = await LocalFileStore.readJson(filePath);
    if (json == null) return [];
    final raw = json['records'] as List<dynamic>? ?? [];
    return raw.map((e) => Record.fromJson<T>(e as Map<String, dynamic>, itemFromJson)).toList();
  }

  @override
  Future<void> write(List<Record<T>> records) {
    return LocalFileStore.writeJson(filePath, {'records': records.map((r) => r.toJson()).toList()});
  }
}

/// How a [SyncedStore] writes its cloud value.
enum CloudFormat {
  /// The records as one JSON list. What every existing key holds.
  plainList,

  /// `{"v":1,"z":"gzip","data":"<base64 of the gzipped JSON record list>"}`.
  /// A value written by a newer version, or one that cannot be decoded, is
  /// never overwritten (see [SyncedStore.cloudValueUnreadable]). That includes
  /// a value where even one record fails `itemFromJson`: the whole key is
  /// frozen rather than risk dropping the records this build cannot read. It
  /// stays frozen until a build whose `itemFromJson` accepts every record
  /// reads it, and only that build (or a user action that clears the key)
  /// lifts it; this build keeps working from its local copy meanwhile. A plain list
  /// already stored under the key is still read, and replaced by the envelope
  /// on the next write.
  envelope,
}

/// Conflict-free per-item merge engine on top of a local JSON mirror and a
/// pluggable [CloudKVStore]. Mirrors `SyncedStore<Item: Syncable>.swift`
/// (spec §2.10): last-write-wins per item, tombstoned deletes pruned after
/// [tombstoneTTL] (365 days unless the store says otherwise).
class SyncedStore<T extends Syncable> {
  final String filePath;
  final String cloudKey;
  final CloudKVStore cloud;
  final T Function(Map<String, dynamic>) itemFromJson;
  final List<T> Function()? seed;
  final CloudFormat cloudFormat;

  /// Decides a tie: when two records with the same id have equal `updatedAt`,
  /// the one this returns true for ([incoming] against [stored]) wins,
  /// whichever side it came from. Should be a strict order (not true both
  /// ways). Without it a tie goes to the later record in the merge, and
  /// [absorb] ignores a tie. See [replaces].
  final bool Function(Record<T> incoming, Record<T> stored)? prefer;

  /// How long a tombstone is kept; null keeps tombstones for ever.
  final Duration? tombstoneTTL;

  /// Called after every change made through this store (a save, a delete, an
  /// import), and not after a load or a merge. It is how something that
  /// wants to know of local changes, such as the change log sync, hears of
  /// them; it must not throw.
  void Function()? onSaved;

  final LocalRecords<T> _local;
  final Expando<_OperationQueue> _queues = Expando<_OperationQueue>();
  bool _cloudUnreadable = false;
  bool _cloudWriteSkipped = false;
  String? _lastCloudRaw;
  String? _skippedValue;
  String? _skippedAgainstRaw;

  /// What the cloud store tracked in total when the write was skipped (see
  /// [SwitchableCloudKVStore.trackedBytes]); null for a store that does not
  /// track.
  int? _skippedTracked;

  /// The envelope version this build reads and writes.
  static const int envelopeVersion = 1;

  static const Duration defaultTombstoneTTL = Duration(days: 365);

  /// [local] defaults to the JSON file at [filePath].
  SyncedStore({
    required this.filePath,
    required this.cloudKey,
    required this.itemFromJson,
    required this.cloud,
    this.seed,
    LocalRecords<T>? local,
    this.cloudFormat = CloudFormat.plainList,
    this.prefer,
    this.tombstoneTTL = defaultTombstoneTTL,
  }) : _local = local ?? JsonFileRecords<T>(filePath, itemFromJson);

  /// The smallest step between two stamps that every stored form keeps. A
  /// stamp is stored as ISO text, down to the microsecond where the platform
  /// has microseconds and to the millisecond on web, so a microsecond would
  /// not survive a round through a web device.
  static const Duration stampStep = Duration(milliseconds: 1);

  /// Whether [incoming] takes the place of [stored], a record with the same
  /// id. This is the one rule every path decides by: a merge ([keyed]), the
  /// local rows (`DbRecords`), an import of an old file, and [absorb].
  ///
  /// The later `updatedAt` wins. For equal stamps [prefer] decides, and
  /// without one [incoming] is taken. With [strict], equal stamps are never
  /// taken: that is for a source that only flows one way and is never
  /// cleared (an old cloud key, an old file), which must not keep winning a
  /// tie against what this build writes.
  static bool replaces<T extends Syncable>(Record<T> incoming, Record<T> stored, bool Function(Record<T> incoming, Record<T> stored)? prefer, {bool strict = false}) {
    if (strict) return incoming.updatedAt.isAfter(stored.updatedAt);
    if (prefer != null && stored.updatedAt == incoming.updatedAt) return prefer(incoming, stored);
    return !stored.updatedAt.isAfter(incoming.updatedAt);
  }

  /// The stamp of a change made on this device, at [now], to the record
  /// [held] (null for a new one). A clock that is behind the held stamp (it
  /// was set back, or the record came from a device whose clock is ahead)
  /// would stamp the change earlier than what it replaces, and every merge
  /// would then keep the old record and drop the change. So the stamp is
  /// never earlier than one [stampStep] after the held one. [held] is the
  /// record as [_held] gives it, the cloud's copy included: a version that
  /// has arrived in the cloud and was not loaded yet counts as held.
  static DateTime stampAfter(DateTime now, Record? held) {
    if (held == null) return now;
    final least = held.updatedAt.add(stampStep);
    return now.isBefore(least) ? least : now;
  }

  Map<String, Record<T>> keyed(List<Record<T>> records) {
    final byId = <String, Record<T>>{};
    for (final record in records) {
      final existing = byId[record.item.id];
      if (existing == null || replaces(record, existing, prefer)) byId[record.item.id] = record;
    }
    return byId;
  }

  List<Record<T>> merge(List<Record<T>> a, List<Record<T>> b) {
    final combined = keyed([...a, ...b]);
    return combined.values.toList();
  }

  List<Record<T>> prune(List<Record<T>> records, {DateTime? now}) {
    final ttl = tombstoneTTL;
    if (ttl == null) return List.of(records);
    final current = now ?? DateTime.now();
    return records
        .where((r) => !(r.deleted && current.difference(r.updatedAt) > ttl))
        .toList();
  }

  /// Runs [body] after every operation started before it has finished, so a
  /// read-modify-write never works from records another operation is about to
  /// change. A failed operation reports to its own caller and does not hold
  /// up the next.
  ///
  /// Operations are ordered per zone, and each body runs in the zone it was
  /// called from. The app has one zone, so there it is one queue. A zone made
  /// by a test under fake async only advances when the test pumps it, so an
  /// operation from the real zone waiting behind one from the fake zone would
  /// wait for a pump that never comes.
  Future<R> _serialized<R>(Future<R> Function() body) {
    final result = Completer<R>();
    final zone = Zone.current;
    final queue = _queues[zone] ??= _OperationQueue();
    queue.pending.add(() {
      zone.run(() async {
        try {
          result.complete(await body());
        } catch (error, stack) {
          result.completeError(error, stack);
        } finally {
          queue.startNext();
        }
      });
    });
    if (!queue.running) queue.startNext();
    return result.future;
  }

  Future<List<Record<T>>> _readLocal() => _local.read();

  /// Writes [records] locally and returns them as they are stored, which a
  /// backend that guards its rows may have decided otherwise for some.
  Future<List<Record<T>>> _writeLocal(List<Record<T>> records) async {
    final local = _local;
    if (local is GuardedRecords<T>) return local.writeGuarded(records);
    await local.write(records);
    return records;
  }

  /// True while the last cloud read found a value this build cannot use: an
  /// envelope with a newer version, or one that does not decode. The store
  /// then works from its local copy and leaves that key alone, until a read
  /// finds a usable value (or none). Only stores using [CloudFormat.envelope]
  /// ever report it.
  bool get cloudValueUnreadable => _cloudUnreadable;

  /// True after a cloud write was skipped because the store is full; false
  /// after the next write that went through (or once the cloud already holds
  /// what this store would write). An identical skipped write is not retried
  /// until the records or the cloud value change, or the cloud store's
  /// tracked total drops (another key shrank, so there may be room now).
  bool get cloudWriteSkipped => _cloudWriteSkipped;

  Future<List<Record<T>>> _readCloud() async {
    final raw = await cloud.getString(cloudKey);
    _lastCloudRaw = raw;
    if (raw == null || raw.isEmpty) {
      _cloudUnreadable = false;
      return [];
    }
    if (cloudFormat == CloudFormat.envelope) {
      final decoded = _decodeEnvelope(raw);
      _cloudUnreadable = decoded == null;
      return decoded ?? [];
    }
    _cloudUnreadable = false;
    try {
      return _recordsFromList(jsonDecode(raw) as List<dynamic>);
    } catch (_) {
      return [];
    }
  }

  List<Record<T>> _recordsFromList(List<dynamic> list) {
    return list.map((e) => Record.fromJson<T>(e as Map<String, dynamic>, itemFromJson)).toList();
  }

  /// The records in an envelope or a legacy plain list; null when the value
  /// is from a newer version or cannot be decoded.
  List<Record<T>>? _decodeEnvelope(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List<dynamic>) return _recordsFromList(decoded);
      if (decoded is! Map<String, dynamic>) return null;
      final version = decoded['v'];
      if (version is! int || version > envelopeVersion || version < 1) return null;
      if (decoded['z'] != 'gzip') return null;
      final bytes = GZipDecoder().decodeBytes(base64Decode(decoded['data'] as String), verify: true);
      return _recordsFromList(jsonDecode(utf8.decode(bytes)) as List<dynamic>);
    } catch (_) {
      return null;
    }
  }

  String _encodeCloud(List<Record<T>> records) {
    final json = jsonEncode(records.map((r) => r.toJson()).toList());
    if (cloudFormat == CloudFormat.plainList) return json;
    final gzipped = Uint8List.fromList(GZipEncoder().encodeBytes(utf8.encode(json)));
    return jsonEncode({'v': envelopeVersion, 'z': 'gzip', 'data': base64Encode(gzipped)});
  }

  /// Skipped while the key holds a value this build cannot read, so that
  /// value survives.
  Future<void> _writeCloud(List<Record<T>> records) async {
    if (_cloudUnreadable) return;
    final value = _encodeCloud(records);
    final store = cloud;
    final tracked = store is SwitchableCloudKVStore ? store.trackedBytes : null;
    if (_cloudWriteSkipped && value == _skippedValue && _lastCloudRaw == _skippedAgainstRaw && !_roomFreed(tracked)) return;
    var written = true;
    if (store is SwitchableCloudKVStore) {
      written = await store.trySetString(cloudKey, value);
    } else {
      await store.setString(cloudKey, value);
    }
    if (written) {
      _cloudWriteSkipped = false;
      _skippedValue = null;
      _skippedAgainstRaw = null;
      _skippedTracked = null;
    } else {
      _cloudWriteSkipped = true;
      _skippedValue = value;
      _skippedAgainstRaw = _lastCloudRaw;
      _skippedTracked = tracked;
    }
  }

  /// Whether the cloud store tracks less than it did when the write was
  /// skipped.
  bool _roomFreed(int? tracked) => tracked != null && _skippedTracked != null && tracked < _skippedTracked!;

  List<T> _liveSorted(List<Record<T>> records) {
    final live = records.where((r) => !r.deleted).toList()
      ..sort((a, b) {
        final byOrder = a.order.compareTo(b.order);
        if (byOrder != 0) return byOrder;
        return a.item.id.compareTo(b.item.id);
      });
    return live.map((r) => r.item).toList();
  }

  /// Loads the merged local+cloud state (seeding if both are empty),
  /// persists the merge result, and returns the live items in display
  /// order.
  Future<List<T>> load() => _serialized(() => _load());

  Future<List<T>> _load() async {
    final local = await _readLocal();
    final cloudRecords = await _readCloud();

    List<Record<T>> merged;
    if (local.isEmpty && cloudRecords.isEmpty && seed != null && !_cloudUnreadable) {
      final seeded = seed!();
      final distantPast = DateTime.fromMillisecondsSinceEpoch(-8640000000000000, isUtc: true);
      merged = <Record<T>>[
        for (var i = 0; i < seeded.length; i++)
          Record<T>(item: seeded[i], order: i.toDouble(), updatedAt: distantPast),
      ];
    } else {
      merged = prune(merge(local, cloudRecords));
    }

    final stored = await _writeLocal(merged);
    final prunedCloud = prune(cloudRecords);
    if (!_sameRecordSet(prunedCloud, stored)) {
      await _writeCloud(stored);
    } else if (!_cloudUnreadable) {
      _cloudWriteSkipped = false;
      _skippedValue = null;
      _skippedAgainstRaw = null;
      _skippedTracked = null;
    }

    return _liveSorted(stored);
  }

  bool _sameRecordSet(List<Record<T>> a, List<Record<T>> b) {
    if (a.length != b.length) return false;
    final byIdA = {for (final r in a) r.item.id: r};
    for (final r in b) {
      final other = byIdA[r.item.id];
      if (other == null) return false;
      if (other.deleted != r.deleted || other.order != r.order || other.updatedAt != r.updatedAt) return false;
      // With a tie-breaker, equal stamps can still hold different content.
      if (prefer != null && jsonEncode(other.item.toJson()) != jsonEncode(r.item.toJson())) return false;
    }
    return true;
  }

  /// Everything this device knows of the collection: its own copy merged
  /// with the cloud's. Every change the person makes is made to this and
  /// stamped against it ([stampAfter]), so a version that is in the cloud
  /// and was not loaded yet is not written over by an older stamp.
  Future<List<Record<T>>> _held() async => merge(await _readLocal(), await _readCloud());

  /// Makes [records] (what [_held] gave, with a change) the state of the
  /// collection, here and in the cloud. What goes to the cloud is what is
  /// stored here after the write, which is not always what was asked for
  /// (see [GuardedRecords]).
  Future<void> _put(List<Record<T>> records) async {
    await _writeCloud(await _writeLocal(prune(records)));
    onSaved?.call();
  }

  Future<List<T>> upsert(T item) => _serialized(() => _upsert(item));

  Future<List<T>> _upsert(T item) async {
    final held = await _held();
    final now = DateTime.now();
    final existingIndex = held.indexWhere((r) => r.item.id == item.id);
    List<Record<T>> updated;
    if (existingIndex >= 0) {
      final existing = held[existingIndex];
      updated = List.of(held)..[existingIndex] = existing.copyWith(item: item, updatedAt: stampAfter(now, existing), deleted: false);
    } else {
      final maxOrder = held.isEmpty ? -1.0 : held.map((r) => r.order).reduce(max);
      updated = [...held, Record<T>(item: item, order: maxOrder + 1, updatedAt: now)];
    }
    await _put(updated);
    return _liveSorted(await _readLocal());
  }

  /// Adds or replaces every item in [items] in one commit.
  Future<List<T>> upsertAll(List<T> items) => _serialized(() => _upsertAll(items));

  Future<List<T>> _upsertAll(List<T> items) async {
    if (items.isEmpty) return _liveSorted(await _readLocal());
    final held = List<Record<T>>.of(await _held());
    final now = DateTime.now();
    var maxOrder = held.isEmpty ? -1.0 : held.map((r) => r.order).reduce(max);
    final index = {for (var i = 0; i < held.length; i++) held[i].item.id: i};
    for (final item in items) {
      final at = index[item.id];
      if (at != null) {
        held[at] = held[at].copyWith(item: item, updatedAt: stampAfter(now, held[at]), deleted: false);
      } else {
        maxOrder += 1;
        index[item.id] = held.length;
        held.add(Record<T>(item: item, order: maxOrder, updatedAt: now));
      }
    }
    await _put(held);
    return _liveSorted(await _readLocal());
  }

  Future<List<T>> delete(String id) => _serialized(() => _delete(id));

  Future<List<T>> _delete(String id) async {
    final held = await _held();
    final index = held.indexWhere((r) => r.item.id == id);
    if (index < 0) return _liveSorted(await _readLocal());
    final now = DateTime.now();
    await _put(List<Record<T>>.of(held)..[index] = held[index].copyWith(deleted: true, updatedAt: stampAfter(now, held[index])));
    return _liveSorted(await _readLocal());
  }

  /// Adds each of [records] whose id this store has never seen — live or
  /// tombstoned, here or in the cloud — keeping the record's own metadata.
  /// One commit for the batch; returns how many were added.
  ///
  /// For migrations: two devices migrating the same source produce the
  /// same records, and a record the user already deleted is never revived.
  Future<int> insertMissing(List<Record<T>> records) => _serialized(() => _insertMissing(records));

  Future<int> _insertMissing(List<Record<T>> records) async {
    if (records.isEmpty) return 0;
    final held = await _held();
    final known = {for (final r in held) r.item.id};
    final missing = [for (final r in records) if (!known.contains(r.item.id)) r];
    if (missing.isEmpty) return 0;
    await _put([...held, ...missing]);
    return missing.length;
  }

  /// One-way intake of records converted from another source. A record is
  /// taken when its id has never been seen here (a tombstone counts as seen),
  /// or when it takes the place of the stored one by [replaces]: a strictly
  /// later `updatedAt`, or an equal one that [prefer] prefers. A store
  /// without [prefer] ignores equal stamps, and so does every store when
  /// [strict] is set, which is how an old cloud key is read: it is never
  /// cleared, so a tie taken from it would be taken again by every device
  /// and for ever, against whatever this build writes under the same stamp.
  /// The record is kept as given, metadata and all. One commit for the
  /// batch; returns whether anything changed.
  Future<bool> absorb(List<Record<T>> incoming, {bool strict = false}) => _serialized(() => _absorb(incoming, strict: strict));

  Future<bool> _absorb(List<Record<T>> incoming, {required bool strict}) async {
    // Tombstones too old to keep would be pruned straight away (never, when
    // the store keeps tombstones for ever).
    final candidates = prune(incoming);
    if (candidates.isEmpty) return false;
    final byId = keyed(await _held());
    var changed = false;
    for (final record in candidates) {
      final stored = byId[record.item.id];
      if (stored == null || replaces(record, stored, prefer, strict: strict || prefer == null)) {
        byId[record.item.id] = record;
        changed = true;
      }
    }
    if (!changed) return false;
    await _put(byId.values.toList());
    return true;
  }

  /// Tombstones every item in [ids] in one commit.
  Future<List<T>> deleteAll(Iterable<String> ids) => _serialized(() => _deleteAll(ids));

  Future<List<T>> _deleteAll(Iterable<String> ids) async {
    final targets = ids.toSet();
    final held = await _held();
    if (!held.any((r) => targets.contains(r.item.id) && !r.deleted)) return _liveSorted(await _readLocal());
    final now = DateTime.now();
    await _put([
      for (final r in held)
        targets.contains(r.item.id) && !r.deleted ? r.copyWith(deleted: true, updatedAt: stampAfter(now, r)) : r,
    ]);
    return _liveSorted(await _readLocal());
  }

  /// Reassigns order for each id in [orderedIds]; only bumps `updatedAt` for
  /// items whose order actually changed.
  Future<List<T>> setOrder(List<String> orderedIds) => _serialized(() => _setOrder(orderedIds));

  Future<List<T>> _setOrder(List<String> orderedIds) async {
    final now = DateTime.now();
    final updated = List<Record<T>>.of(await _held());
    for (var i = 0; i < orderedIds.length; i++) {
      final index = updated.indexWhere((r) => r.item.id == orderedIds[i]);
      if (index < 0) continue;
      final record = updated[index];
      if (record.order != i.toDouble()) {
        updated[index] = record.copyWith(order: i.toDouble(), updatedAt: stampAfter(now, record));
      }
    }
    await _put(updated);
    return _liveSorted(await _readLocal());
  }

  /// Raw records (including metadata and tombstones) for export/backup
  /// purposes — the merged local+cloud state, unfiltered by [_liveSorted].
  Future<List<Record<T>>> exportRecords() => _serialized(() => _exportRecords());

  Future<List<Record<T>>> _exportRecords() async => prune(await _held());

  /// Imports a previously-exported record set.
  ///
  /// Merge (`replace: false`): folds [records] into the existing
  /// local+cloud state using the normal last-write-wins-per-item merge, so
  /// whichever copy (existing or imported) has the newer `updatedAt` for
  /// each id wins.
  ///
  /// Replace (`replace: true`): the import becomes the new state outright —
  /// every existing live item is tombstoned (unless the import re-adds it),
  /// and every imported item is written, all re-stamped with [now]
  /// (defaulting to the current time) so this restore beats any older edit
  /// already sitting on another device once sync catches up. A record that
  /// is held with a later stamp still (a clock that is behind) is stamped
  /// just after it, see [stampAfter]. "Existing" is everything this store
  /// knows, the cloud's copy included.
  ///
  /// [replaceWhere] limits a replace to part of the collection: only records
  /// it selects are tombstoned or overwritten, and an imported record is
  /// ignored unless it is selected itself and does not land on a stored
  /// record outside the selection. Without it the whole collection is
  /// replaced. It has no effect on a merge.
  Future<List<T>> importRecords(List<Record<T>> records, {required bool replace, DateTime? now, bool Function(Record<T> record)? replaceWhere}) =>
      _serialized(() => _importRecords(records, replace: replace, now: now, replaceWhere: replaceWhere));

  Future<List<T>> _importRecords(List<Record<T>> records, {required bool replace, DateTime? now, bool Function(Record<T> record)? replaceWhere}) async {
    final held = await _held();
    if (!replace) {
      await _put(merge(held, records));
      return _liveSorted(await _readLocal());
    }

    final effectiveNow = now ?? DateTime.now();
    final heldById = {for (final r in held) r.item.id: r};
    if (replaceWhere != null) {
      // A scope is judged against everything this store knows, cloud-only
      // records included, so one outside the selection is never overwritten.
      records = [
        for (final r in records)
          if (replaceWhere(r) && (heldById[r.item.id] == null || replaceWhere(heldById[r.item.id]!))) r,
      ];
    }
    final importedIds = records.map((r) => r.item.id).toSet();
    // Every held LIVE item not present in the import is tombstoned (soft
    // deleted) rather than dropped, so the deletion itself propagates on
    // sync instead of silently reappearing from another device's copy.
    // Already-deleted records are left as-is: their tombstone TTL
    // clock shouldn't reset just because a restore happened to run.
    final tombstoned = [
      for (final r in held)
        if (r.deleted || importedIds.contains(r.item.id) || (replaceWhere != null && !replaceWhere(r))) r else r.copyWith(deleted: true, updatedAt: stampAfter(effectiveNow, r)),
    ];
    final restamped = [for (final r in records) r.copyWith(updatedAt: stampAfter(effectiveNow, heldById[r.item.id]))];
    await _put(merge(tombstoned, restamped));
    return _liveSorted(await _readLocal());
  }

  Future<void> startSync() => cloud.synchronize();

  /// Re-runs the merge+persist against fresh cloud data; returns null if the
  /// cloud has nothing stored for this key yet.
  Future<List<T>?> adoptCloudChanges() => _serialized(() => _adoptCloudChanges());

  Future<List<T>?> _adoptCloudChanges() async {
    final raw = await cloud.getString(cloudKey);
    if (raw == null) return null;
    return _load();
  }
}
