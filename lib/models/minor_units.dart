import 'dart:math' as math;

import 'money.dart';

/// How many decimal places a currency's smallest unit has (ISO 4217), and
/// conversion between major amounts and whole minor units.
///
/// The money ledger stores every amount as an integer count of minor units
/// (halalas, piastres, fils) so sums are exact: a balance never drifts by a
/// fraction of a halala however many lines it adds up.
abstract final class MinorUnits {
  /// Currencies whose minor unit is a thousandth.
  static const Set<String> _three = {'BHD', 'IQD', 'JOD', 'KWD', 'LYD', 'OMR', 'TND'};

  /// Currencies with no minor unit in use.
  static const Set<String> _zero = {
    'BIF', 'CLP', 'DJF', 'GNF', 'ISK', 'JPY', 'KMF', 'KRW', 'PYG', 'RWF', 'UGX', 'VND', 'VUV', 'XAF', 'XOF', 'XPF',
  };

  /// Decimal places of [currency]'s minor unit. Two unless listed above.
  static int digits(String currency) {
    if (_three.contains(currency)) return 3;
    if (_zero.contains(currency)) return 0;
    return 2;
  }

  static int _scale(String currency) => math.pow(10, digits(currency)).toInt();

  /// [major] in whole minor units of [currency], rounded half away from zero.
  static int fromMajor(num major, String currency) => (major * _scale(currency)).round();

  /// [minor] units of [currency] as a major amount, for display and FX maths.
  static double toMajor(int minor, String currency) => minor / _scale(currency);

  /// [minor] units of [from] as whole minor units of [to] at [rates],
  /// rounded half away from zero, or null when either rate is missing.
  ///
  /// The one place a ledger amount changes currency: every total converts
  /// each currency's exact sum once, so no screen can round differently
  /// from another.
  static int? convert(int minor, String from, String to, FXRates rates) {
    if (from == to) return minor;
    final major = convertToMajor(minor, from, to, rates);
    return major == null ? null : fromMajor(major, to);
  }

  /// As [convert], left as a major amount for figures that join market
  /// values (holdings at live prices), which are not whole minor units.
  static double? convertToMajor(int minor, String from, String to, FXRates rates) {
    final major = toMajor(minor, from);
    if (from == to) return major;
    final f = rates.rate(from), t = rates.rate(to);
    if (f == null || t == null) return null;
    return major / f * t;
  }
}
