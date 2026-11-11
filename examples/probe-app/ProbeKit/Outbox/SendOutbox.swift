// SPDX-License-Identifier: MIT
// Durable send outbox (P06, W1-C; spec/host/v1/README.md section 10).
//
// Enqueue is the durable fact: one `<rpcId>.json` file is written with the
// atomic order temp → fsync → rename → directory fsync before any transport
// attempt. `rpcId` is a lowercase UUIDv4 generated at enqueue and is the only
// idempotency key for delivery. The file is removed only after an authoritative
// history contains a `user/message` with that `source.rpcId` and the entry has
// reached `durable`.
//
// The state machine is fixed:
//   queued → submitting → accepted → durable
//   submitting → outcomeUnknown
//   outcomeUnknown → accepted (read-back found it)
//   outcomeUnknown → queued (read-back proved it absent)
// `durable` is never stored as a resting state: the file is deleted instead.
// A transport interruption never triggers an automatic resend.

import Foundation
import Darwin

public enum SendOutboxState: String, Codable, CaseIterable, Sendable {
    case queued
    case submitting
    case accepted
    case durable
    case outcomeUnknown
}

public enum SendOutboxBackend: String, Codable, CaseIterable, Sendable {
    case local
    case pc
}

public struct SendOutboxEntry: Codable, Equatable, Sendable {
    public var v: Int
    public var rpcId: String
    public var sessionId: String
    public var text: String
    public var createdAtMs: Int64
    public var state: SendOutboxState
    public var attempts: Int
    public var lastError: String?
    public var acceptedAtMs: Int64?
    public var durableAtMs: Int64?
    public var outcomeUnknownAtMs: Int64?
    public var backend: SendOutboxBackend?

    public init(v: Int = 1, rpcId: String, sessionId: String, text: String,
                createdAtMs: Int64, state: SendOutboxState, attempts: Int,
                lastError: String? = nil, acceptedAtMs: Int64? = nil,
                durableAtMs: Int64? = nil, outcomeUnknownAtMs: Int64? = nil,
                backend: SendOutboxBackend? = nil) {
        self.v = v
        self.rpcId = rpcId
        self.sessionId = sessionId
        self.text = text
        self.createdAtMs = createdAtMs
        self.state = state
        self.attempts = attempts
        self.lastError = lastError
        self.acceptedAtMs = acceptedAtMs
        self.durableAtMs = durableAtMs
        self.outcomeUnknownAtMs = outcomeUnknownAtMs
        self.backend = backend
    }
}

public enum SendOutboxError: Error, Equatable, CustomStringConvertible {
    case invalidRpcId
    case invalidSessionId
    case emptyText
    case textTooLong
    case unknownEntry
    case illegalTransition(from: SendOutboxState, to: SendOutboxState)
    case deleteRequiresDurable(SendOutboxState)
    case storage(String)

    public var description: String {
        switch self {
        case .invalidRpcId: return "rpcId is not a lowercase UUIDv4"
        case .invalidSessionId: return "sessionId is invalid"
        case .emptyText: return "text is empty"
        case .textTooLong: return "text exceeds 1000000 characters"
        case .unknownEntry: return "outbox entry does not exist"
        case let .illegalTransition(from, to):
            return "illegal outbox transition \(from.rawValue) → \(to.rawValue)"
        case let .deleteRequiresDurable(state):
            return "outbox entry is \(state.rawValue), not durable"
        case let .storage(message): return "outbox storage failed: \(message)"
        }
    }
}

/// The allowed edges of spec/host/v1/README.md section 10. Exposed so the host
/// and tests share one table instead of re-deriving it.
public enum SendOutboxTransition {
    public static func allows(from: SendOutboxState, to: SendOutboxState) -> Bool {
        switch (from, to) {
        case (.queued, .submitting),
             (.submitting, .accepted),
             (.submitting, .outcomeUnknown),
             (.accepted, .durable),
             (.outcomeUnknown, .accepted),
             (.outcomeUnknown, .queued):
            return true
        default:
            return false
        }
    }
}

