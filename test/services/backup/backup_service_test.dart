import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qima/l10n/app_localizations_en.dart';
import 'package:qima/models/asset.dart';
import 'package:qima/models/backup.dart';
import 'package:qima/models/book_account.dart';
import 'package:qima/models/book_entry.dart';
import 'package:qima/models/default_categories.dart';
import 'package:qima/models/holding.dart';
import 'package:qima/models/holding_entry_codec.dart';
import 'package:qima/models/holding_transaction.dart';
import 'package:qima/models/legacy_collapse.dart';
import 'package:qima/models/money_settings.dart';
import 'package:qima/models/syncable.dart';
import 'package:qima/models/watch_card.dart';
import 'package:qima/models/zakat.dart';
import 'package:qima/services/alerts_store.dart';
import 'package:qima/services/backup/backup_codec.dart';
import 'package:qima/services/backup/backup_service.dart';
import 'package:qima/services/book_store.dart';
import 'package:qima/services/cloud_kv_store.dart';
import 'package:qima/services/custom_instrument_store.dart';
import 'package:qima/services/holdings_ledger.dart';
import 'package:qima/services/local_file_store.dart';
import 'package:qima/services/preferences.dart';
import 'package:qima/services/synced_store.dart' show Record;
import 'package:qima/services/watchlist_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

WatchCard _card(String id, {String currency = 'USD'}) =>
    WatchCard(id: id, instrumentID: 'metal.XAU', currency: currency, unit: PriceUnit.troyOunce);

HoldingLot _lot(String id, {double quantity = 1}) => HoldingLot(
      id: id,
      instrumentID: 'metal.XAU',
      quantity: quantity,
      unit: PriceUnit.troyOunce,
      unitCost: 1900,
      costCurrency: 'USD',
      date: DateTime(2026, 1, 1),
    );

/// Every store keys its on-disk file by a FIXED filename (e.g.
/// `watchcards.records.json`), not by an instance id — two [BackupService]s
/// pointed at the same [LocalFileStore] directory are therefore the SAME
/// store, not two independent ones. Tests that need to simulate a second
/// "device" (to build an import payload that's genuinely foreign to the
/// store under test) run [body] against a scratch temp dir and restore
/// [originalDir] as the active one before returning, so the rest of the
/// test keeps writing to its own store afterward.
Future<T> withSeparateLocalStore<T>(Directory originalDir, Future<T> Function() body) async {
  final otherDir = await Directory.systemTemp.createTemp('qima_backup_service_other');
  LocalFileStore.overrideDirectoryForTesting(otherDir);
  try {
    return await body();
  } finally {
    LocalFileStore.overrideDirectoryForTesting(originalDir);
    await otherDir.delete(recursive: true);
  }
}

/// A book whose migration reports [problems], as `BookStore.ledgerProblems`
/// does while the step that folds the holdings into it has not finished.
class _UnfinishedBook extends BookStore {
  Map<String, Object> problems;

  _UnfinishedBook(this.problems);

  @override
  Future<Map<String, Object>> ledgerProblems() async => problems;
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('qima_backup_service_test');
    LocalFileStore.overrideDirectoryForTesting(tempDir);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<BackupService> makeService({CloudKVStore? cloud}) async {
    final kv = cloud ?? LocalOnlyCloudKVStore();
    return BackupService(
      watchlistStore: WatchlistStore(cloud: kv),
      bookStore: BookStore(cloud: kv),
      customInstrumentStore: CustomInstrumentStore(cloud: kv),
      alertsStore: AlertsStore(cloud: kv),
      preferences: await Preferences.create(cloud: kv),
    );
  }

  group('buildPayload / round trip', () {
    test('export then import(merge) restores everything on a fresh store', () async {
      final source = await makeService();
      await source.watchlistStore.upsert(_card('c1'));
      await HoldingsLedger(source.bookStore).upsert(HoldingTransaction.fromLot(_lot('l1')));

      final payload = await source.buildPayload();
      expect(payload.watchcards, hasLength(1));
      expect(payload.book!['entries'], hasLength(1));

      final destTempDir = await Directory.systemTemp.createTemp('qima_backup_service_dest');
      LocalFileStore.overrideDirectoryForTesting(destTempDir);
      final dest = await makeService();
      await dest.import(payload, mode: BackupImportMode.merge);

      final cards = await dest.watchlistStore.load();
      final trades = await HoldingsLedger(dest.bookStore).load();
      expect(cards.map((c) => c.id), contains('c1'));
      expect(trades.map((t) => t.id), contains('l1'));

      await destTempDir.delete(recursive: true);
    });
  });

  group('while the holdings of an earlier version are not in the book', () {
    Future<BackupService> blocked(_UnfinishedBook book) async {
      final kv = LocalOnlyCloudKVStore();
      return BackupService(
        watchlistStore: WatchlistStore(cloud: kv),
        bookStore: book,
        customInstrumentStore: CustomInstrumentStore(cloud: kv),
        alertsStore: AlertsStore(cloud: kv),
        preferences: await Preferences.create(cloud: kv),
      );
    }

    test('no backup is built, by any route, and the person is told why', () async {
      final book = _UnfinishedBook({'migrated.ledger.holdings': StateError('the holdings could not be folded in')});
      final service = await blocked(book);
      await HoldingsLedger(book).upsert(HoldingTransaction.fromLot(_lot('l1')));
      for (final build in <Future<Object?> Function()>[
        service.buildPayload,
        service.buildJson,
        () => service.buildJson(password: 'a long enough password', kdfIterations: 1),
        service.exportJson,
      ]) {
        await expectLater(build(), throwsA(isA<BackupError>().having((e) => e.kind, 'kind', BackupErrorKind.holdingsUnreadable)));
      }
      expect(BackupError(BackupErrorKind.holdingsUnreadable).message(AppLocalizationsEn()), AppLocalizationsEn().backupErrorHoldingsUnreadable);
      expect(service.lastBackupAt, isNull, reason: 'a refused backup is not a backup made');
    });

    test('the backup is built again once the migration has finished', () async {
      final book = _UnfinishedBook({'migrated.ledger.holdings': StateError('x')});
      final service = await blocked(book);
      await HoldingsLedger(book).upsert(HoldingTransaction.fromLot(_lot('l1')));
      await expectLater(service.buildPayload(), throwsA(isA<BackupError>()));
      book.problems = {};
      final payload = await service.buildPayload();
      expect(payload.book!['entries'], hasLength(1));
    });
  });

