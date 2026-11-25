import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/asset.dart';
import 'package:qima/models/book_entry.dart';
import 'package:qima/models/holding_entry_codec.dart';
import 'package:qima/models/holding_transaction.dart';
import 'package:qima/models/ledger.dart';
import 'package:qima/models/metal_breakdown.dart';
import 'package:qima/services/book_store.dart';
import 'package:qima/services/cloud_kv_store.dart';
import 'package:qima/services/holdings_ledger.dart';
import 'package:qima/services/local_file_store.dart';

/// In-memory cloud shared by two simulated devices.
class _FakeCloud implements CloudKVStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> getString(String key) async => _values[key];

  @override
  Future<void> setString(String key, String value) async => _values[key] = value;

  @override
  Future<void> synchronize() async {}

  @override
  Future<bool> accountStatus() async => true;

  @override
  Stream<CloudKVChangeEvent> get didChangeExternally => const Stream.empty();
}

HoldingTransaction _buy(String id, {double quantity = 1, double price = 2000, double fee = 0, TransactionKind kind = TransactionKind.buy}) => HoldingTransaction(
      id: id,
      instrumentID: 'metal.XAU',
      kind: kind,
      quantity: quantity,
      unit: PriceUnit.troyOunce,
      unitPrice: price,
      fee: fee,
      currency: 'USD',
      date: DateTime(2025, 1, 1),
    );

BookEntry _spend(String id) => BookEntry(id: id, date: DateTime(2025, 1, 2), template: EntryTemplate.spend, baseCurrency: 'USD', merchant: 'Cafe', lines: const [
      EntryLine(accountId: 'bank', amount: -700, currency: 'USD', baseAmount: -700),
      EntryLine(accountId: 'category.dining', amount: 700, currency: 'USD', baseAmount: 700),
    ]);

