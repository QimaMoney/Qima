import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qima/models/statement_facts.dart';
import 'package:qima/models/statement_reader.dart';
import 'package:qima/models/transaction_capture.dart';
import 'package:qima/services/ai_assist_provider.dart';
import 'package:qima/services/import/statement_files.dart';
import 'package:qima/services/text_recognition_service.dart';

import '../../../tool/reader_bench/src/recording.dart';
import '../../../tool/reader_bench/src/runner.dart';
import '../../../tool/reader_bench/src/scoring.dart';

// A made-up statement as the native reader gives it (the fixture the
// reader's own tests use), and made-up exports and messages.
List<DocPage> statementPages() => [
      for (final p in jsonDecode(File('test/fixtures/statements/text_layer_pdf.json').readAsStringSync()) as List)
        DocPage([for (final t in (p as Map)['tokens'] as List) DocToken.fromJson(t as Map)]),
    ];

const export = 'Date,Description,Debit,Credit,Balance\n'
    '01/11/2026,SALARY NOVEMBER,,5000.00,6000.00\n'
    '02/11/2026,CORNER GROCER,120.50,,5879.50\n';

const message = 'Purchase of SAR 120.00 at DUNE GYM on 03/11/2026';

/// Text recognition that reads every file as the made-up statement, or as
/// nothing when its name says so.
class FakeRecognition implements TextRecognitionService {
  int calls = 0;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<List<String>?> recognize(String imagePath, List<String> languageTags) async => null;

  @override
  Future<List<DocPage>?> readDocument(String path, List<String> languageTags) async {
    calls++;
    return path.contains('broken') ? null : statementPages();
  }
}

/// A model that calls the taxi line the bank's own text and shortens the
/// grocer's name, pointing only at words on the lines.
class FakeModel implements AiAssistProvider {
  final bool ready;
  int calls = 0;

  FakeModel({this.ready = true});

  @override
  Future<bool> isAvailable() async => ready;

  @override
  Future<ModelStatus> status(String localeTag) async => ready ? ModelStatus.ready : ModelStatus.turnedOff;

  @override
  Future<CaptureSpans?> labelTransaction(String text, String localeTag) async => null;

  @override
  Future<String?> phrase(String sentence, String localeTag) async => null;

  @override
  Future<List<PageStructure>?> structurePages(String path, List<DocPage> pages, String localeTag) async {
    calls++;
    return null;
  }

  @override
  Future<List<LineLabel>?> labelStatementLines(List<String> lines, String localeTag) async {
    calls++;
    return [
      for (var i = 0; i < lines.length; i++)
        if (lines[i].contains('UBER')) LineLabel(i, LineKind.other) else if (lines[i].contains('PANDA')) LineLabel(i, LineKind.transaction, 'PANDA RETAIL CO'),
    ];
  }

  @override
  Future<MessageLabels?> readMessage(String text, String localeTag) async {
    calls++;
    return const MessageLabels(intent: MessageIntent.purchase, amount: 'SAR 120.00', name: 'DUNE GYM');
  }
}