  group('merge (last-write-wins)', () {
    test('keeps a newer LOCAL edit over an older imported one', () async {
      final service = await makeService();
      await service.watchlistStore.upsert(_card('c1', currency: 'USD'));
      final exported = await service.watchlistStore.exportRecords();

      // Local edit happens AFTER the export snapshot was taken.
      await service.watchlistStore.upsert(_card('c1', currency: 'EUR'));

      await service.import(
        BackupPayloadBuilder.fromRecords(watchcards: exported),
        mode: BackupImportMode.merge,
      );

      final cards = await service.watchlistStore.load();
      expect(cards.single.currency, 'EUR'); // the newer local edit wins.
    });

    test('adds an item present only in the import', () async {
      final service = await makeService();
      await service.watchlistStore.upsert(_card('c1'));

      final imported = await withSeparateLocalStore(tempDir, () async {
        final other = await makeService();
        await other.watchlistStore.upsert(_card('c2'));
        return other.watchlistStore.exportRecords();
      });

      await service.import(BackupPayloadBuilder.fromRecords(watchcards: imported), mode: BackupImportMode.merge);

      final ids = (await service.watchlistStore.load()).map((c) => c.id).toSet();
      expect(ids, {'c1', 'c2'});
    });

    test('does not touch settings', () async {
      final service = await makeService();
      await service.preferences.setBaseCurrency('EGP');
      final payload = await service.buildPayload();
      final importedSettings = payload.settings.copyWithBaseCurrency('USD');

      await service.import(
        BackupPayloadBuilder.fromRecords(settings: importedSettings),
        mode: BackupImportMode.merge,
      );

      expect(await service.preferences.baseCurrency, 'EGP');
    });
  });

  group('replace (tombstoning)', () {
    test('tombstones every local live item not re-added by the import', () async {
      final service = await makeService();
      await service.watchlistStore.upsert(_card('local-only'));

      final imported = await withSeparateLocalStore(tempDir, () async {
        final other = await makeService();
        await other.watchlistStore.upsert(_card('imported'));
        return other.watchlistStore.exportRecords();
      });

      await service.import(BackupPayloadBuilder.fromRecords(watchcards: imported), mode: BackupImportMode.replace);

      final live = (await service.watchlistStore.load()).map((c) => c.id).toSet();
      expect(live, {'imported'});
      expect(live, isNot(contains('local-only')));
    });

    test('applies settings', () async {
      final service = await makeService();
      await service.preferences.setBaseCurrency('USD');
      final payload = await service.buildPayload();
      final importedSettings = payload.settings.copyWithBaseCurrency('EGP');

      await service.import(
        BackupPayloadBuilder.fromRecords(settings: importedSettings),
        mode: BackupImportMode.replace,
      );

      expect(await service.preferences.baseCurrency, 'EGP');
    });

    test('carries zakat settings and restores them on replace', () async {
      final source = await makeService();
      final zakat = ZakatSettings(basis: NisabBasis.silver, hawlStart: DateTime(2025, 3, 12), remind: true);
      await source.preferences.setZakatSettings(zakat);
      final payload = await source.buildPayload();
      expect(payload.settings.zakat, zakat.toJson());

      await source.preferences.setZakatSettings(const ZakatSettings());
      await source.import(payload, mode: BackupImportMode.replace);
      expect(await source.preferences.zakatSettings, zakat);
    });

    test('a backup from before zakat leaves current zakat settings alone', () async {
      final service = await makeService();
      final mine = ZakatSettings(hawlStart: DateTime(2024, 1, 1));
      await service.preferences.setZakatSettings(mine);
      final payload = await service.buildPayload();
      final legacy = payload.settings.copyWithBaseCurrency('USD'); // drops `zakat`
      expect(legacy.zakat, isNull);

      await service.import(BackupPayloadBuilder.fromRecords(settings: legacy), mode: BackupImportMode.replace);
      expect(await service.preferences.zakatSettings, mine);
    });
  });

  group('ledger', () {
    test('a backup carries the trades, sales included, as entries of the book, and restores them', () async {
      final source = await makeService();
      final sourceLedger = HoldingsLedger(source.bookStore);
      await sourceLedger.upsert(HoldingTransaction.fromLot(_lot('b1', quantity: 10)));
      await sourceLedger.upsert(HoldingTransaction(
        id: 's1',
        instrumentID: 'metal.XAU',
        kind: TransactionKind.sell,
        quantity: 4,
        unit: PriceUnit.troyOunce,
        unitPrice: 2500,
        currency: 'USD',
        date: DateTime(2026, 2, 1),
      ));
      final payload = await source.buildPayload();
      expect(payload.isLedger, isTrue);
      expect(payload.book!['entries']!.map((r) => (r['item'] as Map)['id']), unorderedEquals(['b1', 's1']));

      final restored = await withSeparateLocalStore(tempDir, () async {
        final target = await makeService();
        await target.import(payload, mode: BackupImportMode.replace);
        return HoldingsLedger(target.bookStore).load();
      });
      expect(restored.map((t) => t.kind), unorderedEquals([TransactionKind.buy, TransactionKind.sell]));
    });

    test('replace removes trades the backup doesn\'t have, and they stay gone', () async {
      final service = await makeService();
      final ledger = HoldingsLedger(service.bookStore);
      await ledger.upsert(HoldingTransaction.fromLot(_lot('local-lot')));
      final empty = BackupPayloadBuilder.fromRecords(book: _emptyBook);

      await service.import(empty, mode: BackupImportMode.replace);
      expect(await ledger.load(), isEmpty);
    });
  });

