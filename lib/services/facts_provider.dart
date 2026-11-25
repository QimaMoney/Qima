import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/instrument_facts.dart';
import 'local_file_store.dart';

/// A stock's or index's facts from Yahoo Finance's chart endpoint, the one
/// prices already come from: the day's figures from a one-day chart, and
/// dividends and splits from a ten-year one. Never throws; null on any
/// failure.
class YahooFactsProvider {
  final http.Client client;
  final String baseUrl;

  YahooFactsProvider({http.Client? client, this.baseUrl = 'https://query1.finance.yahoo.com/v8/finance/chart'})
      : client = client ?? http.Client();

  static const _headers = {'User-Agent': 'Mozilla/5.0'};

  Future<Map<String, dynamic>?> _chart(String symbol, String query) async {
    try {
      final response = await client.get(Uri.parse('$baseUrl/${Uri.encodeComponent(symbol)}?$query'), headers: _headers);
      if (response.statusCode != 200) return null;
      final results = ((jsonDecode(response.body) as Map<String, dynamic>)['chart'] as Map<String, dynamic>)['result'];
      if (results is! List || results.isEmpty) return null;
      return results.first as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// The day's figures for [symbol], fetched at [now].
  Future<InstrumentFacts?> today(String symbol, DateTime now) async {
    final result = await _chart(symbol, 'range=1d&interval=1d');
    final meta = result?['meta'];
    if (meta is! Map<String, dynamic>) return null;
    final currency = meta['currency'];
    if (currency is! String) return null;
    double? number(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
    DateTime? seconds(Object? v) => v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt() * 1000, isUtc: true) : null;
    final regular = (meta['currentTradingPeriod'] as Map?)?['regular'] as Map?;
    final name = meta['longName'] ?? meta['shortName'];
    return InstrumentFacts(
      currency: currency,
      fetchedAt: now,
      name: name is String && name.trim().isNotEmpty ? name.trim() : null,
      price: number(meta['regularMarketPrice']),
      // On a one-day chart this is yesterday's close.
      previousClose: number(meta['chartPreviousClose']),
      dayHigh: number(meta['regularMarketDayHigh']),
      dayLow: number(meta['regularMarketDayLow']),
      yearHigh: number(meta['fiftyTwoWeekHigh']),
      yearLow: number(meta['fiftyTwoWeekLow']),
      lastTraded: seconds(meta['regularMarketTime']),
      sessionStart: seconds(regular?['start']),
      sessionEnd: seconds(regular?['end']),
    );
  }

  /// Dividends and splits over the last ten years, oldest first; null when
  /// the request fails (an empty list is a real answer).
  Future<({List<Dividend> dividends, List<StockSplit> splits})?> events(String symbol) async {
    final result = await _chart(symbol, 'range=10y&interval=3mo&events=div,split');
    if (result == null) return null;
    final events = result['events'] as Map<String, dynamic>? ?? const {};
    DateTime at(Object? v) => DateTime.fromMillisecondsSinceEpoch((v as num).toInt() * 1000, isUtc: true);
    final dividends = <Dividend>[];
    for (final raw in ((events['dividends'] as Map?)?.values ?? const [])) {
      if (raw is Map && raw['amount'] is num && raw['date'] is num && (raw['amount'] as num) > 0) {
        dividends.add(Dividend(date: at(raw['date']), amount: (raw['amount'] as num).toDouble()));
      }
    }
    final splits = <StockSplit>[];
    for (final raw in ((events['splits'] as Map?)?.values ?? const [])) {
      if (raw is Map && raw['numerator'] is num && raw['denominator'] is num && raw['date'] is num) {
        final numerator = (raw['numerator'] as num).toDouble(), denominator = (raw['denominator'] as num).toDouble();
        if (numerator > 0 && denominator > 0 && numerator != denominator) {
          splits.add(StockSplit(date: at(raw['date']), numerator: numerator, denominator: denominator));
        }
      }
    }
    dividends.sort((a, b) => a.date.compareTo(b.date));
    splits.sort((a, b) => a.date.compareTo(b.date));
    return (dividends: dividends, splits: splits);
  }
}

/// Facts for every instrument in one file, `facts.json`.
class FactsStore {
  static const _path = 'facts.json';

  Future<Map<String, InstrumentFacts>> load() async {
    final json = await LocalFileStore.readJson(_path);
    if (json == null) return const {};
    return {for (final e in json.entries) e.key: ?InstrumentFacts.fromJson(e.value)};
  }

  Future<bool> save(Map<String, InstrumentFacts> facts) =>
      LocalFileStore.writeJson(_path, {for (final e in facts.entries) e.key: e.value.toJson()});
}
