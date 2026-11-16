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
    /// G-1 r20: the carrier names the real grant, even when the derivation
    /// source itself omitted grantId. L must resolve it from the carrier and
    /// still refuse the provider after revocation.
    func testCarrierGrantIsResolvedWithoutProviderResurrection() async throws {
        let log = BotProvenanceTestLog()
        let grant = BotResourceIdentity(
            kind: .contextSource, key: "calendar:g", owner: "bot-a")
        let source = try await log.append(ProvenanceTest.contextObservedEvent(
            eventId: "gate-carrier-grant", owner: "bot-a", at: 1_000,
            resource: grant, version: .known(basis: .etag, value: "etag:g"),
            grantId: "g-carrier"))
        _ = try await log.append(memoryEvent(
            path: "agent/carrier-grant.md",
            source: "record://event/\(source)", baseline: "etag:g",
            grantId: nil, eventId: "gate-carrier-memory"))
        let service = BotProvenanceService(eventLog: log)
        let prepared = try await service.prepareDerivation(
            artifact: BotDerivedRef(kind: .memory, id: "agent/carrier-grant.md", version: 1),
            sources: [BotDerivationSource(
                record: "record://event/\(source)", role: .evidence,
                sourceVersion: .known(basis: .etag, value: "etag:g"))])
        XCTAssertEqual(
            prepared["sources"]?.arrayValue?.first?["grantId"]?.stringValue,
            "g-carrier")
        _ = try await log.append(ProvenanceTest.event(
            type: "grant.revoked", eventId: "revoke-carrier-grant",
            data: .object(["grantId": .string("g-carrier")])))
        let rechecker = CountingRechecker(outcome: .same(atMS: 2_000))
        let revoked = BotProvenanceService(eventLog: log, rechecker: rechecker)
        let status = try await revoked.currentState(
            for: BotDerivedRef(kind: .memory, id: "agent/carrier-grant.md", version: 1))
        XCTAssertEqual(status.state, .revoked)
        let calls = await rechecker.callCount()
        XCTAssertEqual(calls, 0)
    }

}