  group('a version-4 file', () {
    final bank = BookAccount(id: 'bank', name: 'Bank', side: AccountSide.own, type: AccountType.debit, currency: 'USD');
    final euro = BookAccount(id: 'euro', name: 'Euro', side: AccountSide.own, type: AccountType.debit, currency: 'EUR');
    HoldingTransaction trade(String id, {String currency = 'USD', double price = 1500, DateTime? date}) => HoldingTransaction(
          id: id,
          instrumentID: 'metal.XAU',
          kind: TransactionKind.buy,
          quantity: 2,
          unit: PriceUnit.troyOunce,
          unitPrice: price,
          currency: currency,
          date: date ?? DateTime(2026, 3, 1),
          note: 'note $id',
        );
    const paid = CashLeg(accountId: 'bank', currency: 'USD', amount: 300000, baseAmount: 300000);
    const paidEuro = CashLeg(accountId: 'euro', currency: 'EUR', amount: 150000, baseAmount: 165000);
    final coffee = BookEntry(id: 'coffee', date: DateTime(2026, 3, 2), template: EntryTemplate.spend, baseCurrency: 'USD', merchant: 'Cafe', lines: const [
      EntryLine(accountId: 'bank', amount: -400, currency: 'USD', baseAmount: -400),
      EntryLine(accountId: 'category.dining', amount: 400, currency: 'USD', baseAmount: 400),
    ]);

    /// A book with a trade that moved cash, one that did not, one in a second
    /// currency with its cash, one deleted, one that carries the provenance
    /// of a migration, a plain entry, a recurring payment and settings.
    Future<BackupService> populated() async {
      final service = await makeService();
      final book = service.bookStore;
      await book.accounts.upsert(bank);
      await book.accounts.upsert(euro);
      await book.entries.upsert(coffee);
      final ledger = HoldingsLedger(book);
      await ledger.upsert(trade('t1'), cash: paid, baseCurrency: 'USD', merchant: 'Gold');
      await ledger.upsert(trade('t2'));
      await ledger.upsert(trade('t3', currency: 'EUR', price: 1400), cash: paidEuro, baseCurrency: 'USD', merchant: 'Gold');
      await ledger.upsert(trade('t4'));
      await ledger.delete('t4');
      final migrated = HoldingEntryCodec.toEntry(trade('t5'), cash: paid, baseCurrency: 'USD', merchant: 'Gold')
          .copyWith(legacy: LegacyProvenance(trade: DateTime.utc(2026, 4, 1), cash: DateTime.utc(2026, 4, 2)));
      await book.entries.importRecords([Record<BookEntry>(item: migrated, order: 9, updatedAt: DateTime.utc(2026, 4, 2))], replace: false);
      await book.recurring.upsert(RecurringPayment(id: 'r1', name: 'Gym', amount: 20000, fromAccountId: 'bank', categoryId: 'category.health', start: DateTime(2026, 3, 1)));
      await book.settings.upsert(const MoneySettings(budgets: {'category.dining': 60000}, budgetCurrency: 'USD'));
      return service;
    }

    test('is what the stores hold: no holdings or transactions list, the trades as entries with their lines', () async {
      final service = await populated();
      final file = jsonDecode(await service.buildJson()) as Map<String, dynamic>;
      expect(file['version'], 4);
      expect(BackupEnvelope.currentVersion, 4);
      final payload = file['payload'] as Map<String, dynamic>;
      expect(payload.keys.toSet(), {'watchcards', 'customInstruments', 'alerts', 'settings', 'book'});
      final book = payload['book'] as Map<String, dynamic>;
      expect(book.keys.toSet(), {'accounts', 'entries', 'recurring', 'settings'});

      final exported = await service.bookStore.entries.exportRecords();
      expect(book['entries'], [for (final r in exported) r.toJson()]);
      final records = {for (final r in (book['entries'] as List).cast<Map<String, dynamic>>()) (r['item'] as Map)['id'] as String: r};
      expect(records.keys.toSet(), {'coffee', 't1', 't2', 't3', 't4', 't5'});
      expect((records['t1']!['item'] as Map)['template'], 'holding_buy');
      expect(((records['t1']!['item'] as Map)['lines'] as List).first, containsPair('qty', 200000000));
      expect(records['t4']!['deleted'], isTrue, reason: 'a deleted trade keeps its tombstone');
      expect((records['t5']!['item'] as Map)['legacy'], isNotNull);
      expect(records.values.where((r) => ((r['item'] as Map)['template'] as String) == 'holding_trade'), isEmpty, reason: 'no cash entry beside a trade');
    });

    test('an encrypted file has the same shape inside', () async {
      final service = await populated();
      final json = await service.buildJson(password: 'pw', kdfIterations: 10);
      final preview = await service.preview(service.parseEnvelope(json), password: 'pw');
      expect(preview.payload.isLedger, isTrue);
      expect(preview.payload.book!['entries'], hasLength(6));
    });

    Map<String, List<Map<String, dynamic>>> dump(Map<String, List<Record<Syncable>>> stores, {bool stamps = true}) => {
          for (final e in stores.entries)
            e.key: ([
              for (final r in e.value)
                {
                  ...r.toJson(),
                  if (!stamps) 'updatedAt': null,
                }
            ]..sort((a, b) => ((a['item'] as Map)['id'] as String).compareTo((b['item'] as Map)['id'] as String))),
        };

    Future<Map<String, List<Record<Syncable>>>> stores(BackupService s) async => {
          'accounts': await s.bookStore.accounts.exportRecords(),
          'entries': await s.bookStore.entries.exportRecords(),
          'recurring': await s.bookStore.recurring.exportRecords(),
          'settings': await s.bookStore.settings.exportRecords(),
        };

    for (final mode in BackupImportMode.values) {
      test('export, wipe, restore ($mode) gives the same records in the four stores', () async {
        final source = await populated();
        // Through the file, as a person would. (Building it seeds the default
        // categories, so the records to compare are read after.)
        final json = await source.buildJson();
        final before = dump(await stores(source), stamps: mode == BackupImportMode.merge);
        final beforeRestore = DateTime.now().toUtc();

        final restored = await withSeparateLocalStore(tempDir, () async {
          final target = await makeService();
          final preview = await target.preview(target.parseEnvelope(json));
          expect(preview.transactionCount, 4, reason: 'live trades: the deleted one is not counted');
          await target.import(preview.payload, mode: mode);
          return (await stores(target), dump(await stores(target), stamps: mode == BackupImportMode.merge));
        });
        expect(restored.$2, before);
        expect(before['entries']!.length, 6, reason: 'every record incl. the tombstone, none dropped');
        if (mode == BackupImportMode.replace) {
          // A replace restamps what it writes.
          for (final r in [for (final l in restored.$1.values) ...l]) {
            expect(r.updatedAt.isBefore(beforeRestore), isFalse);
          }
        }
        final entries = {for (final r in restored.$1['entries']!) r.item.id: r as Record<BookEntry>};
        expect(entries['t4']!.deleted, isTrue);
        expect(entries['t5']!.item.legacy, LegacyProvenance(trade: DateTime.utc(2026, 4, 1), cash: DateTime.utc(2026, 4, 2)));
        expect(HoldingEntryCodec.cashLegOf(entries['t1']!.item)?.amount, -300000);
        expect(HoldingEntryCodec.cashLegOf(entries['t2']!.item), isNull);
        expect(HoldingEntryCodec.cashLegOf(entries['t3']!.item)?.currency, 'EUR');
        expect(entries['t3']!.item.lines.first.currency, 'EUR');
      });
    }

    test('the preview of your own file changes nothing, in either mode', () async {
      final service = await populated();
      final preview = await service.preview(service.parseEnvelope(await service.buildJson()));
      expect(preview.mergeDiff.isEmpty, isTrue);
      expect(preview.replaceDiff.added, 0);
      expect(preview.replaceDiff.removed, 0);
      expect(preview.transactionCount, 4);
    });

    test('the preview on an empty device counts the trades with the other entries, and the accounts', () async {
      final json = await (await populated()).buildJson();
      final preview = await withSeparateLocalStore(tempDir, () async {
        final target = await makeService();
        return target.preview(target.parseEnvelope(json));
      });
      // The two accounts and the default categories, and five live entries:
      // four trades and the coffee. The deleted trade adds nothing.
      final accounts = 2 + DefaultCategories.all.length;
      expect(preview.mergeDiff.added, accounts + 5);
      expect(preview.mergeDiff.removed, 0);
      expect(preview.replaceDiff.added, accounts + 5);
      expect(preview.replaceDiff.removed, 0);
    });

    test('a replace removes the trades and entries it lacks, a merge keeps them; the preview says so', () async {
      final json = await (await populated()).buildJson();
      for (final mode in BackupImportMode.values) {
        await withSeparateLocalStore(tempDir, () async {
          final target = await makeService();
          await target.bookStore.entries.upsert(BookEntry(id: 'mine', date: DateTime(2026, 3, 3), template: EntryTemplate.spend, baseCurrency: 'USD', lines: const [
            EntryLine(accountId: 'bank', amount: -100, currency: 'USD', baseAmount: -100),
            EntryLine(accountId: 'category.dining', amount: 100, currency: 'USD', baseAmount: 100),
          ]));
          await HoldingsLedger(target.bookStore).upsert(trade('mine-trade'));
          final preview = await target.preview(target.parseEnvelope(json));
          expect(preview.mergeDiff.removed, 0);
          expect(preview.replaceDiff.removed, 2);
          await target.import(preview.payload, mode: mode);
          final live = (await target.bookStore.entries.load()).map((e) => e.id).toSet();
          expect(live.contains('mine'), mode == BackupImportMode.merge);
          expect(live.contains('mine-trade'), mode == BackupImportMode.merge);
          expect(live.containsAll(['t1', 't2', 't3', 't5', 'coffee']), isTrue);
          expect(live.contains('t4'), isFalse);
        });
      }
    });

    test('a merge keeps the newer record of a trade as a whole, cash leg and all', () async {
      final service = await populated();
      final file = jsonDecode(await service.buildJson()) as Map<String, dynamic>;
      final entries = ((file['payload'] as Map)['book'] as Map)['entries'] as List;
      final t1 = entries.cast<Map<String, dynamic>>().singleWhere((r) => (r['item'] as Map)['id'] == 't1');
      // The file's copy of t1 is older, and has no cash: the device's stays.
      final bare = HoldingEntryCodec.toEntry(trade('t1', price: 1)).toJson();
      t1['item'] = bare;
      t1['updatedAt'] = '2000-01-01T00:00:00.000Z';
      final older = jsonEncode(file);
      final preview = await service.preview(service.parseEnvelope(older));
      expect(preview.mergeDiff.updated, 0);
      await service.import(preview.payload, mode: BackupImportMode.merge);
      var t = (await service.bookStore.entries.load()).singleWhere((e) => e.id == 't1');
      expect(HoldingEntryCodec.cashLegOf(t)?.amount, -300000);

      // Newer, it wins as a whole record: the cash leg goes with the old one.
      t1['updatedAt'] = '2099-01-01T00:00:00.000Z';
      final newer = await service.preview(service.parseEnvelope(jsonEncode(file)));
      expect(newer.mergeDiff.updated, 1);
      await service.import(newer.payload, mode: BackupImportMode.merge);
      t = (await service.bookStore.entries.load()).singleWhere((e) => e.id == 't1');
      expect(HoldingEntryCodec.cashLegOf(t), isNull);
      expect(t.lines.first.unitPrice, 1);
    });

    test('a file with no book is corrupted, not an empty ledger that would wipe the trades', () async {
      final service = await populated();
      final file = jsonDecode(await service.buildJson()) as Map<String, dynamic>;
      (file['payload'] as Map).remove('book');
      await expectLater(
        () => service.preview(service.parseEnvelope(jsonEncode(file))),
        throwsA(isA<BackupError>().having((e) => e.kind, 'kind', BackupErrorKind.corrupted)),
      );
    });

    test('a file from a later version is refused, whatever it holds', () async {
      final service = await populated();
      final file = jsonDecode(await service.buildJson()) as Map<String, dynamic>;
      file['version'] = BackupEnvelope.currentVersion + 1;
      expect(
        () => service.parseEnvelope(jsonEncode(file)),
        throwsA(isA<BackupError>().having((e) => e.kind, 'kind', BackupErrorKind.newerVersion)),
      );
    });
  });

