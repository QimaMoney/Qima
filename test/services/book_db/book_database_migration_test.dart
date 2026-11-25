import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qima/services/book_db/book_database.dart';
import 'package:qima/services/book_db/db_records.dart';
import 'package:qima/services/local_file_store.dart';

/// The statements of schema version 1, as the first release wrote them. Kept
/// here as they were, so the upgrade is tested against the real old file.
const List<String> _v1 = [
  'CREATE TABLE meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)',
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
  '''CREATE TABLE documents (
      collection TEXT NOT NULL,
      id TEXT NOT NULL,
      body TEXT NOT NULL,
      sort REAL NOT NULL,
      updated_at TEXT NOT NULL,
      deleted INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (collection, id)
    )''',
  '''CREATE TABLE changes (
      seq INTEGER PRIMARY KEY AUTOINCREMENT,
      at TEXT NOT NULL,
      collection TEXT NOT NULL,
      id TEXT NOT NULL,
      op TEXT NOT NULL,
      body TEXT
    )''',
];

/// Rows of a file as the first release left it.
const List<String> _v1Rows = [
  "INSERT INTO meta (key, value) VALUES ('imported.book.entries', '1')",
  "INSERT INTO entries (id, date, template, base_currency, merchant, sort, updated_at, deleted) VALUES ('e1', '2026-11-08T09:30:00.000Z', 'spend', 'SAR', 'Cafe', 1.5, '2026-11-08T10:00:00.000000Z', 0)",
  "INSERT INTO entry_lines (entry_id, idx, account_id, amount, currency, base_amount, extra) VALUES ('e1', 0, 'category.food', 1250, 'SAR', 1250, NULL)",
  "INSERT INTO entry_lines (entry_id, idx, account_id, amount, currency, base_amount, extra) VALUES ('e1', 1, 'account.cash', -1250, 'SAR', -1250, '{\"memo\":\"x\"}')",
  "INSERT INTO documents (collection, id, body, sort, updated_at, deleted) VALUES ('book.accounts', 'a1', '{\"id\":\"a1\"}', 0, '2026-11-08T10:00:00.000000Z', 0)",
  "INSERT INTO changes (at, collection, id, op, body) VALUES ('2026-11-08T10:00:00.000000Z', 'book.entries', 'e1', 'put', NULL)",
];

/// A database with no tables of its own, to read and write a file directly.
class _Plain extends GeneratedDatabase {
  _Plain(super.executor, {this.version = 1});

  final int version;

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];

  @override
  int get schemaVersion => version;
}

/// Opens [file] as a file the first release made: the given statements run
/// as the connection opens, then the version says 1.
Future<void> writeV1(File file, {List<String> statements = _v1, List<String> rows = const []}) async {
  final plain = _Plain(NativeDatabase(file, setup: (raw) {
    for (final s in [...statements, ...rows]) {
      raw.execute(s);
    }
    raw.execute('PRAGMA user_version = 1');
  }));
  await plain.customSelect('SELECT 1').get();
  await plain.close();
}

/// Holds the file's write lock for [hold], from another isolate, and returns
/// once it has it.
Future<Future<void>> holdWriteLock(File file, Duration hold) async {
  final marker = File('${file.path}.locked');
  final done = Isolate.run(() async {
    final plain = _Plain(NativeDatabase(file));
    await plain.customStatement('BEGIN IMMEDIATE');
    marker.writeAsStringSync('held');
    sleep(hold);
    await plain.customStatement('COMMIT');
    await plain.close();
  });
  while (!marker.existsSync()) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return done;
}

