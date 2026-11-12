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
// Rev 4 (PC-20261112-w1-browse-outbox) puts text and attachment sends in the
// same queue. An entry may carry up to twenty attachment *references*
// (`attachments[]`); bytes never live in the JSON. `text` may be empty only
// when at least one attachment is present; a text-only entry still needs text.
// Bytes are written to `attachments/<rpcId>/<attachmentId>` under the same
// durable outbox root, fsynced and digest-verified before the entry file is
// committed. Dispatch re-verifies every file; a missing or modified file blocks the submit and
// leaves the entry queued/outcomeUnknown with an internal `lastError`. There is
// no text-only fallback, no second queue and no new `rpcId`.
//
// The state machine is fixed:
//   queued → submitting → accepted → durable
//   submitting → outcomeUnknown
//   outcomeUnknown → accepted (read-back found it)
//   outcomeUnknown → queued (read-back proved it absent)
// `durable` is never stored as a resting state: the file is deleted instead,
// then the attachment directory is unlinked. A transport interruption never
// triggers an automatic resend.

import Foundation
import Darwin
import CryptoKit

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

/// Closed attachment kinds from the host-private outbox schema. Unknown values
/// fail closed when the entry is decoded.
public enum SendOutboxAttachmentKind: String, Codable, CaseIterable, Sendable {
    case image
    case file
    case audio
    case video
    case document

    /// The App only sends image attachments on the prompt path; the mapping
    /// still covers every declared kind so a future caller cannot accidentally
    /// label an audio/video payload as an image.
    public init(mimeType: String) {
        let lower = mimeType.lowercased()
        if lower.hasPrefix("image/") { self = .image }
        else if lower.hasPrefix("audio/") { self = .audio }
        else if lower.hasPrefix("video/") { self = .video }
        else if lower.hasPrefix("text/") || lower == "application/pdf"
                    || lower == "application/zip"
                    || lower == "application/msword"
                    || lower.hasPrefix("application/vnd.") { self = .document }
        else { self = .file }
    }
}

/// One attachment reference stored in an entry. `storePath` is relative to the
/// outbox root and must be exactly `attachments/<rpcId>/<id>`.
public struct SendOutboxAttachment: Codable, Equatable, Sendable {
    public var id: String
    public var kind: SendOutboxAttachmentKind
    public var byteSize: Int
    public var sha256: String
    public var contentType: String
    public var filename: String
    public var storePath: String

    public init(id: String, kind: SendOutboxAttachmentKind, byteSize: Int,
                sha256: String, contentType: String, filename: String,
                storePath: String) {
        self.id = id
        self.kind = kind
        self.byteSize = byteSize
        self.sha256 = sha256
        self.contentType = contentType
        self.filename = filename
        self.storePath = storePath
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, kind, byteSize, sha256, contentType, filename, storePath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: OutboxCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        for key in container.allKeys where !allowed.contains(key.stringValue) {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container,
                debugDescription: "unknown attachment member \(key.stringValue)")
        }
        self.id = try container.decode(String.self, forKey: OutboxCodingKey("id"))
        self.kind = try container.decode(SendOutboxAttachmentKind.self,
                                         forKey: OutboxCodingKey("kind"))
        self.byteSize = try container.decode(Int.self, forKey: OutboxCodingKey("byteSize"))
        self.sha256 = try container.decode(String.self, forKey: OutboxCodingKey("sha256"))
        self.contentType = try container.decode(String.self, forKey: OutboxCodingKey("contentType"))
        self.filename = try container.decode(String.self, forKey: OutboxCodingKey("filename"))
        self.storePath = try container.decode(String.self, forKey: OutboxCodingKey("storePath"))
        try Self.validateShape(self)
    }

    static func validateShape(_ attachment: SendOutboxAttachment) throws {
        guard SendOutbox.isValidAttachmentId(attachment.id),
              attachment.id != ".", attachment.id != ".." else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [], debugDescription: "invalid attachment id"))
        }
        guard attachment.byteSize >= 0 else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [], debugDescription: "negative attachment byteSize"))
        }
        guard SendOutbox.isValidSHA256(attachment.sha256) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [], debugDescription: "invalid attachment sha256"))
        }
        guard !attachment.contentType.isEmpty,
              attachment.contentType.unicodeScalars.count <= 200 else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [], debugDescription: "invalid attachment contentType"))
        }
        guard !attachment.filename.isEmpty,
              attachment.filename.unicodeScalars.count <= 255 else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [], debugDescription: "invalid attachment filename"))
        }
        guard SendOutbox.isValidStorePath(attachment.storePath,
                                          rpcId: nil, attachmentId: attachment.id) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [], debugDescription: "invalid attachment storePath"))
        }
    }
}