  group('an older file', () {
    final cashId = LegacyCollapse.holdingCashId('t1');
    const at = '2026-03-01T10:00:00.000Z';
    const settings = {'baseCurrency': 'USD', 'appLanguage': 'system', 'appearance': 'system', 'preferredChartRange': 'month1', 'widgetRefreshInterval': 15};
    Map<String, dynamic> rec(Map<String, dynamic> item, {double order = 0, String stamp = at, bool deleted = false}) =>
        {'item': item, 'order': order, 'updatedAt': stamp, 'deleted': deleted};
    Map<String, dynamic> buy(String id, {double qty = 2, double price = 1500}) => {
          'id': id,
          'instrumentID': 'metal.XAU',
          'kind': 'buy',
          'quantity': qty,
          'unit': 'troyOunce',
          'unitPrice': price,
          'currency': 'USD',
          'date': '2026-03-01T09:00:00.000Z',
          'note': 'first',
        };
    final lot = {
      'id': 'l1',
      'instrumentID': 'metal.XAU',
      'quantity': 3.0,
      'unit': 'troyOunce',
      'unitCost': 1900.0,
      'costCurrency': 'USD',
      'date': '2026-01-01T09:00:00.000Z',
    };
    final bankAccount = {'id': 'bank', 'name': 'Bank', 'side': 'own', 'type': 'debit', 'currency': 'USD'};
    final coffeeEntry = {
      'id': 'coffee',
      'date': '2026-03-02T09:00:00.000Z',
      'template': 'spend',
      'base': 'USD',
      'lines': [
        {'account': 'bank', 'amount': -400, 'currency': 'USD', 'base': -400},
        {'account': 'category.dining', 'amount': 400, 'currency': 'USD', 'base': 400},
      ],
      'merchant': 'Cafe',
    };
    final cashEntry = {
      'id': cashId,
      'date': '2026-03-01T09:00:00.000Z',
      'template': 'holding_trade',
      'base': 'USD',
      'lines': [
        {'account': 'bank', 'amount': -300000, 'currency': 'USD', 'base': -300000},
        {'account': 'system.holdings', 'amount': 300000, 'currency': 'USD', 'base': 300000},
      ],
      'merchant': 'Gold',
    };

    String file(int version, Map<String, dynamic> payload) => jsonEncode({
          'format': 'qima-backup',
          'version': version,
          'createdAt': '2026-03-10T00:00:00.000Z',
          'app': {'version': '4.0.0', 'build': '1'},
          'encrypted': false,
          'payload': {'watchcards': [], 'customInstruments': [], 'alerts': [], 'settings': settings, ...payload},
        });

    /// A version-3 file as a 5.0 build wrote it: the trades as transactions,
    /// the cash one moved as an entry of its own, the other entries as they are.
    final v3 = file(3, {
      'holdings': [],
      'transactions': [rec(buy('t1')), rec(buy('t2', qty: 1, price: 1400), order: 1)],
      'book': {
        'accounts': [rec(bankAccount)],
        'entries': [rec(coffeeEntry, order: 1), rec(cashEntry, order: 2)],
        'recurring': [],
        'settings': [],
      },
    });
    // The lots of a version-2 file are the rows its transactions came from.
    final v2 = file(2, {
      'holdings': [rec({...lot, 'id': 't1'})],
      'transactions': [rec(buy('t1')), rec(buy('t2', qty: 1, price: 1400), order: 1)],
    });
    final v1 = file(1, {'holdings': [rec(lot)]});

    Map<String, dynamic> tradeOf(HoldingTransaction t) => {'id': t.id, 'kind': t.kind.name, 'quantity': t.quantity, 'price': t.unitPrice};

    Future<List<Map<String, dynamic>>> trades(BackupService s) async =>
        [for (final t in await HoldingsLedger(s.bookStore).load()) tradeOf(t)]..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));

