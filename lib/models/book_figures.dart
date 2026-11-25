import 'book.dart';
import 'display_point.dart';
import 'money.dart';
import 'money_analysis.dart';

/// One month's money in and out, in one currency.
class MonthFlow {
  final DateTime month;
  final double income;
  final double spent;

  const MonthFlow(this.month, this.income, this.spent);

  double get saved => income - spent;

  /// The share of income kept, or null without income.
  double? get savingsRate => income > 0 ? saved / income : null;
}

/// What changed net worth over a month so far: what was saved from income,
/// and everything else (prices, exchange rates, other changes).
class NetWorthChange {
  final double total;
  final double saved;

  const NetWorthChange({required this.total, required this.saved});

  double get other => total - saved;
}

/// Figures read off the person's own book: arithmetic on what happened,
/// never advice.
class BookFigures {
  BookFigures._();

  /// Money in and out for each of the [count] months ending with [anyDay]'s,
  /// oldest first, from the book's first month on.
  static List<MonthFlow> flows(Book book, DateTime anyDay, {required String currency, required FXRates rates, int count = 6}) {
    final first = firstMonth(book);
    if (first == null) return const [];
    return [
      for (var i = count - 1; i >= 0; i--)
        if (!DateTime(anyDay.year, anyDay.month - i).isBefore(first))
          () {
            final a = MonthAnalysis.of(book, DateTime(anyDay.year, anyDay.month - i), currency: currency, rates: rates);
            return MonthFlow(a.month, a.income, a.spent);
          }(),
    ];
  }

  /// The month of the book's earliest entry, or null for an empty book.
  static DateTime? firstMonth(Book book) {
    if (book.entries.isEmpty) return null;
    final first = book.entries.map((e) => e.date).reduce((a, b) => a.isBefore(b) ? a : b);
    return DateTime(first.year, first.month);
  }

  /// Average spending over the up to [months] whole months before
  /// [anyDay]'s month that the book covers; null with none.
  static double? usualSpending(Book book, DateTime anyDay, {required String currency, required FXRates rates, int months = 3}) {
    final before = _monthsBefore(book, anyDay, months);
    if (before.isEmpty) return null;
    final total = before.fold(0.0, (sum, m) => sum + MonthAnalysis.of(book, m, currency: currency, rates: rates).spent);
    return total / before.length;
  }

  /// Usual monthly spending per category over the up to [months] whole
  /// months before [anyDay]'s, by category id. Empty when the book doesn't
  /// reach back a month.
  static Map<String, double> usualByCategory(Book book, DateTime anyDay, {required String currency, required FXRates rates, int months = 3}) {
    final before = _monthsBefore(book, anyDay, months);
    if (before.isEmpty) return const {};
    final sums = <String, double>{};
    for (final m in before) {
      for (final (id, v) in MonthAnalysis.of(book, m, currency: currency, rates: rates).byCategory) {
        sums[id] = (sums[id] ?? 0) + v;
      }
    }
    return {for (final e in sums.entries) e.key: e.value / before.length};
  }

  static List<DateTime> _monthsBefore(Book book, DateTime anyDay, int months) {
    final first = firstMonth(book);
    if (first == null) return const [];
    return [
      for (var i = 1; i <= months; i++)
        if (!DateTime(anyDay.year, anyDay.month - i).isBefore(first)) DateTime(anyDay.year, anyDay.month - i),
    ];
  }

  /// How many months [cash] covers at [monthlySpending]; null without
  /// spending to measure against.
  static double? runwayMonths(double cash, double? monthlySpending) {
    if (monthlySpending == null || monthlySpending <= 0 || cash <= 0) return null;
    return cash / monthlySpending;
  }

  /// The change in net worth since [now]'s month began, read off [points]
  /// (a daily net worth history reaching back past the month's start), with
  /// [saved] this month's income minus spending. Null when [points] don't
  /// reach the month's start.
  static NetWorthChange? monthChange(List<DisplayPoint> points, DateTime now, double saved) {
    if (points.length < 2) return null;
    final start = DateTime(now.year, now.month);
    DisplayPoint? before;
    for (final p in points) {
      if (!p.date.isBefore(start)) break;
      before = p;
    }
    if (before == null) return null;
    return NetWorthChange(total: points.last.value - before.value, saved: saved);
  }

  /// What is owed as a share of what is owned, or null when nothing is
  /// owned.
  static double? debtRatio(double owned, double owed) => owned > 0 ? owed / owned : null;
}
