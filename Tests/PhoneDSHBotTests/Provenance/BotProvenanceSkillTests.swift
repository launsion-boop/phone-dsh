// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// G-4 skill.lineage: real `skill.changed` carriers + host file recheck decide
/// the current state. Skill files remain plugin-written; L only records lineage.
final class BotProvenanceSkillTests: XCTestCase {
    private let hash1 = "sha256:" + String(repeating: "a", count: 64)
    private let hash2 = "sha256:" + String(repeating: "b", count: 64)

    private func author() -> BotSkillChangeAuthor {
        BotSkillChangeAuthor(kind: "user", botID: "main", sessionID: "gb-main")
    }

    func testCreateCurrentAfterRecheckAndCarrierShape() async throws {
        let log = BotProvenanceTestLog()
        let source = try await log.append(ProvenanceTest.event(
            type: "conversation.user_message", eventId: "skill-source",
            data: .object(["text": .string("write the weekly skill")])))
        let service = BotProvenanceService(
            eventLog: log,
            skillRechecker: BotProvenanceTestSkillRechecker(
                outcome: .same(atMS: 2_100)))
        let artifact = try await service.recordSkillWrite(BotSkillWriteRequest(
            name: "weekly-report", file: "weekly-report.md", revision: 1,
            action: .write, contentSHA256: hash1, bytes: 18, previousSHA256: nil,
            author: author(), atMS: 2_000,
            sources: [BotDerivationSource(
                record: "record://event/\(source)", role: .creator)]))
        XCTAssertEqual(artifact, BotDerivedRef(
            kind: .skill, id: "weekly-report", version: 1))

        let state = try await service.currentState(for: artifact)
        XCTAssertEqual(state.state, .current)
        XCTAssertEqual(state.carrier, "record://event/2")
        XCTAssertEqual(state.sources.first?.record, "record://event/\(source)")
        XCTAssertFalse(state.reasons.contains(.noSkillWriteEvent))

        let events = await log.all()
        let event = try XCTUnwrap(events.first { $0.type == "skill.changed" })
        XCTAssertEqual(event.ignorable, true)
        XCTAssertEqual(event.data["schema"]?.stringValue, "bot-skill-change/v1")
        XCTAssertEqual(event.data["action"]?.stringValue, "write")
        XCTAssertEqual(event.data["skill"]?["name"]?.stringValue, "weekly-report")
        XCTAssertEqual(event.data["skill"]?["revision"]?.intValue, 1)
        XCTAssertEqual(event.data["skill"]?["content_sha256"]?.stringValue, hash1)
        XCTAssertEqual(event.data["skill"]?["bytes"]?.intValue, 18)
        XCTAssertEqual(event.data["author"]?["kind"]?.stringValue, "user")

        // Idempotent retry does not append a second carrier.
        _ = try await service.recordSkillWrite(BotSkillWriteRequest(
            name: "weekly-report", file: "weekly-report.md", revision: 1,
            action: .write, contentSHA256: hash1, bytes: 18, previousSHA256: nil,
            author: author(), atMS: 2_000, sources: []))
        let after = await log.all()
        XCTAssertEqual(after.filter { $0.type == "skill.changed" }.count, 1)
    }

    func testNoRecheckIsNotCurrentAndChangedHashIsChanged() async throws {
        let log = BotProvenanceTestLog()
        let noRecheck = BotProvenanceService(eventLog: log)
        let artifact = try await noRecheck.recordSkillWrite(BotSkillWriteRequest(
            name: "weekly-report", file: "weekly-report.md", revision: 1,
            action: .write, contentSHA256: hash1, bytes: 18, previousSHA256: nil,
            author: author(), atMS: 2_000, sources: []))
        let unknown = try await noRecheck.currentState(for: artifact)
        XCTAssertEqual(unknown.state, .unknown)
        XCTAssertEqual(unknown.reasons, [.refreshNotPerformed])

        let changedService = BotProvenanceService(
            eventLog: log,
            skillRechecker: BotProvenanceTestSkillRechecker(
                outcome: .changed(actualSHA256: hash2, atMS: 2_100)))
        let changed = try await changedService.currentState(for: artifact)
        XCTAssertEqual(changed.state, .changed)
        XCTAssertEqual(changed.reasons, [.sourceChanged])
    }

