import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/instrument_facts.dart';
import '../models/instrument_fundamentals.dart';
import 'local_file_store.dart';

/// A stock's or index's facts from Yahoo Finance's chart endpoint, the one
/// prices already come from: the day's figures from a one-day chart, and
/// dividends and splits from a ten-year one. Valuation and financials come
/// from its fundamentals series, and the earnings date, beta and returns
/// from its quote summary, which needs a session (a cookie and a token).
/// Never throws; null on any failure.
class YahooFactsProvider {
  final http.Client client;
  final String host;

  YahooFactsProvider({http.Client? client, this.host = 'https://query1.finance.yahoo.com', this.sessionUrl = 'https://fc.yahoo.com'})
      : client = client ?? http.Client();

  /// Any page that sets Yahoo's session cookie.
  final String sessionUrl;

  static const _headers = {'User-Agent': 'Mozilla/5.0'};

  /// The cookie and token the quote summary needs, kept for the app's run.
  ({String cookie, String crumb})? _session;

  Future<Map<String, dynamic>?> _chart(String symbol, String query) async {
    try {
      final response = await client.get(Uri.parse('$host/v8/finance/chart/${Uri.encodeComponent(symbol)}?$query'), headers: _headers);
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
    final opens = ((((result?['indicators'] as Map?)?['quote'] as List?)?.firstOrNull as Map?)?['open'] as List?) ?? const [];
    return InstrumentFacts(
      currency: currency,
      fetchedAt: now,
      name: name is String && name.trim().isNotEmpty ? name.trim() : null,
      price: number(meta['regularMarketPrice']),
      open: opens.map(number).nonNulls.firstOrNull,
      volume: number(meta['regularMarketVolume']),
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

extension YahooFundamentals on YahooFactsProvider {
  static const _series = [
    'trailingMarketCap',
    'trailingEnterpriseValue',
    'trailingPeRatio',
    'trailingForwardPeRatio',
    'trailingPegRatio',
    'trailingPsRatio',
    'trailingPbRatio',
    'trailingEnterprisesValueEBITDARatio',
    'trailingTotalRevenue',
    'trailingNetIncome',
    'trailingDilutedEPS',
    'trailingFreeCashFlow',
    'quarterlyCashAndCashEquivalents',
    'quarterlyTotalDebt',
    'quarterlyStockholdersEquity',
  ];

  /// A stock's valuation, latest financials, average volume, and (when a
  /// session can be had) its next earnings date, beta and returns, quoted in
  /// [currency]. Null when none of it came back.
  Future<InstrumentFundamentals?> fundamentals(String symbol, String currency, DateTime now) async {
    final results = await Future.wait([_timeseries(symbol, now), _averageVolume(symbol), _summary(symbol)]);
    final series = results[0] as Map<String, ({double value, String? currency, DateTime asOf})>;
    final averageVolume = results[1] as double?;
    final summary = results[2] as Map<String, dynamic>?;
    if (series.isEmpty && averageVolume == null && summary == null) return null;

    double? ratio(String key) => series[key]?.value;
    ReportedAmount? amount(String key, {String? fallback}) {
      final v = series[key];
      return v == null ? null : ReportedAmount(v.value, v.currency ?? fallback);
    }

    double? raw(String module, String key) {
      final v = (summary?[module] as Map?)?[key];
      final r = v is Map ? v['raw'] : v;
      return r is num && r.isFinite ? r.toDouble() : null;
    }

    final earnings = (summary?['calendarEvents'] as Map?)?['earnings'] as Map?;
    final dates = [
      for (final d in (earnings?['earningsDate'] as List? ?? const []))
        if (d is Map && d['raw'] is num) DateTime.fromMillisecondsSinceEpoch((d['raw'] as num).toInt() * 1000, isUtc: true),
    ]..sort();
    final upcoming = dates.where((d) => !d.isBefore(DateTime(now.year, now.month, now.day))).firstOrNull;
    // The summary's earnings per share follow the latest quarter; the
    // series can lag one.
    final summaryEps = raw('defaultKeyStatistics', 'trailingEps');
    final financialCurrency = (summary?['financialData'] as Map?)?['financialCurrency'];
    final statedDebt = raw('financialData', 'debtToEquity');
    final reported = [
      for (final key in ['trailingTotalRevenue', 'trailingNetIncome', 'quarterlyCashAndCashEquivalents'])
        if (series[key] case final v?) v.asOf,
    ]..sort();

    return InstrumentFundamentals(
      fetchedAt: now,
      // Market values are in the currency the stock trades in.
      marketCap: amount('trailingMarketCap', fallback: currency),
      enterpriseValue: amount('trailingEnterpriseValue', fallback: currency),
      peRatio: ratio('trailingPeRatio'),
      forwardPe: ratio('trailingForwardPeRatio'),
      pegRatio: ratio('trailingPegRatio'),
      priceToSales: ratio('trailingPsRatio'),
      priceToBook: ratio('trailingPbRatio'),
      evToEbitda: ratio('trailingEnterprisesValueEBITDARatio'),
      beta: raw('summaryDetail', 'beta') ?? raw('defaultKeyStatistics', 'beta'),
      averageVolume: averageVolume,
      nextEarnings: upcoming,
      earningsEstimated: upcoming != null && earnings?['isEarningsDateEstimate'] == true,
      reportedAt: reported.lastOrNull,
      revenue: amount('trailingTotalRevenue'),
      netIncome: amount('trailingNetIncome'),
      eps: summaryEps != null
          ? ReportedAmount(summaryEps, financialCurrency is String ? financialCurrency : currency)
          : amount('trailingDilutedEPS'),
      freeCashFlow: amount('trailingFreeCashFlow'),
      cash: amount('quarterlyCashAndCashEquivalents'),
      totalDebt: amount('quarterlyTotalDebt'),
      equity: amount('quarterlyStockholdersEquity'),
      returnOnEquity: raw('financialData', 'returnOnEquity'),
      returnOnAssets: raw('financialData', 'returnOnAssets'),
      // Stated as a percent.
      statedDebtToEquity: statedDebt == null ? null : statedDebt / 100,
    );
  }

  /// The latest value of each series, with its currency and date. Needs no
  /// session.
  Future<Map<String, ({double value, String? currency, DateTime asOf})>> _timeseries(String symbol, DateTime now) async {
    final to = now.millisecondsSinceEpoch ~/ 1000;
    final from = now.subtract(const Duration(days: 400)).millisecondsSinceEpoch ~/ 1000;
    final out = <String, ({double value, String? currency, DateTime asOf})>{};
    try {
      final uri = Uri.parse('$host/ws/fundamentals-timeseries/v1/finance/timeseries/${Uri.encodeComponent(symbol)}'
          '?type=${_series.join(',')}&period1=$from&period2=$to');
      final response = await client.get(uri, headers: YahooFactsProvider._headers);
      if (response.statusCode != 200) return out;
      final results = ((jsonDecode(response.body) as Map)['timeseries'] as Map?)?['result'];
      if (results is! List) return out;
      for (final r in results) {
        if (r is! Map) continue;
        final type = ((r['meta'] as Map?)?['type'] as List?)?.firstOrNull;
        if (type is! String) continue;
        ({double value, String? currency, DateTime asOf})? latest;
        for (final point in (r[type] as List? ?? const [])) {
          if (point is! Map) continue;
          final value = (point['reportedValue'] as Map?)?['raw'];
          // A calendar day, kept in UTC so it never shifts with the device's zone.
          final day = DateTime.tryParse('${point['asOfDate']}');
          final asOf = day == null ? null : DateTime.utc(day.year, day.month, day.day);
          if (value is! num || !value.isFinite || asOf == null) continue;
          if (latest == null || asOf.isAfter(latest.asOf)) {
            latest = (value: value.toDouble(), currency: point['currencyCode'] as String?, asOf: asOf);
          }
        }
        if (latest != null) out[type] = latest;
      }
    } catch (_) {
      // Partial or none: what was read stands.
    }
    return out;
  }

  /// Average daily volume over three months of daily bars.
  Future<double?> _averageVolume(String symbol) async {
    final result = await _chart(symbol, 'range=3mo&interval=1d');
    final quote = ((result?['indicators'] as Map?)?['quote'] as List?)?.firstOrNull as Map?;
    final volumes = [for (final v in (quote?['volume'] as List? ?? const [])) if (v is num && v > 0) v.toDouble()];
    if (volumes.isEmpty) return null;
    return volumes.reduce((a, b) => a + b) / volumes.length;
  }

  /// The quote summary's beta, returns and earnings dates; null when Yahoo
  /// gives no session (a consent page, say) or has no summary for [symbol].
  /// A rejected token is renewed once.
  Future<Map<String, dynamic>?> _summary(String symbol) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final session = _session ??= await _newSession();
      if (session == null) return null;
      try {
        final uri = Uri.parse('$host/v10/finance/quoteSummary/${Uri.encodeComponent(symbol)}'
            '?modules=summaryDetail,defaultKeyStatistics,financialData,calendarEvents&crumb=${Uri.encodeQueryComponent(session.crumb)}');
        final response = await client.get(uri, headers: {...YahooFactsProvider._headers, 'Cookie': session.cookie});
        if (response.statusCode == 401 || response.statusCode == 403) {
          _session = null;
          continue;
        }
        if (response.statusCode != 200) return null;
        final results = ((jsonDecode(response.body) as Map)['quoteSummary'] as Map?)?['result'];
        return results is List && results.isNotEmpty && results.first is Map<String, dynamic> ? results.first as Map<String, dynamic> : null;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  Future<({String cookie, String crumb})?> _newSession() async {
    try {
      final page = await client.get(Uri.parse(sessionUrl), headers: YahooFactsProvider._headers);
      final cookie = cookieHeader(page.headers['set-cookie']);
      if (cookie == null) return null;
      final crumb = await client.get(Uri.parse('$host/v1/test/getcrumb'), headers: {...YahooFactsProvider._headers, 'Cookie': cookie});
      final token = crumb.body.trim();
      if (crumb.statusCode != 200 || token.isEmpty || token.contains('<')) return null;
      return (cookie: cookie, crumb: token);
    } catch (_) {
      return null;
    }
  }

  /// The `name=value` pairs of a Set-Cookie header, which `http` joins with
  /// commas (as do the expiry dates inside it), as one Cookie header.
  static String? cookieHeader(String? setCookie) {
    if (setCookie == null || setCookie.isEmpty) return null;
    final pairs = [
      for (final part in setCookie.split(RegExp(r',(?=\s*[A-Za-z0-9_\-]+=)')))
        if (part.split(';').first.trim() case final pair when pair.contains('=')) pair,
    ];
    return pairs.isEmpty ? null : pairs.join('; ');
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
