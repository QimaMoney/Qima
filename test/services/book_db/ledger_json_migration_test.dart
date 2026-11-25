import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/asset.dart';
import 'package:qima/models/book_account.dart';
import 'package:qima/models/book_entry.dart';
import 'package:qima/models/holding_cash_id.dart';
import 'package:qima/models/holding_transaction.dart';
import 'package:qima/models/legacy_collapse.dart';
import 'package:qima/models/money_settings.dart';
import 'package:qima/models/syncable.dart';
import 'package:qima/services/book_db/ledger_json_migration.dart';
import 'package:qima/services/book_db/ledger_plan.dart';
import 'package:qima/services/cloud_kv_store.dart';
import 'package:qima/services/local_file_store.dart';
import 'package:qima/services/synced_store.dart';

/// The web build keeps the book in JSON files. These tests run its migration
/// and records over the same file store the native build uses for JSON, which
/// is the code the web build runs (`LocalFileStore` picks shared preferences
/// there, and nothing in the migration depends on which).

final _day = DateTime(2026, 3, 12);
final _t0 = DateTime.utc(2026, 5, 1, 10);
DateTime _at(int s) => _t0.add(Duration(seconds: s));

class _Cloud implements CloudKVStore {
  final Map<String, String> values = {};
  final List<String> written = [];

  @override
  Future<String?> getString(String key) async => values[key];

  @override
  Future<void> setString(String key, String value) async {
    written.add(key);
    values[key] = value;
  }

  @override
  Future<void> synchronize() async {}

  @override
  Future<bool> accountStatus() async => true;

  @override
  Stream<CloudKVChangeEvent> get didChangeExternally => const Stream.empty();
}

HoldingTransaction _trade(String id, TransactionKind kind, {double fee = 0}) => HoldingTransaction(
      id: id,
      instrumentID: 'metal.XAU',
      kind: kind,
      quantity: 10,
      unit: PriceUnit.gram,
      unitPrice: 50,
      fee: fee,
      currency: 'USD',
      date: _day,
    );

Record<BookEntry> _spend(String id, int stamp, {double order = 9}) => Record(
      item: BookEntry(id: id, date: _day, template: EntryTemplate.spend, baseCurrency: 'USD', merchant: 'Cafe', lines: const [
        EntryLine(accountId: 'acct.bank', amount: -700, currency: 'USD', baseAmount: -700),
        EntryLine(accountId: 'category.food', amount: 700, currency: 'USD', baseAmount: 700),
      ]),
      order: order,
      updatedAt: _at(stamp),
    );

Record<BookEntry> _cash(String tradeId, int amount, int stamp) => Record(
      item: BookEntry(
        id: holdingCashId(tradeId),
        date: _day,
        template: EntryTemplate.holdingTrade,
        baseCurrency: 'USD',
        merchant: 'Gold',
        lines: [
          EntryLine(accountId: 'acct.bank', amount: amount, currency: 'USD', baseAmount: amount),
          EntryLine(accountId: 'system.holdings', amount: -amount, currency: 'USD', baseAmount: -amount),
        ],
      ),
      order: 5,
      updatedAt: _at(stamp),
    );

final _account = BookAccount(id: 'a1', name: 'Cash', side: AccountSide.own, type: AccountType.cash, currency: 'SAR');
final _trades = [Record(item: _trade('buy', TransactionKind.buy, fee: 5), order: 2, updatedAt: _at(10)), Record(item: _trade('sale', TransactionKind.sell), order: 3, updatedAt: _at(12))];
final _oldEntries = [_spend('s1', 1), _cash('buy', -50500, 20)];

