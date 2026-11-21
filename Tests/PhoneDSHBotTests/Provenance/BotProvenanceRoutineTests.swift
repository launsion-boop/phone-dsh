// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import XCTest
@testable import PhoneDSHBot

/// 100-sample missing_refs: routine memory writes had no record:// sources.
/// The routine run_started event is the real trigger; a run without one stays
/// no-derivation.
final class BotProvenanceRoutineTests: XCTestCase {
    func testRoutineRunStartedIsARealTriggerSource() async throws {
        let log = BotProvenanceTestLog()
        _ = try await log.append(ProvenanceTest.event(
            type: "routine.run_started", eventId: "started:run-1",
            data: .object([
                "runId": .string("run-1"), "routineId": .string("weekly"),
                "title": .string("Weekly"), "attempt": .number(1),
                "scheduledFor": .number(1_000),
            ]),
            principalKind: "routine", botID: "main", sessionID: "routine-session"))
        _ = try await log.append(ProvenanceTest.event(
            type: "routine.run_finished", eventId: "finished:run-1",
            data: .object(["runId": .string("run-1")]),
            principalKind: "routine", botID: "main", sessionID: "routine-session"))
        _ = try await log.append(ProvenanceTest.event(
            type: "routine.defined", eventId: "routine-definition",
            data: .object([
                "botId": .string("main"),
                "document": .object([
                    "version": .number(1),
                    "routines": .array([.object([
                        "id": .string("weekly"),
                    ])]),
                    "deliveries": .object([:]),
                ]),
            ]), principalKind: "routine", botID: "main", sessionID: nil))
        let service = BotProvenanceService(eventLog: log)
        let triggers = try await service.routineDerivationSources(
            botID: "main", sessionID: "routine-session")
        XCTAssertEqual(triggers.count, 2)
        XCTAssertEqual(triggers[0].record, "record://event/1")
        XCTAssertEqual(triggers[0].role, .trigger)
        XCTAssertEqual(triggers[1].record, "record://event/3")
        XCTAssertEqual(triggers[1].role, .basis)

        let evidence = try await log.append(ProvenanceTest.event(
            type: "conversation.user_message", eventId: "routine-evidence",
            data: .object(["text": .string("user source")])))
        let prepared = try await service.prepareDerivation(
            artifact: BotDerivedRef(kind: .memory, id: "agent/weekly.md", version: 1),
            sources: triggers + [BotDerivationSource(
                record: "record://event/\(evidence)", role: .evidence)])
        let sources = try XCTUnwrap(prepared["sources"]?.arrayValue)
        XCTAssertEqual(sources.count, 3)
        XCTAssertEqual(sources[0]["role"]?.stringValue, "trigger")
        XCTAssertEqual(sources[0]["record"]?.stringValue, "record://event/1")
        XCTAssertEqual(sources[1]["role"]?.stringValue, "basis")
        XCTAssertEqual(sources[1]["record"]?.stringValue, "record://event/3")
        XCTAssertEqual(sources[2]["role"]?.stringValue, "evidence")
        XCTAssertEqual(sources[2]["record"]?.stringValue, "record://event/\(evidence)")
    }

    func testRoutineWithoutRunStartedHasNoTriggerSources() async throws {
        let log = BotProvenanceTestLog()
        let service = BotProvenanceService(eventLog: log)
        let triggers = try await service.routineDerivationSources(
            botID: "main", sessionID: "routine-session")
        XCTAssertTrue(triggers.isEmpty)
        // No source means no derivation: a memory artifact must not become current.
        _ = try await log.append(ProvenanceTest.event(
            type: "memory.document_written", eventId: "routine-no-source",
            data: .object([
                "path": .string("agent/weekly.md"), "version": .number(1),
                "evidence": .array([]),
            ]), principalKind: "routine", sessionID: "routine-session"))
        let state = try await service.currentState(for: BotDerivedRef(
            kind: .memory, id: "agent/weekly.md", version: 1))
        XCTAssertEqual(state.state, .unknown)
        XCTAssertEqual(state.reasons, [.noDerivation])
    }

}
