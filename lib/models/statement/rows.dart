part of '../statement_reader.dart';

/// Turns a document's lines into rows: one transaction per dated line with
/// an amount, with the text around it.
mixin _Rows on _ReaderCore, _Dates, _Amounts, _Layout, _Reconcile {
  static final _skipWords = RegExp(
    r'opening balance|closing balance|balance brought forward|balance carried forward|brought forward|carried forward|'
    r'previous balance|total|subtotal|statement period|page \d|b/f\b|paid up capital|commercial registration|رأس المال|الرصيد الافتتاحي|الرصيد الختامي|رصيد افتتاحي|رصيد ختامي|الرصيد السابق|'
    r'المجموع|الإجمالي|اجمالي|إجمالي|solde initial|solde final|saldo inicial|saldo final|total',
    caseSensitive: false,
  );

  static final _summaryWords = RegExp(
    r'credit limit|available limit|available credit|minimum payment|minimum due|payment due|due date|outstanding|overdue|'
    r'installment amount|instalment amount|final installment|finance amount|amount paid|tenure|deferment|last payment received|'
    r'installment due|remaining io balance|remaining installment|annual percentage rate|pay off the full amount|profit mark ?up|'
    r'الحد الائتماني|الحد المتاح|الحد الأدنى|الحد الادنى|الحد الدنى|تاريخ الاستحقاق|المبلغ المستحق|المبلغ المتبقي|قيمة القسط|'
    r'plafond|paiement minimum|límite de crédito|pago mínimo',
    caseSensitive: false,
  );

  static final _incomeWords = RegExp(
    r'salary|payroll|deposit|credited|received|refund|reversal|cashback|transfer in|incoming|interest earned|'
    r'راتب|رواتب|إيداع|ايداع|وارد|واردة|استرداد|مسترد|استرجاع|أضيف|اضيف|salaire|virement reçu|remboursement|nómina|nomina|abono|reembolso',
    caseSensitive: false,
  );
  static final _spendWords = RegExp(
    r'purchase|debited|withdrawal|paid|payment|pos\b|atm|transfer out|outgoing|fee|charge|'
    r'شراء|مشتريات|خصم|سحب|صادرة|صادر|دفع|سداد|رسوم|achat|retrait|paiement|compra|retiro|pago',
    caseSensitive: false,
  );

  // ---------------------------------------------------------- reading

  /// Rows from positioned pages: statement PDFs, screenshots, tables.
  List<StatementRow> readPages(List<DocPage> pages) => _readPages([for (final p in pages) _Layout._lines(p.tokens)]).$1;

  /// [readPages] from the pages' lines, with the lines that start a
  /// message bubble.
  (List<StatementRow>, Set<int>) _readPages(List<List<_Line>> allLines) {
    final bubbleLines = <int>{};
    final texts = [for (final ls in allLines) for (final l in ls) _Text.normalize(l.text)];
    _decideOrder(texts);
    _decideTrailingMinus(texts);

    final rows = <StatementRow>[];
    final rowLines = <_Line>[];
    Map<_Column, double>? header;
    // A statement with a table: nothing above its first header is a
    // transaction (the summary, the address, the statement's own date).
    final hasTable = allLines.any((ls) => ls.any((l) => _header(l) != null));
    double? pendingLeft;
    // Rows read without columns: the other way to read their figures, with
    // the balance first (right-to-left statements put it on the left).
    final balanceFirst = <int, (_Money, double)>{};
    // Rows whose only figure is the balance: their amount cell was lost or
    // misplaced (some PDFs misreport where a figure is), so the change in
    // the running balance gives it.
    final fromBalance = <int>{};
    DateTime? sectionDate;
    // Rows whose day came from a date line above them, and how often a
    // date line under a row turned out to be that row's (card lists).
    final datedBySection = <int>{};
    // Where each row's figure sits across the page, for tables printed
    // without column names (CIB): by the row's line.
    final amountX = <int, double>{};
    // The same for the second figure, which is the amount when the
    // balance turns out to be printed first.
    final flipX = <int, double>{};
    var datesUnder = 0;
    String pendingText = '';
    double? pendingBottom;
    // Tables whose cells centre their lines on the dated one: a row's
    // reference sits on the line above its date, so a line between two
    // rows belongs to the nearer one. Decided by the table's first row.
    bool? centred;
    _Line? rowAnchor;
    // The last line of a page, with more pages to come, heads the next
    // page's first row.
    bool nearerNext(List<_Line> lines, _Line line, _Line anchor, {required bool morePages}) {
      for (final next in lines.skip(lines.indexOf(line) + 1)) {
        if (_dates(_Text.normalize(next.text)).$1.isEmpty) continue;
        return next.top - line.bottom < line.top - anchor.bottom;
      }
      return morePages && identical(line, lines.last);
    }

    var lineBase = 0;
    for (final lines in allLines) {
      final base = lineBase;
      lineBase += lines.length;
      sectionDate = null;
      // A screenshot of messages: each bubble is read as one message, so the
      // limit or balance a bank adds is never a transaction of its own.
      final messages = hasTable ? const <int, List<_Line>>{} : _messageBlocks(lines);
      final skip = <_Line>{};
      for (final line in lines) {
        if (skip.contains(line)) continue;
        final bubble = messages[lines.indexOf(line)];
        if (bubble != null) {
          skip.addAll(bubble);
          final row = _message([for (final l in bubble) _Text.normalize(l.text)]);
          bubbleLines.add(base + lines.indexOf(line));
          if (row != null) rows.add(row.copyWithLine(base + lines.indexOf(line)));
          pendingText = '';
          continue;
        }
        final h = _header(line);
        if (h != null) {
          header = h;
          pendingText = '';
          // A date above the table (the statement's own date) heads nothing.
          sectionDate = null;
          continue;
        }

        if (hasTable && header == null) continue;

        // Per cell: dates, amounts, and what's left as words.
        final dates = <_Found<DateTime>>[];
        final amounts = <(_Found<_Money>, _Column?)>[];
        final words = <String>[];
        String? lineCurrency;
        for (final cell in line.cells) {
          final text = _Text.normalize(cell.text);
          final column = header == null ? null : _columnAt(header, cell.x + cell.w / 2);
          final (ds, dateSpans) = _dates(text);
          final times = [for (final m in _Dates._time.allMatches(text)) _Span(m.start, m.end)];
          final taken = [...dateSpans, ...times];
          final moneyColumn = column == _Column.debit || column == _Column.credit || column == _Column.amount || column == _Column.balance;
          final ams = _amounts(text, taken, loose: moneyColumn);
          for (final d in ds) {
            dates.add(_Found(d.value, d.span, cell.x + cell.w / 2, hijri: d.hijri, loose: d.loose));
          }
          for (final a in ams) {
            final at = cell.x + cell.w * ((a.span.start + a.span.end) / 2 / math.max(text.length, 1));
            final col = header == null ? null : _columnAt(header, at) ?? column;
            amounts.add((_Found(a.value, a.span, at), col));
          }
          final spans = [...taken, ...ams.map((a) => a.span)]..sort((a, b) => a.start - b.start);
          var rest = StringBuffer();
          var i = 0;
          for (final s in spans) {
            if (s.start > i) rest.write(text.substring(i, s.start));
            rest.write(' ');
            i = math.max(i, s.end);
          }
          if (i < text.length) rest.write(text.substring(i));
          final cleaned = _Text._clean(rest.toString());
          final asCurrency = _Amounts._currencyOf(cleaned);
          if (asCurrency != null) {
            lineCurrency = asCurrency;
          } else if (cleaned.isNotEmpty && column != _Column.balance) {
            words.add(cleaned);
          }
        }
        final description = _Text._clean(words.join(' '));

        // The day a line gives the rows under it. In a table only the date
        // column's dates count (a transfer's details carry their own
        // timestamps), and a day and month with no year never replaces a
        // full date: it is the Hijri date printed under it.
        DateTime? heading(List<_Found<DateTime>> found) {
          final dateColumn = header?[_Column.date];
          for (final d in found) {
            if (d.hijri || (d.loose && sectionDate != null)) continue;
            if (dateColumn != null && header != null && _columnAt(header, d.x) != _Column.date) continue;
            return d.value;
          }
          return null;
        }

        if (_skipWords.hasMatch(description)) {
          pendingText = '';
          continue;
        }

        if (amounts.isEmpty) {
          if (dates.isNotEmpty && description.length < 3) {
            final prev = rowLines.isEmpty ? null : rowLines.last;
            final close = prev != null && rows.isNotEmpty && line.top - prev.bottom < prev.height * 1.5;
            // Nearer the row above than the line below: not a group heading.
            final i = lines.indexOf(line);
            final next = i + 1 < lines.length ? lines[i + 1] : null;
            final belongsAbove = close && (next == null || line.top - prev.bottom <= next.top - line.bottom);
            // A list that has dated more rows from below than from above
            // is a card list: an orphan date line there is its row's
            // whatever the spacing. Otherwise the spacing decides.
            final cardList = datesUnder >= datedBySection.length;
            if (close && (rows.last.dateGuessed || (datesUnder > 0 && (cardList || belongsAbove) && datedBySection.contains(rows.length - 1)))) {
              // A date under a row that had none is that row's (card lists);
              // once the list is known to date its rows from below, a row
              // dated from above by an orphan date line takes its own.
              rows.last = rows.last.copyWith(date: dates.first.value, dateGuessed: false);
              datedBySection.remove(rows.length - 1);
              datesUnder++;
              rowLines.last = line;
            } else {
              // A date on its own heads a group of rows (banking apps).
              sectionDate = heading(dates) ?? sectionDate;
            }
            pendingText = '';
          } else if (description.isNotEmpty) {
            final prev = rowLines.isEmpty ? null : rowLines.last;
            final close = prev != null && rows.isNotEmpty && line.top - prev.bottom < prev.height * 1.2 && line.top > prev.top;
            final under = close && !(centred == true && rowAnchor != null && nearerNext(lines, line, rowAnchor, morePages: !identical(lines, allLines.last)));
            if (under && pendingText.isEmpty && dates.isEmpty) {
              final last = rows.removeLast();
              rows.add(StatementRow(
                date: last.date,
                dateGuessed: last.dateGuessed,
                description: last.description.isEmpty ? description : last.description,
                detail: last.description.isEmpty ? last.detail : [last.detail, description].where((s) => s.isNotEmpty).join(' '),
                amount: last.amount,
                signGuessed: last.signGuessed,
                currency: last.currency,
                balance: last.balance,
                line: last.line,
              ));
              rowLines.last = line;
            } else {
              // A name wrapped onto the next line continues it.
              final wraps = pendingText.isNotEmpty && pendingBottom != null && pendingLeft != null && line.top - pendingBottom < line.height * 0.6 && (line.left - pendingLeft).abs() < 0.03;
              pendingText = wraps ? '$pendingText $description' : description;
              pendingBottom = line.bottom;
              pendingLeft = line.left;
              sectionDate = heading(dates) ?? sectionDate;
            }
          }
          continue;
        }

        // Which figure is the transaction and which the balance.
        double? balance;
        _Money? money;
        var sign = 0;
        (_Money, double)? flip;
        final byColumn = header != null && amounts.any((a) => a.$2 != null);
        // A card row in a foreign currency gives that amount and then the
        // local one: the local one is the transaction, the foreign one its
        // detail.
        _Money? foreign;
        // A figure with decimals or a currency beats a bare number in a
        // name ("Branch 101"), and the local amount beats a foreign one.
        bool better(_Money a, _Money than) => (than.bare && !a.bare) || (than.currency != null && a.currency == null && !a.bare);
        if (byColumn) {
          for (final (a, col) in amounts) {
            final s = switch (col) {
              _Column.debit => -1,
              _Column.credit => 1,
              _Column.amount || null => a.value.sign,
              _ => null,
            };
            if (col == _Column.balance) {
              balance = a.value.major * (a.value.sign == 0 ? 1 : a.value.sign);
            } else if (s != null && (money == null || better(a.value, money))) {
              if (money?.currency != null && a.value.currency == null) foreign = money;
              money = a.value;
              sign = s;
            }
          }
        } else {
          // A bare number in a name ("Branch 101") is not the amount when the
          // line has figures with decimals.
          final all = [for (final a in amounts) a.$1.value];
          final list = all.any((m) => !m.bare) ? all.where((m) => !m.bare).toList() : all;
          money = list.first;
          double? xOf(_Money m) => amounts.where((a) => identical(a.$1.value, m)).firstOrNull?.$1.x;
          final at = base + lines.indexOf(line);
          if (xOf(money) case final x?) amountX[at] = x;
          sign = money.sign;
          if (list.length >= 2) {
            final last = list.last;
            balance = last.major * (last.sign == 0 ? 1 : last.sign);
            final first = list.first;
            flip = (list[1], first.major * (first.sign == 0 ? 1 : first.sign));
            if (xOf(list[1]) case final x?) flipX[at] = x;
          }
        }
        final balanceOnly = money == null && balance != null && byColumn;
        if (money == null && !balanceOnly) continue;

        // The day: the date column's, else a Gregorian one, else the first.
        final dateColumn = header?[_Column.date];
        // Ties keep the line's order: a transaction date comes before the
        // posting date.
        final ownDates = [...dates]
          ..sort((a, b) {
            if (dateColumn != null) {
              final c = (a.x - dateColumn).abs().compareTo((b.x - dateColumn).abs());
              if (c != 0) return c;
            }
            if (a.hijri != b.hijri) return a.hijri ? 1 : -1;
            if (a.loose != b.loose) return a.loose ? 1 : -1;
            return a.x.compareTo(b.x) != 0 ? a.x.compareTo(b.x) : a.span.start - b.span.start;
          });
        // In a statement table every transaction carries its date. A line
        // without one is the bank's address, register number or terms at
        // the foot of the page, unless a date line inside the table heads it
        // and its figure is real money.
        if (header != null && ownDates.isEmpty && (sectionDate == null || balanceOnly || money!.bare)) {
          pendingText = '';
          continue;
        }

        // A name with no word in it is a mask ("A.. E. K...") or a misread
        // figure, not a name.
        var text = RegExp(r'\p{L}{2,}', unicode: true).hasMatch(description) ? description : '';
        if (header != null && centred == null) {
          // A line just above the first row and one just below it, before
          // the next row: the row's text is centred on its date.
          final i = lines.indexOf(line);
          final next = i + 1 < lines.length ? lines[i + 1] : null;
          centred = pendingText.isNotEmpty &&
              pendingBottom != null &&
              line.top - pendingBottom < line.height * 1.5 &&
              next != null &&
              _dates(_Text.normalize(next.text)).$1.isEmpty;
        }
        final wrapped = pendingText.isNotEmpty && pendingBottom != null && pendingLeft != null && line.top - pendingBottom < line.height * 0.5 && (line.left - pendingLeft).abs() < 0.03;
        if (text.isNotEmpty && pendingText.isNotEmpty && (wrapped || centred == true)) {
          // The name's first line sits above, its second on this line.
          text = '$pendingText $text';
        } else if (text.isEmpty && pendingText.isNotEmpty) {
          text = pendingText;
        }
        pendingText = '';

        // The statement's summary (limit, minimum payment, what is still
        // owed) is not a transaction, nor an undated line of bare figures.
        // A dated row stays even when its name came out unreadable.
        if (_summaryWords.hasMatch(text) || (ownDates.isEmpty && text.isEmpty)) continue;

        var signGuessed = false;
        if (sign == 0) {
          signGuessed = true;
          sign = _incomeWords.hasMatch(text) && !_spendWords.hasMatch(text) ? 1 : -1;
        }
        final ccy = money?.currency ?? lineCurrency;
        // A row that starts (or, right to left, ends) with two dates gives
        // the transaction and posting dates: it happened on the earlier.
        final paired = _edgeDates(line);
        final date = paired.length >= 2
            ? paired.reduce((a, b) => a.isBefore(b) ? a : b)
            : ownDates.isNotEmpty
                ? ownDates.first.value
                : sectionDate;
        if (flip != null) balanceFirst[rows.length] = flip;
        if (balanceOnly) fromBalance.add(rows.length);
        if (date != null && paired.length < 2 && ownDates.isEmpty) datedBySection.add(rows.length);
        rows.add(StatementRow(
          date: date ?? DateTime(received.year, received.month, received.day),
          dateGuessed: date == null,
          description: text,
          detail: foreign == null ? '' : '${foreign.major.toStringAsFixed(2)} ${foreign.currency}',
          amount: (money?.major ?? 0) * sign,
          signGuessed: signGuessed,
          currency: ccy,
          balance: balance,
          line: base + lines.indexOf(line),
        ));
        rowLines.add(line);
        rowAnchor = line;
      }
    }
    final local = _localAmounts(rows);
    final sided = _balanceSide(local, balanceFirst);
    // Balance printed first: each row's amount is its second figure.
    if (!identical(sided, local)) amountX.addAll(flipX);
    return (_signsFromMarkers(_signsFromColumns(_signsFromBalances(_withDocumentCurrency(_amountsFromBalances(sided, fromBalance))), amountX)), bubbleLines);
  }

  /// The full Gregorian dates in the cells at the start of a line and at
  /// its end that hold nothing but dates.
  List<DateTime> _edgeDates(_Line line) {
    List<DateTime>? only(DocToken cell) {
      final t = _Text.normalize(cell.text);
      final (ds, spans) = _dates(t);
      if (ds.isEmpty) return null;
      var rest = t;
      for (final s in [...spans]..sort((a, b) => b.start - a.start)) {
        rest = rest.replaceRange(s.start, s.end, ' ');
      }
      if (RegExp(r'[\p{L}\d]', unicode: true).hasMatch(rest)) return null;
      return [for (final d in ds) if (!d.hijri && !d.loose) d.value];
    }

    List<DateTime> run(Iterable<DocToken> cells) {
      final out = <DateTime>[];
      for (final c in cells) {
        final ds = only(c);
        if (ds == null) break;
        out.addAll(ds);
      }
      return out;
    }

    final start = run(line.cells);
    return start.length >= 2 ? start : run(line.cells.reversed);
  }

  /// Message bubbles on a page, by the index of their first line: runs of
  /// lines with no gap between them that read as sentences (a dozen words
  /// or more over two lines or more) with the amount inside a sentence. In
  /// a list the amount is a piece of text of its own, beside the name.
  Map<int, List<_Line>> _messageBlocks(List<_Line> lines) {
    final out = <int, List<_Line>>{};
    var start = 0;
    void close(int end) {
      final block = lines.sublist(start, end);
      final words = block.fold(0, (n, l) => n + l.text.trim().split(RegExp(r'\s+')).length);
      if (block.length < 2 || words < 12) return;
      var inSentence = false;
      for (final cell in block.expand((l) => l.cells)) {
        final text = _Text.normalize(cell.text);
        final found = _amounts(text, _dates(text).$2);
        if (found.isEmpty) continue;
        final rest = found.fold(text, (t, a) => t.replaceRange(a.span.start, a.span.end, ' '.padRight(a.span.end - a.span.start)));
        final restWords = rest.split(RegExp(r'\s+')).where((w) => RegExp(r'\p{L}{2,}', unicode: true).hasMatch(w) && _Amounts._currencyOf(w) == null).length;
        // A message written as fields ("Amount: SAR 13.00") names each
        // figure with one word.
        if (restWords < 2 && !StatementReader._fieldLabel.hasMatch(text)) return;
        inSentence = true;
      }
      if (inSentence) out[start] = block;
    }

    for (var i = 1; i <= lines.length; i++) {
      if (i == lines.length) {
        close(i);
        break;
      }
      final prev = lines[i - 1], line = lines[i];
      if (line.top - prev.bottom > math.min(prev.height, line.height)) {
        close(i);
        start = i;
      }
    }
    return out;
  }
}
