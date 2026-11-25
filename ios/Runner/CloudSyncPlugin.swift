#if os(macOS)
import FlutterMacOS
import Security
#else
import Flutter
#endif
import CloudKit
import Foundation

// This file is the same in `ios/Runner` and `macos/Runner`; keep the two
// copies alike and put what differs between the platforms under `#if`.

/// Stores the parts of the change log sync as records in the person's
/// private CloudKit database, for `lib/services/sync/cloudkit_sync_transport.dart`
/// over the channel "qima/cloud_sync". It stores text under names and knows
/// nothing of what the text means; the protocol is described on the Dart
/// class.
///
/// `CKContainer(identifier:)` raises an Objective-C exception, which ends
/// the app, when the build is not signed for the container. So nothing here
/// touches CloudKit until `isEntitled` has said yes: registering the plugin
/// only makes a channel, and without the entitlement `available` answers
/// false and every other call answers the error `unavailable`.
final class CloudSyncPlugin: NSObject, FlutterPlugin {
  static let containerIdentifier = "iCloud.com.devlabtechnologies.qima"

  private static let methods: Set<String> = ["available", "account", "store", "read", "list", "discard"]

  /// Made on the first call that needs it, and only in a build that may use
  /// the container.
  private lazy var zone: CloudSyncZone? = CloudSyncPlugin.isEntitled ? CloudSyncZone(containerIdentifier: CloudSyncPlugin.containerIdentifier) : nil

  static func register(with registrar: FlutterPluginRegistrar) {
    #if os(macOS)
    let messenger = registrar.messenger
    #else
    let messenger = registrar.messenger()
    #endif
    let channel = FlutterMethodChannel(name: "qima/cloud_sync", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(CloudSyncPlugin(), channel: channel)
  }

  /// Whether this build may use the container.
  ///
  /// macOS can ask the system for the entitlements the running process was
  /// signed with. iOS has no public call for that, and the provisioning
  /// profile is not inside an App Store build to be read, so there the
  /// answer is the Info.plist flag `QimaCloudSyncEnabled`, which must be set
  /// only together with the entitlement.
  private static let isEntitled: Bool = {
    #if os(macOS)
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    let services = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) as? [String] ?? []
    let containers = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String] ?? []
    return services.contains("CloudKit") && containers.contains(containerIdentifier)
    #else
    return Bundle.main.object(forInfoDictionaryKey: "QimaCloudSyncEnabled") as? Bool == true
    #endif
  }()

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard CloudSyncPlugin.methods.contains(call.method) else {
      result(FlutterMethodNotImplemented)
      return
    }
    let reply = CloudSyncReply(result)
    guard let zone = zone else {
      reply.send(call.method == "available" ? false : FlutterError(code: "unavailable", message: "This build is not signed for the iCloud container \(CloudSyncPlugin.containerIdentifier).", details: nil))
      return
    }
    let arguments = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "available":
      zone.accountAvailable { reply.send($0) }

    case "account":
      zone.accountName(done: reply.answer { $0 })

    case "store":
      guard let record = CloudSyncKind.record(arguments), let body = arguments["body"] as? String else {
        reply.send(CloudSyncPlugin.badArguments("store requires 'kind', 'name' and 'body'"))
        return
      }
      zone.store(type: record.type, name: record.name, body: body, done: reply.answer { $0 })

    case "read":
      guard let record = CloudSyncKind.record(arguments) else {
        reply.send(CloudSyncPlugin.badArguments("read requires 'kind' and 'name'"))
        return
      }
      zone.read(name: record.name, done: reply.answer { $0 })

    case "list":
      zone.list(done: reply.answer { CloudSyncKind.sorted($0) })

    default:
      var names: [String] = []
      for kind in CloudSyncKind.all {
        guard let given = arguments[kind.name] as? [String], !given.contains(where: { !CloudSyncKind.isRecordName(kind.prefix + $0) }) else {
          reply.send(CloudSyncPlugin.badArguments("discard requires a list of names for '\(kind.name)'"))
          return
        }
        names += given.map { kind.prefix + $0 }
      }
      zone.discard(names: names, done: reply.answer { _ in nil })
    }
  }

  private static func badArguments(_ message: String) -> FlutterError {
    return FlutterError(code: "bad_args", message: message, details: nil)
  }
}

