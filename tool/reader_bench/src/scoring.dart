// How the reader bench scores one reading: against the rows a person
// confirmed are on the document, and by measures that need no one to have
// looked (guesses, whether the statement adds up).
import 'dart:convert';
import 'dart:io';

import 'package:qima/models/statement_facts.dart';
import 'package:qima/models/statement_reader.dart';
import 'package:qima/services/import/statement_files.dart';

// --------------------------------------------------------------- expected

/// One transaction a person confirmed is on the document.
class ExpectedRow {
  final DateTime date;

  /// Positive is money in, negative money out.
  final double amount;

  /// Null when the document doesn't print one on the row.
  final String? currency;
  final String name;

  /// Null when the document prints no balance on the row.
  final double? balance;

  const ExpectedRow({required this.date, required this.amount, this.currency, this.name = '', this.balance});

  Map<String, Object?> toJson() => {'date': _day(date), 'amount': amount, 'currency': currency, 'name': name, 'balance': balance};

  factory ExpectedRow.fromJson(Map<String, dynamic> json) => ExpectedRow(
        date: DateTime.parse(json['date'] as String),
        amount: (json['amount'] as num).toDouble(),
        currency: json['currency'] as String?,
        name: json['name'] as String? ?? '',
        balance: (json['balance'] as num?)?.toDouble(),
      );
}

String _day(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// What a document holds, as a person confirmed it. Only a [verified] file
/// counts toward accuracy: until someone has checked it, it is just the
/// reader's own reading written down.
class Expected {
  final bool verified;
  final List<ExpectedRow> rows;

  /// The opening and closing balances and the account's last four digits,
  /// each null when the document doesn't print it.
  final double? opening, closing;
  final String? account;

  const Expected({this.verified = false, this.rows = const [], this.opening, this.closing, this.account});

  Map<String, Object?> toJson() => {
        'verified': verified,
        'opening': opening,
        'closing': closing,
        'account': account,
        'rows': [for (final r in rows) r.toJson()],
      };

  factory Expected.fromJson(Map<String, dynamic> json) => Expected(
        verified: json['verified'] == true,
        opening: (json['opening'] as num?)?.toDouble(),
        closing: (json['closing'] as num?)?.toDouble(),
        account: json['account'] as String?,
        rows: [for (final r in json['rows'] as List? ?? const []) ExpectedRow.fromJson(r as Map<String, dynamic>)],
      );

  static Expected? load(File file) => file.existsSync() ? Expected.fromJson(jsonDecode(file.readAsStringSync()) as Map<String, dynamic>) : null;

  /// A reading written down for a person to correct. Balances the reader
  /// worked out from the rows are left out: the document doesn't print them.
  factory Expected.proposed(StatementRead read) => Expected(
        opening: read.facts.openingWorkedOut ? null : read.facts.opening,
        closing: read.facts.closingWorkedOut ? null : read.facts.closing,
        account: read.facts.refs.firstOrNull?.last4,
        rows: [
          for (final r in read.rows) ExpectedRow(date: r.date, amount: r.amount, currency: r.currency, name: r.description, balance: r.balance),
        ],
      );
}

/// Writes an unverified candidate to [file] unless one is there already: a
/// person's corrections are never overwritten. Says whether it wrote.
bool propose(File file, StatementRead read) {
  if (file.existsSync()) return false;
  file.parent.createSync(recursive: true);
  file.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(Expected.proposed(read).toJson())}\n');
  return true;
}

// --------------------------------------------------------------- matching

bool sameMoney(double a, double b) => (a - b).abs() < 0.005;
bool sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

/// A name as the reader folds text, lower-cased and with single spaces.
String foldName(String s) => StatementReader.normalize(s).toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

bool nameExact(String expected, String read) => foldName(expected) == foldName(read);

/// One name holds the other: a reading that kept the city or dropped a
/// reference is still the same payee.
bool nameContains(String expected, String read) {
  final a = foldName(expected), b = foldName(read);
  return a == b || (a.isNotEmpty && b.isNotEmpty && (a.contains(b) || b.contains(a)));
}

/// The digits of an amount without its zeros and point: a slipped decimal
/// point or a lost thousands group leaves them as they were.
String _digits(double amount) => amount.abs().toStringAsFixed(2).replaceAll(RegExp(r'[^1-9]'), '');

class RowPair {
  final int expected, read;
  const RowPair(this.expected, this.read);
}

/// Which read row is which expected row, each used once.
class Matching {
  final List<RowPair> pairs;

  /// Expected rows the reading doesn't have, and read rows the document
  /// doesn't, by index.
  final List<int> missed, invented;

  const Matching(this.pairs, this.missed, this.invented);
}

