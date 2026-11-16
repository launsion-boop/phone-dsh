// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Q-09: a failing resolver is not "the record has no observation time".
/// Read/recall must omit `evidence_status` and leave a diagnostic instead of
/// fabricating all-null entries.
final class MemoryEvidenceStatusFailureTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteDomainStore!
    private var gateway: BotGateway!
    private var service: BotRecordService!
    private var runtime: BotMCPRuntime!

    private let userMessage = "record://session/gb-main#3"

    /// Delegates evidence validation to the real service but fails the batched
    /// snapshot, which is the resolver path `evidence_status` uses.
    private final class SnapshotFailingResolver: BotRecordEvidenceResolving,
        BotSourceStateResolving, @unchecked Sendable {
        let service: BotRecordService

        init(service: BotRecordService) { self.service = service }

        func resolveEvidence(_ references: [String], callerBotID: String,
                             callerSessionID: String) async throws -> BotRecordEvidence {
            try await service.resolveEvidence(
                references, callerBotID: callerBotID, callerSessionID: callerSessionID)
        }

        func sourceStates(for references: [String], callerBotID: String,
                          callerSessionID: String) async throws -> [BotSourceState] {
            try await service.sourceStates(
                for: references, callerBotID: callerBotID,
                callerSessionID: callerSessionID)
        }

        func evidenceSnapshot(for references: [String], callerBotID: String,
                              callerSessionID: String) async throws -> BotRecordEvidenceSnapshot {
            throw BotRecordServiceError.unavailable("simulated snapshot failure")
        }
    }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-status-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("materialized/home/sessions/gb-main", isDirectory: true),
            withIntermediateDirectories: true)
        try writeSessionLog()
        store = try SQLiteDomainStore(
            fileURL: root.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        gateway = BotGateway(now: { 1_000 })
        try await gateway.issueSession(botId: "bot-a", sessionId: "gb-main", kind: .chat)
        service = BotRecordService(store: store, gateway: gateway, workspaceRoot: root)
        runtime = BotMCPRuntime(
            store: store, gateway: gateway,
            recordEvidence: SnapshotFailingResolver(service: service), now: { 1_760_000_030_000 })
        await runtime.installProvenance(BotProvenanceService(eventLog: store))
    }

    override func tearDown() async throws {
        try? await store?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testReadMemoryOmitsEvidenceStatusWhenResolverFails() async throws {
        let written = try await call([
            "action": "write", "path": "agent/notes/snapshot-fails.md",
            "content": "observed", "expected_version": 0,
            "evidence": [userMessage],
        ])
        XCTAssertEqual(written.structuredContent?["ok"], .bool(true),
                       "\(String(describing: written.structuredContent))")
        let read = try await call(
            ["path": "agent/notes/snapshot-fails.md"], name: "ReadMemory")
        XCTAssertNil(read.structuredContent?["evidence_status"],
                     "a resolver failure must omit the view, not emit all-null entries")
        // The evidence list itself is still authoritative.
        XCTAssertEqual(read.structuredContent?["evidence"]?.arrayValue?.first?.stringValue,
                       userMessage)
        let diagnostic = await runtime.lastBridgeError()
        XCTAssertEqual(diagnostic?.code, "evidence_status_unavailable")
    }

    func testRecallMemoryOmitsEvidenceStatusWhenResolverFails() async throws {
        _ = try await call([
            "action": "write", "path": "agent/notes/snapshot-recall.md",
            "content": "Example Domain", "expected_version": 0,
            "evidence": [userMessage],
        ])
        let recall = try await call(
            ["query": "Example Domain", "limit": 10], name: "RecallMemory")
        let hits = recall.structuredContent?["hits"]?.arrayValue ?? []
        XCTAssertFalse(hits.isEmpty)
        for hit in hits {
            XCTAssertNil(hit["evidence_status"], "a failing snapshot must not fake nulls")
        }
        let diagnostic = await runtime.lastBridgeError()
        XCTAssertEqual(diagnostic?.code, "evidence_status_unavailable")
    }

    // MARK: - Helpers

    private func call(
        _ fields: [String: Any],
        name: String = "UpdateMemory"
    ) async throws -> BotMCPCallResult {
        let arguments = try BotJSONValue.parse(
            JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]))
        await runtime.beginTurn(sessionId: "gb-main", hidden: false,
                                origin: BotTurnOrigin(rpcId: "bot-1"))
        await runtime.observeUserMessage(
            sessionId: "gb-main", seq: 3,
            source: ["kind": .string("user"), "rpcId": .string("bot-1")])
        return try await registerAndExecute(
            runtime, name: name, arguments: arguments,
            sessionId: "gb-main", callId: UUID().uuidString)
    }

    private func writeSessionLog() throws {
        let events: [[String: Any]] = [
            [
                "type": "user/message", "seq": 3, "time": 1_760_000_003_000,
                "data": [
                    "message": ["role": "user", "content": [["type": "text", "text": "我叫小林"]]],
                    "source": ["kind": "user", "rpcId": "bot-1"],
                ],
                "surfaceOp": "append",
            ],
        ]
        let header: [String: Any] = [
            "type": "session", "version": 4, "id": "gb-main",
            "createdAt": 1_760_000_000_000, "isSeeded": false, "delegationDepth": 0,
        ]
        let lines = try [header] + events
        let text = try lines.map { object in
            String(decoding: try JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        try text.write(
            to: root.appendingPathComponent(
                "materialized/home/sessions/gb-main/session.v4.jsonl"),
            atomically: true, encoding: .utf8)
    }
}
