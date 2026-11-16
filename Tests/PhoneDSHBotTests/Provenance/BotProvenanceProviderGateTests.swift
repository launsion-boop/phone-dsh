// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

private actor CountingRechecker: BotProvenanceRechecking {
    private(set) var calls = 0
    var outcome: BotProvenanceRecheckOutcome

    init(outcome: BotProvenanceRecheckOutcome) { self.outcome = outcome }

    func recheck(resource: BotResourceIdentity,
                 baseline: BotProvenanceSourceVersion,
                 botID: String?) async -> BotProvenanceRecheckOutcome {
        calls += 1
        return outcome
    }

    func callCount() -> Int { calls }
}

private actor CountingSkillRechecker: BotSkillRechecking {
    private(set) var calls = 0
    var outcome: BotSkillRecheckOutcome

    init(outcome: BotSkillRecheckOutcome) { self.outcome = outcome }

    func recheckSkill(name: String, file: String,
                      expectedSHA256: String) async -> BotSkillRecheckOutcome {
        calls += 1
        return outcome
    }

    func callCount() -> Int { calls }
}

/// A03/A08: a provider read must not happen after the lineage is already known
/// invalid. Counting doubles stand in for file/HTTP providers.
final class BotProvenanceProviderGateTests: XCTestCase {
    private func memoryEvent(path: String, source: String, baseline: String,
                             grantId: String?, botID: String = "bot-a",
                             eventId: String) -> BotEvent {
        var sourceObject: [String: BotJSONValue] = [
            "record": .string(source), "role": .string("evidence"),
            "sourceVersion": .object([
                "basis": .string("etag"), "value": .string(baseline),
                "observed_at_ms": .number(1_000),
            ]),
        ]
        if let grantId { sourceObject["grantId"] = .string(grantId) }
        return ProvenanceTest.event(
            type: "memory.document_written", eventId: eventId,
            data: .object([
                "path": .string(path), "version": .number(1),
                "derivation": .object([
                    "artifact": .object([
                        "kind": .string("memory"), "id": .string(path),
                        "version": .number(1),
                    ]),
                    "sources": .array([.object(sourceObject)]),
                ]),
            ]), principalKind: "chat", botID: botID,
            sessionID: "gb-\(botID)")
    }

    private func sourceEvent(_ log: BotProvenanceTestLog,
                             id: String = "gate-source") async throws -> Int {
        try await log.append(ProvenanceTest.toolResultEvent(
            eventId: id, source: "web", origin: "https://gate.example/a",
            owner: "bot-a", at: 1_000))
    }

    func testNormalSourceStillCallsProviderAndIsCurrent() async throws {
        let log = BotProvenanceTestLog()
        let source = try await sourceEvent(log)
        _ = try await log.append(memoryEvent(
            path: "agent/gate.md", source: "record://event/\(source)",
            baseline: "etag:a", grantId: nil, eventId: "gate-normal"))
        let rechecker = CountingRechecker(outcome: .same(atMS: 2_000))
        let service = BotProvenanceService(eventLog: log, rechecker: rechecker)
        let statuses = try await service.sourceStatuses(for: BotDerivedRef(
            kind: .memory, id: "agent/gate.md", version: 1))
        XCTAssertEqual(statuses.first?.state, .current)
        let normalCalls = await rechecker.callCount()
        XCTAssertEqual(normalCalls, 1)
    }

    func testErasedSourceDoesNotCallProvider() async throws {
        let log = BotProvenanceTestLog()
        let source = try await sourceEvent(log, id: "gate-erased")
        _ = try await log.append(memoryEvent(
            path: "agent/erased.md", source: "record://event/\(source)",
            baseline: "etag:a", grantId: nil, eventId: "gate-erased-memory"))
        _ = try await log.append(ProvenanceTest.erasureEvent(
            erasureId: "gate-erased", eventRecords: ["record://event/\(source)"]))
        let rechecker = CountingRechecker(outcome: .same(atMS: 2_000))
        let service = BotProvenanceService(eventLog: log, rechecker: rechecker)
        let status = try await service.currentState(
            for: BotDerivedRef(kind: .memory, id: "agent/erased.md", version: 1))
        XCTAssertEqual(status.state, .erased)
        let erasedCalls = await rechecker.callCount()
        XCTAssertEqual(erasedCalls, 0)
    }

    func testRevokedGrantDoesNotCallProviderAndNewCarrierCannotResurrect() async throws {
        let log = BotProvenanceTestLog()
        let source = try await sourceEvent(log, id: "gate-revoked")
        _ = try await log.append(ProvenanceTest.event(
            type: "grant.revoked", eventId: "revoke-gate",
            data: .object(["grantId": .string("g1")])))
        // The carrier is written *after* revocation, but reuses the old grant.
        // It must stay revoked, not become current because its carrierSeq is
        // newer than the revocation sequence.
        _ = try await log.append(memoryEvent(
            path: "agent/revoked.md", source: "record://event/\(source)",
            baseline: "etag:a", grantId: "g1", eventId: "gate-revoked-memory"))
        let rechecker = CountingRechecker(outcome: .same(atMS: 2_000))
        let service = BotProvenanceService(eventLog: log, rechecker: rechecker)
        let status = try await service.currentState(
            for: BotDerivedRef(kind: .memory, id: "agent/revoked.md", version: 1))
        XCTAssertEqual(status.state, .revoked)
        XCTAssertEqual(status.reasons, [.grantRevoked])
        let erasedCalls = await rechecker.callCount()
        XCTAssertEqual(erasedCalls, 0)
    }

    func testSkillSourceErasedDoesNotCallFileProvider() async throws {
        let log = BotProvenanceTestLog()
        let source = try await log.append(ProvenanceTest.event(
            type: "conversation.user_message", eventId: "gate-skill-source",
            data: .object(["text": .string("source")])))
        let skillRechecker = CountingSkillRechecker(outcome: .same(atMS: 2_000))
        let service = BotProvenanceService(
            eventLog: log, skillRechecker: skillRechecker)
        _ = try await service.recordSkillWrite(BotSkillWriteRequest(
            name: "gate-skill", file: "gate-skill.md", revision: 1,
            action: .write,
            contentSHA256: "sha256:" + String(repeating: "a", count: 64),
            bytes: 18, previousSHA256: nil,
            author: BotSkillChangeAuthor(kind: "user", botID: "bot-a"),
            atMS: 1_500,
            sources: [BotDerivationSource(
                record: "record://event/\(source)", role: .evidence)]))
        _ = try await log.append(ProvenanceTest.erasureEvent(
            erasureId: "gate-skill-erased",
            eventRecords: ["record://event/\(source)"]))
        let state = try await service.currentState(
            for: BotDerivedRef(kind: .skill, id: "gate-skill", version: 1))
        XCTAssertEqual(state.state, .erased)
        let skillCalls = await skillRechecker.callCount()
        XCTAssertEqual(skillCalls, 0)
    }

    func testPrepareDerivationPreservesGrantBinding() async throws {
        let log = BotProvenanceTestLog()
        let source = try await sourceEvent(log, id: "gate-grant-binding")
        let service = BotProvenanceService(eventLog: log)
        let prepared = try await service.prepareDerivation(
            artifact: BotDerivedRef(kind: .memory, id: "agent/binding.md", version: 1),
            sources: [BotDerivationSource(
                record: "record://event/\(source)", role: .evidence,
                sourceVersion: .known(basis: .etag, value: "etag:a"),
                grantId: "g1")])
        XCTAssertEqual(prepared["sources"]?.arrayValue?.first?["grantId"]?.stringValue, "g1")
    }
}
