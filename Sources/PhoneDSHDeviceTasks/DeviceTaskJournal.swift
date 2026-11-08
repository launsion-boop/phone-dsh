// SPDX-License-Identifier: MIT
import CryptoKit
import Darwin
import Foundation
import PhoneDSHAgentCore

public struct DeviceTaskRecord: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case received, accepted, running, terminal }
    public let v: Int
    public let deviceID: String
    public let task: DeviceTask
    public let fingerprint: String
    public let msgID: String
    public let requestID: String
    public let seq: UInt64
    public let sessionID: String
    public var phase: Phase
    public var deadlineMS: Int64
    public var outcome: DeviceTaskOutcome?

    enum CodingKeys: String, CodingKey {
        case v, task, fingerprint, seq, phase, outcome
        case deviceID = "device_id", msgID = "msg_id", requestID = "request_id"
        case sessionID = "session_id", deadlineMS = "deadline_ms"
    }

    /// The P07 uplink is derived from the authenticated journal identity,
    /// never from a device-supplied session or origin.
    var uplinkEnvelope: JSONValue {
        .object(["v": .number(1), "msg_id": .string(msgID), "device_id": .string(deviceID),
                 "session_id": .string(sessionID), "dir": .string("up"), "kind": .string("text"),
                 "origin": .string("device"), "seq": .number(Double(seq)), "text": .string(task.body.text)])
    }
}

/// One process holds this lock while it can accept or report device tasks.
/// Callers serialize operations through DeviceTaskExecutor.
final class DeviceTaskJournal: @unchecked Sendable {
    private static let ownershipLock = NSLock()
    private static var ownedPaths = Set<String>()
    // A scan must not open a hard link to any process-held journal lock.
    // Protect only bookkeeping under this lock, never filesystem operations.
    private static var pendingInitializers = 0
    private static var inspectionActive = false
    #if DEBUG
    // Test-only synchronization at real lifecycle boundaries; no I/O occurs
    // while the bookkeeping mutex is held.
    static var testAfterInitializationReservation: (() -> Void)?
    static var testBeforeOwnerClose: (() -> Void)?
    #endif
    private static let knownRecordMembers: Set<String> = [
        "v", "device_id", "task", "fingerprint", "msg_id", "request_id", "seq",
        "session_id", "phase", "deadline_ms", "outcome",
    ]
    private static let knownOutcomeMembers: Set<String> = ["kind", "output", "truncated", "failure_kind", "message"]
    private let directory: URL
    private let lockPath: String
    private let lockFD: Int32
    private let encoder: JSONEncoder

