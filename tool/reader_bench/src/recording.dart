// What the reader bench keeps of one file so its reading can be replayed
// without the platform: the pages text recognition gave, and what the
// on-device model answered. Recordings hold a document's real text, so
// they are only ever written under `<files folder>/.bench/`, never in the
// repository.
import 'dart:convert';
import 'dart:io';

import 'package:qima/models/statement_facts.dart';
import 'package:qima/models/statement_reader.dart';
import 'package:qima/models/transaction_capture.dart';
import 'package:qima/services/ai_assist_provider.dart';
import 'package:qima/services/import/import_inbox.dart';
import 'package:qima/services/import/statement_files.dart';
import 'package:qima/services/text_recognition_service.dart';

const recordingVersion = 1;

/// How the bench groups files: a PDF, a picture, a table (CSV, Excel) or a
/// shared message. Null for a file the app doesn't read.
String? kindOf(String extension) {
  if (extension == 'pdf') return 'pdf';
  if (StatementFiles.images.contains(extension)) return 'picture';
  if (StatementFiles.tables.contains(extension)) return 'table';
  if (extension == 'txt') return 'message';
  return null;
}

/// Where everything derived from the files in [files] lives.
class BenchFolder {
  final Directory files;
  const BenchFolder(this.files);

  Directory get root => Directory('${files.path}/.bench');
  File pages(String rel) => File('${root.path}/pages/$rel.json');
  File model(String rel) => File('${root.path}/model/$rel.json');
  File expected(String rel) => File('${root.path}/expected/$rel.json');
  File detail(String rel) => File('${root.path}/detail/$rel.txt');
  File get report => File('${root.path}/report.json');
  File get history => File('${root.path}/history.jsonl');
  File get summary => File('${root.path}/summary.txt');

  /// Every file the app could read, by its path under [files], sorted.
  /// Hidden files and folders (this bench's own among them) are left out.
  List<String> list() {
    if (!files.existsSync()) return const [];
    final prefix = files.absolute.path.endsWith('/') ? files.absolute.path : '${files.absolute.path}/';
    final out = <String>[];
    for (final e in files.absolute.listSync(recursive: true, followLinks: false)) {
      if (e is! File || !e.path.startsWith(prefix)) continue;
      final rel = e.path.substring(prefix.length);
      if (rel.split('/').any((part) => part.startsWith('.'))) continue;
      out.add(rel);
    }
    return out..sort();
  }

  File file(String rel) => File('${files.path}/$rel');

  /// The file as the import flow sees it. A recording has no day it was
  /// shared, so the day the file was last changed stands in for it.
  ImportFile importFile(String rel) {
    final f = file(rel);
    return ImportFile(id: rel, name: rel.split('/').last, receivedAt: f.lastModifiedSync(), path: f.path);
  }
}

