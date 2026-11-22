part of '../statement_reader.dart';

/// Finds dates in a line of text: Gregorian and Hijri, written in figures or
/// with a month's name, in the order the document itself uses.
mixin _Dates on _ReaderCore {
  // -------------------------------------------------------------- months

  static final Map<String, int> _months = () {
    final m = <String, int>{};
    void add(List<String> names) {
      for (var i = 0; i < 12; i++) {
        for (final n in names[i].split('|')) {
          m[n] = i + 1;
        }
      }
    }

    add([
      'jan|january', 'feb|february', 'mar|march', 'apr|april', 'may', 'jun|june', //
      'jul|july', 'aug|august', 'sep|sept|september', 'oct|october', 'nov|november', 'dec|december',
    ]);
    add([
      'janv|janvier', 'févr|fevr|février|fevrier', 'mars', 'avr|avril', 'mai', 'juin', //
      'juil|juillet', 'août|aout', 'sept|septembre', 'oct|octobre', 'nov|novembre', 'déc|dec|décembre|decembre',
    ]);
    add([
      'ene|enero', 'febrero', 'marzo', 'abr|abril', 'mayo', 'junio', //
      'julio', 'ago|agosto', 'septiembre|setiembre', 'octubre', 'noviembre', 'dic|diciembre',
    ]);
    add([
      'يناير|كانون الثاني', 'فبراير|شباط', 'مارس|آذار', 'أبريل|ابريل|إبريل|نيسان', 'مايو|أيار', 'يونيو|يونيه|حزيران', //
      'يوليو|يوليه|تموز', 'أغسطس|اغسطس|آب', 'سبتمبر|أيلول', 'أكتوبر|اكتوبر|تشرين الأول', 'نوفمبر|تشرين الثاني', 'ديسمبر|كانون الأول',
    ]);
    return m;
  }();

  static final String _monthAlt = (_months.keys.toList()..sort((a, b) => b.length - a.length)).map(RegExp.escape).join('|');

  // Dates. Order matters: the first pattern that matches a span wins.
  static final _isoDate = RegExp(r'(?<!\d)(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?!\d)');
  static final _numDate = RegExp(r'(?<!\d)(\d{1,2})[-/.](\d{1,2})(?:[-/.](\d{2}|\d{4}))?(?!\d|[.,]\d)');
  static final _dayMonth = RegExp('(?<![\\p{L}\\d])(\\d{1,2})(?:st|nd|rd|th)?[\\s\\-/.]*($_monthAlt)\\.?(?:[\\s\\-/.,]*(\\d{4}|\\d{2}))?(?![\\p{L}\\d])', caseSensitive: false, unicode: true);
  static final _monthDay = RegExp('(?<![\\p{L}\\d])($_monthAlt)\\.?[\\s\\-/.]*(\\d{1,2})(?:st|nd|rd|th)?(?:[\\s,]+(\\d{4}))?(?![\\p{L}\\d])', caseSensitive: false, unicode: true);
  static final _misreadDate = RegExp(r'(?<!\d)(\d{2})[1lI|](\d{2})/(\d{4})(?!\d)');
  static final _relative = RegExp(r"(?<![\p{L}])(today|yesterday|اليوم|أمس|امس|aujourd'hui|aujourd’hui|hier|hoy|ayer)(?![\p{L}])", caseSensitive: false, unicode: true);
  static final _time = RegExp(r'(?<!\d)\d{1,2}:\d{2}(?::\d{2})?(?:\s?(?:am|pm|ص|م))?(?![\d])', caseSensitive: false);

  // ---------------------------------------------------------- dates

  /// Whether dates written as numbers put the day first. Decided once per
  /// document from any date whose first or second number is over 12.
  bool _dayFirst = true;

  void _decideOrder(Iterable<String> texts) {
    var day = 0, month = 0;
    for (final t in texts) {
      for (final m in _numDate.allMatches(t)) {
        if (m[3] == null && t.substring(m.start, m.end).contains('.')) continue;
        final a = int.parse(m[1]!), b = int.parse(m[2]!);
        if (a > 12 && b <= 12) day++;
        if (b > 12 && a <= 12) month++;
      }
    }
    _dayFirst = month <= day;
  }

  /// Years Saudi and Gulf statements print Hijri dates in (1448 is 2026).
  static bool _isHijriYear(int y) => y >= 1350 && y <= 1500;

  /// A real day near the statement, or null. Hijri dates are converted; any
  /// other year far from the share date is a reference number, a register
  /// number or a birth date, not a transaction.
  DateTime? _day(int y, int m, int d) {
    if (m < 1 || m > 12 || d < 1 || d > 31) return null;
    if (_isHijriYear(y)) {
      if (d > 30) return null;
      return _near(hijriToGregorian(y, m, d));
    }
    final date = DateTime(y, m, d);
    return date.month == m ? _near(date) : null;
  }

  DateTime? _near(DateTime d) => d.year >= received.year - 20 && !d.isAfter(received.add(const Duration(days: 366))) ? d : null;

  /// Umm al-Qura, the calendar Saudi banks print: the length of each month
  /// from Muharram 1420 to Dhu al-Hijjah 1480 ('0' is 30 days, '9' is 29),
  /// from 1 Muharram 1420 (day 10698 after 1970-01-01).
  static const _ummAlQuraFrom = 1420;
  static const _ummAlQuraStart = 10698;
  static const _ummAlQuraLengths =
      '909909000090990999000090099099900090090909909090090090990909090090900909909090090090990909009009'
      '099099000900909909900900900990909090900909090990900090909099090090090909909090090099090909090090'
      '909090909090090099090990090009909909090009090990909000909099090900900909909090900909090909090900'
      '909009909090900090990990900090099099090009090909909009009090990909009009090990909009000990990090'
      '090099099090090090909909090090090909909009090090990909090009099099090000909909909000900990990900'
      '900909099090900909090099090900909009909090900090909909900090090990990090009099909009009009909090'
      '909009090909909009009090990900900909099090900900909909090090909009909090900900990909900900099099'
      '090900090909909900009090990909009009099090909009090909090909';

  static DateTime hijriToGregorian(int y, int m, int d) {
    final index = (y - _ummAlQuraFrom) * 12 + m - 1;
    if (index >= 0 && index < _ummAlQuraLengths.length) {
      var days = _ummAlQuraStart;
      for (var i = 0; i < index; i++) {
        days += _ummAlQuraLengths[i] == '0' ? 30 : 29;
      }
      final epoch = DateTime.utc(1970).add(Duration(days: days + d - 1));
      return DateTime(epoch.year, epoch.month, epoch.day);
    }
    // Outside the table: the tabular calendar, within a day or two.
    final jd = ((11 * y + 3) / 30).floor() + 354 * y + 30 * m - ((m - 1) / 2).floor() + d + 1948440 - 385;
    // Julian day to Gregorian (Fliegel and Van Flandern).
    var l = jd + 68569;
    final n = (4 * l / 146097).floor();
    l = l - ((146097 * n + 3) / 4).floor();
    final i = (4000 * (l + 1) / 1461001).floor();
    l = l - (1461 * i / 4).floor() + 31;
    final j = (80 * l / 2447).floor();
    final day = l - (2447 * j / 80).floor();
    l = (j / 11).floor();
    final month = j + 2 - 12 * l;
    final year = 100 * (n - 49) + i + l;
    return DateTime(year, month, day);
  }

  int _year(String? raw, int month, int day) {
    if (raw == null) {
      // No year: the latest such day that isn't after the share date.
      final y = received.year;
      final candidate = DateTime(y, month, day);
      return candidate.isAfter(received.add(const Duration(days: 1))) ? y - 1 : y;
    }
    final v = int.parse(raw);
    return raw.length == 2 ? 2000 + v : v;
  }

  /// The dates in [text], and every span that looked like one (a far year
  /// included), so those digits aren't read as money.
  (List<_Found<DateTime>>, List<_Span>) _dates(String text0) {
    var text = text0;
    final out = <_Found<DateTime>>[];
    final taken = <_Span>[];
    final eitherWay = <(RegExpMatch, DateTime?, DateTime)>[];
    bool free(int s, int e) => !taken.any((t) => s < t.end && e > t.start);
    void take(RegExpMatch m, DateTime? d, {bool hijri = false, bool loose = false}) {
      if (!free(m.start, m.end)) return;
      final span = _Span(m.start, m.end);
      // Not a usable day (a far year): the digits still aren't money.
      taken.add(span);
      if (d != null) out.add(_Found(d, span, 0, hijri: hijri, loose: loose));
    }

    // Text recognition reads a leading zero as the letter O ("O6SEP").
    text = text.replaceAllMapped(RegExp('(?<![\\p{L}\\d])[Oo](?=\\d\\s?(?:$_monthAlt)(?![\\p{L}]))', caseSensitive: false, unicode: true), (_) => '0');

    for (final m in _isoDate.allMatches(text)) {
      final y = int.parse(m[1]!);
      take(m, _day(y, int.parse(m[2]!), int.parse(m[3]!)), hijri: _isHijriYear(y));
    }
    for (final m in _dayMonth.allMatches(text)) {
      final month = _months[m[2]!.toLowerCase()];
      if (month == null) continue;
      final day = int.parse(m[1]!);
      var date = _day(_year(m[3], month, day), month, day);
      // Right to left, "19-أكتوبر-26" comes out of a picture as
      // "26-أكتوبر-19": when only the other reading is a recent day, it is
      // the one written.
      final year = m[3];
      if (year != null && year.length == 2 && m[1]!.length == 2 && RegExp(r'[ء-ي]').hasMatch(m[2]!)) {
        final other = int.parse(year);
        final swapped = _day(_year(m[1], month, other), month, other);
        if (swapped != null && swapped != date) {
          // Decided once the line's other dates are read.
          if (free(m.start, m.end)) eitherWay.add((m, date, swapped));
          continue;
        }
      }
      take(m, date);
    }
    for (final m in _monthDay.allMatches(text)) {
      final month = _months[m[1]!.toLowerCase()];
      if (month == null) continue;
      final day = int.parse(m[2]!);
      take(m, _day(_year(m[3], month, day), month, day));
    }
    for (final m in _numDate.allMatches(text)) {
      final a = int.parse(m[1]!), b = int.parse(m[2]!);
      final (d, mo) = _dayFirst ? (a, b) : (b, a);
      // "12.50" is money, not a date: a date without a year needs a slash
      // or a dash.
      if (m[3] == null && text.substring(m.start, m.end).contains('.')) continue;
      final y = _year(m[3], mo, d);
      take(m, _day(y, mo, d), hijri: _isHijriYear(y), loose: m[3] == null);
    }
    for (final m in _misreadDate.allMatches(text)) {
      final (a, b) = (int.parse(m[1]!), int.parse(m[2]!));
      final (d, mo) = _dayFirst ? (a, b) : (b, a);
      take(m, _day(int.parse(m[3]!), mo, d));
    }
    for (final m in _relative.allMatches(text)) {
      final w = m[1]!.toLowerCase();
      final today = DateTime(received.year, received.month, received.day);
      final isToday = const {'today', 'اليوم', "aujourd'hui", 'aujourd’hui', 'hoy'}.contains(w);
      take(m, isToday ? today : today.subtract(const Duration(days: 1)));
    }
    // The same day written beside it in Latin letters settles it; else
    // the reading that is a recent day.
    bool recent(DateTime? d) => d != null && !d.isAfter(received.add(const Duration(days: 1))) && d.isAfter(received.subtract(const Duration(days: 800)));
    for (final (m, written, swapped) in eitherWay) {
      final beside = out.any((f) => f.value == swapped) && !out.any((f) => f.value == written);
      take(m, beside || (!recent(written) && recent(swapped)) ? swapped : written);
    }
    out.sort((a, b) => a.span.start - b.span.start);
    return (out, taken);
  }
}
