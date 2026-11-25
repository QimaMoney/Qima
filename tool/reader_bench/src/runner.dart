// Runs the reader bench over a folder of files: replays each recording
// through the app's import flow, scores it, and writes the report. What it
// prints holds counts and percentages only; anything that could quote a
// document goes under `<files folder>/.bench/`.
import 'dart:convert';
import 'dart:io';

import 'package:qima/services/import/statement_files.dart';

import 'recording.dart';
import 'scoring.dart';

class BenchOptions {
  /// The folder of files to read; its top-level folders are the banks.
  final String files;

  /// Write an unverified expected file for every file that has none.
  final bool propose;

  /// Compare with the run before and fail when a total got worse.
  final bool compare;

  /// A file (by its path under [files]) to write a row by row diff for.
  final String? detail;

  /// How many percentage points a total may drop before [compare] fails.
  final double threshold;

  /// The app language the files are read in.
  final String language;

  /// Stamped on the run; the tests pin them.
  final String commit;
  final DateTime now;

  BenchOptions({
    required this.files,
    this.propose = false,
    this.compare = false,
    this.detail,
    this.threshold = 1,
    this.language = 'en',
    this.commit = '',
    DateTime? now,
  }) : now = now ?? DateTime.now();
}

class BenchResult {
  final int exitCode;

  /// What to print: counts and percentages only.
  final String output;
  final Map<String, Object?> report;

  const BenchResult(this.exitCode, this.output, this.report);
}

/// One file, read both ways.
class FileResult {
  final String rel, bank, kind;

  /// A PDF or picture nobody recorded yet can't be read here.
  final bool recorded;
  final StatementRead? rules;

  /// Null when there are no model answers for the file.
  final StatementRead? model;
  final bool stale;
  final Expected? expected;

  const FileResult({required this.rel, required this.bank, required this.kind, this.recorded = true, this.rules, this.model, this.stale = false, this.expected});

  bool get verified => expected?.verified ?? false;
  bool get hasModel => model != null;
  bool get modelChanged => model != null && (model!.outcome != rules!.outcome || !_same(model!, rules!));

  static bool _same(StatementRead a, StatementRead b) {
    if (a.facts != b.facts || a.rows.length != b.rows.length) return false;
    for (var i = 0; i < a.rows.length; i++) {
      if (a.rows[i] != b.rows[i]) return false;
    }
    return true;
  }
}

/// How the model moved the readings of the files it answered for.
class ModelEffect {
  int unchanged = 0, better = 0, worse = 0, level = 0, undecided = 0;

  void add(FileResult f) {
    if (!f.hasModel) return;
    if (!f.modelChanged) {
      unchanged++;
    } else if (!f.verified) {
      // Without verified rows a different reading is only different.
      undecided++;
    } else {
      final before = score(f.rules!, f.expected).mistakes, after = score(f.model!, f.expected).mistakes;
      if (after < before) {
        better++;
      } else if (after > before) {
        worse++;
      } else {
        level++;
      }
    }
  }

  Map<String, Object?> toJson() => {'unchanged': unchanged, 'better': better, 'worse': worse, 'changedSameScore': level, 'changedNotDecidable': undecided};
}

/// The numbers of one group of files: the rules over all of them, and the
/// rules against the rules with the model over the files the model
/// answered for, so the two columns count the same documents.
class GroupScore {
  final String name;
  final Tally rules = Tally(), rulesWhereModel = Tally(), model = Tally();
  final ModelEffect effect = ModelEffect();
  int notRecorded = 0, stale = 0, unverified = 0;

  GroupScore(this.name);

  void add(FileResult f) {
    if (!f.recorded) {
      notRecorded++;
      return;
    }
    if (f.expected != null && !f.verified) unverified++;
    rules.add(score(f.rules!, f.expected));
    if (f.stale) stale++;
    if (f.hasModel) {
      rulesWhereModel.add(score(f.rules!, f.expected));
      model.add(score(f.model!, f.expected));
      effect.add(f);
    }
  }

  Map<String, Object?> toJson() => {
        'notRecorded': notRecorded,
        'staleModelAnswers': stale,
        'unverifiedExpected': unverified,
        'rules': rules.toJson(),
        'rulesOnModelFiles': rulesWhereModel.toJson(),
        'rulesPlusModel': model.toJson(),
        'modelEffect': effect.toJson(),
      };
}

