import 'package:intl/intl.dart';

import '../models/currency_style.dart';
import '../models/instrument_fundamentals.dart';
import '../models/money.dart';

/// Large figures the way market pages write them: 5.07T, 478.83B, 43.59M,
/// 12.40K, and smaller ones in full.
String bigNumber(double value, [String? locale]) {
  final m = value.abs();
  final (scaled, suffix) = m >= 1e12
      ? (m / 1e12, 'T')
      : m >= 1e9
          ? (m / 1e9, 'B')
          : m >= 1e6
              ? (m / 1e6, 'M')
              : m >= 1e4
                  ? (m / 1e3, 'K')
                  : (m, '');
  final number = NumberFormat.decimalPatternDigits(locale: locale, decimalDigits: suffix.isEmpty && scaled == scaled.roundToDouble() ? 0 : 2)
      .format(scaled);
  return '${value < 0 ? '-' : ''}$number$suffix';
}

/// A reported amount: large ones shortened (5.07T), small ones (earnings
/// per share) in full, with the currency's own symbol.
String reportedMoney(ReportedAmount amount, [String? locale]) {
  final currency = amount.currency;
  if (amount.value.abs() < 1e4) {
    return currency == null ? bigNumber(amount.value, locale) : Money(amount.value, currency).formatted(locale: locale, decimals: 2);
  }
  final number = bigNumber(amount.value.abs(), locale);
  return currency == null
      ? '${amount.value < 0 ? '-' : ''}$number'
      : CurrencyStyle.of(currency).apply(number, isNegative: amount.value < 0);
}

/// A ratio like a P/E: two decimals, kept left to right.
String ratioFigure(double value) => '\u2066${value.toStringAsFixed(2)}\u2069';

/// A fraction as a percent with two decimals.
String percentFigure(double fraction) => '\u2066${(fraction * 100).toStringAsFixed(2)}%\u2069';
