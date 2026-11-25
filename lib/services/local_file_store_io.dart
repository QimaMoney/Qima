import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// `dart:io`-backed JSON file storage, used on every platform except Web
/// (see `local_file_store.dart` / `local_file_store_stub.dart`).
Directory? _cachedDir;

Future<Directory> _directory() async {
  final cached = _cachedDir;
  if (cached != null) return cached;
  final dir = await getApplicationSupportDirectory();
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  _cachedDir = dir;
  return dir;
}

/// Like [_fileFor], recreates the directory if something removed it.
Future<String> directoryPath() async {
  final dir = await _directory();
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir.absolute.path;
}

Future<File> _fileFor(String relativePath) async {
  final dir = await _directory();
  final file = File('${dir.path}/$relativePath');
  final parent = file.parent;
  if (!await parent.exists()) {
    await parent.create(recursive: true);
  }
  return file;
}

Future<Map<String, dynamic>?> readJson(String relativePath) async {
  final file = await _fileFor(relativePath);
  if (!await file.exists()) return null;
  final contents = await file.readAsString();
  if (contents.isEmpty) return null;
  return jsonDecode(contents) as Map<String, dynamic>;
}

/// Like [readJson], but a file that cannot be read or parsed throws instead
/// of looking like a missing one.
Future<Map<String, dynamic>?> readJsonStrict(String relativePath) async {
  final file = await _fileFor(relativePath);
  if (!await file.exists()) return null;
  return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
}

/// Writes [data] atomically: the encoded JSON lands in a sibling `path.tmp`
/// file first, then that file is renamed over [relativePath]. A rename is a
/// single filesystem operation, so a crash or a concurrent writer (a
/// background isolate will also write these files later) can never observe
/// a half-written target file.
Future<bool> writeJson(String relativePath, Map<String, dynamic> data) async {
  final file = await _fileFor(relativePath);
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsString(jsonEncode(data));
  await tmp.rename(file.path);
  return true;
}

void overrideDirectoryForTesting(Object dir) {
  _cachedDir = dir as Directory;
}