    init(directory: URL) throws {
        guard Self.beginInitialization() else { throw DeviceTaskError.deviceBusy }
        defer { Self.endInitialization() }
        #if DEBUG
        Self.testAfterInitializationReservation?()
        #endif
        self.directory = directory
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.standardizedFileURL.resolvingSymlinksInPath().path
        Self.ownershipLock.lock()
        let acquired = Self.ownedPaths.insert(path).inserted
        Self.ownershipLock.unlock()
        guard acquired else { throw DeviceTaskError.deviceBusy }
        let lock = Darwin.open(directory.appendingPathComponent(".lock").path, O_RDWR | O_CREAT, 0o600)
        guard lock >= 0 else {
            Self.release(path)
            throw DeviceTaskError.corruptJournal
        }
        guard Darwin.lockf(lock, F_TLOCK, 0) == 0 else {
            Darwin.close(lock)
            Self.release(path)
            throw DeviceTaskError.deviceBusy
        }
        lockFD = lock
        lockPath = path
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    private static func beginInitialization() -> Bool {
        ownershipLock.lock()
        defer { ownershipLock.unlock() }
        guard !inspectionActive else { return false }
        pendingInitializers += 1
        return true
    }

    private static func endInitialization() {
        ownershipLock.lock()
        pendingInitializers -= 1
        ownershipLock.unlock()
    }

    static func reserveInspection() -> Bool {
        ownershipLock.lock()
        defer { ownershipLock.unlock() }
        guard !inspectionActive, pendingInitializers == 0, ownedPaths.isEmpty else { return false }
        inspectionActive = true
        return true
    }

    static func releaseInspection() {
        ownershipLock.lock()
        inspectionActive = false
        ownershipLock.unlock()
    }

    private static func release(_ path: String) {
        ownershipLock.lock()
        ownedPaths.remove(path)
        ownershipLock.unlock()
    }

    deinit {
        #if DEBUG
        Self.testBeforeOwnerClose?()
        #endif
        Darwin.lockf(lockFD, F_ULOCK, 0)
        Darwin.close(lockFD)
        Self.release(lockPath)
    }

    static func msgID(deviceID: String, key: String) -> String {
        var bytes = Data(deviceID.utf8)
        bytes.append(0)
        bytes.append(contentsOf: key.utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func fingerprint(_ task: DeviceTask) throws -> String {
        SHA256.hash(data: try encoder.encode(task)).map { String(format: "%02x", $0) }.joined()
    }

    private func validDeviceID(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count), let first = value.utf8.first,
              (48...57).contains(first) || (65...90).contains(first) || (97...122).contains(first) else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [46, 95, 58, 45].contains($0) }
    }

    func records() throws -> [DeviceTaskRecord] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]).filter { $0.pathExtension == "json" }
        guard urls.count <= 4096 else { throw DeviceTaskError.corruptJournal }
        var result: [DeviceTaskRecord] = []
        var sequences: [String: Set<UInt64>] = [:]
        var taskIDs: [String: Set<String>] = [:]
        var sessions: [String: String] = [:]
        for url in urls {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw DeviceTaskError.corruptJournal }
            let record: DeviceTaskRecord
            let rawTask: DeviceTask
            do {
                let data = try Data(contentsOf: url)
                var raw = UniqueJSONKeys(data)
                guard let members = raw.rawRootMembers(capturing: ["task", "outcome"], enforcingUnique: Self.knownRecordMembers),
                      let taskData = members["task"] else { throw DeviceTaskError.corruptJournal }
                rawTask = try DeviceTask.decode(taskData)
                record = try JSONDecoder().decode(DeviceTaskRecord.self, from: data)
                if record.outcome != nil {
                    guard let outcomeData = members["outcome"] else { throw DeviceTaskError.corruptJournal }
                    var outcome = UniqueJSONKeys(outcomeData)
                    guard outcome.rawRootMembers(capturing: [], enforcingUnique: Self.knownOutcomeMembers) != nil else {
                        throw DeviceTaskError.corruptJournal
                    }
                }
            }
            catch { throw DeviceTaskError.corruptJournal }
            let expectedID = Self.msgID(deviceID: record.deviceID, key: record.task.idempotencyKey)
            guard record.v == 1, validDeviceID(record.deviceID),
                  rawTask == record.task,
                  record.fingerprint == (try? fingerprint(record.task)),
                  record.msgID == expectedID, record.requestID == "dev:" + expectedID,
                  url.lastPathComponent == expectedID + ".json", (1...4096).contains(record.seq),
                  (1...256).contains(record.sessionID.utf8.count), record.deadlineMS > 0,
                  (record.phase == .terminal) == (record.outcome != nil),
                  taskIDs[record.deviceID, default: []].insert(record.task.id).inserted,
                  sequences[record.deviceID, default: []].insert(record.seq).inserted else { throw DeviceTaskError.corruptJournal }
            if let session = sessions[record.deviceID], session != record.sessionID { throw DeviceTaskError.corruptJournal }
            sessions[record.deviceID] = record.sessionID
            if let outcome = record.outcome {
                guard outcome.isTransportSafe else { throw DeviceTaskError.corruptJournal }
            }
            result.append(record)
        }
        try inventoryBLEIntents(parents: result)
        try inventoryBLESecureIntents(parents: result)
        return result
    }

    /// Verify all persisted Link intents before any task can be used. The
    /// journal lock is already held; inventory is strictly read-only.
    private func inventoryBLEIntents(parents: [DeviceTaskRecord]) throws {
        let ops = directory.appendingPathComponent("ble-ops", isDirectory: true)
        var metadata = stat()
        if Darwin.lstat(ops.path, &metadata) != 0 {
            if errno == ENOENT { return }
            throw DeviceTaskError.corruptJournal
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR else { throw DeviceTaskError.corruptJournal }
        let directoryFD = Darwin.open(ops.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw DeviceTaskError.corruptJournal }
        defer { Darwin.close(directoryFD) }
        let streamFD = Darwin.dup(directoryFD)
        guard streamFD >= 0 else { throw DeviceTaskError.corruptJournal }
        guard let stream = Darwin.fdopendir(streamFD) else {
            Darwin.close(streamFD)
            throw DeviceTaskError.corruptJournal
        }
        defer { Darwin.closedir(stream) }
        let byID = Dictionary(uniqueKeysWithValues: parents.map { ($0.msgID, $0) })
        let keys: Set<String> = ["v", "msg_id", "device_id", "task_id", "action", "request_id", "idem_key", "arguments_sha256"]
        var count = 0
        while true {
            errno = 0
            guard let entry = Darwin.readdir(stream) else {
                guard errno == 0 else { throw DeviceTaskError.corruptJournal }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            count += 1
            guard count <= 12288 else { throw DeviceTaskError.corruptJournal }
            let fd = Darwin.openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw DeviceTaskError.corruptJournal }
            let data: Data
            do {
                defer { Darwin.close(fd) }
                var info = stat()
                guard Darwin.fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                      info.st_size >= 0, info.st_size <= 65536 else { throw DeviceTaskError.corruptJournal }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                var buffer = Data()
                while buffer.count <= 65536 {
                    let chunk = try handle.read(upToCount: 65537 - buffer.count) ?? Data()
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                }
                guard buffer.count <= 65536, buffer.count == info.st_size else { throw DeviceTaskError.corruptJournal }
                data = buffer
            } catch { throw DeviceTaskError.corruptJournal }
            var unique = UniqueJSONKeys(data)
            guard unique.check(),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == keys,
                  let intent = try? JSONDecoder().decode(BLETaskIntent.self, from: data),
                  let parent = byID[intent.msgID],
                  name == intent.msgID + "-" + intent.action.rawValue + ".json" else {
                throw DeviceTaskError.corruptJournal
            }
            let arguments = try canonicalBLEArguments(record: parent, action: intent.action)
            guard let expected = try? BLETaskIntent.make(record: parent, action: intent.action, arguments: arguments),
                  intent == expected else { throw DeviceTaskError.corruptJournal }
        }
    }

    private func canonicalBLEArguments(record: DeviceTaskRecord, action: BLETaskIntent.Action) throws -> JSONValue {
        switch action {
        case .accept:
            return .object(["id": .string(record.task.id)])
        case .complete:
            guard record.phase == .terminal, case .completed(let output, let truncated) = record.outcome else {
                throw DeviceTaskError.corruptJournal
            }
            return .object(["id": .string(record.task.id), "output": .string(output), "truncated": .bool(truncated)])
        case .fail:
            guard record.phase == .terminal, case .failed(let kind, let message) = record.outcome else {
                throw DeviceTaskError.corruptJournal
            }
            return .object(["id": .string(record.task.id), "failure": .object(["kind": .string(kind.rawValue), "message": .string(message)])])
        }
    }

    /// Reads every entry of an intent directory under the journal lock: a real
    /// directory (absent = empty), at most 12288 regular non-symlink files of at
    /// most 65536 bytes. Any other entry fails the whole inventory closed.
    private func readIntentDirectory(_ name: String) throws -> [(String, Data)] {
        let ops = directory.appendingPathComponent(name, isDirectory: true)
        var metadata = stat()
        if Darwin.lstat(ops.path, &metadata) != 0 {
            if errno == ENOENT { return [] }
            throw DeviceTaskError.corruptJournal
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR else { throw DeviceTaskError.corruptJournal }
        let directoryFD = Darwin.open(ops.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw DeviceTaskError.corruptJournal }
        defer { Darwin.close(directoryFD) }
        let streamFD = Darwin.dup(directoryFD)
        guard streamFD >= 0 else { throw DeviceTaskError.corruptJournal }
        guard let stream = Darwin.fdopendir(streamFD) else {
            Darwin.close(streamFD)
            throw DeviceTaskError.corruptJournal
        }
        defer { Darwin.closedir(stream) }
        var out: [(String, Data)] = []
        while true {
            errno = 0
            guard let entry = Darwin.readdir(stream) else {
                guard errno == 0 else { throw DeviceTaskError.corruptJournal }
                break
            }
            let entryName = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if entryName == "." || entryName == ".." { continue }
            guard out.count < 12288 else { throw DeviceTaskError.corruptJournal }
            let fd = Darwin.openat(directoryFD, entryName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw DeviceTaskError.corruptJournal }
            defer { Darwin.close(fd) }
            var info = stat()
            guard Darwin.fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size >= 0, info.st_size <= 65536 else { throw DeviceTaskError.corruptJournal }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            var buffer = Data()
            do {
                while buffer.count <= 65536 {
                    let chunk = try handle.read(upToCount: 65537 - buffer.count) ?? Data()
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                }
            } catch { throw DeviceTaskError.corruptJournal }
            guard buffer.count <= 65536, buffer.count == info.st_size else { throw DeviceTaskError.corruptJournal }
            out.append((entryName, buffer))
        }
        return out
    }

    /// secure-session-v1 §9.2: inventory `ble-secure-ops` with the legacy
    /// rules. Each intent names exactly one validated parent of the same
    /// secure device ID; its hash is re-derived from the parent alone.
    private func inventoryBLESecureIntents(parents: [DeviceTaskRecord]) throws {
        let byID = Dictionary(uniqueKeysWithValues: parents.map { ($0.msgID, $0) })
        for (name, data) in try readIntentDirectory("ble-secure-ops") {
            let intent = try BLESecureTaskIntent.decode(data)
            guard let parent = byID[intent.msgID], parent.deviceID == intent.deviceID,
                  name == intent.fileName else { throw DeviceTaskError.corruptJournal }
            let arguments = try BLESecureTransitionArguments.reconstruct(record: parent, action: intent.action)
            guard let expected = try? BLESecureTaskIntent.make(deviceID: parent.deviceID, phoneID: intent.phoneID, arguments: arguments),
                  intent == expected else { throw DeviceTaskError.corruptJournal }
        }
    }

    /// secure-session-v1 §9.2. Runs under the owning journal lock. `fresh` is
    /// true only in the call that durably installed the intent; otherwise the
    /// pre-existing intent (never rewritten, possibly of an older phone key)
    /// is returned and the caller must reconcile with `status` first (§9.3).
    func prepareBLESecureTransition(record: DeviceTaskRecord, phoneID: String,
                                    arguments: BLESecureTransitionArguments) throws -> (intent: BLESecureTaskIntent, fresh: Bool) {
        guard BLESecureTaskIntent.isSecureDeviceID(record.deviceID),
              try find(deviceID: record.deviceID, key: record.task.idempotencyKey) == record else {
            throw DeviceTaskError.corruptJournal
        }
        guard try BLESecureTransitionArguments.reconstruct(record: record, action: arguments.action) == arguments else {
            throw DeviceTaskError.corruptJournal
        }
        let intent = try BLESecureTaskIntent.make(deviceID: record.deviceID, phoneID: phoneID, arguments: arguments)
        let ops = directory.appendingPathComponent("ble-secure-ops", isDirectory: true)
        try FileManager.default.createDirectory(at: ops, withIntermediateDirectories: true)
        let opsValues = try ops.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard opsValues.isDirectory == true, opsValues.isSymbolicLink != true else { throw DeviceTaskError.corruptJournal }
        let file = ops.appendingPathComponent(intent.fileName)
        if FileManager.default.fileExists(atPath: file.path) {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw DeviceTaskError.corruptJournal }
            let saved = try BLESecureTaskIntent.decode(try Data(contentsOf: file))
            let sameKey = try BLESecureTaskIntent.make(deviceID: record.deviceID, phoneID: saved.phoneID, arguments: arguments)
            guard saved == sameKey else { throw DeviceTaskError.corruptJournal }
            return (saved, false)
        }
        try encoder.encode(intent).write(to: file, options: .atomic)
        let handle = try FileHandle(forWritingTo: file)
        try handle.synchronize()
        try handle.close()
        for path in [ops, directory] {
            let fd = Darwin.open(path.path, O_RDONLY)
            guard fd >= 0 else { throw DeviceTaskError.corruptJournal }
            let result = Darwin.fsync(fd)
            Darwin.close(fd)
            guard result == 0 else { throw DeviceTaskError.corruptJournal }
        }
        return (intent, true)
    }

    func find(deviceID: String, key: String) throws -> DeviceTaskRecord? {
        guard validDeviceID(deviceID) else { throw DeviceTaskError.invalidDeviceIdentity }
        return try records().first { $0.deviceID == deviceID && $0.task.idempotencyKey == key }
    }

    func create(deviceID: String, task: DeviceTask, sessionID: String, now: Date) throws -> DeviceTaskRecord {
        guard validDeviceID(deviceID) else { throw DeviceTaskError.invalidDeviceIdentity }
        guard (1...256).contains(sessionID.utf8.count), (try? DeviceTask.decode(encoder.encode(task))) == task else { throw DeviceTaskError.invalidTask }
        let all = try records()
        if let existing = all.first(where: { $0.deviceID == deviceID && $0.task.idempotencyKey == task.idempotencyKey }) {
            guard existing.fingerprint == (try fingerprint(task)) else { throw DeviceTaskError.idempotencyConflict }
            return existing
        }
        guard !all.contains(where: { $0.deviceID == deviceID && $0.task.id == task.id }) else {
            throw DeviceTaskError.idempotencyConflict
        }
        guard all.filter({ $0.deviceID == deviceID }).allSatisfy({ $0.sessionID == sessionID }) else { throw DeviceTaskError.corruptJournal }
        guard all.count < 4096 else { throw DeviceTaskError.storageFull }
        let previous = all.filter { $0.deviceID == deviceID }.map(\.seq).max() ?? 0
        guard previous < UInt64.max else { throw DeviceTaskError.storageFull }
        let id = Self.msgID(deviceID: deviceID, key: task.idempotencyKey)
        let deadline = min(task.deadlineDate ?? now.addingTimeInterval(300), now.addingTimeInterval(300))
        let record = DeviceTaskRecord(v: 1, deviceID: deviceID, task: task,
                                      fingerprint: try fingerprint(task), msgID: id,
                                      requestID: "dev:" + id, seq: previous + 1,
                                      sessionID: sessionID, phase: .received,
                                      deadlineMS: Int64(deadline.timeIntervalSince1970 * 1000), outcome: nil)
        try save(record)
        return record
    }

    /// This method runs under the owning journal lock. `fresh` is true only in
    /// the call which durably created the intent; every later call must query.
    func prepareBLETransition(record: DeviceTaskRecord, action: BLETaskIntent.Action,
                              arguments: JSONValue) throws -> (intent: BLETaskIntent, fresh: Bool) {
        guard try find(deviceID: record.deviceID, key: record.task.idempotencyKey) == record else {
            throw DeviceTaskError.corruptJournal
        }
        guard try canonicalBLEArguments(record: record, action: action) == arguments else {
            throw DeviceTaskError.corruptJournal
        }
        let intent = try BLETaskIntent.make(record: record, action: action, arguments: arguments)
        let ops = directory.appendingPathComponent("ble-ops", isDirectory: true)
        try FileManager.default.createDirectory(at: ops, withIntermediateDirectories: true)
        let opsValues = try ops.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard opsValues.isDirectory == true, opsValues.isSymbolicLink != true else { throw DeviceTaskError.corruptJournal }
        let file = ops.appendingPathComponent(intent.msgID + "-" + action.rawValue + ".json")
        if FileManager.default.fileExists(atPath: file.path) {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw DeviceTaskError.corruptJournal }
            let data = try Data(contentsOf: file)
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard Set(object?.keys.map { $0 } ?? []) == Set(["v", "msg_id", "device_id", "task_id", "action", "request_id", "idem_key", "arguments_sha256"]),
                  let saved = try? JSONDecoder().decode(BLETaskIntent.self, from: data),
                  saved == intent else { throw DeviceTaskError.corruptJournal }
            return (saved, false)
        }
        try encoder.encode(intent).write(to: file, options: .atomic)
        let handle = try FileHandle(forWritingTo: file)
        try handle.synchronize()
        try handle.close()
        for path in [ops, directory] {
            let fd = Darwin.open(path.path, O_RDONLY)
            guard fd >= 0 else { throw DeviceTaskError.corruptJournal }
            let result = Darwin.fsync(fd)
            Darwin.close(fd)
            guard result == 0 else { throw DeviceTaskError.corruptJournal }
        }
        return (intent, true)
    }

    func save(_ record: DeviceTaskRecord) throws {
        let target = directory.appendingPathComponent(record.msgID + ".json")
        try encoder.encode(record).write(to: target, options: .atomic)
        let handle = try FileHandle(forWritingTo: target)
        try handle.synchronize()
        try handle.close()
        for path in [directory, directory.deletingLastPathComponent()] {
            let fd = Darwin.open(path.path, O_RDONLY)
            guard fd >= 0 else { throw DeviceTaskError.corruptJournal }
            let result = Darwin.fsync(fd)
            Darwin.close(fd)
            guard result == 0 else { throw DeviceTaskError.corruptJournal }
        }
    }
}
