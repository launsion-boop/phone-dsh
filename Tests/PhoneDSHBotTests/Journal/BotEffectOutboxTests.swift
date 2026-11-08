// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotEffectOutboxTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phonedsh-bot-effects-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testEnqueueIsIdempotentAndHonorsNotBefore() async throws {
        let store = try makeStore()
        let effect = Self.makeEffect()
        _ = try await store.enqueue(effect)
        _ = try await store.enqueue(effect)
        await assertEqualAsync(try await store.headCommitSeq(), 1)
        await assertEqualAsync(try await store.effect(effect.effectKey)?.state, .pending)
        await assertNilAsync(try await store.lease(owner: "owner-a", now: 999))
        let lease = try await store.lease(owner: "owner-a", now: 1_000)
        XCTAssertEqual(lease?.attempt, 1)
        XCTAssertEqual(lease?.generation, 1)
        await assertEqualAsync(try await store.effect(effect.effectKey)?.state, .leased)
        try await store.close()
    }

    func testExpiredLeaseTakeoverRejectsOldOwnerACK() async throws {
        let file = directory.appendingPathComponent("domain.sqlite")
        let store = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        let effect = Self.makeEffect()
        _ = try await store.enqueue(effect)
        let old = try await unwrapAsync(try await store.leaseNext(owner: "owner-old", now: 1_000, ttlMs: 10))
        await assertNilAsync(try await store.leaseNext(owner: "owner-new", now: 1_009, ttlMs: 10))
        let current = try await unwrapAsync(try await store.leaseNext(owner: "owner-new", now: 1_010, ttlMs: 20))
        XCTAssertEqual(current.attempt, 2)
        XCTAssertEqual(current.generation, 2)

        do {
            try await store.ack(old, resultRef: "stale")
            XCTFail("stale owner ACK must be rejected")
        } catch {
            XCTAssertEqual(error as? SQLiteDomainStoreError, .staleLease(effect.effectKey))
        }
        await assertEqualAsync(try await store.effect(effect.effectKey)?.leaseOwner, "owner-new")
        try await store.ack(current, resultRef: "result-current")
        try await store.ack(current, resultRef: "result-current")
        await assertEqualAsync(try await store.effect(effect.effectKey)?.state, .acked)
        try await store.close()

        let reopened = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        await assertEqualAsync(try await reopened.effect(effect.effectKey)?.state, .acked)
        await assertEqualAsync(try await reopened.effect(effect.effectKey)?.resultRef, "result-current")
        try await reopened.close()
    }

    func testRenewKeepsAttemptAndGenerationAndMovesExpiry() async throws {
        let store = try makeStore()
        _ = try await store.enqueue(Self.makeEffect())
        let lease = try await unwrapAsync(try await store.leaseNext(owner: "owner", now: 1_000, ttlMs: 10))
        let renewed = try await store.renew(lease, now: 1_005, ttlMs: 20)
        XCTAssertEqual(renewed.attempt, lease.attempt)
        XCTAssertEqual(renewed.generation, lease.generation)
        XCTAssertEqual(renewed.leaseExpiresAt, 1_025)
        await assertNilAsync(try await store.leaseNext(owner: "other", now: 1_024, ttlMs: 10))
        try await store.ack(renewed, resultRef: nil)
        try await store.close()
    }

    func testTransientRetryExhaustionWritesFailedAndDeadLetterAtomically() async throws {
        let store = try makeStore()
        let effect = Self.makeEffect()
        _ = try await store.enqueue(effect)
        let first = try await unwrapAsync(try await store.lease(owner: "owner", now: 1_000))
        try await store.fail(first, errorClass: "transient", reason: "temporary sk-secret-value")
        var record = try await unwrapAsync(try await store.effect(effect.effectKey))
        XCTAssertEqual(record.state, .failed)
        XCTAssertFalse(record.lastError?.contains("sk-secret-value") ?? true)

        let second = try await unwrapAsync(try await store.lease(owner: "owner", now: 1_000))
        XCTAssertEqual(second.attempt, 2)
        XCTAssertEqual(second.generation, 1)
        try await store.fail(second, errorClass: "transient", reason: "still failing")
        record = try await unwrapAsync(try await store.effect(effect.effectKey))
        XCTAssertEqual(record.state, .deadLetter)
        await assertNilAsync(try await store.lease(owner: "owner", now: 2_000))
        let events = try await store.events(after: 0, limit: 20)
        XCTAssertEqual(events.suffix(2).map(\.type), ["effect.failed", "effect.dead_lettered"])
        XCTAssertEqual(events.last?.batch?.total, 2)
        try await store.close()
    }

    func testPermanentFailureDeadLettersImmediately() async throws {
        let store = try makeStore()
        let effect = Self.makeEffect(idempotent: false)
        _ = try await store.enqueue(effect)
        let lease = try await unwrapAsync(try await store.lease(owner: "owner", now: 1_000))
        try await store.fail(lease, errorClass: "permanent", reason: "denied")
        await assertEqualAsync(try await store.effect(effect.effectKey)?.state, .deadLetter)
        try await store.close()
    }

    func testUnknownOutcomeNeedsReconciliationAndExplicitResolution() async throws {
        let store = try makeStore()
        let effect = Self.makeEffect(idempotent: false)
        _ = try await store.enqueue(effect)
        let lease = try await unwrapAsync(try await store.lease(owner: "owner", now: 1_000))
        try await store.fail(lease, errorClass: "unknown", reason: "connection lost after send")
        let record = try await unwrapAsync(try await store.effect(effect.effectKey))
        XCTAssertEqual(record.state, .needsReconciliation)
        XCTAssertEqual(record.reconciliationReason, "unknown-outcome")
        await assertNilAsync(try await store.lease(owner: "owner", now: 2_000))
        let head = try await store.headCommitSeq()
        try await store.markNeedsReconciliation(effect.effectKey, reason: "unknown-outcome")
        await assertEqualAsync(try await store.headCommitSeq(), head)
        try await store.ackReconciled(
            effectKey: effect.effectKey, generation: record.generation, attempt: record.attempt,
            resultRef: "externally-confirmed")
        await assertEqualAsync(try await store.effect(effect.effectKey)?.state, .acked)
        let last = try await store.events(after: head - 1, limit: 2).last
        if case .bool(true)? = last?.data.objectValue?["reconciled"] {} else {
            XCTFail("manual ACK must carry reconciled=true")
        }
        try await store.close()
    }

    func testExpiredSingleAttemptEffectDoesNotReplayAutomatically() async throws {
        let store = try makeStore()
        let effect = Self.makeEffect(idempotent: false)
        _ = try await store.enqueue(effect)
        _ = try await unwrapAsync(try await store.leaseNext(owner: "owner", now: 1_000, ttlMs: 10))
        await assertNilAsync(try await store.leaseNext(owner: "other", now: 1_010, ttlMs: 10))
        await assertEqualAsync(try await store.effect(effect.effectKey)?.state, .needsReconciliation)
        try await store.close()
    }

    func testNetworkIdempotentRetryUsesBackoff() async throws {
        let store = try makeStore()
        let effect = Self.makeEffect(retryPolicy: "network-idempotent")
        _ = try await store.enqueue(effect)
        let lease = try await unwrapAsync(try await store.lease(owner: "owner", now: 1_000))
        try await store.fail(lease, errorClass: "transient", reason: "503")
        await assertNilAsync(try await store.lease(owner: "owner", now: 1_999))
        let retry = try await unwrapAsync(try await store.lease(owner: "owner", now: 2_000))
        XCTAssertEqual(retry.attempt, 2)
        try await store.close()
    }

    func testCancellationBeforeAndAfterLease() async throws {
        let store = try makeStore()
        let pending = Self.makeEffect(key: "fx-pending")
        _ = try await store.enqueue(pending)
        try await store.requestCancel(pending.effectKey, reason: "user")
        await assertEqualAsync(try await store.effect(pending.effectKey)?.state, .canceled)

        let leased = Self.makeEffect(key: "fx-leased")
        _ = try await store.enqueue(leased)
        let lease = try await unwrapAsync(try await store.lease(owner: "owner", now: 1_000))
        try await store.requestCancel(leased.effectKey, reason: "user")
        await assertEqualAsync(try await store.effect(leased.effectKey)?.state, .cancelRequested)
        try await store.confirmCancel(lease, reason: "checkpoint")
        await assertEqualAsync(try await store.effect(leased.effectKey)?.state, .canceled)
        try await store.close()
    }

    func testInboxRetriesReturnCachedResultWithoutReexecuting() async throws {
        let file = directory.appendingPathComponent("domain.sqlite")
        let store = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        let effect = Self.makeEffect()
        _ = try await store.enqueue(effect)
        let lease = try await unwrapAsync(try await store.lease(owner: "owner", now: 1_000))
        let counter = InboxCounter()
        let inbox = try SQLiteBotEffectInbox(store: store, receiver: "local-tool", now: { 1_100 })
        for index in 0..<100 {
            let result = try await inbox.apply(lease) { _ in
                counter.increment()
                return "result-1"
            }
            XCTAssertEqual(result.deduped, index != 0)
            XCTAssertEqual(result.resultRef, "result-1")
        }
        XCTAssertEqual(counter.value, 1)
        try await store.ack(lease, resultRef: "result-1")
        try await store.close()

        let reopened = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        let reopenedInbox = try SQLiteBotEffectInbox(store: reopened, receiver: "local-tool", now: { 2_100 })
        let replay = try await reopenedInbox.apply(lease) { _ in
            counter.increment()
            return "unexpected"
        }
        XCTAssertTrue(replay.deduped)
        XCTAssertEqual(replay.resultRef, "result-1")
        XCTAssertEqual(counter.value, 1)
        try await reopened.close()
    }

    func testCrashDuringLeaseRollsBackEventAndProjectionTogether() async throws {
        let file = directory.appendingPathComponent("domain.sqlite")
        let store = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        let effect = Self.makeEffect()
        _ = try await store.enqueue(effect)
        await store.armCrashPoint("abort-before-commit")
        do {
            _ = try await store.lease(owner: "owner", now: 1_000)
            XCTFail("injected crash must fail lease")
        } catch {
            XCTAssertEqual(error as? SQLiteDomainStoreError, .simulatedCrash("abort-before-commit"))
        }
        try await store.close()

        let reopened = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        await assertEqualAsync(try await reopened.headCommitSeq(), 1)
        await assertEqualAsync(try await reopened.effect(effect.effectKey)?.state, .pending)
        await assertEqualAsync(try await reopened.effect(effect.effectKey)?.attempts, 0)
        let lease = try await unwrapAsync(try await reopened.lease(owner: "owner", now: 1_000))
        XCTAssertEqual(lease.attempt, 1)
        await assertEqualAsync(try await reopened.headCommitSeq(), 2)
        _ = try await reopened.enqueue(effect)
        await assertEqualAsync(try await reopened.headCommitSeq(), 2)
        try await reopened.close()
    }

    private func makeStore() throws -> SQLiteDomainStore {
        try SQLiteDomainStore(fileURL: directory.appendingPathComponent("domain.sqlite"), now: { 1_000 })
    }

    private static func makeEffect(
        key: String = "fx-test",
        idempotent: Bool = true,
        retryPolicy: String? = nil
    ) -> BotEffect {
        BotEffect(
            effectKey: key, kind: "test", operation: "notify", target: "row-1",
            canonicalResource: "row-1", argsDigest: "args-digest", payloadDigest: "payload-digest",
            logicalKey: "request-1", idempotent: idempotent, retryPolicy: retryPolicy)
    }
}

private final class InboxCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private extension BotJSONValue {
    var objectValue: [String: BotJSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }
}
