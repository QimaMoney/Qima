import 'package:equatable/equatable.dart';

/// A cash dividend: [amount] per share in the facts' currency, on its
/// ex-date. Yahoo states it per share as shares stand today, after any later
/// split.
class Dividend extends Equatable {
  final DateTime date;
  final double amount;

  const Dividend({required this.date, required this.amount});

  Map<String, dynamic> toJson() => {'date': date.toUtc().toIso8601String(), 'amount': amount};

  static Dividend? fromJson(Object? json) {
    if (json is! Map) return null;
    final date = DateTime.tryParse('${json['date']}');
    final amount = json['amount'];
    if (date == null || amount is! num) return null;
    return Dividend(date: date, amount: amount.toDouble());
  }

  @override
  List<Object?> get props => [date, amount];
}

/// A split or bonus issue: from its date, every [denominator] shares became
/// [numerator] (11 for 10 is a 10% bonus issue).
class StockSplit extends Equatable {
  final DateTime date;
  final double numerator;
  final double denominator;

  const StockSplit({required this.date, required this.numerator, required this.denominator});

  /// Shares after the split per share before it.
  double get ratio => numerator / denominator;

  /// Identifies this split for [instrumentID] across devices, by its day.
  String keyFor(String instrumentID) {
    final d = date.toUtc();
    return '$instrumentID@${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> toJson() =>
      {'date': date.toUtc().toIso8601String(), 'numerator': numerator, 'denominator': denominator};

  static StockSplit? fromJson(Object? json) {
    if (json is! Map) return null;
    final date = DateTime.tryParse('${json['date']}');
    final numerator = json['numerator'], denominator = json['denominator'];
    if (date == null || numerator is! num || denominator is! num || numerator <= 0 || denominator <= 0) return null;
    return StockSplit(date: date, numerator: numerator.toDouble(), denominator: denominator.toDouble());
  }

  @override
  List<Object?> get props => [date, numerator, denominator];
}

/// What the exchange says about a stock or index beyond its price, in the
/// exchange's own [currency]: the day so far, the year's range, when it last
/// traded, today's session, and its dividends and splits.
class InstrumentFacts extends Equatable {
  /// Beyond this, a price is no longer today's news: a long weekend plus a
  /// holiday stays inside it, a delisted or stuck feed does not.
  static const Duration staleAfter = Duration(days: 7);

  final String currency;

  /// The company's full name, like "Saudi Arabian Oil Company".
  final String? name;
  final double? price;
  final double? previousClose;
  final double? dayHigh;
  final double? dayLow;
  final double? yearHigh;
  final double? yearLow;

  /// When [price] last traded.
  final DateTime? lastTraded;

  /// Today's regular session, or the next one on a day the exchange is shut.
  final DateTime? sessionStart;
  final DateTime? sessionEnd;

  /// Oldest first.
  final List<Dividend> dividends;
  final List<StockSplit> splits;

  /// When the day's figures, and the dividends and splits, were fetched.
  final DateTime fetchedAt;
  final DateTime? eventsFetchedAt;

  const InstrumentFacts({
    required this.currency,
    required this.fetchedAt,
    this.name,
    this.price,
    this.previousClose,
    this.dayHigh,
    this.dayLow,
    this.yearHigh,
    this.yearLow,
    this.lastTraded,
    this.sessionStart,
    this.sessionEnd,
    this.dividends = const [],
    this.splits = const [],
    this.eventsFetchedAt,
  });

  /// The price hasn't traded for [staleAfter], so it shouldn't read as
  /// current.
  bool isStale(DateTime now) => lastTraded != null && now.difference(lastTraded!) > staleAfter;

  /// Dividends per share over the year to [now].
  double trailingDividends(DateTime now) {
    final since = now.subtract(const Duration(days: 365));
    return dividends.where((d) => d.date.isAfter(since)).fold(0.0, (sum, d) => sum + d.amount);
  }

  /// Trailing dividends against [price]; null without both.
  double? yieldOn(DateTime now) {
    final p = price;
    final paid = trailingDividends(now);
    if (p == null || p <= 0 || paid <= 0) return null;
    return paid / p;
  }

  /// These figures with [dividends] and [splits], fetched at [at] (null
  /// when they were never fetched).
  InstrumentFacts withEvents({required List<Dividend> dividends, required List<StockSplit> splits, required DateTime? at}) =>
      InstrumentFacts(
        currency: currency,
        fetchedAt: fetchedAt,
        name: name,
        price: price,
        previousClose: previousClose,
        dayHigh: dayHigh,
        dayLow: dayLow,
        yearHigh: yearHigh,
        yearLow: yearLow,
        lastTraded: lastTraded,
        sessionStart: sessionStart,
        sessionEnd: sessionEnd,
        dividends: dividends,
        splits: splits,
        eventsFetchedAt: at,
      );

  Map<String, dynamic> toJson() => {
        'currency': currency,
        'fetchedAt': fetchedAt.toUtc().toIso8601String(),
        if (name != null) 'name': name,
        if (price != null) 'price': price,
        if (previousClose != null) 'previousClose': previousClose,
        if (dayHigh != null) 'dayHigh': dayHigh,
        if (dayLow != null) 'dayLow': dayLow,
        if (yearHigh != null) 'yearHigh': yearHigh,
        if (yearLow != null) 'yearLow': yearLow,
        if (lastTraded != null) 'lastTraded': lastTraded!.toUtc().toIso8601String(),
        if (sessionStart != null) 'sessionStart': sessionStart!.toUtc().toIso8601String(),
        if (sessionEnd != null) 'sessionEnd': sessionEnd!.toUtc().toIso8601String(),
        'dividends': [for (final d in dividends) d.toJson()],
        'splits': [for (final s in splits) s.toJson()],
        if (eventsFetchedAt != null) 'eventsFetchedAt': eventsFetchedAt!.toUtc().toIso8601String(),
      };

  static InstrumentFacts? fromJson(Object? json) {
    if (json is! Map) return null;
    final currency = json['currency'], fetchedAt = DateTime.tryParse('${json['fetchedAt']}');
    if (currency is! String || fetchedAt == null) return null;
    double? number(String key) => json[key] is num ? (json[key] as num).toDouble() : null;
    DateTime? date(String key) => json[key] == null ? null : DateTime.tryParse('${json[key]}');
    return InstrumentFacts(
      currency: currency,
      fetchedAt: fetchedAt,
      name: json['name'] is String ? json['name'] as String : null,
      price: number('price'),
      previousClose: number('previousClose'),
      dayHigh: number('dayHigh'),
      dayLow: number('dayLow'),
      yearHigh: number('yearHigh'),
      yearLow: number('yearLow'),
      lastTraded: date('lastTraded'),
      sessionStart: date('sessionStart'),
      sessionEnd: date('sessionEnd'),
      dividends: [for (final d in (json['dividends'] as List? ?? const [])) ?Dividend.fromJson(d)],
      splits: [for (final s in (json['splits'] as List? ?? const [])) ?StockSplit.fromJson(s)],
      eventsFetchedAt: date('eventsFetchedAt'),
    );
  }

  @override
  List<Object?> get props => [
        currency,
        name,
        price,
        previousClose,
        dayHigh,
        dayLow,
        yearHigh,
        yearLow,
        lastTraded,
        sessionStart,
        sessionEnd,
        dividends,
        splits,
        fetchedAt,
        eventsFetchedAt,
      ];
}
