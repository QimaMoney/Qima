import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../local_file_store.dart';

/// The money book's SQLite file. Hand-written on purpose: the schema is a few
/// raw statements, so there is nothing to generate, and every query goes
/// through `customSelect` / `customStatement`.
class BookDatabase extends GeneratedDatabase {
  static const String fileName = 'book.sqlite';

  static final Map<String, _Slot> _open = {};
  static bool _configured = false;

  /// Replaces how the file is opened, so a test can run the executor the app
  /// uses. Null picks the default, see [_executorFor].
  @visibleForTesting
  static QueryExecutor Function(File file)? executorOverride;

  final String path;

  /// Collections whose JSON file could not be read this run. The import is
  /// tried again on the next start, not on every operation.
  final Set<String> skippedImports = {};

  /// The ledger migration of this file, once something in this isolate has
  /// asked for it (see `LedgerMigration.ensure`).
  Future<void>? ledgerMigration;

  /// Whether the ledger migration also runs step B, the collapse of holdings
  /// trades into book entries. Always on in the app; a test of the migration
  /// itself turns it off to run the steps one at a time.
  bool collapseHoldings = true;

  /// A step of the ledger migration that did not finish this run, and why.
  /// It is tried again on the next start; the book works meanwhile.
  final Map<String, Object> ledgerProblems = {};

  BookDatabase._(super.executor, this.path);

  /// The database in the directory `LocalFileStore` uses, opened once per
  /// file. A test that points `LocalFileStore` at a new directory gets a new
  /// database; the old one stays open until [closeAll].
  ///
  /// A handle to a file that has since been deleted would only report a
  /// read-only database, so it is closed and the file is opened afresh.
  static Future<BookDatabase> open() async {
    final path = _pathIn(await LocalFileStore.directoryPath());
    while (true) {
      final slot = _open[path];
      if (slot == null) break;
      await slot.opened;
      if (File(path).existsSync()) return slot.db;
      if (identical(_open[path], slot)) {
        _open.remove(path);
        await slot.db.close();
      }
    }
    if (!_configured) {
      // Each file has its own instance on purpose, so drift's warning about
      // creating the class twice does not apply.
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      _configured = true;
    }
    final db = BookDatabase._((executorOverride ?? _executorFor)(File(path)), path);
    // Opening creates the file and the schema; later callers wait for it.
    final slot = _Slot(db, db.customSelect('SELECT 1').get().then((_) {}));
    _open[path] = slot;
    try {
      await slot.opened;
    } catch (_) {
      if (identical(_open[path], slot)) _open.remove(path);
      try {
        await db.close();
      } catch (_) {
        // The open already failed; that error is the one to report, and
        // closing is only to release the handle and the isolate.
      }
      rethrow;
    }
    return db;
  }

  static String _pathIn(String directory) => File('$directory/$fileName').absolute.path;

  /// Widget tests run under fake async, where work on another isolate never
  /// completes, so they open the file in this isolate. The app opens it on a
  /// background isolate so the interface never waits on disk.
  static QueryExecutor _executorFor(File file) => executorFor(file, inBackground: !Platform.environment.containsKey('FLUTTER_TEST'));

  /// The executor the app uses, in this isolate or on a background one. A
  /// test can pick either, whichever the environment would not.
  @visibleForTesting
  static QueryExecutor executorFor(File file, {required bool inBackground}) =>
      inBackground ? NativeDatabase.createInBackground(file, setup: _configure) : NativeDatabase(file, setup: _configure);

  /// Runs on every connection the moment the file is opened, before any
  /// migration: a second process (a background task) or isolate may hold the
  /// file for a moment, and the migration must wait for it, not fail. A top
  /// level or static function, so it can be sent to the background isolate;
  /// `database` is the sqlite3 handle, which this library does not import.
  static void _configure(dynamic database) => database.execute(_busyTimeout);

  static const String _busyTimeout = 'PRAGMA busy_timeout = 5000';

