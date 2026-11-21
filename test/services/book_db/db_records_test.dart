import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/asset.dart';
import 'package:qima/models/book_account.dart';
import 'package:qima/models/book_entry.dart';
import 'package:qima/services/book_db/book_database.dart';
import 'package:qima/services/book_db/db_records.dart';
import 'package:qima/services/book_store.dart';
import 'package:qima/services/cloud_kv_store.dart';
import 'package:qima/services/local_file_store.dart';
import 'package:qima/services/synced_store.dart';

/// An entry that keeps the JSON it was read from and writes it back, so a key
/// the model has no field for (one a later version adds) can be followed
/// through the database.
class _RawEntry extends BookEntry {
  final Map<String, dynamic> raw;

  _RawEntry(this.raw, BookEntry e)
      : super(id: e.id, date: e.date, template: e.template, baseCurrency: e.baseCurrency, lines: e.lines, postedDate: e.postedDate, status: e.status, merchant: e.merchant);

  factory _RawEntry.fromJson(Map<String, dynamic> json) => _RawEntry(json, BookEntry.fromJson(json));

  @override
  Map<String, dynamic> toJson() => raw;

  @override
  List<Object?> get props => [...super.props, jsonEncode(raw)];
}

/// A cloud copy that holds whatever was last set, like iCloud's key-value store.
class _MemoryCloud implements CloudKVStore {
  final Map<String, String> values = {};

  @override
  Future<String?> getString(String key) async => values[key];

  @override
  Future<void> setString(String key, String value) async => values[key] = value;

  @override
  Future<void> synchronize() async {}

  @override
  Future<bool> accountStatus() async => true;

  @override
  Stream<CloudKVChangeEvent> get didChangeExternally => const Stream.empty();
}

BookEntry _entry(String id, {int amount = 1250, String merchant = '', DateTime? date, EntryStatus status = EntryStatus.posted, int lines = 2}) {
  final spread = [
    EntryLine(accountId: 'category.food', amount: amount, currency: 'SAR', baseAmount: amount),
    for (var i = 2; i < lines; i++) EntryLine(accountId: 'cat$i', amount: 1, currency: 'SAR', baseAmount: 1),
  ];
  final sum = spread.fold<int>(0, (a, l) => a + l.amount);
  return BookEntry(
    id: id,
    date: date ?? DateTime.utc(2026, 11, 8, 9, 30).toLocal(),
    template: EntryTemplate.spend,
    baseCurrency: 'SAR',
    status: status,
    merchant: merchant,
    lines: [...spread, EntryLine(accountId: 'account.cash', amount: -sum, currency: 'SAR', baseAmount: -sum)],
  );
}

Record<BookEntry> _record(BookEntry e, {double order = 0, DateTime? at, bool deleted = false}) =>
    Record<BookEntry>(item: e, order: order, updatedAt: at ?? DateTime.utc(2026, 11, 8, 10, 11, 12, 123, 456), deleted: deleted);