    test('v3 with a book: the trade and its cash become one entry, the bank stays where it was', () async {
      for (final mode in BackupImportMode.values) {
        await withSeparateLocalStore(tempDir, () async {
          final target = await makeService();
          final preview = await target.preview(target.parseEnvelope(v3));
          expect(preview.payload.isLedger, isFalse);
          expect(preview.transactionCount, 2);
          // The bank, two trades and the coffee; the cash entry folds into t1.
          expect(preview.mergeDiff.added, 4);
          expect(preview.replaceDiff.added, 4);
          await target.import(preview.payload, mode: mode);
          final entries = await target.bookStore.entries.load();
          expect(entries.map((e) => e.id).toSet(), {'t1', 't2', 'coffee'});
          expect(entries.where((e) => e.template == EntryTemplate.holdingTrade), isEmpty);
          final t1 = entries.singleWhere((e) => e.id == 't1');
          expect(HoldingEntryCodec.cashLegOf(t1)?.amount, -300000);
          expect(t1.merchant, 'Gold');
          expect(HoldingEntryCodec.cashLegOf(entries.singleWhere((e) => e.id == 't2')), isNull);
          expect(await trades(target), [
            {'id': 't1', 'kind': 'buy', 'quantity': 2.0, 'price': 1500.0},
            {'id': 't2', 'kind': 'buy', 'quantity': 1.0, 'price': 1400.0},
          ]);
          expect((await target.bookStore.accounts.load()).map((a) => a.id), contains('bank'));
          // The cash entry is not a live entry, so the books balance as before.
          final raw = await target.bookStore.entries.exportRecords();
          expect(raw.singleWhere((r) => r.item.id == cashId).deleted, isTrue);
        });
      }
    });

