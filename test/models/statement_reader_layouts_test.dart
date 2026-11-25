import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/statement_reader.dart';

// Layouts and wordings no rule names a bank for: every figure, name, card
// and reference here is made up.
List<DocToken> line(double y, List<(String, double, double)> cells, {double h = 0.02}) =>
    [for (final (t, x, w) in cells) DocToken(t, x, y, w, h)];

void main() {
  final reader = StatementReader(received: DateTime(2026, 11, 21, 18));

  group('a shared bank message', () {
    test('what is left is never the amount, whatever it is a balance of and wherever the currency sits', () {
      final row = reader.readMessages('شراء-POS\nبـSAR 41.00\nمن Lemon Mart\nإئتمانية **4471 (Apple Pay)\nفي 20/11/26 20:01\nالصرف المتبقي SAR 9510.39').single;
      expect(row.amount, -41);
      expect(row.currency, 'SAR');
      expect(row.description, 'Lemon Mart');
      expect(row.date, DateTime(2026, 11, 20));
      // The amount has no currency of its own; what is left has one.
      expect(reader.readMessages('Paid 75.50 at Paper House. Available limit is SAR 1,204.10').single.amount, -75.5);
    });

    test('a balance named right before its figure is what is left; a balance transfer is money moving', () {
      expect(reader.readMessages('Garden Cafe\nBalance SAR 640.00').isEmpty, isTrue);
      expect(reader.readMessages('Balance transfer of SAR 2,000.00 to your card').single.amount.abs(), 2000);
    });

    test('a statement notice that says what to pay and by when is not a payment', () {
      expect(
        reader.readMessages('كشف حساب شهر نوفمبر 2026 لبطاقتك الائتمانية المنتهية بـ 4471 هو 3447.67 جم ، الحد الأدنى للسداد قبل 05/12 هو 172.87 جم'),
        isEmpty,
      );
      // Paid, not to be paid.
      expect(reader.readMessages('تم سداد فاتورة بمبلغ 120.00 ريال. تاريخ الاستحقاق القادم 05/12').single.amount, -120);
    });

    test('a name ends at the line it is on and before the person\'s own card', () {
      expect(reader.readMessages('Purchase SAR 12.00\nfrom Dune Club\ncard **4471\non 20/11/26').single.description, 'Dune Club');
      expect(reader.readMessages('Purchase of SAR 12.00 from Dune Club card **4471 on 20/11/26').single.description, 'Dune Club card');
    });

    test('a currency written straight after an Arabic word is still the amount\'s', () {
      final row = reader.readMessages('حوالة صادرة محلية بSAR 60.25\n19/11/26 15:03').single;
      expect(row.amount, -60.25);
      expect(row.currency, 'SAR');
    });
  });

  group('a picture of a banking app', () {
    test('a record stacked on lines of its own: name, date, amount, then the balance after it', () {
      final page = DocPage([
        ...line(0.10, [('REF11AA22 - Card purchase', 0.07, 0.5)]),
        ...line(0.12, [('>', 0.9, 0.02)]),
        ...line(0.13, [('18/11/26', 0.07, 0.1)], h: 0.012),
        ...line(0.155, [('-125.00 EGP', 0.07, 0.2)]),
        ...line(0.20, [('100000000001', 0.07, 0.2), ('18/11/26', 0.83, 0.1)], h: 0.012),
        ...line(0.225, [('Balance after the transaction', 0.07, 0.35), ('1,329.49 EGP', 0.75, 0.18)], h: 0.012),
        ...line(0.33, [('REF33BB44 - Payee name', 0.07, 0.5)]),
        ...line(0.36, [('16/11/26', 0.07, 0.1)], h: 0.012),
        ...line(0.385, [('-51.00 EGP', 0.07, 0.2)]),
        ...line(0.43, [('100000000001', 0.07, 0.2), ('16/11/26', 0.83, 0.1)], h: 0.012),
        ...line(0.455, [('Balance after the transaction', 0.07, 0.35), ('1,454.49 EGP', 0.75, 0.18)], h: 0.012),
      ]);
      final rows = reader.readPages([page]);
      expect(rows.map((r) => r.amount), [-125, -51]);
      expect(rows.map((r) => r.description), ['REF11AA22 - Card purchase', 'REF33BB44 - Payee name']);
      expect(rows.map((r) => r.date), [DateTime(2026, 11, 18), DateTime(2026, 11, 16)]);
      expect(rows.map((r) => r.balance), [1329.49, 1454.49]);
    });

    test('a figure under its label of what is left, and a balance under a row, are no transactions', () {
      final account = DocPage([
        ...line(0.10, [('Available Balance', 0.07, 0.3)], h: 0.012),
        ...line(0.13, [('3,826.73 EGP', 0.07, 0.3)]),
      ]);
      expect(reader.readPages([account]), isEmpty);
      final list = DocPage([
        ...line(0.10, [('Oct 31, 2026', 0.1, 0.2)], h: 0.012),
        ...line(0.14, [('Cloud One', 0.2, 0.2), ('87.71', 0.8, 0.1)]),
        ...line(0.165, [('Online purchase', 0.2, 0.3), ('Balance 147.73', 0.7, 0.2)], h: 0.012),
        ...line(0.22, [('Oct 01, 2026', 0.1, 0.2)], h: 0.012),
        ...line(0.26, [('Top up balance', 0.2, 0.3), ('50.00', 0.8, 0.1)]),
      ]);
      final rows = reader.readPages([list]);
      expect(rows.map((r) => r.amount.abs()), [87.71, 50]);
      expect(rows.first.balance, 147.73);
      expect(rows.last.description, 'Top up balance');
    });

    test('a sign read after the figure, and a credit marker read as a piece of its own', () {
      final page = DocPage([
        ...line(0.10, [('18 NOVEMBER', 0.07, 0.2)], h: 0.012),
        ...line(0.14, [('Incoming', 0.2, 0.2), ('33.00+#', 0.8, 0.12)]),
        ...line(0.20, [('Corner Shop', 0.2, 0.3), ('33.00-#', 0.8, 0.12)]),
      ]);
      expect(reader.readPages([page]).map((r) => r.amount), [33, -33]);
      final card = DocPage([
        ...line(0.10, [('05-01', 0.05, 0.05), ('06-01', 0.25, 0.05), ('Payment - Direct Debit', 0.4, 0.2), ('1335.16', 0.8, 0.07), ('CR', 0.9, 0.03)]),
        ...line(0.13, [('06-01', 0.05, 0.05), ('07-01', 0.25, 0.05), ('BOOK HOUSE', 0.4, 0.2), ('269.99', 0.8, 0.07)]),
        ...line(0.16, [('07-01', 0.05, 0.05), ('08-01', 0.25, 0.05), ('Refund BOOK HOUSE', 0.4, 0.2), ('20.00', 0.8, 0.07), ('CR', 0.9, 0.03)]),
        ...line(0.19, [('08-01', 0.05, 0.05), ('09-01', 0.25, 0.05), ('TEA ROOM', 0.4, 0.2), ('45.00', 0.8, 0.07)]),
      ]);
      expect(reader.readPages([card]).map((r) => r.amount), [1335.16, -269.99, 20, -45]);
    });

    test('a screen that lists what is held, not what happened, leaves nothing ticked', () {
      final page = DocPage([
        ...line(0.10, [('Total Value', 0.07, 0.2)]),
        ...line(0.13, [('76,000.00 EGP', 0.07, 0.3)]),
        ...line(0.30, [('MM0000000001', 0.2, 0.3)]),
        ...line(0.33, [('70,000.00 EGP', 0.2, 0.3)]),
        ...line(0.355, [('Annual Interest rate: 18.75%', 0.2, 0.4)], h: 0.012),
        ...line(0.375, [('Maturity date: 04/08/2028', 0.2, 0.4)], h: 0.012),
      ]);
      final (rows, _) = reader.read([page]);
      expect(rows.where((r) => !r.doubtful), isEmpty);
      // The rate is not money.
      expect(rows.any((r) => r.amount.abs() == 18.75), isFalse);
    });
  });

  group('a picture of bank messages', () {
    test('a message written as a few short lines is one message, its label read back before its figure', () {
      final page = DocPage([
        ...line(0.10, [('POS-شراء', 0.4, 0.2)]),
        ...line(0.125, [('SAR 41.00', 0.4, 0.2)]),
        ...line(0.15, [('Lemon Mart من', 0.3, 0.3)]),
        ...line(0.175, [('(Apple Pay) 4471** إئتمانية', 0.2, 0.4)]),
        ...line(0.20, [('في 20:01 20/11/26', 0.3, 0.3)]),
        ...line(0.225, [('9510.39 الصرف المتبقي', 0.2, 0.4)]),
        // A one-time code that quotes the amount it is for.
        ...line(0.30, [('لا تشارك رمز التفعيل 8757', 0.3, 0.4)]),
        ...line(0.325, [('تحويل لبنك محلي', 0.4, 0.3)]),
        ...line(0.35, [('SAR', 0.5, 0.06), ('120 مبلغ', 0.57, 0.13)]),
      ]);
      final row = reader.readPages([page]).single;
      expect(row.amount, -41);
      expect(row.description, 'Lemon Mart');
      expect(row.date, DateTime(2026, 11, 20));
    });

    test('a sentence cut into pieces where its script changes is still one message', () {
      final page = DocPage([
        ...line(0.10, [('كشف حساب شهر نوفمبر 2026 لبطاقتك', 0.09, 0.62)]),
        ...line(0.125, [('4471 هو 3447.67', 0.10, 0.32), ('الائتمانية المنتهية', 0.45, 0.26)]),
        ...line(0.15, [('الحد الأدنى للسداد قبل 05/12 هو', 0.11, 0.52), ('جم', 0.65, 0.06)]),
        ...line(0.175, [('172.87 جم .يمكنك الاطلاع على تفاصيل', 0.10, 0.61)]),
        ...line(0.20, [('كشف الحساب من خلال الرابط التالي:', 0.15, 0.55)]),
      ]);
      expect(reader.readPages([page]), isEmpty);
    });
  });

  group('a picture of a thread of messages', () {
    // The share day, 21 November 2026, is a Saturday.
    test('the line between two days names the day of the messages under it', () {
      final page = DocPage([
        ...line(0.10, [('Monday 1:12 PM', 0.39, 0.22)], h: 0.013),
        ...line(0.14, [('Please note that an amount of', 0.09, 0.6)]),
        ...line(0.165, [('EGP 310.00 was debited from your', 0.09, 0.6)]),
        ...line(0.19, [('account ending 4471 to Lemon Mart', 0.09, 0.6)]),
        ...line(0.215, [('with reference AB12CD on 13:1', 0.09, 0.6)]),
        ...line(0.30, [('Saturday', 0.44, 0.12), ('9:05', 0.57, 0.05), ('AM', 0.63, 0.04)], h: 0.013),
        ...line(0.34, [('Your card ending 4471 was charged', 0.09, 0.6)]),
        ...line(0.365, [('for EGP 75.50 at Paper House. Your', 0.09, 0.6)]),
        ...line(0.39, [('available limit is 1,204.10', 0.09, 0.5)]),
      ]);
      final rows = reader.readPages([page]);
      expect(rows.map((r) => r.amount), [-310, -75.5]);
      // The Monday before the share day; today's own name is last week's.
      expect(rows.map((r) => r.date), [DateTime(2026, 11, 16), DateTime(2026, 11, 14)]);
      expect(rows.any((r) => r.dateGuessed), isFalse);
      // The day's name is the heading, not part of a name.
      expect(rows.any((r) => r.description.contains('Monday') || r.detail.contains('Monday')), isFalse);
    });

    test('a day named in a sentence, or with no time beside it, heads nothing', () {
      for (final above in ['Branches are closed on Friday', 'Friday']) {
        final page = DocPage([
          ...line(0.10, [(above, 0.09, 0.6)]),
          ...line(0.20, [('Garden Cafe', 0.07, 0.3), ('-45.00 SAR', 0.75, 0.18)]),
        ]);
        expect(reader.readPages([page]).single.dateGuessed, isTrue, reason: above);
      }
    });

    test('a bubble is one message even when a piece of its line was lost and the figure sits apart', () {
      final page = DocPage([
        // Right to left: the figure comes out far from its words, the
        // currency between them lost.
        ...line(0.10, [('75.25', 0.20, 0.08), ('حوالة صادرة محلية', 0.43, 0.29)]),
        ...line(0.125, [('N. OMAR 2002*K', 0.33, 0.39)]),
        ...line(0.15, [('17/11/26 11:40', 0.08, 0.25)]),
        ...line(0.21, [('Tuesday 3:10 PM', 0.39, 0.22)], h: 0.013),
        ...line(0.25, [('POS-شراء', 0.4, 0.17)]),
        ...line(0.275, [('SAR 52.00-', 0.36, 0.21)]),
        ...line(0.30, [('Dune Club من', 0.3, 0.27)]),
        ...line(0.325, [('في 14:05 17/11/26', 0.27, 0.3)]),
        ...line(0.35, [('2718.60', 0.07, 0.08), ('الصرف المتبقي', 0.34, 0.23)]),
      ]);
      final rows = reader.readPages([page]);
      expect(rows.map((r) => r.amount), [-75.25, -52]);
      expect(rows.any((r) => r.signGuessed || r.dateGuessed), isFalse);
      expect(rows.map((r) => r.date).toSet(), {DateTime(2026, 11, 17)});
      expect(rows.last.description, 'Dune Club');
    });

    test('the same lines with no line between days stay a list: the figure set apart is a column', () {
      final page = DocPage([
        ...line(0.10, [('75.25', 0.20, 0.08), ('حوالة محلية', 0.43, 0.29)]),
        ...line(0.125, [('N. OMAR 2002*K', 0.33, 0.39)]),
        ...line(0.15, [('17/11/26 11:40', 0.08, 0.25)]),
      ]);
      final row = reader.readPages([page]).single;
      expect(row.amount.abs(), 75.25);
      expect(row.signGuessed, isTrue);
    });

    test('the bubble cut off by the top of the screen does not spoil the first whole one', () {
      final page = DocPage([
        ...line(0.075, [('<', 0.07, 0.03), ('16.40 15/11', 0.24, 0.19)]),
        ...line(0.098, [('المتبقي 302.15', 0.18, 0.24)]),
        ...line(0.13, [('Bank Name ›', 0.39, 0.23)]),
        ...line(0.157, [('POS-شراء', 0.4, 0.16)]),
        ...line(0.18, [('SAR 37.00-', 0.36, 0.2)]),
        ...line(0.205, [('Lemon Mart من', 0.3, 0.27)]),
        ...line(0.23, [('في 10:20 18/11/26', 0.25, 0.31)]),
        ...line(0.255, [('9510.39', 0.07, 0.08), ('الصرف المتبقي', 0.34, 0.23)]),
        ...line(0.32, [('Yesterday 8:40 PM', 0.38, 0.24)], h: 0.013),
        ...line(0.36, [('POS-شراء', 0.4, 0.16)]),
        ...line(0.385, [('SAR 24.75-', 0.36, 0.2)]),
        ...line(0.41, [('Garden Cafe من', 0.3, 0.27)]),
        ...line(0.435, [('في 20:39 20/11/26', 0.25, 0.31)]),
      ]);
      final rows = reader.readPages([page]);
      final whole = rows.where((r) => r.amount == -37).single;
      expect(whole.date, DateTime(2026, 11, 18));
      expect(whole.dateGuessed, isFalse);
      expect(whole.signGuessed, isFalse);
      expect(whole.description, 'Lemon Mart');
      expect(rows.last.amount, -24.75);
      expect(rows.last.date, DateTime(2026, 11, 20));
      // What is left of the cut-off one never claims a direction.
      expect(rows.where((r) => r.amount.abs() == 16.4).every((r) => r.signGuessed), isTrue);
    });

    test('the end of a date whose day was misread is no date of its own', () {
      // "on 13/09/26" with its day read as letters leaves "09/26".
      final page = DocPage([
        ...line(0.08, [('212.40', 0.21, 0.13), ('at', 0.34, 0.04), ('PAPER HOUSE', 0.4, 0.3)]),
        ...line(0.105, [('olz/09/26 at 07:12 the limit left', 0.08, 0.6)]),
        ...line(0.13, [('to use is 1,480.25 and the limit', 0.08, 0.6)]),
        ...line(0.155, [('abroad is EGP 6200', 0.08, 0.5)]),
      ]);
      final row = reader.readPages([page]).single;
      expect(row.amount.abs(), 212.4);
      expect(row.dateGuessed, isTrue);
      // Two dates joined by a dash are still two dates.
      final range = DocPage([...line(0.1, [('01/11-15/11', 0.05, 0.2), ('Garden Cafe', 0.3, 0.3), ('-45.00 SAR', 0.75, 0.18)])]);
      expect(reader.readPages([range]).single.dateGuessed, isFalse);
    });
  });

  group('a picture of an account or card screen', () {
    test('a balance under a bare label is the newest row\'s running balance, and a row\'s second line says its direction', () {
      final page = DocPage([
        ...line(0.25, [('Balance', 0.08, 0.1)], h: 0.012),
        ...line(0.275, [('412.30 SAR', 0.08, 0.25)], h: 0.03),
        ...line(0.67, [('Spending history', 0.07, 0.28)]),
        ...line(0.715, [('Oct 27, 2026', 0.1, 0.16)]),
        ...line(0.75, [('Cloud Storage', 0.16, 0.22), ('64.20 SAR', 0.8, 0.13)]),
        ...line(0.77, [('Online purchase', 0.19, 0.3), ('Balance SAR 412.30', 0.7, 0.23)], h: 0.014),
        ...line(0.807, [('Oct 04, 2026', 0.1, 0.16)]),
        ...line(0.84, [('TEXT SERVICE RE', 0.17, 0.42), ('2.75 SAR', 0.83, 0.1)]),
        // The app prints the same balance under two rows: no link there.
        ...line(0.86, [('Online purchase', 0.19, 0.3), ('Balance SAR 500.00', 0.7, 0.23)], h: 0.014),
        ...line(0.897, [('Sep 28, 2026', 0.1, 0.17)]),
        ...line(0.93, [('Music Plan', 0.17, 0.28), ('22.00 SAR', 0.82, 0.11)]),
        ...line(0.95, [('Online purchase', 0.19, 0.3), ('Balance SAR 500.00', 0.7, 0.23)], h: 0.014),
      ]);
      final (rows, facts) = reader.read([page]);
      expect(rows.map((r) => r.amount), [-64.2, -2.75, -22]);
      expect(rows.any((r) => r.signGuessed || r.dateGuessed || r.doubtful), isFalse);
      expect(rows.map((r) => r.detail).toSet(), {'Online purchase'});
      expect(facts.closing, 412.3);
    });

    test('words in the label\'s own piece of the line are the label\'s, not the row\'s', () {
      final page = DocPage([
        ...line(0.10, [('Lemon Mart', 0.07, 0.3), ('120.00 SAR', 0.8, 0.15)]),
        ...line(0.125, [('Purchase limit remaining SAR 900.00', 0.07, 0.5)], h: 0.014),
        ...line(0.15, [('19/11/2026', 0.07, 0.18)], h: 0.013),
      ]);
      final row = reader.readPages([page]).single;
      expect(row.balance, 900);
      expect(row.detail, isEmpty);
      expect(row.signGuessed, isTrue);
    });

    test('miles and points earned are a count, not money', () {
      final page = DocPage([
        ...line(0.37, [('18,240', 0.16, 0.09), ('TRAVEL MILES EARNED', 0.25, 0.33)]),
        ...line(0.66, [('AVAILABLE LIMIT', 0.1, 0.26)]),
        ...line(0.69, [('SAR 6,407.15', 0.1, 0.26)], h: 0.028),
      ]);
      expect(reader.read([page]).$1, isEmpty);
      // A shop called after them, with a price, is a row.
      final shop = DocPage([
        ...line(0.10, [('Miles Cafe', 0.07, 0.3), ('25.00 SAR', 0.8, 0.13)]),
        ...line(0.125, [('19/11/2026', 0.07, 0.18)], h: 0.013),
      ]);
      expect(reader.readPages([shop]).single.amount.abs(), 25);
    });

    test('a list with no sign, no word and no balance leaves every direction a guess', () {
      final page = DocPage([
        ...line(0.08, [('My Cards', 0.14, 0.16)]),
        for (var i = 0; i < 4; i++) ...[
          ...line(0.14 + i * 0.08, [('SHOP NUMBER $i~~CITY~', 0.035, 0.6), ('${30 + i}.80 SAR', 0.8, 0.17)]),
          ...line(0.163 + i * 0.08, [('${10 + i}/11/2026', 0.035, 0.18)], h: 0.013),
        ],
      ]);
      final rows = reader.readPages([page]);
      expect(rows.length, 4);
      expect(rows.every((r) => r.signGuessed && !r.dateGuessed), isTrue);
    });

    test('a row\'s own name says its direction only when it says it outright', () {
      StatementRow named(String name) => reader.readPages([
            DocPage([
              ...line(0.10, [(name, 0.07, 0.5), ('120.00 SAR', 0.8, 0.15)]),
              ...line(0.125, [('19/11/2026', 0.07, 0.18)], h: 0.013),
            ]),
          ]).single;
      for (final out in ['Online purchase', 'POS Lemon Mart', 'Cash withdrawal', 'حوالة صادرة محلية', 'شراء عبر الإنترنت', 'Achat en ligne', 'Retrait', 'Compra en tienda']) {
        expect(named(out).amount, -120, reason: out);
        expect(named(out).signGuessed, isFalse, reason: out);
      }
      for (final back in ['Refund Lemon Mart', 'Purchase refund', 'POS reversal', 'POS PURCHASE REV', 'Incoming transfer', 'حوالة واردة', 'استرداد مبلغ', 'Remboursement', 'Reembolso']) {
        expect(named(back).amount, 120, reason: back);
        expect(named(back).signGuessed, isFalse, reason: back);
      }
      // Said both ways, or not said: the person is asked.
      for (final unclear in [
        'Lemon Mart',
        'Transfer',
        'Card payment',
        'Purchase return',
        'Purchase cancelled',
        'ATM cash deposit withdrawal',
        'Payment reversal',
        'Refund reversal',
        'Incoming transfer fee',
        'تحويل',
        'سداد بطاقة',
      ]) {
        expect(named(unclear).signGuessed, isTrue, reason: unclear);
      }
    });

    test('a date with a small word beside it closes the row above; a date under its own label does not', () {
      final closed = DocPage([
        ...line(0.10, [('Garden Cafe', 0.3, 0.3)]),
        ...line(0.125, [('SAR 33.00', 0.33, 0.21)]),
        ...line(0.15, [('(Tap to pay) 4471**', 0.2, 0.4)]),
        // Read twice, the second time with a stray letter.
        ...line(0.175, [('في 14:05 18/11/26', 0.23, 0.31), ('18/11/26 Li', 0.34, 0.2)]),
      ]);
      final row = reader.readPages([closed]).single;
      expect(row.date, DateTime(2026, 11, 18));
      expect(row.dateGuessed, isFalse);
      final held = DocPage([
        ...line(0.50, [('CD00112233', 0.16, 0.26)]),
        ...line(0.535, [('12,500.00 EGP', 0.16, 0.25)]),
        ...line(0.56, [('Maturity date: 09/03/2026', 0.16, 0.33)], h: 0.015),
      ]);
      expect(reader.readPages([held]).single.dateGuessed, isTrue);
    });
  });

  group('a statement', () {
    test('a row dated after the day it was received is a due date, kept unticked', () {
      final page = DocPage([
        ...line(0.10, [('02/12/2026', 0.05, 0.1), ('Balance to settle', 0.3, 0.3), ('1,857.44', 0.8, 0.1)]),
        ...line(0.13, [('16/11/2026', 0.05, 0.1), ('Garden Cafe', 0.3, 0.3), ('-45.00', 0.8, 0.1)]),
      ]);
      final (rows, _) = reader.read([page]);
      expect(rows.map((r) => r.doubtful), [true, false]);
    });

    test('where rows begin with their date, a figure dated only by the sentence around it is the bank\'s own text', () {
      final page = DocPage([
        for (var i = 0; i < 6; i++)
          ...line(0.10 + i * 0.03, [('${10 + i}-OCT-26', 0.05, 0.1), ('${11 + i}-OCT-26', 0.17, 0.1), ('SHOP NUMBER $i', 0.3, 0.3), ('${20 + i}.50', 0.8, 0.1)]),
        ...line(0.40, [('Statement (B) is issued on October 10 showing a carried amount of SAR 4,632.75 to settle.', 0.05, 0.9)]),
      ]);
      final (rows, _) = reader.read([page]);
      expect(rows.where((r) => !r.doubtful).map((r) => r.amount.abs()), [20.5, 21.5, 22.5, 23.5, 24.5, 25.5]);
    });

    test('an Arabic date read right to left is the day written beside it in Latin letters', () {
      final page = DocPage([
        ...line(0.10, [('26-أكتوبر-23', 0.05, 0.1), ('23-OCT-26', 0.17, 0.1), ('LOCAL SHOP', 0.4, 0.3), ('165.00', 0.8, 0.1)]),
        ...line(0.13, [('26-أكتوبر-25', 0.05, 0.1), ('25-OCT-26', 0.17, 0.1), ('LOCAL CAFE', 0.4, 0.3), ('16.00', 0.8, 0.1)]),
      ]);
      expect(reader.readPages([page]).map((r) => r.date), [DateTime(2026, 10, 23), DateTime(2026, 10, 25)]);
    });
  });
}