    func testDeleteMakesSkillDeleted() async throws {
        let log = BotProvenanceTestLog()
        let service = BotProvenanceService(
            eventLog: log,
            skillRechecker: BotProvenanceTestSkillRechecker(
                outcome: .same(atMS: 2_100)))
        let artifact = try await service.recordSkillWrite(BotSkillWriteRequest(
            name: "weekly-report", file: "weekly-report.md", revision: 1,
            action: .write, contentSHA256: hash1, bytes: 18, previousSHA256: nil,
            author: author(), atMS: 2_000, sources: []))
        let deleted = try await service.recordSkillWrite(BotSkillWriteRequest(
            name: "weekly-report", file: "weekly-report.md", revision: 2,
            action: .delete, contentSHA256: nil, bytes: nil,
            previousSHA256: hash1, author: author(), atMS: 2_100, sources: []))
        XCTAssertEqual(artifact.id, deleted.id)
        XCTAssertEqual(deleted.version, 2)
        let state = try await service.currentState(for: deleted)
        XCTAssertEqual(state.state, .unavailable)
        XCTAssertEqual(state.reasons, [.skillDeleted])
    }

    func testSkillUpdateUsesPreviousCarrierAsSource() async throws {
        let log = BotProvenanceTestLog()
        let service = BotProvenanceService(
            eventLog: log,
            skillRechecker: BotProvenanceTestSkillRechecker(
                outcome: .same(atMS: 2_100)))
        _ = try await service.recordSkillWrite(BotSkillWriteRequest(
            name: "weekly-report", file: "weekly-report.md", revision: 1,
            action: .write, contentSHA256: hash1, bytes: 18, previousSHA256: nil,
            author: author(), atMS: 2_000, sources: []))
        let events = await log.all()
        let carrier = try XCTUnwrap(
            events.first { $0.type == "skill.changed" }?.commitSeq)
        let second = try await service.recordSkillWrite(BotSkillWriteRequest(
            name: "weekly-report", file: "weekly-report.md", revision: 2,
            action: .write, contentSHA256: hash2, bytes: 19,
            previousSHA256: hash1, author: author(), atMS: 2_100,
            sources: [BotDerivationSource(
                record: "record://event/\(carrier)", role: .basis)]))
        let state = try await service.currentState(for: second)
        XCTAssertEqual(state.state, .current)
        XCTAssertEqual(state.carrier, "record://event/2")
        XCTAssertEqual(state.sources.first?.record, "record://event/\(carrier)")
    }

    func testInvalidSkillChangeRejected() async throws {
        let log = BotProvenanceTestLog()
        let service = BotProvenanceService(eventLog: log)
        do {
            _ = try await service.recordSkillWrite(BotSkillWriteRequest(
                name: "Bad Name", file: "Bad Name.md", revision: 1,
                action: .write, contentSHA256: hash1, bytes: 18,
                previousSHA256: nil, author: author(), atMS: 1_000, sources: []))
            XCTFail("invalid skill name accepted")
        } catch {}
        do {
            _ = try await service.recordSkillWrite(BotSkillWriteRequest(
                name: "weekly-report", file: "weekly-report.md", revision: 1,
                action: .write, contentSHA256: "sha256:XYZ", bytes: 18,
                previousSHA256: nil, author: author(), atMS: 1_000, sources: []))
            XCTFail("invalid digest accepted")
        } catch {}
    }
}

