part of '../statement_reader.dart';

/// Rebuilds a page's lines and columns from where its text sits.
mixin _Layout on _ReaderCore {
  // Header words, per column.
  static const Map<_Column, List<String>> _headerWords = {
    _Column.date: ['date', 'posting date', 'transaction date', 'value date', 'التاريخ', 'تاريخ', 'تاريخ العملية', 'fecha', 'date opération', 'datum'],
    _Column.description: ['description', 'details', 'narrative', 'narratives', 'particulars', 'merchant', 'transaction', 'البيان', 'الوصف', 'التفاصيل', 'تفاصيل', 'العملية', 'libellé', 'libelle', 'concepto', 'descripción', 'descripcion'],
    _Column.debit: ['debit', 'debits', 'withdrawal', 'withdrawals', 'money out', 'paid out', 'out', 'مدين', 'سحب', 'مسحوبات', 'المدين', 'خصم', 'débit', 'debito', 'débito', 'cargo', 'cargos'],
    _Column.credit: ['credit', 'credits', 'deposit', 'deposits', 'money in', 'paid in', 'in', 'دائن', 'إيداع', 'ايداع', 'إيداعات', 'الدائن', 'crédit', 'credito', 'crédito', 'abono', 'abonos'],
    _Column.amount: ['amount', 'value', 'المبلغ', 'مبلغ', 'القيمة', 'montant', 'importe', 'monto'],
    _Column.balance: ['balance', 'running balance', 'الرصيد', 'رصيد', 'solde', 'saldo'],
  };

  // ---------------------------------------------------------- lines

  static final _latinThenArabic = RegExp(r'^([^ء-ي]+?)\s+([ء-ي][ء-يـ\s:]*)$');

  /// A picture's line in reading order: text recognition gives a
  /// right-to-left line left to right, so a label that ends the line
  /// ("35510.39 الرصيد المتبقي") is put back before what it names.
  static String _logical(String line) {
    final m = _latinThenArabic.firstMatch(line.trim());
    return m == null ? line : '${m[2]!.trim()} ${m[1]}';
  }

  /// Tokens grouped into lines: a token joins a line when its middle is
  /// within half a line's height of the line's middle.
  static List<_Line> _lines(List<DocToken> tokens) {
    final sorted = [...tokens.where((t) => t.text.trim().isNotEmpty)]..sort((a, b) => a.midY.compareTo(b.midY));
    final lines = <List<DocToken>>[];
    for (final t in sorted) {
      final line = lines.isEmpty ? null : lines.last;
      if (line != null) {
        final mid = line.map((c) => c.midY).reduce((a, b) => a + b) / line.length;
        final h = line.map((c) => c.h).reduce(math.min);
        if ((t.midY - mid).abs() <= math.min(h, t.h) * 0.5) {
          line.add(t);
          continue;
        }
      }
      lines.add([t]);
    }
    return [for (final l in lines) _Line(l..sort((a, b) => a.x.compareTo(b.x)))];
  }

  /// A header row: two or more cells that each name a column. Returns each
  /// column's middle across the page.
  Map<_Column, double>? _header(_Line line) {
    // Each column's extent over all the cells naming it: a bilingual
    // header names a column twice ("Debit المدين"), and its figures sit
    // under both names, not under the first.
    final spans = <_Column, (double, double)>{};
    for (final c in line.cells) {
      final t = _Text.normalize(c.text).toLowerCase().trim();
      for (final e in _headerWords.entries) {
        // Long words match with one letter misread ("Vithdrawals").
        if (e.value.any((w) => t == w || (w.length >= 6 && _oneEdit(t, w)) || (w.length > 3 && t.split(RegExp(r'\s*[/(]\s*')).any((p) => p.trim() == w)))) {
          final had = spans[e.key];
          spans[e.key] = had == null ? (c.x, c.x + c.w) : (math.min(had.$1, c.x), math.max(had.$2, c.x + c.w));
          break;
        }
      }
    }
    final found = {for (final e in spans.entries) e.key: (e.value.$1 + e.value.$2) / 2};
    final money = found.keys.where((k) => k == _Column.debit || k == _Column.credit || k == _Column.amount || k == _Column.balance);
    return found.length >= 2 && money.isNotEmpty ? found : null;
  }

  /// Whether [a] is [b] with at most one letter added, dropped or changed.
  static bool _oneEdit(String a, String b) {
    if ((a.length - b.length).abs() > 1) return false;
    var i = 0, j = 0, edits = 0;
    while (i < a.length && j < b.length) {
      if (a[i] == b[j]) {
        i++;
        j++;
        continue;
      }
      if (++edits > 1) return false;
      if (a.length > b.length) {
        i++;
      } else if (a.length < b.length) {
        j++;
      } else {
        i++;
        j++;
      }
    }
    return edits + (a.length - i) + (b.length - j) <= 1;
  }

  _Column? _columnAt(Map<_Column, double> header, double x) {
    final xs = header.values.toList()..sort();
    var gap = 1.0;
    for (var i = 1; i < xs.length; i++) {
      gap = math.min(gap, xs[i] - xs[i - 1]);
    }
    _Column? best;
    var bestD = double.infinity;
    for (final e in header.entries) {
      final d = (e.value - x).abs();
      if (d < bestD) {
        bestD = d;
        best = e.key;
      }
    }
    return bestD <= math.max(gap * 0.75, 0.04) ? best : null;
  }
}