void main() {
  late Directory dir;
  late BookStore book;
  late HoldingsLedger ledger;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('qima_holdings_ledger_test');
    LocalFileStore.overrideDirectoryForTesting(dir);
    book = BookStore();
    ledger = HoldingsLedger(book);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('an empty book has no trades', () async {
    expect(await ledger.load(), isEmpty);
  });

  test('a trade is saved as one entry with its own id, and reads back equal', () async {
    final t = _buy('a', quantity: 2.5, fee: 12.5);
    expect(await ledger.upsert(t), [t]);
    expect(await ledger.load(), [t]);
    final entries = await book.entries.load();
    expect(entries.single.id, 'a');
    expect(entries.single.template, EntryTemplate.holdingBuy);
  });

  test('every kind of trade comes back as it went in, so every figure derived from them is the same', () async {
    HoldingTransaction row(String id, TransactionKind kind, int day, {double quantity = 1, double price = 0, double fee = 0, PriceUnit unit = PriceUnit.gram, GoldKarat? karat, String instrument = 'metal.XAU'}) =>
        HoldingTransaction(
          id: id,
          instrumentID: instrument,
          kind: kind,
          quantity: quantity,
          unit: unit,
          karat: karat,
          unitPrice: price,
          fee: fee,
          currency: 'USD',
          date: DateTime(2026, 1, day),
          note: 'note $id',
        );
    final fixture = [
      row('b1', TransactionKind.buy, 1, quantity: 10.125, price: 61.37, fee: 3.5, karat: GoldKarat.k21),
      row('b2', TransactionKind.buy, 2, quantity: 5, price: 64, unit: PriceUnit.troyOunce),
      row('in', TransactionKind.transferIn, 3, quantity: 2.5, price: 55),
      row('out', TransactionKind.transferOut, 4, quantity: 1),
      row('fee', TransactionKind.fee, 5, quantity: 0, fee: 7.25),
      row('s1', TransactionKind.sell, 6, quantity: 4.0001, price: 70, fee: 1.1),
      row('s2', TransactionKind.sell, 7, quantity: 0.3333, price: 71),
      row('x1', TransactionKind.buy, 8, quantity: 3, price: 25, instrument: 'metal.XAG'),
    ];
    for (final t in fixture) {
      // Some with cash and some without: the cash leg changes no holdings figure.
      if (t.kind == TransactionKind.buy && t.id != 'x1') {
        final cost = (t.totalCost * 100).round();
        await ledger.upsert(t, cash: CashLeg(accountId: 'bank', currency: 'USD', amount: cost, baseAmount: cost), baseCurrency: 'USD', merchant: 'Gold');
      } else {
        await ledger.upsert(t);
      }
    }
    final loaded = await ledger.load();
    expect(loaded, fixture);
    expect(Ledger.derive(loaded), Ledger.derive(fixture));
    expect(Ledger.derive(loaded).openLots, Ledger.derive(fixture).openLots);
  });

  test('trades come back in the order they were added, and an edit keeps its place', () async {
    await ledger.upsert(_buy('b'));
    await ledger.upsert(_buy('a'));
    await ledger.upsert(_buy('c'));
    expect((await ledger.load()).map((t) => t.id), ['b', 'a', 'c']);
    await ledger.upsert(_buy('a', quantity: 7));
    final loaded = await ledger.load();
    expect(loaded.map((t) => t.id), ['b', 'a', 'c']);
    expect(loaded[1].quantity, 7);
  });

  test('the cash leg is part of the one entry, and is replaced by the next save', () async {
    final t = _buy('a', quantity: 1, price: 100);
    const cash = CashLeg(accountId: 'bank', currency: 'USD', amount: 10000, baseAmount: 10000);
    await ledger.upsert(t, cash: cash, baseCurrency: 'USD', merchant: 'Gold');
    var entry = (await book.entries.load()).single;
    expect(HoldingEntryCodec.cashLegOf(entry)?.accountId, 'bank');
    expect(entry.merchant, 'Gold');
    expect(entry.issues, isEmpty);

    await ledger.upsert(t, baseCurrency: 'USD');
    entry = (await book.entries.load()).single;
    expect(HoldingEntryCodec.cashLegOf(entry), isNull, reason: 'the caller says the cash leg on every save; nothing is carried over');
    expect(await book.entries.load(), hasLength(1));
  });

  test('an edit keeps the source and posted date of the stored entry, follows the new status, and drops the legacy provenance', () async {
    final stored = HoldingEntryCodec.toEntry(_buy('a')).copyWith(
      source: EntrySource.import,
      postedDate: DateTime(2025, 1, 5),
      status: EntryStatus.pending,
      legacy: LegacyProvenance(trade: DateTime.utc(2025, 1, 3)),
    );
    await book.entries.upsert(stored);
    expect((await book.entries.load()).single.legacy, isNotNull);

    await ledger.upsert(_buy('a', quantity: 3));
    final edited = (await book.entries.load()).single;
    expect(edited.source, EntrySource.import);
    expect(edited.postedDate, DateTime(2025, 1, 5));
    expect(edited.status, EntryStatus.posted);
    expect(edited.legacy, isNull);
    expect((await ledger.load()).single.quantity, 3);
  });

  test('a trade saved for the first time is typed, with no posted date, and a deleted one saved again starts over', () async {
    await ledger.upsert(_buy('a'));
    final first = (await book.entries.load()).single;
    expect(first.source, EntrySource.typed);
    expect(first.postedDate, isNull);

    await book.entries.upsert(first.copyWith(source: EntrySource.import, postedDate: DateTime(2025, 1, 5)));
    await ledger.delete('a');
    await ledger.upsert(_buy('a'));
    final again = (await book.entries.load()).single;
    expect(again.source, EntrySource.typed);
    expect(again.postedDate, isNull);
  });

  test('delete removes the trade and its cash with it; deleting what is not there changes nothing', () async {
    await ledger.upsert(_buy('a'), cash: const CashLeg(accountId: 'bank', currency: 'USD', amount: 200000, baseAmount: 200000), baseCurrency: 'USD');
    await ledger.upsert(_buy('b'));
    expect((await ledger.delete('a')).map((t) => t.id), ['b']);
    expect(await book.entries.load(), hasLength(1));
    expect((await ledger.delete('nope')).map((t) => t.id), ['b']);
  });

  test('addAll adds a batch in one commit after what is there, and leaves an id it has seen as it is', () async {
    await ledger.upsert(_buy('old'));
    await ledger.delete('gone');
    final added = await ledger.addAll([_buy('x'), _buy('y')]);
    expect(added.map((t) => t.id), ['old', 'x', 'y']);
    final again = await ledger.addAll([_buy('x', quantity: 9), _buy('z')]);
    expect(again.map((t) => t.id), ['old', 'x', 'y', 'z']);
    expect(again.firstWhere((t) => t.id == 'x').quantity, 1);
  });

  test('deleteAll undoes a batch and touches nothing else', () async {
    await ledger.upsert(_buy('keep'));
    await ledger.addAll([_buy('x'), _buy('y')]);
    expect((await ledger.deleteAll(['x', 'y'])).map((t) => t.id), ['keep']);
    expect((await ledger.deleteAll(const [])).map((t) => t.id), ['keep']);
  });

  group('the rest of the book', () {
    test('is not changed by addAll', () async {
      await book.entries.upsert(_spend('s1'));
      await ledger.addAll([_buy('x')]);
      final records = await book.entries.exportRecords();
      expect(records.singleWhere((r) => r.item.id == 's1').deleted, isFalse);
      expect((await book.entries.load()).map((e) => e.id).toSet(), {'s1', 'x'});
      expect((await ledger.load()).map((t) => t.id), ['x']);
    });

    test('is not deleted by deleteAll or delete, whatever ids are given', () async {
      await book.entries.upsert(_spend('s1'));
      await ledger.upsert(_buy('x'));
      final before = (await book.entries.exportRecords()).singleWhere((r) => r.item.id == 's1');
      await ledger.deleteAll(['s1', 'x']);
      await ledger.delete('s1');
      final after = (await book.entries.exportRecords()).singleWhere((r) => r.item.id == 's1');
      expect(after.deleted, isFalse);
      expect(after.updatedAt, before.updatedAt);
      expect(after.order, before.order);
      expect((await book.entries.load()).map((e) => e.id), ['s1']);
    });

    test('is not replaced by a trade that has its id', () async {
      await book.entries.upsert(_spend('s1'));
      await expectLater(ledger.upsert(_buy('s1')), throwsStateError);
      expect((await book.entries.load()).single.template, EntryTemplate.spend);
    });

    test('is not reordered by a trade being saved', () async {
      await book.entries.upsert(_spend('s1'));
      await book.entries.upsert(_spend('s2'));
      final before = {for (final r in await book.entries.exportRecords()) r.item.id: (r.order, r.updatedAt)};
      await ledger.upsert(_buy('x'));
      await ledger.upsert(_buy('x', quantity: 3));
      final after = {for (final r in await book.entries.exportRecords()) r.item.id: (r.order, r.updatedAt)};
      expect(after['s1'], before['s1']);
      expect(after['s2'], before['s2']);
    });

    test('an entry that is not a trade is not read as one, and a trade that cannot be read is left as it is', () async {
      await book.entries.upsert(_spend('s1'));
      final lost = BookEntry(id: 'lost', date: DateTime(2025, 1, 3), template: EntryTemplate.holdingBuy, baseCurrency: 'USD', lines: const [
        EntryLine(accountId: 'bank', amount: -100, currency: 'USD', baseAmount: -100),
        EntryLine(accountId: 'system.holdings', amount: 100, currency: 'USD', baseAmount: 100),
      ]);
      await book.entries.upsert(lost);
      await ledger.upsert(_buy('x'));
      expect((await ledger.load()).map((t) => t.id), ['x']);
      expect(await book.entries.load(), hasLength(3));
    });
  });

  group('an entry that would not be sound', () {
    test('is refused by upsert with what is wrong, and nothing is written', () async {
      await ledger.upsert(_buy('a'));
      // A fee too small to be a minor unit moves nothing at all.
      final nothing = _buy('b', kind: TransactionKind.fee, quantity: 0, price: 0, fee: 0.001);
      final error = await ledger.upsert(nothing).then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<HoldingRejected>());
      expect((error! as HoldingRejected).issues, isNotEmpty);
      expect((error as HoldingRejected).message, isNotEmpty);
      expect((await ledger.load()).map((t) => t.id), ['a']);
      expect(await book.entries.load(), hasLength(1));
    });

    test('is refused by upsert when the cash leg cannot balance, and the earlier version stays', () async {
      final t = _buy('a');
      await ledger.upsert(t);
      // Cash paid out for a trade that cost nothing, in another currency: the
      // two sides have no common amount.
      const cash = CashLeg(accountId: 'bank', currency: 'EGP', amount: 500, baseAmount: 100);
      await expectLater(ledger.upsert(t.copyWith(unitPrice: 0), cash: cash, baseCurrency: 'SAR'), throwsA(isA<HoldingRejected>()));
      expect((await ledger.load()).single.unitPrice, 2000);
    });

    test('refuses the whole batch of addAll', () async {
      await expectLater(ledger.addAll([_buy('x'), _buy('y', kind: TransactionKind.fee, quantity: 0, price: 0, fee: 0.001)]), throwsA(isA<HoldingRejected>()));
      expect(await ledger.load(), isEmpty);
    });
  });

  test('two devices through one cloud converge on the same trades', () async {
    final cloud = _FakeCloud();
    final a = HoldingsLedger(BookStore(cloud: cloud));
    await a.upsert(_buy('a'));

    // Device B: fresh local files, the same cloud.
    final otherDir = await Directory.systemTemp.createTemp('qima_holdings_ledger_b');
    LocalFileStore.overrideDirectoryForTesting(otherDir);
    try {
      final b = HoldingsLedger(BookStore(cloud: cloud));
      expect((await b.load()).map((t) => t.id), ['a']);
      await b.delete('a');
    } finally {
      LocalFileStore.overrideDirectoryForTesting(dir);
      await otherDir.delete(recursive: true);
    }
    expect(await a.load(), isEmpty);
  });
}
