import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../models/book_entry.dart';
import '../../models/syncable.dart';
import '../local_file_store.dart';
import '../synced_store.dart';
import 'book_database.dart';
import 'ledger_migration.dart';
import 'ledger_plan.dart';

/// One SQL statement and its arguments.
typedef _Sql = (String, List<Object?>);

/// A [LocalRecords] kept in the book database. `write` is row level: it
/// compares the records with what this store last read and applies only the
/// difference, in one transaction, logging each row it touches in `changes`.
/// A row this store never read, because another store (another isolate, the
/// background refresh) added it since, is never touched, so a write cannot
/// undo someone else's save. When two stores change the same row the later
/// writer wins.
///
/// Subclasses say how one record maps to rows; the diff, the import of the
/// old JSON file and the log are here.
abstract class DbRecords<T extends Syncable> implements LocalRecords<T> {
  /// The cloud key of the collection; names it in `documents`, `changes` and
  /// the `imported.*` flag.
  final String collection;

  /// The JSON file earlier versions kept this collection in.
  final String filePath;
  final T Function(Map<String, dynamic>) itemFromJson;

  DbRecords({required this.collection, required this.filePath, required this.itemFromJson});

  /// Every stored record, in the order they were first stored. Run inside one
  /// transaction by the callers, so entries and their lines come from the
  /// same moment.
  Future<List<Record<T>>> _selectAll(BookDatabase db);

  List<_Sql> _insertRecord(Record<T> record);

  /// Rewrites the item and the metadata of a stored record.
  List<_Sql> _updateRecord(Record<T> record);

  /// Rewrites only the metadata (order, time, deleted) of a stored record.
  List<_Sql> _updateMeta(Record<T> record);

  List<_Sql> _removeRecord(String id);

  String get _flag => 'imported.$collection';

  /// What a collection needs before its first read or write: the ledger
  /// collections wait for the migration of the old ones (it is done once per
  /// file, and by whichever isolate gets there first), then every collection
  /// imports its JSON file.
  Future<void> _prepare(BookDatabase db) async {
    if (LedgerNames.isLedger(collection)) await LedgerMigration.ensure(db);
    await ensureImported(db);
  }

  /// Every stored record, for a migration that already holds a transaction on
  /// [db].
  Future<List<Record<T>>> storedIn(BookDatabase db) => _selectAll(db);

  /// What this store last read or wrote, by id, and the database it came
  /// from. A write is measured against it: the store changes the rows it has
  /// changed since, and nothing else.
  Map<String, Record<T>>? _known;
  BookDatabase? _knownIn;

  @override
  Future<List<Record<T>>> read() async {
    final db = await BookDatabase.open();
    await _prepare(db);
    final records = await db.transaction(() => _selectAll(db));
    _remember(db, records);
    return records;
  }

  @override
  Future<void> write(List<Record<T>> records) async {
    final db = await BookDatabase.open();
    await _prepare(db);
    final known = identical(_knownIn, db) ? _known! : <String, Record<T>>{};
    final (changed, dropped) = _difference(known, records);
    if (changed.isNotEmpty || dropped.isNotEmpty) {
      await db.transaction(() => _apply(db, changed, dropped));
    }
    _remember(db, records);
  }

  void _remember(BookDatabase db, List<Record<T>> records) {
    _knownIn = db;
    _known = {for (final r in records) r.item.id: r};
  }

  /// Applies to the stored rows what [records] changed against [known] (what
  /// the caller last read): a record that is new or differs from its known
  /// version is put, an id in [known] that [records] leaves out is purged.
  /// A stored row the caller never read is left alone, and so is one that
  /// already is what would be written, so nothing is logged for it. Runs
  /// inside the transaction the caller holds. With nothing known (a caller
  /// that only adds, like the migration) nothing is purged.
  Future<void> writeIn(BookDatabase db, List<Record<T>> records, {Map<String, Record<T>> known = const {}}) async {
    final (changed, dropped) = _difference(known, records);
    await _apply(db, changed, dropped);
  }

