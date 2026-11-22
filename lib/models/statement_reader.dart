import 'dart:math' as math;

import 'package:equatable/equatable.dart';

import 'minor_units.dart';
import 'statement_facts.dart';

part 'bank_message.dart';
part 'statement/text.dart';
part 'statement/dates.dart';
part 'statement/amounts.dart';
part 'statement/layout.dart';
part 'statement/rows.dart';
part 'statement/reconcile.dart';
part 'statement/facts.dart';
part 'statement/model.dart';

/// A piece of text on a page and where it sits, in page fractions (0 to 1,
/// top left origin). PDFs give one per run of text, screenshots one per
/// recognized line, spreadsheets one per cell.
class DocToken extends Equatable {
  final String text;
  final double x, y, w, h;

  const DocToken(this.text, this.x, this.y, this.w, this.h);

  double get midY => y + h / 2;
  double get right => x + w;

  factory DocToken.fromJson(Map<dynamic, dynamic> json) => DocToken(
        json['t'] as String? ?? '',
        (json['x'] as num).toDouble(),
        (json['y'] as num).toDouble(),
        (json['w'] as num).toDouble(),
        (json['h'] as num).toDouble(),
      );

  @override
  List<Object?> get props => [text, x, y, w, h];
}

class DocPage {
  final List<DocToken> tokens;
  const DocPage(this.tokens);

  /// A spreadsheet or CSV as pages of cells: each row a line, each column at
  /// its own place across the page, so the same reader handles both.
  factory DocPage.fromTable(List<List<String>> rows) {
    final columns = rows.fold<int>(1, (m, r) => math.max(m, r.length));
    final w = 1 / columns;
    final h = rows.isEmpty ? 1.0 : 1 / rows.length;
    return DocPage([
      for (var r = 0; r < rows.length; r++)
        for (var c = 0; c < rows[r].length; c++)
          if (rows[r][c].trim().isNotEmpty) DocToken(rows[r][c].trim(), c * w, r * h, w * 0.98, h * 0.9),
    ]);
  }
}

/// One transaction read from a statement, a screenshot or a message.
class StatementRow extends Equatable {
  final DateTime date;

  /// No date was found on the row or above it; [date] is the day it was
  /// shared.
  final bool dateGuessed;
  final String description;

  /// More text found under the row (a second line, a reference).
  final String detail;

  /// As written, in [currency] (or the account's currency when null);
  /// positive is money in, negative money out.
  final double amount;

  /// Nothing on the row said whether the money came in or went out.
  final bool signGuessed;
  final String? currency;
  final double? balance;

  /// The line of the document the row was read from ([StatementReader.lineTexts]).
  final int? line;

  /// The on-device model read the row's line as the bank's own text, not a
  /// transaction. Kept for the person to decide, unticked.
  final bool doubtful;

  const StatementRow({
    required this.date,
    required this.description,
    required this.amount,
    this.dateGuessed = false,
    this.detail = '',
    this.signGuessed = false,
    this.currency,
    this.balance,
    this.line,
    this.doubtful = false,
  });

  bool get isIn => amount > 0;

  StatementRow copyWithLine(int line) => StatementRow(
        date: date,
        description: description,
        amount: amount,
        dateGuessed: dateGuessed,
        detail: detail,
        signGuessed: signGuessed,
        currency: currency,
        balance: balance,
        line: line,
        doubtful: doubtful,
      );

  StatementRow copyWith(
          {DateTime? date, bool? dateGuessed, String? description, double? amount, bool? signGuessed, String? currency, double? balance, bool? doubtful}) =>
      StatementRow(
        date: date ?? this.date,
        description: description ?? this.description,
        amount: amount ?? this.amount,
        dateGuessed: dateGuessed ?? this.dateGuessed,
        detail: detail,
        signGuessed: signGuessed ?? this.signGuessed,
        currency: currency ?? this.currency,
        balance: balance ?? this.balance,
        line: line,
        doubtful: doubtful ?? this.doubtful,
      );

  @override
  List<Object?> get props => [date, dateGuessed, description, detail, amount, signGuessed, currency, balance, line, doubtful];

  @override
  String toString() => 'StatementRow(${date.toIso8601String().substring(0, 10)}, $description, $amount ${currency ?? ''})';
}

enum _Column { date, description, debit, credit, amount, balance }

class _Span {
  final int start, end;
  const _Span(this.start, this.end);
}

class _Found<T> {
  final T value;
  final _Span span;
  final double x;

  /// A date written in the Hijri calendar (and converted).
  final bool hijri;

  /// A day and month in figures with no year ("24/3"): often the Hijri
  /// date a Saudi statement prints under the real one.
  final bool loose;
  const _Found(this.value, this.span, this.x, {this.hijri = false, this.loose = false});
}

class _Money {
  final double major;

  /// -1 out, 1 in, 0 not said.
  final int sign;
  final String? currency;