void main() {
  late Directory dir;
  late EntryRecords entries;
  late BookDatabase db;

  Future<int> count(String sql) async => (await db.customSelect(sql).getSingle()).data.values.first as int;
  Future<List<String>> ops() async => [for (final r in await db.customSelect('SELECT op || \':\' || id AS x FROM changes ORDER BY seq').get()) r.data['x'] as String];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('qima_book_db');
    LocalFileStore.overrideDirectoryForTesting(dir);
    entries = EntryRecords(collection: 'book.entries', filePath: 'book.entries.json');
    db = await BookDatabase.open();
  });

  tearDown(() async {
    await BookDatabase.closeAll();
    await dir.delete(recursive: true);
  });

  group('round trip', () {
    test('every field, the exact time and order, and a tombstone come back', () async {
      final full = BookEntry(
        id: 'e1',
        date: DateTime.utc(2026, 11, 8, 9, 30).toLocal(),
        postedDate: DateTime.utc(2026, 11, 9).toLocal(),
        template: EntryTemplate.cardPayment,
        status: EntryStatus.pending,
        baseCurrency: 'SAR',
        merchant: 'Cafe',
        rawMerchant: 'CAFE 123 RIYADH',
        note: 'with Sam',
        source: EntrySource.import,
        lines: const [
          EntryLine(accountId: 'a', amount: 1000, currency: 'USD', baseAmount: 3750),
          EntryLine(accountId: 'b', amount: -1000, currency: 'USD', baseAmount: -3750),
        ],
      );
      final at = DateTime.utc(2026, 11, 8, 10, 11, 12, 123, 456);
      final records = [
        _record(full, order: 2.5, at: at),
        _record(_entry('e2'), order: -1000.25, deleted: true),
        _record(_entry('e3', lines: 3), order: 7),
      ];
      await entries.write(records);

      final back = await entries.read();
      expect(back.map((r) => r.item), records.map((r) => r.item));
      expect(back.map((r) => r.order), [2.5, -1000.25, 7]);
      expect(back.first.updatedAt.toUtc().toIso8601String(), at.toIso8601String());
      expect(back.first.updatedAt, DateTime.parse(at.toIso8601String()));
      expect(back.map((r) => r.deleted), [false, true, false]);
      expect(back.map((r) => r.toJson()), records.map((r) => Record.fromJson(r.toJson(), BookEntry.fromJson).toJson()));
      expect(await count('SELECT count(*) FROM entry_lines'), 7);
    });

    test('a key with no column, on the entry or on a line, is kept and comes back', () async {
      final raw = _entry('e1').toJson()
        ..['futureField'] = {'a': [1, 2.5, null], 'b': 'x'}
        ..['note'] = null;
      (raw['lines'] as List<Map<String, dynamic>>)[0]['memo'] = 'split';
      final withExtra = EntryRecords.forTesting(collection: 'book.entries', filePath: 'book.entries.json', itemFromJson: _RawEntry.fromJson);
      await withExtra.write([_record(_RawEntry(raw, BookEntry.fromJson(raw)))]);

      final back = (await withExtra.read()).single.item.toJson();
      expect(back, raw);
      final stored = await db.customSelect('SELECT extra FROM entries').getSingle();
      expect(jsonDecode(stored.data['extra'] as String), {'futureField': raw['futureField'], 'note': null});
      expect(await count("SELECT count(*) FROM entry_lines WHERE extra = '{\"memo\":\"split\"}'"), 1);
    });

    test('lines that do not fit the columns stay whole in the entry', () async {
      final raw = _entry('e1').toJson();
      raw['lines'] = [
        {'account': 'a', 'amount': 'ten', 'currency': 'SAR', 'base': 10},
      ];
      final withExtra = EntryRecords.forTesting(collection: 'book.entries', filePath: 'book.entries.json', itemFromJson: (json) => _RawEntry(json, _entry('e1')));
      await withExtra.write([_record(_RawEntry(raw, _entry('e1')))]);
      expect((await withExtra.read()).single.item.toJson(), raw);
      expect(await count('SELECT count(*) FROM entry_lines'), 0);
    });

    test('text that is not well formed is kept exactly and never rewritten', () async {
      const cut = 'cut \ud83d';
      final cloud = _MemoryCloud();
      final store = SyncedStore<BookEntry>(filePath: 'book.entries.json', cloudKey: 'book.entries', itemFromJson: BookEntry.fromJson, cloud: cloud, local: entries);
      await store.upsert(_entry('e1', merchant: cut));
      expect((await store.load()).single.merchant, cut);
      expect((await entries.read()).single.item.merchant, cut);

      final logged = await count('SELECT count(*) FROM changes');
      final writes = await count('SELECT total_changes()');
      for (var i = 0; i < 3; i++) {
        await store.load();
      }
      expect(await count('SELECT count(*) FROM changes'), logged);
      expect(await count('SELECT total_changes()'), writes);
      expect(await count('SELECT count(*) FROM entries WHERE merchant IS NOT NULL'), 0);
    });

    test('a NUL, or a lone surrogate in a line, round trips', () async {
      final raw = _entry('e1').toJson()..['note'] = 'a\u0000b';
      (raw['lines'] as List<Map<String, dynamic>>)[0]['currency'] = 'S\udc00R';
      final custom = EntryRecords.forTesting(collection: 'book.entries', filePath: 'book.entries.json', itemFromJson: (json) => _RawEntry(json, _entry('e1')));
      await custom.write([_record(_RawEntry(raw, _entry('e1')))]);
      expect((await custom.read()).single.item.toJson(), raw);
      expect(await count('SELECT count(*) FROM entry_lines'), 0);
    });

    test('documents keep their JSON body and metadata', () async {
      final docs = DocumentRecords<BookAccount>(collection: 'book.accounts', filePath: 'book.accounts.json', itemFromJson: BookAccount.fromJson);
      final account = BookAccount(id: 'a1', name: 'Cash', side: AccountSide.own, type: AccountType.cash, currency: 'SAR', statementRefs: const ['card:4417']);
      final at = DateTime.utc(2026, 1, 2, 3, 4, 5, 6, 7);
      await docs.write([Record<BookAccount>(item: account, order: 3.75, updatedAt: at, deleted: true)]);
      final back = (await docs.read()).single;
      expect(back.item, account);
      expect(back.order, 3.75);
      expect(back.updatedAt.toUtc().toIso8601String(), at.toIso8601String());
      expect(back.deleted, isTrue);
    });
  });

  group('writing', () {
    test('records that did not change write nothing and log nothing', () async {
      final records = [_record(_entry('e1'), order: 0), _record(_entry('e2'), order: 1, deleted: true)];
      await entries.write(records);
      final writes = await count('SELECT total_changes()');
      final logged = await count('SELECT count(*) FROM changes');

      // The same records, rebuilt: nothing is different but the objects.
      await entries.write([for (final r in await entries.read()) r.copyWith()]);
      await entries.write(records);

      expect(await count('SELECT total_changes()'), writes);
      expect(await count('SELECT count(*) FROM changes'), logged);
    });

    test('a date held as UTC and the same one read back in local time are not a change', () async {
      await entries.write([_record(_entry('e1', date: DateTime.utc(2026, 11, 8, 9, 30)))]);
      final writes = await count('SELECT total_changes()');
      await entries.write([_record(_entry('e1', date: DateTime.utc(2026, 11, 8, 9, 30).toLocal()))]);
      expect(await count('SELECT total_changes()'), writes);
    });

    test('a changed entry replaces its lines and nobody else\'s', () async {
      await entries.write([_record(_entry('e1', lines: 4)), _record(_entry('e2'), order: 1)]);
      expect(await count("SELECT count(*) FROM entry_lines WHERE entry_id = 'e1'"), 4);

      await entries.write([_record(_entry('e1', amount: 9900, merchant: 'New', lines: 2), at: DateTime.utc(2026, 11, 9)), _record(_entry('e2'), order: 1)]);

      final back = {for (final r in await entries.read()) r.item.id: r.item};
      expect(back['e1']!.merchant, 'New');
      expect(back['e1']!.lines.map((l) => l.amount), [9900, -9900]);
      expect(await count("SELECT count(*) FROM entry_lines WHERE entry_id = 'e1'"), 2);
      expect(await count("SELECT count(*) FROM entry_lines WHERE entry_id = 'e2'"), 2);
      expect((await ops()).where((o) => o.endsWith(':e2')), ['put:e2']);
    });

    test('a change of metadata alone leaves the lines and costs one row', () async {
      await entries.write([_record(_entry('e1'), order: 0)]);
      final writes = await count('SELECT total_changes()');
      await entries.write([_record(_entry('e1'), order: 4, at: DateTime.utc(2026, 11, 9))]);
      // The entry row and the log row.
      expect(await count('SELECT total_changes()'), writes + 2);
      expect((await entries.read()).single.order, 4);
      expect((await ops()).last, 'meta:e1');
      expect(await count("SELECT count(*) FROM changes WHERE op = 'meta' AND body IS NOT NULL"), 0);
    });

    test('moving many entries logs each without repeating the item', () async {
      await entries.write([for (var i = 0; i < 5; i++) _record(_entry('e$i', merchant: 'M$i'), order: i.toDouble())]);
      await entries.write([for (var i = 0; i < 5; i++) _record(_entry('e$i', merchant: 'M$i'), order: 10.0 - i, at: DateTime.utc(2026, 11, 9))]);
      expect(await count("SELECT count(*) FROM changes WHERE op = 'meta'"), 5);
      expect(await count("SELECT count(*) FROM changes WHERE op = 'put'"), 5);
      expect(await count("SELECT count(*) FROM changes WHERE op = 'meta' AND body IS NULL"), 5);
    });

    test('a tombstone that is only re-stamped is a meta change, not a second delete', () async {
      await entries.write([_record(_entry('e1'), deleted: true)]);
      await entries.write([_record(_entry('e1'), deleted: true, at: DateTime.utc(2026, 11, 9))]);
      expect((await ops()).skip(1), ['delete:e1', 'meta:e1']);
    });

    test('a record gone from the list is purged with its lines', () async {
      await entries.write([_record(_entry('e1')), _record(_entry('e2'), order: 1)]);
      await entries.write([_record(_entry('e1'))]);
      expect((await entries.read()).map((r) => r.item.id), ['e1']);
      expect(await count("SELECT count(*) FROM entry_lines WHERE entry_id = 'e2'"), 0);
      expect(await ops(), ['import:', 'put:e1', 'put:e2', 'purge:e2']);
    });

    test('a new tombstone is logged as a delete and a revived one as a put', () async {
      await entries.write([_record(_entry('e1'))]);
      await entries.write([_record(_entry('e1'), deleted: true, at: DateTime.utc(2026, 11, 9))]);
      await entries.write([_record(_entry('e1'), at: DateTime.utc(2026, 11, 10))]);
      expect((await ops()).skip(1), ['put:e1', 'delete:e1', 'put:e1']);
      final put = await db.customSelect("SELECT body FROM changes WHERE op = 'put' ORDER BY seq LIMIT 1").getSingle();
      expect(jsonDecode(put.data['body'] as String), _entry('e1').toJson());
    });

    test('a failure part way leaves nothing written', () async {
      final docs = DocumentRecords<BookAccount>(collection: 'book.accounts', filePath: 'book.accounts.json', itemFromJson: BookAccount.fromJson);
      BookAccount account(String id, String name) => BookAccount(id: id, name: name, side: AccountSide.own, type: AccountType.cash, currency: 'SAR');
      await docs.write([Record<BookAccount>(item: account('a', 'Before'), order: 0, updatedAt: DateTime.utc(2026))]);
      final logged = await count('SELECT count(*) FROM changes');

      // The rows go in before the log rows, so the log failing is a failure
      // after rows were written.
      await db.customStatement('ALTER TABLE changes RENAME TO changes_away');
      await expectLater(
        docs.write([
          Record<BookAccount>(item: account('a', 'After'), order: 0, updatedAt: DateTime.utc(2027)),
          Record<BookAccount>(item: account('b', 'New'), order: 1, updatedAt: DateTime.utc(2027)),
        ]),
        throwsA(anything),
      );
      await db.customStatement('ALTER TABLE changes_away RENAME TO changes');

      final back = await docs.read();
      expect(back.map((r) => r.item.name), ['Before']);
      expect(await count('SELECT count(*) FROM changes'), logged);
    });
  });

  group('importing the JSON files earlier versions kept the book in', () {
    File json(String name) => File('${dir.path}/$name');

    Future<List<Map<String, dynamic>>> legacyEntries() async {
      final list = [
        _record(_entry('e1', merchant: 'Cafe'), order: -1000.0, at: DateTime.utc(2026, 3, 1, 8, 0, 0, 123, 456)),
        _record(_entry('e2', lines: 3), order: 0.5, at: DateTime.utc(2026, 4, 2)),
        _record(_entry('e3'), order: 12, at: DateTime.utc(2026, 5, 3, 4), deleted: true),
      ];
      return [for (final r in list) r.toJson()];
    }

    test('every record arrives with its id and metadata, once, and the file is untouched', () async {
      final records = await legacyEntries();
      await LocalFileStore.writeJson('book.entries.json', {'records': records});
      final before = await json('book.entries.json').readAsBytes();

      final first = await entries.read();
      expect(first.map((r) => r.toJson()), records.map((r) => Record.fromJson(r, BookEntry.fromJson).toJson()));
      expect(first.map((r) => r.toJson()), records);
      final logged = await count('SELECT count(*) FROM changes');
      final writes = await count('SELECT total_changes()');

      final second = await entries.read();
      expect(second, hasLength(3));
      expect(await count('SELECT count(*) FROM changes'), logged);
      expect(await count('SELECT total_changes()'), writes);
      expect(await ops(), ['import:']);
      expect(await json('book.entries.json').readAsBytes(), before);
    });

    test('the file is not read again once it has been imported', () async {
      await LocalFileStore.writeJson('book.entries.json', {'records': await legacyEntries()});
      await entries.read();
      await entries.write([_record(_entry('later'))]);
      await LocalFileStore.writeJson('book.entries.json', {'records': await legacyEntries()});
      expect((await entries.read()).map((r) => r.item.id), ['later']);
    });

    test('a missing file only sets the flag', () async {
      expect(await entries.read(), isEmpty);
      expect(await count("SELECT count(*) FROM meta WHERE key = 'imported.book.entries'"), 1);
      await LocalFileStore.writeJson('book.entries.json', {'records': await legacyEntries()});
      expect(await entries.read(), isEmpty);
    });

    test('a write before any read imports first, so the old records are not lost', () async {
      await LocalFileStore.writeJson('book.entries.json', {'records': await legacyEntries()});
      await entries.write([_record(_entry('e1', merchant: 'Cafe'), order: -1000.0, at: DateTime.utc(2026, 3, 1, 8, 0, 0, 123, 456)), _record(_entry('e2', lines: 3), order: 0.5, at: DateTime.utc(2026, 4, 2)), _record(_entry('e3'), order: 12, at: DateTime.utc(2026, 5, 3, 4), deleted: true)]);
      expect(await ops(), ['import:']);
      expect(await count('SELECT count(*) FROM entries'), 3);
    });

    test('a stop half way imports nothing and the next read imports everything', () async {
      await LocalFileStore.writeJson('book.entries.json', {'records': await legacyEntries()});
      await db.customStatement('ALTER TABLE changes RENAME TO changes_away');
      await expectLater(entries.read(), throwsA(anything));
      await db.customStatement('ALTER TABLE changes_away RENAME TO changes');
      expect(await count('SELECT count(*) FROM entries'), 0);
      expect(await count('SELECT count(*) FROM meta'), 0);

      expect(await entries.read(), hasLength(3));
      expect(await count('SELECT count(*) FROM entries'), 3);
    });

    test('a file that cannot be read sets no flag, loses nothing, and is tried again on the next start', () async {
      final records = await legacyEntries();
      await LocalFileStore.writeJson('book.entries.json', {'records': records});
      final good = await json('book.entries.json').readAsString();
      await json('book.entries.json').writeAsString(good.substring(0, good.length ~/ 2));

      expect(await entries.read(), isEmpty);
      expect(await count("SELECT count(*) FROM meta WHERE key = 'imported.book.entries'"), 0);
      // Work done meanwhile is kept, and the broken file is not read again
      // on every operation.
      await entries.write([_record(_entry('mine'), order: 50)]);
      await json('book.entries.json').writeAsString(good);
      expect((await entries.read()).map((r) => r.item.id), ['mine']);

      await BookDatabase.closeAll();
      db = await BookDatabase.open();
      expect((await entries.read()).map((r) => r.item.id).toSet(), {'e1', 'e2', 'e3', 'mine'});
      expect(await count("SELECT count(*) FROM meta WHERE key = 'imported.book.entries'"), 1);
    });

    test('a file that is unreadable once and then readable imports on the next start', () async {
      if (Platform.isWindows) return;
      await LocalFileStore.writeJson('book.entries.json', {'records': await legacyEntries()});
      await Process.run('chmod', ['000', json('book.entries.json').path]);
      try {
        expect(await entries.read(), isEmpty);
        expect(await count('SELECT count(*) FROM meta'), 0);
      } finally {
        await Process.run('chmod', ['644', json('book.entries.json').path]);
      }
      await BookDatabase.closeAll();
      db = await BookDatabase.open();
      expect(await entries.read(), hasLength(3));
      expect(await count('SELECT count(*) FROM meta'), 1);
    });

    test('two records of one id import as the newer one, whole', () async {
      final older = _record(_entry('dup', merchant: 'Old', lines: 4), at: DateTime.utc(2026, 1, 1));
      final newer = _record(_entry('dup', merchant: 'New', amount: 500), at: DateTime.utc(2026, 2, 1));
      for (final order in [[older, newer], [newer, older]]) {
        await LocalFileStore.writeJson('book.entries.json', {'records': [for (final r in order) r.toJson()]});
        final back = (await entries.read()).single.item;
        expect(back.merchant, 'New');
        expect(back.lines, hasLength(2));
        expect(back.isBalanced, isTrue);
        await db.customStatement('DELETE FROM entries');
        await db.customStatement('DELETE FROM entry_lines');
        await db.customStatement('DELETE FROM meta');
      }
    });

    test('an import after the database holds records keeps the newer of each, whole', () async {
      final legacy = [
        _record(_entry('same', merchant: 'Legacy', lines: 4), at: DateTime.utc(2026, 1, 1)),
        _record(_entry('stale', merchant: 'Legacy', lines: 4), at: DateTime.utc(2026, 1, 1)),
        _record(_entry('fresh', merchant: 'Legacy', lines: 3), at: DateTime.utc(2026, 1, 1)),
      ];
      await LocalFileStore.writeJson('book.entries.json', {'records': [for (final r in legacy) r.toJson()]});
      final good = await json('book.entries.json').readAsString();
      await json('book.entries.json').writeAsString('{');

      expect(await entries.read(), isEmpty);
      await entries.write([
        _record(_entry('same', merchant: 'Edited', lines: 2), at: DateTime.utc(2026, 6, 1)),
        _record(_entry('stale', merchant: 'Edited', lines: 2), at: DateTime.utc(2025, 6, 1)),
        _record(_entry('only', merchant: 'Edited'), at: DateTime.utc(2026, 6, 1)),
      ]);
      await json('book.entries.json').writeAsString(good);
      await BookDatabase.closeAll();
      db = await BookDatabase.open();

      final back = {for (final r in await entries.read()) r.item.id: r.item};
      expect(back.keys.toSet(), {'same', 'stale', 'fresh', 'only'});
      expect(back['same']!.merchant, 'Edited');
      expect(back['same']!.lines, hasLength(2));
      expect(back['stale']!.merchant, 'Legacy');
      expect(back['stale']!.lines, hasLength(4));
      expect(back['fresh']!.lines, hasLength(3));
      expect(back.values.every((e) => e.isBalanced), isTrue);
      expect(await count('SELECT count(*) FROM entry_lines'), 2 + 4 + 3 + 2);
    });

    test('BookStore reads all four collections from the files', () async {
      final account = BookAccount(id: 'a1', name: 'Cash', side: AccountSide.own, type: AccountType.cash, currency: 'SAR');
      Map<String, dynamic> rec(Map<String, dynamic> item) => {'item': item, 'order': 0.0, 'updatedAt': '2026-02-03T04:05:06.789012Z', 'deleted': false};
      await LocalFileStore.writeJson('book.accounts.json', {'records': [rec(account.toJson())]});
      await LocalFileStore.writeJson('book.entries.json', {'records': await legacyEntries()});
      await LocalFileStore.writeJson('book.recurring.json', {'records': <Object>[]});
      await LocalFileStore.writeJson('money.settings.json', {'records': [rec({'id': 'money.settings', 'seenWhatsNew': true})]});

      final store = BookStore();
      expect((await store.accounts.load()).single, account);
      expect(await store.entries.load(), hasLength(2));
      expect(await store.recurring.load(), isEmpty);
      expect((await store.loadSettings()).seenWhatsNew, isTrue);
      expect(await count("SELECT count(*) FROM meta WHERE key LIKE 'imported.ledger.%'"), 4);
    });
  });

  group('the same operations over the JSON file and the database', () {
    test('give the same records', () async {
      Future<List<Map<String, dynamic>>> run(LocalRecords<BookEntry>? local, String file) async {
        final store = SyncedStore<BookEntry>(filePath: file, cloudKey: file, itemFromJson: BookEntry.fromJson, cloud: LocalOnlyCloudKVStore(), local: local);
        await store.upsertAll([_entry('a'), _entry('b', lines: 3), _entry('c')]);
        await store.upsert(_entry('b', amount: 700, merchant: 'Edited'));
        await store.delete('c');
        await store.setOrder(['b', 'a']);
        final live = await store.deleteAll(['a']);
        expect(live.map((e) => e.id), ['b']);
        await store.importRecords([_record(_entry('z'), order: 9, at: DateTime.utc(2020))], replace: false);
        final out = [for (final r in await store.exportRecords()) r.toJson()..remove('updatedAt')];
        out.sort((x, y) => ((x['item'] as Map)['id'] as String).compareTo((y['item'] as Map)['id'] as String));
        return out;
      }

      final inJson = await run(null, 'one.json');
      final inDb = await run(EntryRecords(collection: 'two', filePath: 'two.json'), 'two.json');
      expect(inDb, inJson);
    });
  });

  group('reads and writes that overlap', () {
    test('a read never sees an entry without its lines', () async {
      await entries.write([for (var i = 0; i < 40; i++) _record(_entry('e$i', lines: 3), order: i.toDouble())]);
      for (var round = 0; round < 15; round++) {
        final changed = [for (var i = 0; i < 40; i++) _record(_entry('e$i', amount: 100 + round, lines: 2 + round % 3), order: i.toDouble(), at: DateTime.utc(2026, 11, 9, 0, 0, round))];
        final reads = [for (var i = 0; i < 5; i++) entries.read()];
        await entries.write(changed);
        for (final read in reads) {
          expect([for (final r in await read) r.item.lines.length].where((n) => n < 2).isEmpty, isTrue);
        }
      }
    });

    test('saves through one store that overlap all land, with their lines', () async {
      final store = SyncedStore<BookEntry>(filePath: 'book.entries.json', cloudKey: 'book.entries', itemFromJson: BookEntry.fromJson, cloud: _MemoryCloud(), local: entries);
      await Future.wait([for (var i = 0; i < 20; i++) store.upsert(_entry('n$i', lines: 3)), store.load(), store.load()]);
      final back = await store.load();
      expect(back.map((e) => e.id).toSet(), {for (var i = 0; i < 20; i++) 'n$i'});
      expect(back.every((e) => e.lines.length == 3 && e.isBalanced), isTrue);
    });
  });

  group('holding lines and collections', () {
    BookEntry holdingEntry(String id, {int quantity = 2500000000, double? raw}) => BookEntry(
          id: id,
          date: DateTime.utc(2026, 11, 8, 9, 30).toLocal(),
          template: EntryTemplate.holdingBuy,
          baseCurrency: 'SAR',
          lines: [
            EntryLine(
              accountId: 'holding.metal.XAU',
              amount: 1000,
              currency: 'SAR',
              baseAmount: 1000,
              quantity: quantity,
              commodity: 'metal.XAU',
              unit: PriceUnit.gram,
              karat: 21,
              unitPrice: 0.1 + 0.2,
              fee: 1.5,
              quantityRaw: raw,
            ),
            const EntryLine(accountId: 'system.holdings', amount: -1000, currency: 'SAR', baseAmount: -1000),
          ],
        );

    Future<void> otherRow(String id, {String collection = 'holdings.test'}) async {
      await db.customStatement("INSERT INTO entries (id, collection, date, template, base_currency, sort, updated_at, deleted) VALUES ('$id', '$collection', '2026-11-08T09:30:00.000Z', 'holding_in', 'SAR', 0, '2026-11-08T10:00:00.000000Z', 0)");
      await db.customStatement("INSERT INTO entry_lines (entry_id, idx, account_id, amount, currency, base_amount, quantity, commodity) VALUES ('$id', 0, 'a', 5, 'SAR', 5, 7, 'metal.XAU')");
    }

    test('quantity and commodity are columns, the other facts of the line are kept, and all come back', () async {
      final e = holdingEntry('h1', raw: 2500000000.0000001 / 1e8);
      await entries.write([_record(e), _record(_entry('m1'), order: 1)]);

      final row = await db.customSelect("SELECT quantity, commodity, extra FROM entry_lines WHERE entry_id = 'h1' AND idx = 0").getSingle();
      expect((row.data['quantity'], row.data['commodity']), (2500000000, 'metal.XAU'));
      expect(jsonDecode(row.data['extra'] as String), {'unit': 'gram', 'karat': 21, 'px': 0.1 + 0.2, 'fee': 1.5, 'qtyRaw': 2500000000.0000001 / 1e8});
      final cash = await db.customSelect("SELECT quantity, commodity, extra FROM entry_lines WHERE entry_id = 'h1' AND idx = 1").getSingle();
      expect([cash.data['quantity'], cash.data['commodity'], cash.data['extra']], [null, null, null]);

      final back = (await entries.read()).first.item;
      expect(back, e);
      expect(jsonEncode(back.toJson()), jsonEncode(e.toJson()));
      expect(await entries.read(), hasLength(2));
    });

    test('a quantity or commodity of the wrong type stays in the line’s extra and comes back', () async {
      final raw = holdingEntry('h2').toJson();
      final line = (raw['lines'] as List<Map<String, dynamic>>)[0];
      line['qty'] = 2.5;
      line['commodity'] = 7;
      final custom = EntryRecords.forTesting(collection: 'book.entries', filePath: 'book.entries.json', itemFromJson: (json) => _RawEntry(json, holdingEntry('h2')));
      await custom.write([_record(_RawEntry(raw, holdingEntry('h2')))]);
      expect((await custom.read()).single.item.toJson(), raw);
      final row = await db.customSelect("SELECT quantity, commodity, extra FROM entry_lines WHERE entry_id = 'h2' AND idx = 0").getSingle();
      expect([row.data['quantity'], row.data['commodity']], [null, null]);
      expect(jsonDecode(row.data['extra'] as String), containsPair('qty', 2.5));
    });

    test('a line with a unit or a count this build does not know does not make the collection unreadable', () async {
      await entries.write([_record(_entry('ok'))]);
      await db.customStatement("INSERT INTO entries (id, collection, date, template, base_currency, sort, updated_at, deleted) VALUES ('later', 'book.entries', '2026-11-08T09:30:00.000Z', 'holding_in', 'SAR', 1, '2026-11-08T10:00:00.000000Z', 0)");
      await db.customStatement(
          "INSERT INTO entry_lines (entry_id, idx, account_id, amount, currency, base_amount, quantity, commodity, extra) VALUES ('later', 0, 'holding.metal.XAU', 0, 'SAR', 0, 5, 'metal.XAU', '{\"unit\":\"stone\",\"karat\":21.0}')");
      final back = await entries.read();
      expect(back.map((r) => r.item.id), ['ok', 'later']);
      final line = back.last.item.lines.single;
      expect((line.quantity, line.commodity, line.unit, line.karat), (5, 'metal.XAU', null, 21));
    });

    test('an entry that changes keeps its lines in step, quantity included', () async {
      await entries.write([_record(holdingEntry('h3'))]);
      await entries.write([_record(holdingEntry('h3', quantity: 100), at: DateTime.utc(2026, 11, 9))]);
      expect((await entries.read()).single.item.lines.first.quantity, 100);
      expect(await count('SELECT count(*) FROM entry_lines'), 2);
    });

    test('rows are put in the collection of the store that wrote them', () async {
      await entries.write([_record(_entry('e1'))]);
      expect(await count("SELECT count(*) FROM entries WHERE collection = 'book.entries'"), 1);
      final other = EntryRecords(collection: 'holdings.test', filePath: 'holdings.json');
      await other.write([_record(holdingEntry('h1'))]);
      expect(await count("SELECT count(*) FROM entries WHERE collection = 'holdings.test'"), 1);
    });

    test('a store reads, writes and purges only its own collection', () async {
      await otherRow('theirs');
      await entries.write([_record(_entry('e1'), order: 0), _record(_entry('e2'), order: 1)]);
      expect((await entries.read()).map((r) => r.item.id), ['e1', 'e2']);

      // A write that leaves out every one of its own rows purges those only.
      await entries.write([_record(_entry('e1'), order: 0)]);
      expect((await entries.read()).map((r) => r.item.id), ['e1']);
      await entries.write(const []);
      expect(await entries.read(), isEmpty);
      expect(await count("SELECT count(*) FROM entries WHERE id = 'theirs'"), 1);
      expect(await count("SELECT count(*) FROM entry_lines WHERE entry_id = 'theirs'"), 1);

      final other = EntryRecords(collection: 'holdings.test', filePath: 'holdings.json');
      expect((await other.read()).map((r) => r.item.id), ['theirs']);
      expect((await other.read()).single.item.lines.single.quantity, 7);
    });

    test('two stores over the table keep their own rows through writes and deletes', () async {
      final other = EntryRecords(collection: 'holdings.test', filePath: 'holdings.json');
      await entries.write([_record(_entry('e1')), _record(_entry('e2'), order: 1, deleted: true)]);
      await other.write([_record(holdingEntry('h1')), _record(holdingEntry('h2'), order: 1)]);
      await entries.write([_record(_entry('e1', amount: 5), at: DateTime.utc(2026, 11, 9))]);
      await other.write([_record(holdingEntry('h1', quantity: 9), order: 3, at: DateTime.utc(2026, 11, 9))]);
      expect((await entries.read()).map((r) => r.item.id), ['e1']);
      expect((await other.read()).map((r) => r.item.id), ['h1']);
      expect((await other.read()).single.item.lines.first.quantity, 9);
      expect(await count('SELECT count(*) FROM entries'), 2);
    });
  });
}
