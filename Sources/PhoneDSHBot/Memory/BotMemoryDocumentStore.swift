// SPDX-License-Identifier: MIT

import Foundation

public struct BotMemoryStoreWriteRequest: Sendable, Equatable {
    public var action: BotMemoryAction
    public var path: String
    public var content: String?
    public var find: String?
    public var replace: String?
    public var to: String?
    public var expectedVersion: Int
    public var restoreVersion: Int?
    public var author: BotMemoryAuthor
    public var evidence: [String]
    public var trust: BotRecordTrust?
    public var source: BotMemorySource?
    public var atMS: Int64
    /// Non-nil only for a maintenance batch: all writes of one run share
    /// `memory-maintenance:<batch_id>` so the host can collect and roll back
    /// exactly that run from the event log.
    public var correlationID: String?

    public init(
        action: BotMemoryAction,
        path: String,
        content: String? = nil,
        find: String? = nil,
        replace: String? = nil,
        to: String? = nil,
        expectedVersion: Int,
        restoreVersion: Int? = nil,
        author: BotMemoryAuthor,
        evidence: [String] = [],
        trust: BotRecordTrust? = nil,
        source: BotMemorySource? = nil,
        atMS: Int64,
        correlationID: String? = nil
    ) {
        self.action = action
        self.path = path
        self.content = content
        self.find = find
        self.replace = replace
        self.to = to
        self.expectedVersion = expectedVersion
        self.restoreVersion = restoreVersion
        self.author = author
        self.evidence = evidence
        self.trust = trust
        self.source = source
        self.atMS = atMS
        self.correlationID = correlationID
    }
}

public enum BotMemoryStoreWriteOutcome: Sendable, Equatable {
    case written(BotMemoryDocument, replaced: Int? = nil)
    case deleted(BotMemoryDocumentVersion)
    case conflict(currentVersion: Int)
    case notFound(path: String)
    case pathExists(path: String)
    case replaceNotFound
    case versionNotFound(version: Int)
    case indexTooLong(path: String, limit: Int, actual: Int)
}


/// Result of one host-side physical erasure. `removedDocuments` counts live
/// documents and `removedVersions` counts every historical version, including
/// the live one. `erasedEvents` counts payloads cleared in `bot_event_payloads`.
public struct BotMemoryPhysicalEraseOutcome: Sendable, Equatable {
    public let ok: Bool
    public let error: String?
    public let scope: BotMemoryScope
    public let paths: [String]
    public let removedDocuments: Int
    public let removedVersions: Int
    public let erasedEvents: Int
    public let erasedBytes: Int
    public let erasureRecord: String?
    public let uncoveredRecords: [String]

    public init(
        ok: Bool,
        error: String? = nil,
        scope: BotMemoryScope,
        paths: [String] = [],
        removedDocuments: Int = 0,
        removedVersions: Int = 0,
        erasedEvents: Int = 0,
        erasedBytes: Int = 0,
        erasureRecord: String? = nil,
        uncoveredRecords: [String] = []
    ) {
        self.ok = ok
        self.error = error
        self.scope = scope
        self.paths = paths
        self.removedDocuments = removedDocuments
        self.removedVersions = removedVersions
        self.erasedEvents = erasedEvents
        self.erasedBytes = erasedBytes
        self.erasureRecord = erasureRecord
        self.uncoveredRecords = uncoveredRecords
    }
}

public protocol BotMemoryDocumentStore: Actor {
    func documents(scope: BotMemoryScope?) async throws -> [BotMemoryDocument]
    func document(path: String) async throws -> BotMemoryDocument?
    func versions(path: String) async throws -> [BotMemoryDocumentVersion]
    func write(_ request: BotMemoryStoreWriteRequest) async throws -> BotMemoryStoreWriteOutcome
    func eraseAll(scope: BotMemoryScope, author: BotMemoryAuthor, atMS: Int64) async throws -> Int
    /// Physical erase of one document and every historical version.
    func erase(path: String, author: BotMemoryAuthor, atMS: Int64) async throws -> BotMemoryPhysicalEraseOutcome
    /// Physical erase of every document under one root.
    func erase(scope: BotMemoryScope, author: BotMemoryAuthor, atMS: Int64) async throws -> BotMemoryPhysicalEraseOutcome
    /// Legacy facts visible to this store's Bot: its own agent facts plus the
    /// shared user facts. Used only by the one-time migration.
    func legacyFacts(scope: BotMemoryScope?) async throws -> [BotMemoryFact]
    func replayDiagnostics() async -> BotMemoryReplayDiagnostics
}

public enum BotMemoryFactStoreError: Error, Sendable, Equatable {
    case duplicateFactID(String)
    case erasedFactID(String)
    case factNotFound(String)
    case invalidOperation(String)
    case corrupted(String)
}

final class BotMemoryAsyncMutex: @unchecked Sendable {
    private let lock = NSLock()
    private var acquired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ operation: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !acquired {
                acquired = true
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    private func release() {
        lock.lock()
        guard !waiters.isEmpty else {
            acquired = false
            lock.unlock()
            return
        }
        let next = waiters.removeFirst()
        lock.unlock()
        next.resume()
    }
}
