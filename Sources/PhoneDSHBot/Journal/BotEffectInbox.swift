// SPDX-License-Identifier: MIT

import Foundation

struct BotEffectInboxFlightKey: Hashable {
    let receiver: String
    let effectKey: String
    let generation: Int
}

public actor SQLiteBotEffectInbox {
    private let store: SQLiteDomainStore
    private let receiver: String
    private let clock: @Sendable () -> Int64

    public init(
        store: SQLiteDomainStore,
        receiver: String,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) throws {
        guard receiver.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil,
              receiver != ".", receiver != ".." else {
            throw SQLiteDomainStoreError.invalidConfiguration("invalid effect receiver")
        }
        self.store = store
        self.receiver = receiver
        self.clock = now
    }

    public func apply(
        _ lease: BotEffectLease,
        executor: @escaping @Sendable (BotEffectLease) async throws -> String?
    ) async throws -> BotEffectInboxResult {
        try await store.applySharedInbox(
            receiver: receiver, lease: lease, appliedAt: clock, executor: executor)
    }
}

extension SQLiteDomainStore {
    func applySharedInbox(
        receiver: String,
        lease: BotEffectLease,
        appliedAt: @escaping @Sendable () -> Int64,
        executor: @escaping @Sendable (BotEffectLease) async throws -> String?
    ) async throws -> BotEffectInboxResult {
        if let existing = try inboxEntry(receiver: receiver, effectKey: lease.effectKey),
           existing.generation >= lease.generation {
            return BotEffectInboxResult(deduped: true, resultRef: existing.resultRef, entry: existing)
        }
        let key = BotEffectInboxFlightKey(
            receiver: receiver, effectKey: lease.effectKey, generation: lease.generation)
        if let flight = inboxFlights[key] {
            let entry = try await flight.value
            return BotEffectInboxResult(deduped: true, resultRef: entry.resultRef, entry: entry)
        }
        guard let record = try effectRecord(forKey: lease.effectKey) else {
            throw SQLiteDomainStoreError.unknownEffect(lease.effectKey)
        }
        guard record.generation == lease.generation,
              record.attempt == lease.attempt,
              record.leaseOwner == lease.leaseOwner else {
            throw SQLiteDomainStoreError.staleLease(lease.effectKey)
        }
        guard record.state == .leased || record.state == .cancelRequested else {
            throw SQLiteDomainStoreError.invalidTransition("effect is not leased for inbox apply")
        }

        let flight = Task<BotEffectInboxEntry, Error> {
            let resultRef = try await executor(lease)
            return try self.recordInbox(
                receiver: receiver, lease: lease, appliedAt: appliedAt(), resultRef: resultRef)
        }
        inboxFlights[key] = flight
        defer { inboxFlights[key] = nil }
        let entry = try await flight.value
        return BotEffectInboxResult(deduped: false, resultRef: entry.resultRef, entry: entry)
    }
}
