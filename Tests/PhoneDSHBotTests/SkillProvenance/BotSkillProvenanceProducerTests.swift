// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import XCTest
@testable import PhoneDSHBot

private struct TestSkillRoots: BotSkillRootResolving {
    var roots: [String: URL]
    func root(for source: BotSkillSource, ownerBotID: String?) -> URL? {
        roots["\(source.rawValue):\(ownerBotID ?? "-")"]
    }
}

final class BotSkillProvenanceProducerTests: XCTestCase {
    private var root: URL!
    private var botRoot: String!
    private var roots: TestSkillRoots!
    private var projectDir: URL!
    private var userDir: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-producer-\(UUID().uuidString)", isDirectory: true)
        botRoot = "/dsh/workspace/.dshbot/agents/bot-a"
        projectDir = root.appendingPathComponent("materialized/workspace/.dshbot/agents/bot-a/.dsh/skills")
        userDir = root.appendingPathComponent("materialized/home/skills")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        roots = TestSkillRoots(roots: [
            "project-dsh:bot-a": projectDir,
            "project-dsh:bot-b": root.appendingPathComponent("materialized/workspace/.dshbot/agents/bot-b/.dsh/skills"),
            "user-dsh:-": userDir,
        ])
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func service(_ log: BotProvenanceTestLog) -> BotProvenanceService {
        BotProvenanceService(eventLog: log)
    }

    private func producer(_ service: BotProvenanceService,
                           botID: String = "bot-a") -> BotSkillProvenanceProducer {
        BotSkillProvenanceProducer(
            botRoot: "/dsh/workspace/.dshbot/agents/\(botID)",
            roots: roots,
            recorder: { try await service.recordSkillWrite($0) },
            latest: { try await service.latestSkillChange(identity: $0) },
            now: { 2_000 })
    }

