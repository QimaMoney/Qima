import 'dart:convert';
import 'dart:io';

import 'ai_inbox.dart';
import 'mcp_server.dart';
import 'snapshot_location.dart';

/// `qima-mcp`'s command line: Qima's MCP server for AI apps on the desktop
/// (Claude Desktop, VS Code, Cursor and others), over stdio.
///
///     qima-mcp [--snapshot <path>]
///
/// It reads only the copy Qima writes when "Let AI apps read Qima" is on,
/// and with "Let AI apps add transactions" on it leaves transactions in the
/// folder beside that copy for the person to review in Qima.
///
/// Every helper build runs this: `tool/qima_mcp` compiles it on Windows and
/// Linux, and the Mac helper runs it on the app's own Flutter engine
/// (`mcpMain` in `main.dart`). Returns the process's exit code once the AI
/// app closes stdin.
Future<int> runMcpStdio(List<String> args, {required String version}) async {
  String? path;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--snapshot' when i + 1 < args.length:
        path = args[++i];
      case '--version':
        stdout.writeln('qima-mcp $version');
        return 0;
      case '--help' || '-h':
        stdout.writeln('Usage: qima-mcp [--snapshot <path>]\nQima\'s MCP server for AI apps, over stdio.');
        return 0;
      default:
        stderr.writeln('qima-mcp: unknown argument ${args[i]}');
        return 64;
    }
  }
  path ??= SnapshotLocation.defaultPath();
  if (path == null) {
    stderr.writeln('qima-mcp: no default snapshot path on this system; pass --snapshot <path>.');
    return 64;
  }
  final snapshot = path;
  final inbox = AiInbox.folderFor(snapshot);
  final server = McpServer(
    loadSnapshot: () => SnapshotLocation.read(snapshot),
    leaveFile: (name, contents) => AiInbox.leave(inbox, name, contents, DateTime.now()),
    version: version,
  );

  // stdout carries protocol messages only; anything else goes to stderr.
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final reply = server.handleLine(line);
    if (reply != null) stdout.writeln(reply);
  }
  return 0;
}
