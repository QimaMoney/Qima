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
  static QueryExecutor _executorFor(File file) {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return NativeDatabase(file);
    return NativeDatabase.createInBackground(file);
  }

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
  int get schemaVersion => 1;

  // No onUpgrade: drift's default throws when the version moves without a
  // step written for it, which is what a missed migration should do.
  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          for (final statement in _schemaV1) {
            await customStatement(statement);
          }
        },
        // A second process (a background task) may hold the file for a moment.
        beforeOpen: (details) => customStatement('PRAGMA busy_timeout = 5000'),
      );

  Future<bool> hasFlag(String key) async {
    final rows = await customSelect('SELECT 1 FROM meta WHERE key = ?', variables: [Variable<String>(key)]).get();
    return rows.isNotEmpty;
  }

  static const List<String> _schemaV1 = [
    'CREATE TABLE meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)',
    // One row per entry. The columns are the keys BookEntry.toJson writes; a
    // key with no column (or with a value a column would not return
    // unchanged) is kept in `extra`, so nothing a model writes is ever
    // dropped.
    '''CREATE TABLE entries (
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
    'CREATE INDEX entries_date ON entries (date)',
    '''CREATE TABLE entry_lines (
      entry_id TEXT NOT NULL,
      idx INTEGER NOT NULL,
      account_id TEXT NOT NULL,
      amount INTEGER NOT NULL,
      currency TEXT NOT NULL,
      base_amount INTEGER NOT NULL,
      extra TEXT,
      PRIMARY KEY (entry_id, idx)
    )''',
    'CREATE INDEX entry_lines_account ON entry_lines (account_id)',
    // Accounts, recurring payments and settings: the item's JSON as the body.
    '''CREATE TABLE documents (
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
    '''CREATE TABLE changes (
      seq INTEGER PRIMARY KEY AUTOINCREMENT,
      at TEXT NOT NULL,
      collection TEXT NOT NULL,
      id TEXT NOT NULL,
      op TEXT NOT NULL,
      body TEXT
    )''',
  ];
}

/// A registered database and the moment it is open and its schema is in place.
class _Slot {
  final BookDatabase db;
  final Future<void> opened;

  _Slot(this.db, this.opened);
}