/// Reads every file under the folder both ways. Files the app doesn't read
/// are left out.
Future<List<FileResult>> readAll(BenchFolder folder, {required String language}) async {
  final languages = StatementFiles.languagesFor(language);
  final out = <FileResult>[];
  for (final rel in folder.list()) {
    final kind = kindOf(extensionOf(rel));
    if (kind == null) continue;
    final bank = rel.contains('/') ? rel.split('/').first : '(no folder)';
    final needsPages = kind == 'pdf' || kind == 'picture';
    final pages = needsPages ? PagesRecording.load(folder.pages(rel)) : null;
    if (needsPages && pages == null) {
      out.add(FileResult(rel: rel, bank: bank, kind: kind, recorded: false));
      continue;
    }
    final file = folder.importFile(rel);
    final (rules, _) = await replay(file, pages: pages, languages: languages);
    // A table is read by its columns; the app never asks the model.
    final answers = kind == 'table' ? null : ModelRecording.load(folder.model(rel));
    StatementRead? withModel;
    var stale = false;
    if (answers != null && answers.available) {
      (withModel, stale) = await replay(file, pages: pages, model: answers, languages: languages);
    }
    out.add(FileResult(rel: rel, bank: bank, kind: kind, rules: rules, model: withModel, stale: stale, expected: Expected.load(folder.expected(rel))));
  }
  return out;
}

String _git(List<String> args) {
  try {
    final r = Process.runSync('git', args);
    return r.exitCode == 0 ? (r.stdout as String).trim() : '';
  } catch (_) {
    return '';
  }
}

/// The commit the working tree is at, with a mark when it has changes.
String currentCommit() {
  final head = _git(['rev-parse', '--short', 'HEAD']);
  if (head.isEmpty) return '';
  return _git(['status', '--porcelain', '--untracked-files=no']).isEmpty ? head : '$head+changes';
}

Future<BenchResult> runBench(BenchOptions options) async {
  final folder = BenchFolder(Directory(options.files));
  if (!folder.files.existsSync()) return const BenchResult(64, 'No such folder of files.\n', {});
  folder.root.createSync(recursive: true);
  final files = await readAll(folder, language: options.language);
  final out = StringBuffer();

  if (options.propose) {
    var written = 0, kept = 0, unread = 0;
    for (final f in files) {
      if (!f.recorded) {
        unread++;
      } else if (propose(folder.expected(f.rel), f.rules!)) {
        written++;
      } else {
        kept++;
      }
    }
    out.writeln('Proposed expected rows for $written files (unverified); left $kept existing files alone; $unread not recorded yet.');
    out.writeln('Correct each file under .bench/expected/ and set "verified": true for it to count.');
    // Read them back so this run's report shows them as waiting.
    return _report(folder, await readAll(folder, language: options.language), options, out);
  }

  if (options.detail != null) {
    final f = files.where((f) => f.rel == options.detail).firstOrNull;
    if (f == null || !f.recorded) return const BenchResult(64, 'No reading for that file: check its path under the files folder, and that it is recorded.\n', {});
    final target = folder.detail(f.rel);
    target.parent.createSync(recursive: true);
    target.writeAsStringSync(_detail(f));
    return BenchResult(0, 'Wrote ${target.path}\n', const {});
  }

  return _report(folder, files, options, out);
}