extension BotProvenanceSkillTests {
    /// G-1 skill identity: two Bots may have the same project-dsh skill name.
    func testProjectSkillIdentityIsPerBotNotNameOnly() async throws {
        let log = BotProvenanceTestLog()
        let service = BotProvenanceService(
            eventLog: log,
            skillRechecker: BotProvenanceTestSkillRechecker(
                outcome: .same(atMS: 2_000)))
        let digest = "sha256:" + String(repeating: "d", count: 64)
        for owner in ["bot-a", "bot-b"] {
            _ = try await service.recordSkillWrite(BotSkillWriteRequest(
                name: "weekly-report", file: "weekly-report.md", revision: 1,
                action: .write, contentSHA256: digest, bytes: 18,
                previousSHA256: nil,
                author: BotSkillChangeAuthor(kind: "bot", botID: owner),
                atMS: 1_500, sources: [],
                source: .projectDsh, ownerBotID: owner))
        }
        let written = await log.all()
        XCTAssertEqual(written.count, 2)
        XCTAssertEqual(
            written.first?.data["skill"]?["source"]?.stringValue, "project-dsh")
        let snapshot = BotProvenanceSnapshot.build(events: written)
        let first = try XCTUnwrap(snapshot.assertions.values.first?.first)
        XCTAssertEqual(first.skillSource, "project-dsh")
        XCTAssertEqual(first.skillOwnerBotID, "bot-a")
        let aScoped = snapshot.scoped(botID: "bot-a")
        XCTAssertEqual(aScoped.assertions.values.first?.count, 1)
        XCTAssertEqual(
            aScoped.assertions.values.first?.first?.skillOwnerBotID, "bot-a")
        let aIdentity = BotSkillIdentity(
            source: .projectDsh, ownerBotID: "bot-a", name: "weekly-report")
        let aSkillScoped = aScoped.skillScoped(aIdentity, botID: "bot-a")
        XCTAssertEqual(aSkillScoped.assertions.values.first?.count, 1)
        for owner in ["bot-a", "bot-b"] {
            let identity = BotSkillIdentity(
                source: .projectDsh, ownerBotID: owner, name: "weekly-report")
            let state = try await service.currentState(
                forSkill: identity, botID: owner)
            XCTAssertEqual(state.state, .current)
            XCTAssertEqual(state.carrier,
                           owner == "bot-a"
                               ? "record://event/1" : "record://event/2")
            let latest = try await service.latestSkillChange(identity: identity)
            XCTAssertEqual(latest?.ownerBotID, owner)
            XCTAssertEqual(latest?.source, .projectDsh)
        }
        let legacy = BotSkillIdentity(name: "weekly-report")
        let style = try await service.currentState(forSkill: legacy, botID: "bot-a")
        XCTAssertEqual(style.state, .unknown)
        XCTAssertEqual(style.reasons, [.noSkillWriteEvent])
    }
}

extension BotProvenanceSkillTests {
    func testSkillToolEligibilityUsesPrivateIdentityAndErasedSource() async throws {
        let log = BotProvenanceTestLog()
        let source = try await log.append(ProvenanceTest.event(
            type: "conversation.user_message", eventId: "skill-tool-source",
            data: .object(["text": .string("source")]), botID: "bot-a"))
        let service = BotProvenanceService(
            eventLog: log,
            skillRechecker: BotProvenanceTestSkillRechecker(
                outcome: .same(atMS: 2_000)))
        _ = try await service.recordSkillWrite(BotSkillWriteRequest(
            name: "weekly-report", file: "weekly-report.md", revision: 1,
            action: .write,
            contentSHA256: "sha256:" + String(repeating: "e", count: 64),
            bytes: 18, previousSHA256: nil,
            author: BotSkillChangeAuthor(kind: "bot", botID: "bot-a"),
            atMS: 1_500,
            sources: [BotDerivationSource(
                record: "record://event/\(source)", role: .evidence)],
            source: .projectDsh, ownerBotID: "bot-a"))
        let current = await service.status(
            forSkillName: "weekly-report", botID: "bot-a")
        XCTAssertEqual(current, .current)
        let untracked = await service.status(
            forSkillName: "missing-report", botID: "bot-a")
        XCTAssertNil(untracked)
        _ = try await log.append(ProvenanceTest.erasureEvent(
            erasureId: "skill-tool-erase",
            eventRecords: ["record://event/\(source)"]))
        let erased = await service.status(
            forSkillName: "weekly-report", botID: "bot-a")
        XCTAssertEqual(erased, .erased)
    }

    func testPrivateCurrentShadowsGlobalErasedSkillOfTheSameName() async throws {
        let log = BotProvenanceTestLog()
        let service = BotProvenanceService(
            eventLog: log,
            skillRechecker: BotProvenanceTestSkillRechecker(
                outcome: .same(atMS: 2_000)))
        let digest = "sha256:" + String(repeating: "f", count: 64)
        _ = try await service.recordSkillWrite(BotSkillWriteRequest(
            name: "weekly-report", file: "weekly-report.md", revision: 1,
            action: .write, contentSHA256: digest, bytes: 18,
            previousSHA256: nil,
            author: BotSkillChangeAuthor(kind: "user", botID: "main"),
            atMS: 1_000, sources: [], source: .userDsh))
        _ = try await service.recordSkillWrite(BotSkillWriteRequest(
            name: "weekly-report", file: "weekly-report.md", revision: 1,
            action: .write, contentSHA256: digest, bytes: 18,
            previousSHA256: nil,
            author: BotSkillChangeAuthor(kind: "bot", botID: "bot-a"),
            atMS: 1_500, sources: [], source: .projectDsh, ownerBotID: "bot-a"))
        let status = await service.status(
            forSkillName: "weekly-report", botID: "bot-a")
        XCTAssertEqual(status, .current)
    }
}
