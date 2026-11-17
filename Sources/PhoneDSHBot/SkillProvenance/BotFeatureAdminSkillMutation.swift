// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// One user-driven feature-admin skill mutation. This is not a model tool and
/// never carries a chat session: the App's settings page is the actor.
public enum BotFeatureAdminSkillMutationAction: String, Codable, Sendable, Equatable {
    case write
    case delete
}

public enum BotFeatureAdminSkillMutationStatus: String, Codable, Sendable, Equatable {
    case requested
    case applied
    case failed
}

public enum BotFeatureAdminSkillMutationError: Error, Equatable, Sendable {
    case invalidRequest(String)
    case unavailable(String)
    case unknownOperation
    case alreadyApplied
    case fileMismatch
    case fileStillPresent
    case appendFailed
}

/// The one queue seam this adapter needs. The composition injects the current
/// user-dsh queue/router; tests inject a fake. `emit` records the single
/// `skill.changed` for the operation after the applied fact exists.
public struct BotFeatureAdminSkillMutationQueue: Sendable {
    public typealias Ready = @Sendable () -> Bool
    public typealias Suppress = @Sendable (_ file: String, _ action: String,
                                           _ operationID: String) -> Void
    public typealias Clear = @Sendable (_ operationID: String) -> Void
    public typealias Emit = @Sendable (_ file: String,
                                       _ action: BotFeatureAdminSkillMutationAction,
                                       _ requestRecord: String,
                                       _ appliedRecord: String) async -> Bool

    public var ready: Ready
    public var suppress: Suppress
    public var clear: Clear
    public var emit: Emit

    public init(ready: @escaping Ready, suppress: @escaping Suppress,
                clear: @escaping Clear, emit: @escaping Emit) {
        self.ready = ready
        self.suppress = suppress
        self.clear = clear
        self.emit = emit
    }
}

/// The HTTP route's one operation. Implemented by the recorder and faked in
/// tests; the server never treats this as a model tool.
public protocol BotFeatureAdminSkillMutationServing: Sendable {
    func handle(_ body: BotJSONValue) async -> BotJSONValue
}

