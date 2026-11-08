// SPDX-License-Identifier: MIT

import Foundation

public struct BotMemoryTombstone: Codable, Sendable, Equatable {
    public let factID: String
    public let erasedAtMS: Int64

    public init(factID: String, erasedAtMS: Int64) {
        self.factID = factID
        self.erasedAtMS = erasedAtMS
    }

    enum CodingKeys: String, CodingKey {
        case factID = "fact_id"
        case erasedAtMS = "erased_at_ms"
    }
}

public struct BotMemoryRemoval: Sendable, Equatable {
    public let removed: [BotMemoryFact]
    public let count: Int
    public let tombstone: BotMemoryTombstone?

    public init(removed: [BotMemoryFact], count: Int, tombstone: BotMemoryTombstone? = nil) {
        self.removed = removed
        self.count = count
        self.tombstone = tombstone
    }
}

public protocol BotMemoryFactStore: Actor {
    func facts(scope: BotMemoryScope?) async throws -> [BotMemoryFact]
    @discardableResult
    func append(_ fact: BotMemoryFact) async throws -> BotMemoryFact
    @discardableResult
    func remove(
        factIDs: [String],
        scope: BotMemoryScope,
        tombstone: BotMemoryTombstone?
    ) async throws -> BotMemoryRemoval
    func touch(factIDs: [String], lastUsedMS: Int64) async throws
    func tombstone(factID: String, scope: BotMemoryScope) async throws -> BotMemoryTombstone?
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