BenchResult _report(BenchFolder folder, List<FileResult> files, BenchOptions options, StringBuffer out) {
  final total = GroupScore('TOTAL');
  final banks = <String, GroupScore>{}, kinds = <String, GroupScore>{};
  for (final f in files) {
    total.add(f);
    banks.putIfAbsent(f.bank, () => GroupScore(f.bank)).add(f);
    kinds.putIfAbsent(f.kind, () => GroupScore(f.kind)).add(f);
  }
  final report = <String, Object?>{
    'date': options.now.toUtc().toIso8601String(),
    'commit': options.commit,
    'language': options.language,
    'files': files.length,
    'total': total.toJson(),
    'byBank': {for (final g in banks.values) g.name: g.toJson()},
    'byKind': {for (final g in kinds.values) g.name: g.toJson()},
  };

  out.writeln('Reader bench, ${options.now.toIso8601String().substring(0, 16).replaceFirst('T', ' ')}, commit ${options.commit.isEmpty ? 'unknown' : options.commit}');
  out.writeln('Files ${files.length}: ${[for (final g in kinds.values) '${g.name} ${g.rules.files + g.notRecorded}'].join(', ')}');
  out.writeln();
  _table(out, total);
  for (final g in banks.values) {
    _table(out, g, title: 'Bank ${g.name}');
  }
  for (final g in kinds.values) {
    _table(out, g, title: 'Kind ${g.name}');
  }

  var exitCode = 0;
  if (options.compare) {
    final previous = _lastRun(folder.history);
    if (previous == null) {
      out.writeln('Compare: no earlier run to compare with.');
    } else {
      final worse = _compare(out, previous, report, options.threshold);
      if (worse > 0) exitCode = 1;
    }
  }

  folder.report.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(report)}\n');
  folder.history.writeAsStringSync('${jsonEncode({'date': report['date'], 'commit': report['commit'], 'files': files.length, 'total': report['total']})}\n', mode: FileMode.append);
  return BenchResult(exitCode, out.toString(), report);
}

// ------------------------------------------------------------------ table

String _cell(Share s) => s.d == 0 ? '-' : '${s.n}/${s.d} ${s.percent!.toStringAsFixed(1)}%';

void _table(StringBuffer out, GroupScore g, {String? title}) {
  final hasModel = g.model.files > 0;
  out.writeln('== ${title ?? g.name} ==');
  out.writeln('files read here ${g.rules.files}, not recorded ${g.notRecorded}, rows ${g.rules.rows}; '
      'verified ${g.rules.verifiedFiles} files with ${g.rules.expectedRows} expected rows, waiting to be verified ${g.unverified}; '
      'with model answers ${g.model.files}, of them stale ${g.stale}');
  const wide = 38, col = 20;
  out.writeln('${'measure'.padRight(wide)}${'rules'.padRight(col)}${hasModel ? '${'rules, model files'.padRight(col)}rules + model' : ''}');
  for (final m in Measure.all) {
    if (m.labelled && g.rules.verifiedFiles == 0) continue;
    final line = StringBuffer(m.label.padRight(wide))..write(_cell(g.rules[m.key]).padRight(col));
    if (hasModel) line.write('${_cell(g.rulesWhereModel[m.key]).padRight(col)}${_cell(g.model[m.key])}');
    out.writeln(line.toString().trimRight());
  }
  if (g.rules.verifiedFiles == 0) out.writeln('(no verified files: accuracy against expected rows is not measured)');
  if (hasModel) {
    final e = g.effect;
    out.writeln('model effect on ${g.model.files} files: unchanged ${e.unchanged}, better ${e.better}, worse ${e.worse}, '
        'changed with the same score ${e.level}, changed but not verified ${e.undecided}');
  }
  out.writeln();
}

// ---------------------------------------------------------------- compare

