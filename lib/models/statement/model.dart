part of '../statement_reader.dart';

/// Joins the on-device model's reading to the rules': the model points at
/// words, and every figure is still read by this code.
mixin _Model on _ReaderCore, _Dates, _Amounts, _Layout, _Reconcile, _Rows, _Facts {
  // ---------------------------------------------------------- the model

  /// The document's lines as the reader sees them, for the on-device model;
  /// [StatementRow.line] indexes into them.
  List<String> lineTexts(List<DocPage> pages) => [
        for (final p in pages)
          for (final l in _Layout._lines(p.tokens)) _Text.normalize(l.text),
      ];

  /// What the on-device model adds to a reading: rows on lines it reads as
  /// the bank's own text are marked doubtful (kept, unticked), names it
  /// copied from a line replace the reader's, and balances or an account
  /// the reader missed are read, by this code, from the lines it points at.
  /// The on-device model's reading of each page ([structures], word
  /// indexes into [pages]) against the rules' [rows] and [facts]:
  ///
  /// - Every figure comes from a word the model pointed at; a pointer to a
  ///   word with no figure in it drops the model's whole reading.
  /// - The model's rows are kept only when the numbers back them at least
  ///   as well as the rules' rows (the statement adds up, the running
  ///   balance links the rows) and none are lost.
  /// - Otherwise the rules' rows stay, taking the model's name for a row
  ///   whose own name came out unreadable, when both readings have the same
  ///   rows with the same amounts.
  ///
  /// Call it after [read] on the same [pages]: the document's own reading
  /// of a trailing minus is decided there.
  (List<StatementRow>, StatementFacts) withStructure(
      List<DocPage> pages, List<StatementRow> rows, StatementFacts facts, List<PageStructure> structures) {
    final read = _fromStructure(pages, structures);
    if (read == null) return (rows, facts);
    final (found, opening, closing) = read;
    final modelFacts = facts.copyWith(opening: facts.opening ?? opening, closing: facts.closing ?? closing);
    final modelRows = _signFromOpening(found, modelFacts.opening);
    if (modelRows.isNotEmpty && modelRows.length >= rows.length && _score(modelRows, modelFacts) >= _score(rows, facts)) {
      return (modelRows, _withWorkedOut(modelFacts, modelRows));
    }
    final sameRows = modelRows.length == rows.length &&
        [for (var i = 0; i < rows.length; i++) _Reconcile._same(rows[i].amount.abs(), modelRows[i].amount.abs())].every((x) => x);
    if (!sameRows) return (rows, facts);
    return (
      [
        for (var i = 0; i < rows.length; i++)
          _unreadable(rows[i].description) && modelRows[i].description.isNotEmpty ? rows[i].copyWith(description: modelRows[i].description) : rows[i],
      ],
      facts
    );
  }

  /// The oldest row's direction from the opening balance, when the running
  /// balance has no earlier row to go by. Rows run oldest or newest first.
  static List<StatementRow> _signFromOpening(List<StatementRow> rows, double? opening) {
    if (opening == null || rows.isEmpty) return rows;
    final (forward, backward) = _Reconcile._balanceFits(rows);
    final i = backward > forward ? rows.length - 1 : 0;
    final r = rows[i];
    if (!r.signGuessed || r.balance == null) return rows;
    final change = r.balance! - opening;
    if (!_Reconcile._same(change.abs(), r.amount.abs()) || change == 0) return rows;
    return [...rows]..[i] = r.copyWith(amount: r.amount.abs() * change.sign, signGuessed: false);
  }

  /// A name with no word in it, or more dots than letters (a mask).
  static bool _unreadable(String name) {
    final letters = RegExp(r'\p{L}', unicode: true).allMatches(name).length;
    return !RegExp(r'\p{L}{2,}', unicode: true).hasMatch(name) || '.'.allMatches(name).length >= letters;
  }

  /// How well the numbers back a reading: the statement adding up counts
  /// most, then each pair of rows the running balance links, then each row
  /// whose direction and date were read rather than guessed.
  static int _score(List<StatementRow> rows, StatementFacts facts) {
    final (forward, backward) = _Reconcile._balanceFits(rows);
    return ((Reconciliation.of(facts, rows)?.addsUp ?? false) ? 100000 : 0) +
        math.max(forward, backward) * 100 +
        rows.where((r) => !r.signGuessed).length +
        rows.where((r) => !r.dateGuessed).length;
  }

  /// Rows, and the opening and closing figures, from the words the model
  /// pointed at. Null when it pointed at a word that holds no figure.
  (List<StatementRow>, double?, double?)? _fromStructure(List<DocPage> pages, List<PageStructure> structures) {
    final out = <StatementRow>[];
    double? opening, closing;
    var base = 0;
    for (var p = 0; p < pages.length && p < structures.length; p++) {
      final tokens = pages[p].tokens;
      final lines = _Layout._lines(tokens);
      final s = structures[p];
      String? word(int? id) => id == null || id >= tokens.length ? null : _Text.normalize(tokens[id].text);
      List<_Found<_Money>>? figures(int? id) {
        final t = word(id);
        if (t == null) return null;
        final found = _amounts(t, _dates(t).$2, loose: true);
        return found.isEmpty ? null : found;
      }

      int? lineOf(int? id) {
        if (id == null || id >= tokens.length) return null;
        final i = lines.indexWhere((l) => l.cells.contains(tokens[id]));
        return i < 0 ? null : base + i;
      }

      for (final r in s.rows) {
        final amounts = figures(r.amount);
        if (amounts == null) return null;
        final money = amounts.first.value;
        final balanceFigures = r.balance == null ? null : figures(r.balance);
        if (r.balance != null && balanceFigures == null) return null;
        // The balance shares the amount's word when the two were read as one.
        final balanceMoney = balanceFigures == null ? null : (r.balance == r.amount ? (balanceFigures.length > 1 ? balanceFigures.last.value : null) : balanceFigures.last.value);
        final dateText = word(r.date);
        final date = dateText == null ? null : _dates(dateText).$1.where((d) => !d.hijri).firstOrNull?.value;
        var sign = money.sign;
        if (sign == 0) {
          final cue = [for (final id in r.direction) ?word(id)].join(' ').toLowerCase();
          if (RegExp(r'\bcr\b|\+|credit|deposit|دائن|إيداع|ايداع|crédit|abono').hasMatch(cue)) sign = 1;
          if (RegExp(r'\bdr\b|(?:^|\s)-|debit|withdrawal|مدين|سحب|خصم|débit|cargo').hasMatch(cue)) sign = -1;
        }
        out.add(StatementRow(
          date: date ?? DateTime(received.year, received.month, received.day),
          dateGuessed: date == null,
          description: r.name,
          amount: money.major * (sign == 0 ? -1 : sign),
          signGuessed: sign == 0,
          currency: money.currency,
          balance: balanceMoney == null ? null : balanceMoney.major * (balanceMoney.sign == 0 ? 1 : balanceMoney.sign),
          line: lineOf(r.amount),
        ));
      }
      if (s.opening != null) {
        final f = figures(s.opening);
        if (f == null) return null;
        opening ??= f.last.value.major * (f.last.value.sign < 0 ? -1 : 1);
      }
      if (s.closing != null) {
        final f = figures(s.closing);
        if (f == null) return null;
        closing = f.last.value.major * (f.last.value.sign < 0 ? -1 : 1);
      }
      base += lines.length;
    }
    return (_signsFromMarkers(_signsFromBalances(_withDocumentCurrency(out))), opening, closing);
  }

  (List<StatementRow>, StatementFacts) withLabels(List<StatementRow> rows, StatementFacts facts, List<String> lines, List<LineLabel> labels) {
    final byLine = {for (final l in labels) if (l.line >= 0 && l.line < lines.length) l.line: l};
    StatementRow labelled(StatementRow r) {
      final label = r.line == null ? null : byLine[r.line];
      if (label == null) return r;
      // A balance line or the account number read as a row is kept, flagged.
      return label.kind == LineKind.transaction ? _named(r, label.name, lines[label.line]) : r.copyWith(doubtful: true);
    }

    final out = rows.map(labelled).toList();
    var f = facts;
    for (final l in byLine.values) {
      final text = lines[l.line];
      double? figure() {
        final found = _amounts(text, _dates(text).$2);
        return found.isEmpty ? null : found.last.value.major * (found.last.value.sign < 0 ? -1 : 1);
      }

      switch (l.kind) {
        case LineKind.opening when f.opening == null || f.openingWorkedOut:
          final v = figure();
          if (v != null) f = f.copyWith(opening: v, openingWorkedOut: false);
        case LineKind.closing when f.closing == null || f.closingWorkedOut:
          final v = figure();
          if (v != null) f = f.copyWith(closing: v, closingWorkedOut: false, closingAvailable: _Facts._available.hasMatch(text));
        case LineKind.account when f.refs.isEmpty:
          final digits = RegExp(r'\d[\d\s-]{3,}\d').allMatches(text).map((m) => m[0]!.replaceAll(RegExp(r'\D'), '')).where((d) => d.length >= 4).toList()
            ..sort((a, b) => b.length - a.length);
          final refs = _refs(text);
          if (refs.isNotEmpty) {
            f = f.copyWith(refs: refs);
          } else if (digits.isNotEmpty) {
            f = f.copyWith(refs: [
              StatementRef(_Facts._cardLabel.hasMatch(text) ? StatementRefKind.card : StatementRefKind.account, digits.first.substring(digits.first.length - 4), digits.first.length)
            ]);
          }
        default:
          break;
      }
    }
    return (out, f);
  }

  /// A row named by the model, when its words are on the line and aren't
  /// a figure.
  StatementRow _named(StatementRow r, String name, String line) {
    final clean = _Text._clean(name);
    if (clean.length < 2 || !line.toLowerCase().contains(name.toLowerCase())) return r;
    if (_amounts(clean, const []).isNotEmpty || RegExp(r'^[\d\s.,/-]+$').hasMatch(clean)) return r;
    return r.copyWith(description: clean);
  }
}