/// Caller-facing input for a new attachment. The store owns the id, digest,
/// byte size and store path; callers only hand over bytes and metadata.
public struct SendOutboxAttachmentInput: Sendable, Equatable {
    public var id: String?
    public var kind: SendOutboxAttachmentKind
    public var contentType: String
    public var filename: String
    public var data: Data

    public init(id: String? = nil, kind: SendOutboxAttachmentKind,
                contentType: String, filename: String, data: Data) {
        self.id = id
        self.kind = kind
        self.contentType = contentType
        self.filename = filename
        self.data = data
    }
}

/// A verified attachment read back from the store for dispatch.
public struct SendOutboxLoadedAttachment: Sendable, Equatable {
    public var attachment: SendOutboxAttachment
    public var data: Data

    public init(attachment: SendOutboxAttachment, data: Data) {
        self.attachment = attachment
        self.data = data
    }
}

/// The only two internal attachment failure reasons allowed by Rev 3. They are
/// written to `lastError`; they are never user-visible text.
public enum SendOutboxAttachmentFailure: String, Sendable {
    case missing = "attachment_missing"
    case digestMismatch = "attachment_digest_mismatch"
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
    /// Absent/empty for a text-only entry. Old entries decode unchanged.
    public var attachments: [SendOutboxAttachment]?