  /// A whole number with no grouping, decimals or currency, only taken
  /// because it sits under an amount column.
  final bool bare;
  const _Money(this.major, this.sign, this.currency, {this.bare = false});
}

class _Line {
  final List<DocToken> cells;
  _Line(this.cells);
  double get top => cells.map((c) => c.y).reduce(math.min);
  double get bottom => cells.map((c) => c.y + c.h).reduce(math.max);
  double get height => bottom - top;
  double get left => cells.first.x;
  String get text => cells.map((c) => c.text).join(' ');
}

/// Reads transactions out of whatever a bank gives: statement PDFs (with a
/// text layer or scanned), tables, screenshots of a banking app, CSV and
/// Excel exports, and bank messages. Everything arrives as positioned text
/// ([DocPage]); rows are rebuilt from where the text sits, and columns from
/// a header row when there is one.
///
/// It never makes up an amount: a row without one is dropped. When it can't
/// tell the date or whether money came in or went out, it says so
/// ([StatementRow.dateGuessed], [StatementRow.signGuessed]) and the review
/// screen asks.
///
/// The reading runs in stages, each in its own file under `statement/`:
/// text, dates and amounts find what a line holds; layout rebuilds lines
/// and columns; rows turns lines into transactions; reconcile checks them
/// against the running balance; facts reads what the document says about
/// itself; model joins the on-device model's reading. A stage names the
/// ones it needs in its `on` clause.
class StatementReader extends _ReaderCore with _Dates, _Amounts, _Layout, _Reconcile, _Rows, _Facts, _Model {
  StatementReader({required super.received});

  static String normalize(String s) => _Text.normalize(s);
  static double? parseNumber(String raw, {String? currency}) => _Amounts.parseNumber(raw, currency: currency);
  static DateTime hijriToGregorian(int y, int m, int d) => _Dates.hijriToGregorian(y, m, d);

  /// How many neighbouring pairs of [rows] the running balance links, read
  /// oldest first and newest first. For measuring a reading (the reader
  /// bench), not for making one.
  static (int, int) balanceLinks(List<StatementRow> rows) => _Reconcile._balanceFits(rows);

  /// One row per message: shared text such as a bank SMS. Messages are
  /// separated by blank lines.
  List<StatementRow> readMessages(String text) {
    // A message's minus is never a card statement's refund marker.
    _trailingMinusIsCredit = false;
    return [
      for (final block in _Text.normalize(text).split(RegExp(r'\n\s*\n')))
        ?_message(block.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList()),
    ];
  }

  static final _merchantAt = RegExp(r'(?:\bat\b|لدى|\bchez\b|\ben\b)\s*:?\s*([^\d\s*][^·]{1,40})', caseSensitive: false);
  static final _paidTo = RegExp(r'(?:\bto\b|(?:^|\s)(?:إلى|الى|لصالح)(?=\s))\s*:?\s*([^\d\s*][^·]{1,40})', caseSensitive: false);
  static final _paidFrom = RegExp(r'(?:\bfrom\b|(?:^|\s)من(?=\s))\s*:?\s*([^\d\s*][^·]{1,40})', caseSensitive: false);
  // Where a name stops: the date, a reference, the next sentence.
  static final _nameEnd = RegExp(r'(?:\s(?:on|at|ref|reference|بتاريخ|في|برقم|رقم|le|el|via|عبر)(?:\s|$)|(?<![\s.]\p{L})(?<!\.)\.(?=\s|$)|[،,;:](?:\s|$)|\s\d).*$', caseSensitive: false, unicode: true);
  // A message's "Label: value" line, and the labels that name who was paid.
  static final _fieldLabel = RegExp(r'^\s*\p{L}[\p{L}\s()/.-]{0,30}:\s*\S', unicode: true);
  static final _payeeField = RegExp(
    r'^\s*(?:merchant(?: name)?|payee|beneficiary|store|shop|اسم التاجر|التاجر|المتجر|لدى|المستفيد|marchand|commerçant|bénéficiaire|comercio|beneficiario)\s*:\s*(.+)$',
    caseSensitive: false,
  );
  // The figure a message gives after the transaction: the limit or the
  // balance left.
  static final _leftBefore = RegExp(
    r'(?:limit|balance|available|remaining|الرصيد|المتبقي|المتاح|الحد|المتوفر|solde|plafond|disponible|saldo|límite)[^\d]{0,20}$',
    caseSensitive: false,
  );
  static final _accountWords = RegExp(r'^(?:your\s)?(?:account|card|a/c|حساب|حسابك|بطاقة|بطاقتك|compte|cuenta)', caseSensitive: false);
}

/// What every stage shares about one reading.
abstract class _ReaderCore {
  /// When the file was shared: the year for dates written without one, and
  /// the day for "Today".
  final DateTime received;

  _ReaderCore({required this.received});
}