    test('v3 over a device that has the same data changes nothing', () async {
      final service = await makeService();
      final first = await service.preview(service.parseEnvelope(v3));
      await service.import(first.payload, mode: BackupImportMode.merge);
      final again = await service.preview(service.parseEnvelope(v3));
      expect(again.mergeDiff.isEmpty, isTrue);
      expect(again.replaceDiff.removed, 0);
    });

    test('v2 with transactions and no book restores the transactions, and the lot they came from adds nothing', () async {
      for (final mode in BackupImportMode.values) {
        await withSeparateLocalStore(tempDir, () async {
          final target = await makeService();
          final preview = await target.preview(target.parseEnvelope(v2));
          expect(preview.payload.book, isNull);
          expect(preview.transactionCount, 2);
          expect(preview.mergeDiff.added, 2);
          await target.import(preview.payload, mode: mode);
          expect((await trades(target)).map((t) => t['id']), ['t1', 't2']);
        });
      }
    });

    test('the preview counts the accounts trades were paid from that a replace takes away, only for a file with no book', () async {
      final target = await makeService();
      final ledger = HoldingsLedger(target.bookStore);
      HoldingTransaction deviceBuy(String id) => HoldingTransaction(
          id: id, instrumentID: 'metal.XAU', kind: TransactionKind.buy, quantity: 2, unit: PriceUnit.troyOunce, unitPrice: 1500, currency: 'USD', date: DateTime(2026, 3, 1));
      const leg = CashLeg(accountId: 'bank', currency: 'USD', amount: 300000, baseAmount: 300000);
      await ledger.upsert(deviceBuy('paid1'), cash: leg, baseCurrency: 'USD');
      await ledger.upsert(deviceBuy('paid2'), cash: leg, baseCurrency: 'USD');
      await ledger.upsert(deviceBuy('held'));
      await ledger.upsert(deviceBuy('gone'), cash: leg, baseCurrency: 'USD');
      await ledger.delete('gone');
      for (final old in [v2, v1]) {
        expect((await target.preview(target.parseEnvelope(old))).cashSidesReplaced, 2);
      }
      // A file with a book brings the cash back with its trades, and a file
      // of this version is the whole book.
      expect((await target.preview(target.parseEnvelope(v3))).cashSidesReplaced, 0);
      final own = BackupCodec.encodePlain(payload: await target.buildPayload(), app: const BackupAppInfo(version: '5', build: '1'));
      expect((await target.preview(target.parseEnvelope(own))).cashSidesReplaced, 0);
    });

    test('v1 with lots only restores each as a buy', () async {
      for (final mode in BackupImportMode.values) {
        await withSeparateLocalStore(tempDir, () async {
          final target = await makeService();
          final preview = await target.preview(target.parseEnvelope(v1));
          expect(preview.transactionCount, 1);
          expect(preview.mergeDiff.added, 1);
          await target.import(preview.payload, mode: mode);
          expect(await trades(target), [
            {'id': 'l1', 'kind': 'buy', 'quantity': 3.0, 'price': 1900.0},
          ]);
        });
      }
    });

    test('a deleted lot is not restored', () async {
      final json = file(1, {'holdings': [rec(lot, deleted: true)]});
      final service = await makeService();
      final preview = await service.preview(service.parseEnvelope(json));
      expect(preview.mergeDiff.added, 0);
      await service.import(preview.payload, mode: BackupImportMode.replace);
      expect(await trades(service), isEmpty);
    });

    test('a file without holdings is corrupted before version 4', () async {
      final json = jsonEncode({
        'format': 'qima-backup',
        'version': 3,
        'createdAt': '2026-03-10T00:00:00.000Z',
        'app': {'version': '4.0.0', 'build': '1'},
        'encrypted': false,
        'payload': {'watchcards': [], 'customInstruments': [], 'alerts': [], 'settings': settings, 'transactions': []},
      });
      final service = await makeService();
      await expectLater(
        () => service.preview(service.parseEnvelope(json)),
        throwsA(isA<BackupError>().having((e) => e.kind, 'kind', BackupErrorKind.corrupted)),
      );
    });

