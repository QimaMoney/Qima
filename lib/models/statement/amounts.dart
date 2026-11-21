part of '../statement_reader.dart';

/// Finds amounts of money in a line of text, with their sign and currency.
mixin _Amounts on _ReaderCore {
  /// Card statements (SNB) print refunds and payments with a trailing
  /// minus ("3,075.00-"): money in, not out. Decided per document by
  /// [_decideTrailingMinus], which every entry point calls.
  bool _trailingMinusIsCredit = false;
  static final _trailingMinusFigure = RegExp(r'\d[.,]\d{2}-(?:\s|$)');
  static final _plainFigure = RegExp(r'\d[.,]\d{2}(?![\d-])');
  static final _creditRowWords = RegExp(
    r'payment|refund|\bret\b|reversal|\bcredit\b|cash ?back|thank you|سداد|استرداد|مرتجع',
    caseSensitive: false,
  );

  /// A trailing minus means money in when it marks the few rows that are
  /// refunds or payments among a card's unmarked spending: the marked lines
  /// are fewer than the unmarked ones, and most of them name a refund or a
  /// payment. A statement that marks its spending that way ("CARD PAYMENT
  /// 12.50-" on most rows) keeps the minus as money out.
  void _decideTrailingMinus(Iterable<String> texts) {
    var marked = 0, credits = 0, plain = 0;
    for (final t in texts) {
      if (_trailingMinusFigure.hasMatch(t)) {
        marked++;
        if (_creditRowWords.hasMatch(t)) credits++;
      } else if (_plainFigure.hasMatch(t)) {
        plain++;
      }
    }
    _trailingMinusIsCredit = credits > 0 && credits * 2 >= marked && marked < plain;
  }

  // Money.
  static const Map<String, String> _currencyWords = {
    'sar': 'SAR', 'sr': 'SAR', '\u20c1': 'SAR', 'ر.س': 'SAR', 'ر س': 'SAR', 'ريال': 'SAR', 'رس': 'SAR', '﷼': 'SAR', //
    'egp': 'EGP', 'le': 'EGP', 'ج.م': 'EGP', 'جم': 'EGP', 'جنيه': 'EGP', //
    'aed': 'AED', 'د.إ': 'AED', 'درهم': 'AED', 'kwd': 'KWD', 'د.ك': 'KWD', 'qar': 'QAR', 'ر.ق': 'QAR', //
    'bhd': 'BHD', 'د.ب': 'BHD', 'omr': 'OMR', 'ر.ع': 'OMR', 'jod': 'JOD', 'usd': 'USD', r'$': 'USD', r'us$': 'USD', //
    'eur': 'EUR', '€': 'EUR', 'gbp': 'GBP', '£': 'GBP', 'mad': 'MAD', 'try': 'TRY', 'inr': 'INR', '₹': 'INR',
  };
  static final String _ccyAlt = (_currencyWords.keys.toList()..sort((a, b) => b.length - a.length)).map(RegExp.escape).join('|');
  static final _amount = RegExp(
    '(?<![\\p{L}\\d.,*])(\\()?\\s*([-+])?\\s*(?:($_ccyAlt)\\s?)?([-+])?\\s*'
    r'(\d{1,3}(?:[,\s.]\d{3})+(?:[.,]\d{1,3})?|\d+(?:[.,]\d{1,3})?)'
    '(?:\\s?($_ccyAlt))?\\s*(\\))?\\s*(-|cr\\b|dr\\b|db\\b|مدين|دائن)?(?![\\p{L}\\d])',
    caseSensitive: false,
    unicode: true,
  );

  // ---------------------------------------------------------- money

  static String? _currencyOf(String? word) => word == null ? null : _currencyWords[word.toLowerCase()];

  static double? parseNumber(String raw, {String? currency}) {
    var s = raw.replaceAll(' ', '');
    final lastDot = s.lastIndexOf('.'), lastComma = s.lastIndexOf(',');
    final last = math.max(lastDot, lastComma);
    if (last >= 0) {
      final decimals = s.length - last - 1;
      final sep = s[last];
      final other = sep == '.' ? ',' : '.';
      final threeDigit = currency != null && MinorUnits.digits(currency) == 3;
      final isDecimal = decimals <= 2 || (decimals == 3 && (threeDigit || s.contains(other)) && !s.substring(0, last).contains(sep));
      if (isDecimal && !(decimals == 3 && s.indexOf(sep) != last)) {
        s = '${s.substring(0, last).replaceAll(RegExp(r'[.,]'), '')}.${s.substring(last + 1)}';
      } else {
        s = s.replaceAll(RegExp(r'[.,]'), '');
      }
    }
    return double.tryParse(s);
  }

  /// The amounts in [text]. [loose] accepts a bare whole number (a cell under
  /// an amount column); otherwise a figure needs decimals or a currency so
  /// that reference numbers, card digits and times are never read as money.
  List<_Found<_Money>> _amounts(String text, List<_Span> notHere, {bool loose = false}) {
    final out = <_Found<_Money>>[];
    for (final m in _amount.allMatches(text)) {
      if (notHere.any((t) => m.start < t.end && m.end > t.start)) continue;
      final digits = m[5]!;
      final ccy = _currencyOf(m[3]) ?? _currencyOf(m[6]);
      final hasDecimals = RegExp(r'[.,]\d{1,3}$').hasMatch(digits) && !RegExp(r'^\d{1,3}[.,]\d{3}$').hasMatch(digits);
      final grouped = RegExp(r'^\d{1,3}(?:[,\s.]\d{3})+').hasMatch(digits) && digits.length > 4;
      final bare = ccy == null && !hasDecimals && !grouped;
      if (!loose && bare) continue;
      // A long run of digits is a phone, account or register number.
      if (bare && digits.length > 7) continue;
      if (!loose && ccy == null && digits.replaceAll(RegExp(r'\D'), '').length > 9) continue;
      final value = parseNumber(digits, currency: ccy);
      if (value == null || value == 0) continue;
      final marker = (m[8] ?? '').toLowerCase();
      var sign = 0;
      if (marker == '-' && _trailingMinusIsCredit) {
        sign = 1;
      } else if (m[2] == '-' || m[4] == '-' || marker == '-' || (m[1] != null && m[7] != null) || marker == 'dr' || marker == 'db' || marker == 'مدين') {
        sign = -1;
      } else if (m[2] == '+' || m[4] == '+' || marker == 'cr' || marker == 'دائن') {
        sign = 1;
      }
      out.add(_Found(_Money(value, sign, ccy, bare: bare), _Span(m.start, m.end), 0));
    }
    return out;
  }
}