  static Future<void> closeAll() async {
    final all = _open.values.toList();
    _open.clear();
    for (final slot in all) {
      await slot.db.close();
    }
  }

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];

  @override
  int get schemaVersion => 2;

  // drift runs onCreate and onUpgrade outside a transaction and only records
  // the new version once they return, so each runs in a transaction of its own
  // here: a stop half way leaves the file as it was. A step is also skipped
  // when it has already been done, so the next start (or another isolate that
  // read the old version at the same moment and waited for this one) can run
  // it again without failing. A later version adds its own step to
  // onUpgrade; without one drift would carry on at the new version unmigrated.
  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => transaction(() async {
          for (final statement in _schemaV1) {
            await customStatement(statement);
          }
          await _upgradeToV2();
        }),
        onUpgrade: (m, from, to) {
          // A file from a later build is never opened by this one: it would
          // be stamped back to this version with its newer shape unread.
          if (from > to) throw StateError('The book database is version $from; this build reads up to version $to. Update the app.');
          return transaction(() async {
            if (from < 2) await _upgradeToV2();
          });
        },
        // The setup of the connection has set this already; this is for an
        // executor that was opened without it.
        beforeOpen: (details) => customStatement(_busyTimeout),
      );

  /// Entries get a collection (so a second store can share the table) and
  /// lines get the quantity of a holding. Moves no data: every row that is
  /// already there is in 'book.entries'.
  Future<void> _upgradeToV2() async {
    for (final (table, column, definition) in _schemaV2Columns) {
      final present = await customSelect('SELECT 1 FROM pragma_table_info(?) WHERE name = ?', variables: [Variable<String>(table), Variable<String>(column)]).get();
      if (present.isEmpty) await customStatement('ALTER TABLE $table ADD COLUMN $column $definition');
    }
    for (final statement in _schemaV2Indexes) {
      await customStatement(statement);
    }
  }

  Future<bool> hasFlag(String key) async {
    final rows = await customSelect('SELECT 1 FROM meta WHERE key = ?', variables: [Variable<String>(key)]).get();
    return rows.isNotEmpty;
  }

  // Every statement is safe to run on a file that already has its result: two
  // isolates opening a new file at once both create it, one after the other.
  static const List<String> _schemaV1 = [
    'CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)',
    // One row per entry. The columns are the keys BookEntry.toJson writes; a
    // key with no column (or with a value a column would not return
    // unchanged) is kept in `extra`, so nothing a model writes is ever
    // dropped.
    '''CREATE TABLE IF NOT EXISTS entries (
      id TEXT PRIMARY KEY NOT NULL,
      date TEXT,
      posted_date TEXT,
      template TEXT,
      status TEXT,
      base_currency TEXT,
      merchant TEXT,
      raw_merchant TEXT,
      note TEXT,
      source TEXT,
      extra TEXT,
      sort REAL NOT NULL,
      updated_at TEXT NOT NULL,
      deleted INTEGER NOT NULL DEFAULT 0
    )''',
    'CREATE INDEX IF NOT EXISTS entries_date ON entries (date)',
    '''CREATE TABLE IF NOT EXISTS entry_lines (
      entry_id TEXT NOT NULL,
      idx INTEGER NOT NULL,
      account_id TEXT NOT NULL,
      amount INTEGER NOT NULL,
      currency TEXT NOT NULL,
      base_amount INTEGER NOT NULL,
      extra TEXT,
      PRIMARY KEY (entry_id, idx)
    )''',
    'CREATE INDEX IF NOT EXISTS entry_lines_account ON entry_lines (account_id)',
    // Accounts, recurring payments and settings: the item's JSON as the body.
    '''CREATE TABLE IF NOT EXISTS documents (
      collection TEXT NOT NULL,
      id TEXT NOT NULL,
      body TEXT NOT NULL,
      sort REAL NOT NULL,
      updated_at TEXT NOT NULL,
      deleted INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (collection, id)
    )''',
    // Append-only, one row for every record a write put, deleted, moved
    // (`meta`) or purged. Left unbounded for now: a later phase reads it and
    // compacts it.
    '''CREATE TABLE IF NOT EXISTS changes (
      seq INTEGER PRIMARY KEY AUTOINCREMENT,
      at TEXT NOT NULL,
      collection TEXT NOT NULL,
      id TEXT NOT NULL,
      op TEXT NOT NULL,
      body TEXT
    )''',
  ];

  /// Table, column and definition, added to a file that has the v1 schema.
  static const List<(String, String, String)> _schemaV2Columns = [
    ('entries', 'collection', "TEXT NOT NULL DEFAULT 'book.entries'"),
    // A signed count of 1e-8 of the commodity's unit; the line's other facts
    // of a holding (unit, karat, price, fee) are kept in `extra`.
    ('entry_lines', 'quantity', 'INTEGER'),
    ('entry_lines', 'commodity', 'TEXT'),
  ];

  static const List<String> _schemaV2Indexes = [
    'CREATE INDEX IF NOT EXISTS entries_collection ON entries (collection)',
    'CREATE INDEX IF NOT EXISTS entry_lines_commodity ON entry_lines (commodity) WHERE commodity IS NOT NULL',
  ];
}

/// A registered database and the moment it is open and its schema is in place.
class _Slot {
  final BookDatabase db;
  final Future<void> opened;

  _Slot(this.db, this.opened);
}
