// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHBot

actor BotRoutineOutbox: RoutineResultSink {
    static let kind = "routine-delivery"

    let store: SQLiteDomainStore
    let machine: RoutineMachine
    let botID: String

    init(store: SQLiteDomainStore, machine: RoutineMachine, botID: String) {
        self.store = store
        self.machine = machine
        self.botID = botID
    }

    @discardableResult
    func deliver(_ automation: RoutineAutomation) async throws -> Bool {
        let key = "routine:\(automation.deliveryKey)"
        let digest = try BotArgumentsDigest.string(for: .object([
            "deliveryKey": .string(automation.deliveryKey), "runId": .string(automation.runId),
            "text": .string(automation.result), "status": .string(automation.status),
        ]))
        _ = try await store.enqueue(BotEffect(
            effectKey: key, kind: Self.kind, operation: "routine.deliver",
            target: automation.deliveryKey, canonicalResource: automation.deliveryKey,
            argsDigest: digest, logicalKey: automation.deliveryKey,
            idempotent: true, retryPolicy: "local-idempotent"))
        return true
    }

    func apply(_ lease: BotEffectLease) async throws -> BotEffectState {
        guard let record = try await store.effect(lease.effectKey),
              let delivery = try await machine.delivery(record.effect.logicalKey, botId: botID) else {
            try await store.fail(lease, errorClass: "permanent", reason: "routine delivery payload is missing")
            return .deadLetter
        }
        let automation = RoutineAutomation(delivery: delivery)
        let event = BotEvent(
            type: "conversation.automation_run", eventId: "automation:\(automation.deliveryKey)",
            time: automation.finishedAt, origin: .local(source: "scheduler"),
            traceId: "automation:\(automation.deliveryKey)",
            principal: BotPrincipal(botId: botID, sessionId: nil, kind: "routine"),
            causationId: nil, correlationId: automation.deliveryKey,
            data: .object([
                "id": .string(automation.id), "routineId": .string(automation.routineId),
                "title": .string(automation.routineTitle), "status": .string(automation.status),
                "text": .string(automation.result), "result": .string(automation.result),
                "error": automation.error.map(PhoneDSHBot.BotJSONValue.string) ?? .null,
                "attempt": .number(Double(automation.attempt)), "runId": .string(automation.runId),
                "deliveryKey": .string(automation.deliveryKey), "delivery": .string(automation.delivery.rawValue),
                "quiet": .bool(automation.quiet), "context": .string(automation.context),
                "scheduledFor": automation.scheduledFor.map { .number(Double($0)) } ?? .null,
                "finishedAt": .number(Double(automation.finishedAt)),
                "heldInbox": automation.heldInbox.map(PhoneDSHBot.BotJSONValue.string) ?? .null,
            ]))
        _ = try await store.append(event)
        try await store.ack(lease, resultRef: automation.id)
        return .acked
    }
}

actor BotProductionEffectRunner {
    typealias Handler = @Sendable (BotEffectLease) async throws -> BotEffectState

    /// Closed catalogue of effect kinds this host understands. The store's
    /// `bot_effects.kind` accepts any non-empty string, so a row can carry a
    /// kind outside this set; that is a permanent producer error, not a
    /// missing executor (`spec/bot/v1/store.md` §9.7).
    static let catalogue: Set<String> = [BotRoutineOutbox.kind]

    private let store: SQLiteDomainStore
    private var handlers: [String: Handler] = [:]
    private var work: Task<Void, Never>?
    private let now: @Sendable () -> Int64

    init(store: SQLiteDomainStore,
         now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }) {
        self.store = store
        self.now = now
    }

    func register(kind: String, handler: @escaping Handler) {
        handlers[kind] = handler
    }

    func start() {
        guard work == nil else { return }
        // This task inherits the actor's isolation, not its caller's
        // `@MainActor`: the 250ms effect poll runs on the cooperative pool.
        // Field samples confirmed it is not a main-thread DB poll (the main
        // thread was entirely inside SwiftUI's graph update while the effect
        // runner appeared on `com.apple.root.user-initiated-qos.cooperative`).
        work = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                _ = try? await self.runNext()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func stop() {
        work?.cancel()
        work = nil
    }

    @discardableResult
    func runNext() async throws -> BotEffectState? {
        // The store's lease is the only selection order. The runner must not
        // build its own pending/failed ordering or filter candidates first.
        guard let lease = try await store.lease(owner: "bot-production-effects", now: now()) else {
            return nil
        }
        guard let record = try await store.effect(lease.effectKey) else {
            throw SQLiteDomainStoreError.unknownEffect(lease.effectKey)
        }
        let kind = record.effect.kind
        guard Self.catalogue.contains(kind) else {
            try await store.fail(lease, errorClass: "permanent", reason: "unknown_effect_kind")
            return .deadLetter
        }
        guard let handler = handlers[kind] else {
            // Known kind, executor not installed yet: return the effect to the
            // retry lane with the store's retry delay; never dead-letter it.
            return try await store.release(lease)
        }
        do {
            return try await handler(lease)
        } catch {
            try await store.fail(lease, errorClass: "unknown", reason: String(describing: error))
            return .needsReconciliation
        }
    }
}