  /// The records that differ from what [known] holds for their id, and the
  /// ids [known] holds that [records] no longer has.
  (List<Record<T>>, List<String>) _difference(Map<String, Record<T>> known, List<Record<T>> records) {
    final incoming = {for (final r in records) r.item.id: r};
    return (
      [
        for (final r in incoming.values)
          if (!_same(known[r.item.id], r)) r,
      ],
      [
        for (final id in known.keys)
          if (!incoming.containsKey(id)) id,
      ],
    );
  }

  /// Puts [changed] and purges [dropped], logging each row it really
  /// touches. If another store changed the same row meanwhile, this write
  /// wins: the later writer's version is the one that stays.
  Future<void> _apply(BookDatabase db, List<Record<T>> changed, List<String> dropped) async {
    if (changed.isEmpty && dropped.isEmpty) return;
    final stored = {for (final r in await _selectAll(db)) r.item.id: r};
    final at = DateTime.now().toUtc().toIso8601String();
    final statements = <_Sql>[];
    for (final record in changed) {
      final before = stored[record.item.id];
      final String op;
      if (before == null) {
        statements.addAll(_insertRecord(record));
        op = record.deleted ? 'delete' : 'put';
      } else {
        final sameItem = _sameItem(before.item, record.item);
        if (sameItem && _sameMeta(before, record)) continue;
        statements.addAll(sameItem ? _updateMeta(record) : _updateRecord(record));
        // A move or a re-stamp is logged without the item, which did not
        // change; only the first delete and a revival are worth a name.
        if (!sameItem) {
          op = record.deleted ? 'delete' : 'put';
        } else if (!before.deleted && record.deleted) {
          op = 'delete';
        } else if (before.deleted && !record.deleted) {
          op = 'put';
        } else {
          op = 'meta';
        }
      }
      statements.add(_log(at, op, record.item.id, op == 'put' ? jsonEncode(record.item.toJson()) : null));
    }
    for (final id in dropped) {
      if (!stored.containsKey(id)) continue;
      statements.addAll(_removeRecord(id));
      statements.add(_log(at, 'purge', id, null));
    }
    await _run(db, statements);
  }

  bool _same(Record<T>? a, Record<T> b) => a != null && _sameItem(a.item, b.item) && _sameMeta(a, b);

  bool _sameMeta(Record<T> a, Record<T> b) => a.order == b.order && a.deleted == b.deleted && _stamp(a) == _stamp(b);

  /// Folds the collection's JSON file into the database the first time it is
  /// used, the way `SyncedStore.merge` folds two copies: per id the newer
  /// `updatedAt` wins, whole, so a stored record is never half replaced.
  /// Ids, order, times and deleted flags are kept. The file is left where it
  /// is. All of it, flag included, is one transaction, so a stop half way
  /// imports nothing and the next start tries again.
  ///
  /// A file that is there but cannot be read or parsed sets no flag and
  /// throws nothing away: the collection works from what the database holds,
  /// and the import is tried again on the next start.
  Future<void> ensureImported(BookDatabase db) async {
    if (await db.hasFlag(_flag) || db.skippedImports.contains(_flag)) return;
    final legacy = await _readLegacy();
    if (legacy == null) {
      db.skippedImports.add(_flag);
      return;
    }
    final newest = <String, Record<T>>{};
    for (final record in legacy) {
      final seen = newest[record.item.id];
      if (seen == null || !seen.updatedAt.isAfter(record.updatedAt)) newest[record.item.id] = record;
    }
    await db.transaction(() async {
      if (await db.hasFlag(_flag)) return;
      final stored = {for (final r in await _selectAll(db)) r.item.id: r};
      final statements = <_Sql>[];
      var applied = 0;
      for (final record in newest.values) {
        final before = stored[record.item.id];
        if (before == null) {
          statements.addAll(_insertRecord(record));
        } else if (record.updatedAt.isAfter(before.updatedAt)) {
          statements.addAll(_updateRecord(record));
        } else {
          continue;
        }
        applied++;
      }
      statements.add(_log(DateTime.now().toUtc().toIso8601String(), 'import', '', jsonEncode({'count': applied})));
      statements.add(('INSERT INTO meta (key, value) VALUES (?, ?)', [_flag, '1']));
      await _run(db, statements);
    });
  }

