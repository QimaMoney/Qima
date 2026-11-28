import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Why transactions could not be handed to Qima, in words the AI app can
/// pass on to the person.
class AddingUnavailable implements Exception {
  final String message;
  const AddingUnavailable(this.message);

  @override
  String toString() => message;
}

/// Where the `qima-mcp` helper leaves transactions an AI app wants added.
/// It is a folder beside the shared copy, laid out as Qima's import inbox
/// (`<id>/<file>` and `<id>/meta.json`), so the app reads each batch like
/// any shared statement and the person reviews it before anything is saved.
/// The helper never touches the books.
///
/// The app keeps [marker] in the folder while "Let AI apps add
/// transactions" is on; without it the helper writes nothing. Batches
/// already left stay for the person when the setting goes off.
abstract final class AiInbox {
  static const String folderName = 'qima-ai-inbox';
  static const String marker = '.accepting';

  /// The folder that goes with the shared copy at [snapshotPath].
  static String folderFor(String snapshotPath) => '${File(snapshotPath).parent.path}${Platform.pathSeparator}$folderName';

  static bool accepting(String folder) => File('$folder${Platform.pathSeparator}$marker').existsSync();

  /// What the helper answers while the person has not allowed adding.
  static const AddingUnavailable notAccepting = AddingUnavailable(
    'Qima is not letting AI apps add transactions on this computer. In Qima, open Settings, then AI apps, '
    'and turn on "Let AI apps add transactions".',
  );

  /// What the helper answers when the folder cannot be written; [why] is
  /// the system's own message.
  static AddingUnavailable unwritable(String why) => AddingUnavailable('Qima\'s folder could not be written ($why).');

  /// The `meta.json` that goes beside a file named [name] left at [now].
  static String meta(String name, DateTime now) =>
      jsonEncode({'name': name, 'receivedAt': now.toUtc().toIso8601String()});

  /// Leaves one file for Qima to read. Written under a dotted name and
  /// renamed once complete, so the app never reads half a batch.
  static void leave(String folder, String name, String contents, DateTime now, {Random? random}) {
    if (!accepting(folder)) throw notAccepting;
    final r = random ?? Random.secure();
    final id = [for (var i = 0; i < 16; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
    final sep = Platform.pathSeparator;
    final staging = Directory('$folder$sep.$id');
    try {
      staging.createSync();
      File('${staging.path}$sep$name').writeAsStringSync(contents, flush: true);
      File('${staging.path}${sep}meta.json')
          .writeAsStringSync(meta(name, now), flush: true);
      staging.renameSync('$folder$sep$id');
    } on FileSystemException catch (e) {
      try {
        if (staging.existsSync()) staging.deleteSync(recursive: true);
      } on FileSystemException {
        // Left behind under a dotted name, which Qima ignores.
      }
      throw unwritable(e.osError?.message ?? e.message);
    }
  }
}
