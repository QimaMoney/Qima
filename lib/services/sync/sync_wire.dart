import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'sync_transport.dart';

/// Something a later build wrote. It is never changed, removed or skipped by
/// this one.
class SyncNewerVersion implements Exception {
  final int version;

  const SyncNewerVersion(this.version);

  @override
  String toString() => 'SyncNewerVersion: written in format $version; this build reads up to ${SyncWire.version}. Update the app.';
}

/// One record as it travels: the collection it belongs to and the whole
/// record (`Record.toJson`: item, order, updatedAt, deleted).
class SyncOp {
  final String collection;
  final Map<String, dynamic> record;

  const SyncOp(this.collection, this.record);

  Map<String, dynamic> toJson() => {'c': collection, 'r': record};

  static SyncOp fromJson(Object? json) {
    final map = json as Map<String, dynamic>;
    return SyncOp(map['c'] as String, map['r'] as Map<String, dynamic>);
  }
}

/// The text the engine hands a transport, like the cloud envelope of
/// `SyncedStore`: `{"v":1,"z":"gzip","data":"<base64 of the gzipped JSON>"}`.
/// The version is outside the compressed part, so a build can tell that a
/// body is from a later one without understanding anything else of it.
///
/// The same payload always gives the same text (the gzip header carries no
/// time), which is what lets a transport tell a body stored twice from two
/// different bodies under one name.
abstract final class SyncWire {
  /// The format this build reads and writes.
  static const int version = 1;

  /// About how much JSON one body carries. A batch or snapshot larger than
  /// this is stored as several parts, so that a transport with a limit on the
  /// size of a value can carry any book, and a reader never holds more than
  /// one part at a time. A single record larger than this is a part alone.
  static const int partBytes = 256 * 1024;

  /// The largest body this build reads, as text, and the most it will unpack
  /// one to. Far above what a part is, and far below what would exhaust a
  /// phone: a body is small on the wire whatever it unpacks to.
  static const int maxBodyBytes = 16 * 1024 * 1024;
  static const int maxPayloadBytes = 32 * 1024 * 1024;

  static String encode(Map<String, dynamic> payload) => jsonEncode({'v': version, 'z': 'gzip', 'data': base64Encode(gzip.encode(utf8.encode(jsonEncode(payload))))});

  /// Throws [SyncNewerVersion] for a later format and [FormatException] for
  /// anything that is not a body, is damaged, or is larger than this build
  /// reads.
  static Map<String, dynamic> decode(String body) {
    if (body.length > maxBodyBytes) throw FormatException('a sync body of ${body.length} characters, more than this build reads');
    final Object? envelope;
    try {
      envelope = jsonDecode(body);
    } catch (e) {
      throw FormatException('not a sync body: $e');
    }
    if (envelope is! Map<String, dynamic>) throw const FormatException('not a sync body');
    final v = envelope['v'];
    if (v is! int || v < 1) throw const FormatException('a sync body without a version');
    if (v > version) throw SyncNewerVersion(v);
    try {
      if (envelope['z'] != 'gzip') throw const FormatException('unknown compression');
      return jsonDecode(utf8.decode(_unpack(base64Decode(envelope['data'] as String)))) as Map<String, dynamic>;
    } catch (e) {
      throw FormatException('a sync body that cannot be read: $e');
    }
  }

  /// Unpacks gzip a piece at a time and stops at [maxPayloadBytes], so a
  /// small body cannot be made to fill the memory.
  static Uint8List _unpack(Uint8List packed) {
    final out = _Bounded(maxPayloadBytes);
    final input = gzip.decoder.startChunkedConversion(out);
    const step = 64 * 1024;
    for (var at = 0; at < packed.length; at += step) {
      input.add(Uint8List.sublistView(packed, at, at + step > packed.length ? packed.length : at + step));
    }
    input.close();
    return out.bytes.takeBytes();
  }

  /// [ops] in runs of about [partBytes] of JSON each, in order; one empty run
  /// for no ops, so there is always a first part.
  static List<List<SyncOp>> split(List<SyncOp> ops, {int partBytes = SyncWire.partBytes}) {
    final parts = <List<SyncOp>>[[]];
    var size = 0;
    for (final op in ops) {
      final length = jsonEncode(op.toJson()).length;
      if (parts.last.isNotEmpty && size + length > partBytes) {
        parts.add([]);
        size = 0;
      }
      parts.last.add(op);
      size += length;
    }
    return parts;
  }

  /// Runs [read] over a decoded payload, so a payload of the wrong shape is a
  /// [FormatException] like any other damage.
  static R _shaped<R>(R Function() read) {
    try {
      return read();
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('a sync body of the wrong shape: $e');
    }
  }
}

class _Bounded extends ByteConversionSink {
  final int max;
  final BytesBuilder bytes = BytesBuilder(copy: false);

  _Bounded(this.max);

  @override
  void add(List<int> chunk) {
    if (bytes.length + chunk.length > max) throw FormatException('unpacks to more than $max bytes');
    bytes.add(chunk);
  }

  @override
  void close() {}
}

/// One part of the changed records of one stretch of one device's log.
class SyncBatch {
  final SyncBatchRef ref;
  final List<SyncOp> ops;

  const SyncBatch(this.ref, this.ops);

  String get body => SyncWire.encode({
        'device': ref.device,
        'prev': ref.prev,
        'last': ref.last,
        'part': ref.part,
        'parts': ref.parts,
        'ops': [for (final op in ops) op.toJson()],
      });

  /// Reads the body stored under [ref]. A body that says it is another part
  /// or another batch (a file under the wrong name) is damage.
  static SyncBatch read(SyncBatchRef ref, String body) {
    final payload = SyncWire.decode(body);
    return SyncWire._shaped(() {
      if (payload['device'] != ref.device || payload['prev'] != ref.prev || payload['last'] != ref.last || payload['part'] != ref.part || payload['parts'] != ref.parts) {
        throw FormatException('not the batch $ref');
      }
      return SyncBatch(ref, [for (final op in payload['ops'] as List<dynamic>) SyncOp.fromJson(op)]);
    });
  }
}

/// One part of everything a device held at one moment. [covers], the same in
/// every part, says per device up to where in that device's log the snapshot
/// already has everything: whoever has taken the whole snapshot in does not
/// need the batches up to there.
class SyncSnapshot {
  final SyncSnapshotRef ref;
  final Map<String, int> covers;
  final List<SyncOp> records;

  const SyncSnapshot(this.ref, this.covers, this.records);

  String get body => SyncWire.encode({
        'device': ref.device,
        'seq': ref.seq,
        'part': ref.part,
        'parts': ref.parts,
        'covers': covers,
        'records': [for (final op in records) op.toJson()],
      });

  static SyncSnapshot read(SyncSnapshotRef ref, String body) {
    final payload = SyncWire.decode(body);
    return SyncWire._shaped(() {
      if (payload['device'] != ref.device || payload['seq'] != ref.seq || payload['part'] != ref.part || payload['parts'] != ref.parts) throw FormatException('not the snapshot $ref');
      final covers = (payload['covers'] as Map<String, dynamic>).map((device, seq) => MapEntry(device, seq as int));
      if (covers.keys.any((device) => !isDeviceId(device)) || covers.values.any((seq) => seq < 0)) throw const FormatException('a snapshot that covers what cannot be');
      return SyncSnapshot(ref, covers, [for (final op in payload['records'] as List<dynamic>) SyncOp.fromJson(op)]);
    });
  }
}
