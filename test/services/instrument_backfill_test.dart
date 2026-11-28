import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/asset.dart';
import 'package:qima/models/fx_history.dart';
import 'package:qima/models/instrument_catalog.dart';
import 'package:qima/models/quote.dart';
import 'package:qima/services/local_file_store.dart';
import 'package:qima/services/price_repository.dart';
import 'package:qima/services/quote_history_store.dart';
import 'package:qima/services/quote_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Serves one daily bar per day from [from] through [to], and [intraday]
/// for 15-minute requests, recording every daily range it was asked for.
class _FakeHistoryProvider extends YahooHistoryProvider {
  final DateTime from;
  final DateTime to;
  final double close;
  List<Bar> intraday;
  final List<Bar>? daily;
  final List<String> requestedRanges = [];
  int intradayRequests = 0;

  /// The feed's own latest price, when a test gives it one.
  Bar? latest;

  _FakeHistoryProvider(this.from, this.to, {this.close = 4000, this.intraday = const [], this.daily});

  @override
  Future<List<Bar>> bars(String symbol, {String range = '5y', String interval = '1d'}) async {
    if (interval != '1d') {
      intradayRequests++;
      return intraday;
    }
    requestedRanges.add(range);
    if (daily != null) return daily!;
    return [
      for (var d = from; !d.isAfter(to); d = d.add(const Duration(days: 1)))
        Bar(date: d, close: close, currency: 'USD'),
    ];
  }

  @override
  Future<BarHistory> history(String symbol, {String range = '5y', String interval = '1d'}) async =>
      BarHistory(bars: await bars(symbol, range: range, interval: interval), latest: latest);
}

/// The live spot price, or a failure when [price] is null.
class _FakeSpot extends GoldAPIProvider {
  double? price;
  _FakeSpot(this.price);

  @override
  Future<double> canonicalUSDPrice(Instrument instrument) async {
    final value = price;
    if (value == null) throw const PriceError.invalidResponse();
    return value;
  }
}