/// Append-only raw records for a feature-admin skill write/delete.
///
/// Order is fixed by G-FAM-2:
/// 1. append `requested` (recoverable bounded content, hash/bytes bind it),
/// 2. suppress the user-dsh observer for this operation/file,
/// 3. the plugin performs the atomic file mutation,
/// 4. append `applied` (success) or `failed` (bounded code),
/// 5. only an applied fact may inject one `skill.changed` with the applied
///    record as `basis` (the request record remains the raw-input evidence).
///
/// No second store, no model catalog entry and no fabricated chat turn.
public actor BotFeatureAdminSkillMutationRecorder: BotFeatureAdminSkillMutationServing {
    public static let eventType = "feature-admin.skill_mutation"
    public static let schema = "phone-skill-mutation/v2"
    public static let maximumContentBytes = 65_536
    public static let maximumPendingOperations = 32
    public static let operationTTLMS: Int64 = 60_000

    private struct BeginRequest: Sendable, Equatable {
        var operationID: String
        var action: BotFeatureAdminSkillMutationAction
        var file: String
        var content: String
        var contentSHA256: String
        var bytes: Int
    }

    private struct Pending: Sendable, Equatable {
        var request: BeginRequest
        var requestRecord: String
        var createdAtMS: Int64
    }

    private struct Completed: Sendable, Equatable {
        var request: BeginRequest
        var requestRecord: String
        var appliedRecord: String
        var atMS: Int64
        /// True only when the real producer returned a recorded skill change.
        /// A true value forbids a second emit for the same operation; a false
        /// value is the one bounded repair retry.
        var skillEventEmitted: Bool
    }

    private let eventLog: any BotEventLog
    private let userSkillsRoot: URL
    private let queue: BotFeatureAdminSkillMutationQueue
    private let now: @Sendable () -> Int64
    /// The Worker's VFS write ACK can precede the host materializer. The
    /// applied fact waits a bounded number of polls for the real file, never
    /// infinite and never a silent trust of the Worker's bytes.
    private let fileVerificationAttempts: Int
    private let fileVerificationDelayNanoseconds: UInt64
    private var pending: [String: Pending] = [:]
    private var completed: [String: Completed] = [:]
    /// One applied call per operation at a time. Actor reentrancy at the
    /// queue await must not append/emit the same operation twice.
    private var appliedInFlight: Set<String> = []

    /// Tests can prove that a failed write never registers suppression.
    private(set) var suppressionRegistrations = 0

    public init(eventLog: any BotEventLog,
                userSkillsRoot: URL,
                queue: BotFeatureAdminSkillMutationQueue,
                now: @escaping @Sendable () -> Int64 = {
                    Int64(Date().timeIntervalSince1970 * 1_000)
                },
                fileVerificationAttempts: Int = 60,
                fileVerificationDelayNanoseconds: UInt64 = 50_000_000) {
        self.eventLog = eventLog
        self.userSkillsRoot = userSkillsRoot.standardizedFileURL
        self.queue = queue
        self.now = now
        self.fileVerificationAttempts = max(1, fileVerificationAttempts)
        self.fileVerificationDelayNanoseconds = fileVerificationDelayNanoseconds
    }

    // MARK: - route

    public func handle(_ body: BotJSONValue) async -> BotJSONValue {
        guard let object = body.optionalObject else {
            return Self.error("invalid-request", "mutation record body must be an object")
        }
        guard let op = object["op"]?.stringValue else {
            return Self.error("invalid-request", "mutation record body needs op")
        }
        switch op {
        case "begin":
            return await begin(object)
        case "applied":
            return await applied(object)
        case "failed":
            return await failed(object)
        default:
            return Self.error("invalid-request", "unknown mutation record op: \(op)")
        }
    }

    // MARK: - begin

    private func begin(_ object: [String: BotJSONValue]) async -> BotJSONValue {
        do {
            guard queue.ready() else {
                throw BotFeatureAdminSkillMutationError.unavailable(
                    "the user-dsh skill queue is not attached")
            }
            let request = try Self.decodeBegin(object)
            purgeExpired()
            guard pending.count < Self.maximumPendingOperations else {
                throw BotFeatureAdminSkillMutationError.unavailable(
                    "too many feature-admin skill operations are in flight")
            }
            if let existing = pending[request.operationID] {
                // A retried HTTP request returns the same durable requested
                // record and re-registers suppression for the same op.
                guard existing.request == request else {
                    throw BotFeatureAdminSkillMutationError.invalidRequest(
                        "operation_id was already used with different input")
                }
                queue.suppress(request.file, request.action.rawValue, request.operationID)
                suppressionRegistrations += 1
                return Self.ok(record: existing.requestRecord, operationID: request.operationID,
                               status: .requested)
            }
            if let done = completed[request.operationID] {
                guard done.request == request else {
                    throw BotFeatureAdminSkillMutationError.invalidRequest(
                        "operation_id was already used with different input")
                }
                return Self.ok(record: done.requestRecord, operationID: request.operationID,
                               status: .requested)
            }
            if request.action == .delete {
                try await verifyDeleteRequest(request)
            }
            let atMS = now()
            let seq = try await append(status: .requested, request: request,
                                       requestRecord: nil, failureCode: nil, atMS: atMS)
            let record = "record://event/\(seq)"
            pending[request.operationID] = Pending(
                request: request, requestRecord: record, createdAtMS: atMS)
            // Requested is durable before the file is touched; the observer
            // must not add a second event for this exact operation.
            queue.suppress(request.file, request.action.rawValue, request.operationID)
            suppressionRegistrations += 1
            return Self.ok(record: record, operationID: request.operationID, status: .requested)
        } catch let error as BotFeatureAdminSkillMutationError {
            return Self.error(error)
        } catch {
            return Self.error("append-failed",
                              "the requested raw record could not be appended: \(error)")
        }
    }

    // MARK: - applied

    private func applied(_ object: [String: BotJSONValue]) async -> BotJSONValue {
        do {
            let operationID = try Self.decodeOperationID(object)
            purgeExpired()
            guard !appliedInFlight.contains(operationID) else {
                return Self.error("operation-in-progress",
                                  "the same feature-admin operation is already being applied")
            }
            appliedInFlight.insert(operationID)
            defer { appliedInFlight.remove(operationID) }
            guard let entry = pending[operationID] else {
                if let done = completed[operationID] {
                    // The applied fact already exists. A completed operation
                    // that really emitted must not call the producer again:
                    // recordUserDshWrite would read the new latest and append a
                    // second revision. Only a previously failed emit gets one
                    // bounded repair attempt with the same applied record.
                    if done.skillEventEmitted {
                        return Self.ok(record: done.appliedRecord, operationID: operationID,
                                       status: .applied,
                                       extra: ["skill_event": .bool(true)])
                    }
                    let repaired = await queue.emit(done.request.file, done.request.action,
                                                    done.requestRecord, done.appliedRecord)
                    if repaired {
                        completed[operationID]?.skillEventEmitted = true
                    }
                    return Self.ok(record: done.appliedRecord, operationID: operationID,
                                   status: .applied,
                                   extra: ["skill_event": .bool(repaired)])
                }
                throw BotFeatureAdminSkillMutationError.unknownOperation
            }
            do {
                try await verifyApplied(entry.request)
            } catch let error as BotFeatureAdminSkillMutationError {
                // The real file does not match the requested bytes. Record a
                // bounded failure, release the one-shot observer suppression
                // and never emit a skill event.
                _ = try? await append(status: .failed, request: entry.request,
                                      requestRecord: entry.requestRecord,
                                      failureCode: Self.failureCode(error),
                                      atMS: now())
                pending.removeValue(forKey: operationID)
                queue.clear(operationID)
                return Self.error(error)
            }
            let atMS = now()
            let seq: Int
            do {
                seq = try await append(status: .applied, request: entry.request,
                                       requestRecord: entry.requestRecord,
                                       failureCode: nil, atMS: atMS)
            } catch {
                // File succeeded but applied did not append: no skill event,
                // no false current. Keep requested + file + bounded
                // suppression for an explicit repair; the TTL releases it.
                return Self.error("append-failed",
                                  "the applied raw record could not be appended; "
                                  + "the file is not indexed and no skill event was emitted")
            }
            let appliedRecord = "record://event/\(seq)"
            let emitted = await queue.emit(entry.request.file, entry.request.action,
                                           entry.requestRecord, appliedRecord)
            pending.removeValue(forKey: operationID)
            completed[operationID] = Completed(
                request: entry.request, requestRecord: entry.requestRecord,
                appliedRecord: appliedRecord, atMS: atMS,
                skillEventEmitted: emitted)
            // The observer consumes the one-shot suppression when it sees the
            // file change; if it never does, the queue's TTL removes it.
            return Self.ok(record: appliedRecord, operationID: operationID,
                           status: .applied,
                           extra: ["skill_event": .bool(emitted)])
        } catch let error as BotFeatureAdminSkillMutationError {
            return Self.error(error)
        } catch {
            return Self.error("append-failed", "the applied raw record could not be appended: \(error)")
        }
    }

    // MARK: - failed

    private func failed(_ object: [String: BotJSONValue]) async -> BotJSONValue {
        do {
            let operationID = try Self.decodeOperationID(object)
            let failureCode = try Self.decodeFailureCode(object)
            purgeExpired()
            if completed[operationID] != nil {
                throw BotFeatureAdminSkillMutationError.alreadyApplied
            }
            guard let entry = pending[operationID] else {
                // A retried failed call is idempotent; the requested record is
                // still the raw input, and no file operation is claimed.
                return Self.ok(record: nil, operationID: operationID, status: .failed)
            }
            let seq = try await append(status: .failed, request: entry.request,
                                       requestRecord: entry.requestRecord,
                                       failureCode: failureCode, atMS: now())
            pending.removeValue(forKey: operationID)
            queue.clear(operationID)
            return Self.ok(record: "record://event/\(seq)", operationID: operationID,
                           status: .failed)
        } catch let error as BotFeatureAdminSkillMutationError {
            return Self.error(error)
        } catch {
            return Self.error("append-failed", "the failed raw record could not be appended: \(error)")
        }
    }

    // MARK: - file verification

    private func verifyDeleteRequest(_ request: BeginRequest) async throws {
        let url = try targetURL(request.file)
        for attempt in 0..<fileVerificationAttempts {
            if let data = try? readRegularFile(url, file: request.file),
               data.count == request.bytes,
               Self.sha256Hex(data) == request.contentSHA256 {
                return
            }
            if attempt + 1 < fileVerificationAttempts {
                try? await Task.sleep(nanoseconds: fileVerificationDelayNanoseconds)
            }
        }
        throw BotFeatureAdminSkillMutationError.fileMismatch
    }

    private func verifyApplied(_ request: BeginRequest) async throws {
        let url = try targetURL(request.file)
        switch request.action {
        case .write:
            for attempt in 0..<fileVerificationAttempts {
                if let data = try? readRegularFile(url, file: request.file),
                   data.count == request.bytes,
                   Self.sha256Hex(data) == request.contentSHA256 {
                    return
                }
                if attempt + 1 < fileVerificationAttempts {
                    try? await Task.sleep(nanoseconds: fileVerificationDelayNanoseconds)
                }
            }
            throw BotFeatureAdminSkillMutationError.fileMismatch
        case .delete:
            for attempt in 0..<fileVerificationAttempts {
                if isStrictlyAbsent(url) { return }
                if attempt + 1 < fileVerificationAttempts {
                    try? await Task.sleep(nanoseconds: fileVerificationDelayNanoseconds)
                }
            }
            throw BotFeatureAdminSkillMutationError.fileStillPresent
        }
    }

    /// Strict ENOENT: a permission/IO failure is not a delete.
    private func isStrictlyAbsent(_ url: URL) -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return false
        } catch let error as NSError {
            return error.code == NSFileReadNoSuchFileError
                || error.code == NSFileNoSuchFileError
        }
    }

    private func targetURL(_ file: String) throws -> URL {
        guard Self.isFlatSkillFile(file) else {
            throw BotFeatureAdminSkillMutationError.invalidRequest(
                "skill file must be a flat kebab-case .md basename")
        }
        let root = userSkillsRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(file)
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.path + "/") else {
            throw BotFeatureAdminSkillMutationError.invalidRequest(
                "skill path escapes the user-dsh skills root")
        }
        return candidate
    }

    private func readRegularFile(_ url: URL, file: String) throws -> Data {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: keys)
        } catch {
            throw BotFeatureAdminSkillMutationError.fileMismatch
        }
        guard values.isSymbolicLink != true else {
            throw BotFeatureAdminSkillMutationError.invalidRequest(
                "skill path is a symbolic link and is refused: \(file)")
        }
        guard values.isRegularFile == true else {
            throw BotFeatureAdminSkillMutationError.fileMismatch
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw BotFeatureAdminSkillMutationError.fileMismatch
        }
        return data
    }

    // MARK: - event append

    private func append(status: BotFeatureAdminSkillMutationStatus,
                        request: BeginRequest, requestRecord: String?,
                        failureCode: String?, atMS: Int64) async throws -> Int {
        var data: [String: BotJSONValue] = [
            "schema": .string(Self.schema),
            "operation_id": .string(request.operationID),
            "status": .string(status.rawValue),
            "action": .string(request.action.rawValue),
            "file": .string(request.file),
            "content_sha256": .string(request.contentSHA256),
            "bytes": .number(Double(request.bytes)),
            "actor": .object(["kind": .string("user")]),
            "at_ms": .number(Double(atMS)),
            "surface": .string("phone-feature-admin"),
        ]
        if status == .requested {
            data["content"] = .string(request.content)
        }
        if let requestRecord {
            data["request_record"] = .string(requestRecord)
        }
        if let failureCode {
            data["failure_code"] = .string(failureCode)
        }
        let event = BotEvent(
            type: Self.eventType,
            eventId: "feature-admin.skill-mutation:\(request.operationID):\(status.rawValue)",
            time: atMS,
            origin: .local(source: "user"),
            traceId: "trace-feature-admin-skill-mutation:\(request.operationID)",
            principal: BotPrincipal(botId: nil, sessionId: nil, kind: "ipc"),
            causationId: nil, correlationId: nil, ignorable: true,
            data: .object(data))
        let seq = try await eventLog.append(event)
        guard seq >= 1 else { throw BotFeatureAdminSkillMutationError.appendFailed }
        return seq
    }

    // MARK: - decode / validate

    private static func decodeBegin(_ object: [String: BotJSONValue]) throws -> BeginRequest {
        guard let operationID = object["operation_id"]?.stringValue,
              isValidOperationID(operationID) else {
            throw BotFeatureAdminSkillMutationError.invalidRequest(
                "operation_id must be 1...128 safe characters")
        }
        guard let rawAction = object["action"]?.stringValue,
              let action = BotFeatureAdminSkillMutationAction(rawValue: rawAction) else {
            throw BotFeatureAdminSkillMutationError.invalidRequest(
                "action must be write or delete")
        }
        guard let file = object["file"]?.stringValue, isFlatSkillFile(file) else {
            throw BotFeatureAdminSkillMutationError.invalidRequest(
                "file must be a flat kebab-case .md basename")
        }
        guard let content = object["content"]?.stringValue else {
            throw BotFeatureAdminSkillMutationError.invalidRequest(
                "content must be the actual UTF-8 user input")
        }
        guard let hash = object["content_sha256"]?.stringValue, isLowercaseSHA256(hash) else {
            throw BotFeatureAdminSkillMutationError.invalidRequest(
                "content_sha256 must be 64 lowercase hex characters")
        }
        guard let bytes = object["bytes"]?.intValue, bytes >= 0,
              bytes <= maximumContentBytes else {
            throw BotFeatureAdminSkillMutationError.invalidRequest(
                "bytes must be within 0...\(maximumContentBytes)")
        }
        let data = Data(content.utf8)
        guard data.count == bytes else {
            throw BotFeatureAdminSkillMutationError.invalidRequest(
                "bytes does not match the UTF-8 content length")
        }
        guard sha256Hex(data) == hash else {
            throw BotFeatureAdminSkillMutationError.invalidRequest(
                "content_sha256 does not match the content")
        }
        return BeginRequest(operationID: operationID, action: action, file: file,
                            content: content, contentSHA256: hash, bytes: bytes)
    }

    private static func decodeOperationID(_ object: [String: BotJSONValue]) throws -> String {
        guard let operationID = object["operation_id"]?.stringValue,
              isValidOperationID(operationID) else {
            throw BotFeatureAdminSkillMutationError.invalidRequest(
                "operation_id must be 1...128 safe characters")
        }
        return operationID
    }

    private static func decodeFailureCode(_ object: [String: BotJSONValue]) throws -> String {
        guard let code = object["failure_code"]?.stringValue,
              !code.isEmpty, code.count <= 128 else {
            throw BotFeatureAdminSkillMutationError.invalidRequest(
                "failure_code must be a bounded non-empty string")
        }
        return code
    }

    private static func isValidOperationID(_ value: String) -> Bool {
        guard (1...128).contains(value.unicodeScalars.count) else { return false }
        return value.range(of: #"^[A-Za-z0-9._:-]+$"#, options: .regularExpression) != nil
    }

    private static func isFlatSkillFile(_ value: String) -> Bool {
        guard value.unicodeScalars.count <= 68,
              value.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*\.md$"#,
                          options: .regularExpression) != nil else { return false }
        return true
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy {
            ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f")
        }
    }

    private static func failureCode(_ error: BotFeatureAdminSkillMutationError) -> String {
        switch error {
        case .fileMismatch: return "file-mismatch"
        case .fileStillPresent: return "file-still-present"
        case .invalidRequest: return "invalid-request"
        case .unavailable: return "unavailable"
        case .unknownOperation: return "unknown-operation"
        case .alreadyApplied: return "already-applied"
        case .appendFailed: return "append-failed"
        }
    }

    // MARK: - retention

    private func purgeExpired() {
        let wall = now()
        let stalePending = pending.filter {
            wall - $0.value.createdAtMS > Self.operationTTLMS
        }.map { $0.key }
        for operationID in stalePending {
            pending.removeValue(forKey: operationID)
            queue.clear(operationID)
        }
        let staleCompleted = completed.filter {
            wall - $0.value.atMS > Self.operationTTLMS
        }.map { $0.key }
        for operationID in staleCompleted {
            completed.removeValue(forKey: operationID)
        }
    }

    // MARK: - replies

    private static func ok(record: String?,
                           operationID: String,
                           status: BotFeatureAdminSkillMutationStatus,
                           extra: [String: BotJSONValue] = [:]) -> BotJSONValue {
        var reply: [String: BotJSONValue] = [
            "ok": .bool(true),
            "operation_id": .string(operationID),
            "status": .string(status.rawValue),
        ]
        if let record { reply["record"] = .string(record) }
        for (key, value) in extra { reply[key] = value }
        return .object(reply)
    }

    private static func error(_ failure: BotFeatureAdminSkillMutationError) -> BotJSONValue {
        error(failureCode(failure), message(failure))
    }

    private static func error(_ code: String, _ reason: String) -> BotJSONValue {
        .object(["ok": .bool(false), "code": .string(code), "reason": .string(reason)])
    }

    private static func message(_ error: BotFeatureAdminSkillMutationError) -> String {
        switch error {
        case let .invalidRequest(reason), let .unavailable(reason): return reason
        case .unknownOperation: return "the feature-admin operation is not pending"
        case .alreadyApplied: return "the feature-admin operation already has an applied record"
        case .fileMismatch: return "the real skill file does not match the requested bytes"
        case .fileStillPresent: return "the skill file is still present after delete"
        case .appendFailed: return "the raw record could not be appended"
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension BotJSONValue {
    var optionalObject: [String: BotJSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }
}