  /// The records in the JSON file: empty when there is no file, null when
  /// there is one that cannot be read, which is why this catches everything.
  Future<List<Record<T>>?> _readLegacy() async {
    try {
      final json = await LocalFileStore.readJsonStrict(filePath);
      if (json == null) return const [];
      final raw = json['records'] as List<dynamic>? ?? [];
      return [for (final e in raw) Record.fromJson<T>(e as Map<String, dynamic>, itemFromJson)];
    } catch (_) {
      return null;
    }
  }

  Future<void> _run(BookDatabase db, List<_Sql> statements) async {
    if (statements.isEmpty) return;
    await db.batch((b) {
      for (final (sql, args) in statements) {
        b.customStatement(sql, args);
      }
    });
  }

  _Sql _log(String at, String op, String id, String? body) =>
      ('INSERT INTO changes (at, collection, id, op, body) VALUES (?, ?, ?, ?, ?)', [at, collection, id, op, body]);

  /// Two items are the same when they are equal, or when they write the same
  /// JSON (a date held as UTC and one read back in local time are not `==`
  /// but are one stored value).
  bool _sameItem(T a, T b) => a == b || jsonEncode(a.toJson()) == jsonEncode(b.toJson());

  /// The time as the cloud copy writes it, so it comes back exactly.
  static String _stamp(Record record) => record.updatedAt.toUtc().toIso8601String();

  static List<Object?> _meta(Record record) => [record.order, _stamp(record), record.deleted ? 1 : 0];

  /// Rebuilds the record the way `Record.fromJson` does for a JSON file.
  Record<T> _assemble(Map<String, dynamic> item, Map<String, Object?> row) {
    return Record.fromJson<T>({
      'item': item,
      'order': (row['sort'] as num).toDouble(),
      'updatedAt': row['updated_at'] as String,
      'deleted': (row['deleted'] as int) != 0,
    }, itemFromJson);
  }
}

/// Accounts, recurring payments and settings: one row each, the item's JSON
/// as the body.
class DocumentRecords<T extends Syncable> extends DbRecords<T> {
  DocumentRecords({required super.collection, required super.filePath, required super.itemFromJson});

  @override
  Future<List<Record<T>>> _selectAll(BookDatabase db) async {
    final rows = await db
        .customSelect('SELECT id, body, sort, updated_at, deleted FROM documents WHERE collection = ? ORDER BY rowid', variables: [Variable<String>(collection)])
        .get();
    return [for (final row in rows) _assemble(jsonDecode(row.data['body'] as String) as Map<String, dynamic>, row.data)];
  }

  @override
  List<_Sql> _insertRecord(Record<T> record) => [
        (
          'INSERT INTO documents (collection, id, body, sort, updated_at, deleted) VALUES (?, ?, ?, ?, ?, ?)',
          [collection, record.item.id, jsonEncode(record.item.toJson()), ...DbRecords._meta(record)],
        ),
      ];

  @override
  List<_Sql> _updateRecord(Record<T> record) => [
        (
          'UPDATE documents SET body = ?, sort = ?, updated_at = ?, deleted = ? WHERE collection = ? AND id = ?',
          [jsonEncode(record.item.toJson()), ...DbRecords._meta(record), collection, record.item.id],
        ),
      ];

  @override
  List<_Sql> _updateMeta(Record<T> record) => [
        ('UPDATE documents SET sort = ?, updated_at = ?, deleted = ? WHERE collection = ? AND id = ?', [...DbRecords._meta(record), collection, record.item.id]),
      ];

