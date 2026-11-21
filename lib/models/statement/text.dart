part of '../statement_reader.dart';

/// Text as it arrives from PDFs and text recognition, folded to the letters
/// and digits people type. The first stage: every other one reads its output.
abstract final class _Text {
  // ---------------------------------------------------------------- text

  static const _digitMap = {
    '٠': '0', '١': '1', '٢': '2', '٣': '3', '٤': '4', '٥': '5', '٦': '6', '٧': '7', '٨': '8', '٩': '9', //
    '۰': '0', '۱': '1', '۲': '2', '۳': '3', '۴': '4', '۵': '5', '۶': '6', '۷': '7', '۸': '8', '۹': '9',
    '٫': '.', '٬': ',', '−': '-', '–': '-', ' ': ' ', '‏': '', '‎': '', '؜': '',
  };

  static String normalize(String s) {
    final b = StringBuffer();
    for (final ch in s.split('')) {
      final unit = ch.codeUnitAt(0);
      if (unit >= 0xFE70 && unit <= 0xFEFC) {
        b.write(_arabicForms[unit] ?? ch);
        continue;
      }
      b.write(_digitMap[ch] ?? ch);
    }
    return b.toString();
  }

  /// Arabic letters as many PDFs store them: one shape per position in the
  /// word (Arabic Presentation Forms-B), folded back to the letters people
  /// type, so "ﺍﻟﺮﺻﻴﺪ" reads as "الرصيد". Isolated vowel marks are dropped.
  static final Map<int, String> _arabicForms = () {
    const runs = [
      (0xFE80, 1, 'ء'), (0xFE81, 2, 'آ'), (0xFE83, 2, 'أ'), (0xFE85, 2, 'ؤ'), (0xFE87, 2, 'إ'), (0xFE89, 4, 'ئ'), //
      (0xFE8D, 2, 'ا'), (0xFE8F, 4, 'ب'), (0xFE93, 2, 'ة'), (0xFE95, 4, 'ت'), (0xFE99, 4, 'ث'), (0xFE9D, 4, 'ج'),
      (0xFEA1, 4, 'ح'), (0xFEA5, 4, 'خ'), (0xFEA9, 2, 'د'), (0xFEAB, 2, 'ذ'), (0xFEAD, 2, 'ر'), (0xFEAF, 2, 'ز'),
      (0xFEB1, 4, 'س'), (0xFEB5, 4, 'ش'), (0xFEB9, 4, 'ص'), (0xFEBD, 4, 'ض'), (0xFEC1, 4, 'ط'), (0xFEC5, 4, 'ظ'),
      (0xFEC9, 4, 'ع'), (0xFECD, 4, 'غ'), (0xFED1, 4, 'ف'), (0xFED5, 4, 'ق'), (0xFED9, 4, 'ك'), (0xFEDD, 4, 'ل'),
      (0xFEE1, 4, 'م'), (0xFEE5, 4, 'ن'), (0xFEE9, 4, 'ه'), (0xFEED, 2, 'و'), (0xFEEF, 2, 'ى'), (0xFEF1, 4, 'ي'),
      (0xFEF5, 2, 'لآ'), (0xFEF7, 2, 'لأ'), (0xFEF9, 2, 'لإ'), (0xFEFB, 2, 'لا'),
    ];
    return {
      for (var c = 0xFE70; c <= 0xFE7F; c++) c: '',
      for (final (start, count, letter) in runs)
        for (var c = start; c < start + count; c++) c: letter,
    };
  }();

  static String _clean(String s) => s
      .replaceAll(RegExp(r'\*{2,}\d*|x{4,}\d*|#\d+', caseSensitive: false), ' ')
      // Card networks separate the merchant, city and country with tildes;
      // text recognition reads the new riyal sign as '#'.
      .replaceAll(RegExp(r'[|•·~#]+'), ' ')
      // The country and region code a card network appends ("SAU682").
      .replaceAll(RegExp(r'(?:^|\s)[A-Z]{3}\d{3}(?=\s|$)'), ' ')
      // Debris of a misread date or number ("27109/2026").
      .replaceAll(RegExp(r'(?:^|\s)[\d/\-.:]{5,}(?=\s|$)'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^[\s\-–:,.]+|[\s\-–:,]+$'), '')
      .trim();
}
