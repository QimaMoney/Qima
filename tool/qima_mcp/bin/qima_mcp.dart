import 'dart:io';

// The helper shares Qima's models by path so it needs neither Flutter nor
// the app's plugins: everything under lib/mcp and lib/models it reaches is
// pure Dart.
// ignore: avoid_relative_lib_imports
import '../../../lib/mcp/mcp_stdio.dart';

/// `qima-mcp` for Windows and Linux, built with `dart compile exe` and
/// shipped beside the desktop app. The Mac helper runs the same
/// [runMcpStdio] on the app's Flutter engine instead (`macos/main.swift`).
const String _version = String.fromEnvironment('QIMA_VERSION', defaultValue: 'dev');

Future<void> main(List<String> args) async {
  exitCode = await runMcpStdio(args, version: _version);
}