/// Answers one call, on the main thread, and only the first time it is
/// asked to: Flutter must be given exactly one answer per call.
private final class CloudSyncReply {
  private var result: FlutterResult?

  init(_ result: @escaping FlutterResult) {
    self.result = result
  }

  func send(_ value: Any?) {
    DispatchQueue.main.async {
      guard let result = self.result else { return }
      self.result = nil
      result(value)
    }
  }

  /// What to hand a CloudKit call as its completion: a result is sent as
  /// `value` makes it, an error as a `FlutterError` with one of our codes.
  func answer<T>(_ value: @escaping (T) -> Any?) -> (Result<T, Error>) -> Void {
    return { outcome in
      switch outcome {
      case .success(let found): self.send(value(found))
      case .failure(let error): self.send(CloudSyncZone.flutterError(error))
      }
    }
  }
}

/// The two kinds of record. The record name is the name Dart gives with the
/// kind in front, so a batch and a snapshot can never share one.
private struct CloudSyncKind {
  let name: String
  let type: String
  var prefix: String { return name + "." }

  static let all = [CloudSyncKind(name: "batch", type: "SyncBatch"), CloudSyncKind(name: "snapshot", type: "SyncSnapshot")]

  /// CloudKit raises an exception for a record name it does not accept, so
  /// one is never made from a name that was not checked here.
  static func isRecordName(_ text: String) -> Bool {
    return !text.isEmpty && text.utf8.count <= 255 && !text.hasPrefix("_") && !text.utf8.contains(where: { $0 < 0x20 || $0 > 0x7e })
  }

  /// The record type and record name the arguments of a call name.
  static func record(_ arguments: [String: Any]) -> (type: String, name: String)? {
    guard let kind = all.first(where: { $0.name == arguments["kind"] as? String }), let name = arguments["name"] as? String, isRecordName(kind.prefix + name) else { return nil }
    return (kind.type, kind.prefix + name)
  }

  /// The records of a zone as the listing Dart reads: per kind the names
  /// without the kind in front, and under "other" the record names of
  /// whatever is not ours.
  static func sorted(_ types: [String: String]) -> [String: [String]] {
    var listing: [String: [String]] = ["other": []]
    for kind in all { listing[kind.name] = [] }
    for (recordName, type) in types {
      if let kind = all.first(where: { $0.type == type && recordName.hasPrefix($0.prefix) }) {
        listing[kind.name]?.append(String(recordName.dropFirst(kind.prefix.count)))
      } else {
        listing["other"]?.append(recordName)
      }
    }
    return listing
  }
}

/// The record names a listing has met so far, with their record types.
private final class CloudSyncNames {
  var types: [String: String] = [:]
}

/// The zone the records are kept in. Its public methods are called on the
/// main thread and call `done` there, once.
private final class CloudSyncZone {
  private static let bodyField = "body"
  private static let assetField = "asset"

  /// A record takes 1 MB in all. A body above this, in UTF-8, goes into a
  /// file beside the record instead; the parts the engine makes are about a
  /// quarter of it.
  private static let inlineLimit = 700 * 1024

  /// What `SyncWire.maxBodyBytes` is on the Dart side: more is not loaded.
  private static let readLimit = 16 * 1024 * 1024

  /// CloudKit takes at most 400 records in one request.
  private static let deleteChunk = 400

  /// A listing stops after this many pages and names what it has, so a
  /// server that never says it is done cannot hold a call for ever.
  private static let listPages = 1000

  private let container: CKContainer
  private let database: CKDatabase
  private let zoneID = CKRecordZone.ID(zoneName: "Book", ownerName: CKCurrentUserDefaultName)
  private let zoneReadyKey = "qima.cloudSync.zoneReady.Book"

  /// Whether the zone is known to be there, kept across starts so that only
  /// the very first call pays for making it.
  private var zoneReady: Bool
  private var zoneWaiters: [(Error?) -> Void] = []

  init(containerIdentifier: String) {
    container = CKContainer(identifier: containerIdentifier)
    database = container.privateCloudDatabase
    zoneReady = UserDefaults.standard.bool(forKey: zoneReadyKey)
  }

  // MARK: - What the channel asks for