void main() {
  final gold = InstrumentCatalog.instrument('metal.XAU')!;
  final now = DateTime.utc(2026, 10, 21, 13);
  final store = QuoteHistoryStore();
  late Directory dir;

  setUp(() {
    // History already stored in the current shape, as after the first
    // pull with this version.
    SharedPreferences.setMockInitialValues({'quoteHistoryLevel.${gold.id}': 'ohlc-v2'});
    dir = Directory.systemTemp.createTempSync('qima_backfill_test');
    LocalFileStore.overrideDirectoryForTesting(dir);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  /// Five years of daily closes ending [lastClose], then today's live quote —
  /// the shape a series has after weeks of failed live quotes.
  Future<void> seedGappedHistory(DateTime lastClose) async {
    final quotes = <Quote>[
      for (var d = lastClose.subtract(const Duration(days: 365 * 5)); !d.isAfter(lastClose); d = d.add(const Duration(days: 1)))
        Quote(instrumentID: gold.id, timestamp: d, canonicalUSD: 3000),
      Quote(instrumentID: gold.id, timestamp: now, canonicalUSD: 4137),
    ];
    await store.save(QuoteSeries(instrumentID: gold.id, quotes: quotes));
  }

  /// The last intraday bar closes at 4000, the same as the live price, so
  /// nothing is rescaled unless a test says otherwise.
  List<Bar> intradayBars(DateTime from, DateTime to, {double close = 4000}) => [
        for (var t = from; !t.isAfter(to); t = t.add(const Duration(minutes: 15)))
          Bar(date: t, close: close, currency: 'USD'),
      ];

  PriceRepository repositoryWith(_FakeHistoryProvider provider, {double? spot = 4000}) => PriceRepository(
        historyProvider: provider,
        metalCryptoProvider: _FakeSpot(spot),
        quoteHistoryStore: store,
      );

  test('fills a gap in deep history back to the last daily close', () async {
    final lastClose = DateTime.utc(2026, 8, 19);
    await seedGappedHistory(lastClose);
    final provider = _FakeHistoryProvider(
      lastClose,
      now.subtract(const Duration(days: 1)),
      intraday: intradayBars(now.subtract(const Duration(days: 1)), now.subtract(const Duration(minutes: 15))),
    );

    await repositoryWith(provider).backfillInstruments([gold], FXHistory.empty, now: now);

    expect(provider.requestedRanges, ['3mo']);
    final series = await store.load(gold.id);
    final september = series.quotes.where((q) => q.timestamp.year == 2026 && q.timestamp.month == 9);
    expect(september, hasLength(30));
    expect(series.latest!.canonicalUSD, 4137, reason: "today's live quote survives the merge");
  });

  test('refreshes the tail at most once per interval', () async {
    final lastClose = now.subtract(const Duration(days: 5));
    await seedGappedHistory(lastClose);
    final provider = _FakeHistoryProvider(
      lastClose,
      now.subtract(const Duration(days: 1)),
      intraday: intradayBars(now.subtract(const Duration(days: 1)), now.subtract(const Duration(minutes: 15))),
    );
    final repository = repositoryWith(provider);

    await repository.backfillInstruments([gold], FXHistory.empty, now: now);
    await repository.backfillInstruments([gold], FXHistory.empty, now: now.add(const Duration(hours: 1)));
    expect(provider.requestedRanges, ['1mo']);

    await repository.backfillInstruments([gold], FXHistory.empty, now: now.add(const Duration(hours: 13)));
    expect(provider.requestedRanges, ['1mo', '1mo']);
  });

  test('backs off after a failed tail refresh', () async {
    await seedGappedHistory(DateTime.utc(2026, 8, 19));
    final provider = _FakeHistoryProvider(now, now.subtract(const Duration(days: 1))); // serves no bars
    final repository = repositoryWith(provider);

    await repository.backfillInstruments([gold], FXHistory.empty, now: now);
    await repository.backfillInstruments([gold], FXHistory.empty, now: now.add(const Duration(minutes: 5)));
    expect(provider.requestedRanges, hasLength(1));

    await repository.backfillInstruments([gold], FXHistory.empty, now: now.add(const Duration(minutes: 11)));
    expect(provider.requestedRanges, hasLength(2));
  });

  test('a shallow series still gets the full five-year pull', () async {
    final provider = _FakeHistoryProvider(now.subtract(const Duration(days: 10)), now);

    await repositoryWith(provider).backfillInstruments([gold], FXHistory.empty, now: now);

    expect(provider.requestedRanges, ['5y']);
  });

  group('recent days', () {
    test('15-minute bars replace the live samples and the mis-dated daily bar in their span', () async {
      final today = DateTime.utc(2026, 10, 21, 5); // a daily bar's open, carrying today's latest price
      await store.save(QuoteSeries(instrumentID: gold.id, quotes: [
        Quote(instrumentID: gold.id, timestamp: today, canonicalUSD: 4139.10),
        Quote(instrumentID: gold.id, timestamp: DateTime.utc(2026, 10, 21, 9, 7), canonicalUSD: 3990),
        Quote(instrumentID: gold.id, timestamp: now, canonicalUSD: 4000), // newer than the last bar
      ]));
      final bars = intradayBars(DateTime.utc(2026, 10, 20, 13), now.subtract(const Duration(minutes: 15)));
      final provider = _FakeHistoryProvider(DateTime.utc(2021, 10, 21), today, intraday: bars);

      await repositoryWith(provider).backfillInstruments([gold], FXHistory.empty, now: now);

      final recent = (await store.load(gold.id)).quotes.where((q) => !q.timestamp.isBefore(bars.first.date)).toList();
      expect(recent.map((q) => q.timestamp), [...bars.map((b) => b.date), now]);
      expect(recent.any((q) => q.canonicalUSD == 4139.10 || q.canonicalUSD == 3990), isFalse);
    });

    test('are fetched at most every 15 minutes', () async {
      final provider = _FakeHistoryProvider(
        now.subtract(const Duration(days: 365)),
        now.subtract(const Duration(days: 3)),
        intraday: intradayBars(now.subtract(const Duration(hours: 2)), now),
      );
      final repository = repositoryWith(provider);
      await repository.backfillInstruments([gold], FXHistory.empty, now: now);
      expect(provider.intradayRequests, 1);

      await repository.backfillInstruments([gold], FXHistory.empty, now: now.add(const Duration(minutes: 10)));
      expect(provider.intradayRequests, 1);
      expect(provider.requestedRanges, ['5y'], reason: 'deep history waits for its own interval');

      await repository.backfillInstruments([gold], FXHistory.empty, now: now.add(const Duration(minutes: 16)));
      expect(provider.intradayRequests, 2);
    });
  });

  group('a new listing', () {
    const listing = Instrument(id: 'stock.ZZTEST', symbol: 'ZZTEST', assetClass: AssetClass.stock, nameKey: 'asset.zztest');
    final listingDay = DateTime.utc(2026, 10, 18);

    /// The first day as the feed served it: a reference price at the open, a
    /// stretch of empty bars (which the feed leaves out), then trading that
    /// opened far higher, ranged widely and closed lower.
    List<Bar> firstDay() => [
          Bar(date: listingDay.add(const Duration(hours: 14, minutes: 30)), close: 10, high: 10, low: 10, currency: 'USD'),
          Bar(date: listingDay.add(const Duration(hours: 16, minutes: 30)), close: 24, high: 30, low: 20, currency: 'USD'),
          Bar(date: listingDay.add(const Duration(hours: 18)), close: 12, high: 26, low: 8, currency: 'USD'),
          Bar(date: listingDay.add(const Duration(hours: 20, minutes: 45)), close: 16, high: 17, low: 11, currency: 'USD'),
        ];

    /// The day's daily bar: stamped at the open, carrying the close and the
    /// day's true extremes.
    Bar dailyBar() => Bar(date: listingDay.add(const Duration(hours: 14, minutes: 30)), close: 16, high: 30, low: 8, currency: 'USD');

    PriceRepository repository(_FakeHistoryProvider provider) =>
        PriceRepository(historyProvider: provider, metalCryptoProvider: _FakeSpot(null), quoteHistoryStore: store);

    test('still starts at its first price, with the true high and low, once the day is old', () async {
      final first = listingDay.add(const Duration(hours: 21));
      // Day one: everything is inside the intraday window and kept whole.
      final provider = _FakeHistoryProvider(listingDay, listingDay, intraday: firstDay(), daily: [dailyBar()]);
      await repository(provider).backfillInstruments([listing], FXHistory.empty, now: first);
      expect((await store.load(listing.id)).quotes, hasLength(4));

      // Three days later the feed's five days still reach back, but the
      // stored day has been collapsed by the merges in between.
      final later = listingDay.add(const Duration(days: 3, hours: 13));
      provider.intraday = [
        Bar(date: later.subtract(const Duration(hours: 20)), close: 17, high: 18, low: 16, currency: 'USD'),
        Bar(date: later.subtract(const Duration(minutes: 15)), close: 17.5, high: 18, low: 17, currency: 'USD'),
      ];
      await repository(provider).backfillInstruments([listing], FXHistory.empty, now: later);

      final series = await store.load(listing.id);
      expect(series.quotes.first.canonicalUSD, 10, reason: 'the price the listing started at');
      expect(series.quotes.first.timestamp, firstDay().first.date);
      final dayLast = series.quotes.firstWhere((q) => q.timestamp == firstDay().last.date);
      expect(dayLast.canonicalUSD, 16);
      final high = series.quotes.map((q) => q.high ?? q.canonicalUSD).reduce((a, b) => a > b ? a : b);
      final low = series.quotes.map((q) => q.low ?? q.canonicalUSD).reduce((a, b) => a < b ? a : b);
      expect(high, 30);
      expect(low, 8);
    });
  });

  group('metals and crypto', () {
    test("gold's futures bars are scaled to meet the live spot price", () async {
      final provider = _FakeHistoryProvider(
        now.subtract(const Duration(days: 365)),
        now.subtract(const Duration(days: 3)),
        close: 4040,
        intraday: intradayBars(now.subtract(const Duration(hours: 2)), now, close: 4040),
      );

      await repositoryWith(provider, spot: 4000).backfillInstruments([gold], FXHistory.empty, now: now);

      final series = await store.load(gold.id);
      expect(series.latest!.canonicalUSD, closeTo(4000, 1e-9));
      expect(series.quotes.first.canonicalUSD, closeTo(4000, 1e-9), reason: 'the daily history is at the same level');
    });

    test('a stock is stored as Yahoo prices it, with no live price asked for', () async {
      final tesla = InstrumentCatalog.all.firstWhere((i) => i.assetClass == AssetClass.stock);
      final provider = _FakeHistoryProvider(
        now.subtract(const Duration(days: 365)),
        now.subtract(const Duration(days: 3)),
        close: 350,
        intraday: intradayBars(now.subtract(const Duration(hours: 2)), now, close: 350),
      );

      await repositoryWith(provider, spot: null).backfillInstruments([tesla], FXHistory.empty, now: now);

      expect((await store.load(tesla.id)).latest!.canonicalUSD, 350);
    });

    test('without a live price nothing is stored, rather than bars at the wrong level', () async {
      final provider = _FakeHistoryProvider(
        now.subtract(const Duration(days: 365)),
        now.subtract(const Duration(days: 3)),
        intraday: intradayBars(now.subtract(const Duration(hours: 2)), now),
      );

      final result = await repositoryWith(provider, spot: null).backfillInstruments([gold], FXHistory.empty, now: now);

      expect(result, isEmpty);
      expect((await store.load(gold.id)).isEmpty, isTrue);
    });

    group('whose 15-minute bars stopped a day ago', () {
      // The feed skipped a shortened session: its bars end at 3620 while
      // its own price has gone on to 3698 and spot to 3673.
      final lastBar = now.subtract(const Duration(hours: 28));
      _FakeHistoryProvider stopped({double close = 3620}) => _FakeHistoryProvider(
            now.subtract(const Duration(days: 365)),
            now.subtract(const Duration(days: 3)),
            close: close,
            intraday: intradayBars(lastBar.subtract(const Duration(hours: 2)), lastBar, close: close),
          );

      test('are leveled by the feed\'s own latest price, not by their last bar', () async {
        final provider = stopped()..latest = Bar(date: now.subtract(const Duration(minutes: 10)), close: 3698, currency: 'USD');

        await repositoryWith(provider, spot: 3673).backfillInstruments([gold], FXHistory.empty, now: now);

        final series = await store.load(gold.id);
        expect(series.latest!.timestamp, lastBar);
        expect(series.latest!.canonicalUSD, closeTo(3620 * 3673 / 3698, 1e-9), reason: 'the rise since is no part of the level');
        expect(series.quotes.first.canonicalUSD, closeTo(3620 * 3673 / 3698, 1e-9));
      });

      test('keep the level last measured when the feed has no later price', () async {
        final live = stopped(close: 4040)..intraday = intradayBars(now.subtract(const Duration(hours: 2)), now, close: 4040);
        await repositoryWith(live, spot: 4000).backfillInstruments([gold], FXHistory.empty, force: true, now: now);

        await repositoryWith(stopped(), spot: 3673).backfillInstruments([gold], FXHistory.empty, force: true, now: now);

        final stored = (await store.load(gold.id)).quotes.firstWhere((q) => q.timestamp == lastBar);
        expect(stored.canonicalUSD, closeTo(3620 * 4000 / 4040, 1e-9), reason: 'not 3673, which a day of trading lies before');
      });

      test('are not stored while no level was ever measured', () async {
        final result = await repositoryWith(stopped(), spot: 3673).backfillInstruments([gold], FXHistory.empty, now: now);

        expect(result, isEmpty);
        expect((await store.load(gold.id)).isEmpty, isTrue);
      });

      test('still meet a live price from before a weekend', () async {
        // Sunday morning: nothing has traded since Friday's close.
        final sunday = DateTime.utc(2026, 10, 25, 9);
        final fridayClose = DateTime.utc(2026, 10, 23, 20, 45);
        final provider = _FakeHistoryProvider(
          sunday.subtract(const Duration(days: 365)),
          sunday.subtract(const Duration(days: 3)),
          close: 4040,
          intraday: intradayBars(fridayClose.subtract(const Duration(hours: 2)), fridayClose, close: 4040),
        );

        await repositoryWith(provider, spot: 4000).backfillInstruments([gold], FXHistory.empty, now: sunday);

        expect((await store.load(gold.id)).latest!.canonicalUSD, closeTo(4000, 1e-9));
      });
    });

    test('a daily pull replaces days stored at another level', () async {
      // A week of days kept from 15-minute bars an earlier fetch scaled
      // 4% low, each dated at its last bar.
      final days = [for (var d = 9; d >= 3; d--) DateTime.utc(now.year, now.month, now.day - d)];
      await store.save(QuoteSeries(instrumentID: gold.id, quotes: [
        for (final day in days)
          Quote(instrumentID: gold.id, timestamp: day.add(const Duration(hours: 20, minutes: 45)), canonicalUSD: 3840, open: 3830, high: 3850, low: 3820),
      ]));
      final provider = _FakeHistoryProvider(
        days.first,
        days.last,
        daily: [for (final day in days) Bar(date: day.add(const Duration(hours: 5)), open: 3990, close: 4000, high: 4010, low: 3980, currency: 'USD')],
        intraday: intradayBars(now.subtract(const Duration(hours: 2)), now),
      );

      await repositoryWith(provider).backfillInstruments([gold], FXHistory.empty, force: true, now: now);

      final old = (await store.load(gold.id)).quotes.where((q) => q.timestamp.isBefore(now.subtract(const Duration(days: 2))));
      expect(old, hasLength(days.length));
      expect(old.map((q) => q.canonicalUSD).toSet(), {4000});
      expect(old.map((q) => q.low).toSet(), {3980}, reason: 'no extreme left from the other level');
    });

    test("a bar's open is stored, scaled like its close", () async {
      final provider = _FakeHistoryProvider(
        now.subtract(const Duration(days: 365)),
        now.subtract(const Duration(days: 3)),
        daily: [
          for (var d = now.subtract(const Duration(days: 365)); d.isBefore(now.subtract(const Duration(days: 3))); d = d.add(const Duration(days: 1)))
            Bar(date: d, open: 4000, close: 4040, high: 4080, low: 3960, currency: 'USD'),
        ],
        intraday: intradayBars(now.subtract(const Duration(hours: 2)), now, close: 4040),
      );

      await repositoryWith(provider, spot: 4000).backfillInstruments([gold], FXHistory.empty, now: now);

      final first = (await store.load(gold.id)).quotes.first;
      final factor = 4000 / 4040;
      expect(first.canonicalUSD, closeTo(4040 * factor, 1e-9));
      expect(first.open, closeTo(4000 * factor, 1e-9));
      expect(first.high, closeTo(4080 * factor, 1e-9));
    });

    test('a stock stored before bars kept their open is pulled again in full, once', () async {
      SharedPreferences.setMockInitialValues({});
      final tesla = InstrumentCatalog.all.firstWhere((i) => i.assetClass == AssetClass.stock);
      final from = now.subtract(const Duration(days: 365)), to = now.subtract(const Duration(days: 3));
      await store.save(QuoteSeries(instrumentID: tesla.id, quotes: [
        for (var d = from; !d.isAfter(to); d = d.add(const Duration(days: 1)))
          Quote(instrumentID: tesla.id, timestamp: d, canonicalUSD: 350),
      ]));
      final provider = _FakeHistoryProvider(
        from,
        to,
        daily: [
          for (var d = from; !d.isAfter(to); d = d.add(const Duration(days: 1)))
            Bar(date: d, open: 340, close: 350, high: 360, low: 330, currency: 'USD'),
        ],
        intraday: intradayBars(now.subtract(const Duration(hours: 2)), now, close: 350),
      );
      final repository = repositoryWith(provider, spot: null);

      await repository.backfillInstruments([tesla], FXHistory.empty, now: now);
      expect(provider.requestedRanges, ['5y']);
      expect((await store.load(tesla.id)).quotes.first.open, 340);

      await repository.backfillInstruments([tesla], FXHistory.empty, now: now.add(const Duration(minutes: 20)));
      expect(provider.requestedRanges, ['5y'], reason: 'in the new shape now; the tail waits for its interval');
    });

    test('history stored before scaling is pulled again in full, once', () async {
      SharedPreferences.setMockInitialValues({});
      await seedGappedHistory(now.subtract(const Duration(days: 3)));
      final provider = _FakeHistoryProvider(
        now.subtract(const Duration(days: 365 * 5)),
        now.subtract(const Duration(days: 3)),
        intraday: intradayBars(now.subtract(const Duration(hours: 2)), now),
      );
      final repository = repositoryWith(provider);

      await repository.backfillInstruments([gold], FXHistory.empty, now: now);
      expect(provider.requestedRanges, ['5y']);

      await repository.backfillInstruments([gold], FXHistory.empty, now: now.add(const Duration(minutes: 20)));
      expect(provider.requestedRanges, ['5y'], reason: 'leveled now; the tail waits for its interval');
    });
  });

  test("a currency's closes kept from a feed since found wrong are cleared, and today's live samples stay", () async {
    final sar = InstrumentCatalog.instrument('fx.SAR')!;
    await store.save(QuoteSeries(instrumentID: sar.id, quotes: [
      for (var d = DateTime.utc(2026, 6, 1); d.isBefore(DateTime.utc(2026, 10, 15)); d = d.add(const Duration(days: 1)))
        Quote(instrumentID: sar.id, timestamp: d, canonicalUSD: 1 / 3.64),
      Quote(instrumentID: sar.id, timestamp: now, canonicalUSD: 1 / 3.75),
    ]));
    final provider = _FakeHistoryProvider(now, now);

    // The checked history has no SAR: its feed disagreed with the live rate.
    await repositoryWith(provider).backfillInstruments([sar], FXHistory.empty, force: true, now: now);

    final series = await store.load(sar.id);
    expect(series.quotes.map((q) => q.canonicalUSD), [1 / 3.75]);
  });
}
