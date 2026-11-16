// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// P lane: restore inherits the version's evidence metadata without either
/// synthesising a review or losing the source reference, and the inherited
/// reference keeps resolving to the same source version afterwards.
final class MemoryEvidenceRestoreTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteDomainStore!
    private var gateway: BotGateway!
    private var memory: BotMemory!
    private var records: BotRecordService!
    private let now: Int64 = 1_760_000_010_000
    private let reference = "record://session/gb-main#3"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-evidence-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("materialized/home/sessions/gb-main", isDirectory: true),
            withIntermediateDirectories: true)
        try writeSessionLog()
        store = try SQLiteDomainStore(
            fileURL: root.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        gateway = BotGateway(now: { 1_000 })
        try await gateway.issueSession(botId: "bot-a", sessionId: "gb-main", kind: .chat)
        memory = BotMemory(
            store: SQLiteBotMemoryDocumentStore(eventLog: store, botID: "bot-a", now: { self.now }),
            botID: "bot-a", now: { self.now })
        records = BotRecordService(
            store: store, gateway: gateway, workspaceRoot: root, now: { 1_000 })
    }

    override func tearDown() async throws {
        try? await store?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testRestoreInheritsEvidenceReviewAndSourceVersion() async throws {
        let path = "agent/notes/plan.md"
        let context = BotMemoryWriteContext(
            botID: "bot-a", sessionID: "gb-main", authorKind: .chat,
            source: BotMemorySource(kind: .userTurn, sessionID: "gb-main"),
            trust: .observation, isMainBot: true)
        let review = BotMemoryReview(
            state: .verified, basis: .observation, refs: [reference])
        let first = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: path, content: "version one",
                expectedVersion: 0, evidence: [reference], review: review),
            context: context)
        XCTAssertTrue(first.ok, "\(String(describing: first.code))")

        // A later edit drops evidence/review on purpose; restore must bring the
        // first version's metadata back instead of inheriting the edit's empty
        // values (the bug PC-20261116-bot-aha-evidence fixed).
        let edit = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: path, content: "version two",
                expectedVersion: 1),
            context: context)
        XCTAssertTrue(edit.ok, "\(String(describing: edit.code))")

        let restored = try await memory.write(
            BotMemoryWriteRequest(
                action: .restore, path: path,
                expectedVersion: 2, restoreVersion: 1),
            context: context)
        XCTAssertTrue(restored.ok, "\(String(describing: restored.code))")

        guard case let .document(document) = try await memory.read(path: path) else {
            return XCTFail("expected a restored document")
        }
        XCTAssertEqual(document.version, 3)
        XCTAssertEqual(document.content, "version one")
        XCTAssertEqual(document.evidence, [reference])
        XCTAssertEqual(document.trust, "observation")
        XCTAssertEqual(document.review, review)
        XCTAssertEqual(document.source?.kind, .userTurn)

        // The inherited reference still names the same authoritative record and
        // therefore the same version; restore did not rewrite or re-resolve it.
        let states = try await records.sourceStates(
            for: document.evidence, callerBotID: "bot-a", callerSessionID: "gb-main")
        let state = try XCTUnwrap(states.first)
        XCTAssertTrue(state.resolved)
        XCTAssertEqual(state.observedAtMS, 1_760_000_003_000)
        XCTAssertNil(state.version,
                     "a user message is not an observation and carries no source version")
    }

    func testRestoreOfUnreviewedVersionNeverSynthesisesReview() async throws {
        let path = "agent/notes/plain.md"
        let context = BotMemoryWriteContext(
            botID: "bot-a", sessionID: "gb-main", authorKind: .chat,
            source: BotMemorySource(kind: .userTurn, sessionID: "gb-main"),
            trust: .user, isMainBot: true)
        let first = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: path, content: "plain one",
                expectedVersion: 0, evidence: [reference]),
            context: context)
        XCTAssertTrue(first.ok)
        _ = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: path, content: "plain two",
                expectedVersion: 1),
            context: context)
        let restored = try await memory.write(
            BotMemoryWriteRequest(
                action: .restore, path: path,
                expectedVersion: 2, restoreVersion: 1),
            context: context)
        XCTAssertTrue(restored.ok)
        guard case let .document(document) = try await memory.read(path: path) else {
            return XCTFail("expected a restored document")
        }
        XCTAssertNil(document.review,
                     "an absent review means no recorded judgment; restore must not invent verified")
        XCTAssertEqual(document.evidence, [reference])
    }

    // MARK: - Helpers

    private func writeSessionLog() throws {
        let header: [String: Any] = [
            "type": "session", "version": 4, "id": "gb-main",
            "createdAt": 1_760_000_000_000, "isSeeded": false, "delegationDepth": 0,
        ]
        let event: [String: Any] = [
            "type": "user/message", "seq": 3, "time": 1_760_000_003_000,
            "data": [
                "message": ["role": "user", "content": [
                    ["type": "text", "text": "remember the plan"]]],
                "source": ["kind": "user", "rpcId": "bot-1"],
            ],
        ]
        let lines = [header, event].map { object in
            String(decoding: try! JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
        let url = root.appendingPathComponent(
            "materialized/home/sessions/gb-main/session.v4.jsonl")
        try (lines.joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }
}
