// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotEffectRecoveryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phonedsh-bot-effect-recovery-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testSharedSingleFlightAcrossInboxInstancesRunsOnceAndSharesResult() async throws {
        let store = try makeStore()
        let effect = Self.effect()
        _ = try await store.enqueue(effect)
        let lease = try await unwrapAsync(try await store.lease(owner: "owner", now: 1_000))
        let first = try SQLiteBotEffectInbox(store: store, receiver: "local-tool", now: { 1_100 })
        let second = try SQLiteBotEffectInbox(store: store, receiver: "local-tool", now: { 1_100 })
        let gate = InboxExecutorGate()

        let resultsTask = Task {
            try await withThrowingTaskGroup(of: BotEffectInboxResult.self) { group in
                for index in 0..<100 {
                    group.addTask {
                        let inbox = index.isMultiple(of: 2) ? first : second
                        return try await inbox.apply(lease) { _ in await gate.execute() }
                    }
                }
                var results: [BotEffectInboxResult] = []
                for try await result in group { results.append(result) }
                return results
            }
        }
        await gate.waitUntilStarted()
        await assertNilAsync(try await store.inboxEntry(receiver: "local-tool", effectKey: effect.effectKey))
        try await Task.sleep(nanoseconds: 50_000_000)
        await gate.release()
        let results = try await resultsTask.value

        XCTAssertEqual(results.count, 100)
        XCTAssertEqual(results.filter { !$0.deduped }.count, 1)
        XCTAssertTrue(results.allSatisfy { $0.resultRef == "shared-result" })
        let executionCount = await gate.executionCount
        XCTAssertEqual(executionCount, 1)
        let entry = try await unwrapAsync(
            try await store.inboxEntry(receiver: "local-tool", effectKey: effect.effectKey))
        XCTAssertEqual(entry.resultRef, "shared-result")
        try await store.close()
    }

    func testSharedFlightFailureDoesNotWriteInboxAndAllowsRetry() async throws {
        let store = try makeStore()
        let effect = Self.effect()
        _ = try await store.enqueue(effect)
        let lease = try await unwrapAsync(try await store.lease(owner: "owner", now: 1_000))
        let inbox = try SQLiteBotEffectInbox(store: store, receiver: "local-tool", now: { 1_100 })
        do {
            _ = try await inbox.apply(lease) { _ in throw RecoveryTestError.expected }
            XCTFail("executor failure must propagate")
        } catch {
            XCTAssertEqual(error as? RecoveryTestError, .expected)
        }
        await assertNilAsync(try await store.inboxEntry(receiver: "local-tool", effectKey: effect.effectKey))

        let retry = try await inbox.apply(lease) { _ in "recovered" }
        XCTAssertFalse(retry.deduped)
        XCTAssertEqual(retry.resultRef, "recovered")
        try await store.close()
    }

    func testCrashWhileCancelRequestedExecutorIsInFlightRequiresReconciliation() async throws {
        let file = directory.appendingPathComponent("domain.sqlite")
        let store = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        let effect = Self.effect(idempotent: false)
        _ = try await store.enqueue(effect)
        let lease = try await unwrapAsync(try await store.leaseNext(owner: "owner", now: 1_000, ttlMs: 10))
        try await store.requestCancel(effect.effectKey, reason: "user")
        let gate = InboxExecutorGate()
        let inbox = try SQLiteBotEffectInbox(store: store, receiver: "local-tool", now: { 1_100 })
        let applyTask = Task {
            try await inbox.apply(lease) { _ in await gate.execute() }
        }
        await gate.waitUntilStarted()
        try await store.close()

        let reopened = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        await assertEqualAsync(try await reopened.effect(effect.effectKey)?.state, .cancelRequested)
        await assertNilAsync(try await reopened.leaseNext(owner: "other", now: 1_009, ttlMs: 10))
        await assertNilAsync(try await reopened.leaseNext(owner: "other", now: 1_010, ttlMs: 10))
        await assertEqualAsync(try await reopened.effect(effect.effectKey)?.state, .needsReconciliation)
        await assertNilAsync(try await reopened.inboxEntry(receiver: "local-tool", effectKey: effect.effectKey))

        await gate.release()
        do {
            _ = try await applyTask.value
            XCTFail("the closed store must not record an inbox result")
        } catch {}
        let executionCount = await gate.executionCount
        XCTAssertEqual(executionCount, 1)
        await assertEqualAsync(try await reopened.effect(effect.effectKey)?.state, .needsReconciliation)
        await assertNilAsync(try await reopened.lease(owner: "other", now: 2_000))
        await assertNilAsync(try await reopened.inboxEntry(receiver: "local-tool", effectKey: effect.effectKey))
        let events = try await reopened.events(after: 0, limit: 10)
        XCTAssertEqual(events.map(\.commitSeq), [1, 2, 3, 4])
        XCTAssertEqual(events.last?.type, "effect.reconciliation_required")
        try await reopened.close()
    }

    func testExpiredCancelRequestedIdempotentEffectUsesExplicitRetryPolicy() async throws {
        let file = directory.appendingPathComponent("domain.sqlite")
        let store = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        let effect = Self.effect(retryPolicy: "network-idempotent")
        _ = try await store.enqueue(effect)
        _ = try await unwrapAsync(try await store.leaseNext(owner: "owner", now: 1_000, ttlMs: 10))
        try await store.requestCancel(effect.effectKey, reason: "user")
        try await store.close()

        let reopened = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        await assertNilAsync(try await reopened.leaseNext(owner: "other", now: 1_010, ttlMs: 10))
        await assertEqualAsync(try await reopened.effect(effect.effectKey)?.state, .needsReconciliation)
        try await reopened.retryNeedsReconciliation(effect.effectKey, notBefore: 5_000)
        await assertNilAsync(try await reopened.lease(owner: "other", now: 4_999))
        let retry = try await unwrapAsync(try await reopened.lease(owner: "other", now: 5_000))
        XCTAssertEqual(retry.generation, 2)
        XCTAssertEqual(retry.attempt, 1)
        try await reopened.close()
    }

    func testActionEventEffectAndNonceTransactionRemainsAtomic() async throws {
        let file = directory.appendingPathComponent("domain.sqlite")
        let store = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        let action = Self.action()
        let plan = Self.plan()
        await assertEqualAsync(
            try await store.performAndRecord(action: action, plan: plan),
            .accepted(eventID: "evt-action-recovery"))
        await assertEqualAsync(
            try await store.eventID(botID: action.botID, nonce: action.nonce), "evt-action-recovery")
        await assertEqualAsync(try await store.headCommitSeq(), 2)
        let effect = try await unwrapAsync(try await store.effect("fx-action-recovery"))
        XCTAssertEqual(effect.state, .pending)
        XCTAssertEqual(effect.enqueuedCommitSeq, 2)

        let lease = try await unwrapAsync(try await store.lease(owner: "owner", now: 1_000))
        let inbox = try SQLiteBotEffectInbox(store: store, receiver: "local-tool", now: { 1_100 })
        let applied = try await inbox.apply(lease) { _ in "action-result" }
        XCTAssertEqual(applied.resultRef, "action-result")
        try await store.ack(lease, resultRef: applied.resultRef)
        await assertEqualAsync(
            try await store.performAndRecord(action: action, plan: plan),
            .duplicate(eventID: "evt-action-recovery"))
        await assertEqualAsync(try await store.headCommitSeq(), 4)
        try await store.verifyIntegrity()
        try await store.close()

        let reopened = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        await assertEqualAsync(
            try await reopened.performAndRecord(action: action, plan: plan),
            .duplicate(eventID: "evt-action-recovery"))
        await assertEqualAsync(try await reopened.headCommitSeq(), 4)
        await assertEqualAsync(try await reopened.effect(effect.effectKey)?.state, .acked)
        try await reopened.verifyIntegrity()
        try await reopened.close()
    }

    private func makeStore() throws -> SQLiteDomainStore {
        try SQLiteDomainStore(fileURL: directory.appendingPathComponent("domain.sqlite"), now: { 1_000 })
    }

    private static func effect(
        key: String = "fx-recovery",
        idempotent: Bool = true,
        retryPolicy: String? = nil
    ) -> BotEffect {
        BotEffect(
            effectKey: key, kind: "test", operation: "notify", target: "row-1",
            canonicalResource: "row-1", argsDigest: "args-digest", payloadDigest: "payload-digest",
            logicalKey: "request-1", idempotent: idempotent, retryPolicy: retryPolicy)
    }

    private static func action() -> BotUserAction {
        BotUserAction(nonce: "nonce-recovery", botID: "main", kind: .chat, text: "继续")
    }

    private static func plan() -> BotUserActionPlan {
        let event = BotEvent(
            type: "conversation.user_message", eventId: "evt-action-recovery", time: 1_000,
            origin: .local(source: "user"), traceId: "trace-action-recovery",
            principal: BotPrincipal(botId: "main", sessionId: "main", kind: "chat"),
            causationId: nil, correlationId: "nonce-recovery", data: .object(["text": .string("继续")]))
        return BotUserActionPlan(event: event, effects: [effect(key: "fx-action-recovery")])
    }
}

private enum RecoveryTestError: Error, Equatable {
    case expected
}

private actor InboxExecutorGate {
    private var executions = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    var executionCount: Int { executions }

    func execute() async -> String {
        executions += 1
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        return "shared-result"
    }

    func waitUntilStarted() async {
        if executions > 0 { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
