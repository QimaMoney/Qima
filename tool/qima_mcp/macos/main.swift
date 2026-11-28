import FlutterMacOS
import Foundation

// qima-mcp on the Mac: runs Qima's MCP server (`mcpMain` in lib/main.dart)
// on the Flutter engine the app already ships, with no window.
//
// It is not a `dart compile exe` binary as on Windows and Linux: Dart's
// standalone runtime links a private dyld symbol
// (`__dyld_find_unwind_sections`), which App Review rejects (guideline
// 2.5.1). The engine does not, and the app's compiled Dart is already in
// App.framework, so this adds no second runtime to the bundle.

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("qima-mcp: \(message)\n".utf8))
  exit(70)
}

// Qima.app/Contents/Helpers/QimaMCP.app → Qima.app/Contents/Frameworks.
let helper = Bundle.main
let frameworks = helper.bundleURL
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appendingPathComponent("Frameworks", isDirectory: true)
guard let dart = Bundle(url: frameworks.appendingPathComponent("App.framework", isDirectory: true)) else {
  fail("Qima's App.framework is missing; run the helper from inside Qima.app.")
}

// A debug engine announces its VM service on stdout, which carries the
// protocol. Release engines ignore these.
setenv("FLUTTER_ENGINE_SWITCHES", "1", 1)
setenv("FLUTTER_ENGINE_SWITCH_1", "disable-vm-service=true", 1)

let version = [
  helper.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
  helper.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
].compactMap { $0 }.joined(separator: "+")

let project = FlutterDartProject(precompiledDartBundle: dart)
project.dartEntrypointArguments = [version.isEmpty ? "dev" : version] + CommandLine.arguments.dropFirst()
let engine = FlutterEngine(name: "qima-mcp", project: project, allowHeadlessExecution: true)
guard engine.run(withEntrypoint: "mcpMain") else {
  fail("the Flutter engine did not start.")
}
// The Dart side exits the process when the AI app closes stdin.
RunLoop.main.run()