Map<String, dynamic>? _lastRun(File history) {
  if (!history.existsSync()) return null;
  final lines = history.readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
  if (lines.isEmpty) return null;
  try {
    return jsonDecode(lines.last) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

/// Prints every total that moved since [previous] and says how many got
/// worse by more than [threshold] percentage points.
int _compare(StringBuffer out, Map<String, dynamic> previous, Map<String, Object?> current, double threshold) {
  out.writeln('== Compared with the run of ${previous['date']}, commit ${previous['commit'] ?? 'unknown'} ==');
  final now = jsonDecode(jsonEncode(current['total'])) as Map<String, dynamic>;
  final before = previous['total'] as Map<String, dynamic>? ?? const {};
  var worse = 0, moved = 0;
  for (final (column, title) in [('rules', 'rules'), ('rulesPlusModel', 'rules + model')]) {
    final a = before[column] as Map<String, dynamic>? ?? const {}, b = now[column] as Map<String, dynamic>? ?? const {};
    for (final m in Measure.all) {
      final pa = (a[m.key] as Map<String, dynamic>?)?['percent'] as num?, pb = (b[m.key] as Map<String, dynamic>?)?['percent'] as num?;
      // A measure one of the runs couldn't take has nothing to compare.
      if (pa == null || pb == null) continue;
      final delta = pb.toDouble() - pa.toDouble();
      if (delta.abs() < 0.005) continue;
      moved++;
      final isWorse = m.better != 0 && delta * m.better < -threshold;
      if (isWorse) worse++;
      final da = (a[m.key] as Map<String, dynamic>)['d'], db = (b[m.key] as Map<String, dynamic>)['d'];
      out.writeln('${'$title: ${m.label}'.padRight(54)}${pa.toStringAsFixed(1)}% -> ${pb.toStringAsFixed(1)}% '
          '(${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(1)} points${da == db ? '' : ', out of $da then and $db now'})${isWorse ? '  WORSE' : ''}');
    }
  }
  if (moved == 0) out.writeln('No total moved.');
  out.writeln(worse == 0
      ? 'Nothing got worse by more than ${threshold.toStringAsFixed(1)} points.'
      : '$worse totals got worse by more than ${threshold.toStringAsFixed(1)} points.');
  out.writeln();
  return worse;
}

// ----------------------------------------------------------------- detail

/// A row by row account of one file. It quotes the document, so it is only
/// ever written under the files folder.
String _detail(FileResult f) {
  final out = StringBuffer('${f.rel}\n');
  final expected = f.expected;
  if (expected == null) out.writeln('No expected rows yet: run with --propose, correct them and mark them verified.');
  if (expected != null && !expected.verified) out.writeln('The expected rows are not verified; the comparison below is against a candidate.');
  void reading(String title, StatementRead read) {
    out.writeln('\n== $title ==');
    out.writeln('outcome ${read.outcome.name}, rows ${read.rows.length}, opening ${read.facts.opening}${read.facts.openingWorkedOut ? ' (worked out)' : ''}, '
        'closing ${read.facts.closing}${read.facts.closingWorkedOut ? ' (worked out)' : ''}, account ${read.facts.refs.map((r) => r.key).join(' ')}');
    String row(int i) {
      final r = read.rows[i];
      return '#$i ${r.date.toIso8601String().substring(0, 10)}${r.dateGuessed ? '?' : ''} ${r.amount}${r.signGuessed ? '?' : ''} ${r.currency ?? ''} '
          '"${r.description}" balance ${r.balance}${r.doubtful ? ' doubtful' : ''}';
    }

    if (expected == null) {
      for (var i = 0; i < read.rows.length; i++) {
        out.writeln(row(i));
      }
      return;
    }
    String want(int i) {
      final e = expected.rows[i];
      return '#$i ${e.date.toIso8601String().substring(0, 10)} ${e.amount} ${e.currency ?? ''} "${e.name}" balance ${e.balance}';
    }

    final m = matchRows(expected.rows, read.rows);
    for (final p in m.pairs) {
      final e = expected.rows[p.expected], r = read.rows[p.read];
      final wrong = [
        if (!sameDay(e.date, r.date)) 'date',
        if (e.amount.sign != r.amount.sign) 'direction',
        if (!sameMoney(e.amount.abs(), r.amount.abs())) 'amount',
        if (e.currency != null && e.currency != r.currency) 'currency',
        if (e.balance != null && (r.balance == null || !sameMoney(e.balance!, r.balance!))) 'balance',
        if (e.name.trim().isNotEmpty && !nameContains(e.name, r.description)) 'name' else if (e.name.trim().isNotEmpty && !nameExact(e.name, r.description)) 'name (contains)',
      ];
      out.writeln('${wrong.isEmpty ? 'ok     ' : 'WRONG  '} expected ${want(p.expected)}\n         read     ${row(p.read)}${wrong.isEmpty ? '' : '\n         wrong: ${wrong.join(', ')}'}');
    }
    for (final i in m.missed) {
      out.writeln('MISSED   expected ${want(i)}');
    }
    for (final i in m.invented) {
      out.writeln('INVENTED read     ${row(i)}');
    }
    out.writeln('expected opening ${expected.opening}, closing ${expected.closing}, account ${expected.account}');
  }

  reading('rules', f.rules!);
  if (f.model != null) {
    reading('rules + model${f.stale ? ' (the model answers are stale: record the file again)' : ''}', f.model!);
  } else {
    out.writeln('\nNo model answers recorded for this file.');
  }
  return out.toString();
}