void main() {
  late Directory dir;

  File f(String name) => File('${dir.path}/$name');
  List<String> files(List<String> names) => [for (final n in names) f(n).existsSync() ? f(n).readAsStringSync() : '-'];
  const ledgerFiles = [LedgerNames.accountsFile, LedgerNames.recurringFile, LedgerNames.settingsFile, LedgerNames.entriesFile];
  const oldFiles = [LedgerNames.legacyAccountsFile, LedgerNames.legacyRecurringFile, LedgerNames.legacySettingsFile, LedgerNames.legacyEntriesFile];

  Future<void> writeOld() async {
    await LocalFileStore.writeJson(LedgerNames.legacyAccountsFile, {'records': [Record(item: _account, order: 0, updatedAt: _at(1)).toJson()]});
    await LocalFileStore.writeJson(LedgerNames.legacyEntriesFile, {'records': [for (final r in _oldEntries) r.toJson()]});
    await LocalFileStore.writeJson(LedgerNames.legacyRecurringFile, {'records': <Object>[]});
    await LocalFileStore.writeJson(LedgerNames.legacySettingsFile, {'records': [Record(item: const MoneySettings(seenWhatsNew: true), order: 0, updatedAt: _at(1)).toJson()]});
  }

  Future<void> writeHoldings({List<Record<HoldingTransaction>>? trades}) async {
    await LocalFileStore.writeJson(LedgerNames.transactionsFile, {'records': [for (final t in trades ?? _trades) t.toJson()]});
  }

  List<Record<BookEntry>> entriesIn(String name) =>
      [for (final j in (jsonDecode(f(name).readAsStringSync())['records'] as List)) Record.fromJson<BookEntry>((j as Map).cast<String, dynamic>(), BookEntry.fromJson)];

  List<String> dump(Iterable<Record> rs) => [for (final r in rs) jsonEncode(r.toJson())];

  List<Record<BookEntry>> oracle() => LegacyCollapse.collapse(transactions: _trades, lots: const [], entries: _oldEntries)..sort((a, b) => a.item.id.compareTo(b.item.id));

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('qima_ledger_json');
    LocalFileStore.overrideDirectoryForTesting(dir);
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('step A writes the four ledger files from the old ones, then the marker, and leaves the old files alone', () async {
    await writeOld();
    final old = files(oldFiles);
    await LedgerJsonMigration.ensure(collapseHoldings: false);
    expect(files(oldFiles), old);
    expect(files(ledgerFiles), old, reason: 'the same records, in the ledger files');
    expect(f(LedgerNames.markerBookFile).existsSync(), isTrue);
    expect(f(LedgerNames.markerHoldingsFile).existsSync(), isFalse);
  });

  test('a book with no files migrates to empty ledger files', () async {
    await LedgerJsonMigration.ensure(collapseHoldings: false);
    for (final n in ledgerFiles) {
      expect(jsonDecode(f(n).readAsStringSync()), {'records': <Object>[]}, reason: n);
    }
    expect(f(LedgerNames.markerBookFile).existsSync(), isTrue);
  });

  test('nothing is read or written before the marker: a store waits for the migration', () async {
    await writeOld();
    final store = SyncedStore<BookEntry>(
      filePath: LedgerNames.entriesFile,
      cloudKey: LedgerNames.entries,
      itemFromJson: BookEntry.fromJson,
      cloud: LocalOnlyCloudKVStore(),
      local: LedgerJsonRecords<BookEntry>(LedgerNames.entriesFile, BookEntry.fromJson, collapseHoldings: false),
    );
    expect(f(LedgerNames.entriesFile).existsSync(), isFalse);
    expect((await store.load()).map((e) => e.id), [holdingCashId('buy'), 's1']);
    expect(f(LedgerNames.markerBookFile).existsSync(), isTrue);
  });

  test('stores sharing one start migrate once, and what they write afterwards is not written over', () async {
    await writeOld();
    final cloud = _Cloud();
    SyncedStore<T> store<T extends Syncable>(String key, String file, T Function(Map<String, dynamic>) fromJson) =>
        SyncedStore<T>(filePath: file, cloudKey: key, itemFromJson: fromJson, cloud: cloud, local: LedgerJsonRecords<T>(file, fromJson, collapseHoldings: false), cloudFormat: CloudFormat.envelope, tombstoneTTL: null);
    final accounts = store<BookAccount>(LedgerNames.accounts, LedgerNames.accountsFile, BookAccount.fromJson);
    final entries = store<BookEntry>(LedgerNames.entries, LedgerNames.entriesFile, BookEntry.fromJson);
    final settings = store<MoneySettings>(LedgerNames.settings, LedgerNames.settingsFile, MoneySettings.fromJson);
    final loaded = await Future.wait([accounts.load(), entries.load(), settings.load()]);
    expect((loaded[0] as List).length, 1);
    expect((loaded[1] as List).length, 2);

    await entries.upsert(_spend('later', 50).item);
    await Future.wait([accounts.load(), settings.load(), entries.load()]);
    expect((await entries.load()).map((e) => e.id), contains('later'));
    expect(cloud.values.keys.toSet().intersection({LedgerNames.legacyAccounts, LedgerNames.legacyEntries, LedgerNames.legacyRecurring, LedgerNames.legacySettings}), isEmpty);
    expect(cloud.written.toSet(), {LedgerNames.accounts, LedgerNames.entries, LedgerNames.settings});
  });

  test('a file that cannot be read stops it before anything is written, and it runs when it can be read', () async {
    await writeOld();
    final good = f(LedgerNames.legacyEntriesFile).readAsStringSync();
    f(LedgerNames.legacyEntriesFile).writeAsStringSync(good.substring(0, 20));
    await expectLater(LedgerJsonMigration.ensure(collapseHoldings: false), throwsA(isA<LedgerSourceUnreadable>()));
    expect(files(ledgerFiles), ['-', '-', '-', '-']);
    expect(f(LedgerNames.markerBookFile).existsSync(), isFalse);
    expect(f(LedgerNames.legacyEntriesFile).readAsStringSync(), good.substring(0, 20));

    f(LedgerNames.legacyEntriesFile).writeAsStringSync(good);
    await LedgerJsonMigration.ensure(collapseHoldings: false);
    expect(f(LedgerNames.markerBookFile).existsSync(), isTrue);
  });

  test('a run that stopped after any of its files is run again from the start, with the same result', () async {
    await writeOld();
    await LedgerJsonMigration.ensure(collapseHoldings: false);
    final done = files(ledgerFiles);
    for (final lost in [
      [LedgerNames.markerBookFile],
      [LedgerNames.markerBookFile, LedgerNames.entriesFile],
      [LedgerNames.markerBookFile, LedgerNames.entriesFile, LedgerNames.settingsFile],
      [LedgerNames.markerBookFile, ...ledgerFiles],
    ]) {
      for (final n in lost) {
        if (f(n).existsSync()) f(n).deleteSync();
      }
      await LedgerJsonMigration.ensure(collapseHoldings: false);
      expect(files(ledgerFiles), done, reason: '$lost');
      expect(f(LedgerNames.markerBookFile).existsSync(), isTrue);
    }
  });

  test('with the collapse, the entries are written already collapsed, as LegacyCollapse makes them', () async {
    await writeOld();
    await writeHoldings();
    await LedgerJsonMigration.ensure(collapseHoldings: true);
    expect(dump(entriesIn(LedgerNames.entriesFile)..sort((a, b) => a.item.id.compareTo(b.item.id))), dump(oracle()));
    expect(f(LedgerNames.markerBookFile).existsSync() && f(LedgerNames.markerHoldingsFile).existsSync(), isTrue);
    final bytes = f(LedgerNames.entriesFile).readAsStringSync();
    // Run again after a stop before the markers: same files.
    f(LedgerNames.markerBookFile).deleteSync();
    f(LedgerNames.markerHoldingsFile).deleteSync();
    await LedgerJsonMigration.ensure(collapseHoldings: true);
    expect(f(LedgerNames.entriesFile).readAsStringSync(), bytes);
    // The old holdings and book files were not written.
    expect(jsonDecode(f(LedgerNames.transactionsFile).readAsStringSync())['records'], hasLength(2));
    expect(jsonDecode(f(LedgerNames.legacyEntriesFile).readAsStringSync())['records'], hasLength(2));
  });

  test('step B on a book that step A migrated before: collapses the ledger entries, once', () async {
    await writeOld();
    await writeHoldings();
    await LedgerJsonMigration.ensure(collapseHoldings: false);
    final entries = SyncedStore<BookEntry>(
      filePath: LedgerNames.entriesFile,
      cloudKey: LedgerNames.entries,
      itemFromJson: BookEntry.fromJson,
      cloud: LocalOnlyCloudKVStore(),
      local: LedgerJsonRecords<BookEntry>(LedgerNames.entriesFile, BookEntry.fromJson, collapseHoldings: false),
    );
    // The person keeps using the book; a later build then runs step B.
    await entries.upsert(_spend('edited', 40).item);
    final withEdit = [..._oldEntries, _spend('edited', 40)];
    await LedgerJsonMigration.ensure(collapseHoldings: true);
    final expected = LegacyCollapse.collapse(transactions: _trades, lots: const [], entries: withEdit)..sort((a, b) => a.item.id.compareTo(b.item.id));
    final stored = entriesIn(LedgerNames.entriesFile)..sort((a, b) => a.item.id.compareTo(b.item.id));
    expect(stored.map((r) => r.item.id), expected.map((r) => r.item.id));
    expect(stored.singleWhere((r) => r.item.id == 'buy').item.legacy, isNotNull);
    expect(stored.singleWhere((r) => r.item.id == holdingCashId('buy')).deleted, isTrue);
    expect(f(LedgerNames.markerHoldingsFile).existsSync(), isTrue);

    // A stop between the entries file and its marker: the marker is written, the file is not collapsed again.
    final bytes = f(LedgerNames.entriesFile).readAsStringSync();
    f(LedgerNames.markerHoldingsFile).deleteSync();
    await LedgerJsonMigration.ensure(collapseHoldings: true);
    expect(f(LedgerNames.entriesFile).readAsStringSync(), bytes);
    expect(f(LedgerNames.markerHoldingsFile).existsSync(), isTrue);

    // And a later call changes nothing, even over a changed holdings file.
    await writeHoldings(trades: [..._trades, Record(item: _trade('late', TransactionKind.buy), order: 9, updatedAt: _at(99))]);
    await LedgerJsonMigration.ensure(collapseHoldings: true);
    expect(f(LedgerNames.entriesFile).readAsStringSync(), bytes);
  });

  test('step B with an unreadable holdings file writes nothing and sets no marker, until it can be read', () async {
    await writeOld();
    await writeHoldings();
    await LedgerJsonMigration.ensure(collapseHoldings: false);
    final before = files(ledgerFiles);
    final good = f(LedgerNames.transactionsFile).readAsStringSync();
    f(LedgerNames.transactionsFile).writeAsStringSync('{"records": [');
    await expectLater(LedgerJsonMigration.ensure(collapseHoldings: true), throwsA(isA<LedgerSourceUnreadable>()));
    expect(files(ledgerFiles), before);
    expect(f(LedgerNames.markerHoldingsFile).existsSync(), isFalse);
    f(LedgerNames.transactionsFile).writeAsStringSync(good);
    await LedgerJsonMigration.ensure(collapseHoldings: true);
    expect(f(LedgerNames.markerHoldingsFile).existsSync(), isTrue);
  });

  test('a trade with the id of an entry that is not a holding is left out, and the rest is collapsed', () async {
    await writeOld();
    await writeHoldings(trades: [Record(item: _trade('s1', TransactionKind.buy), order: 1, updatedAt: _at(10)), Record(item: _trade('buy', TransactionKind.buy), order: 2, updatedAt: _at(11))]);
    await LedgerJsonMigration.ensure(collapseHoldings: true);
    expect(f(LedgerNames.markerBookFile).existsSync(), isTrue);
    expect(f(LedgerNames.markerHoldingsFile).existsSync(), isTrue);
    final stored = entriesIn(LedgerNames.entriesFile);
    final s1 = stored.singleWhere((r) => r.item.id == 's1');
    expect(s1.item.template, EntryTemplate.spend);
    expect(stored.singleWhere((r) => r.item.id == 'buy').item.template.isHoldingEntry, isTrue);
  });
}