    public init(v: Int = 1, rpcId: String, sessionId: String, text: String,
                createdAtMs: Int64, state: SendOutboxState, attempts: Int,
                lastError: String? = nil, acceptedAtMs: Int64? = nil,
                durableAtMs: Int64? = nil, outcomeUnknownAtMs: Int64? = nil,
                backend: SendOutboxBackend? = nil,
                attachments: [SendOutboxAttachment]? = nil) {
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
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case v, rpcId, sessionId, text, createdAtMs, state, attempts
        case lastError, acceptedAtMs, durableAtMs, outcomeUnknownAtMs, backend
        case attachments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: OutboxCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        for key in container.allKeys where !allowed.contains(key.stringValue) {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container,
                debugDescription: "unknown outbox entry member \(key.stringValue)")
        }
        self.v = try container.decode(Int.self, forKey: OutboxCodingKey("v"))
        self.rpcId = try container.decode(String.self, forKey: OutboxCodingKey("rpcId"))
        self.sessionId = try container.decode(String.self, forKey: OutboxCodingKey("sessionId"))
        self.text = try container.decode(String.self, forKey: OutboxCodingKey("text"))
        self.createdAtMs = try container.decode(Int64.self, forKey: OutboxCodingKey("createdAtMs"))
        self.state = try container.decode(SendOutboxState.self, forKey: OutboxCodingKey("state"))
        self.attempts = try container.decode(Int.self, forKey: OutboxCodingKey("attempts"))
        self.lastError = try container.decodeIfPresent(String.self,
                                                        forKey: OutboxCodingKey("lastError"))
        self.acceptedAtMs = try container.decodeIfPresent(Int64.self,
                                                           forKey: OutboxCodingKey("acceptedAtMs"))
        self.durableAtMs = try container.decodeIfPresent(Int64.self,
                                                          forKey: OutboxCodingKey("durableAtMs"))
        self.outcomeUnknownAtMs = try container.decodeIfPresent(
            Int64.self, forKey: OutboxCodingKey("outcomeUnknownAtMs"))
        self.backend = try container.decodeIfPresent(SendOutboxBackend.self,
                                                      forKey: OutboxCodingKey("backend"))
        if container.contains(OutboxCodingKey("attachments")),
           try container.decodeNil(forKey: OutboxCodingKey("attachments")) {
            throw DecodingError.dataCorruptedError(
                forKey: OutboxCodingKey("attachments"), in: container,
                debugDescription: "attachments must be an array when present")
        }
        self.attachments = try container.decodeIfPresent(
            [SendOutboxAttachment].self, forKey: OutboxCodingKey("attachments"))
        try SendOutbox.validateDecoded(self)
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
    case tooManyAttachments(Int)
    case duplicateAttachmentId(String)
    case invalidAttachmentId(String)
    case invalidContentType
    case invalidFilename
    case attachmentMissing(String)
    case attachmentDigestMismatch(String)
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
        case let .tooManyAttachments(count):
            return "outbox entry has \(count) attachments (maximum 20)"
        case let .duplicateAttachmentId(id):
            return "duplicate attachment id \(id)"
        case let .invalidAttachmentId(id):
            return "invalid attachment id \(id)"
        case .invalidContentType: return "attachment contentType is invalid"
        case .invalidFilename: return "attachment filename is invalid"
        case let .attachmentMissing(id): return "attachment bytes missing for \(id)"
        case let .attachmentDigestMismatch(id):
            return "attachment bytes do not match the recorded digest for \(id)"
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

private struct OutboxCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ string: String) { self.stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// One thread-safe durable queue. The actor serializes every file operation;
/// callers never read or write the directory directly.
public actor SendOutbox {
    public nonisolated let directory: URL
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

    /// `attachments/<rpcId>/` under the same durable root as the entries.
    public nonisolated var attachmentsDirectory: URL {
        directory.appendingPathComponent("attachments", isDirectory: true)
    }

    public nonisolated func attachmentDirectory(rpcId: String) -> URL {
        attachmentsDirectory.appendingPathComponent(rpcId, isDirectory: true)
    }

    // MARK: - Enqueue

    @discardableResult
    public func enqueue(sessionID: String, text: String,
                        attachments: [SendOutboxAttachmentInput] = [],
                        backend: SendOutboxBackend = .local,
                        rpcId: String? = nil,
                        now: Date = Date()) throws -> SendOutboxEntry {
        try Self.validate(sessionID: sessionID, text: text,
                          hasAttachments: !attachments.isEmpty)
        let resolvedRpcId = rpcId ?? UUID().uuidString.lowercased()
        guard Self.isValidRpcId(resolvedRpcId) else { throw SendOutboxError.invalidRpcId }
        guard attachments.count <= 20 else {
            throw SendOutboxError.tooManyAttachments(attachments.count)
        }
        // Enqueue creates a new idempotency key. Reusing an existing rpcId
        // would overwrite its state or its attachment references; callers that
        // already have the entry use the transition methods instead.
        guard !fileManager.fileExists(atPath: fileURL(resolvedRpcId).path) else {
            throw SendOutboxError.storage(
                "outbox entry already exists for \(resolvedRpcId)")
        }

        var seen = Set<String>()
        var metadata: [SendOutboxAttachment] = []
        for input in attachments {
            let id = input.id ?? UUID().uuidString.lowercased()
            guard Self.isValidAttachmentId(id), id != ".", id != ".." else {
                throw SendOutboxError.invalidAttachmentId(id)
            }
            guard seen.insert(id).inserted else {
                throw SendOutboxError.duplicateAttachmentId(id)
            }
            guard !input.contentType.isEmpty,
                  input.contentType.unicodeScalars.count <= 200 else {
                throw SendOutboxError.invalidContentType
            }
            guard !input.filename.isEmpty,
                  input.filename.unicodeScalars.count <= 255 else {
                throw SendOutboxError.invalidFilename
            }
            metadata.append(SendOutboxAttachment(
                id: id,
                kind: input.kind,
                byteSize: input.data.count,
                sha256: Self.sha256Hex(input.data),
                contentType: input.contentType,
                filename: input.filename,
                storePath: "attachments/\(resolvedRpcId)/\(id)"))
        }

        let entry = SendOutboxEntry(
            rpcId: resolvedRpcId,
            sessionId: sessionID,
            text: text,
            createdAtMs: Int64((now.timeIntervalSince1970 * 1_000).rounded()),
            state: .queued,
            attempts: 0,
            backend: backend,
            attachments: metadata.isEmpty ? nil : metadata)

        if !metadata.isEmpty {
            do {
                try writeAttachmentBytes(metadata, inputs: attachments, rpcId: resolvedRpcId)
            } catch {
                try? fileManager.removeItem(at: attachmentDirectory(rpcId: resolvedRpcId))
                throw error
            }
        }
        do {
            try write(entry)
        } catch {
            // Attachment-first ordering means a failed entry write can leave
            // bytes behind. Remove them now; startup GC also removes orphans.
            try? fileManager.removeItem(at: attachmentDirectory(rpcId: resolvedRpcId))
            try? fsyncDirectory(attachmentsDirectory)
            throw error
        }
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

    // MARK: - Attachments

    /// Re-reads every attachment referenced by the entry and verifies the byte
    /// size and SHA-256 recorded at enqueue. Dispatch must call this before
    /// each submit (first attempt and every retry).
    public func verifiedAttachmentData(rpcId: String) throws -> [SendOutboxLoadedAttachment] {
        guard let entry = entry(rpcId: rpcId) else { throw SendOutboxError.unknownEntry }
        guard let attachments = entry.attachments, !attachments.isEmpty else { return [] }
        var loaded: [SendOutboxLoadedAttachment] = []
        for attachment in attachments {
            let url = directory.appendingPathComponent(attachment.storePath)
            guard fileManager.fileExists(atPath: url.path) else {
                throw SendOutboxError.attachmentMissing(attachment.id)
            }
            let data: Data
            do { data = try Data(contentsOf: url) } catch {
                throw SendOutboxError.attachmentMissing(attachment.id)
            }
            guard data.count == attachment.byteSize,
                  Self.sha256Hex(data) == attachment.sha256 else {
                throw SendOutboxError.attachmentDigestMismatch(attachment.id)
            }
            loaded.append(SendOutboxLoadedAttachment(attachment: attachment, data: data))
        }
        return loaded
    }

    /// Records the internal consistency failure without changing the state or
    /// deleting/rewriting anything. Only `queued`/`outcomeUnknown` entries are
    /// relevant; other states are a no-op.
    public func recordAttachmentFailure(rpcId: String,
                                        failure: SendOutboxAttachmentFailure) throws {
        guard let entry = entry(rpcId: rpcId) else { throw SendOutboxError.unknownEntry }
        guard entry.state == .queued || entry.state == .outcomeUnknown else { return }
        var updated = entry
        updated.lastError = failure.rawValue
        try write(updated)
    }

    /// Removes only attachment directories with no entry file. An entry whose
    /// attachment file is missing is a consistency failure, not an orphan, and
    /// is kept here. Returns the removed rpcId directories for tests/logging.
    @discardableResult
    public func collectOrphanAttachments() -> [String] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: attachmentsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var removed: [String] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            let rpcId = url.lastPathComponent
            guard !fileManager.fileExists(atPath: fileURL(rpcId).path) else { continue }
            if (try? fileManager.removeItem(at: url)) != nil { removed.append(rpcId) }
        }
        if !removed.isEmpty { try? fsyncDirectory(attachmentsDirectory) }
        return removed
    }