    group('a file with no book', () {
      final bank = BookAccount(id: 'bank', name: 'Bank', side: AccountSide.own, type: AccountType.debit, currency: 'USD');
      final coffee = BookEntry(id: 'coffee', date: DateTime(2026, 3, 2), template: EntryTemplate.spend, baseCurrency: 'USD', merchant: 'Cafe', lines: const [
        EntryLine(accountId: 'bank', amount: -400, currency: 'USD', baseAmount: -400),
        EntryLine(accountId: 'category.dining', amount: 400, currency: 'USD', baseAmount: 400),
      ]);
      const paid = CashLeg(accountId: 'bank', currency: 'USD', amount: 300000, baseAmount: 300000);
      final t1 = HoldingTransaction(id: 't1', instrumentID: 'metal.XAU', kind: TransactionKind.buy, quantity: 2, unit: PriceUnit.troyOunce, unitPrice: 1500, currency: 'USD', date: DateTime(2026, 3, 1), note: 'first');

      Future<BackupService> withTrade() async {
        final service = await makeService();
        await service.bookStore.accounts.upsert(bank);
        await service.bookStore.entries.upsert(coffee);
        await HoldingsLedger(service.bookStore).upsert(t1, cash: paid, baseCurrency: 'USD', merchant: 'Gold');
        return service;
      }

      Future<Set<String>> liveIds(BackupService s) async => (await s.bookStore.entries.load()).map((e) => e.id).toSet();

      test('in replace mode it replaces the trades and leaves every money entry and account', () async {
        final service = await withTrade();
        final json = file(2, {
          'holdings': [],
          'transactions': [rec(buy('t9'))],
        });
        final preview = await service.preview(service.parseEnvelope(json));
        expect(preview.replaceDiff.added, 1);
        expect(preview.replaceDiff.removed, 1, reason: 't1 goes; the coffee is not counted');
        await service.import(preview.payload, mode: BackupImportMode.replace);
        expect(await liveIds(service), {'t9', 'coffee'});
        expect((await service.bookStore.accounts.load()).map((a) => a.id), contains('bank'));
        final coffeeNow = (await service.bookStore.entries.load()).singleWhere((e) => e.id == 'coffee');
        expect(coffeeNow, coffee);
      });

      test('in replace mode a trade the file has is the file\'s whole record: the cash leg it lacks goes', () async {
        final service = await withTrade();
        final json = file(2, {
          'holdings': [],
          'transactions': [rec(buy('t1'))],
        });
        final preview = await service.preview(service.parseEnvelope(json));
        expect(preview.replaceDiff.updated, 1);
        expect(preview.replaceDiff.removed, 0);
        await service.import(preview.payload, mode: BackupImportMode.replace);
        final now = (await service.bookStore.entries.load()).singleWhere((e) => e.id == 't1');
        expect(HoldingEntryCodec.cashLegOf(now), isNull);
        expect(await liveIds(service), {'t1', 'coffee'});
      });

      test('in replace mode a trade the file lacks goes with its cash leg, and the bank follows the entry', () async {
        final service = await withTrade();
        final json = file(1, {'holdings': []});
        await service.import((await service.preview(service.parseEnvelope(json))).payload, mode: BackupImportMode.replace);
        expect(await liveIds(service), {'coffee'});
      });

      test('in merge mode the device\'s trade keeps its cash leg while the file\'s copy is not newer', () async {
        final service = await withTrade();
        // Older than the device's record.
        final older = file(2, {
          'holdings': [],
          'transactions': [rec(buy('t1'), stamp: '2020-01-01T00:00:00.000Z')],
        });
        final preview = await service.preview(service.parseEnvelope(older));
        expect(preview.mergeDiff.isEmpty, isTrue);
        await service.import(preview.payload, mode: BackupImportMode.merge);
        final now = (await service.bookStore.entries.load()).singleWhere((e) => e.id == 't1');
        expect(HoldingEntryCodec.cashLegOf(now)?.amount, -300000);
      });

      test('in merge mode the same stamp as the migrated record keeps the cash leg', () async {
        final service = await makeService();
        final stamp = DateTime.utc(2026, 3, 1, 10);
        final migrated = HoldingEntryCodec.toEntry(t1, cash: paid, baseCurrency: 'USD', merchant: 'Gold').copyWith(legacy: LegacyProvenance(trade: stamp, cash: stamp));
        await service.bookStore.entries.importRecords([Record<BookEntry>(item: migrated, order: 0, updatedAt: stamp)], replace: false);
        final json = file(2, {
          'holdings': [],
          'transactions': [rec(buy('t1'))],
        });
        final preview = await service.preview(service.parseEnvelope(json));
        expect(preview.mergeDiff.isEmpty, isTrue);
        await service.import(preview.payload, mode: BackupImportMode.merge);
        final now = (await service.bookStore.entries.load()).singleWhere((e) => e.id == 't1');
        expect(HoldingEntryCodec.cashLegOf(now)?.amount, -300000);
      });

      test('in merge mode a newer copy of the trade in the file wins as a whole record, its cash leg gone', () async {
        final service = await withTrade();
        final newer = file(2, {
          'holdings': [],
          'transactions': [rec(buy('t1', price: 1600), stamp: '2099-01-01T00:00:00.000Z')],
        });
        final preview = await service.preview(service.parseEnvelope(newer));
        expect(preview.mergeDiff.updated, 1);
        await service.import(preview.payload, mode: BackupImportMode.merge);
        final now = (await service.bookStore.entries.load()).singleWhere((e) => e.id == 't1');
        expect(HoldingEntryCodec.cashLegOf(now), isNull);
        expect(now.lines.first.unitPrice, 1600);
        expect(await liveIds(service), {'t1', 'coffee'});
      });

      test('in merge mode nothing is removed and the money entries are not touched', () async {
        final service = await withTrade();
        final json = file(2, {
          'holdings': [],
          'transactions': [rec(buy('t9'))],
        });
        final preview = await service.preview(service.parseEnvelope(json));
        expect(preview.mergeDiff.removed, 0);
        await service.import(preview.payload, mode: BackupImportMode.merge);
        expect(await liveIds(service), {'t1', 't9', 'coffee'});
      });
    });
  });

  group('diff counts', () {
    test('merge diff: added/updated/removed reflect what the merge would actually do', () async {
      final service = await makeService();
      await service.watchlistStore.upsert(_card('existing'));
      final imported = await withSeparateLocalStore(tempDir, () async {
        final other = await makeService();
        await other.watchlistStore.upsert(_card('new-item'));
        return other.watchlistStore.exportRecords();
      });

      final preview = await service.preview(
        BackupCodec.parseEnvelope(
          BackupCodec.encodePlain(
            payload: BackupPayloadBuilder.fromRecords(watchcards: imported, book: _emptyBook),
            app: _testAppInfo,
          ),
        ),
      );

      expect(preview.mergeDiff.added, 1); // "new-item" only.
      expect(preview.mergeDiff.removed, 0); // merge never removes.
    });

    test('replace diff: counts the existing item as removed when not re-imported', () async {
      final service = await makeService();
      await service.watchlistStore.upsert(_card('existing'));
      final imported = await withSeparateLocalStore(tempDir, () async {
        final other = await makeService();
        await other.watchlistStore.upsert(_card('new-item'));
        return other.watchlistStore.exportRecords();
      });

      final preview = await service.preview(
        BackupCodec.parseEnvelope(
          BackupCodec.encodePlain(
            payload: BackupPayloadBuilder.fromRecords(watchcards: imported, book: _emptyBook),
            app: _testAppInfo,
          ),
        ),
      );

      expect(preview.replaceDiff.added, 1);
      expect(preview.replaceDiff.removed, 1); // "existing" gets tombstoned.
    });
  });

  group('atomicity on failed import', () {
    test('nothing changes when the file fails to parse before any store is touched', () async {
      final service = await makeService();
      await service.watchlistStore.upsert(_card('c1'));

      expect(
        () => service.parseEnvelope('not a qima backup file'),
        throwsA(isA<BackupError>()),
      );

      final cards = await service.watchlistStore.load();
      expect(cards.map((c) => c.id), ['c1']); // untouched.
    });

    test('nothing changes when the password is wrong', () async {
      final service = await makeService();
      await service.watchlistStore.upsert(_card('c1'));
      final payload = await service.buildPayload();
      // A low test iteration count (see `BackupCrypto.encrypt`'s doc
      // comment) — this test is about the wrong-password error path, not
      // the KDF's real cost, and decoding always reads `kdf.iterations`
      // back from the file regardless.
      final json = await BackupCodec.encodeEncrypted(
        payload: payload,
        app: _testAppInfo,
        password: 'right',
        kdfIterations: 10,
      );
      final envelope = service.parseEnvelope(json);

      await expectLater(
        () => service.preview(envelope, password: 'wrong'),
        throwsA(isA<BackupError>()),
      );

      final cards = await service.watchlistStore.load();
      expect(cards.map((c) => c.id), ['c1']); // untouched — preview never writes anyway.
    });
  });

  group('reminder due logic', () {
    test('never backed up + data changed + reminder on => due', () async {
      final service = await makeService();
      await service.setReminderEnabled(true);
      await service.setDataChangedSinceLastBackup(true);
      expect(service.isReminderDue(), isTrue);
    });

    test('reminder off => never due, even with stale data', () async {
      final service = await makeService();
      await service.setReminderEnabled(false);
      await service.setDataChangedSinceLastBackup(true);
      expect(service.isReminderDue(), isFalse);
    });

    test('no data changed since last backup => not due, regardless of elapsed time', () async {
      final service = await makeService();
      await service.setReminderEnabled(true);
      await service.setDataChangedSinceLastBackup(false);
      await service.setLastBackupAt(DateTime.now().subtract(const Duration(days: 400)));
      expect(service.isReminderDue(), isFalse);
    });

    test('backed up 29 days ago with changed data => not yet due', () async {
      final service = await makeService();
      await service.setReminderEnabled(true);
      await service.setDataChangedSinceLastBackup(true);
      final now = DateTime(2026, 3, 1);
      await service.setLastBackupAt(now.subtract(const Duration(days: 29)));
      expect(service.isReminderDue(now: now), isFalse);
    });

    test('backed up 31 days ago with changed data => due', () async {
      final service = await makeService();
      await service.setReminderEnabled(true);
      await service.setDataChangedSinceLastBackup(true);
      final now = DateTime(2026, 3, 1);
      await service.setLastBackupAt(now.subtract(const Duration(days: 31)));
      expect(service.isReminderDue(now: now), isTrue);
    });

    test('shouldNotifyReminder caps at once per 30 days even if due repeatedly', () async {
      final service = await makeService();
      await service.setReminderEnabled(true);
      await service.setDataChangedSinceLastBackup(true);
      final now = DateTime(2026, 3, 1);
      await service.setLastBackupAt(now.subtract(const Duration(days: 40)));
      await service.setReminderNotifiedAt(now.subtract(const Duration(days: 5)));

      expect(service.isReminderDue(now: now), isTrue); // still due for the in-app card...
      expect(service.shouldNotifyReminder(now: now), isFalse); // ...but already notified recently.
    });

    test('shouldNotifyReminder fires again once 30 days pass since the last notification', () async {
      final service = await makeService();
      await service.setReminderEnabled(true);
      await service.setDataChangedSinceLastBackup(true);
      final now = DateTime(2026, 3, 1);
      await service.setLastBackupAt(now.subtract(const Duration(days: 70)));
      await service.setReminderNotifiedAt(now.subtract(const Duration(days: 31)));

      expect(service.shouldNotifyReminder(now: now), isTrue);
    });
  });
}