  @override
  List<_Sql> _removeRecord(String id) => [('DELETE FROM documents WHERE collection = ? AND id = ?', [collection, id])];
}

/// Entries: the keys `BookEntry.toJson` writes are columns, each line is a
/// row in `entry_lines`, and any other key goes into `extra` so it is kept
/// and comes back.
///
/// The table is shared: every row says which collection it belongs to, and
/// this store reads, compares, rewrites and purges only its own. Entry ids
/// are unique across collections (the id is the table's key), which holds for
/// the ids the app makes.
class EntryRecords extends DbRecords<BookEntry> {
  EntryRecords({required super.collection, required super.filePath}) : super(itemFromJson: BookEntry.fromJson);

  /// For a model that reads keys `BookEntry` does not.
  @visibleForTesting
  EntryRecords.forTesting({required super.collection, required super.filePath, required super.itemFromJson});

  /// `BookEntry.toJson` key and the column that holds it.
  static const List<(String, String)> _textColumns = [
    ('date', 'date'),
    ('postedDate', 'posted_date'),
    ('template', 'template'),
    ('status', 'status'),
    ('base', 'base_currency'),
    ('merchant', 'merchant'),
    ('rawMerchant', 'raw_merchant'),
    ('note', 'note'),
    ('source', 'source'),
  ];

  /// `EntryLine.toJson` key, column and whether the value is a number.
  static const List<(String, String, bool)> _lineColumns = [
    ('account', 'account_id', false),
    ('amount', 'amount', true),
    ('currency', 'currency', false),
    ('base', 'base_amount', true),
  ];

  /// The keys of a holding line that have a column. A line without them has
  /// null there; one with a value of another type keeps it in `extra`.
  static const List<(String, String, bool)> _optionalLineColumns = [
    ('qty', 'quantity', true),
    ('commodity', 'commodity', false),
  ];

  @override
  Future<List<Record<BookEntry>>> _selectAll(BookDatabase db) async {
    final lineRows = await db
        .customSelect(
          'SELECT l.entry_id, l.idx, l.account_id, l.amount, l.currency, l.base_amount, l.quantity, l.commodity, l.extra '
          'FROM entry_lines l JOIN entries e ON e.id = l.entry_id WHERE e.collection = ? ORDER BY l.entry_id, l.idx',
          variables: [Variable<String>(collection)],
        )
        .get();
    final linesByEntry = <String, List<Map<String, dynamic>>>{};
    for (final row in lineRows) {
      final data = row.data;
      linesByEntry.putIfAbsent(data['entry_id'] as String, () => []).add({
        for (final (key, column, _) in _lineColumns) key: data[column],
        for (final (key, column, _) in _optionalLineColumns)
          if (data[column] != null) key: data[column],
        ..._decode(data['extra']),
      });
    }
    final rows = await db.customSelect('SELECT * FROM entries WHERE collection = ? ORDER BY rowid', variables: [Variable<String>(collection)]).get();
    return [
      for (final row in rows)
        () {
          final data = row.data;
          final id = data['id'] as String;
          final item = <String, dynamic>{'id': id};
          for (final (key, column) in _textColumns) {
            final value = data[column];
            if (value != null) item[key] = value;
          }
          item['lines'] = linesByEntry[id] ?? <Map<String, dynamic>>[];
          item.addAll(_decode(data['extra']));
          return _assemble(item, data);
        }(),
    ];
  }

  @override
  List<_Sql> _insertRecord(Record<BookEntry> record) {
    final (values, extra, lines) = _split(record.item.toJson());
    return [
      (
        'INSERT INTO entries (id, collection, date, posted_date, template, status, base_currency, merchant, raw_merchant, note, source, extra, sort, updated_at, deleted) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [record.item.id, collection, ...values, extra, ...DbRecords._meta(record)],
      ),
      ..._lineStatements(record.item.id, lines),
    ];
  }

