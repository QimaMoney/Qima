part of '../statement_reader.dart';

/// What a document says about itself (balances, period, account), and the
/// whole reading: rows and facts, each checked against the other.
mixin _Facts on _ReaderCore, _Dates, _Amounts, _Layout, _Reconcile, _Rows {
  // ---------------------------------------------------------- facts

  static final _openingLabel = RegExp(
    r'opening balance|beginning balance|starting balance|previous balance|balance brought forward|brought forward|'
    r'الرصيد الافتتاحي|رصيد افتتاحي|الرصيد السابق|رصيد أول المدة|رصيد اول المدة|الرصيد المرحل|'
    r'solde initial|solde précédent|solde precedent|ancien solde|saldo inicial|saldo anterior',
    caseSensitive: false,
  );
  static final _closingLabel = RegExp(
    r'closing balance|ending balance|end balance|new balance|current balance|balance carried forward|carried forward|statement balance|available balance|'
    r'الرصيد الختامي|رصيد ختامي|الرصيد الحالي|رصيد آخر المدة|رصيد اخر المدة|الرصيد المتاح|الرصيد المتوفر|الرصيد الجديد|'
    r'solde final|nouveau solde|solde actuel|saldo final|saldo actual|saldo disponible',
    caseSensitive: false,
  );
  /// What is still owed on a loan or card, when no closing balance is
  /// labelled.
  static final _outstandingLabel = RegExp(
    r'outstanding amount|outstanding balance|amount outstanding|remaining balance|'
    r'المبلغ المتبقي|الرصيد المتبقي|المبلغ المستحق المتبقي|montant restant|solde restant|saldo pendiente',
    caseSensitive: false,
  );
  // Miles and points have balances of their own.
  static final _rewards = RegExp(r'\bmiles\b|\bpoints\b|\brewards\b|أميال|نقاط|مكافآت|\bpuntos\b', caseSensitive: false);
  static final _available = RegExp(r'available|المتاح|المتوفر|disponible', caseSensitive: false);
  static final _from = RegExp(r'^(?:.*\s)?(?:from|du|desde|من)(?:\s|$)', caseSensitive: false);
  static final _to = RegExp(r'^(?:.*\s)?(?:to|au|hasta|إلى|الى)(?:\s|$)', caseSensitive: false);
  static final _periodLabel = RegExp(
    r'\bperiod\b|\bfrom\b.*\bto\b|statement date|الفترة|من تاريخ|للفترة|\bpériode\b|\bdu\b.*\bau\b|\bperíodo\b|\bdel\b.*\bal\b',
    caseSensitive: false,
  );
  static final _accountLabel = RegExp(
    r'account (?:no|number|#)|a/c (?:no|number)|acct|رقم الحساب|الحساب رقم|حساب رقم|numéro de compte|n° de compte|número de cuenta|cuenta n',
    caseSensitive: false,
  );
  static final _nearAccount = RegExp(r'account|a/c|acct|حساب|compte|cuenta', caseSensitive: false);
  static final _nearCard =
      RegExp(r'card|\bvisa\b|master ?card|\bmada\b|\bamex\b|\bcredit\b(?!ed)|بطاقة|مدى|carte|tarjeta', caseSensitive: false);
  static final _cardLabel = RegExp(r'card|بطاقة|بطاقتك|carte|tarjeta', caseSensitive: false);
  static final _iban = RegExp(r'\b([A-Z]{2}\d{2}(?:\s?[A-Z0-9]{4}){3,7}(?:\s?[A-Z0-9]{1,4})?)\b');
  // A masked number: stars or x's then its last digits, or the reverse as
  // right-to-left text sometimes comes out.
  static final _masked = RegExp(r'(?:[*xX•]{2,}[\s-]?(\d{4})(?!\d))|(?:(?<!\d)(\d{4})[*xX•]{4,})');
  static final _cardEnding = RegExp(r'(?:ending(?: in)?|ends with|#|رقم|المنتهية بـ?|المنتهية ب)\s*:?\s*(\d{4})(?!\d)', caseSensitive: false);
  static final _longNumber = RegExp(r'(?<![\d.,])\d{8,20}(?![\d.,])');

  static bool _validIban(String raw) {
    final s = raw.replaceAll(' ', '').toUpperCase();
    if (s.length < 15 || s.length > 34) return false;
    final moved = s.substring(4) + s.substring(0, 4);
    var rem = 0;
    for (final ch in moved.codeUnits) {
      final v = ch >= 65 ? ch - 55 : ch - 48;
      if (v < 0 || v > 35) return false;
      rem = int.parse('$rem$v') % 97;
    }
    return rem == 1;
  }

  /// The account or card a text names, as last four digits.
  List<StatementRef> _refs(String text, {bool cardContext = false}) {
    final out = <StatementRef>{};
    for (final m in _iban.allMatches(text.toUpperCase())) {
      final digits = m[1]!.replaceAll(RegExp(r'\D'), '');
      if (_validIban(m[1]!) && digits.length >= 4) out.add(StatementRef(StatementRefKind.iban, digits.substring(digits.length - 4), digits.length));
    }
    final card = cardContext || _cardLabel.hasMatch(text);
    final account = _accountLabel.hasMatch(text);
    for (final m in _masked.allMatches(text)) {
      // The words right around the number say what it is, before the text
      // as a whole does: "To: XX4010; Visa Credit" is a card.
      final near = text.substring(math.max(0, m.start - 24), math.min(text.length, m.end + 16));
      final kind = _nearAccount.hasMatch(near)
          ? StatementRefKind.account
          : _nearCard.hasMatch(near) || (card && !account)
              ? StatementRefKind.card
              : StatementRefKind.account;
      out.add(StatementRef(kind, m[1] ?? m[2]!));
    }
    if (card) {
      for (final m in _cardEnding.allMatches(text)) {
        out.add(StatementRef(StatementRefKind.card, m[1]!));
      }
    }
    if (account && out.isEmpty) {
      final i = _accountLabel.firstMatch(text)!.end;
      final m = _longNumber.firstMatch(text.substring(i).replaceAll(RegExp(r'(?<=\d)[\s-](?=\d)'), ''));
      if (m != null) out.add(StatementRef(StatementRefKind.account, m[0]!.substring(m[0]!.length - 4), m[0]!.length));
    }
    return out.toList();
  }

  /// The figure a label names: on its own line after it, else just under it.
  double? _labelled(List<_Line> lines, int i, RegExp label) {
    final line = lines[i];
    final text = _Text.normalize(line.text);
    final m = label.firstMatch(text);
    if (m == null) return null;
    double signed(_Found<_Money> a) => a.value.major * (a.value.sign < 0 ? -1 : 1);
    // Text up to the next label ("Days: 31") is this label's.
    String upToLabel(String s) {
      final next = RegExp(r'\p{L}[\p{L} ]{2,}:', unicode: true).firstMatch(s);
      return next == null ? s : s.substring(0, next.start);
    }

    final at = line.cells.indexWhere((c) => label.hasMatch(_Text.normalize(c.text)));
    if (at >= 0) {
      // In the label's own text the value follows it.
      final own = _Text.normalize(line.cells[at].text);
      final after = upToLabel(own.substring(label.firstMatch(own)!.end));
      final here = _amounts(after, _dates(after).$2, loose: true);
      if (here.isNotEmpty) return signed(here.first);
      // Beside it: to the right of a left-to-right label, to the left of
      // an Arabic one, up to the next label.
      final rtl = RegExp(r'[\u0600-\u06FF]').hasMatch(label.firstMatch(own)![0]!);
      final order = rtl ? [for (var j = at - 1; j >= 0; j--) j] : [for (var j = at + 1; j < line.cells.length; j++) j];
      for (final j in order) {
        final t = _Text.normalize(line.cells[j].text);
        final found = _amounts(t, _dates(t).$2, loose: true);
        if (found.isNotEmpty) return signed(rtl ? found.last : found.first);
        if (RegExp(r'\p{L}{2,}', unicode: true).hasMatch(t)) break;
      }
    } else {
      final after = upToLabel(text.substring(m.end));
      final here = _amounts(after, _dates(after).$2, loose: true);
      if (here.isNotEmpty) return signed(here.first);
    }
    // A label over its value (summary boxes).
    if (i + 1 < lines.length) {
      final below = lines[i + 1];
      if (below.top - line.bottom < line.height * 1.5) {
        // Where in its cell the label and each figure sit: a summary box
        // can come out as one wide cell of six labels over one of six
        // figures.
        (double, double) extent(DocToken cell, String text, int start, int end) {
          final n = math.max(text.length, 1);
          return (cell.x + cell.w * start / n, cell.x + cell.w * end / n);
        }
        final labelCell = line.cells.firstWhere((c) => label.hasMatch(_Text.normalize(c.text)), orElse: () => line.cells.first);
        final labelText = _Text.normalize(labelCell.text);
        final lm = label.firstMatch(labelText);
        final (l0, l1) = lm == null ? (labelCell.x, labelCell.x + labelCell.w) : extent(labelCell, labelText, lm.start, lm.end);
        // A figure under the label overlaps it across the page, however
        // wide it is (a banking app prints the balance large under a small
        // label); among those, and failing that, the nearest middle wins.
        _Found<_Money>? best;
        var bestD = double.infinity;
        for (final c in below.cells) {
          final t = _Text.normalize(c.text);
          for (final a in _amounts(t, _dates(t).$2, loose: true)) {
            final (f0, f1) = extent(c, t, a.span.start, a.span.end);
            final apart = ((f0 + f1) - (l0 + l1)).abs() / 2;
            final overlaps = f0 < l1 && l0 < f1;
            final d = overlaps ? apart : 1 + apart;
            if (d < bestD && (overlaps || apart < 0.2)) {
              bestD = d;
              best = a;
            }
          }
        }
        if (best != null) return best.value.major * (best.value.sign < 0 ? -1 : 1);
      }
    }
    return null;
  }

  /// Everything a document gives: its rows and what it says about itself,
  /// each checked against the other. Use this rather than [readPages] and
  /// [facts] apart.
  (List<StatementRow>, StatementFacts) read(List<DocPage> pages) {
    final pageLines = [for (final p in pages) _Layout._lines(p.tokens)];
    // Message bubbles carry their day in the chat's separator, not in
    // themselves: an undated one is still a transaction.
    var (rows, bubbles) = _readPages(pageLines);
    // A banking app's account screen shows the balance large at its top;
    // that figure is the balance its labels give, not a transaction, and
    // the screen is no receipt.
    final hasTable = pageLines.any((ls) => ls.any((l) => _header(l) != null));
    final shown = hasTable ? null : this.facts(pages, const []).closing;
    final headline = shown == null ? const <StatementRow>[] : rows.where((r) => r.dateGuessed && _Reconcile._same(r.amount.abs(), shown.abs())).toList();
    if (headline.isNotEmpty) rows = [for (final r in rows) if (!headline.contains(r)) r];
    // A receipt, a bill or a transfer confirmation: one transaction.
    final single = headline.isEmpty && rows.length <= 2 && rows.map((r) => _dayKey(r.date)).toSet().length <= 1 ? _receipt(pages) : null;
    // Only when the rows found are that one transaction read in pieces; a
    // short list with a "Total" line under it keeps its rows.
    if (single != null && (rows.isEmpty || rows.any((r) => _Reconcile._same(r.amount.abs(), single.$1.single.amount.abs())))) return single;
    rows = _beforeOpeningDoubtful(_undatedDoubtful(rows, bubbles, table: hasTable), pageLines);
    var facts = this.facts(pages, rows);
    final settled = _lastFromClosing(rows, facts);
    if (!identical(settled, rows)) {
      rows = settled;
      facts = this.facts(pages, rows);
    }
    // A balance with no transactions and no period (a loan's screen) is
    // the balance on the day the document was received.
    if (rows.isEmpty && facts.closing != null && facts.to == null) {
      facts = facts.copyWith(to: DateTime(received.year, received.month, received.day));
    }
    return (rows, facts);
  }

  static String _dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

  /// In a statement whose rows carry their dates, a row with none is a
  /// limit, a carried-forward balance, a tax breakdown or the terms: kept
  /// for the person to decide, unticked. A row the same document prints
  /// twice (same day, amount and running balance, a page overlap) is too.
  /// A card statement's first page lists the amount due, the minimum and
  /// the fees beside unprinted labels before the table starts with the
  /// balance brought forward: figures above that line are not transactions.
  List<StatementRow> _beforeOpeningDoubtful(List<StatementRow> rows, List<List<_Line>> pageLines) {
    final texts = [for (final ls in pageLines) for (final l in ls) _Text.normalize(l.text)];
    final first = texts.indexWhere((t) => _openingLabel.hasMatch(t) || _broughtForward.hasMatch(t));
    if (first < 0) return rows;
    final before = rows.where((r) => r.line != null && r.line! < first && !r.doubtful).length;
    final after = rows.where((r) => r.line != null && r.line! > first && !r.doubtful).length;
    // Lines that come after a closing balance with no opening balance
    // between: the statement's footer. A closing label counts only under a
    // row of its page (a balance in the page's header box is not the end
    // of the table), and the footer runs on to the next page unless the
    // label only carried the balance forward to it.
    final rowAt = {for (final r in rows) ?r.line};
    final afterClosing = List<bool>.filled(texts.length, false);
    var i = 0;
    var closed = false, carry = false;
    for (final ls in pageLines) {
      if (!carry) closed = false;
      var rowsSeen = false;
      for (var k = 0; k < ls.length; k++, i++) {
        afterClosing[i] = closed;
        if (rowAt.contains(i)) rowsSeen = true;
        if (_openingLabel.hasMatch(texts[i])) {
          closed = false;
        } else if (rowsSeen && _closingLabel.hasMatch(texts[i])) {
          closed = true;
          carry = !_carriedForward.hasMatch(texts[i]);
        }
      }
    }
    // A nameless row of figures under the closing balance is the
    // statement's footer (due date, minimum payment), not a transaction.
    bool underClosing(StatementRow r) =>
        r.line != null && r.line! < texts.length && afterClosing[r.line!] && !_hasWord.hasMatch(r.description);

    final footers = [for (final r in rows) !r.doubtful && underClosing(r) ? r.copyWith(doubtful: true) : r];
    if (before == 0 || before > 3 || after < 5) return footers;
    return [for (final r in footers) r.line != null && r.line! < first ? r.copyWith(doubtful: true) : r];
  }

  static final _broughtForward = RegExp(r'\bb/f\b', caseSensitive: false);
  static final _carriedForward = RegExp(r'carried forward|\bc/f\b', caseSensitive: false);
  static final _hasWord = RegExp(r'\p{L}{2,}', unicode: true);

  /// In a statement whose rows begin or end with their date, a figure dated
  /// only by a sentence around it or by a heading above it is the bank's
  /// own text (terms, a worked example, a tax breakdown): unticked too.
  ///
  /// Also kept unticked: a row dated after the day the document was
  /// received (a due date or a maturity date, not something that happened),
  /// and a figure with no date, no sign and no word saying money moved (an
  /// account's balance, a deposit held, points earned on a screen that
  /// lists no transactions).
  List<StatementRow> _undatedDoubtful(List<StatementRow> rows, Set<int> bubbles, {bool table = false}) {
    final dated = rows.where((r) => !r.dateGuessed).length;
    final undatedDoubtful = dated >= 5 && dated > rows.length / 2;
    final tomorrow = DateTime(received.year, received.month, received.day + 2);
    bool saysNothing(StatementRow r) =>
        r.dateGuessed && r.signGuessed && !bubbles.contains(r.line) && messageIntent('${r.description} ${r.detail}') == MessageIntent.unknown;
    // (A table with named columns already drops what isn't one of its rows.)
    final byDate = !table && rows.where((r) => _edgeDated.contains(r.line)).length >= 5;
    final seen = <String>{};
    return [
      for (final r in rows)
        if ((undatedDoubtful && r.dateGuessed && !bubbles.contains(r.line)) || (byDate && r.line != null && !_edgeDated.contains(r.line)))
          r.copyWith(doubtful: true)
        else if ((!r.dateGuessed && !r.date.isBefore(tomorrow)) || saysNothing(r))
          r.copyWith(doubtful: true)
        else if (r.balance != null && !seen.add('${_dayKey(r.date)}|${r.amount}|${r.balance}'))
          r.copyWith(doubtful: true)
        else
          r,
    ];
  }

  // Labels of the figure a receipt or bill comes to, strongest first.
  static final _totalLabels = [
    RegExp(
      r'total amount|grand total|amount due|total due|total to pay|amount payable|net amount|'
      r'المبلغ الإجمالي|المبلغ الاجمالي|إجمالي الفاتورة|اجمالي الفاتورة|المبلغ المطلوب سداده|المبلغ المستحق|الإجمالي المستحق|'
      r'montant total|total à payer|montant dû|importe total|total a pagar',
      caseSensitive: false,
    ),
    RegExp(r'^\s*total\b|\btotal\s*:|amount including vat|المبلغ شامل الضريبة|الإجمالي\s*:|^\s*الإجمالي|^\s*total\b', caseSensitive: false),
    RegExp(r'debit amount|amount paid|paid amount|مبلغ الخصم|المبلغ المدفوع|montant débité|importe cargado', caseSensitive: false),
  ];
  // What says a document is one transaction, not a list of them.
  static final _receiptWords = RegExp(
    r'\b(?:receipt|invoice|bill|transfer|payment|purchase|transaction details|order)\b|'
    r'فاتورة|إيصال|ايصال|حوالة|تحويل|سداد|شراء|تفاصيل العملية|'
    r'\b(?:reçu|facture|virement|paiement|recibo|factura|transferencia|pago)\b',
    caseSensitive: false,
  );
  // A title that says only what kind of paper it is ("Simplified tax invoice").
  static final _genericTitle = RegExp(
    r'^(?:simplified|tax|vat|invoice|receipt|bill|e-?receipt|فاتورة|ضريبية|مبسطة|إيصال|ايصال|facture|reçu|factura|recibo|\s)+$',
    caseSensitive: false,
  );
  static final _dateLabels = [
    RegExp(
      r'invoice date|transaction date|date (?:&|and) time|payment date|purchase date|issue date|'
      r'تاريخ الفاتورة|التاريخ والوقت|تاريخ العملية|تاريخ الدفع|تاريخ الإصدار|date de facture|date de l.opération|fecha de factura|fecha de la operación',
      caseSensitive: false,
    ),
    RegExp(r'\bdate\b|التاريخ|تاريخ|fecha', caseSensitive: false),
  ];
  static final _fromLabel = RegExp(r'^\s*(?:from|من)\b|\bfrom account\b|من حساب|\bdu compte\b|\bdesde\b', caseSensitive: false);
  static final _creditOnly = RegExp(r'credit amount|amount received|deposit|مبلغ الإيداع|إيداع|crédit|abono', caseSensitive: false);

  /// One transaction read from a receipt, a bill or a transfer
  /// confirmation: the figure it comes to, its date, what it was for, and
  /// the account it was paid from. Null when the document is not one.
  (List<StatementRow>, StatementFacts)? _receipt(List<DocPage> pages) {
    final lines = [for (final p in pages) ..._Layout._lines(p.tokens)];
    final texts = [for (final l in lines) _Text.normalize(l.text)];
    if (!texts.any(_receiptWords.hasMatch)) return null;

    // A bill repeats its total (on each page, in each language); a figure
    // misread beside one label is outvoted by the others.
    double? total;
    int? totalLine;
    String? totalCurrency;
    for (final label in _totalLabels) {
      final votes = <double, List<int>>{};
      for (var i = 0; i < lines.length; i++) {
        if (!label.hasMatch(texts[i])) continue;
        final v = _labelled(lines, i, label);
        if (v != null && v != 0) (votes[v.abs()] ??= []).add(i);
      }
      if (votes.isEmpty) continue;
      final best = votes.entries.reduce((a, b) => b.value.length > a.value.length ? b : a);
      total = best.key;
      totalLine = best.value.first;
      totalCurrency = _currencyIn(texts[totalLine]);
      break;
    }
    if (total == null || totalLine == null) return null;

    DateTime? date;
    for (final label in _dateLabels) {
      for (var i = 0; i < lines.length && date == null; i++) {
        final m = label.firstMatch(texts[i]);
        if (m == null) continue;
        // The date beside its label, not another one on the same line.
        final here = _dates(texts[i]).$1.where((d) => !d.hijri).toList();
        final after = here.where((d) => d.span.start >= m.end);
        final before = here.where((d) => d.span.end <= m.start);
        if (after.isNotEmpty) {
          date = after.first.value;
        } else if (before.isNotEmpty) {
          date = before.last.value;
        } else if (i + 1 < lines.length) {
          final below = _dates(texts[i + 1]).$1.where((d) => !d.hijri);
          if (below.isNotEmpty) date = below.first.value;
        }
      }
      if (date != null) break;
    }
    date ??= [for (final t in texts) ..._dates(t).$1.where((d) => !d.hijri).map((d) => d.value)].firstOrNull;

    // What it was for: the first line naming a kind of transaction, with
    // the line under it when it only says "tax invoice".
    var title = '';
    for (var i = 0; i < texts.length; i++) {
      // "Transaction details" heads the page; it names nothing.
      final text = texts[i].replaceAll(RegExp(r'transaction details|تفاصيل العملية', caseSensitive: false), '');
      if (!_receiptWords.hasMatch(text) || RegExp(r'\d{3,}').hasMatch(text)) continue;
      title = _Text._clean(text);
      if (title.isEmpty) continue;
      if (_genericTitle.hasMatch(title) && i + 1 < texts.length && !RegExp(r'\d').hasMatch(texts[i + 1])) {
        title = '$title ${_Text._clean(texts[i + 1])}';
      }
      break;
    }
    // Text in two scripts says the same thing twice: keep the first.
    final halves = RegExp(r'^([^\u0600-\u06FF]*[A-Za-z][^\u0600-\u06FF]*?)\s+([\u0600-\u06FF].*)$').firstMatch(title);
    final description = halves == null ? title : halves[1]!.trim();
    final detail = halves == null ? '' : halves[2]!.trim();

    // The account it was paid from.
    final refs = <StatementRef>[];
    for (var i = 0; i < texts.length && refs.isEmpty; i++) {
      if (!_fromLabel.hasMatch(texts[i])) continue;
      for (final t in texts.skip(i).take(3)) {
        final number = RegExp(r'(?<![\d.,])\d{8,20}(?![\d.,])').firstMatch(t.replaceAll(RegExp(r'(?<=\d)[\s-](?=\d)'), ''));
        final ref = _refs(t, cardContext: _cardLabel.hasMatch(t));
        if (ref.isNotEmpty) {
          refs.addAll(ref);
        } else if (number != null) {
          refs.add(StatementRef(StatementRefKind.account, number[0]!.substring(number[0]!.length - 4), number[0]!.length));
        }
        if (refs.isNotEmpty) break;
      }
    }

    final moneyIn = texts.any(_creditOnly.hasMatch) && !texts.any((t) => _totalLabels.last.hasMatch(t) || RegExp(r'invoice|bill|فاتورة|facture|factura', caseSensitive: false).hasMatch(t));
    final currency = totalCurrency ?? texts.map((t) => _currencyLabel.hasMatch(t) ? _currencyIn(t) : null).nonNulls.firstOrNull;
    final row = StatementRow(
      date: date ?? DateTime(received.year, received.month, received.day),
      dateGuessed: date == null,
      description: description,
      detail: detail,
      amount: moneyIn ? total : -total,
      signGuessed: !moneyIn && !texts.any((t) => _totalLabels.last.hasMatch(t) || RegExp(r'invoice|bill|فاتورة|purchase|شراء|facture|factura', caseSensitive: false).hasMatch(t)),
      currency: currency,
      line: totalLine,
    );
    return ([row], StatementFacts(refs: refs, currency: currency));
  }

  /// The newest row, when its only figure was read as the amount but is the
  /// closing balance the statement prints: its amount is the change from
  /// the row before it.
  static List<StatementRow> _lastFromClosing(List<StatementRow> rows, StatementFacts facts) {
    final closing = facts.closing;
    if (closing == null || facts.closingWorkedOut || rows.length < 2) return rows;
    final oldestFirst = !rows.first.date.isAfter(rows.last.date);
    final i = oldestFirst ? rows.length - 1 : 0;
    final before = rows[oldestFirst ? i - 1 : 1];
    final r = rows[i];
    if (r.balance != null || before.balance == null || !_Reconcile._same(r.amount.abs(), closing.abs())) return rows;
    final amount = ((closing - before.balance!) * 1000).round() / 1000;
    if (amount == 0) return rows;
    return [...rows]..[i] = r.copyWith(amount: amount, balance: closing, signGuessed: false);
  }

  /// The statement's balances, account and period, read from its pages.
  StatementFacts facts(List<DocPage> pages, List<StatementRow> rows) {
    double? opening, closing, outstanding;
    var available = false;
    // Every closing figure read, as each page repeats it.
    final closings = <(double, bool)>[];
    final refs = <StatementRef>{};
    int? tableStart;
    DateTime? from, to, firstSeen, lastSeen;
    String? currency;
    // The table: card numbers in a row's details (a card payment) are not
    // the statement's own account.
    final rowLines = [for (final r in rows) ?r.line];
    final firstRow = rowLines.isEmpty ? null : rowLines.reduce(math.min);
    final lastRow = rowLines.isEmpty ? null : rowLines.reduce(math.max);
    var base = 0;
    for (final page in pages) {
      final lines = _Layout._lines(page.tokens);
      for (var i = 0; i < lines.length; i++) {
        final at = base + i;
        final text = _Text.normalize(lines[i].text);
        // The first opening and the last closing balance: a multi-page
        // statement repeats them per page.
        if (tableStart == null && _header(lines[i]) != null) tableStart = at;
        if (_openingLabel.hasMatch(text) && !_rewards.hasMatch(text)) opening ??= _labelled(lines, i, _openingLabel);
        if (_outstandingLabel.hasMatch(text)) outstanding ??= _labelled(lines, i, _outstandingLabel);
        if (_closingLabel.hasMatch(text) && !_rewards.hasMatch(text)) {
          final v = _labelled(lines, i, _closingLabel);
          if (v != null) {
            closing = v;
            available = _available.hasMatch(_closingLabel.firstMatch(text)![0]!);
            closings.add((v, available));
          }
        }
        // From the table's header down: a transfer's details name the
        // other side's account.
        final start = tableStart ?? firstRow;
        final inTable = start != null && lastRow != null && at >= start && at <= lastRow;
        if (!inTable) refs.addAll(_refs(text));
        if (currency == null && _currencyLabel.hasMatch(text) && !_foreignLabel.hasMatch(text)) currency = _currencyIn(text);
        final (ds, spans) = _dates(text);
        // Two dates and no money: a row with a value date is not the period.
        final dated = ds.where((d) => !d.hijri).map((d) => d.value).toList();
        final money = _amounts(text, spans).where((a) => !a.value.bare);
        if (from == null && dated.length == 1 && money.isEmpty && _from.hasMatch(text)) {
          // "From 16/06/2026" over "To 15/09/2026".
          for (final next in lines.skip(i + 1).take(2)) {
            final t = _Text.normalize(next.text);
            final until = _dates(t).$1.where((d) => !d.hijri).toList();
            if (_to.hasMatch(t) && until.length == 1 && until.first.value.isAfter(dated.first)) {
              from = dated.first;
              to = until.first.value;
              break;
            }
          }
        }
        if (dated.length < 2 || money.isNotEmpty) continue;
        if (from == null && _periodLabel.hasMatch(text)) {
          from = dated.first;
          to = dated.last;
        } else if (firstSeen == null && (firstRow == null || at < firstRow)) {
          // Dates side by side above the table, often under "Date" labels.
          final sorted = [...dated]..sort();
          if (sorted.last.difference(sorted.first).inDays.abs() <= 400 && sorted.first != sorted.last) {
            firstSeen = sorted.first;
            lastSeen = sorted.last;
          }
        }
      }
      base += lines.length;
    }
    from ??= firstSeen;
    to ??= lastSeen;
    // Pages that print different closing figures (one page's text placed
    // wrongly): the one the opening balance and the rows add up to.
    if (opening != null && closings.map((c) => c.$1).toSet().length > 1) {
      for (final (v, avail) in closings) {
        if (Reconciliation.of(StatementFacts(opening: opening, closing: v), rows)?.addsUp ?? false) {
          closing = v;
          available = avail;
          break;
        }
      }
    }
    // A card's own number also shows as an account number: one card.
    final cards = {for (final r in refs) if (r.kind == StatementRefKind.card) r.last4};
    refs.removeWhere((r) => r.kind == StatementRefKind.account && cards.contains(r.last4));
    return _withWorkedOut(
        StatementFacts(
          opening: opening,
          closing: closing ?? outstanding,
          closingAvailable: closing != null && available,
          refs: refs.toList(),
          from: from,
          to: to,
          currency: _currencyOfRows(rows) ?? currency,
        ),
        rows);
  }

  static final _currencyLabel = RegExp(r'currency|العملة|devise|moneda', caseSensitive: false);
  static final _foreignLabel = RegExp(r'foreign|exchange|الأجنبية|الاجنبية|تحويل العملة|étrangère|change|extranjera|cambio', caseSensitive: false);

  /// The currency a line names, word by word ("ريال سعودي", "SAR").
  static String? _currencyIn(String text) {
    for (final w in text.toLowerCase().split(RegExp(r'[\s\-–/,:()&]+'))) {
      final c = _Amounts._currencyOf(w);
      if (c != null) return c;
    }
    return null;
  }

  /// What a bank message says: the account or card, and the balance after.
  StatementFacts messageFacts(String text, List<StatementRow> rows) {
    final t = _Text.normalize(text);
    final refs = _refs(t);
    double? closing;
    final m = _closingLabel.firstMatch(t);
    if (m != null) {
      final after = t.substring(m.end);
      final found = _amounts(after, _dates(after).$2);
      if (found.isNotEmpty) closing = found.first.value.major;
    }
    return StatementFacts(
        closing: closing, closingAvailable: m != null && _available.hasMatch(m[0]!), refs: refs, currency: _currencyOfRows(rows));
  }

  static String? _currencyOfRows(List<StatementRow> rows) {
    final counts = <String, int>{};
    for (final r in rows) {
      if (r.currency != null) counts[r.currency!] = (counts[r.currency!] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;
    final top = (counts.entries.toList()..sort((a, b) => b.value - a.value)).first;
    return top.value * 2 >= rows.length ? top.key : null;
  }

  /// Balances the statement doesn't print but its running balance shows:
  /// the oldest row's balance before it, and the newest row's after it.
  StatementFacts _withWorkedOut(StatementFacts f, List<StatementRow> rows) {
    final withBalance = rows.where((r) => r.balance != null).toList();
    if (withBalance.length < 2) return f;
    final newestFirst = withBalance.first.date.isAfter(withBalance.last.date);
    final oldest = newestFirst ? withBalance.last : withBalance.first;
    final newest = newestFirst ? withBalance.first : withBalance.last;
    var out = f;
    if (out.opening == null) out = out.copyWith(opening: oldest.balance! - oldest.amount, openingWorkedOut: true);
    if (out.closing == null) out = out.copyWith(closing: newest.balance, closingWorkedOut: true);
    return out;
  }
}
