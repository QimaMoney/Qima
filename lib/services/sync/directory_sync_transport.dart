import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'sync_transport.dart';
import 'sync_wire.dart';

/// A [SyncTransport] that is a directory: one file per part of a batch and
/// of a snapshot, `batch.<name>.json` and `snapshot.<name>.json` with the
/// names the refs give. Whatever keeps the directory the same on every device
/// (a synced folder, an iCloud container) is the remote.
///
/// A file is written under another name first, flushed, and renamed into
/// place, so a reader, here or on another device, never sees half of one from
/// this code. A file that is only half there because its download has not
/// finished is handed over as it is; the engine finds it unreadable, reports
/// it and reads it again on the next round. Files that are not ours (and the
/// hidden files a sync service keeps beside its downloads) are left alone.
///
/// The rename is not flushed to the disk: `dart:io` cannot sync a directory.
/// After a power cut a file stored a moment before may be missing although
/// the engine was told it is there. Readers then wait at that gap in the
/// writer's log until the writer's next snapshot, which covers it.
class DirectorySyncTransport implements SyncTransport {
  static const String _batch = 'batch.';
  static const String _snapshot = 'snapshot.';
  static const String _extension = '.json';
  static const String _temporary = '.tmp';

  /// How old a temporary file must be before it is taken for the remains of
  /// a write that stopped, and removed. No write takes this long.
  static const Duration staleAfter = Duration(hours: 1);

  final Directory directory;
  final Random _random = Random();

  DirectorySyncTransport(this.directory);

  File _batchFile(SyncBatchRef ref) => File('${directory.path}/$_batch${ref.name}$_extension');

  File _snapshotFile(SyncSnapshotRef ref) => File('${directory.path}/$_snapshot${ref.name}$_extension');

  /// Writes [body] to [file] all or nothing. A file that is already there is
  /// kept, and the answer is whether it holds [body].
  Future<bool> _store(File file, String body) async {
    await directory.create(recursive: true);
    final held = await _read(file);
    if (held != null) return held == body;
    final name = file.uri.pathSegments.last;
    // Hidden, and unlike any other writer's: two isolates may store the same
    // name at once.
    final temp = File('${directory.path}/.$name.$pid.${_random.nextInt(1 << 32)}$_temporary');
    try {
      await temp.writeAsString(body, flush: true);
      await temp.rename(file.path);
    } catch (_) {
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
    return true;
  }

  @override
  Future<bool> append(SyncBatchRef ref, String body) => _store(_batchFile(ref), body);

  @override
  Future<bool> writeSnapshot(SyncSnapshotRef ref, String body) => _store(_snapshotFile(ref), body);

  /// The part of a file name between [prefix] and the extension, or null when
  /// the file is not one of that kind.
  static String? _named(String fileName, String prefix) =>
      fileName.startsWith(prefix) && fileName.endsWith(_extension) ? fileName.substring(prefix.length, fileName.length - _extension.length) : null;

  Future<List<File>> _files() async {
    if (!await directory.exists()) return const [];
    return [
      await for (final entity in directory.list())
        if (entity is File) entity,
    ];
  }

  @override
  Future<SyncListing> list({required Map<String, int> after}) async {
    final batches = <SyncBatchRef>[];
    final snapshots = <SyncSnapshotRef>[];
    final problems = <String>[];
    for (final file in await _files()) {
      final fileName = file.uri.pathSegments.last;
      final batchName = _named(fileName, _batch);
      final snapshotName = _named(fileName, _snapshot);
      if (batchName != null) {
        final ref = SyncBatchRef.parse(batchName);
        if (ref == null) {
          problems.add('$fileName is not named like a batch');
        } else if (ref.last > (after[ref.device] ?? 0)) {
          batches.add(ref);
        }
      } else if (snapshotName != null) {
        final ref = SyncSnapshotRef.parse(snapshotName);
        if (ref == null) {
          problems.add('$fileName is not named like a snapshot');
        } else {
          snapshots.add(ref);
        }
      }
    }
    return SyncListing(batches: batches, snapshots: snapshots, problems: problems);
  }

  /// The text of [file], or null when it is not there (another device
  /// compacted since it was listed). Bytes that are not text (a file cut in
  /// the middle of a character) and a file larger than the engine reads are
  /// handed over as text the engine finds unreadable, so they are reported
  /// like any other damaged body and never loaded whole.
  Future<String?> _read(File file) async {
    try {
      final length = await file.length();
      if (length > SyncWire.maxBodyBytes) return 'a file of $length bytes';
      return utf8.decode(await file.readAsBytes(), allowMalformed: true);
    } on PathNotFoundException {
      return null;
    }
  }

  @override
  Future<String?> read(SyncBatchRef ref) => _read(_batchFile(ref));

  @override
  Future<String?> readSnapshot(SyncSnapshotRef ref) => _read(_snapshotFile(ref));

  @override
  Future<void> discard({required Map<String, int> batchesThrough, required Iterable<SyncSnapshotRef> snapshots}) async {
    final now = DateTime.now();
    for (final file in await _files()) {
      final fileName = file.uri.pathSegments.last;
      final batchName = _named(fileName, _batch);
      final ref = batchName == null ? null : SyncBatchRef.parse(batchName);
      if (ref != null && ref.last <= (batchesThrough[ref.device] ?? 0)) {
        await _remove(file);
      } else if (_isOurTemporary(fileName) && now.difference(await _modified(file) ?? now) > staleAfter) {
        // What a write that stopped half way left behind.
        await _remove(file);
      }
    }
    for (final ref in snapshots) {
      await _remove(_snapshotFile(ref));
    }
  }

  static bool _isOurTemporary(String fileName) => fileName.endsWith(_temporary) && (fileName.startsWith('.$_batch') || fileName.startsWith('.$_snapshot'));

  static Future<DateTime?> _modified(File file) async {
    try {
      return await file.lastModified();
    } on PathNotFoundException {
      return null;
    }
  }

  /// Another device may have removed the file already.
  static Future<void> _remove(File file) async {
    try {
      await file.delete();
    } on PathNotFoundException {
      // Gone already.
    }
  }
}