/// Pairs read rows with expected rows, whatever order either is in. The
/// surest pairs are made first: the same day, amount and direction; then
/// the same day and amount (a wrong direction); then the same amount on
/// the nearest other day (a wrong date); then the same day with something
/// else to tie the two together, the name, the balance or the amount's
/// digits (a wrong amount). What is left over was missed or invented.
Matching matchRows(List<ExpectedRow> expected, List<StatementRow> read) {
  final pairOfExpected = <int, int>{};
  final usedRead = <int>{};

  int nameRank(ExpectedRow e, StatementRow r) => nameExact(e.name, r.description) ? 0 : (nameContains(e.name, r.description) ? 1 : 2);

  void tier(bool Function(ExpectedRow, StatementRow) fits, {bool nearestDay = false}) {
    final candidates = <(int, int, int, int)>[];
    for (var e = 0; e < expected.length; e++) {
      if (pairOfExpected.containsKey(e)) continue;
      for (var r = 0; r < read.length; r++) {
        if (usedRead.contains(r) || !fits(expected[e], read[r])) continue;
        final days = nearestDay ? expected[e].date.difference(read[r].date).inDays.abs() : 0;
        candidates.add((days, nameRank(expected[e], read[r]), e, r));
      }
    }
    // Ties fall to the order the rows are in.
    candidates.sort((a, b) {
      for (final c in [a.$1 - b.$1, a.$2 - b.$2, (a.$3 - a.$4).abs() - (b.$3 - b.$4).abs(), a.$3 - b.$3, a.$4 - b.$4]) {
        if (c != 0) return c;
      }
      return 0;
    });
    for (final (_, _, e, r) in candidates) {
      if (pairOfExpected.containsKey(e) || usedRead.contains(r)) continue;
      pairOfExpected[e] = r;
      usedRead.add(r);
    }
  }

  bool amount(ExpectedRow e, StatementRow r) => sameMoney(e.amount.abs(), r.amount.abs());
  bool sign(ExpectedRow e, StatementRow r) => e.amount.sign == r.amount.sign;
  bool day(ExpectedRow e, StatementRow r) => sameDay(e.date, r.date);

  tier((e, r) => day(e, r) && amount(e, r) && sign(e, r));
  tier((e, r) => day(e, r) && amount(e, r));
  tier(amount, nearestDay: true);
  tier((e, r) =>
      day(e, r) &&
      ((e.name.trim().isNotEmpty && nameContains(e.name, r.description)) ||
          (e.balance != null && r.balance != null && sameMoney(e.balance!, r.balance!)) ||
          (_digits(e.amount).isNotEmpty && _digits(e.amount) == _digits(r.amount))));

  return Matching(
    [for (var e = 0; e < expected.length; e++) if (pairOfExpected.containsKey(e)) RowPair(e, pairOfExpected[e]!)],
    [for (var e = 0; e < expected.length; e++) if (!pairOfExpected.containsKey(e)) e],
    [for (var r = 0; r < read.length; r++) if (!usedRead.contains(r)) r],
  );
}

// --------------------------------------------------------------- measures

/// So many out of so many.
class Share {
  int n, d;
  Share([this.n = 0, this.d = 0]);

  double? get percent => d == 0 ? null : 100 * n / d;

  void add(Share other) {
    n += other.n;
    d += other.d;
  }

  void count(bool hit) {
    d++;
    if (hit) n++;
  }

  Map<String, Object?> toJson() => {'n': n, 'd': d, 'percent': percent == null ? null : double.parse(percent!.toStringAsFixed(2))};
}

/// A measure, in the order the table prints them. [better] says which way
/// is an improvement: 1 a higher share, -1 a lower one, 0 neither (it
/// describes the documents, or what the model doubts).
class Measure {
  final String key, label;
  final int better;

  /// Needs rows a person verified.
  final bool labelled;

  const Measure(this.key, this.label, this.better, {this.labelled = false});

  static const all = [
    Measure('read', 'files read at all', 1),
    Measure('withRows', 'files with rows', 1),
    Measure('dateGuessed', 'rows with a guessed date', -1),
    Measure('signGuessed', 'rows with a guessed direction', -1),
    Measure('doubtful', 'rows marked doubtful', 0),
    Measure('checkable', 'statements with both balances', 0),
    Measure('addsUp', 'statements that add up', 1),
    Measure('balanceLinks', 'neighbouring rows the balance links', 1),
    Measure('recall', 'rows found (recall)', 1, labelled: true),
    Measure('precision', 'rows not invented (precision)', 1, labelled: true),
    Measure('date', 'matched rows: date right', 1, labelled: true),
    Measure('direction', 'matched rows: direction right', 1, labelled: true),
    Measure('amount', 'matched rows: amount right', 1, labelled: true),
    Measure('currency', 'matched rows: currency right', 1, labelled: true),
    Measure('balance', 'matched rows: balance right', 1, labelled: true),
    Measure('nameExact', 'matched rows: name exact', 1, labelled: true),
    Measure('nameContains', 'matched rows: name contains', 1, labelled: true),
    Measure('opening', 'opening balance right', 1, labelled: true),
    Measure('closing', 'closing balance right', 1, labelled: true),
    Measure('account', 'account reference right', 1, labelled: true),
  ];
}