const _testAppInfo = BackupAppInfo(version: '1.0.0', build: '1');

/// A book with nothing in it: the ledger shape of a payload with no trades.
const _emptyBook = <String, List<Map<String, dynamic>>>{'accounts': [], 'entries': [], 'recurring': [], 'settings': []};

/// Test-only helper for constructing a [BackupPayload] from raw exported
/// [Record] lists (what `SyncedStore.exportRecords`/`Store.exportRecords`
/// return), since production code always goes through
/// `BackupService.buildPayload` for a full payload but these tests want to
/// exercise merge/replace/diff behavior against a deliberately partial one.
extension BackupPayloadBuilder on BackupPayload {
  static BackupPayload fromRecords({
    List<dynamic> watchcards = const [],
    List<dynamic> holdings = const [],
    // Null leaves the payload as a pre-ledger (v2.x) backup would be.
    List<dynamic>? transactions,
    List<dynamic> customInstruments = const [],
    List<dynamic> alerts = const [],
    BackupSettings? settings,
    Map<String, List<Map<String, dynamic>>>? book,
  }) {
    return BackupPayload(
      watchcards: watchcards.map((r) => (r as dynamic).toJson() as Map<String, dynamic>).toList(),
      holdings: holdings.map((r) => (r as dynamic).toJson() as Map<String, dynamic>).toList(),
      transactions: transactions?.map((r) => (r as dynamic).toJson() as Map<String, dynamic>).toList(),
      customInstruments: customInstruments.map((r) => (r as dynamic).toJson() as Map<String, dynamic>).toList(),
      alerts: alerts.map((r) => (r as dynamic).toJson() as Map<String, dynamic>).toList(),
      settings: settings ??
          const BackupSettings(
            baseCurrency: 'USD',
            appLanguage: 'system',
            appearance: 'system',
            preferredChartRange: 'month1',
            widgetRefreshInterval: 15,
          ),
      book: book,
    );
  }
}

extension _SettingsCopy on BackupSettings {
  BackupSettings copyWithBaseCurrency(String value) => BackupSettings(
        baseCurrency: value,
        appLanguage: appLanguage,
        appearance: appearance,
        preferredChartRange: preferredChartRange,
        widgetRefreshInterval: widgetRefreshInterval,
      );
}
