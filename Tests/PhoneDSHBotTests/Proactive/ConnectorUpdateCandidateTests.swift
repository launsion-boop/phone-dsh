// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// The connector delta is also a proactive candidate. It must build from the
/// durable `connector-update` record and go through the existing dnd / quiet
/// hours / fuse policy with no new budget, cooldown, quota or TTL.
final class ConnectorUpdateCandidateTests: XCTestCase {
    func testDurableConnectorRecordBecomesOneCandidate() async throws {
        let sources = ProactiveSources(now: { 1_000 })
        let event = try Self.connectorEvent()
        let candidates = await sources.candidates(for: event)
        XCTAssertEqual(candidates.count, 1)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate.kind, .connectorUpdate)
        XCTAssertEqual(candidate.botId, "bot-a")
        XCTAssertEqual(candidate.dedupeKey, "connector:gmail:100:200")
        XCTAssertEqual(candidate.trigger, "connector.scan")
        XCTAssertEqual(candidate.title, "Gmail")
        XCTAssertEqual(candidate.body, "2 new items: One")
        XCTAssertEqual(candidate.sourceEventId, event.eventId)
        XCTAssertEqual(candidate.channel, "system-notification")
    }

    func testDndStillBlocksTheConnectorCandidate() async throws {
        let engine = ProactiveEngine(settings: { Self.settings(dnd: true) }, now: { 1_000 })
        let candidate = try await Self.candidate()
        let decision = await engine.consider(candidate)
        XCTAssertEqual(decision.decision, .skip)
        XCTAssertEqual(decision.reason, "dnd")
    }

    func testQuietHoursStillBlockTheConnectorCandidate() async throws {
        let engine = ProactiveEngine(
            settings: { Self.settings(quietStart: "00:00", quietEnd: "23:59") },
            now: { 1_000 })
        let candidate = try await Self.candidate()
        let decision = await engine.consider(candidate)
        XCTAssertEqual(decision.decision, .skip)
        XCTAssertEqual(decision.reason, "quiet-hours")
    }

    func testTheExistingFrequencyFuseApplies() async throws {
        let engine = ProactiveEngine(
            settings: { Self.settings(mode: .would) }, now: { 1_000 })
        let candidate = try await Self.candidate()
        for _ in 0..<ProactivePolicyConfiguration().fuseMaxWakeups {
            let decision = await engine.consider(candidate)
            XCTAssertEqual(decision.decision, .would)
            XCTAssertEqual(decision.reason, "would-mode")
        }
        let tripped = await engine.consider(candidate)
        XCTAssertEqual(tripped.decision, .skip)
        XCTAssertEqual(tripped.reason, "fuse")
    }

    func testProactiveModeOffStillSkips() async throws {
        let engine = ProactiveEngine(settings: { Self.settings(mode: .off) }, now: { 1_000 })
        let candidate = try await Self.candidate()
        let decision = await engine.consider(candidate)
        XCTAssertEqual(decision.decision, .skip)
        XCTAssertEqual(decision.reason, "mode-off")
    }

    // MARK: - Fixtures

    private static func settings(mode: ProactiveMode = .on, dnd: Bool = false,
                                 quietStart: String = "00:00", quietEnd: String = "00:00")
    -> ProactiveSettings {
        ProactiveSettings(mode: mode, dnd: dnd, quietStart: quietStart, quietEnd: quietEnd,
                          routineQuietWeekends: false, timeZone: "UTC")
    }

    private static func connectorEvent() throws -> BotEvent {
        let update = try ConnectorUpdateRecord(
            connector: .gmail, cursorFrom: "100", cursorTo: "200",
            items: [
                .init(id: "m1", at: 10, from: "QA <qa@example.com>", subject: "One"),
                .init(id: "m2", at: 20, from: "Ops <ops@example.com>", subject: "Two"),
            ],
            createdAt: 1_000)
        return BotEvent(
            type: ConnectorUpdateOutbox.recordEventType,
            eventId: ConnectorUpdateOutbox.recordEventID(for: update),
            time: 1_000, origin: .local(source: "comm-service"),
            traceId: "connector-update:\(update.digest)",
            principal: BotPrincipal(botId: "bot-a", sessionId: nil, kind: "chat"),
            causationId: nil, correlationId: update.requestID,
            data: .object([
                "botId": .string("bot-a"),
                "connectorUpdate": try BotJSONValue.parse(JSONEncoder().encode(update)),
            ]))
    }

    private static func candidate() async throws -> ProactiveCandidate {
        let sources = ProactiveSources(now: { 1_000 })
        let event = try connectorEvent()
        let candidates = await sources.candidates(for: event)
        return try XCTUnwrap(candidates.first)
    }
}
