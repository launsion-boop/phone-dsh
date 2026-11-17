// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// P lane, G-1 r8 Plan A: the provenance owner constructs `derivation.sources`
/// (including `resource`); P validates and persists it verbatim and never
/// derives a resource identity itself.
final class MemoryDerivationOverrideTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteDomainStore!
    private var memory: BotMemory!
    private let now: Int64 = 1_760_000_040_000
    private let observationRef = "record://session/gb-main#5"
    private let userRef = "record://session/gb-main#3"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-derivation-override-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try SQLiteDomainStore(
            fileURL: root.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        memory = BotMemory(
            store: SQLiteBotMemoryDocumentStore(eventLog: store, botID: "bot-a", now: { self.now }),
            botID: "bot-a", now: { self.now })
    }

    override func tearDown() async throws {
        try? await store?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testOverridePersistsResourceAndVersionWithoutAResolver() async throws {
        let path = "agent/notes/override.md"
        let resource = BotMemoryResource(
            kind: "file", key: "imports/attachments-a/report.txt",
            owner: "bot-a", scope: "agent")
        let baseline = BotSourceBaseline(
            record: observationRef, role: .evidence,
            sourceVersion: .known(BotKnownSourceVersion(
                kind: .contentSHA256, value: "sha256:" + String(repeating: "a", count: 64),
                observedAtMS: 1_760_000_005_000, basisRef: observationRef)),
            resource: resource)
        let result = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: path, content: "from the file",
                expectedVersion: 0, evidence: [observationRef],
                sourceBaselines: [baseline]),
            context: context())
        XCTAssertTrue(result.ok, "\(String(describing: result.code))")

        let event = try await documentWrittenEvent(path: path, version: 1)
        let derivation = try XCTUnwrap(event.data["derivation"]?.objectValue)
        let sources = try XCTUnwrap(derivation["sources"]?.arrayValue)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0]["record"]?.stringValue, observationRef)
        XCTAssertEqual(sources[0]["role"]?.stringValue, "evidence")
        let version = try XCTUnwrap(sources[0]["sourceVersion"]?.objectValue)
        XCTAssertEqual(version["basis"]?.stringValue, "content-sha256")
        let storedResource = try XCTUnwrap(sources[0]["resource"]?.objectValue)
        XCTAssertEqual(storedResource["kind"]?.stringValue, "file")
        XCTAssertEqual(storedResource["key"]?.stringValue, "imports/attachments-a/report.txt")
        XCTAssertEqual(storedResource["owner"]?.stringValue, "bot-a")
        XCTAssertEqual(storedResource["scope"]?.stringValue, "agent")
    }

    func testNonObservationBaselineNeedsNoResource() async throws {
        let path = "agent/notes/override-user.md"
        let result = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: path, content: "user said so",
                expectedVersion: 0, evidence: [userRef],
                sourceBaselines: [BotSourceBaseline(
                    record: userRef, role: .evidence, sourceVersion: nil)]),
            context: context())
        XCTAssertTrue(result.ok, "\(String(describing: result.code))")
        let event = try await documentWrittenEvent(path: path, version: 1)
        let source = try XCTUnwrap(event.data["derivation"]?["sources"]?.arrayValue?.first)
        XCTAssertNil(source["sourceVersion"])
        XCTAssertNil(source["resource"])
    }

    func testObservationBaselineWithoutResourceFailsClosed() async throws {
        let path = "agent/notes/override-no-resource.md"
        let result = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: path, content: "x",
                expectedVersion: 0, evidence: [observationRef],
                sourceBaselines: [BotSourceBaseline(
                    record: observationRef, role: .evidence,
                    sourceVersion: .known(BotKnownSourceVersion(
                        kind: .contentSHA256, value: "sha256:abc",
                        observedAtMS: 1, basisRef: observationRef)))]),
            context: context())
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.code, "memory-source-baseline-unavailable")
        let events = try await documentWrittenEvents(path: path)
        XCTAssertTrue(events.isEmpty)
    }

    func testOverrideMustCoverEveryEvidenceAndReviewRef() async throws {
        let path = "agent/notes/override-missing.md"
        let result = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: path, content: "x",
                expectedVersion: 0, evidence: [userRef],
                sourceBaselines: []),
            context: context())
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.code, "memory-source-baseline-unavailable")
        let events = try await documentWrittenEvents(path: path)
        XCTAssertTrue(events.isEmpty)
    }

    func testDuplicateRecordRoleFailsClosed() async throws {
        let path = "agent/notes/override-dup.md"
        let baseline = BotSourceBaseline(
            record: userRef, role: .evidence, sourceVersion: nil)
        let result = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: path, content: "x",
                expectedVersion: 0, evidence: [userRef],
                sourceBaselines: [baseline, baseline]),
            context: context())
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.code, "memory-source-baseline-unavailable")
        let events = try await documentWrittenEvents(path: path)
        XCTAssertTrue(events.isEmpty)
    }

    func testRestoreUsesSuppliedDerivationWithTheNewVersion() async throws {
        let path = "agent/notes/override-restore.md"
        _ = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: path, content: "one",
                expectedVersion: 0, evidence: [userRef]),
            context: context())
        _ = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: path, content: "two", expectedVersion: 1),
            context: context())
        let supplied = BotSourceBaseline(
            record: userRef, role: .evidence, sourceVersion: nil)
        let restored = try await memory.write(
            BotMemoryWriteRequest(
                action: .restore, path: path, expectedVersion: 2, restoreVersion: 1,
                sourceBaselines: [supplied]),
            context: context())
        XCTAssertTrue(restored.ok, "\(String(describing: restored.code))")
        let event = try await documentWrittenEvent(path: path, version: 3)
        let artifact = try XCTUnwrap(event.data["derivation"]?["artifact"]?.objectValue)
        XCTAssertEqual(artifact["version"]?.intValue, 3)
        XCTAssertEqual(event.data["derivation"]?["sources"]?.arrayValue?.count, 1)
    }

    // MARK: - Helpers

    private func context() -> BotMemoryWriteContext {
        BotMemoryWriteContext(
            botID: "bot-a", sessionID: "gb-main", authorKind: .chat,
            source: BotMemorySource(kind: .userTurn, sessionID: "gb-main"),
            trust: .observation, isMainBot: true)
    }

    private func documentWrittenEvents(path: String) async throws -> [BotEvent] {
        let events = try await store.events(after: 0, limit: 100)
        return events.filter {
            $0.type == "memory.document_written" && $0.data["path"]?.stringValue == path
        }
    }

    private func documentWrittenEvent(path: String, version: Int) async throws -> BotEvent {
        let events = try await documentWrittenEvents(path: path)
        guard let event = events.first(where: { $0.data["version"]?.intValue == version }) else {
            throw BotMemoryTestError.seedFailed("\(path) has no version \(version) event")
        }
        return event
    }
}
