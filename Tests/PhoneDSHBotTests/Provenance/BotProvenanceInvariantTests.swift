// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// P0 counterexamples from the 9a373ade review: one global recheck outcome per
/// record, and one artifact key shared by two Bots.
final class BotProvenanceInvariantTests: XCTestCase {
    private struct BaselineOutcomeRechecker: BotProvenanceRechecking {
        func recheck(resource: BotResourceIdentity,
                     baseline: BotProvenanceSourceVersion,
                     botID: String?) async -> BotProvenanceRecheckOutcome {
            let value = baseline.knownFields?.value
            if value == "etag:a" { return .same(atMS: 10) }
            return .changed(
                version: .known(basis: .etag, value: "etag:a", observedAtMS: 20),
                atMS: 20)
        }
    }

    private func memoryEvent(
        path: String, source: String, role: String, baseline: String,
        botID: String, eventId: String
    ) -> BotEvent {
        ProvenanceTest.event(
            type: "memory.document_written", eventId: eventId,
            data: .object([
                "path": .string(path),
                "version": .number(1),
                "derivation": .object([
                    "artifact": .object([
                        "kind": .string("memory"), "id": .string(path),
                        "version": .number(1),
                    ]),
                    "sources": .array([.object([
                        "record": .string(source),
                        "role": .string(role),
                        "sourceVersion": .object([
                            "basis": .string("etag"), "value": .string(baseline),
                            "observed_at_ms": .number(1_000),
                        ]),
                    ])]),
                ]),
            ]),
            principalKind: "chat", botID: botID, sessionID: "gb-\(botID)")
    }

    /// Same source ref, two artifacts with different captured baselines. The
    /// recheck outcome must be selected by each artifact's baseline, not by the
    /// last assertion visited.
    func testRecheckOutcomeIsPerBaselineNotLastWriter() async throws {
        let log = BotProvenanceTestLog()
        let observationSeq = try await log.append(ProvenanceTest.toolResultEvent(
            eventId: "invariant-observation", source: "web",
            origin: "https://invariant.example/a", owner: "bot-a", at: 1_000))
        let sourceRef = "record://event/\(observationSeq)"
        _ = try await log.append(memoryEvent(
            path: "agent/a.md", source: sourceRef, role: "evidence",
            baseline: "etag:a", botID: "bot-a", eventId: "memory-a"))
        _ = try await log.append(memoryEvent(
            path: "agent/b.md", source: sourceRef, role: "evidence",
            baseline: "etag:b", botID: "bot-a", eventId: "memory-b"))
        let service = BotProvenanceService(
            eventLog: log, rechecker: BaselineOutcomeRechecker())

        let a = try await service.sourceStatuses(for: BotDerivedRef(
            kind: .memory, id: "agent/a.md", version: 1))
        let b = try await service.sourceStatuses(for: BotDerivedRef(
            kind: .memory, id: "agent/b.md", version: 1))
        XCTAssertEqual(a.first?.state, .current)
        XCTAssertEqual(a.first?.recheckedAtMS, 10)
        XCTAssertEqual(b.first?.state, .changed)
    }

