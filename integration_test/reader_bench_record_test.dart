// Records what the reader bench replays: for every bank file in a folder,
// the pages the platform's text recognition gives and what the on-device
// model answers, both of which only exist inside the real app. Run it
// through `tool/reader_bench/stage.sh`, which puts the files where the
// sandboxed app may read them and brings the recordings back.
//
// The app itself is never started: only the two platform services are
// called, through the same import flow the app uses, so nothing is added
// to the book. It prints counts only; the recordings hold the documents'
// text and stay under the files folder.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:qima/services/import/statement_files.dart';
import 'package:qima/services/platform_ai.dart';
import 'package:qima/services/text_recognition_service.dart';

import '../tool/reader_bench/src/recording.dart';

/// The folder of files; recordings go in its `.bench` folder. The sandbox
/// only lets the app read inside its own container.
const _files = String.fromEnvironment('QIMA_BENCH_FILES');
const _refresh = String.fromEnvironment('QIMA_BENCH_REFRESH');

/// The app language the files are read in.
const _language = String.fromEnvironment('QIMA_BENCH_LANG', defaultValue: 'en');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('record the reader bench', (tester) async {
    final folder = BenchFolder(Directory(_files.isEmpty ? '${Directory.systemTemp.path}/qima-reader-bench' : _files));
    expect(folder.files.existsSync(), isTrue, reason: 'The folder of files is missing or the sandbox hides it');
    const recognition = PlatformTextRecognition();
    expect(await recognition.isAvailable(), isTrue, reason: 'Text recognition is not available on this device');
    final summary = await recordFolder(
      folder,
      recognition: recognition,
      assist: platformAiAssist(),
      languages: StatementFiles.languagesFor(_language),
      refresh: _refresh == '1',
    );
    debugPrint('QIMA_BENCH_RECORD $summary');
    expect(summary.failed, 0);
  }, timeout: Timeout.none);
}