String extensionOf(String rel) {
  final name = rel.split('/').last;
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

// ------------------------------------------------------------------ pages

/// The pages text recognition gave for one file; [pages] is null when it
/// couldn't read the file.
class PagesRecording {
  final List<String> languages;
  final List<DocPage>? pages;

  const PagesRecording({required this.languages, required this.pages});

  Map<String, Object?> toJson() => {
        'version': recordingVersion,
        'languages': languages,
        'pages': pages == null
            ? null
            : [
                for (final p in pages!) [for (final t in p.tokens) {'t': t.text, 'x': t.x, 'y': t.y, 'w': t.w, 'h': t.h}],
              ],
      };

  factory PagesRecording.fromJson(Map<String, dynamic> json) => PagesRecording(
        languages: [for (final l in json['languages'] as List? ?? const []) l as String],
        pages: json['pages'] == null
            ? null
            : [
                for (final p in json['pages'] as List) DocPage([for (final t in p as List) DocToken.fromJson(t as Map<dynamic, dynamic>)]),
              ],
      );

  static PagesRecording? load(File file) => file.existsSync() ? PagesRecording.fromJson(jsonDecode(file.readAsStringSync()) as Map<String, dynamic>) : null;
}

// ------------------------------------------------------------------ model

/// One question put to the model and what it said. [asked] is what the
/// answer was about (the lines, the message): an answer only replays onto
/// the same question.
class ModelCall {
  final Object? asked;
  final Object? answer;

  /// The call threw; the import flow gives the file up as unreadable.
  final bool failed;

  const ModelCall({this.asked, this.answer, this.failed = false});

  Map<String, Object?> toJson() => {'asked': asked, 'answer': answer, if (failed) 'failed': true};

  static ModelCall? fromJson(Object? json) =>
      json is Map<String, dynamic> ? ModelCall(asked: json['asked'], answer: json['answer'], failed: json['failed'] == true) : null;
}

/// What the on-device model said about one file, in the shapes its platform
/// channel uses, so replaying goes through the app's own parsing.
class ModelRecording {
  final bool available;

  /// [ModelStatus] by name.
  final String status;
  final ModelCall? structure;
  final ModelCall? lines;
  final ModelCall? message;

  const ModelRecording({required this.available, required this.status, this.structure, this.lines, this.message});

  Map<String, Object?> toJson() => {
        'version': recordingVersion,
        'available': available,
        'status': status,
        'structurePages': structure?.toJson(),
        'labelStatementLines': lines?.toJson(),
        'readMessage': message?.toJson(),
      };

  factory ModelRecording.fromJson(Map<String, dynamic> json) => ModelRecording(
        available: json['available'] == true,
        status: json['status'] as String? ?? ModelStatus.unsupported.name,
        structure: ModelCall.fromJson(json['structurePages']),
        lines: ModelCall.fromJson(json['labelStatementLines']),
        message: ModelCall.fromJson(json['readMessage']),
      );

  static ModelRecording? load(File file) => file.existsSync() ? ModelRecording.fromJson(jsonDecode(file.readAsStringSync()) as Map<String, dynamic>) : null;
}

const _kindNames = {
  LineKind.transaction: 'transaction',
  LineKind.opening: 'opening balance',
  LineKind.closing: 'closing balance',
  LineKind.account: 'account',
  LineKind.other: 'other',
};

Map<String, Object?> _labelJson(LineLabel l) => {'line': l.line, 'kind': _kindNames[l.kind], 'name': l.name};

Map<String, Object?> _structureJson(PageStructure s) => {
      'rows': [
        for (final r in s.rows) {'date': r.date, 'amount': r.amount, 'balance': r.balance, 'direction': r.direction, 'name': r.name},
      ],
      'opening': s.opening,
      'closing': s.closing,
      'account': s.account,
    };

Map<String, Object?> _messageJson(MessageLabels m) => {'intent': m.intent?.name, 'amount': m.amount, 'balance': m.balance, 'name': m.name};

bool _sameList(Object? a, List<String> b) {
  if (a is! List || a.length != b.length) return false;
  for (var i = 0; i < b.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// -------------------------------------------------------------- recording

/// Text recognition that keeps what the real one gave.
class RecordingRecognition implements TextRecognitionService {
  final TextRecognitionService inner;
  PagesRecording? recorded;

  RecordingRecognition(this.inner);

  @override
  Future<bool> isAvailable() => inner.isAvailable();

  @override
  Future<List<String>?> recognize(String imagePath, List<String> languageTags) => inner.recognize(imagePath, languageTags);

  @override
  Future<List<DocPage>?> readDocument(String path, List<String> languageTags) async {
    final pages = await inner.readDocument(path, languageTags);
    recorded = PagesRecording(languages: languageTags, pages: pages);
    return pages;
  }
}

/// A model that keeps what the real one answered. Wrapped round the model
/// while the app's own import flow reads a file, it records exactly the
/// questions that flow asks.
class RecordingAssist implements AiAssistProvider {
  final AiAssistProvider inner;
  final String localeTag;
  bool? _available;
  ModelCall? _structure, _lines, _message;

  RecordingAssist(this.inner, this.localeTag);

  Future<ModelRecording> recording() async => ModelRecording(
        available: _available ?? await inner.isAvailable(),
        status: (await inner.status(localeTag)).name,
        structure: _structure,
        lines: _lines,
        message: _message,
      );

  @override
  Future<bool> isAvailable() async => _available = await inner.isAvailable();

  @override
  Future<ModelStatus> status(String localeTag) => inner.status(localeTag);

  @override
  Future<CaptureSpans?> labelTransaction(String text, String localeTag) => inner.labelTransaction(text, localeTag);

  @override
  Future<String?> phrase(String sentence, String localeTag) => inner.phrase(sentence, localeTag);

  @override
  Future<List<PageStructure>?> structurePages(String path, List<DocPage> pages, String localeTag) async {
    try {
      final answer = await inner.structurePages(path, pages, localeTag);
      _structure = ModelCall(answer: answer?.map(_structureJson).toList());
      return answer;
    } catch (_) {
      _structure = const ModelCall(failed: true);
      rethrow;
    }
  }

  @override
  Future<List<LineLabel>?> labelStatementLines(List<String> lines, String localeTag) async {
    try {
      final answer = await inner.labelStatementLines(lines, localeTag);
      _lines = ModelCall(asked: lines, answer: answer?.map(_labelJson).toList());
      return answer;
    } catch (_) {
      _lines = ModelCall(asked: lines, failed: true);
      rethrow;
    }
  }

  @override
  Future<MessageLabels?> readMessage(String text, String localeTag) async {
    try {
      final answer = await inner.readMessage(text, localeTag);
      _message = ModelCall(asked: text, answer: answer == null ? null : _messageJson(answer));
      return answer;
    } catch (_) {
      _message = ModelCall(asked: text, failed: true);
      rethrow;
    }
  }
}

// ----------------------------------------------------------------- replay

/// Text recognition that gives back the recorded pages.
class ReplayRecognition implements TextRecognitionService {
  final PagesRecording? recording;
  const ReplayRecognition(this.recording);

  @override
  Future<bool> isAvailable() async => recording != null;

  @override
  Future<List<String>?> recognize(String imagePath, List<String> languageTags) async => null;

  @override
  Future<List<DocPage>?> readDocument(String path, List<String> languageTags) async => recording?.pages;
}

/// A model that gives back the recorded answers. An answer about lines or a
/// message is only given for the same lines or message: once the reader
/// splits a page differently, line numbers no longer mean the same lines,
/// and the recording is [stale] until the file is recorded again.
class ReplayAssist implements AiAssistProvider {
  final ModelRecording recording;
  bool stale = false;

  ReplayAssist(this.recording);

  @override
  Future<bool> isAvailable() async => recording.available;

  @override
  Future<ModelStatus> status(String localeTag) async => ModelStatus.values.asNameMap()[recording.status] ?? ModelStatus.unsupported;

  @override
  Future<CaptureSpans?> labelTransaction(String text, String localeTag) async => null;

  @override
  Future<String?> phrase(String sentence, String localeTag) async => null;

  static void _failIf(ModelCall call) {
    if (call.failed) throw StateError('The recorded call failed');
  }

  @override
  Future<List<PageStructure>?> structurePages(String path, List<DocPage> pages, String localeTag) async {
    final call = recording.structure;
    if (call == null) return null;
    _failIf(call);
    final raw = call.answer;
    if (raw is! List) return null;
    if (raw.length != pages.length) {
      stale = true;
      return null;
    }
    return [for (final p in raw) p is Map<Object?, Object?> ? PageStructure.fromMap(p) : const PageStructure()];
  }

  @override
  Future<List<LineLabel>?> labelStatementLines(List<String> lines, String localeTag) async {
    final call = recording.lines;
    if (call == null) {
      // The flow asks now though it didn't when recorded.
      if (lines.isNotEmpty) stale = true;
      return null;
    }
    if (!_sameList(call.asked, lines)) {
      stale = true;
      return null;
    }
    _failIf(call);
    final raw = call.answer;
    if (raw is! List) return null;
    return raw.whereType<Map<Object?, Object?>>().map(LineLabel.fromMap).nonNulls.toList();
  }

  @override
  Future<MessageLabels?> readMessage(String text, String localeTag) async {
    final call = recording.message;
    if (call == null || call.asked != text) {
      stale = true;
      return null;
    }
    _failIf(call);
    final raw = call.answer;
    return raw is Map<Object?, Object?> ? MessageLabels.fromMap(raw) : null;
  }
}

/// Files as they lie on disk: tables and messages are read straight from
/// their path.
class DiskInbox implements ImportInbox {
  const DiskInbox();

  @override
  Future<List<int>> bytes(ImportFile file) => File(file.path).readAsBytes();

  @override
  Future<List<ImportFile>> pending() async => const [];

  @override
  Future<ImportFile?> add(String name, List<int> bytes, {DateTime? receivedAt}) async => null;

  @override
  Future<void> remove(String id) async {}
}

/// Reads [file] the way the app does, from what was recorded: the rules
/// alone when [model] is null, the rules and the model's recorded answers
/// otherwise. The second value says the model's answers no longer fit.
Future<(StatementRead, bool)> replay(ImportFile file, {PagesRecording? pages, ModelRecording? model, required List<String> languages}) async {
  final assist = model == null ? null : ReplayAssist(model);
  final files = StatementFiles(
    recognition: ReplayRecognition(pages),
    inbox: const DiskInbox(),
    assist: () => assist ?? const NullAiAssistProvider(),
  );
  final read = await files.read(file, languages: pages == null || pages.languages.isEmpty ? languages : pages.languages);
  return (read, assist?.stale ?? false);
}

// ---------------------------------------------------------------- record

/// What one recording run did, as counts only.
class RecordSummary {
  int files = 0, recorded = 0, skipped = 0, unreadable = 0, notRecordable = 0, withModel = 0, failed = 0;
  String modelStatus = '';

  @override
  String toString() =>
      'files $files, recorded $recorded, already recorded $skipped, need no recording $notRecordable, unreadable $unreadable, failed $failed, '
      'with model answers $withModel, model status ${modelStatus.isEmpty ? 'not asked' : modelStatus}';
}

void _write(File file, Object? json) {
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(jsonEncode(json));
}

bool _fresh(File recording, File source) => recording.existsSync() && recording.lastModifiedSync().isAfter(source.lastModifiedSync());

/// Records every file under [folder] by running the app's own import flow
/// over it with [recognition] and [assist], keeping the pages and the
/// model's answers. A file whose recording is newer than the file is left
/// alone unless [refresh]; so is a model recording, except one made while
/// the model was unavailable, which is tried again once it is ready.
Future<RecordSummary> recordFolder(
  BenchFolder folder, {
  required TextRecognitionService recognition,
  required AiAssistProvider assist,
  required List<String> languages,
  bool refresh = false,
}) async {
  final summary = RecordSummary();
  final locale = languages.first;
  final modelReady = await assist.isAvailable();
  summary.modelStatus = (await assist.status(locale)).name;
  for (final rel in folder.list()) {
    final kind = kindOf(extensionOf(rel));
    if (kind == null) continue;
    summary.files++;
    if (kind == 'table') {
      summary.notRecordable++;
      continue;
    }
    final source = folder.file(rel);
    final pagesFile = folder.pages(rel), modelFile = folder.model(rel);
    final needsPages = kind != 'message';
    final pagesFresh = !needsPages || (!refresh && _fresh(pagesFile, source));
    final earlier = !refresh && _fresh(modelFile, source) ? ModelRecording.load(modelFile) : null;
    final modelFresh = earlier != null && (earlier.available || !modelReady);
    if (pagesFresh && modelFresh) {
      summary.skipped++;
      if (earlier.available) summary.withModel++;
      continue;
    }
    try {
      final recorder = RecordingRecognition(recognition);
      final model = RecordingAssist(assist, locale);
      final files = StatementFiles(
        recognition: needsPages && pagesFresh ? ReplayRecognition(PagesRecording.load(pagesFile)) : recorder,
        inbox: const DiskInbox(),
        assist: () => model,
      );
      await files.read(folder.importFile(rel), languages: languages);
      if (needsPages && !pagesFresh) {
        final pages = recorder.recorded ?? PagesRecording(languages: languages, pages: null);
        if (pages.pages == null) summary.unreadable++;
        _write(pagesFile, pages.toJson());
      }
      final answers = await model.recording();
      _write(modelFile, answers.toJson());
      if (answers.available) summary.withModel++;
      summary.recorded++;
    } catch (_) {
      // Never the error itself: it may quote the document.
      summary.failed++;
    }
  }
  return summary;
}