/// The measures of one reading, or of many added together.
class Tally {
  final Map<String, Share> shares = {for (final m in Measure.all) m.key: Share()};
  int files = 0, rows = 0, verifiedFiles = 0, expectedRows = 0;

  Share operator [](String key) => shares[key]!;

  void add(Tally other) {
    files += other.files;
    rows += other.rows;
    verifiedFiles += other.verifiedFiles;
    expectedRows += other.expectedRows;
    for (final e in other.shares.entries) {
      shares[e.key]!.add(e.value);
    }
  }

  /// Everything the reading got wrong against verified rows: rows missed
  /// and invented, each wrong field of a matched row, each wrong balance or
  /// account. Lower is a better reading. A name counts as right when one
  /// holds the other.
  int get mistakes {
    var out = 0;
    for (final key in ['recall', 'precision', 'date', 'direction', 'amount', 'currency', 'balance', 'nameContains', 'opening', 'closing', 'account']) {
      out += shares[key]!.d - shares[key]!.n;
    }
    return out;
  }

  Map<String, Object?> toJson() => {
        'files': files,
        'rows': rows,
        'verifiedFiles': verifiedFiles,
        'expectedRows': expectedRows,
        for (final m in Measure.all) m.key: shares[m.key]!.toJson(),
      };
}

/// Scores one file's [read]. [expected] only counts when verified.
Tally score(StatementRead read, [Expected? expected]) {
  final t = Tally()..files = 1;
  final rows = read.rows, facts = read.facts;
  t.rows = rows.length;
  t['read'].count(read.outcome == ReadOutcome.read);
  t['withRows'].count(rows.isNotEmpty);
  for (final r in rows) {
    t['dateGuessed'].count(r.dateGuessed);
    t['signGuessed'].count(r.signGuessed);
    t['doubtful'].count(r.doubtful);
  }
  final reconciliation = Reconciliation.of(facts, rows);
  if (read.outcome == ReadOutcome.read) t['checkable'].count(reconciliation != null);
  if (reconciliation != null) t['addsUp'].count(reconciliation.addsUp);
  // Only pairs that both print a balance can be linked by one.
  final withBalances = [for (var i = 1; i < rows.length; i++) if (rows[i].balance != null && rows[i - 1].balance != null) i].length;
  if (withBalances > 0) {
    final (forward, backward) = StatementReader.balanceLinks(rows);
    t['balanceLinks'].add(Share(forward > backward ? forward : backward, withBalances));
  }

  if (expected == null || !expected.verified) return t;
  t.verifiedFiles = 1;
  t.expectedRows = expected.rows.length;
  final m = matchRows(expected.rows, rows);
  t['recall'].add(Share(m.pairs.length, expected.rows.length));
  t['precision'].add(Share(m.pairs.length, rows.length));
  for (final p in m.pairs) {
    final e = expected.rows[p.expected], r = rows[p.read];
    t['date'].count(sameDay(e.date, r.date));
    t['direction'].count(e.amount.sign == r.amount.sign);
    t['amount'].count(sameMoney(e.amount.abs(), r.amount.abs()));
    // A field the document doesn't print can't be read right or wrong.
    if (e.currency != null) t['currency'].count(r.currency == e.currency);
    if (e.balance != null) t['balance'].count(r.balance != null && sameMoney(r.balance!, e.balance!));
    if (e.name.trim().isNotEmpty) {
      t['nameExact'].count(nameExact(e.name, r.description));
      t['nameContains'].count(nameContains(e.name, r.description));
    }
  }
  if (expected.opening != null) t['opening'].count(facts.opening != null && sameMoney(facts.opening!, expected.opening!));
  if (expected.closing != null) t['closing'].count(facts.closing != null && sameMoney(facts.closing!, expected.closing!));
  final account = expected.account?.replaceAll(RegExp(r'\D'), '');
  if (account != null && account.length >= 4) {
    final last4 = account.substring(account.length - 4);
    t['account'].count(facts.refs.any((ref) => ref.last4 == last4));
  }
  return t;
}