  @override
  List<_Sql> _updateRecord(Record<BookEntry> record) {
    final (values, extra, lines) = _split(record.item.toJson());
    return [
      (
        'UPDATE entries SET date = ?, posted_date = ?, template = ?, status = ?, base_currency = ?, merchant = ?, raw_merchant = ?, note = ?, source = ?, extra = ?, '
            'sort = ?, updated_at = ?, deleted = ? WHERE id = ? AND collection = ?',
        [...values, extra, ...DbRecords._meta(record), record.item.id, collection],
      ),
      ('DELETE FROM entry_lines WHERE entry_id = ?', [record.item.id]),
      ..._lineStatements(record.item.id, lines),
    ];
  }

  @override
  List<_Sql> _updateMeta(Record<BookEntry> record) => [
        ('UPDATE entries SET sort = ?, updated_at = ?, deleted = ? WHERE id = ? AND collection = ?', [...DbRecords._meta(record), record.item.id, collection]),
      ];

  @override
  List<_Sql> _removeRecord(String id) => [
        ('DELETE FROM entry_lines WHERE entry_id = ?', [id]),
        ('DELETE FROM entries WHERE id = ? AND collection = ?', [id, collection]),
      ];

  List<_Sql> _lineStatements(String entryId, List<List<Object?>> lines) => [
        for (final (i, line) in lines.indexed)
          ('INSERT INTO entry_lines (entry_id, idx, account_id, amount, currency, base_amount, quantity, commodity, extra) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)', [entryId, i, ...line]),
      ];

  /// Splits an entry's JSON into the column values, the leftover keys and the
  /// line rows. A key whose value is not the type its column holds stays in
  /// `extra`, so the round trip is exact whatever the model wrote.
  (List<Object?>, String?, List<List<Object?>>) _split(Map<String, dynamic> json) {
    final rest = Map<String, dynamic>.of(json)..remove('id');
    final values = <Object?>[];
    for (final (key, _) in _textColumns) {
      final value = rest[key];
      if (value is String && _storable(value)) {
        values.add(value);
        rest.remove(key);
      } else {
        values.add(null);
      }
    }
    final lines = _splitLines(rest['lines']);
    if (lines != null) rest.remove('lines');
    return (values, rest.isEmpty ? null : jsonEncode(rest), lines ?? const []);
  }

  /// One row per line (account, amount, currency, base amount, quantity,
  /// commodity, extra), or null when a line does not fit the columns, in which
  /// case the entry keeps `lines` whole in its own `extra`.
  List<List<Object?>>? _splitLines(Object? lines) {
    if (lines is! List) return null;
    final out = <List<Object?>>[];
    for (final line in lines) {
      if (line is! Map) return null;
      final rest = Map<String, dynamic>.of(line.cast<String, dynamic>());
      final row = <Object?>[];
      for (final (key, _, numeric) in _lineColumns) {
        final value = rest.remove(key);
        if (numeric ? value is! int : (value is! String || !_storable(value))) return null;
        row.add(value);
      }
      for (final (key, _, numeric) in _optionalLineColumns) {
        final value = rest[key];
        if (numeric ? value is int : (value is String && _storable(value))) {
          row.add(value);
          rest.remove(key);
        } else {
          row.add(null);
        }
      }
      row.add(rest.isEmpty ? null : jsonEncode(rest));
      out.add(row);
    }
    return out;
  }

  Map<String, dynamic> _decode(Object? extra) => extra == null ? const {} : jsonDecode(extra as String) as Map<String, dynamic>;

  /// Whether SQLite returns [text] exactly as it was given. A lone surrogate
  /// comes back as the replacement character and a NUL cuts the text short;
  /// `jsonEncode` escapes both, so such text is kept in `extra`.
  static bool _storable(String text) {
    for (var i = 0; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      if (unit == 0) return false;
      if (unit >= 0xD800 && unit <= 0xDBFF) {
        final next = i + 1 < text.length ? text.codeUnitAt(i + 1) : 0;
        if (next < 0xDC00 || next > 0xDFFF) return false;
        i++;
      } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
        return false;
      }
    }
    return true;
  }
}