/// Opens the book database in [dir] from another isolate, as a second
/// process of the app would, and reports what it found.
Future<String> openElsewhere(String dir) => Isolate.run(() async {
      LocalFileStore.overrideDirectoryForTesting(Directory(dir));
      try {
        final db = await BookDatabase.open();
        final version = (await db.customSelect('PRAGMA user_version').getSingle()).data.values.first;
        await BookDatabase.closeAll();
        return 'ok $version';
      } catch (e) {
        return 'failed $e';
      }
    });

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('qima_book_migration');
    LocalFileStore.overrideDirectoryForTesting(dir);
    file = File('${dir.path}/${BookDatabase.fileName}');
  });

  tearDown(() async {
    await BookDatabase.closeAll();
    BookDatabase.executorOverride = null;
    await dir.delete(recursive: true);
  });

  Future<List<String>> names(BookDatabase db, String sql) async => [for (final r in await db.customSelect(sql).get()) r.data.values.first as String];
  Future<List<String>> columns(BookDatabase db, String table) => names(db, "SELECT name FROM pragma_table_info('$table') ORDER BY cid");
  Future<int> version(BookDatabase db) async => (await db.customSelect('PRAGMA user_version').getSingle()).data.values.first as int;
  Future<int> count(BookDatabase db, String sql) async => (await db.customSelect(sql).getSingle()).data.values.first as int;

  const v2Columns = ['collection'];
  const v2LineColumns = ['quantity', 'commodity'];

  group('a new file', () {
    test('gets the version 1 tables and the version 2 columns and indexes', () async {
      final db = await BookDatabase.open();
      expect(await version(db), 2);
      expect(await columns(db, 'entries'), containsAll(['id', 'date', 'extra', 'deleted', ...v2Columns]));
      expect(await columns(db, 'entry_lines'), containsAll(['entry_id', 'base_amount', 'extra', ...v2LineColumns]));
      expect(await names(db, "SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%'"),
          unorderedEquals(['entries_date', 'entries_collection', 'entry_lines_account', 'entry_lines_commodity']));
      expect(await names(db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"), ['changes', 'documents', 'entries', 'entry_lines', 'meta']);
    });

    test('puts a new entry in book.entries unless told otherwise', () async {
      final db = await BookDatabase.open();
      await db.customStatement("INSERT INTO entries (id, sort, updated_at) VALUES ('x', 0, 'x')");
      expect(await names(db, "SELECT collection FROM entries WHERE id = 'x'"), ['book.entries']);
    });

    test('waits for the lock like every other connection', () async {
      final db = await BookDatabase.open();
      expect(await count(db, 'PRAGMA busy_timeout'), 5000);
    });

    test('several isolates creating the same new file at once all get through', () async {
      final results = await Future.wait([for (var i = 0; i < 4; i++) openElsewhere(dir.path), BookDatabase.open().then((db) async => 'ok ${await version(db)}')]);
      expect(results, everyElement('ok 2'));
      final db = await BookDatabase.open();
      expect(await names(db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"), ['changes', 'documents', 'entries', 'entry_lines', 'meta']);
    });
  });

  group('upgrading a version 1 file', () {
    test('keeps every row, and the records read back as they did', () async {
      await writeV1(file, rows: _v1Rows);
      final db = await BookDatabase.open();
      expect(await version(db), 2);
      expect(await columns(db, 'entries'), containsAll(v2Columns));
      expect(await columns(db, 'entry_lines'), containsAll(v2LineColumns));
      expect(await count(db, 'SELECT count(*) FROM entries'), 1);
      expect(await count(db, 'SELECT count(*) FROM entry_lines'), 2);
      expect(await count(db, 'SELECT count(*) FROM documents'), 1);
      expect(await count(db, 'SELECT count(*) FROM changes'), 1);
      expect(await count(db, 'SELECT count(*) FROM meta'), 1);
      expect(await names(db, 'SELECT collection FROM entries'), ['book.entries']);
      expect(await count(db, 'SELECT count(*) FROM entry_lines WHERE quantity IS NOT NULL OR commodity IS NOT NULL'), 0);

      final back = await EntryRecords(collection: 'book.entries', filePath: 'book.entries.json').read();
      final entry = back.single.item;
      expect(entry.merchant, 'Cafe');
      expect(entry.lines.map((l) => (l.accountId, l.amount, l.currency, l.baseAmount, l.quantity, l.commodity)), [('category.food', 1250, 'SAR', 1250, null, null), ('account.cash', -1250, 'SAR', -1250, null, null)]);
      expect(back.single.order, 1.5);
      expect(jsonEncode(entry.toJson()['lines']), '[{"account":"category.food","amount":1250,"currency":"SAR","base":1250},{"account":"account.cash","amount":-1250,"currency":"SAR","base":-1250}]');
      expect(await names(db, "SELECT extra FROM entry_lines WHERE entry_id = 'e1' AND idx = 1"), ['{"memo":"x"}']);
    });

    test('run again over the same file changes nothing', () async {
      await writeV1(file, rows: _v1Rows);
      var db = await BookDatabase.open();
      final before = [await columns(db, 'entries'), await columns(db, 'entry_lines')];
      await db.customStatement('PRAGMA user_version = 1');
      await BookDatabase.closeAll();

      db = await BookDatabase.open();
      expect(await version(db), 2);
      expect([await columns(db, 'entries'), await columns(db, 'entry_lines')], before);
      expect(await count(db, 'SELECT count(*) FROM entries'), 1);
    });

    test('finishes a file whose upgrade stopped after some of its steps', () async {
      for (final done in [
        ["ALTER TABLE entries ADD COLUMN collection TEXT NOT NULL DEFAULT 'book.entries'"],
        ["ALTER TABLE entries ADD COLUMN collection TEXT NOT NULL DEFAULT 'book.entries'", 'ALTER TABLE entry_lines ADD COLUMN quantity INTEGER'],
        [
          "ALTER TABLE entries ADD COLUMN collection TEXT NOT NULL DEFAULT 'book.entries'",
          'ALTER TABLE entry_lines ADD COLUMN quantity INTEGER',
          'ALTER TABLE entry_lines ADD COLUMN commodity TEXT',
          'CREATE INDEX entries_collection ON entries (collection)',
        ],
      ]) {
        await BookDatabase.closeAll();
        if (file.existsSync()) file.deleteSync();
        await writeV1(file, statements: [..._v1, ...done], rows: _v1Rows);
        final db = await BookDatabase.open();
        expect(await version(db), 2, reason: done.last);
        expect(await columns(db, 'entries'), containsAll(v2Columns));
        expect(await columns(db, 'entry_lines'), containsAll(v2LineColumns));
        expect(await names(db, "SELECT name FROM sqlite_master WHERE type = 'index' AND name IN ('entries_collection', 'entry_lines_commodity')"), hasLength(2));
        expect(await names(db, 'SELECT collection FROM entries'), ['book.entries']);
      }
    });

    test('a file from a later schema is refused and left as it was', () async {
      await writeV1(file, rows: _v1Rows);
      final plain = _Plain(NativeDatabase(file));
      await plain.customStatement('PRAGMA user_version = 3');
      await plain.close();
      final before = file.readAsBytesSync();

      await expectLater(BookDatabase.open(), throwsA(isA<StateError>().having((e) => e.message, 'message', contains('version 3'))));
      await BookDatabase.closeAll();
      expect(file.readAsBytesSync(), before);

      final again = _Plain(NativeDatabase(file), version: 3);
      addTearDown(again.close);
      expect((await again.customSelect('PRAGMA user_version').getSingle()).data.values.first, 3);
      expect(await again.customSelect("SELECT name FROM pragma_table_info('entries') WHERE name = 'collection'").get(), isEmpty);
    });

    test('a step that fails leaves the file as it was, and the version at 1', () async {
      // No entry_lines table: the first ALTER works and the second cannot.
      await writeV1(file, statements: [for (final s in _v1) if (!s.contains('entry_lines')) s], rows: [_v1Rows.first]);
      await expectLater(BookDatabase.open(), throwsA(anything));
      await BookDatabase.closeAll();

      final plain = _Plain(NativeDatabase(file));
      addTearDown(plain.close);
      expect(await plain.customSelect("SELECT name FROM pragma_table_info('entries')").get().then((r) => r.map((x) => x.data['name'])), isNot(contains('collection')));
      expect((await plain.customSelect('PRAGMA user_version').getSingle()).data.values.first, 1);
    });

    for (final inBackground in [false, true]) {
      test('waits for another process that holds the file${inBackground ? ', on the background isolate' : ''}', () async {
        BookDatabase.executorOverride = (f) => BookDatabase.executorFor(f, inBackground: inBackground);
        await writeV1(file, rows: _v1Rows);
        final released = await holdWriteLock(file, const Duration(milliseconds: 700));
        final db = await BookDatabase.open();
        await released;
        expect(await version(db), 2);
        expect(await columns(db, 'entries'), containsAll(v2Columns));
        expect(await count(db, 'SELECT count(*) FROM entries'), 1);
      });
    }

    test('several isolates upgrading the same file at once all get through', () async {
      await writeV1(file, rows: _v1Rows);
      final results = await Future.wait([for (var i = 0; i < 4; i++) openElsewhere(dir.path), BookDatabase.open().then((db) async => 'ok ${await version(db)}')]);
      expect(results, everyElement('ok 2'));
      final db = await BookDatabase.open();
      expect(await columns(db, 'entries').then((c) => c.where((n) => n == 'collection')), ['collection']);
      expect(await columns(db, 'entry_lines').then((c) => c.where((n) => n == 'quantity' || n == 'commodity')), ['quantity', 'commodity']);
      expect(await count(db, 'SELECT count(*) FROM entries'), 1);
    });
  });
}
