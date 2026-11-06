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
    public let deadlineMS: Int64
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
    private let directory: URL
    private let lockPath: String
    private let lockFD: Int32
    private let encoder: JSONEncoder

    init(directory: URL) throws {
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

    private static func release(_ path: String) {
        ownershipLock.lock()
        ownedPaths.remove(path)
        ownershipLock.unlock()
    }

    deinit {
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
        var sessions: [String: String] = [:]
        for url in urls {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw DeviceTaskError.corruptJournal }
            let record: DeviceTaskRecord
            do { record = try JSONDecoder().decode(DeviceTaskRecord.self, from: Data(contentsOf: url)) }
            catch { throw DeviceTaskError.corruptJournal }
            let expectedID = Self.msgID(deviceID: record.deviceID, key: record.task.idempotencyKey)
            guard record.v == 1, validDeviceID(record.deviceID),
                  (try? DeviceTask.decode(encoder.encode(record.task))) == record.task,
                  record.fingerprint == (try? fingerprint(record.task)),
                  record.msgID == expectedID, record.requestID == "dev:" + expectedID,
                  url.lastPathComponent == expectedID + ".json", (1...4096).contains(record.seq),
                  (1...256).contains(record.sessionID.utf8.count), record.deadlineMS > 0,
                  (record.phase == .terminal) == (record.outcome != nil),
                  sequences[record.deviceID, default: []].insert(record.seq).inserted else { throw DeviceTaskError.corruptJournal }
            if let session = sessions[record.deviceID], session != record.sessionID { throw DeviceTaskError.corruptJournal }
            sessions[record.deviceID] = record.sessionID
            if let outcome = record.outcome {
                switch outcome {
                case .completed(let output, _): guard output.utf8.count <= 1024 else { throw DeviceTaskError.corruptJournal }
                case .failed(_, let message): guard message.utf8.count <= 256 else { throw DeviceTaskError.corruptJournal }
                }
            }
            result.append(record)
        }
        return result
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
