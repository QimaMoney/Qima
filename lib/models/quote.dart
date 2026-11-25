import 'package:equatable/equatable.dart';

/// A single canonical-USD price sample for an instrument.
class Quote extends Equatable {
  final String instrumentID;
  final DateTime timestamp;
  final double canonicalUSD;

  /// The extremes of the span this sample stands for (a feed bar, or the
  /// calendar day it was collapsed into), in canonical USD like
  /// [canonicalUSD]. Null when only the price is known, as for a live quote.
  final double? high;
  final double? low;

  const Quote({required this.instrumentID, required this.timestamp, required this.canonicalUSD, this.high, this.low});

  Map<String, dynamic> toJson() => {
        'instrumentID': instrumentID,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'canonicalUSD': canonicalUSD,
        if (high != null) 'high': high,
        if (low != null) 'low': low,
      };

  factory Quote.fromJson(Map<String, dynamic> json) => Quote(
        instrumentID: json['instrumentID'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
        canonicalUSD: (json['canonicalUSD'] as num).toDouble(),
        high: (json['high'] as num?)?.toDouble(),
        low: (json['low'] as num?)?.toDouble(),
      );

  /// This sample with its extremes replaced.
  Quote withExtremes({required double high, required double low}) =>
      Quote(instrumentID: instrumentID, timestamp: timestamp, canonicalUSD: canonicalUSD, high: high, low: low);

  @override
  List<Object?> get props => [instrumentID, timestamp, canonicalUSD, high, low];
}

String _minuteKey(DateTime t) {
  final local = t.toLocal();
  return 'm-${local.year}-${local.month}-${local.day}-${local.hour}-${local.minute}';
}

String _dayKey(DateTime t) {
  final local = t.toLocal();
  final startOfDay = DateTime(local.year, local.month, local.day);
  return 'd-${startOfDay.millisecondsSinceEpoch}';
}

/// The extremes and sample count of one collapsed calendar day.
class _DaySpan {
  double high;
  double low;
  int count = 1;

  _DaySpan(Quote q)
      : high = q.high ?? q.canonicalUSD,
        low = q.low ?? q.canonicalUSD;

  void add(Quote q) {
    count += 1;
    final qHigh = q.high ?? q.canonicalUSD;
    final qLow = q.low ?? q.canonicalUSD;
    if (qHigh > high) high = qHigh;
    if (qLow < low) low = qLow;
  }
}

/// Keeps full detail for samples at or after [intradayCutoff] (one per
/// calendar minute) and collapses every older calendar day to one sample.
/// Shared by [QuoteSeries.appending] and [QuoteSeries.merging] so the two
/// can never disagree about what a stored day looks like.
///
/// - The sample with the greatest timestamp stands for its bucket, and on a
///   tie the later one in [input] does (the new one: callers put new samples
///   last).
/// - A collapsed day's sample takes the highest high and lowest low over
///   every sample of that day in [input], kept or not, a sample without
///   extremes counting by its price. A daily bar stamped at the market open
///   (it carries the day's close, high and low) therefore loses to a later
///   sample as the day's price, yet still widens its range.
/// - The earliest calendar day present also keeps its first sample. For a
///   new listing that sample is the price it started at, the one fact about
///   it people look for, and keeping only the day's last sample would start
///   the chart at the close of that day instead. On a tie the earlier one in
///   [input] is the first, so a daily bar stamped at the open, which carries
///   the day's close, never takes the place of the bar the day opened with. The rule follows the
///   earliest day in [input], so when a backfill adds earlier days the former
///   first day is no longer the earliest and collapses to one sample at the
///   next merge. An instrument with years of daily history has one sample on
///   its earliest day, so nothing changes for it.
List<Quote> _collapsed(Iterable<Quote> input, DateTime intradayCutoff) {
  final byKey = <String, Quote>{};
  final spans = <String, _DaySpan>{};
  Quote? first;
  for (final q in input) {
    final older = q.timestamp.isBefore(intradayCutoff);
    final key = older ? _dayKey(q.timestamp) : _minuteKey(q.timestamp);
    if (older) {
      final span = spans[key];
      if (span == null) {
        spans[key] = _DaySpan(q);
      } else {
        span.add(q);
      }
    }
    final existing = byKey[key];
    if (existing == null || !q.timestamp.isBefore(existing.timestamp)) {
      byKey[key] = q;
    }
    if (first == null || q.timestamp.isBefore(first.timestamp)) first = q;
  }

  final out = <Quote>[];
  for (final entry in byKey.entries) {
    final span = spans[entry.key];
    final q = entry.value;
    // A day of one sample is left exactly as it was stored.
    out.add(span == null || span.count < 2 ? q : q.withExtremes(high: span.high, low: span.low));
  }
  if (first != null && first.timestamp.isBefore(intradayCutoff)) {
    final dayLast = byKey[_dayKey(first.timestamp)];
    // Two samples at one instant are one sample: the winner stands.
    if (dayLast != null && first.timestamp.isBefore(dayLast.timestamp)) out.add(first);
  }
  out.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  return out;
}

/// Ordered (ascending by timestamp) history of quotes for one instrument.
class QuoteSeries extends Equatable {
  final String instrumentID;
  final List<Quote> quotes;

