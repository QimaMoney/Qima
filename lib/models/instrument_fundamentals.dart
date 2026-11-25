import 'package:equatable/equatable.dart';

/// An amount a company reported, in the currency it reported it in (Taiwan
/// Semiconductor reports in TWD though it trades in USD).
class ReportedAmount extends Equatable {
  final double value;
  final String? currency;

  const ReportedAmount(this.value, [this.currency]);

  Map<String, dynamic> toJson() => {'value': value, if (currency != null) 'currency': currency};

  static ReportedAmount? fromJson(Object? json) {
    if (json is! Map || json['value'] is! num) return null;
    return ReportedAmount((json['value'] as num).toDouble(), json['currency'] is String ? json['currency'] as String : null);
  }

  @override
  List<Object?> get props => [value, currency];
}

/// A stock's valuation and its latest reported financials. Every figure is
/// optional: smaller exchanges publish only some of them.
class InstrumentFundamentals extends Equatable {
  final DateTime fetchedAt;

  // Valuation, as of the latest close.
  final ReportedAmount? marketCap;
  final ReportedAmount? enterpriseValue;
  final double? peRatio;
  final double? forwardPe;
  final double? pegRatio;
  final double? priceToSales;
  final double? priceToBook;
  final double? evToEbitda;
  final double? beta;

  // Trading.
  final double? averageVolume;

  /// The next earnings report, and whether the company has confirmed it.
  final DateTime? nextEarnings;
  final bool earningsEstimated;

  // The latest report: trailing twelve months, or the quarter's end for the
  // balance sheet.
  final DateTime? reportedAt;
  final ReportedAmount? revenue;
  final ReportedAmount? netIncome;
  final ReportedAmount? eps;
  final ReportedAmount? freeCashFlow;
  final ReportedAmount? cash;
  final ReportedAmount? totalDebt;
  final ReportedAmount? equity;
  final double? returnOnEquity;
  final double? returnOnAssets;

  /// Debt over equity as the exchange's summary states it, leases
  /// included; preferred to [totalDebt] over [equity].
  final double? statedDebtToEquity;

  const InstrumentFundamentals({
    required this.fetchedAt,
    this.marketCap,
    this.enterpriseValue,
    this.peRatio,
    this.forwardPe,
    this.pegRatio,
    this.priceToSales,
    this.priceToBook,
    this.evToEbitda,
    this.beta,
    this.averageVolume,
    this.nextEarnings,
    this.earningsEstimated = false,
    this.reportedAt,
    this.revenue,
    this.netIncome,
    this.eps,
    this.freeCashFlow,
    this.cash,
    this.totalDebt,
    this.equity,
    this.returnOnEquity,
    this.returnOnAssets,
    this.statedDebtToEquity,
  });

  /// Net income as a share of revenue, when both are in one currency.
  double? get profitMargin {
    final r = revenue, n = netIncome;
    if (r == null || n == null || r.value == 0 || r.currency != n.currency) return null;
    return n.value / r.value;
  }

  /// Total debt against shareholders' equity, when both are in one
  /// currency and equity is positive.
  double? get debtToEquity {
    if (statedDebtToEquity != null) return statedDebtToEquity;
    final d = totalDebt, e = equity;
    if (d == null || e == null || e.value <= 0 || d.currency != e.currency) return null;
    return d.value / e.value;
  }

  bool get hasValuation =>
      marketCap != null ||
      enterpriseValue != null ||
      peRatio != null ||
      forwardPe != null ||
      pegRatio != null ||
      priceToSales != null ||
      priceToBook != null ||
      evToEbitda != null ||
      beta != null;

  bool get hasFinancials =>
      revenue != null ||
      netIncome != null ||
      eps != null ||
      freeCashFlow != null ||
      cash != null ||
      debtToEquity != null ||
      returnOnEquity != null ||
      returnOnAssets != null;

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'fetchedAt': fetchedAt.toUtc().toIso8601String(), 'earningsEstimated': earningsEstimated};
    void amount(String key, ReportedAmount? v) {
      if (v != null) json[key] = v.toJson();
    }

    void number(String key, double? v) {
      if (v != null) json[key] = v;
    }

    void date(String key, DateTime? v) {
      if (v != null) json[key] = v.toUtc().toIso8601String();
    }

    amount('marketCap', marketCap);
    amount('enterpriseValue', enterpriseValue);
    number('peRatio', peRatio);
    number('forwardPe', forwardPe);
    number('pegRatio', pegRatio);
    number('priceToSales', priceToSales);
    number('priceToBook', priceToBook);
    number('evToEbitda', evToEbitda);
    number('beta', beta);
    number('averageVolume', averageVolume);
    date('nextEarnings', nextEarnings);
    date('reportedAt', reportedAt);
    amount('revenue', revenue);
    amount('netIncome', netIncome);
    amount('eps', eps);
    amount('freeCashFlow', freeCashFlow);
    amount('cash', cash);
    amount('totalDebt', totalDebt);
    amount('equity', equity);
    number('returnOnEquity', returnOnEquity);
    number('returnOnAssets', returnOnAssets);
    number('statedDebtToEquity', statedDebtToEquity);
    return json;
  }

  static InstrumentFundamentals? fromJson(Object? json) {
    if (json is! Map) return null;
    final fetchedAt = DateTime.tryParse('${json['fetchedAt']}');
    if (fetchedAt == null) return null;
    double? number(String key) => json[key] is num ? (json[key] as num).toDouble() : null;
    DateTime? date(String key) => json[key] == null ? null : DateTime.tryParse('${json[key]}');
    ReportedAmount? amount(String key) => ReportedAmount.fromJson(json[key]);
    return InstrumentFundamentals(
      fetchedAt: fetchedAt,
      marketCap: amount('marketCap'),
      enterpriseValue: amount('enterpriseValue'),
      peRatio: number('peRatio'),
      forwardPe: number('forwardPe'),
      pegRatio: number('pegRatio'),
      priceToSales: number('priceToSales'),
      priceToBook: number('priceToBook'),
      evToEbitda: number('evToEbitda'),
      beta: number('beta'),
      averageVolume: number('averageVolume'),
      nextEarnings: date('nextEarnings'),
      earningsEstimated: json['earningsEstimated'] == true,
      reportedAt: date('reportedAt'),
      revenue: amount('revenue'),
      netIncome: amount('netIncome'),
      eps: amount('eps'),
      freeCashFlow: amount('freeCashFlow'),
      cash: amount('cash'),
      totalDebt: amount('totalDebt'),
      equity: amount('equity'),
      returnOnEquity: number('returnOnEquity'),
      returnOnAssets: number('returnOnAssets'),
      statedDebtToEquity: number('statedDebtToEquity'),
    );
  }

  @override
  List<Object?> get props => [
        fetchedAt,
        marketCap,
        enterpriseValue,
        peRatio,
        forwardPe,
        pegRatio,
        priceToSales,
        priceToBook,
        evToEbitda,
        beta,
        averageVolume,
        nextEarnings,
        earningsEstimated,
        reportedAt,
        revenue,
        netIncome,
        eps,
        freeCashFlow,
        cash,
        totalDebt,
        equity,
        returnOnEquity,
        returnOnAssets,
        statedDebtToEquity,
      ];
}
