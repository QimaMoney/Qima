import 'package:equatable/equatable.dart';

/// How often a consumer price figure is published.
enum InflationFrequency {
  monthly(12),
  quarterly(4),
  annual(1);

  /// How many periods of this length make a year.
  final int perYear;

  const InflationFrequency(this.perYear);
}

/// One month, quarter or year of a price series.
class InflationPeriod extends Equatable implements Comparable<InflationPeriod> {
  final InflationFrequency frequency;
  final int year;

  /// The month (1 to 12) or quarter (1 to 4) within [year]; 1 for a year.
  final int part;

  const InflationPeriod.month(this.year, int month)
      : frequency = InflationFrequency.monthly,
        part = month;

  const InflationPeriod.quarter(this.year, int quarter)
      : frequency = InflationFrequency.quarterly,
        part = quarter;

  const InflationPeriod.year(this.year)
      : frequency = InflationFrequency.annual,
        part = 1;

  /// The period of [frequency] that [date] falls in, by the date's own
  /// calendar fields.
  factory InflationPeriod.containing(InflationFrequency frequency, DateTime date) => switch (frequency) {
        InflationFrequency.monthly => InflationPeriod.month(date.year, date.month),
        InflationFrequency.quarterly => InflationPeriod.quarter(date.year, (date.month - 1) ~/ 3 + 1),
        InflationFrequency.annual => InflationPeriod.year(date.year),
      };

  static final RegExp _keyPattern = RegExp(r'^(\d{4})(?:-([MQ])(\d{1,2}))?$');

  /// Reads the feed's own period names: `2024`, `2024-Q1`, `2024-M01`.
  /// Null for anything else, or for a month or quarter that does not exist.
  static InflationPeriod? tryParse(String key) {
    final match = _keyPattern.firstMatch(key);
    if (match == null) return null;
    final year = int.parse(match.group(1)!);
    final kind = match.group(2);
    if (kind == null) return InflationPeriod.year(year);
    final part = int.parse(match.group(3)!);
    final frequency = kind == 'M' ? InflationFrequency.monthly : InflationFrequency.quarterly;
    if (part < 1 || part > frequency.perYear) return null;
    return InflationPeriod._(frequency, year, part);
  }

  const InflationPeriod._(this.frequency, this.year, this.part);

  /// The name [tryParse] reads back.
  String get key => switch (frequency) {
        InflationFrequency.monthly => '$year-M${part.toString().padLeft(2, '0')}',
        InflationFrequency.quarterly => '$year-Q$part',
        InflationFrequency.annual => '$year',
      };

  int get _ordinal => year * frequency.perYear + part - 1;

  InflationPeriod _shifted(int periods) {
    final ordinal = _ordinal + periods;
    return InflationPeriod._(frequency, ordinal ~/ frequency.perYear, ordinal % frequency.perYear + 1);
  }

  /// The month, quarter or year just before this one.
  InflationPeriod get previous => _shifted(-1);

  /// The same month or quarter a year earlier; the year before, for a year.
  InflationPeriod get yearBefore => _shifted(-frequency.perYear);

  /// The first instant of the period, in UTC.
  DateTime get start => DateTime.utc(year, (part - 1) * (12 ~/ frequency.perYear) + 1);

  /// Oldest first. Periods of different lengths that start together sort
  /// from the shortest to the longest.
  @override
  int compareTo(InflationPeriod other) {
    final byStart = start.compareTo(other.start);
    return byStart != 0 ? byStart : frequency.index.compareTo(other.frequency.index);
  }

  @override
  List<Object?> get props => [frequency, year, part];
}

/// The inflation rate over the year that ends with [period].
class InflationPoint extends Equatable {
  final InflationPeriod period;

  /// A fraction: 0.14 is 14%.
  final double rate;

  const InflationPoint({required this.period, required this.rate});

  @override
  List<Object?> get props => [period, rate];
}

