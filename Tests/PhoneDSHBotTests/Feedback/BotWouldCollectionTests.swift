// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotWouldCollectionTests: XCTestCase {
    private var store: SQLiteDomainStore!
    private var root: URL!

    override func setUp() async throws {
        (store, root) = try makeMemoryTestStore()
    }

    override func tearDown() async throws {
        try? await store?.close()
        cleanupMemoryTestStore(root)
    }

    private func appendConsidered(botID: String, decision: String, kind: String,
                                  dedupeKey: String, at: Int64,
                                  reason: String = "delivered") async throws {
        let event = BotEvent(
            type: "proactive.considered", eventId: "proactive:\(at):\(dedupeKey)",
            time: at, origin: .local(source: "runtime"), traceId: "trace:\(dedupeKey)",
            principal: BotPrincipal(botId: botID, sessionId: nil, kind: "proactive"),
            causationId: nil, correlationId: dedupeKey,
            data: .object([
                "decision": .string(decision),
                "reason": .string(reason),
                "kind": .string(kind),
                "botId": .string(botID),
                "mode": .string(decision == "would" ? "would" : "on"),
                "dedupeKey": .string(dedupeKey),
                "fuseRecorded": .bool(decision != "skip"),
            ]))
        try await store.append(event)
    }

    func testWouldOnlyShadowHasNoFabricatedAdoptionRate() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let center = BotFeedbackCenter(store: InMemoryBotFeedbackStore(), eventLog: store,
                                       memory: nil, now: { clock.now })
        let engine = ProactiveEngine(settings: { wp6Settings(mode: .would) },
                                     now: { clock.now }, eventLog: store,
                                     feedback: center)
        _ = await engine.consider(FeedbackFixtures.candidate("would-1"))
        _ = await engine.consider(FeedbackFixtures.candidate("would-2"))
        let report = try await center.wouldReport(
            botID: "bot-1", fromMS: clock.now - 60_000, toMS: clock.now + 60_000)
        XCTAssertEqual(report.would, 2)
        XCTAssertEqual(report.did, 0)
        XCTAssertNil(report.adoptionRate)
        XCTAssertTrue(report.nonEstimable.contains("no-user-visible-deliveries"))
        XCTAssertTrue(report.nonEstimable.contains("window-shorter-than-14-days"))
    }

    func testReportCountsAdoptionOnlyFromRealDeliveriesAndHonestSpan() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let deliverer = WP6NotificationDeliverer()
        let center = BotFeedbackCenter(store: InMemoryBotFeedbackStore(), eventLog: store,
                                       memory: nil, now: { clock.now })
        let engine = ProactiveEngine(settings: { wp6Settings() }, now: { clock.now },
                                     deliverer: deliverer, eventLog: store, feedback: center,
                                     deliveryKinds: [.taskDone])
        let delivered = await engine.consider(FeedbackFixtures.candidate("did-1"))
        XCTAssertEqual(delivered.decision, .did)
        let adopted = try await center.record(FeedbackFixtures.adopt(delivered, nonce: "adopt-1"))
        XCTAssertEqual(adopted.status, .accepted)
        let suppression = try await center.record(
            FeedbackFixtures.suppress(delivered, scope: .user, nonce: "stop-1"))
        XCTAssertEqual(suppression.status, .accepted)
        _ = await engine.consider(FeedbackFixtures.candidate("held-2"))

        // A real 16-day span of durable events: the report must use the real
        // event timestamps, not the caller's requested window.
        try await appendConsidered(botID: "bot-1", decision: "did", kind: "task-done",
                                   dedupeKey: "old-did", at: clock.now - 16 * 86_400_000)
        let windowStart = clock.now - 16 * 86_400_000
        let report = try await center.wouldReport(
            botID: "bot-1", fromMS: windowStart, toMS: clock.now + 1_000)
        XCTAssertEqual(report.did, 2)
        XCTAssertEqual(report.adopted, 1)
        XCTAssertEqual(report.heldByFeedback, 1)
        XCTAssertEqual(report.window.spanDays, 16, accuracy: 0.1)
        let rate = try XCTUnwrap(report.adoptionRate)
        XCTAssertEqual(rate, 0.5, accuracy: 0.0001)
        XCTAssertFalse(report.nonEstimable.contains("window-shorter-than-14-days"))
    }

    func testNoEventsIsExplicitlyNotEstimable() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let center = BotFeedbackCenter(store: InMemoryBotFeedbackStore(), eventLog: store,
                                       memory: nil, now: { clock.now })
        let report = try await center.wouldReport(
            botID: "bot-1", fromMS: clock.now - 60_000, toMS: clock.now)
        XCTAssertNil(report.adoptionRate)
        XCTAssertTrue(report.nonEstimable.contains("no-user-visible-deliveries"))
        XCTAssertEqual(report.would, 0)
        XCTAssertEqual(report.did, 0)
    }

    func testEventLogUnavailableIsNotSilentlyZero() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let center = BotFeedbackCenter(store: InMemoryBotFeedbackStore(), eventLog: nil,
                                       memory: nil, now: { clock.now })
        let report = try await center.wouldReport(
            botID: "bot-1", fromMS: clock.now - 60_000, toMS: clock.now)
        XCTAssertTrue(report.nonEstimable.contains("event-log-unavailable"))
        XCTAssertNil(report.adoptionRate)
    }
}
