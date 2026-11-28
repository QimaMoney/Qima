import 'dart:js_interop';

// Shares Qima's models by path, as bin/qima_mcp.dart does.
// ignore: avoid_relative_lib_imports
import '../../../lib/mcp/ai_inbox.dart';
// ignore: avoid_relative_lib_imports
import '../../../lib/mcp/mcp_server.dart';
// ignore: avoid_relative_lib_imports
import '../../../lib/mcp/snapshot_location.dart';

/// The Mac helper's half of `qima-mcp`: the same [McpServer] as
/// `bin/qima_mcp.dart`, compiled with `dart compile js` and run by
/// `macos/main.swift` in the system's JavaScript engine.
///
/// The Mac App Store turns away a `dart compile exe` binary, because Dart's
/// own runtime calls a system function Apple keeps private. So on the Mac
/// the helper is a small Swift program that owns stdin, stdout and the
/// files, and this script answers each line. There is no `dart:io` here:
/// every file is reached through [_Host].
const String _version = String.fromEnvironment('QIMA_VERSION', defaultValue: 'dev');

/// What `macos/main.swift` offers the script, as the global `qimaHost`.
extension type _Host._(JSObject _) implements JSObject {
  /// The text of the shared copy, or null when it could not be read.
  external JSString? readSnapshot();

  /// Why the last [readSnapshot] gave nothing: null when there is no copy,
  /// else the system's message.
  external JSString? readProblem();

  /// Whether the file named [marker] is in the folder named [folder] beside
  /// the shared copy.
  external JSBoolean accepting(JSString folder, JSString marker);

  /// Leaves [contents] as [name], with [meta] as `meta.json`, in a new
  /// batch in [folder]. Null when done, else the system's message.
  external JSString? leaveFile(JSString folder, JSString name, JSString contents, JSString meta);
}

@JS('qimaHost')
external _Host get _host;

@JS('qimaHandleLine')
external set _handleLine(JSFunction answer);

void main() {
  final server = McpServer(
    loadSnapshot: () {
      final text = _host.readSnapshot()?.toDart;
      if (text != null) return SnapshotLocation.parse(text);
      final why = _host.readProblem()?.toDart;
      throw why == null ? SnapshotLocation.notShared : SnapshotLocation.unreadable(why);
    },
    leaveFile: (name, contents) {
      final folder = AiInbox.folderName.toJS;
      if (!_host.accepting(folder, AiInbox.marker.toJS).toDart) throw AiInbox.notAccepting;
      final why = _host.leaveFile(folder, name.toJS, contents.toJS, AiInbox.meta(name, DateTime.now()).toJS)?.toDart;
      if (why != null) throw AiInbox.unwritable(why);
    },
    version: _version,
  );
  _handleLine = ((JSString line) => server.handleLine(line.toDart)?.toJS).toJS;
}