    /// Two Bots can legitimately use the same agent path/version. A bot-scoped
    /// query keeps them apart; user/ stays host-shared.
    func testCrossBotSamePathAndVersionIsScopedByReaderBot() async throws {
        let log = BotProvenanceTestLog()
        let aSource = try await log.append(ProvenanceTest.event(
            type: "conversation.user_message", eventId: "a-source",
            data: .object(["text": .string("a")]), botID: "bot-a"))
        let bSource = try await log.append(ProvenanceTest.event(
            type: "conversation.user_message", eventId: "b-source",
            data: .object(["text": .string("b")]), botID: "bot-b"))
        let path = "agent/playbook/weekly.md"
        _ = try await log.append(memoryEvent(
            path: path, source: "record://event/\(aSource)", role: "evidence",
            baseline: "etag:a", botID: "bot-a", eventId: "memory-a"))
        _ = try await log.append(memoryEvent(
            path: path, source: "record://event/\(bSource)", role: "evidence",
            baseline: "etag:b", botID: "bot-b", eventId: "memory-b"))
        let service = BotProvenanceService(eventLog: log)
        let artifact = BotDerivedRef(kind: .memory, id: path, version: 1)

        let a = try await service.sourceStatuses(for: artifact, botID: "bot-a")
        let b = try await service.sourceStatuses(for: artifact, botID: "bot-b")
        XCTAssertEqual(a.first?.ref, "record://event/\(aSource)")
        XCTAssertEqual(b.first?.ref, "record://event/\(bSource)")
        let aView = try await service.currentState(for: artifact, botID: "bot-a")
        let bView = try await service.currentState(for: artifact, botID: "bot-b")
        XCTAssertEqual(aView.sources.first?.record, "record://event/\(aSource)")
        XCTAssertEqual(bView.sources.first?.record, "record://event/\(bSource)")
        // The unscoped legacy call can only collapse to the latest carrier;
        // this is the cross-Bot collision the bot-scoped query resolves.
        let legacy = try await service.sourceStatuses(for: artifact)
        XCTAssertTrue([a.first?.ref, b.first?.ref].contains(legacy.first?.ref))

        // user/ is host-shared: bot-b may query main's document lineage.
        _ = try await log.append(memoryEvent(
            path: "user/profile.md", source: "record://event/\(aSource)",
            role: "evidence", baseline: "etag:a", botID: "main",
            eventId: "memory-user"))
        let shared = try await service.sourceStatuses(
            for: BotDerivedRef(kind: .memory, id: "user/profile.md", version: 1),
            botID: "bot-b")
        XCTAssertEqual(shared.first?.ref, "record://event/\(aSource)")
        let sharedView = try await service.currentState(
            for: BotDerivedRef(kind: .memory, id: "user/profile.md", version: 1),
            botID: "bot-b")
        XCTAssertEqual(sharedView.sources.first?.record, "record://event/\(aSource)")
    }
    /// File bytes unchanged must not override an erased source or a failed
    /// upstream artifact. The skill's current body and its lineage are distinct.
    func testSkillSameHashDoesNotResurrectErasedSourceOrUpstream() async throws {
        let log = BotProvenanceTestLog()
        let source = try await log.append(ProvenanceTest.event(
            type: "conversation.user_message", eventId: "skill-source",
            data: .object(["text": .string("weekly source")])))
        let service = BotProvenanceService(
            eventLog: log,
            skillRechecker: BotProvenanceTestSkillRechecker(
                outcome: .same(atMS: 2_100)))
        _ = try await service.recordSkillWrite(BotSkillWriteRequest(
            name: "weekly-report", file: "weekly-report.md", revision: 1,
            action: .write,
            contentSHA256: "sha256:" + String(repeating: "a", count: 64),
            bytes: 18, previousSHA256: nil,
            author: BotSkillChangeAuthor(kind: "user", botID: "main"),
            atMS: 2_000,
            sources: [BotDerivationSource(
                record: "record://event/\(source)", role: .evidence)]))
        _ = try await log.append(ProvenanceTest.erasureEvent(
            erasureId: "skill-source-erased",
            eventRecords: ["record://event/\(source)"]))
        let skill = try await service.currentState(
            for: BotDerivedRef(kind: .skill, id: "weekly-report", version: 1))
        XCTAssertEqual(skill.state, .erased)
        XCTAssertTrue(skill.reasons.contains(.recordErased))
        XCTAssertNotEqual(skill.state, .current)

        // Upstream memory artifact erased through its own source, while the
        // skill file hash is still unchanged: upstream must win over recheck.
        let log2 = BotProvenanceTestLog()
        let memorySource = try await log2.append(ProvenanceTest.event(
            type: "conversation.user_message", eventId: "memory-source",
            data: .object(["text": .string("memory source")])))
        _ = try await log2.append(ProvenanceTest.event(
            type: "memory.document_written", eventId: "memory-carrier",
            data: .object([
                "path": .string("agent/weekly.md"), "version": .number(1),
                "derivation": .object([
                    "artifact": .object([
                        "kind": .string("memory"), "id": .string("agent/weekly.md"),
                        "version": .number(1),
                    ]),
                    "sources": .array([.object([
                        "record": .string("record://event/\(memorySource)"),
                        "role": .string("evidence"),
                    ])]),
                ]),
            ])))
        let service2 = BotProvenanceService(
            eventLog: log2,
            skillRechecker: BotProvenanceTestSkillRechecker(
                outcome: .same(atMS: 2_100)))
        _ = try await service2.recordSkillWrite(BotSkillWriteRequest(
            name: "weekly-report", file: "weekly-report.md", revision: 1,
            action: .write,
            contentSHA256: "sha256:" + String(repeating: "b", count: 64),
            bytes: 18, previousSHA256: nil,
            author: BotSkillChangeAuthor(kind: "user", botID: "main"),
            atMS: 2_000,
            sources: [BotDerivationSource(
                record: "record://event/2", role: .evidence)]))
        _ = try await log2.append(ProvenanceTest.erasureEvent(
            erasureId: "memory-source-erased",
            eventRecords: ["record://event/\(memorySource)"]))
        let skill2 = try await service2.currentState(
            for: BotDerivedRef(kind: .skill, id: "weekly-report", version: 1))
        XCTAssertEqual(skill2.state, .erased)
    }

}
