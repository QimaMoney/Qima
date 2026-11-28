import Foundation
import JavaScriptCore

// qima-mcp on the Mac: Qima's MCP server for AI apps, over stdio.
//
//     qima-mcp [--snapshot <path>]
//
// This program owns stdin, stdout and the files. Each line is answered by
// qima_mcp.js beside it in the bundle: Qima's own server (lib/mcp), compiled
// from bin/qima_mcp_js.dart, so the Mac gives the same answers as Windows
// and Linux. It is not a `dart compile exe` binary because the Mac App Store
// turns those away (Dart's runtime calls a private system function).
//
// It reads only the copy Qima writes when "Let AI apps read Qima" is on, and
// with "Let AI apps add transactions" on it leaves transactions in the
// folder beside that copy for the person to review in Qima.

/// Must match `SnapshotLocation.macAppGroup` and `SnapshotLocation.fileName`.
let appGroup = "ZS3A435WC2.com.devlabtechnologies.qima"
let snapshotName = "qima-ai-snapshot.json"

func fail(_ message: String, code: Int32) -> Never {
  FileHandle.standardError.write(Data("qima-mcp: \(message)\n".utf8))
  exit(code)
}

/// A sandboxed process is given its own container as its home folder; the
/// group container is under the real one.
func defaultSnapshot() -> String? {
  guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return nil }
  return "\(String(cString: dir))/Library/Group Containers/\(appGroup)/\(snapshotName)"
}

func systemMessage(_ error: Error) -> String {
  let e = error as NSError
  if let posix = e.userInfo[NSUnderlyingErrorKey] as? NSError, posix.domain == NSPOSIXErrorDomain {
    return String(cString: strerror(Int32(posix.code)))
  }
  return e.localizedDescription
}

var snapshot: String?
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
  switch argument {
  case "--snapshot" where !arguments.isEmpty:
    snapshot = arguments.popFirst()
  case "--version":
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
    let build = (info?["CFBundleVersion"] as? String).map { "+\($0)" } ?? ""
    print("qima-mcp \(version)\(build)")
    exit(0)
  case "--help", "-h":
    print("Usage: qima-mcp [--snapshot <path>]\nQima's MCP server for AI apps, over stdio.")
    exit(0)
  default:
    fail("unknown argument \(argument)", code: 64)
  }
}
guard let snapshotPath = snapshot ?? defaultSnapshot() else {
  fail("no default snapshot path on this system; pass --snapshot <path>.", code: 64)
}
let beside = URL(fileURLWithPath: snapshotPath).deletingLastPathComponent()

guard let script = Bundle.main.url(forResource: "qima_mcp", withExtension: "js"),
  let source = try? String(contentsOf: script, encoding: .utf8)
else { fail("qima_mcp.js is missing from the bundle.", code: 70) }

guard let context = JSContext() else { fail("the JavaScript engine did not start.", code: 70) }
// stdout carries protocol messages only; anything else goes to stderr.
context.exceptionHandler = { _, exception in
  FileHandle.standardError.write(Data("qima-mcp: \(exception?.toString() ?? "unknown error")\n".utf8))
}

var readProblem: String?
let host = JSValue(newObjectIn: context)!

let readSnapshot: @convention(block) () -> Any = {
  readProblem = nil
  guard FileManager.default.fileExists(atPath: snapshotPath) else { return NSNull() }
  do {
    return try String(contentsOfFile: snapshotPath, encoding: .utf8)
  } catch {
    readProblem = systemMessage(error)
    return NSNull()
  }
}
host.setObject(readSnapshot, forKeyedSubscript: "readSnapshot" as NSString)

let problem: @convention(block) () -> Any = { readProblem ?? NSNull() }
host.setObject(problem, forKeyedSubscript: "readProblem" as NSString)

let accepting: @convention(block) (String, String) -> Bool = { folder, marker in
  FileManager.default.fileExists(atPath: beside.appendingPathComponent(folder).appendingPathComponent(marker).path)
}
host.setObject(accepting, forKeyedSubscript: "accepting" as NSString)

/// One batch as Qima's import inbox lays it out: `<id>/<name>` and
/// `<id>/meta.json`, written under a dotted name and renamed once complete
/// so the app never reads half a batch.
let leaveFile: @convention(block) (String, String, String, String) -> Any = { folder, name, contents, meta in
  guard !name.isEmpty, name == (name as NSString).lastPathComponent, !name.hasPrefix(".") else {
    return "The file name is not a plain name."
  }
  var generator = SystemRandomNumberGenerator()
  let id = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
  let inbox = beside.appendingPathComponent(folder)
  let staging = inbox.appendingPathComponent(".\(id)")
  do {
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    try Data(contents.utf8).write(to: staging.appendingPathComponent(name))
    try Data(meta.utf8).write(to: staging.appendingPathComponent("meta.json"))
    try FileManager.default.moveItem(at: staging, to: inbox.appendingPathComponent(id))
    return NSNull()
  } catch {
    // If this fails too it stays under a dotted name, which Qima ignores.
    try? FileManager.default.removeItem(at: staging)
    return systemMessage(error)
  }
}
host.setObject(leaveFile, forKeyedSubscript: "leaveFile" as NSString)

context.setObject(host, forKeyedSubscript: "qimaHost" as NSString)
// The compiled script looks for the global object under this name.
context.evaluateScript("var self = this;")
context.evaluateScript(source, withSourceURL: script)
guard let answer = context.objectForKeyedSubscript("qimaHandleLine"), !answer.isUndefined else {
  fail("qima_mcp.js did not load.", code: 70)
}

while let line = readLine(strippingNewline: true) {
  guard let reply = answer.call(withArguments: [line]), reply.isString, let text = reply.toString() else { continue }
  FileHandle.standardOutput.write(Data("\(text)\n".utf8))
}
