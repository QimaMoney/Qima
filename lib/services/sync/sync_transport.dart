/// Where one part of one batch sits in the log of the device that wrote it.
///
/// A batch is the changes of [device] after [prev], up to and including
/// [last] (both are numbers in that device's own change log). The batches of
/// a device form a chain, each starting where an earlier one ended, which is
/// how a reader knows that it has missed none. A batch too large for one body
/// is stored as [parts] bodies, numbered from 1; a reader uses the batch once
/// all of them are there.
///
/// [writer] names the run of the engine that wrote the batch (a new one for
/// every start, on every isolate). It makes the name of a batch its own: two
/// databases that share a device id (one is a copy of the other) never give
/// two different batches one name, and each can tell the batches it wrote
/// from the other's, whatever their numbers.
class SyncBatchRef {
  final String device;
  final String writer;
  final int prev;
  final int last;
  final int part;
  final int parts;

  const SyncBatchRef({required this.device, required this.writer, required this.prev, required this.last, this.part = 1, this.parts = 1});

  /// The name a transport can store the body under.
  String get name => '$device.$writer.$prev.$last.$part.$parts';

  /// The whole batch this is a part of, without the part number.
  String get batch => '$device.$writer.$prev.$last.$parts';

  SyncBatchRef partAt(int number) => SyncBatchRef(device: device, writer: writer, prev: prev, last: last, part: number, parts: parts);

  /// The ref [name] is the name of, or null when it is not such a name. Only
  /// the one spelling [name] gives is accepted, so a ref that was parsed
  /// always leads back to the body it was parsed from.
  static SyncBatchRef? parse(String name) {
    final fields = name.split('.');
    if (fields.length != 6 || !isDeviceId(fields[0]) || !isDeviceId(fields[1])) return null;
    final numbers = [for (final field in fields.skip(2)) _number(field)];
    if (numbers.contains(null)) return null;
    final [prev!, last!, part!, parts!] = numbers;
    if (last <= prev || part < 1 || part > parts) return null;
    return SyncBatchRef(device: fields[0], writer: fields[1], prev: prev, last: last, part: part, parts: parts);
  }

  @override
  bool operator ==(Object other) => other is SyncBatchRef && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => name;
}

/// One part of a snapshot: everything [device] held when its own change log
/// stood at [seq], in [parts] bodies, written by the run [writer] of its
/// engine. A device writes a new snapshot under a new name and never rewrites
/// one, so a reader that has taken one in can name exactly that one for
/// removal.
class SyncSnapshotRef {
  final String device;
  final String writer;
  final int seq;
  final int part;
  final int parts;

  const SyncSnapshotRef({required this.device, required this.writer, required this.seq, this.part = 1, this.parts = 1});

  String get name => '$device.$writer.$seq.$part.$parts';

  /// The whole snapshot this is a part of.
  String get snapshot => '$device.$writer.$seq.$parts';

  SyncSnapshotRef partAt(int number) => SyncSnapshotRef(device: device, writer: writer, seq: seq, part: number, parts: parts);

  static SyncSnapshotRef? parse(String name) {
    final fields = name.split('.');
    if (fields.length != 5 || !isDeviceId(fields[0]) || !isDeviceId(fields[1])) return null;
    final numbers = [for (final field in fields.skip(2)) _number(field)];
    if (numbers.contains(null)) return null;
    final [seq!, part!, parts!] = numbers;
    if (part < 1 || part > parts) return null;
    return SyncSnapshotRef(device: fields[0], writer: fields[1], seq: seq, part: part, parts: parts);
  }

  @override
  bool operator ==(Object other) => other is SyncSnapshotRef && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => name;
}

/// Device ids and writer names are lower case letters and digits only, so a
/// ref's name can be a file name, a record name or a path segment as it is.
bool isDeviceId(String text) => _deviceId.hasMatch(text);

final RegExp _deviceId = RegExp(r'^[a-z0-9]{1,64}$');

/// A number as `toString` writes it: no sign, no leading zero.
final RegExp _digits = RegExp(r'^(0|[1-9][0-9]{0,17})$');

int? _number(String text) => _digits.hasMatch(text) ? int.parse(text) : null;

/// The names of what a transport holds.
class SyncListing {
  final List<SyncBatchRef> batches;
  final List<SyncSnapshotRef> snapshots;

  /// Things the transport found and could not name (a file that only looks
  /// like one of ours), in words for a log. Never fatal.
  final List<String> problems;

  const SyncListing({this.batches = const [], this.snapshots = const [], this.problems = const []});
}

/// The shared place the devices of one person exchange changes through. It
/// stores text under names and knows nothing of what the text means, so a
/// folder of files, a set of CloudKit records or a server endpoint can each
/// be one.
///
/// What the engine relies on:
/// - [append] and [writeSnapshot] are all or nothing, and what they stored is
///   still there after they return. A name that is already there keeps its
///   body, and the call says whether that body is, to the letter, the one it
///   was given. When it is not, the engine stores its body under another
///   name and leaves what is there alone.
/// - [list] may name less than there is (a slow download, a page of results),
///   more than was asked for, and the same name twice, in any order. The
///   engine sorts that out and asks again while it makes progress.
/// - A body may be cut short or damaged when it is read. The engine reports
///   it and reads it again on a later round.
/// - Nothing is ever removed except by [discard].
abstract class SyncTransport {
  /// Stores one part of a batch. False when the name is there with another
  /// body, which is then left as it is.
  Future<bool> append(SyncBatchRef ref, String body);

  /// Stores one part of a snapshot; false as for [append].
  Future<bool> writeSnapshot(SyncSnapshotRef ref, String body);

  /// The batches whose `last` is beyond what [after] holds for their device
  /// (0 for a device it does not name), and all snapshots.
  Future<SyncListing> list({required Map<String, int> after});

  /// The body of a part, or null when it is not there (any more).
  Future<String?> read(SyncBatchRef ref);

  Future<String?> readSnapshot(SyncSnapshotRef ref);

  /// Removes the batches whose `last` is at or before what [batchesThrough]
  /// holds for their device, and the named snapshot parts. A device it does
  /// not name keeps every batch.
  Future<void> discard({required Map<String, int> batchesThrough, required Iterable<SyncSnapshotRef> snapshots});
}
