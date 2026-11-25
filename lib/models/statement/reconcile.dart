part of '../statement_reader.dart';

/// Checks rows against each other once they are read: signs and amounts are
/// settled by the running balance and by which column a figure sits in.
mixin _Reconcile on _ReaderCore, _Dates, _Amounts {
  /// Rows read without columns whose figures are a foreign amount and then
  /// another figure, in a list whose rows carry no balance: the other
  /// figure is the amount in the statement's own currency (card rows), not
  /// a balance.
  List<StatementRow> _localAmounts(List<StatementRow> rows) {
    final foreign = rows.where((r) => r.currency != null && r.balance != null).length;
    if (foreign == 0) return rows;
    final plain = rows.where((r) => r.currency == null && r.balance == null).length;
    if (plain < rows.length / 2) return rows;
    return [
      for (final r in rows)
        r.currency == null || r.balance == null
            ? r
            : StatementRow(
                date: r.date,
                dateGuessed: r.dateGuessed,
                description: r.description,
                detail: [r.detail, '${r.amount.abs().toStringAsFixed(2)} ${r.currency}'].where((s) => s.isNotEmpty).join(' '),
                amount: r.balance!.abs() * (r.amount < 0 ? -1 : 1),
                signGuessed: r.signGuessed,
                line: r.line,
                doubtful: r.doubtful,
              ),
    ];
  }

  /// A list that marks only one direction (refunds and payments "CR" on a
  /// card, or money in "+" in an app): its unmarked rows went the other way.
  List<StatementRow> _signsFromMarkers(List<StatementRow> rows) {
    final marked = rows.where((r) => !r.signGuessed).toList();
    final guessed = rows.length - marked.length;
    // Two marked rows at least: one is no pattern.
    if (marked.length < 2 || guessed < marked.length) return rows;
    final sign = marked.first.amount.sign;
    if (sign == 0 || marked.any((r) => r.amount.sign != sign)) return rows;
    return [for (final r in rows) r.signGuessed ? r.copyWith(amount: -sign * r.amount.abs(), signGuessed: false) : r];
  }

  /// Rows whose only figure was read as the amount but is really their
  /// balance: in a statement where the rows carry balances, the figure is
  /// taken as this row's balance when a neighbouring row's balance moves
  /// from it by exactly that row's amount. Their amounts then come from
  /// the balances, like rows whose amount cell was lost.
  (List<StatementRow>, Set<int>) _balancesTakenForAmounts(List<StatementRow> rows, Set<int> lost) {
    final withBalance = rows.where((r) => r.balance != null).length;
    if (rows.length < 3 || withBalance < rows.length * 2 / 3) return (rows, lost);
    final out = [...rows];
    final missing = {...lost};
    bool movesFrom(double figure, int j) {
      if (j < 0 || j >= rows.length || missing.contains(j)) return false;
      final b = rows[j].balance;
      return b != null && _same((b - figure).abs(), rows[j].amount.abs());
    }

    for (var i = 0; i < rows.length; i++) {
      if (rows[i].balance != null || missing.contains(i)) continue;
      final figure = rows[i].amount.abs();
      if (movesFrom(figure, i + 1) || movesFrom(figure, i - 1)) {
        out[i] = rows[i].copyWith(balance: figure);
        missing.add(i);
      }
    }
    return (out, missing);
  }

  /// Fills in rows that only showed a balance with the change from the row
  /// before (in time); one with nothing to compare against is dropped.
  List<StatementRow> _amountsFromBalances(List<StatementRow> input, Set<int> lost) {
    final (rows, missing) = _balancesTakenForAmounts(input, lost);
    if (missing.isEmpty) return rows;
    // Which way the rows run, from the rows that have both figures.
    var forward = 0, backward = 0;
    for (var i = 1; i < rows.length; i++) {
      if (missing.contains(i) || missing.contains(i - 1)) continue;
      final a = rows[i - 1].balance, b = rows[i].balance;
      if (a == null || b == null) continue;
      if (_same((b - a).abs(), rows[i].amount.abs())) forward++;
      if (_same((a - b).abs(), rows[i - 1].amount.abs())) backward++;
    }
    final newestFirst = backward > forward;
    return [
      for (var i = 0; i < rows.length; i++)
        if (!missing.contains(i))
          rows[i]
        else if ((newestFirst ? i + 1 : i - 1) case final j when j >= 0 && j < rows.length && rows[j].balance != null && !_same(rows[i].balance!, rows[j].balance!))
          rows[i].copyWith(amount: ((rows[i].balance! - rows[j].balance!) * 1000).round() / 1000, signGuessed: false),
    ];
  }

  /// Which figure is the running balance, decided by the numbers: the
  /// reading whose balances move by exactly the amounts wins.
  List<StatementRow> _balanceSide(List<StatementRow> rows, Map<int, (_Money, double)> balanceFirst) {
    if (balanceFirst.length < 2) return rows;
    final flipped = [
      for (var i = 0; i < rows.length; i++)
        if (balanceFirst[i] case (final money, final balance))
          StatementRow(
            date: rows[i].date,
            dateGuessed: rows[i].dateGuessed,
            description: rows[i].description,
            detail: rows[i].detail,
            amount: money.major * (money.sign == 0 ? -1 : money.sign),
            signGuessed: money.sign == 0,
            currency: rows[i].currency,
            balance: balance,
            line: rows[i].line,
          )
        else
          rows[i],
    ];
    int fits(List<StatementRow> rs) {
      var n = 0;
      for (var i = 1; i < rs.length; i++) {
        final a = rs[i - 1].balance, b = rs[i].balance;
        if (a == null || b == null) continue;
        final d = (b - a).abs();
        if (_same(d, rs[i].amount.abs()) || _same(d, rs[i - 1].amount.abs())) n++;
      }
      return n;
    }

    return fits(flipped) > fits(rows) ? flipped : rows;
  }

  /// Rows without their own currency take the one the rest of the document
  /// uses, when it uses one.
  List<StatementRow> _withDocumentCurrency(List<StatementRow> rows) {
    final counts = <String, int>{};
    for (final r in rows) {
      if (r.currency != null) counts[r.currency!] = (counts[r.currency!] ?? 0) + 1;
    }
    if (counts.isEmpty) return rows;
    final top = (counts.entries.toList()..sort((a, b) => b.value - a.value)).first;
    // One foreign row on a card doesn't make the card foreign.
    if (top.value * 2 < rows.length) return rows;
    return [for (final r in rows) r.currency == null ? r.copyWith(currency: top.key) : r];
  }

  static bool _same(double a, double b) => (a * 1000).round() == (b * 1000).round();

  /// Where rows carry a running balance, it says which way each amount went.
  /// Tries the rows oldest first and newest first and keeps whichever order
  /// the balances fit.
  /// How many neighbouring rows the running balance links, read oldest
  /// first and newest first.
  static (int, int) _balanceFits(List<StatementRow> rows) {
    int fits(bool newestFirst) {
      var n = 0;
      for (var i = 1; i < rows.length; i++) {
        final (older, newer) = newestFirst ? (rows[i], rows[i - 1]) : (rows[i - 1], rows[i]);
        if (older.balance == null || newer.balance == null) continue;
        if (_same((newer.balance! - older.balance!).abs(), newer.amount.abs())) n++;
      }
      return n;
    }

    return (fits(false), fits(true));
  }

  List<StatementRow> _signsFromBalances(List<StatementRow> rows) {
    if (rows.where((r) => r.balance != null).length < 2) return rows;
    final (forward, backward) = _balanceFits(rows);
    if (forward == 0 && backward == 0) return rows;
    final newestFirst = backward > forward;
    final out = [...rows];
    for (var i = 0; i < rows.length; i++) {
      final j = newestFirst ? i + 1 : i - 1;
      if (j < 0 || j >= rows.length) continue;
      final r = rows[i], older = rows[j];
      if (r.balance == null || older.balance == null) continue;
      final delta = r.balance! - older.balance!;
      if (!_same(delta.abs(), r.amount.abs()) || delta == 0) continue;
      out[i] = r.copyWith(amount: r.amount.abs() * delta.sign, signGuessed: false);
    }
    return out;
  }

  /// A table printed without column names puts money out and money in in
  /// two columns of their own (CIB): the figures fall into two groups
  /// across the page. Which group is which is decided by the running
  /// balance, printed only now and then: the reading under which the
  /// balances move by the rows between them wins. Only rows whose
  /// direction was a guess change.
  List<StatementRow> _signsFromColumns(List<StatementRow> rows, Map<int, double> amountX) {
    final placed = [for (final r in rows) if (r.line != null && amountX[r.line] != null) amountX[r.line]!]..sort();
    if (placed.length < 8 || rows.where((r) => r.balance != null).length < 3) return rows;
    var gap = 0.0, split = 0.0;
    for (var i = 1; i < placed.length; i++) {
      if (placed[i] - placed[i - 1] > gap) {
        gap = placed[i] - placed[i - 1];
        split = (placed[i] + placed[i - 1]) / 2;
      }
    }
    final left = placed.where((x) => x < split).length;
    if (gap < 0.04 || left < 2 || placed.length - left < 2) return rows;
    List<StatementRow> reading(int leftSign) => [
          for (final r in rows)
            r.signGuessed && r.line != null && amountX[r.line] != null
                ? r.copyWith(amount: r.amount.abs() * (amountX[r.line]! < split ? leftSign : -leftSign), signGuessed: false)
                : r,
        ];
    int fits(List<StatementRow> rs) {
      var best = 0;
      for (final newestFirst in [false, true]) {
        var n = 0;
        int? last;
        for (var i = 0; i < rs.length; i++) {
          if (rs[i].balance == null) continue;
          if (last != null) {
            final between = newestFirst ? rs.sublist(last, i) : rs.sublist(last + 1, i + 1);
            final moved = between.fold<double>(0, (t, r) => t + r.amount);
            final delta = newestFirst ? rs[last].balance! - rs[i].balance! : rs[i].balance! - rs[last].balance!;
            if (_same(moved, delta)) n++;
          }
          last = i;
        }
        best = math.max(best, n);
      }
      return best;
    }

    final outLeft = reading(-1), inLeft = reading(1);
    final a = fits(outLeft), b = fits(inLeft), now = fits(rows);
    if (a > b && a > now) return outLeft;
    if (b > a && b > now) return inLeft;
    return rows;
  }
}
