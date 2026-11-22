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
