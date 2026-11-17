// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Q1 P1-6: the material adapter must use L's ARTIFACT-scoped sourceStatuses,
/// not the refs overload that has no baseline. These tests build a real
/// memory-derivation artifact and drive the real BotDecisionContextService
/// caller through L's current-state logic, covering current/changed/revoked.
final class BotDecisionMaterialStateIntegrationTests: XCTestCase {
    private struct OutcomeRechecker: BotProvenanceRechecking {
        let outcome: BotProvenanceRecheckOutcome

        func recheck(resource: BotResourceIdentity,
                     baseline: BotProvenanceSourceVersion,
                     botID: String?) async -> BotProvenanceRecheckOutcome {
            outcome
        }
    }

    private static let path = "agent/playbook/weekly.md"
    private static let artifact = BotDerivedRef(kind: .memory, id: path, version: 1)
    private static let resource = BotResourceIdentity(
        kind: .file, key: "notes/source.md", owner: "bot-a", scope: "grant-7")
    private static let sourceVersion = BotProvenanceSourceVersion.known(
        basis: .etag, value: "etag:e1", observedAtMS: 1_000)

    private func makeState(
        rechecker: any BotProvenanceRechecking,
        revoked: Bool = false
    ) async throws -> (BotDecisionMaterialState, BotDecisionMaterialReason?) {
        let log = BotProvenanceTestLog()
        let source = try await log.append(ProvenanceTest.toolResultEvent(
            eventId: "material-source", source: "web",
            origin: "https://example.test/source", owner: "bot-a",
            text: "weekly source body", resource: Self.resource,
            at: 1_000, sessionID: "gb-main", seq: 1))
        let record = "record://event/\(source)"
        let derivation = BotDerivation(
            artifact: Self.artifact,
            sources: [BotDerivationSource(
                record: record, role: .evidence, resource: Self.resource,
                sourceVersion: Self.sourceVersion,
                grantId: revoked ? "grant-1" : nil)])
        _ = try await log.append(ProvenanceTest.event(
            type: "memory.document_written", eventId: "material-carrier",
            at: 1_100,
            data: .object(["derivation": try ProvenanceTest.encoded(derivation)])))
        if revoked {
            _ = try await log.append(ProvenanceTest.event(
                type: "grant.revoked", eventId: "material-revoke", at: 1_200,
                data: .object(["grantId": .string("grant-1")])))
        }
        let provenance = BotProvenanceService(eventLog: log, rechecker: rechecker)
        let adapter = BotDecisionMaterialStateAdapter(provenance: provenance)

        let made = try makeMemoryTestStore()
        defer { cleanupMemoryTestStore(made.root) }
        let memory = makeMemory(store: made.store)
        _ = try await seedDocument(
            makeDocument(
                Self.path, "weekly risk export",
                updatedAtMS: 1_100, evidence: [record]),
            store: made.store)
        let service = BotDecisionContextService(
            memoryForBot: { _ in memory },
            permissionRevision: { _, _, _ in "rev-1" },
            materialState: adapter.state(for:),
            now: { 1_250 })
        let block = try await service.materials(for: BotDecisionRequest(
            stage: .preStep, botID: "main", sessionID: "gb-main",
            turnID: "gb-main#1", query: "weekly risk export", scopes: [.agent]))
        let material = try XCTUnwrap(block.materials.first)
        XCTAssertEqual(material.path, Self.path)
        return (material.state, material.reason)
    }

    func testUnchangedArtifactIsCurrent() async throws {
        let state = try await makeState(
            rechecker: OutcomeRechecker(outcome: .same(atMS: 1_250)))
        XCTAssertEqual(state.0, .current)
        XCTAssertNil(state.1)
    }

    func testChangedArtifactIsChanged() async throws {
        let state = try await makeState(
            rechecker: OutcomeRechecker(outcome: .changed(
                version: .known(BotKnownProvenanceSourceVersion(
                    basis: .etag, value: "etag:e2", observedAtMS: 1_250)),
                atMS: 1_250)))
        XCTAssertEqual(state.0, .changed)
        XCTAssertEqual(state.1, .sourceChanged)
    }

    func testRevokedArtifactIsRevoked() async throws {
        let state = try await makeState(
            rechecker: OutcomeRechecker(outcome: .same(atMS: 1_250)),
            revoked: true)
        XCTAssertEqual(state.0, .revoked)
        XCTAssertEqual(state.1, .grantRevoked)
    }

    func testArtifactScopedQueryReceivesPathAndVersion() async throws {
        var seen: [BotDerivedRef] = []
        let provenance = BotProvenanceService(eventLog: BotProvenanceTestLog())
        let adapter = BotDecisionMaterialStateAdapter { artifact, _ in
            seen.append(artifact)
            return []
        }
        _ = await adapter.state(for: .init(
            botID: "bot-a", sessionID: "gb-main", path: Self.path,
            version: 3, evidence: ["record://event/1"]))
        XCTAssertEqual(seen, [BotDerivedRef(kind: .memory, id: Self.path, version: 3)])
        _ = provenance
    }
}