void main() {
  late Directory dir;
  late BenchFolder folder;
  const languages = ['en-US', 'ar-SA'];
  final at = DateTime(2026, 11, 20, 9);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('reader_bench_test');
    folder = BenchFolder(dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  void put(String rel, String content) {
    final f = File('${dir.path}/$rel')..parent.createSync(recursive: true);
    f.writeAsStringSync(content);
    // Older than any recording made in the test.
    f.setLastModifiedSync(DateTime(2026, 11, 10));
  }

  Future<BenchResult> bench({bool propose = false, bool compare = false, String? detail, double threshold = 1}) =>
      runBench(BenchOptions(files: dir.path, propose: propose, compare: compare, detail: detail, threshold: threshold, commit: 'abc1234', now: at));

  Map<String, dynamic> total(BenchResult r, String column) => jsonDecode(jsonEncode(r.report['total']))[column] as Map<String, dynamic>;

  group('recording', () {
    test('keeps the pages and the answers of each file, outside the files themselves', () async {
      put('Bank A/statement.pdf', 'not a real pdf');
      put('Bank A/export.csv', export);
      put('Bank B/message.txt', message);
      put('Bank B/notes.docx', 'not read by the app');
      put('.DS_Store', '');
      final summary = await recordFolder(folder, recognition: FakeRecognition(), assist: FakeModel(), languages: languages);
      expect(summary.files, 3);
      expect(summary.recorded, 2);
      expect(summary.notRecordable, 1);
      expect(summary.withModel, 2);
      expect(summary.failed, 0);

      final pages = PagesRecording.load(folder.pages('Bank A/statement.pdf'))!;
      expect(pages.languages, languages);
      expect(pages.pages!.single.tokens, statementPages().single.tokens);
      final model = ModelRecording.load(folder.model('Bank A/statement.pdf'))!;
      expect(model.available, isTrue);
      expect(model.status, 'ready');
      expect(model.lines!.asked, StatementReader(received: at).lineTexts(statementPages()));
      expect(model.lines!.answer, hasLength(2));
      expect(folder.pages('Bank A/export.csv').existsSync(), isFalse);
      expect(folder.pages('Bank B/message.txt').existsSync(), isFalse);
      expect(ModelRecording.load(folder.model('Bank B/message.txt'))!.available, isTrue);
    });

    test('skips what is recorded and newer than its file, unless refreshed', () async {
      put('Bank A/statement.pdf', 'not a real pdf');
      final recognition = FakeRecognition();
      await recordFolder(folder, recognition: recognition, assist: FakeModel(), languages: languages);
      expect(recognition.calls, 1);

      final again = await recordFolder(folder, recognition: recognition, assist: FakeModel(), languages: languages);
      expect((again.skipped, again.recorded), (1, 0));
      expect(recognition.calls, 1);

      final refreshed = await recordFolder(folder, recognition: recognition, assist: FakeModel(), languages: languages, refresh: true);
      expect((refreshed.skipped, refreshed.recorded), (0, 1));
      expect(recognition.calls, 2);

      // The file changed after it was recorded.
      File('${dir.path}/Bank A/statement.pdf').setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));
      await recordFolder(folder, recognition: recognition, assist: FakeModel(), languages: languages);
      expect(recognition.calls, 3);
    });

    test('says the model was unavailable instead of failing, and asks again once it is ready', () async {
      put('Bank A/statement.pdf', 'not a real pdf');
      final recognition = FakeRecognition();
      final off = FakeModel(ready: false);
      final summary = await recordFolder(folder, recognition: recognition, assist: off, languages: languages);
      expect((summary.recorded, summary.withModel, summary.failed), (1, 0, 0));
      expect(summary.modelStatus, 'turnedOff');
      expect(off.calls, 0);
      final recorded = ModelRecording.load(folder.model('Bank A/statement.pdf'))!;
      expect((recorded.available, recorded.status, recorded.lines), (false, 'turnedOff', null));

      // Still off: nothing to do. Ready: the model is asked, the pages kept.
      expect((await recordFolder(folder, recognition: recognition, assist: off, languages: languages)).skipped, 1);
      final on = await recordFolder(folder, recognition: recognition, assist: FakeModel(), languages: languages);
      expect((on.recorded, on.withModel), (1, 1));
      expect(recognition.calls, 1);
    });

    test('a file text recognition cannot read is recorded as unreadable', () async {
      put('Bank A/broken.png', 'not a real picture');
      final summary = await recordFolder(folder, recognition: FakeRecognition(), assist: FakeModel(ready: false), languages: languages);
      expect(summary.unreadable, 1);
      expect(PagesRecording.load(folder.pages('Bank A/broken.png'))!.pages, isNull);
      final r = await bench();
      expect(total(r, 'rules')['read'], {'n': 0, 'd': 1, 'percent': 0});
    });
  });

  group('replay through the import flow', () {
    test('rules alone, then with the recorded model answers', () async {
      put('Bank A/statement.pdf', 'not a real pdf');
      await recordFolder(folder, recognition: FakeRecognition(), assist: FakeModel(), languages: languages);
      final file = folder.importFile('Bank A/statement.pdf');
      final pages = PagesRecording.load(folder.pages('Bank A/statement.pdf'));

      final (rules, _) = await replay(file, pages: pages, languages: languages);
      expect(rules.outcome, ReadOutcome.read);
      expect(rules.rows.map((r) => r.amount), [18000.0, -642.10, -300.0, -38.75, 1000.0, -86.40]);
      expect(rules.rows.any((r) => r.doubtful), isFalse);
      expect(rules.rows[1].description, 'POS PANDA RETAIL CO RIYADH');
      expect((rules.facts.opening, rules.facts.closing), (22020.35, 39953.10));

      final (model, stale) = await replay(file, pages: pages, model: ModelRecording.load(folder.model('Bank A/statement.pdf')), languages: languages);
      expect(stale, isFalse);
      expect(model.rows.map((r) => r.amount), rules.rows.map((r) => r.amount));
      expect(model.rows.map((r) => r.doubtful), [false, false, false, true, false, false]);
      expect(model.rows[1].description, 'PANDA RETAIL CO');
    });

    test('answers about other lines are not used, and the recording is stale', () async {
      put('Bank A/statement.pdf', 'not a real pdf');
      await recordFolder(folder, recognition: FakeRecognition(), assist: FakeModel(), languages: languages);
      final recorded = ModelRecording.load(folder.model('Bank A/statement.pdf'))!;
      final moved = ModelRecording(
        available: true,
        status: 'ready',
        structure: recorded.structure,
        lines: ModelCall(asked: ['a line that is no longer there', ...recorded.lines!.asked as List], answer: recorded.lines!.answer),
      );
      final (read, stale) = await replay(folder.importFile('Bank A/statement.pdf'),
          pages: PagesRecording.load(folder.pages('Bank A/statement.pdf')), model: moved, languages: languages);
      expect(stale, isTrue);
      expect(read.rows.any((r) => r.doubtful), isFalse);
    });

    test('a model recorded as unavailable reads as the rules do', () async {
      put('Bank A/statement.pdf', 'not a real pdf');
      await recordFolder(folder, recognition: FakeRecognition(), assist: FakeModel(ready: false), languages: languages);
      final r = await bench();
      expect(total(r, 'rules')['files'], 1);
      expect(total(r, 'rulesPlusModel')['files'], 0);
    });

    test('a table and a message need no recording; a PDF does', () async {
      put('Bank A/statement.pdf', 'not a real pdf');
      put('Bank A/export.csv', export);
      put('Bank B/message.txt', message);
      final r = await bench();
      final t = total(r, 'rules');
      expect(t['files'], 2);
      expect(t['rows'], 3);
      expect((r.report['total'] as Map)['notRecorded'], 1);
      expect((r.report['byBank'] as Map).keys, ['Bank A', 'Bank B']);
      expect((r.report['byKind'] as Map).keys, ['table', 'pdf', 'message']);
    });
  });

  group('the bench run', () {
    Future<void> seed() async {
      put('Bank A/statement.pdf', 'not a real pdf');
      put('Bank A/export.csv', export);
      put('Bank B/message.txt', message);
      await recordFolder(folder, recognition: FakeRecognition(), assist: FakeModel(), languages: languages);
    }

    void verify(String rel, {void Function(Map<String, dynamic>)? change}) {
      final f = folder.expected(rel);
      final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      json['verified'] = true;
      change?.call(json);
      f.writeAsStringSync(jsonEncode(json));
    }

    test('propose writes unverified candidates and never overwrites one', () async {
      await seed();
      final first = await bench(propose: true);
      expect(first.exitCode, 0);
      for (final rel in ['Bank A/statement.pdf', 'Bank A/export.csv', 'Bank B/message.txt']) {
        expect(Expected.load(folder.expected(rel))!.verified, isFalse, reason: rel);
      }
      final proposed = Expected.load(folder.expected('Bank A/statement.pdf'))!;
      expect(proposed.rows, hasLength(6));
      // The made-up IBAN has no valid check digits, so the reader keeps no
      // account for it and none is proposed.
      expect((proposed.opening, proposed.closing, proposed.account), (22020.35, 39953.10, null));
      // Unverified files never count toward accuracy.
      expect(total(first, 'rules')['verifiedFiles'], 0);
      expect(total(first, 'rules')['recall'], {'n': 0, 'd': 0, 'percent': null});
      expect((first.report['total'] as Map)['unverifiedExpected'], 3);

      // A person corrected one; proposing again leaves it as it is.
      verify('Bank A/export.csv', change: (json) => (json['rows'] as List).removeLast());
      final corrected = folder.expected('Bank A/export.csv').readAsStringSync();
      folder.expected('Bank B/message.txt').deleteSync();
      await bench(propose: true);
      expect(folder.expected('Bank A/export.csv').readAsStringSync(), corrected);
      expect(Expected.load(folder.expected('Bank B/message.txt'))!.verified, isFalse);
    });

    test('scores verified files, groups them, and prints no document text', () async {
      await seed();
      await bench(propose: true);
      // The grocer's name as printed on the made-up statement's line.
      verify('Bank A/statement.pdf', change: (json) => ((json['rows'] as List)[1] as Map)['name'] = 'PANDA RETAIL CO');
      verify('Bank A/export.csv');
      final r = await bench();

      final rules = total(r, 'rules'), model = total(r, 'rulesPlusModel');
      expect(rules['files'], 3);
      expect(rules['verifiedFiles'], 2);
      expect(rules['expectedRows'], 8);
      expect(rules['recall'], {'n': 8, 'd': 8, 'percent': 100});
      expect(rules['precision'], {'n': 8, 'd': 8, 'percent': 100});
      expect(rules['nameExact'], {'n': 7, 'd': 8, 'percent': 87.5});
      expect(rules['nameContains'], {'n': 8, 'd': 8, 'percent': 100});
      expect(rules['addsUp']['n'], greaterThanOrEqualTo(1));
      expect((rules['opening']['n'], rules['closing']['n']), (1, 1));
      // No account was expected of either file, so none is scored.
      expect(rules['account']['d'], 0);
      // The model answered for the PDF and the message, not for the table.
      expect(model['files'], 2);
      expect(model['nameExact'], {'n': 6, 'd': 6, 'percent': 100});
      expect(model['doubtful']['n'], 1);
      expect((r.report['total'] as Map)['modelEffect'], containsPair('changedSameScore', 1));
      expect(((r.report['byKind'] as Map)['pdf'] as Map)['rules']['rows'], 6);
      expect(((r.report['byBank'] as Map)['Bank B'] as Map)['rules']['files'], 1);

      for (final private in ['PANDA', 'SALARY', 'GROCER', 'DUNE', '18000', '18,000', '642', '120.5', '7519']) {
        expect(r.output, isNot(contains(private)), reason: private);
      }
      expect(r.output, contains('rows found (recall)'));
      expect(r.output, contains('Bank Bank A'));
      expect(jsonDecode(folder.report.readAsStringSync())['commit'], 'abc1234');
    });

    test('every run adds a line to the history', () async {
      await seed();
      await bench();
      await bench();
      final lines = folder.history.readAsLinesSync();
      expect(lines, hasLength(2));
      final last = jsonDecode(lines.last) as Map<String, dynamic>;
      expect(last['commit'], 'abc1234');
      expect(last['total']['rules']['files'], 3);
    });

    test('compare fails only when a total got worse by more than the threshold', () async {
      await seed();
      await bench(propose: true);
      verify('Bank A/export.csv');
      final first = await bench(compare: true);
      expect(first.exitCode, 0);
      expect(first.output, contains('No total moved'));

      // The document turns out to hold a third row the reader misses:
      // rows found falls from 2 of 2 to 2 of 3.
      verify('Bank A/export.csv', change: (json) => (json['rows'] as List).add({'date': '2026-11-03', 'amount': -45.0, 'name': 'CITY TAXI'}));
      final lenient = await bench(compare: true, threshold: 50);
      expect(lenient.exitCode, 0);
      expect(lenient.output, contains('rows found (recall)'));

      // Back to all found, then down again under the usual threshold.
      verify('Bank A/export.csv', change: (json) => (json['rows'] as List).removeLast());
      final better = await bench(compare: true);
      expect(better.exitCode, 0);
      verify('Bank A/export.csv', change: (json) => (json['rows'] as List).add({'date': '2026-11-03', 'amount': -45.0, 'name': 'CITY TAXI'}));
      final worse = await bench(compare: true);
      expect(worse.exitCode, 1);
      expect(worse.output, contains('WORSE'));

      // Nothing moved since the worse run: it is the one compared with now.
      expect((await bench(compare: true)).exitCode, 0);
    });

    test('compare with no earlier run passes', () async {
      await seed();
      final r = await bench(compare: true);
      expect(r.exitCode, 0);
      expect(r.output, contains('no earlier run'));
    });

    test('detail writes the rows under the files folder and prints only where', () async {
      await seed();
      await bench(propose: true);
      verify('Bank A/statement.pdf', change: (json) => (json['rows'] as List).add({'date': '2026-11-06', 'amount': -9.0, 'name': 'KIOSK'}));
      final r = await bench(detail: 'Bank A/statement.pdf');
      expect(r.exitCode, 0);
      expect(r.output.trim(), 'Wrote ${folder.detail('Bank A/statement.pdf').path}');
      final detail = folder.detail('Bank A/statement.pdf').readAsStringSync();
      expect(detail, contains('MISSED'));
      expect(detail, contains('KIOSK'));
      expect(detail, contains('== rules + model'));
      expect((await bench(detail: 'Bank A/nothing.pdf')).exitCode, 64);
    });
  });
}
