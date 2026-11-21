// SPDX-License-Identifier: MIT

import CryptoKit
import XCTest
@testable import PhoneDSHBot

/// P → L integration on the real event log: P supplies the record facts and the
/// write-time baseline; L owns identity/current/review-effective. A historical
/// `verified` must not become current just because it was stored, and an
/// erasure must flow through to the read model without a second status store.
final class MemoryProvenanceReadViewTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteDomainStore!
    private var gateway: BotGateway!
    private var records: BotRecordService!
    private var memory: BotMemory!
    private var provenance: BotProvenanceService!
    private let now: Int64 = 1_760_000_050_000
    private let observationTime: Int64 = 1_760_000_005_000
    private let observationText = "Example Domain"
    private let observationRef = "record://session/gb-main#5"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-provenance-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("materialized/home/sessions/gb-main", isDirectory: true),
            withIntermediateDirectories: true)
        try writeSessionLog()
        store = try SQLiteDomainStore(
            fileURL: root.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        gateway = BotGateway(now: { 1_000 })
        try await gateway.issueSession(botId: "bot-a", sessionId: "gb-main", kind: .chat)
        records = BotRecordService(
            store: store, gateway: gateway, workspaceRoot: root, now: { 1_000 })
        memory = BotMemory(
            store: SQLiteBotMemoryDocumentStore(eventLog: store, botID: "bot-a", now: { self.now }),
            botID: "bot-a", now: { self.now })
        provenance = BotProvenanceService(eventLog: store, resolver: records)
        _ = try await store.append(BotEvent(
            type: "conversation.tool_call",
            eventId: "conversation.tool_call:\(UUID().uuidString)", time: 900,
            origin: .local(source: "runtime"), traceId: "trace-\(UUID().uuidString)",
            principal: BotPrincipal(botId: "bot-a", sessionId: "gb-main", kind: "chat"),
            causationId: nil, correlationId: "gb-main",
            data: .object([
                "callId": .string("call-1"),
                "name": .string("web_fetch"),
                "arguments": .string("{\"url\":\"https://example.com/a\"}"),
            ])))
    }

    override func tearDown() async throws {
        try? await store?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testPFactsAndBaselineFlowIntoProvenanceWithoutFalseCurrent() async throws {
        let path = "agent/notes/provenance-read.md"
        let review = BotMemoryReview(
            state: .verified, basis: .observation, refs: [observationRef])
        let baseline = BotSourceBaseline(
            record: observationRef, role: .evidence,
            sourceVersion: .known(BotKnownSourceVersion(
                kind: .contentSHA256,
                value: "sha256:" + sha256Hex(observationText),
                observedAtMS: observationTime, basisRef: observationRef)),
            resource: BotMemoryResource(
                kind: "web-url", key: "https://example.com/a",
                owner: "bot-a", scope: "agent"))
        let written = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: path, content: "observed",
                expectedVersion: 0, evidence: [observationRef], review: review,
                sourceBaselines: [baseline]),
            context: context())
        XCTAssertTrue(written.ok, "\(String(describing: written.code))")

        // M-style refs view: no artifact baseline is passed, so an observation
        // with a P-supplied version is unknown/no-baseline, never current.
        let refStatuses = try await provenance.sourceStatuses(for: [observationRef])
        let refStatus = try XCTUnwrap(refStatuses[observationRef])
        XCTAssertTrue(refStatus.resolved)
        XCTAssertEqual(refStatus.trust, "observation")
        XCTAssertEqual(refStatus.sourceVersion?.knownValue,
                       "sha256:" + sha256Hex(observationText))
        XCTAssertEqual(refStatus.state, .unknown)
        XCTAssertEqual(refStatus.reasons, [.noBaseline])

        // Artifact view: the derivation carries the baseline and resource, but
        // with no real recheck provider the state is refresh-not-performed.
        let artifactStatuses = try await provenance.sourceStatuses(
            for: BotDerivedRef(kind: .memory, id: path, version: 1))
        let status = try XCTUnwrap(artifactStatuses.first)
        XCTAssertEqual(status.ref, observationRef)
        XCTAssertEqual(status.trust, "observation")
        XCTAssertEqual(status.sourceVersion?.knownValue,
                       "sha256:" + sha256Hex(observationText))
        XCTAssertEqual(status.baseline?.knownValue,
                       "sha256:" + sha256Hex(observationText))
        XCTAssertEqual(status.resource?.kind, .webURL)
        XCTAssertEqual(status.state, .unknown)
        XCTAssertEqual(status.reasons, [.refreshNotPerformed])
        XCTAssertNil(status.recheckedAtMS)

        let view = try await provenance.currentState(
            for: BotDerivedRef(kind: .memory, id: path, version: 1))
        XCTAssertEqual(view.state, .unknown)
        XCTAssertNotEqual(view.reviewEffective.state, .verified,
                          "stored verified is historical, not current-valid")
    }

    func testErasureMakesTheReadModelErasedWithoutResurrection() async throws {
        let path = "agent/notes/provenance-erased.md"
        let baseline = BotSourceBaseline(
            record: observationRef, role: .evidence,
            sourceVersion: .known(BotKnownSourceVersion(
                kind: .contentSHA256,
                value: "sha256:" + sha256Hex(observationText),
                observedAtMS: observationTime, basisRef: observationRef)),
            resource: BotMemoryResource(kind: "web-url", key: "https://example.com/a"))
        _ = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: path, content: "observed",
                expectedVersion: 0, evidence: [observationRef],
                sourceBaselines: [baseline]),
            context: context())
        let before = try await provenance.sourceStatuses(for: [observationRef])
        XCTAssertNotEqual(before[observationRef]?.state, .erased)

        try writeErasedSessionLog()
        let erasure = BotErasureEventData(
            erasureId: "provenance-read-erasure", reason: "memory-path-erase",
            atMS: now,
            targets: [BotErasureEventData.Target(
                kind: "memory", scope: "agent", path: "agent/notes/unrelated.md")],
            erasedSessionRecords: [BotErasureEventData.ErasedSessionRecord(
                record: observationRef, sessionId: "gb-main", seq: 5)],
            sessionEpochs: [])
        _ = try await store.append(BotEvent(
            type: "erasure", eventId: "provenance-read-erasure", time: now,
            origin: .local(source: "user"), traceId: "provenance-read-erasure",
            principal: BotPrincipal(botId: "bot-a", sessionId: "gb-main", kind: "chat"),
            causationId: nil, correlationId: nil,
            data: try BotJSONValue.parse(JSONEncoder().encode(erasure))))

        let after = try await provenance.sourceStatuses(for: [observationRef])
        let status = try XCTUnwrap(after[observationRef])
        XCTAssertTrue(status.erased)
        XCTAssertTrue(status.resolved)
        XCTAssertEqual(status.state, .erased)
        XCTAssertTrue(status.reasons.contains(.recordErased))
        let view = try await provenance.currentState(
            for: BotDerivedRef(kind: .memory, id: path, version: 1))
        XCTAssertEqual(view.state, .erased)
        XCTAssertNotEqual(view.reviewEffective.state, .verified)
    }

    // MARK: - Helpers

    private func context() -> BotMemoryWriteContext {
        BotMemoryWriteContext(
            botID: "bot-a", sessionID: "gb-main", authorKind: .chat,
            source: BotMemorySource(kind: .userTurn, sessionID: "gb-main"),
            trust: .observation, isMainBot: true)
    }

    private func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func writeSessionLog() throws {
        try writeLog(tombstone: false)
    }

    private func writeErasedSessionLog() throws {
        try writeLog(tombstone: true)
    }

    private func writeLog(tombstone: Bool) throws {
        let header: [String: Any] = [
            "type": "session", "version": 4, "id": "gb-main",
            "createdAt": 1_760_000_000_000, "isSeeded": false, "delegationDepth": 0,
        ]
        let user: [String: Any] = [
            "type": "user/message", "seq": 3, "time": 1_760_000_003_000,
            "data": [
                "message": ["role": "user", "content": [
                    ["type": "text", "text": "remember the domain"]]],
                "source": ["kind": "user", "rpcId": "bot-1"],
            ],
        ]
        let call: [String: Any] = [
            "type": "tool/call", "seq": 4, "time": 1_760_000_004_000,
            "data": ["callId": "call-1", "name": "web_fetch",
                     "arguments": "{\"url\":\"https://example.com/a\"}"],
        ]
        var lines = [header, user, call].map {
            String(decoding: try! JSONSerialization.data(
                withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self)
        }
        if tombstone {
            let line = try BotSessionErasureTombstone.line(
                sessionID: "gb-main", seq: 5, time: observationTime,
                erasureID: "provenance-read-erasure")
            lines.append(String(decoding: line, as: UTF8.self))
        } else {
            let result: [String: Any] = [
                "type": "tool/result", "seq": 5, "time": observationTime,
                "data": [
                    "message": ["role": "tool", "toolCallId": "call-1",
                                "content": [["type": "text", "text": observationText]],
                                "isError": false],
                    "source": ["kind": "tool", "callId": "call-1"],
                ],
            ]
            lines.append(String(decoding: try! JSONSerialization.data(
                withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        }
        try (lines.joined(separator: "\n") + "\n").write(
            to: root.appendingPathComponent(
                "materialized/home/sessions/gb-main/session.v4.jsonl"),
            atomically: true, encoding: .utf8)
    }
}