  QuoteSeries({required this.instrumentID, List<Quote>? quotes})
      : quotes = List.unmodifiable(_sorted(quotes ?? const []));

  static List<Quote> _sorted(List<Quote> quotes) {
    final copy = List<Quote>.of(quotes);
    copy.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return copy;
  }

  static QuoteSeries empty(String instrumentID) => QuoteSeries(instrumentID: instrumentID);

  /// How far back samples keep their minute; older ones collapse to one a
  /// calendar day.
  static const Duration intradayWindow = Duration(days: 2);

  bool get isEmpty => quotes.isEmpty;

  Quote? get latest => quotes.isEmpty ? null : quotes.last;

  Quote? get earliest => quotes.isEmpty ? null : quotes.first;

  double get absoluteChangeUSD {
    if (quotes.length < 2) return 0;
    return quotes.last.canonicalUSD - quotes.first.canonicalUSD;
  }

  double get percentChange {
    if (quotes.length < 2) return 0;
    final first = quotes.first.canonicalUSD;
    if (first == 0) return 0;
    return (quotes.last.canonicalUSD - first) / first;
  }

  bool get isTrendingUp => absoluteChangeUSD >= 0;

  /// Appends a live quote, de-duping any existing quote in the same
  /// device-local calendar minute (newest wins). Samples older than 2 days
  /// are first collapsed to one point per calendar day (the same approach
  /// [merging] uses for backfilled history) so that a long-running foreground
  /// refresh — which only ever calls this method — can't slowly evict years
  /// of daily history by filling [limit] with recent one-minute samples.
  /// Keeps at most [limit] most-recent samples after collapsing, so on a
  /// series that long the earliest day, and with it its extra first sample,
  /// can be what is trimmed.
  QuoteSeries appending(Quote quote, {int limit = 2000, DateTime? now}) {
    final effectiveNow = now ?? quote.timestamp;
    final merged = _collapsed([...quotes, quote], effectiveNow.subtract(intradayWindow));
    final trimmed = merged.length > limit ? merged.sublist(merged.length - limit) : merged;
    return QuoteSeries(instrumentID: instrumentID, quotes: trimmed);
  }

  /// Backfill merge: samples within 2 days of [now] are keyed per-minute;
  /// older samples collapse to one per calendar day. The greater timestamp
  /// wins a collision, and on a tie the new sample does, so a re-fetched
  /// bar replaces the copy stored while it was still forming. A collapsed
  /// day keeps the extremes of every sample that took part in the merge, and
  /// the earliest day also keeps its first sample (see [_collapsed]).
  ///
  /// With [replacing], every existing sample inside that span is dropped
  /// first: the new samples are the whole record of it, so samples from
  /// another source never interleave with them.
  QuoteSeries merging(
    List<Quote> newQuotes,
    DateTime now, {
    int limit = 2000,
    ({DateTime from, DateTime to})? replacing,
  }) {
    bool replaced(Quote q) =>
        replacing != null && !q.timestamp.isBefore(replacing.from) && !q.timestamp.isAfter(replacing.to);

    final merged = _collapsed([...quotes.where((q) => !replaced(q)), ...newQuotes], now.subtract(intradayWindow));
    final trimmed = merged.length > limit ? merged.sublist(merged.length - limit) : merged;
    return QuoteSeries(instrumentID: instrumentID, quotes: trimmed);
  }

  Map<String, dynamic> toJson() => {
        'instrumentID': instrumentID,
        'quotes': quotes.map((q) => q.toJson()).toList(),
      };

  factory QuoteSeries.fromJson(Map<String, dynamic> json) => QuoteSeries(
        instrumentID: json['instrumentID'] as String,
        quotes: (json['quotes'] as List<dynamic>)
            .map((e) => Quote.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  @override
  List<Object?> get props => [instrumentID, quotes];
}
