// The reader bench: how well the app reads bank statements, screenshots
// and messages, in numbers, so a change to the reader is judged by them.
//
// Run it through `tool/reader_bench/bench.sh` (usage is in that file). It
// runs under `flutter test` and not `dart run` because the import flow it
// replays (`StatementFiles`) imports Flutter's services library, which
// only loads in the Flutter test runner. It needs no plugin: pages and
// model answers come from recordings (`stage.sh` makes them).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'src/recording.dart';
import 'src/runner.dart';

void main() {
  test('reader bench', () async {
    final env = Platform.environment;
    final files = env['QIMA_BENCH_FILES'] ?? '';
    // Without a folder this is not a bench run (someone ran every test
    // file there is); there is nothing to do.
    if (files.isEmpty) return;
    final detail = env['QIMA_BENCH_DETAIL'] ?? '';
    final result = await runBench(BenchOptions(
      files: files,
      propose: env['QIMA_BENCH_PROPOSE'] == '1',
      compare: env['QIMA_BENCH_COMPARE'] == '1',
      detail: detail.isEmpty ? null : detail,
      threshold: double.tryParse(env['QIMA_BENCH_THRESHOLD'] ?? '') ?? 1,
      language: env['QIMA_BENCH_LANG'] ?? 'en',
      commit: currentCommit(),
    ));
    // The test runner wraps what a test prints, so the summary and the
    // exit code are handed to bench.sh through files.
    final folder = BenchFolder(Directory(files));
    if (folder.root.existsSync()) {
      folder.summary.writeAsStringSync(result.output);
      File('${folder.root.path}/.exit').writeAsStringSync('${result.exitCode}');
    } else {
      stdout.write(result.output);
    }
  }, timeout: Timeout.none);
}