private actor AwaitGate {
    private var entered = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func enter() async {
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor GatedRechecker: BotProvenanceRechecking {
    let gate: AwaitGate
    private(set) var calls = 0

    init(gate: AwaitGate) { self.gate = gate }

    func recheck(resource: BotResourceIdentity,
                 baseline: BotProvenanceSourceVersion,
                 botID: String?) async -> BotProvenanceRecheckOutcome {
        calls += 1
        await gate.enter()
        return .same(atMS: 2_000)
    }

    func callCount() -> Int { calls }
}

extension BotProvenanceProviderGateTests {
    /// G-1 r21: a revoke/erasure that lands while the provider is awaited must
    /// discard the stale same result. The provider is called once; the settled
    /// state is revoked/erased, never current.
    func testRevokeDuringProviderAwaitDoesNotBecomeCurrent() async throws {
        let log = BotProvenanceTestLog()
        let source = try await sourceEvent(log, id: "await-revoke")
        _ = try await log.append(memoryEvent(
            path: "agent/await-revoke.md", source: "record://event/\(source)",
            baseline: "etag:a", grantId: "g1", eventId: "await-revoke-memory"))
        let gate = AwaitGate()
        let rechecker = GatedRechecker(gate: gate)
        let service = BotProvenanceService(eventLog: log, rechecker: rechecker)
        let task = Task {
            try await service.currentState(
                for: BotDerivedRef(kind: .memory, id: "agent/await-revoke.md", version: 1))
        }
        await gate.waitUntilEntered()
        _ = try await log.append(ProvenanceTest.event(
            type: "grant.revoked", eventId: "await-revoke-grant",
            data: .object(["grantId": .string("g1")])))
        await gate.release()
        let state = try await task.value
        XCTAssertEqual(state.state, .revoked)
        let calls = await rechecker.callCount()
        XCTAssertEqual(calls, 1)
    }

    func testEraseDuringProviderAwaitDoesNotBecomeCurrent() async throws {
        let log = BotProvenanceTestLog()
        let source = try await sourceEvent(log, id: "await-erase")
        _ = try await log.append(memoryEvent(
            path: "agent/await-erase.md", source: "record://event/\(source)",
            baseline: "etag:a", grantId: nil, eventId: "await-erase-memory"))
        let gate = AwaitGate()
        let rechecker = GatedRechecker(gate: gate)
        let service = BotProvenanceService(eventLog: log, rechecker: rechecker)
        let task = Task {
            try await service.currentState(
                for: BotDerivedRef(kind: .memory, id: "agent/await-erase.md", version: 1))
        }
        await gate.waitUntilEntered()
        _ = try await log.append(ProvenanceTest.erasureEvent(
            erasureId: "await-erase", eventRecords: ["record://event/\(source)"]))
        await gate.release()
        let state = try await task.value
        XCTAssertEqual(state.state, .erased)
        let calls = await rechecker.callCount()
        XCTAssertEqual(calls, 1)
    }
}

extension BotProvenanceProviderGateTests {
    /// R2 seam: reverse a workspace file path through the workspaceFile
    /// artifact's derivation. Only current is injectable; untracked is nil.
    func testWorkspaceFileStatusUsesDerivationSourceAndDoesNotReviveAfterErase() async throws {
        let log = BotProvenanceTestLog()
        let source = try await log.append(ProvenanceTest.event(
            type: "conversation.user_message", eventId: "workspace-source",
            data: .object(["text": .string("source")]), botID: "bot-a"))
        _ = try await log.append(ProvenanceTest.event(
            type: "conversation.tool_result", eventId: "workspace-artifact",
            data: .object([
                "derivation": .object([
                    "artifact": .object([
                        "kind": .string("workspaceFile"),
                        "id": .string("docs/current.md"),
                    ]),
                    "sources": .array([
                        .object([
                            "record": .string("record://event/\(source)"),
                            "role": .string("evidence"),
                            "resource": .object([
                                "kind": .string("workspace-file"),
                                "key": .string("docs/current.md"),
                                "owner": .string("bot-a"),
                            ]),
                        ]),
                    ]),
                ]),
            ]), botID: "bot-a", sessionID: "gb-bot-a"))
        let service = BotProvenanceService(eventLog: log)
        let current = await service.status(
            forWorkspacePath: "docs/current.md", botID: "bot-a")
        XCTAssertEqual(current, .current)
        let unrelated = await service.status(
            forWorkspacePath: "docs/unrelated.md", botID: "bot-a")
        XCTAssertNil(unrelated)
        _ = try await log.append(ProvenanceTest.erasureEvent(
            erasureId: "workspace-erase", eventRecords: ["record://event/\(source)"]))
        let erased = await service.status(
            forWorkspacePath: "docs/current.md", botID: "bot-a")
        XCTAssertEqual(erased, .erased)
    }
}

extension BotProvenanceProviderGateTests {
    private func workspaceArtifact(
        path: String, source: String, grantId: String? = nil
    ) -> BotEvent {
        var sourceObject: [String: BotJSONValue] = [
            "record": .string(source), "role": .string("evidence"),
            "resource": .object([
                "kind": .string("workspace-file"),
                "key": .string(path),
                "owner": .string("bot-a"),
            ]),
        ]
        if let grantId { sourceObject["grantId"] = .string(grantId) }
        return ProvenanceTest.event(
            type: "conversation.tool_result",
            eventId: "workspace-artifact-\(path)",
            data: .object(["derivation": .object([
                "artifact": .object([
                    "kind": .string("workspaceFile"), "id": .string(path),
                ]),
                "sources": .array([.object(sourceObject)]),
            ])]), botID: "bot-a", sessionID: "gb-bot-a")
    }

    func testWorkspaceFileRevokedGrantIsNotCurrent() async throws {
        let log = BotProvenanceTestLog()
        let source = try await log.append(ProvenanceTest.event(
            type: "conversation.user_message", eventId: "ws-revoke-source",
            data: .object(["text": .string("source")]), botID: "bot-a"))
        _ = try await log.append(workspaceArtifact(
            path: "docs/revoked.md", source: "record://event/\(source)",
            grantId: "g1"))
        _ = try await log.append(ProvenanceTest.event(
            type: "grant.revoked", eventId: "ws-revoke-grant",
            data: .object(["grantId": .string("g1")])))
        let service = BotProvenanceService(eventLog: log)
        let status = await service.status(
            forWorkspacePath: "docs/revoked.md", botID: "bot-a")
        XCTAssertEqual(status, .revoked)
    }

    func testWorkspaceFileSurvivesUnrelatedMemoryDeleteButUntrackedIsNil() async throws {
        let log = BotProvenanceTestLog()
        let source = try await log.append(ProvenanceTest.event(
            type: "conversation.user_message", eventId: "ws-forget-source",
            data: .object(["text": .string("source")]), botID: "bot-a"))
        _ = try await log.append(workspaceArtifact(
            path: "docs/kept.md", source: "record://event/\(source)"))
        _ = try await log.append(ProvenanceTest.event(
            type: "memory.document_deleted", eventId: "ws-memory-delete",
            data: .object([
                "path": .string("agent/other.md"), "version": .number(1),
            ]), botID: "bot-a", sessionID: "gb-bot-a"))
        _ = try await log.append(ProvenanceTest.event(
            type: "conversation.tool_result", eventId: "ws-untracked",
            data: .object([:]), botID: "bot-a", sessionID: "gb-bot-a"))
        let service = BotProvenanceService(eventLog: log)
        let kept = await service.status(
            forWorkspacePath: "docs/kept.md", botID: "bot-a")
        XCTAssertEqual(kept, .current)
        let untracked = await service.status(
            forWorkspacePath: "docs/untracked.md", botID: "bot-a")
        XCTAssertNil(untracked)
        let escaped = await service.status(
            forWorkspacePath: "../outside.md", botID: "bot-a")
        XCTAssertNil(escaped)
    }
}
