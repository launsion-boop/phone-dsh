// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Root A04 review point: `inspectSources` must use artifact-scoped statuses.
/// One record can be current under one memory version, changed under another,
/// and revoked through a grant; the refs overload flattens all three into
/// `unknown/no-baseline`.
final class BotArtifactSourceInspectionTests: XCTestCase {
    private struct BaselineRechecker: BotProvenanceRechecking {
        func recheck(resource: BotResourceIdentity,
                     baseline: BotProvenanceSourceVersion,
                     botID: String?) async -> BotProvenanceRecheckOutcome {
            switch baseline.knownFields?.value {
            case "etag:e1":
                return .same(atMS: 1_250)
            case "etag:e2":
                return .changed(
                    version: .known(basis: .etag, value: "etag:e3", observedAtMS: 1_250),
                    atMS: 1_250)
            default:
                return .notPerformed
            }
        }
    }

    private let resource = BotResourceIdentity(
        kind: .file, key: "notes/source.md", owner: "main", scope: "agent")

    private func carrier(eventID: String, artifact: BotDerivedRef,
                         record: String, version: String, grantID: String? = nil,
                         botID: String = "main") throws -> BotEvent {
        let derivation = BotDerivation(
            artifact: artifact,
            sources: [BotDerivationSource(
                record: record, role: .evidence, resource: resource,
                sourceVersion: .known(basis: .etag, value: version, observedAtMS: 1_000),
                grantId: grantID)])
        return ProvenanceTest.event(
            type: "memory.document_written", eventId: eventID, at: 1_100,
            data: .object([
                "path": .string(artifact.id),
                "version": .number(Double(artifact.version ?? 1)),
                "derivation": try ProvenanceTest.encoded(derivation),
            ]),
            botID: botID)
    }

    func testDifferentBaselinesAndRevocationStayDistinct() async throws {
        let log = BotProvenanceTestLog()
        let source = try await log.append(ProvenanceTest.toolResultEvent(
            eventId: "source-a", source: "web", origin: "https://example.test/a",
            owner: "main", text: "weekly source", resource: resource,
            at: 1_000, sessionID: "gb-main", seq: 1))
        let record = "record://event/\(source)"
        let path = "agent/playbook/weekly.md"
        let current = BotDerivedRef(kind: .memory, id: path, version: 1)
        let changed = BotDerivedRef(kind: .memory, id: path, version: 2)
        let revoked = BotDerivedRef(kind: .memory, id: path, version: 3)
        _ = try await log.append(carrier(
            eventID: "carrier-current", artifact: current,
            record: record, version: "etag:e1"))
        _ = try await log.append(carrier(
            eventID: "carrier-changed", artifact: changed,
            record: record, version: "etag:e2"))
        _ = try await log.append(carrier(
            eventID: "carrier-revoked", artifact: revoked,
            record: record, version: "etag:e1", grantID: "grant-1"))
        _ = try await log.append(ProvenanceTest.event(
            type: "grant.revoked", eventId: "revoke-grant-1", at: 1_200,
            data: .object(["grantId": .string("grant-1")])))

        let provenance = BotProvenanceService(
            eventLog: log, rechecker: BaselineRechecker())
        let merged = try await BotArtifactSourceInspection.inspect(
            eventIDs: ["carrier-current", "carrier-changed", "carrier-revoked"],
            botID: "main", provenance: provenance)

        XCTAssertEqual(merged.count, 3, "different baselines/states must stay separate")
        let states = Set(merged.map(\.state))
        XCTAssertEqual(states, [.current, .changed, .revoked])
        let currentRow = try XCTUnwrap(merged.first { $0.state == .current })
        XCTAssertEqual(currentRow.sourceVersion?.knownValue, "etag:e1")
        XCTAssertNil(currentRow.reasons.first)
        let changedRow = try XCTUnwrap(merged.first { $0.state == .changed })
        XCTAssertEqual(changedRow.sourceVersion?.knownValue, "etag:e2")
        XCTAssertTrue(changedRow.reasons.contains(.sourceChanged))
        let revokedRow = try XCTUnwrap(merged.first { $0.state == .revoked })
        XCTAssertTrue(revokedRow.reasons.contains(.grantRevoked))
        for row in merged {
            XCTAssertEqual(row.record, record)
            XCTAssertEqual(row.role, .evidence)
        }
    }

    func testSameBaselineMergesArtifactCountInsteadOfDuplicating() async throws {
        let log = BotProvenanceTestLog()
        let source = try await log.append(ProvenanceTest.toolResultEvent(
            eventId: "source-b", source: "web", origin: "https://example.test/b",
            owner: "main", text: "shared source", resource: resource,
            at: 1_000, sessionID: "gb-main", seq: 1))
        let record = "record://event/\(source)"
        _ = try await log.append(carrier(
            eventID: "carrier-b1", artifact: .init(kind: .memory, id: "agent/a.md", version: 1),
            record: record, version: "etag:e1"))
        _ = try await log.append(carrier(
            eventID: "carrier-b2", artifact: .init(kind: .memory, id: "agent/b.md", version: 1),
            record: record, version: "etag:e1"))
        let provenance = BotProvenanceService(eventLog: log, rechecker: BaselineRechecker())
        let merged = try await BotArtifactSourceInspection.inspect(
            eventIDs: ["carrier-b1", "carrier-b2"], botID: "main", provenance: provenance)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].artifactCount, 2)
        XCTAssertEqual(merged[0].state, .current)
    }

    func testCrossBotArtifactDoesNotEnterAnotherBotsInspection() async throws {
        let log = BotProvenanceTestLog()
        let mainSource = try await log.append(ProvenanceTest.toolResultEvent(
            eventId: "source-main", source: "web", origin: "https://example.test/main",
            owner: "main", text: "main source", resource: resource,
            at: 1_000, sessionID: "gb-main", seq: 1))
        let otherSource = try await log.append(ProvenanceTest.toolResultEvent(
            eventId: "source-other", source: "web", origin: "https://example.test/other",
            owner: "other", text: "other source", resource: resource,
            at: 1_000, sessionID: "gb-other", seq: 1))
        _ = try await log.append(carrier(
            eventID: "carrier-main", artifact: .init(kind: .memory, id: "agent/main.md", version: 1),
            record: "record://event/\(mainSource)", version: "etag:e1"))
        _ = try await log.append(carrier(
            eventID: "carrier-other", artifact: .init(kind: .memory, id: "agent/other.md", version: 1),
            record: "record://event/\(otherSource)", version: "etag:e1", botID: "other"))
        let provenance = BotProvenanceService(eventLog: log, rechecker: BaselineRechecker())
        let merged = try await BotArtifactSourceInspection.inspect(
            eventIDs: ["carrier-main", "carrier-other"], botID: "main",
            provenance: provenance)
        XCTAssertTrue(merged.contains { $0.record == "record://event/\(mainSource)" })
        XCTAssertFalse(merged.contains { $0.record == "record://event/\(otherSource)" })
    }
}