  func accountAvailable(_ done: @escaping (Bool) -> Void) {
    container.accountStatus { status, _ in
      DispatchQueue.main.async { done(status == .available) }
    }
  }

  /// The record name of the signed-in user, the same on every device of the
  /// account. Fails like any call when nobody is signed in.
  func accountName(done: @escaping (Result<String, Error>) -> Void) {
    container.fetchUserRecordID { recordID, error in
      DispatchQueue.main.async {
        if let recordID = recordID {
          done(.success(recordID.recordName))
        } else {
          done(.failure(error ?? CKError(.notAuthenticated)))
        }
      }
    }
  }

  /// True when the record now holds `body`, false when it held other text.
  func store(type: String, name: String, body: String, again: Bool = true, done: @escaping (Result<Bool, Error>) -> Void) {
    withZone({ self.save(type: type, name: name, body: body, done: $0) }) { saved in
      guard case .failure(let error) = saved else {
        done(.success(true))
        return
      }
      guard CloudSyncZone.code(error) == .serverRecordChanged else {
        done(.failure(error))
        return
      }
      // The name is taken. What it holds decides the answer; it is never
      // written over.
      self.read(name: name) { held in
        switch held {
        case .failure(let error):
          done(.failure(error))
        case .success(.some(let text)):
          // Byte for byte: `==` on strings takes differently composed
          // characters for the same text.
          done(.success(text.utf8.elementsEqual(body.utf8)))
        case .success(.none):
          // It was removed in between, so the name is free: once more, and
          // then no further, or two devices could keep each other busy.
          if again {
            self.store(type: type, name: name, body: body, again: false, done: done)
          } else {
            done(.failure(error))
          }
        }
      }
    }
  }

  /// The body of the record, or nil when there is no such record.
  func read(name: String, done: @escaping (Result<String?, Error>) -> Void) {
    withZone({ self.fetch(name: name, done: $0) }, done: done)
  }

  /// Record name to record type, for every record in the zone.
  func list(done: @escaping (Result<[String: String], Error>) -> Void) {
    withZone({ finish in
      let found = CloudSyncNames()
      self.changes(after: nil, into: found, pagesLeft: CloudSyncZone.listPages) { finish($0.map { _ in found.types }) }
    }, done: done)
  }

  func discard(names: [String], done: @escaping (Result<Void, Error>) -> Void) {
    let ids = names.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
    withZone({ self.delete(ids[...], done: $0) }, done: done)
  }

  // MARK: - The zone

  /// Runs `work` once the zone is there and hands its result to `done` on
  /// the main thread. When CloudKit says the zone is gone (the person
  /// cleared the app's iCloud data, or signed in to another account), the
  /// zone is made again and `work` run a second time, and no more than that.
  private func withZone<T>(retried: Bool = false, _ work: @escaping (@escaping (Result<T, Error>) -> Void) -> Void, done: @escaping (Result<T, Error>) -> Void) {
    ensureZone { error in
      if let error = error {
        done(.failure(error))
        return
      }
      work { outcome in
        DispatchQueue.main.async {
          if case .failure(let error) = outcome, !retried, CloudSyncZone.isZoneMissing(error) {
            self.setZoneReady(false)
            self.withZone(retried: true, work, done: done)
          } else {
            done(outcome)
          }
        }
      }
    }
  }

  /// Calls back on the main thread once the zone is there, or with why it
  /// could not be made. Calls that come while it is being made wait for the
  /// one request.
  private func ensureZone(_ done: @escaping (Error?) -> Void) {
    if zoneReady {
      done(nil)
      return
    }
    zoneWaiters.append(done)
    if zoneWaiters.count > 1 { return }
    // Saving a zone that is there already succeeds and changes nothing.
    let operation = CKModifyRecordZonesOperation(recordZonesToSave: [CKRecordZone(zoneID: zoneID)], recordZoneIDsToDelete: nil)
    operation.modifyRecordZonesResultBlock = { result in
      DispatchQueue.main.async {
        var failure: Error?
        if case .failure(let error) = result { failure = error }
        if failure == nil { self.setZoneReady(true) }
        let waiters = self.zoneWaiters
        self.zoneWaiters = []
        for waiter in waiters { waiter(failure) }
      }
    }
    start(operation)
  }

  private func setZoneReady(_ ready: Bool) {
    zoneReady = ready
    UserDefaults.standard.set(ready, forKey: zoneReadyKey)
  }

