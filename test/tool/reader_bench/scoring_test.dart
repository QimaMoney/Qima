import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/statement_facts.dart';
import 'package:qima/models/statement_reader.dart';
import 'package:qima/services/import/statement_files.dart';

import '../../../tool/reader_bench/src/runner.dart';
import '../../../tool/reader_bench/src/scoring.dart';

// Every figure and name here is made up.
ExpectedRow want(int day, double amount, [String name = '', double? balance, String? currency]) =>
    ExpectedRow(date: DateTime(2026, 11, day), amount: amount, name: name, balance: balance, currency: currency);

StatementRow got(int day, double amount, [String name = '', double? balance, String? currency]) =>
    StatementRow(date: DateTime(2026, 11, day), description: name, amount: amount, balance: balance, currency: currency);

StatementRead reading(List<StatementRow> rows, [StatementFacts facts = StatementFacts.none]) => StatementRead(ReadOutcome.read, rows, facts);

List<(int, int)> pairs(Matching m) => [for (final p in m.pairs) (p.expected, p.read)];

void main() {
  group('matching', () {
    test('the same rows in the same order pair up', () {
      final m = matchRows([want(1, -10), want(2, 20)], [got(1, -10), got(2, 20)]);
      expect(pairs(m), [(0, 0), (1, 1)]);
      expect(m.missed, isEmpty);
      expect(m.invented, isEmpty);
    });

    test('a row the reading lacks is missed, one the document lacks is invented', () {
      final m = matchRows([want(1, -10), want(2, 20), want(3, -30)], [got(1, -10), got(3, -30), got(4, -99)]);
      expect(pairs(m), [(0, 0), (2, 1)]);
      expect(m.missed, [1]);
      expect(m.invented, [2]);
    });

    test('order does not matter', () {
      final m = matchRows([want(1, -10), want(2, 20), want(3, -30)], [got(3, -30), got(2, 20), got(1, -10)]);
      expect(pairs(m), [(0, 2), (1, 1), (2, 0)]);
      expect(m.missed, isEmpty);
      expect(m.invented, isEmpty);
    });

    test('a wrong direction still pairs, after the rows that fit fully', () {
      // Two rows of the same amount on one day, one in and one out, and a
      // reading that has the second the wrong way round.
      final m = matchRows([want(5, -40, 'A'), want(5, 40, 'B')], [got(5, -40, 'A'), got(5, -40, 'B')]);
      expect(pairs(m), [(0, 0), (1, 1)]);
      expect(m.missed, isEmpty);
    });

    test('the same amount twice on one day pairs each once', () {
      final twice = matchRows([want(5, -12.5), want(5, -12.5)], [got(5, -12.5), got(5, -12.5)]);
      expect(pairs(twice), [(0, 0), (1, 1)]);
      final once = matchRows([want(5, -12.5), want(5, -12.5)], [got(5, -12.5)]);
      expect(pairs(once), [(0, 0)]);
      expect(once.missed, [1]);
      final thrice = matchRows([want(5, -12.5), want(5, -12.5)], [got(5, -12.5), got(5, -12.5), got(5, -12.5)]);
      expect(thrice.invented, [2]);
    });

    test('the same amount twice on one day goes to the row of the same name', () {
      final m = matchRows([want(5, -12.5, 'Bakery'), want(5, -12.5, 'Taxi')], [got(5, -12.5, 'TAXI'), got(5, -12.5, 'BAKERY')]);
      expect(pairs(m), [(0, 1), (1, 0)]);
    });

    test('a wrong date pairs with the nearest day of the same amount', () {
      final m = matchRows([want(10, -75)], [got(20, -75), got(11, -75)]);
      expect(pairs(m), [(0, 1)]);
      expect(m.invented, [0]);
    });

    test('a wrong amount pairs only when something else ties the rows', () {
      // The decimal point slipped: the digits are the same.
      expect(pairs(matchRows([want(7, -1250)], [got(7, -12.5)])), [(0, 0)]);
      // The same name on the same day.
      expect(pairs(matchRows([want(7, -80, 'Corner Cafe')], [got(7, -30, 'CORNER CAFE RIYADH')])), [(0, 0)]);
      // The same balance after it.
      expect(pairs(matchRows([want(7, -80, '', 920)], [got(7, -30, '', 920)])), [(0, 0)]);
      // Nothing in common but the day: one missed, one invented.
      final apart = matchRows([want(7, -80, 'Corner Cafe')], [got(7, -30, 'Fuel')]);
      expect(apart.pairs, isEmpty);
      expect(apart.missed, [0]);
      expect(apart.invented, [0]);
    });
  });

  group('measures against verified rows', () {
    Tally scored(List<ExpectedRow> expected, List<StatementRow> rows, {StatementFacts facts = StatementFacts.none, double? opening, double? closing, String? account}) =>
        score(reading(rows, facts), Expected(verified: true, rows: expected, opening: opening, closing: closing, account: account));

    test('rows found and rows invented', () {
      final t = scored([want(1, -10), want(2, 20), want(3, -30), want(4, -40)], [got(1, -10), got(2, 20), got(3, -30), got(9, -5), got(9, -6)]);
      expect((t['recall'].n, t['recall'].d), (3, 4));
      expect((t['precision'].n, t['precision'].d), (3, 5));
      expect(t['recall'].percent, 75);
      expect(t.verifiedFiles, 1);
      expect(t.expectedRows, 4);
    });

    test('each field of a matched row is scored on its own', () {
      final t = scored(
        [want(1, -10, 'Bakery', 90, 'SAR'), want(2, 20, 'Refund', 110, 'SAR'), want(3, -30, 'Taxi', 80, 'SAR')],
        [got(1, -10, 'bakery', 90, 'SAR'), got(2, -20, 'REFUND SHOP 12', 110, 'USD'), got(8, -30, 'Fuel', 81, 'SAR')],
      );
      expect((t['date'].n, t['date'].d), (2, 3));
      expect((t['direction'].n, t['direction'].d), (2, 3));
      expect((t['amount'].n, t['amount'].d), (3, 3));
      expect((t['currency'].n, t['currency'].d), (2, 3));
      expect((t['balance'].n, t['balance'].d), (2, 3));
      // Case is folded; a longer name that holds the expected one counts
      // only as "contains".
      expect((t['nameExact'].n, t['nameExact'].d), (1, 3));
      expect((t['nameContains'].n, t['nameContains'].d), (2, 3));
    });

    test('a wrong amount is counted on the matched row', () {
      final t = scored([want(7, -1250, 'Rent')], [got(7, -12.5, 'Rent')]);
      expect((t['recall'].n, t['recall'].d), (1, 1));
      expect((t['amount'].n, t['amount'].d), (0, 1));
    });

    test('a field the document does not print is not scored', () {
      final t = scored([want(1, -10)], [got(1, -10, 'Anything', 50, 'SAR')]);
      expect(t['currency'].d, 0);
      expect(t['balance'].d, 0);
      expect(t['nameExact'].d, 0);
      expect(t['opening'].d, 0);
      expect(t['account'].d, 0);
    });

    test('opening, closing and the account', () {
      const facts = StatementFacts(opening: 100, closing: 70, refs: [StatementRef(StatementRefKind.account, '4321', 12)]);
      final right = scored([want(1, -30)], [got(1, -30)], facts: facts, opening: 100, closing: 70, account: '000000004321');
      expect((right['opening'].n, right['closing'].n, right['account'].n), (1, 1, 1));
      final wrong = scored([want(1, -30)], [got(1, -30)], facts: facts, opening: 101, closing: 71, account: '9999');
      expect((wrong['opening'].n, wrong['closing'].n, wrong['account'].n), (0, 0, 0));
      expect((wrong['opening'].d, wrong['closing'].d, wrong['account'].d), (1, 1, 1));
      final unread = scored([want(1, -30)], [got(1, -30)], opening: 100);
      expect((unread['opening'].n, unread['opening'].d), (0, 1));
    });

    test('unverified rows never count', () {
      final t = score(reading([got(1, -10)]), Expected(rows: [want(1, -10)]));
      expect(t.verifiedFiles, 0);
      expect(t['recall'].d, 0);
      expect(t['date'].d, 0);
      expect(t.mistakes, 0);
    });

    test('mistakes add up what was missed, invented and misread', () {
      // One missed, one invented, one wrong direction.
      final t = scored([want(1, -10), want(2, 20)], [got(2, -20), got(9, -5)]);
      expect(t.mistakes, 3);
    });
  });

  group('measures that need no expected rows', () {
    test('guesses and doubts are shares of the rows', () {
      final t = score(reading([
        got(1, -10).copyWith(dateGuessed: true),
        got(2, -20).copyWith(signGuessed: true, doubtful: true),
        got(3, -30).copyWith(signGuessed: true),
        got(4, -40),
      ]));
      expect((t['dateGuessed'].n, t['dateGuessed'].d), (1, 4));
      expect((t['signGuessed'].n, t['signGuessed'].d), (2, 4));
      expect((t['doubtful'].n, t['doubtful'].d), (1, 4));
      expect(t.rows, 4);
      expect((t['read'].n, t['withRows'].n), (1, 1));
    });

    test('an unreadable file and a file without rows', () {
      final unreadable = score(const StatementRead(ReadOutcome.unreadable));
      expect((unreadable['read'].n, unreadable['read'].d), (0, 1));
      expect(unreadable['checkable'].d, 0);
      final empty = score(reading(const []));
      expect((empty['read'].n, empty['withRows'].n, empty['withRows'].d), (1, 0, 1));
    });

    test('a statement adds up or does not, when it prints both balances', () {
      final rows = [got(1, -10, '', 90), got(2, 25, '', 115)];
      final adds = score(reading(rows, const StatementFacts(opening: 100, closing: 115)));
      expect((adds['checkable'].n, adds['addsUp'].n, adds['addsUp'].d), (1, 1, 1));
      final off = score(reading(rows, const StatementFacts(opening: 100, closing: 140)));
      expect((off['addsUp'].n, off['addsUp'].d), (0, 1));
      final none = score(reading(rows));
      expect((none['checkable'].n, none['checkable'].d, none['addsUp'].d), (0, 1, 0));
    });

    test('the running balance links neighbouring rows', () {
      // The third row's balance does not follow from the second.
      final t = score(reading([got(1, -10, '', 90), got(2, 25, '', 115), got(3, -5, '', 300), got(4, -7)]));
      expect((t['balanceLinks'].n, t['balanceLinks'].d), (1, 2));
      expect(score(reading([got(1, -10), got(2, 25)]))['balanceLinks'].d, 0);
    });

    test('tallies add', () {
      final total = Tally()
        ..add(score(reading([got(1, -10).copyWith(signGuessed: true)])))
        ..add(score(reading([got(1, -10), got(2, -20)])));
      expect(total.files, 2);
      expect(total.rows, 3);
      expect((total['signGuessed'].n, total['signGuessed'].d), (1, 3));
    });
  });

  group('what the model did to a reading', () {
    final expected = Expected(verified: true, rows: [want(1, -10), want(2, 20)]);
    final right = reading([got(1, -10), got(2, 20)]);
    final wrongWay = reading([got(1, -10), got(2, -20)]);
    FileResult file(StatementRead rules, StatementRead? model, {Expected? against}) =>
        FileResult(rel: 'Bank/a.pdf', bank: 'Bank', kind: 'pdf', rules: rules, model: model, expected: against);

    test('better, worse, unchanged, and not decidable without verified rows', () {
      final effect = ModelEffect()
        ..add(file(wrongWay, right, against: expected))
        ..add(file(right, wrongWay, against: expected))
        ..add(file(right, right, against: expected))
        ..add(file(wrongWay, right))
        ..add(file(wrongWay, right, against: Expected(rows: expected.rows)))
        // No model answers: not counted at all.
        ..add(file(right, null, against: expected));
      expect((effect.better, effect.worse, effect.unchanged, effect.undecided, effect.level), (1, 1, 1, 2, 0));
    });

    test('a change the verified rows cannot tell apart keeps the same score', () {
      final effect = ModelEffect()..add(file(right, reading([got(1, -10).copyWith(doubtful: true), got(2, 20)]), against: expected));
      expect((effect.level, effect.better, effect.worse), (1, 0, 0));
    });
  });
}