/// What is known about consumer prices in one country.
///
/// Prices are kept as index levels, not rates, because every rate (over a
/// month, a quarter, a year, or between any two periods) comes from two
/// levels. Yearly rates from a second source cover the years, and the
/// countries, the index does not reach.
class InflationSeries extends Equatable {
  /// ISO 3166-1 alpha-3, upper case.
  final String country;

  /// Consumer price index levels. Their base year differs by country and
  /// changes over time, so a level means something only against another
  /// level of the same series.
  final Map<InflationPeriod, double> index;

  /// Yearly rates as fractions, by year, used where [index] has no answer.
  final Map<int, double> annualRates;

  /// When both sources last answered. The epoch when they never both have.
  final DateTime fetchedAt;

  const InflationSeries({
    required this.country,
    this.index = const {},
    this.annualRates = const {},
    required this.fetchedAt,
  });

  bool get isEmpty => index.isEmpty && annualRates.isEmpty;

  /// The change in prices from [from] to [to] as a fraction, or null when
  /// either level is missing. Both must be of the same frequency.
  double? change(InflationPeriod from, InflationPeriod to) {
    final before = index[from], after = index[to];
    if (from.frequency != to.frequency || before == null || after == null || before <= 0) return null;
    return after / before - 1;
  }

  /// The change over the year that ends with [period]: a month against the
  /// same month a year earlier, a quarter against the same quarter, a year
  /// against the year before.
  double? rate(InflationPeriod period) {
    final fromIndex = change(period.yearBefore, period);
    if (fromIndex != null) return fromIndex;
    return period.frequency == InflationFrequency.annual ? annualRates[period.year] : null;
  }

  /// The change from the period just before [period].
  double? changeFromPrevious(InflationPeriod period) => change(period.previous, period);

  /// Every period of [frequency] that has a yearly rate, oldest first.
  List<InflationPoint> history(InflationFrequency frequency) {
    final periods = <InflationPeriod>{
      for (final period in index.keys)
        if (period.frequency == frequency) period,
      if (frequency == InflationFrequency.annual)
        for (final year in annualRates.keys) InflationPeriod.year(year),
    }.toList()
      ..sort();
    final points = <InflationPoint>[];
    for (final period in periods) {
      final value = rate(period);
      if (value != null) points.add(InflationPoint(period: period, rate: value));
    }
    return points;
  }

  /// The newest period of [frequency] that has a yearly rate.
  InflationPoint? latest(InflationFrequency frequency) {
    final points = history(frequency);
    return points.isEmpty ? null : points.last;
  }

  /// The shortest period this country publishes prices for.
  InflationFrequency? get finestFrequency {
    for (final frequency in InflationFrequency.values) {
      if (latest(frequency) != null) return frequency;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'index': {for (final entry in index.entries) entry.key.key: entry.value},
        'annualRates': {for (final entry in annualRates.entries) '${entry.key}': entry.value},
        'fetchedAt': fetchedAt.toUtc().toIso8601String(),
      };

  /// Entries that cannot be read are left out, so one bad figure never
  /// costs the rest of the series.
  factory InflationSeries.fromJson(String country, Map<String, dynamic> json) {
    final index = <InflationPeriod, double>{};
    (json['index'] as Map<String, dynamic>? ?? const {}).forEach((key, value) {
      final period = InflationPeriod.tryParse(key);
      if (period != null && value is num) index[period] = value.toDouble();
    });
    final annualRates = <int, double>{};
    (json['annualRates'] as Map<String, dynamic>? ?? const {}).forEach((key, value) {
      final year = int.tryParse(key);
      if (year != null && value is num) annualRates[year] = value.toDouble();
    });
    return InflationSeries(
      country: country,
      index: index,
      annualRates: annualRates,
      fetchedAt: DateTime.parse(json['fetchedAt'] as String),
    );
  }

  @override
  List<Object?> get props => [country, index, annualRates, fetchedAt];
}
