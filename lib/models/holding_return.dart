import 'dart:math' as math;

import 'holding_transaction.dart';
import 'instrument_facts.dart';
import 'ledger.dart';

/// One dated amount of money in or out of a holding: negative when the
/// person paid, positive when they received.
typedef CashFlow = ({DateTime date, double amount});

/// What a holding has returned over its whole life, in one currency: what
/// was paid in (buys and fees) against what came back (sales and dividends)
/// plus what it is worth now.
class HoldingReturn {
  /// Shorter than this, a yearly rate is mostly noise.
  static const Duration minimumForYearly = Duration(days: 90);

  final double paidIn;
  final double total;
  final double dividends;

  /// The money-weighted yearly rate, or null when it can't be fairly
  /// stated: held under [minimumForYearly], or shares moved in or out
  /// without a price paid.
  final double? yearly;

  const HoldingReturn({required this.paidIn, required this.total, required this.dividends, this.yearly});

  double get fraction => paidIn <= 0 ? 0 : total / paidIn;

  /// The return on [transactions] of one instrument, with [dividends] paid
  /// on the shares [position] held before each ex-date, and [value] the
  /// holding's worth at [now]. [toDisplay] turns an amount in a currency
  /// into the display currency. Null without anything paid in.
  static HoldingReturn? of({
    required List<HoldingTransaction> transactions,
    required InstrumentPosition? position,
    required List<Dividend> dividends,
    required String dividendCurrency,
    required double value,
    required DateTime now,
    required double Function(double amount, String currency) toDisplay,
  }) {
    final flows = <CashFlow>[];
    var paidIn = 0.0;
    var hasTransfers = false;
    for (final t in transactions) {
      final gross = toDisplay(t.quantity * t.unitPrice, t.currency);
      final fee = toDisplay(t.fee, t.currency);
      switch (t.kind) {
        case TransactionKind.buy:
          flows.add((date: t.date, amount: -(gross + fee)));
          paidIn += gross + fee;
        case TransactionKind.sell:
          flows.add((date: t.date, amount: gross - fee));
        case TransactionKind.fee:
          flows.add((date: t.date, amount: -fee));
          paidIn += fee;
        case TransactionKind.transferIn:
        case TransactionKind.transferOut:
          hasTransfers = true;
      }
    }
    var received = 0.0;
    if (position != null) {
      for (final d in dividends) {
        if (d.date.isAfter(now)) continue;
        final shares = position.fineOuncesOn(d.date.subtract(const Duration(seconds: 1)));
        if (shares <= 0) continue;
        final amount = toDisplay(shares * d.amount, dividendCurrency);
        received += amount;
        flows.add((date: d.date, amount: amount));
      }
    }
    if (paidIn <= 0 || hasTransfers) {
      return paidIn <= 0 ? null : HoldingReturn(paidIn: paidIn, total: _sum(flows) + value, dividends: received);
    }
    flows.add((date: now, amount: value));
    final total = _sum(flows);
    final first = flows.map((f) => f.date).reduce((a, b) => a.isBefore(b) ? a : b);
    final yearly = now.difference(first) < minimumForYearly ? null : xirr(flows);
    return HoldingReturn(paidIn: paidIn, total: total, dividends: received, yearly: yearly);
  }

  static double _sum(List<CashFlow> flows) => flows.fold(0.0, (s, f) => s + f.amount);

  /// The yearly rate that brings [flows] to zero, by bisection; null when
  /// none lies between -99.99% and +10000% a year, or the flows don't both
  /// pay and receive.
  static double? xirr(List<CashFlow> flows) {
    if (flows.length < 2 || !flows.any((f) => f.amount < 0) || !flows.any((f) => f.amount > 0)) return null;
    final start = flows.map((f) => f.date).reduce((a, b) => a.isBefore(b) ? a : b);
    double npv(double rate) {
      var sum = 0.0;
      for (final f in flows) {
        final years = f.date.difference(start).inSeconds / (365.25 * 24 * 3600);
        sum += f.amount / math.pow(1 + rate, years);
      }
      return sum;
    }

    var low = -0.9999, high = 100.0;
    var fLow = npv(low), fHigh = npv(high);
    if (fLow.isNaN || fHigh.isNaN || fLow.sign == fHigh.sign) return null;
    for (var i = 0; i < 200; i++) {
      final mid = (low + high) / 2;
      final fMid = npv(mid);
      if (fMid.abs() < 1e-9) return mid;
      if (fMid.sign == fLow.sign) {
        low = mid;
        fLow = fMid;
      } else {
        high = mid;
      }
    }
    return (low + high) / 2;
  }
}

