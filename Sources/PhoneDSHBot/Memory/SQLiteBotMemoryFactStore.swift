// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

public actor SQLiteBotMemoryFactStore: BotMemoryFactStore {
    private struct TombstoneEntry {
        let scope: BotMemoryScope
        let tombstone: BotMemoryTombstone
    }

    private struct ReplayState {
        var order: [String] = []
        var live: [String: BotMemoryFact] = [:]
        var tombstones: [String: TombstoneEntry] = [:]
        var generations: [String: Int] = [:]

        func facts(scope: BotMemoryScope?) -> [BotMemoryFact] {
            order.compactMap { id in
                guard let fact = live[id], scope == nil || fact.scope == scope else { return nil }
                return fact
            }
        }

        func generation(for factID: String) -> Int {
            generations[factID] ?? 0
        }
    }

    private enum ForgottenReason: String, Codable {
        case forget
        case erase
    }

    private struct ForgottenData: Codable {
        let factId: String
        let at: Int64
        let reason: ForgottenReason
        let scope: BotMemoryScope
        let textDigest: String?
    }

    private static let writeEventPrefix = "evt-memory-write-"
    private static let touchEventPrefix = "evt-memory-touch-"
    private static let forgottenEventPrefix = "evt-memory-forgotten-"

    private static let replayPageSize = 500
    private static let maximumSkippedEventIDs = 256

    private let eventLog: SQLiteDomainStore
    private let replayFeed: BotMemoryReplayFeed
    /// Identity of the Bot this store belongs to. `nil` keeps the historical
    /// on-disk shape (memory events written before per-Bot routing) and is
    /// read as `"main"`; new production stores always pass the real bot id.
    private let botID: String?
    private let now: @Sendable () -> Int64
    private let mutationMutex = BotMemoryAsyncMutex()

    /// Incremental replay state. Events are applied exactly once per store and
    /// never re-read from commit 0 after the first synchronization.
    private var state = ReplayState()
    private var processedEventIndex = 0
    private var processedMemoryEventCount = 0
    private var lastProcessedCommitSeq = 0
    private var skippedEventIDs: [String] = []

    public init(
        eventLog: SQLiteDomainStore,
        botID: String? = nil,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) {
        self.eventLog = eventLog
        self.botID = botID
        self.now = now
        self.replayFeed = BotMemoryReplayFeedRegistry.shared.feed(
            for: eventLog, pageSize: Self.replayPageSize)
    }

    /// Read-only view of how much replay each authority has paid for. The feed
    /// counters are shared per durable log; the processed count and skipped ids
    /// belong to this store.
    public var replayDiagnostics: BotMemoryReplayDiagnostics {
        get async {
            let feed = await replayFeed.diagnostics()
            return BotMemoryReplayDiagnostics(
                fullReplayCount: feed.fullReplayCount,
                incrementalReplayCount: feed.incrementalReplayCount,
                scannedEventCount: feed.scannedEventCount,
                processedMemoryEventCount: processedMemoryEventCount,
                skippedEventIDs: skippedEventIDs,
                lastProcessedCommitSeq: lastProcessedCommitSeq
            )
        }
    }

    public func facts(scope: BotMemoryScope? = nil) async throws -> [BotMemoryFact] {
        try await replay().facts(scope: scope)
    }

    /// The Bot whose agent-scope facts this store may read. Historical events
    /// with no bot id belong to `"main"`; user-scope facts are shared by every
    /// Bot and are never filtered.
    private var effectiveBotID: String {
        Self.normalizedBotID(botID)
    }

    private func belongsToThisBot(_ event: BotEvent, scope: BotMemoryScope) -> Bool {
        if scope == .user { return true }
        return Self.normalizedBotID(event.principal.botId) == effectiveBotID
    }

    private static func normalizedBotID(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "main" }
        return value
    }

    /// Only a non-main Bot contributes its identity to an event id. This keeps
    /// every historical `"main"`/`nil` event id byte-identical (so old data
    /// still replays) while two Bots can write the same fact id without
    /// colliding on the shared SQLite event log.
    private static func scopedBotID(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value != "main" else { return nil }
        return value
    }

    @discardableResult
    public func append(_ fact: BotMemoryFact) async throws -> BotMemoryFact {
        try await mutationMutex.withLock {
            let state = try await replay()
            if let existing = state.live[fact.factID] {
                guard existing == fact else {
                    throw BotMemoryFactStoreError.duplicateFactID(fact.factID)
                }
                return existing
            }
            if state.tombstones[fact.factID] != nil {
                throw BotMemoryFactStoreError.erasedFactID(fact.factID)
            }
            let event = try writtenEvent(
                fact,
                at: now(),
                eventID: Self.writeEventID(
                    factID: fact.factID, botID: botID,
                    generation: state.generation(for: fact.factID))
            )
            try await commit([event], duplicateFactID: fact.factID)
            return fact
        }
    }

    @discardableResult
    public func remove(
        factIDs: [String],
        scope: BotMemoryScope,
        tombstone: BotMemoryTombstone?
    ) async throws -> BotMemoryRemoval {
        if let tombstone, !factIDs.contains(tombstone.factID) {
            throw BotMemoryFactStoreError.invalidOperation(
                "erase tombstone \(tombstone.factID) must identify a removed fact"
            )
        }
        return try await mutationMutex.withLock {
            let state = try await replay()
            let ids = Set(factIDs)
            let targets = state.facts(scope: scope).filter { ids.contains($0.factID) }
            let forgetAt = now()
            var events: [BotEvent] = []
            for fact in targets {
                let erasing = tombstone?.factID == fact.factID
                let reason: ForgottenReason = erasing ? .erase : .forget
                events.append(try forgottenEvent(
                    factID: fact.factID,
                    scope: scope,
                    reason: reason,
                    at: erasing ? tombstone!.erasedAtMS : forgetAt,
                    textDigest: Self.digest(fact.text),
                    fact: fact,
                    generation: state.generation(for: fact.factID)
                ))
            }
            if let tombstone,
               !targets.contains(where: { $0.factID == tombstone.factID }),
               state.tombstones[tombstone.factID] == nil {
                events.append(try forgottenEvent(
                    factID: tombstone.factID,
                    scope: scope,
                    reason: .erase,
                    at: tombstone.erasedAtMS,
                    textDigest: nil,
                    fact: nil,
                    generation: state.generation(for: tombstone.factID)
                ))
            }
            if !events.isEmpty {
                try await commit(events)
            }
            let remaining = try await replay().facts(scope: scope).count
            return BotMemoryRemoval(removed: targets, count: remaining, tombstone: tombstone)
        }
    }

    /// Erases every live fact in `scope` with text-free tombstones. For an
    /// agent scope this store only sees its own Bot's facts; for user scope the
    /// shared user facts are erased and the change is visible to every Bot.
    @discardableResult
    public func eraseAll(scope: BotMemoryScope) async throws -> BotMemoryRemoval {
        try await mutationMutex.withLock {
            let current = try await replay()
            let targets = current.facts(scope: scope)
            guard !targets.isEmpty else {
                return BotMemoryRemoval(removed: [], count: 0)
            }
            let at = now()
            var events: [BotEvent] = []
            events.reserveCapacity(targets.count)
            for fact in targets {
                events.append(try forgottenEvent(
                    factID: fact.factID,
                    scope: scope,
                    reason: .erase,
                    at: at,
                    textDigest: Self.digest(fact.text),
                    fact: fact,
                    generation: current.generation(for: fact.factID)
                ))
            }
            try await commit(events)
            let remaining = try await replay().facts(scope: scope).count
            return BotMemoryRemoval(removed: targets, count: remaining)
        }
    }

    public func touch(factIDs: [String], lastUsedMS: Int64) async throws {
        try await mutationMutex.withLock {
            let state = try await replay()
            let ids = Set(factIDs)
            let touched = state.facts(scope: nil).filter { ids.contains($0.factID) }.map { fact -> BotMemoryFact in
                var updated = fact
                updated.lastUsedMS = lastUsedMS
                return updated
            }
            if touched.isEmpty { return }
            let events = try touched.map { fact in
                try writtenEvent(
                    fact,
                    at: lastUsedMS,
                    eventID: Self.touchEventID(
                        factID: fact.factID, botID: botID,
                        generation: state.generation(for: fact.factID),
                        lastUsedMS: lastUsedMS
                    )
                )
            }
            try await commit(events)
        }
    }

    public func tombstone(factID: String, scope: BotMemoryScope) async throws -> BotMemoryTombstone? {
        let state = try await replay()
        guard let entry = state.tombstones[factID], entry.scope == scope else { return nil }
        return entry.tombstone
    }

    private func commit(_ events: [BotEvent], duplicateFactID: String? = nil) async throws {
        guard !events.isEmpty else { return }
        do {
            if events.count == 1 {
                _ = try await eventLog.append(events[0])
            } else {
                _ = try await eventLog.appendBatch(events)
            }
        } catch {
            if (try? await committedEventsMatch(events)) == true { return }
            throw error
        }
        for event in events {
            guard let persisted = try await eventLog.event(withId: event.eventId) else {
                throw BotMemoryFactStoreError.corrupted("committed memory event is missing: \(event.eventId)")
            }
            guard persisted.type == event.type, persisted.data == event.data else {
                if let duplicateFactID {
                    throw BotMemoryFactStoreError.duplicateFactID(duplicateFactID)
                }
                throw BotMemoryFactStoreError.corrupted(
                    "committed memory event payload mismatch: \(event.eventId)"
                )
            }
        }
    }

    private func committedEventsMatch(_ events: [BotEvent]) async throws -> Bool {
        for event in events {
            guard let persisted = try await eventLog.event(withId: event.eventId),
                  persisted.type == event.type,
                  persisted.data == event.data else {
                return false
            }
        }
        return true
    }

    /// Pulls only events committed since the last call and applies them in
    /// order. Decode failures are isolated to their event: they are recorded in
    /// `skippedEventIDs` and the remaining facts stay available.
    private func replay() async throws -> ReplayState {
        let events = try await replayFeed.memoryEvents(
            from: processedEventIndex, eventLog: eventLog)
        guard !events.isEmpty else { return state }
        var index = processedEventIndex
        for event in events {
            guard let commitSeq = event.commitSeq else {
                processedEventIndex = index
                throw BotMemoryFactStoreError.corrupted("durable memory event has no commitSeq")
            }
            do {
                try apply(event)
            } catch is DecodingError {
                recordSkipped(event)
            } catch {
                // Leave the failing event unprocessed so a structural
                // corruption keeps failing closed instead of being skipped.
                processedEventIndex = index
                throw error
            }
            index += 1
            processedMemoryEventCount += 1
            lastProcessedCommitSeq = commitSeq
        }
        processedEventIndex = index
        return state
    }

    private func apply(_ event: BotEvent) throws {
        switch event.type {
        case "memory.written":
            let fact = try Self.decode(BotMemoryFact.self, from: event.data)
            guard belongsToThisBot(event, scope: fact.scope),
                  Self.shouldApplyWritten(event, fact: fact, state: state) else { return }
            if state.tombstones[fact.factID] == nil {
                if let existing = state.live[fact.factID] {
                    guard Self.sameFactApartFromLastUsed(existing, fact) else {
                        throw BotMemoryFactStoreError.corrupted(
                            "conflicting memory.written payloads for fact \(fact.factID)"
                        )
                    }
                    var merged = fact
                    merged.lastUsedMS = max(existing.lastUsedMS, fact.lastUsedMS)
                    state.live[fact.factID] = merged
                } else {
                    state.order.append(fact.factID)
                    state.live[fact.factID] = fact
                }
            }
        case "memory.forgotten":
            let forgotten = try Self.decode(ForgottenData.self, from: event.data)
            guard belongsToThisBot(event, scope: forgotten.scope) else { return }
            let generation = state.generation(for: forgotten.factId)
            if event.eventId.hasPrefix(Self.forgottenEventPrefix),
               event.eventId != Self.forgottenEventID(
                   factID: forgotten.factId,
                   botID: event.principal.botId,
                   scope: forgotten.scope,
                   reason: forgotten.reason,
                   generation: generation
               ) {
                return
            }
            if state.live[forgotten.factId]?.scope == forgotten.scope {
                state.live.removeValue(forKey: forgotten.factId)
                state.order.removeAll { $0 == forgotten.factId }
            }
            if forgotten.reason == .erase {
                state.tombstones[forgotten.factId] = TombstoneEntry(
                    scope: forgotten.scope,
                    tombstone: BotMemoryTombstone(factID: forgotten.factId, erasedAtMS: forgotten.at)
                )
            }
            state.generations[forgotten.factId] = generation + 1
        default:
            break
        }
    }

    private func recordSkipped(_ event: BotEvent) {
        guard !skippedEventIDs.contains(event.eventId) else { return }
        skippedEventIDs.append(event.eventId)
        if skippedEventIDs.count > Self.maximumSkippedEventIDs {
            skippedEventIDs.removeFirst(skippedEventIDs.count - Self.maximumSkippedEventIDs)
        }
    }

    private static func shouldApplyWritten(
        _ event: BotEvent,
        fact: BotMemoryFact,
        state: ReplayState
    ) -> Bool {
        let initial = event.eventId.hasPrefix(writeEventPrefix)
        let touch = event.eventId.hasPrefix(touchEventPrefix)
        guard initial || touch else { return true }
        let generation = state.generation(for: fact.factID)
        if state.live[fact.factID] == nil {
            return initial && event.eventId == writeEventID(
                factID: fact.factID, botID: event.principal.botId, generation: generation)
        }
        return touch && event.eventId == touchEventID(
            factID: fact.factID, botID: event.principal.botId,
            generation: generation,
            lastUsedMS: fact.lastUsedMS
        )
    }

    private static func sameFactApartFromLastUsed(
        _ left: BotMemoryFact,
        _ right: BotMemoryFact
    ) -> Bool {
        var left = left
        var right = right
        left.lastUsedMS = 0
        right.lastUsedMS = 0
        return left == right
    }

    private func writtenEvent(_ fact: BotMemoryFact, at: Int64, eventID: String) throws -> BotEvent {
        try makeEvent(
            type: "memory.written",
            eventID: eventID,
            data: Self.encode(fact),
            at: at,
            fact: fact
        )
    }

    private func forgottenEvent(
        factID: String,
        scope: BotMemoryScope,
        reason: ForgottenReason,
        at: Int64,
        textDigest: String?,
        fact: BotMemoryFact?,
        generation: Int
    ) throws -> BotEvent {
        let data = ForgottenData(
            factId: factID,
            at: at,
            reason: reason,
            scope: scope,
            textDigest: textDigest
        )
        return try makeEvent(
            type: "memory.forgotten",
            eventID: Self.forgottenEventID(
                factID: factID, botID: botID,
                scope: scope,
                reason: reason,
                generation: generation
            ),
            data: Self.encode(data),
            at: at,
            fact: fact
        )
    }

    private func makeEvent(
        type: String,
        eventID: String,
        data: BotJSONValue,
        at: Int64,
        fact: BotMemoryFact?
    ) throws -> BotEvent {
        BotEvent(
            type: type,
            eventId: eventID,
            time: max(0, at),
            origin: .local(source: "memory-service"),
            traceId: "trace-\(eventID)",
            principal: BotPrincipal(botId: botID, sessionId: nil, kind: "ipc"),
            causationId: nil,
            correlationId: nil,
            turnId: fact?.source?.turnID,
            runId: fact?.extractRunID,
            data: data
        )
    }

    private static func writeEventID(factID: String, botID: String?, generation: Int) -> String {
        stableEventID(writeEventPrefix, idComponents(factID, botID: botID, [String(generation)]))
    }

    private static func touchEventID(factID: String, botID: String?,
                                     generation: Int, lastUsedMS: Int64) -> String {
        stableEventID(touchEventPrefix, idComponents(
            factID, botID: botID, [String(generation), String(lastUsedMS)]))
    }

    private static func forgottenEventID(
        factID: String,
        botID: String?,
        scope: BotMemoryScope,
        reason: ForgottenReason,
        generation: Int
    ) -> String {
        stableEventID(forgottenEventPrefix, idComponents(
            factID, botID: botID,
            [scope.rawValue, reason.rawValue, String(generation)]))
    }

    private static func idComponents(_ factID: String, botID: String?, _ rest: [String]) -> [String] {
        var components = [factID]
        if let scoped = scopedBotID(botID) { components.append(scoped) }
        components.append(contentsOf: rest)
        return components
    }

    private static func stableEventID(_ prefix: String, _ components: [String]) -> String {
        prefix + digest(components.joined(separator: "\u{0}"))
    }

    private static func encode<T: Encodable>(_ value: T) throws -> BotJSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try BotJSONValue.parse(encoder.encode(value))
    }

    private static func decode<T: Decodable>(_ type: T.Type, from value: BotJSONValue) throws -> T {
        try JSONDecoder().decode(type, from: value.encoded())
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
