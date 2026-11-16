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

    func testLatestSkillChangeAndFileRechecker() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-recheck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = "weekly-report.md"
        let content = Data("weekly body".utf8)
        try content.write(to: root.appendingPathComponent(file))
        let hash = "sha256:" + SHA256.hash(data: content)
            .map { String(format: "%02x", $0) }.joined()
        let rechecker = BotSkillFileRechecker(root: root)
        let same = await rechecker.recheckSkill(
            name: "weekly-report", file: file, expectedSHA256: hash)
        guard case .same = same else { return XCTFail("expected same, got \(same)") }
        try Data("changed body".utf8).write(to: root.appendingPathComponent(file))
        let changed = await rechecker.recheckSkill(
            name: "weekly-report", file: file, expectedSHA256: hash)
        guard case .changed = changed else { return XCTFail("expected changed") }
        try FileManager.default.removeItem(at: root.appendingPathComponent(file))
        let missing = await rechecker.recheckSkill(
            name: "weekly-report", file: file, expectedSHA256: hash)
        guard case .unavailable = missing else { return XCTFail("expected unavailable") }
        let escaped = await rechecker.recheckSkill(
            name: "weekly-report", file: "../escape.md", expectedSHA256: hash)
        guard case .notPerformed = escaped else { return XCTFail("expected notPerformed") }

        // Latest carrier info for host reconciliation.
        let log = BotProvenanceTestLog()
        let service = BotProvenanceService(eventLog: log)
        _ = try await service.recordSkillWrite(BotSkillWriteRequest(
            name: "weekly-report", file: file, revision: 1, action: .write,
            contentSHA256: hash, bytes: content.count, previousSHA256: nil,
            author: BotSkillChangeAuthor(kind: "system"), atMS: 1_000, sources: []))
        let latest = try await service.latestSkillChange(name: "weekly-report")
        XCTAssertEqual(latest?.revision, 1)
        XCTAssertEqual(latest?.contentSHA256, hash)
        XCTAssertEqual(latest?.action, "write")
        XCTAssertEqual(latest?.carrier, "record://event/1")
    }
}
