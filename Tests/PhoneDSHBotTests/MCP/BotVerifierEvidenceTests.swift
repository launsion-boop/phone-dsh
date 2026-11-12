// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

private actor PagedBotEventLog: BotEventLog {
    private let events: [BotEvent]
    init(_ events: [BotEvent]) { self.events = events }
    func append(_ event: BotEvent) async throws -> Int { 0 }
    func events(after commitSeq: Int, limit: Int) async throws -> [BotEvent] {
        Array(events.filter { ($0.commitSeq ?? 0) > commitSeq }.prefix(limit))
    }
}

final class BotVerifierEvidenceTests: XCTestCase {
    private func event(_ seq: Int, session: String) -> BotEvent {
        BotEvent(
            type: "turn/start", eventId: "event-\(seq)", commitSeq: seq, time: Int64(seq),
            origin: .local(source: "test"), traceId: "trace-\(seq)",
            principal: BotPrincipal(botId: "main", sessionId: session, kind: "chat"),
            causationId: nil, correlationId: nil, data: .object([:]))
    }

    func testNewestSubjectEventsSurviveAWindowLargerThanOnePage() async throws {
        var events: [BotEvent] = []
        for seq in 1...1_400 { events.append(event(seq, session: "gb-other")) }
        let subjectSeqs = [3, 700, 1_250, 1_390, 1_401]
        for seq in subjectSeqs { events.append(event(seq, session: "gb-subject")) }
        events.sort { ($0.commitSeq ?? 0) < ($1.commitSeq ?? 0) }

        let refs = try await BotVerifierEvidence.latestRefs(
            in: PagedBotEventLog(events), subjectSessionId: "gb-subject", limit: 2)
        XCTAssertEqual(refs, ["record://event/1390", "record://event/1401"])
        XCTAssertFalse(refs.contains("record://event/3"))
    }

    func testEvidenceForAnUnknownSessionIsEmptyAndNotBorrowed() async throws {
        let events = (1...1_100).map { event($0, session: "gb-other") }
        let refs = try await BotVerifierEvidence.latestRefs(
            in: PagedBotEventLog(events), subjectSessionId: "gb-new", limit: 4)
        XCTAssertEqual(refs, [])
    }

    func testVerifierSpendIsLedgeredAsCompletionCheckNotWorkerTurn() {
        XCTAssertEqual(BotDSHRemoteRuntime.ledgerPurpose(for: .verifier), .completionCheck)
        XCTAssertEqual(BotDSHRemoteRuntime.ledgerPurpose(for: .chat), .frontTurn)
        XCTAssertEqual(BotDSHRemoteRuntime.ledgerPurpose(for: .maintainer), .memoryMaintenance)
        XCTAssertEqual(BotDSHRemoteRuntime.ledgerPurpose(for: .task), .workerTurn)
        XCTAssertEqual(BotDSHRemoteRuntime.ledgerPurpose(for: .routine), .workerTurn)
    }
}