    func testCreateUpdateAndDeleteCarrySourceOwnerRevisionAndRawBytes() async throws {
        let log = BotProvenanceTestLog()
        let service = service(log)
        let producer = producer(service)
        let file = projectDir.appendingPathComponent("weekly-report.md")
        try Data("# Weekly\n".utf8).write(to: file)

        _ = try await producer.recordBotWrite(
            vfsPath: "\(botRoot!)/.dsh/skills/weekly-report.md",
            botID: "bot-a", sessionID: "gb-main")
        var snapshot = try await service.latestSkillChange(
            identity: BotSkillIdentity(source: .projectDsh,
                                       ownerBotID: "bot-a", name: "weekly-report"))
        XCTAssertEqual(snapshot?.revision, 1)
        XCTAssertEqual(snapshot?.source, .projectDsh)
        XCTAssertEqual(snapshot?.ownerBotID, "bot-a")
        XCTAssertEqual(snapshot?.file, "weekly-report.md")
        XCTAssertEqual(snapshot?.contentSHA256,
                       sha256(Data("# Weekly\n".utf8)))

        try Data("# Weekly v2\n".utf8).write(to: file)
        _ = try await producer.recordBotWrite(
            vfsPath: "\(botRoot!)/.dsh/skills/weekly-report.md",
            botID: "bot-a", sessionID: "gb-main")
        snapshot = try await service.latestSkillChange(
            identity: BotSkillIdentity(source: .projectDsh,
                                       ownerBotID: "bot-a", name: "weekly-report"))
        XCTAssertEqual(snapshot?.revision, 2)
        XCTAssertEqual(snapshot?.contentSHA256,
                       sha256(Data("# Weekly v2\n".utf8)))

        let events = await log.all().filter { $0.type == "skill.changed" }
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.last?.data["skill"]?["source"]?.stringValue, "project-dsh")
        XCTAssertEqual(events.last?.data["skill"]?["owner_bot_id"]?.stringValue, "bot-a")
        XCTAssertNil(events.last?.data["derivation"])
        XCTAssertEqual(events.last?.data["author"]?["kind"]?.stringValue, "bot")
        XCTAssertEqual(events.last?.data["author"]?["bot_id"]?.stringValue, "bot-a")
    }

    func testSameNameInTwoBotsDoesNotShareIdentity() async throws {
        let log = BotProvenanceTestLog()
        let service = service(log)
        let fileA = projectDir.appendingPathComponent("shared.md")
        try Data("a".utf8).write(to: fileA)
        _ = try await producer(service, botID: "bot-a").recordBotWrite(
            vfsPath: "\(botRoot!)/.dsh/skills/shared.md",
            botID: "bot-a", sessionID: "gb-a")
        let snapshotB = try await service.latestSkillChange(
            identity: BotSkillIdentity(source: .projectDsh,
                                       ownerBotID: "bot-b", name: "shared"))
        XCTAssertNil(snapshotB)
        let snapshotA = try await service.latestSkillChange(
            identity: BotSkillIdentity(source: .projectDsh,
                                       ownerBotID: "bot-a", name: "shared"))
        XCTAssertEqual(snapshotA?.revision, 1)
    }

    func testProjectDeleteUsesRealAbsenceAndPreviousDurableHash() async throws {
        let log = BotProvenanceTestLog()
        let service = service(log)
        let producer = producer(service)
        let file = projectDir.appendingPathComponent("weekly-report.md")
        try Data("v1".utf8).write(to: file)
        _ = try await producer.recordBotWrite(
            vfsPath: "\(botRoot!)/.dsh/skills/weekly-report.md",
            botID: "bot-a", sessionID: "gb-main")
        try FileManager.default.removeItem(at: file)
        _ = try await producer.recordBotDelete(
            vfsPath: "\(botRoot!)/.dsh/skills/weekly-report.md",
            botID: "bot-a", sessionID: "gb-main")
        let snapshot = try await service.latestSkillChange(
            identity: BotSkillIdentity(source: .projectDsh,
                                       ownerBotID: "bot-a", name: "weekly-report"))
        XCTAssertEqual(snapshot?.revision, 2)
        XCTAssertEqual(snapshot?.action, "delete")
        XCTAssertEqual(snapshot?.previousSHA256, sha256(Data("v1".utf8)))
        XCTAssertEqual(snapshot?.ownerBotID, "bot-a")
        let events = await log.all().filter { $0.type == "skill.changed" }
        XCTAssertEqual(events.last?.data["skill"]?["source"]?.stringValue, "project-dsh")
        XCTAssertEqual(events.last?.data["skill"]?["owner_bot_id"]?.stringValue, "bot-a")
        do {
            _ = try await producer.recordBotDelete(
                vfsPath: "\(botRoot!)/.dsh/skills/weekly-report.md",
                botID: "bot-a", sessionID: "gb-main")
            XCTFail("delete of a missing file must not append")
        } catch {
            XCTAssertEqual(error as? BotSkillProvenanceError, .missingPreviousVersion)
        }
    }

    func testProjectDeleteRefusesFileStillPresent() async throws {
        let log = BotProvenanceTestLog()
        let producer = producer(service(log))
        let file = projectDir.appendingPathComponent("still.md")
        try Data("present".utf8).write(to: file)
        do {
            _ = try await producer.recordBotDelete(
                vfsPath: "\(botRoot!)/.dsh/skills/still.md",
                botID: "bot-a", sessionID: "gb-main")
            XCTFail("fileStillPresent expected")
        } catch {
            XCTAssertEqual(error as? BotSkillProvenanceError, .fileStillPresent)
        }
    }

    func testUserDshFeatureAdminWriteAndDelete() async throws {
        let log = BotProvenanceTestLog()
        let service = service(log)
        let producer = producer(service)
        let file = userDir.appendingPathComponent("weekly-report.md")
        try Data("user skill".utf8).write(to: file)
        _ = try await producer.recordUserDshWrite(fileName: "weekly-report.md")
        var snapshot = try await service.latestSkillChange(
            identity: BotSkillIdentity(source: .userDsh, name: "weekly-report"))
        XCTAssertEqual(snapshot?.revision, 1)
        XCTAssertEqual(snapshot?.source, .userDsh)
        XCTAssertNil(snapshot?.ownerBotID)
        XCTAssertNil(snapshot?.previousSHA256)

        try FileManager.default.removeItem(at: file)
        _ = try await producer.recordUserDshDelete(fileName: "weekly-report.md")
        snapshot = try await service.latestSkillChange(
            identity: BotSkillIdentity(source: .userDsh, name: "weekly-report"))
        XCTAssertEqual(snapshot?.revision, 2)
        XCTAssertEqual(snapshot?.action, "delete")
        XCTAssertEqual(snapshot?.previousSHA256,
                       sha256(Data("user skill".utf8)))
        let events = await log.all().filter { $0.type == "skill.changed" }
        XCTAssertEqual(events.last?.data["skill"]?["source"]?.stringValue, "user-dsh")
        XCTAssertNil(events.last?.data["skill"]?["owner_bot_id"])
    }

    func testRejectsOutsideSymlinkOversizeAndBadNames() async throws {
        let log = BotProvenanceTestLog()
        let service = service(log)
        let producer = producer(service)
        let outside = root.appendingPathComponent("outside.md")
        try Data("outside".utf8).write(to: outside)
        let link = projectDir.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        do {
            _ = try await producer.recordBotWrite(
                vfsPath: "\(botRoot!)/.dsh/skills/link.md",
                botID: "bot-a", sessionID: "gb-a")
            XCTFail("symlink must be refused")
        } catch {
            let refused = error as? BotSkillProvenanceError
            XCTAssertTrue(refused == .symbolicLink
                          || refused == .pathOutsideSkillRoots,
                          "symlink must be refused, got \(String(describing: refused))")
        }
        let nonSkill = try await producer.recordBotWrite(
            vfsPath: "\(botRoot!)/.dsh/skills/not-a-skill.txt",
            botID: "bot-a", sessionID: "gb-a")
        XCTAssertNil(nonSkill)
        let big = projectDir.appendingPathComponent("big.md")
        try Data(repeating: 0x61, count: BotSkillProvenanceProducer.maximumBytes + 1)
            .write(to: big)
        do {
            _ = try await producer.recordBotWrite(
                vfsPath: "\(botRoot!)/.dsh/skills/big.md",
                botID: "bot-a", sessionID: "gb-a")
            XCTFail("oversize must be refused")
        } catch {
            XCTAssertEqual(error as? BotSkillProvenanceError, .tooLarge)
        }
        let events = await log.all()
        XCTAssertEqual(events.filter { $0.type == "skill.changed" }.count, 0)
    }

    func testDeleteWithoutPriorWriteIsRejected() async throws {
        let log = BotProvenanceTestLog()
        let producer = producer(service(log))
        do {
            _ = try await producer.recordUserDshDelete(fileName: "missing.md")
            XCTFail("delete without a durable write must fail")
        } catch {
            XCTAssertEqual(error as? BotSkillProvenanceError, .missingPreviousVersion)
        }
    }

    private func sha256(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
    }

    func testEraseOfRealSourcePropagatesToSkillStatus() async throws {
        let log = BotProvenanceTestLog()
        let source = try await log.append(ProvenanceTest.event(
            type: "conversation.user_message", eventId: "skill-source",
            data: .object(["text": .string("source")]), botID: "bot-a"))
        let service = BotProvenanceService(
            eventLog: log,
            skillRechecker: BotProvenanceTestSkillRechecker(outcome: .same(atMS: 2_000)))
        let producer = BotSkillProvenanceProducer(
            botRoot: "/dsh/workspace/.dshbot/agents/bot-a",
            roots: roots,
            recorder: { try await service.recordSkillWrite($0) },
            latest: { try await service.latestSkillChange(identity: $0) },
            now: { 1_500 })
        let file = projectDir.appendingPathComponent("derived.md")
        try Data("derived".utf8).write(to: file)
        _ = try await producer.recordBotWrite(
            vfsPath: "/dsh/workspace/.dshbot/agents/bot-a/.dsh/skills/derived.md",
            botID: "bot-a", sessionID: "gb-a",
            sources: [BotDerivationSource(
                record: "record://event/\(source)", role: .evidence)])
        let current = await service.status(forSkillName: "derived", botID: "bot-a")
        XCTAssertEqual(current, .current)
        _ = try await log.append(ProvenanceTest.erasureEvent(
            erasureId: "skill-source-erase",
            eventRecords: ["record://event/\(source)"]))
        let erased = await service.status(forSkillName: "derived", botID: "bot-a")
        XCTAssertEqual(erased, .erased)
    }


    func testCreatorSourceIsDroppedWhenFinalBytesDoNotMatch() async throws {
        final class Captured: @unchecked Sendable {
            private let lock = NSLock()
            private var value: [BotDerivationSource] = []
            func set(_ sources: [BotDerivationSource]) { lock.lock(); value = sources; lock.unlock() }
            func get() -> [BotDerivationSource] { lock.lock(); defer { lock.unlock() }; return value }
        }
        let captured = Captured()
        let producer = BotSkillProvenanceProducer(
            botRoot: botRoot, roots: roots,
            recorder: { request in
                captured.set(request.sources)
                return BotDerivedRef(kind: .skill, id: request.name, version: request.revision)
            },
            latest: { _ in nil }, now: { 1 })
        let file = projectDir.appendingPathComponent("creator.md")
        try Data("final".utf8).write(to: file)
        let callRecord = "record://event/12"
        _ = try await producer.recordBotWrite(
            vfsPath: "\(botRoot!)/.dsh/skills/creator.md", botID: "bot-a",
            sessionID: "gb-a",
            sources: [BotDerivationSource(record: callRecord, role: .creator)],
            creatorRecord: callRecord,
            creatorContentSHA256: BotSkillProvenanceProducer.contentSHA256("different"))
        XCTAssertTrue(captured.get().isEmpty)
    }


    func testVerifiedCreatorCarriesTheFinalContentHash() async throws {
        final class Captured: @unchecked Sendable {
            private let lock = NSLock()
            private var value: [BotDerivationSource] = []
            func set(_ sources: [BotDerivationSource]) { lock.lock(); value = sources; lock.unlock() }
            func get() -> [BotDerivationSource] { lock.lock(); defer { lock.unlock() }; return value }
        }
        let captured = Captured()
        let producer = BotSkillProvenanceProducer(
            botRoot: botRoot, roots: roots,
            recorder: { request in
                captured.set(request.sources)
                return BotDerivedRef(kind: .skill, id: request.name, version: request.revision)
            },
            latest: { _ in nil }, now: { 1 })
        let file = projectDir.appendingPathComponent("verified.md")
        let body = "verified-final"
        try Data(body.utf8).write(to: file)
        let callRecord = "record://event/13"
        _ = try await producer.recordBotWrite(
            vfsPath: "\(botRoot!)/.dsh/skills/verified.md", botID: "bot-a",
            sessionID: "gb-a",
            sources: [BotDerivationSource(record: callRecord, role: .creator)],
            creatorRecord: callRecord,
            creatorContentSHA256: BotSkillProvenanceProducer.contentSHA256(body))
        let creator = captured.get().first { $0.role == .creator }
        XCTAssertEqual(creator?.sourceVersion?.knownValue,
                       BotSkillProvenanceProducer.contentSHA256(body))
    }

}