/// One thread-safe durable queue. The actor serializes every file operation;
/// callers never read or write the directory directly.
public actor SendOutbox {
    public let directory: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL) {
        self.directory = directory
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    // MARK: - Enqueue

    @discardableResult
    public func enqueue(sessionID: String, text: String,
                        backend: SendOutboxBackend = .local,
                        rpcId: String? = nil,
                        now: Date = Date()) throws -> SendOutboxEntry {
        try Self.validate(sessionID: sessionID, text: text)
        if let rpcId, !Self.isValidRpcId(rpcId) { throw SendOutboxError.invalidRpcId }
        let entry = SendOutboxEntry(
            rpcId: rpcId ?? UUID().uuidString.lowercased(),
            sessionId: sessionID,
            text: text,
            createdAtMs: Int64((now.timeIntervalSince1970 * 1_000).rounded()),
            state: .queued,
            attempts: 0,
            backend: backend)
        try write(entry)
        return entry
    }

    // MARK: - Reading

    /// Every entry that still has a file, ordered by `createdAtMs` then rpcId.
    public func entries() -> [SendOutboxEntry] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        var result: [SendOutboxEntry] = []
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let entry = try? decoder.decode(SendOutboxEntry.self, from: data),
                  entry.v == 1 else { continue }
            result.append(entry)
        }
        return result.sorted {
            if $0.createdAtMs != $1.createdAtMs { return $0.createdAtMs < $1.createdAtMs }
            return $0.rpcId < $1.rpcId
        }
    }

    public func entry(rpcId: String) -> SendOutboxEntry? {
        guard let data = try? Data(contentsOf: fileURL(rpcId)) else { return nil }
        return try? decoder.decode(SendOutboxEntry.self, from: data)
    }

    /// Entries a startup scan or a drain must resume, oldest first. `durable`
    /// is never returned: that state deletes the file.
    public func pending(sessionID: String? = nil) -> [SendOutboxEntry] {
        entries().filter { entry in
            guard entry.state == .queued || entry.state == .submitting
                || entry.state == .outcomeUnknown || entry.state == .accepted else {
                return false
            }
            return sessionID == nil || entry.sessionId == sessionID
        }
    }

    // MARK: - Transitions

    @discardableResult
    public func markSubmitting(rpcId: String, now: Date = Date()) throws -> SendOutboxEntry {
        try transition(rpcId, to: .submitting, now: now) { entry in
            entry.attempts += 1
        }
    }

    @discardableResult
    public func markAccepted(rpcId: String, now: Date = Date()) throws -> SendOutboxEntry {
        try transition(rpcId, to: .accepted, now: now) { entry in
            if entry.acceptedAtMs == nil {
                entry.acceptedAtMs = Int64((now.timeIntervalSince1970 * 1_000).rounded())
            }
            entry.lastError = nil
        }
    }

    @discardableResult
    public func markDurable(rpcId: String, now: Date = Date()) throws -> SendOutboxEntry {
        try transition(rpcId, to: .durable, now: now) { entry in
            entry.durableAtMs = Int64((now.timeIntervalSince1970 * 1_000).rounded())
        }
    }

    @discardableResult
    public func markOutcomeUnknown(rpcId: String, lastError: String,
                                   now: Date = Date()) throws -> SendOutboxEntry {
        try transition(rpcId, to: .outcomeUnknown, now: now) { entry in
            entry.lastError = String(lastError.prefix(1_024))
            entry.outcomeUnknownAtMs = Int64((now.timeIntervalSince1970 * 1_000).rounded())
        }
    }

    /// Read-back proved the message absent; the same rpcId may be submitted
    /// again. Never call this without that proof.
    @discardableResult
    public func requeue(rpcId: String) throws -> SendOutboxEntry {
        try transition(rpcId, to: .queued) { entry in
            entry.lastError = nil
            entry.outcomeUnknownAtMs = nil
        }
    }

    /// The authoritative `user/message` observation. A `submitting` entry is
    /// first advanced to `accepted` (the history is proof the request landed),
    /// then `durable`, then removed. Returns true when a file was deleted.
    @discardableResult
    public func observeAuthoritativeUserMessage(rpcId: String,
                                                now: Date = Date()) throws -> Bool {
        guard var entry = entry(rpcId: rpcId) else { return false }
        if entry.state == .submitting {
            entry = try markAccepted(rpcId: rpcId, now: now)
        }
        guard entry.state == .accepted else { return false }
        _ = try markDurable(rpcId: rpcId, now: now)
        return try deleteIfDurable(rpcId: rpcId)
    }

    /// Deletes only a `durable` entry. `accepted` alone is not enough.
    @discardableResult
    public func deleteIfDurable(rpcId: String) throws -> Bool {
        guard let entry = entry(rpcId: rpcId) else { return false }
        guard entry.state == .durable else {
            throw SendOutboxError.deleteRequiresDurable(entry.state)
        }
        do {
            try fileManager.removeItem(at: fileURL(rpcId))
            try fsyncDirectory()
            return true
        } catch {
            throw SendOutboxError.storage(error.localizedDescription)
        }
    }

    // MARK: - Transition body

    @discardableResult
    private func transition(_ rpcId: String, to next: SendOutboxState,
                            now: Date = Date(),
                            mutate: (inout SendOutboxEntry) -> Void) throws -> SendOutboxEntry {
        guard var entry = entry(rpcId: rpcId) else { throw SendOutboxError.unknownEntry }
        if entry.state == next && next != .submitting {
            // Repeating the same observation (a live event and the send
            // acknowledgement can race) is a no-op, not an illegal edge.
            return entry
        }
        guard SendOutboxTransition.allows(from: entry.state, to: next) else {
            throw SendOutboxError.illegalTransition(from: entry.state, to: next)
        }
        entry.state = next
        mutate(&entry)
        try write(entry)
        return entry
    }

    // MARK: - Storage

    private func fileURL(_ rpcId: String) -> URL {
        directory.appendingPathComponent("\(rpcId).json")
    }

    private func write(_ entry: SendOutboxEntry) throws {
        do {
            try fileManager.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
            let data = try encoder.encode(entry)
            try Self.atomicWrite(data, to: fileURL(entry.rpcId))
        } catch let error as SendOutboxError {
            throw error
        } catch {
            throw SendOutboxError.storage(error.localizedDescription)
        }
    }

    /// temp file in the same directory → write → fsync → rename → dir fsync.
    /// The temporary name is hidden so `entries()` never picks a half file.
    public static func atomicWrite(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(
            ".\(url.lastPathComponent).tmp.\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw SendOutboxError.storage("open temp failed (errno \(errno))")
        }
        var descriptorOpen = true
        func closeDescriptor() {
            if descriptorOpen {
                close(fd)
                descriptorOpen = false
            }
        }
        do {
            let written = data.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(fd, base.advanced(by: offset),
                                             buffer.count - offset)
                    if count < 0 {
                        if errno == EINTR { continue }
                        return -1
                    }
                    offset += count
                }
                return offset
            }
            guard written == data.count else {
                closeDescriptor()
                unlink(temp.path)
                throw SendOutboxError.storage("short write (\(written)/\(data.count))")
            }
            let synced = fsync(fd) == 0
            let syncErrno = errno
            closeDescriptor()
            guard synced else {
                unlink(temp.path)
                throw SendOutboxError.storage("file fsync failed (errno \(syncErrno))")
            }
            guard rename(temp.path, url.path) == 0 else {
                let renameErrno = errno
                unlink(temp.path)
                throw SendOutboxError.storage("rename failed (errno \(renameErrno))")
            }
        } catch {
            closeDescriptor()
            unlink(temp.path)
            throw error
        }
        let dirFD = open(directory.path, O_RDONLY)
        guard dirFD >= 0 else {
            throw SendOutboxError.storage("open directory failed (errno \(errno))")
        }
        let dirSynced = fsync(dirFD) == 0
        let dirErrno = errno
        close(dirFD)
        guard dirSynced else {
            throw SendOutboxError.storage("directory fsync failed (errno \(dirErrno))")
        }
    }

    private func fsyncDirectory() throws {
        let dirFD = open(directory.path, O_RDONLY)
        guard dirFD >= 0 else {
            throw SendOutboxError.storage("open directory failed (errno \(errno))")
        }
        let synced = fsync(dirFD) == 0
        close(dirFD)
        guard synced else {
            throw SendOutboxError.storage("directory fsync failed (errno \(errno))")
        }
    }

    // MARK: - Validation

    static func validate(sessionID: String, text: String) throws {
        guard !text.isEmpty else { throw SendOutboxError.emptyText }
        guard text.count <= 1_000_000 else { throw SendOutboxError.textTooLong }
        guard sessionID.count >= 1, sessionID.count <= 64 else {
            throw SendOutboxError.invalidSessionId
        }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard sessionID.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw SendOutboxError.invalidSessionId
        }
    }

    /// `^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`
    public static func isValidRpcId(_ value: String) -> Bool {
        let pattern = "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}