  // MARK: - Requests. Their `done` is called on a CloudKit queue.

  private func start(_ operation: CKDatabaseOperation) {
    let configuration = CKOperation.Configuration()
    // At a lower priority CloudKit waits for a network instead of saying
    // that there is none, for up to a week; the engine is waiting for us.
    configuration.qualityOfService = .userInitiated
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 300
    operation.configuration = configuration
    database.add(operation)
  }

  private func save(type: String, name: String, body: String, done: @escaping (Result<Void, Error>) -> Void) {
    // Off the main thread: a large body is written to a file first.
    DispatchQueue.global(qos: .userInitiated).async {
      let record = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name, zoneID: self.zoneID))
      var file: URL?
      if body.utf8.count > CloudSyncZone.inlineLimit {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qima-sync-\(UUID().uuidString)")
        do {
          try Data(body.utf8).write(to: url, options: .atomic)
        } catch {
          done(.failure(error))
          return
        }
        record[CloudSyncZone.assetField] = CKAsset(fileURL: url)
        file = url
      } else {
        record[CloudSyncZone.bodyField] = body as NSString
      }
      self.modify(save: [record], delete: [], ignoring: nil) { outcome in
        if let file = file { try? FileManager.default.removeItem(at: file) }
        done(outcome)
      }
    }
  }

  private func delete(_ ids: ArraySlice<CKRecord.ID>, done: @escaping (Result<Void, Error>) -> Void) {
    if ids.isEmpty {
      done(.success(()))
      return
    }
    // A record that is gone already is what was asked for.
    modify(save: [], delete: Array(ids.prefix(CloudSyncZone.deleteChunk)), ignoring: .unknownItem) { outcome in
      if case .failure = outcome {
        done(outcome)
      } else {
        self.delete(ids.dropFirst(CloudSyncZone.deleteChunk), done: done)
      }
    }
  }

  /// Saves new records and deletes records. A save never replaces a record:
  /// one that is there already fails with `serverRecordChanged`. The first
  /// error of any record that is not `ignored` is the result.
  private func modify(save: [CKRecord], delete: [CKRecord.ID], ignoring ignored: CKError.Code?, done: @escaping (Result<Void, Error>) -> Void) {
    let operation = CKModifyRecordsOperation(recordsToSave: save, recordIDsToDelete: delete)
    operation.savePolicy = .ifServerRecordUnchanged
    // Each record on its own: one that cannot be deleted must not keep the
    // others.
    operation.isAtomic = false
    var failure: Error?
    let note: (Error) -> Void = { error in
      if failure == nil, ignored == nil || CloudSyncZone.code(error) != ignored { failure = error }
    }
    operation.perRecordSaveBlock = { _, result in
      if case .failure(let error) = result { note(error) }
    }
    operation.perRecordDeleteBlock = { _, result in
      if case .failure(let error) = result { note(error) }
    }
    operation.modifyRecordsResultBlock = { result in
      if failure == nil, case .failure(let error) = result { failure = CloudSyncZone.cause(of: error, ignoring: ignored) }
      done(failure.map { .failure($0) } ?? .success(()))
    }
    start(operation)
  }

  private func fetch(name: String, done: @escaping (Result<String?, Error>) -> Void) {
    let operation = CKFetchRecordsOperation(recordIDs: [CKRecord.ID(recordName: name, zoneID: zoneID)])
    operation.desiredKeys = [CloudSyncZone.bodyField, CloudSyncZone.assetField]
    var outcome: Result<String?, Error>?
    operation.perRecordResultBlock = { _, result in
      switch result {
      case .success(let record):
        // Here and not later: the file of an asset is only kept for as long
        // as the request runs.
        outcome = .success(CloudSyncZone.body(of: record))
      case .failure(let error):
        outcome = CloudSyncZone.code(error) == .unknownItem ? .success(nil) : .failure(error)
      }
    }
    operation.fetchRecordsResultBlock = { result in
      if let outcome = outcome {
        done(outcome)
      } else if case .failure(let error) = result {
        done(CloudSyncZone.cause(of: error, ignoring: .unknownItem).map { .failure($0) } ?? .success(nil))
      } else {
        // Not "there is no such record": nobody said so.
        done(.failure(CKError(.internalError)))
      }
    }
    start(operation)
  }

  /// The text a record holds. One that holds none, or more than is read, is
  /// handed over as text the engine finds unreadable and reports, like any
  /// other damaged body.
  private static func body(of record: CKRecord) -> String {
    if let text = record[bodyField] as? String { return text }
    guard let url = (record[assetField] as? CKAsset)?.fileURL else { return "a record without a body" }
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    if size > readLimit { return "a record of \(size) bytes" }
    guard let data = try? Data(contentsOf: url) else { return "a record whose body could not be read" }
    return String(decoding: data, as: UTF8.self)
  }

  /// Adds the records that changed after `token` to `found`, page by page.
  /// From no token that is every record there is. Only names are asked for,
  /// and no query is used: a query needs an index, which cannot be added to
  /// the production schema from here.
  private func changes(after token: CKServerChangeToken?, into found: CloudSyncNames, pagesLeft: Int, done: @escaping (Result<Void, Error>) -> Void) {
    let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
    configuration.previousServerChangeToken = token
    configuration.desiredKeys = []
    let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID], configurationsByRecordZoneID: [zoneID: configuration])
    operation.fetchAllChanges = false
    var next: CKServerChangeToken?
    var more = false
    var failure: Error?
    operation.recordWasChangedBlock = { id, result in
      // A record that could not be given is left out: a listing may name
      // less than there is, and the engine asks again.
      if case .success(let record) = result { found.types[id.recordName] = record.recordType }
    }
    operation.recordWithIDWasDeletedBlock = { id, _ in
      found.types[id.recordName] = nil
    }
    operation.recordZoneFetchResultBlock = { _, result in
      switch result {
      case .success(let page):
        next = page.serverChangeToken
        more = page.moreComing
      case .failure(let error):
        failure = error
      }
    }
    operation.fetchRecordZoneChangesResultBlock = { result in
      if failure == nil, case .failure(let error) = result { failure = error }
      if let failure = failure {
        done(.failure(failure))
      } else if more, pagesLeft > 1 {
        self.changes(after: next, into: found, pagesLeft: pagesLeft - 1, done: done)
      } else {
        done(.success(()))
      }
    }
    start(operation)
  }

  // MARK: - Errors

  private static func code(_ error: Error) -> CKError.Code? {
    return (error as? CKError)?.code
  }

  /// CloudKit wraps the errors of single records and zones in one "partial
  /// failure". This is the first of them that says something (not `ignored`,
  /// and not only that the request failed as a whole), the error itself when
  /// it wraps none, and nil when all it wraps is `ignored`.
  private static func cause(of error: Error, ignoring ignored: CKError.Code?) -> Error? {
    guard let wrapper = error as? CKError, wrapper.code == .partialFailure, let parts = wrapper.partialErrorsByItemID?.values, !parts.isEmpty else { return error }
    if let first = parts.first(where: { code($0) != .batchRequestFailed && (ignored == nil || code($0) != ignored) }) { return first }
    return parts.contains(where: { code($0) == .batchRequestFailed }) ? error : nil
  }

  private static func isZoneMissing(_ error: Error) -> Bool {
    let found = code(cause(of: error, ignoring: nil) ?? error)
    return found == .zoneNotFound || found == .userDeletedZone
  }

  /// An error as Dart reads it: one of a few codes, the system's words, and
  /// how long iCloud asked to be left alone when it said.
  static func flutterError(_ error: Error) -> FlutterError {
    let found = cause(of: error, ignoring: nil) ?? error
    let name: String
    switch code(found) {
    case .notAuthenticated?, .accountTemporarilyUnavailable?:
      name = "not_signed_in"
    case .networkUnavailable?, .networkFailure?, .serviceUnavailable?, .requestRateLimited?, .zoneBusy?, .serverResponseLost?:
      name = "network"
    case .quotaExceeded?:
      name = "quota"
    case .zoneNotFound?, .userDeletedZone?:
      name = "zone_missing"
    case .badContainer?, .missingEntitlement?:
      name = "unavailable"
    default:
      name = "other"
    }
    let wait = (found as? CKError)?.retryAfterSeconds
    return FlutterError(code: name, message: found.localizedDescription, details: wait.map { ["retryAfter": $0] })
  }
}