    // MARK: - Transitions

    @discardableResult
    public func markSubmitting(rpcId: String, now: Date = Date()) throws -> SendOutboxEntry {
        try transition(rpcId, to: .submitting, now: now) { entry in
            entry.attempts += 1
            entry.lastError = nil
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
    /// Attachment bytes are unlinked only after the entry file is gone; a
    /// failure there leaves an orphan for the next startup GC.
    @discardableResult
    public func deleteIfDurable(rpcId: String) throws -> Bool {
        guard let entry = entry(rpcId: rpcId) else { return false }
        guard entry.state == .durable else {
            throw SendOutboxError.deleteRequiresDurable(entry.state)
        }
        do {
            try fileManager.removeItem(at: fileURL(rpcId))
            try fsyncDirectory(directory)
        } catch {
            throw SendOutboxError.storage(error.localizedDescription)
        }
        let attachmentDirectory = attachmentDirectory(rpcId: rpcId)
        if fileManager.fileExists(atPath: attachmentDirectory.path) {
            try? fileManager.removeItem(at: attachmentDirectory)
            try? fsyncDirectory(attachmentsDirectory)
        }
        return true
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

    /// Writes every attachment byte file before the entry is committed and
    /// re-reads each one to verify size and digest.
    private func writeAttachmentBytes(_ metadata: [SendOutboxAttachment],
                                      inputs: [SendOutboxAttachmentInput],
                                      rpcId: String) throws {
        guard metadata.count == inputs.count else {
            throw SendOutboxError.storage("attachment metadata/input mismatch")
        }
        do {
            try fileManager.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
            try fileManager.createDirectory(at: attachmentsDirectory,
                                            withIntermediateDirectories: true)
            let rpcDirectory = attachmentDirectory(rpcId: rpcId)
            try fileManager.createDirectory(at: rpcDirectory,
                                            withIntermediateDirectories: true)
            // Persist the new directory entry in `attachments/` before any
            // file inside it becomes the only copy of a byte.
            try fsyncDirectory(attachmentsDirectory)
            for (attachment, input) in zip(metadata, inputs) {
                let url = rpcDirectory.appendingPathComponent(attachment.id)
                try Self.atomicWrite(input.data, to: url)
                let readBack: Data
                do { readBack = try Data(contentsOf: url) } catch {
                    throw SendOutboxError.attachmentMissing(attachment.id)
                }
                guard readBack.count == input.data.count,
                      Self.sha256Hex(readBack) == attachment.sha256 else {
                    throw SendOutboxError.attachmentDigestMismatch(attachment.id)
                }
            }
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

    private func fsyncDirectory(_ url: URL) throws {
        let dirFD = open(url.path, O_RDONLY)
        guard dirFD >= 0 else {
            throw SendOutboxError.storage("open directory failed (errno \(errno))")
        }
        let synced = fsync(dirFD) == 0
        let errnoValue = errno
        close(dirFD)
        guard synced else {
            throw SendOutboxError.storage(
                "directory fsync failed (errno \(errnoValue))")
        }
    }

    // MARK: - Validation

    static func validate(sessionID: String, text: String,
                         hasAttachments: Bool) throws {
        // Rev 4: text may be empty only when at least one attachment is
        // present. A text-only entry keeps the original non-empty rule.
        if !hasAttachments {
            guard !text.isEmpty else { throw SendOutboxError.emptyText }
        }
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

    /// Applies the closed schema's field laws to an entry read from disk. This
    /// is what makes `additionalProperties: false` real in the Swift consumer.
    static func validateDecoded(_ entry: SendOutboxEntry) throws {
        guard entry.v == 1 else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [], debugDescription: "unsupported outbox version"))
        }
        guard isValidRpcId(entry.rpcId) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [], debugDescription: "invalid rpcId"))
        }
        let hasAttachments = !(entry.attachments?.isEmpty ?? true)
        try validate(sessionID: entry.sessionId, text: entry.text,
                     hasAttachments: hasAttachments)
        guard entry.createdAtMs >= 0 else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [], debugDescription: "negative createdAtMs"))
        }
        guard entry.attempts >= 0, entry.attempts <= 1_024 else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [], debugDescription: "attempts out of range"))
        }
        if let lastError = entry.lastError, lastError.count > 1_024 {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [], debugDescription: "lastError too long"))
        }
        guard let attachments = entry.attachments else { return }
        guard attachments.count <= 20 else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [], debugDescription: "too many attachments"))
        }
        var seen = Set<String>()
        for attachment in attachments {
            guard seen.insert(attachment.id).inserted else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [], debugDescription: "duplicate attachment id"))
            }
            guard isValidStorePath(attachment.storePath, rpcId: entry.rpcId,
                                   attachmentId: attachment.id) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [], debugDescription: "attachment storePath mismatch"))
            }
        }
    }

    /// `^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`
    public static func isValidRpcId(_ value: String) -> Bool {
        let pattern = "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    /// `^[A-Za-z0-9._-]{1,64}$`
    public static func isValidAttachmentId(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9._-]{1,64}$",
                    options: .regularExpression) != nil
    }

    /// `^[0-9a-f]{64}$`
    public static func isValidSHA256(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    static func isValidStorePath(_ value: String, rpcId: String?,
                                 attachmentId: String) -> Bool {
        let pattern = "^attachments/[0-9a-f-]{36}/[A-Za-z0-9._-]{1,64}$"
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            return false
        }
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 3, String(pieces[0]) == "attachments",
              String(pieces[2]) == attachmentId else { return false }
        if let rpcId, String(pieces[1]) != rpcId { return false }
        return true
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
