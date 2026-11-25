import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/book_entry.dart';
import 'package:qima/services/book_db/book_database.dart';
import 'package:qima/services/book_db/db_records.dart';
import 'package:qima/services/local_file_store.dart';
import 'package:qima/services/synced_store.dart';

/// The app opens the file on a background isolate; widget tests cannot, so
/// this runs the same records through that executor in a plain test.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('qima_book_db_bg');
    LocalFileStore.overrideDirectoryForTesting(dir);
    BookDatabase.executorOverride = (file) => NativeDatabase.createInBackground(file);
  });

  tearDown(() async {
    await BookDatabase.closeAll();
    BookDatabase.executorOverride = null;
    await dir.delete(recursive: true);
  });

  test('records, import and log work through the background executor', () async {
    final legacy = BookEntry(
      id: 'old',
      date: DateTime.utc(2026, 3, 1).toLocal(),
      template: EntryTemplate.spend,
      baseCurrency: 'SAR',
      lines: const [
        EntryLine(accountId: 'category.food', amount: 500, currency: 'SAR', baseAmount: 500),
        EntryLine(accountId: 'account.cash', amount: -500, currency: 'SAR', baseAmount: -500),
      ],
    );
    final at = DateTime.utc(2026, 3, 1, 8, 0, 0, 123, 456);
    await LocalFileStore.writeJson('book.entries.json', {'records': [Record<BookEntry>(item: legacy, order: 1.5, updatedAt: at).toJson()]});

    final entries = EntryRecords(collection: 'book.entries', filePath: 'book.entries.json');
    final imported = await entries.read();
    expect(imported.single.item, legacy);
    expect(imported.single.updatedAt.toUtc().toIso8601String(), at.toIso8601String());

    final added = legacy.copyWith(merchant: 'Cafe');
    await entries.write([imported.single, Record<BookEntry>(item: BookEntry.fromJson({...added.toJson(), 'id': 'new'}), order: 2, updatedAt: DateTime.utc(2026, 4, 1))]);
    expect((await entries.read()).map((r) => r.item.id), ['old', 'new']);

    final db = await BookDatabase.open();
    final log = await db.customSelect('SELECT op FROM changes ORDER BY seq').get();
    expect([for (final r in log) r.data['op']], ['import', 'put']);
  });
}
