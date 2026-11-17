// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotToolResultRefIndexTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteDomainStore!
    private var gateway: BotGateway!
    private var service: BotRecordService!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toolrefs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("materialized/home/sessions/gb-main"),
            withIntermediateDirectories: true)
        try writeSession()
        store = try SQLiteDomainStore(
            fileURL: root.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        gateway = BotGateway(now: { 1_000 })
        try await gateway.issueSession(botId: "bot-a", sessionId: "gb-main", kind: .chat)
        service = BotRecordService(store: store, gateway: gateway, workspaceRoot: root)
    }

    override func tearDown() async throws {
        try? await store?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testOnlySuccessfulBashAndReadRefsWithRealSeq() async throws {
        let refs = await service.recentToolResultRefs(
            botID: "bot-a", sessionID: "gb-main", limit: 5)
        XCTAssertEqual(refs.count, 2, "\(refs)")
        XCTAssertEqual(refs.map(\.tool), ["bash", "read"])
        XCTAssertEqual(refs.first?.record, "record://session/gb-main#3")
        XCTAssertTrue(refs.first?.label.contains("docs/a.md") == true)
        XCTAssertTrue(refs.last?.label.contains("notes/b.md") == true)

        let read = await service.execute(
            arguments: ["read", refs[0].record], callerSessionID: "gb-main")
        XCTAssertEqual(read.exitCode, 0)
        XCTAssertTrue(read.stdout.contains("A07_REF_BODY"))
        XCTAssertFalse(read.stdout.contains("failed-body"))
        XCTAssertFalse(read.stdout.contains("truncated-body"))
    }

    func testFailedTruncatedAndRedactedAreNotListed() async throws {
        let refs = await service.recentToolResultRefs(
            botID: "bot-a", sessionID: "gb-main", limit: 5)
        XCTAssertFalse(refs.contains { $0.record.hasSuffix("#6") }) // failed
        XCTAssertFalse(refs.contains { $0.record.hasSuffix("#7") }) // truncated
        XCTAssertFalse(refs.contains { $0.record.hasSuffix("#8") }) // redacted
    }

    func testOtherBotCannotReadAndReaderHasNoCache() async throws {
        let other = await service.recentToolResultRefs(
            botID: "bot-b", sessionID: "gb-main", limit: 5)
        XCTAssertTrue(other.isEmpty)

        let first = await service.recentToolResultRefs(
            botID: "bot-a", sessionID: "gb-main", limit: 5)
        XCTAssertEqual(first.count, 2)
        try appendSuccess(seq: 20, callId: "call-late", path: "docs/late.md",
                          text: "LATE_REF_BODY")
        let second = await service.recentToolResultRefs(
            botID: "bot-a", sessionID: "gb-main", limit: 5)
        XCTAssertEqual(second.count, 3)
        XCTAssertEqual(second.last?.record, "record://session/gb-main#21")
        XCTAssertTrue(second.last?.label.contains("docs/late.md") == true)
    }


    func testVolatileSnapshotRefreshesRefsWithoutCache() async throws {
        let reader = FakeToolResultRefReader()
        let producer = BotVolatileContextProducer(
            provider: EmptyBotVolatileContextProvider(), toolResultRefs: reader)
        let resolved = await gateway.tokens.lookupSession("gb-main")
        let principal = try XCTUnwrap(resolved)
        let request: BotJSONValue = .object(["sessionId": .string("gb-main")])
        await reader.set([BotToolResultRef(
            record: "record://session/gb-main#3", tool: "bash", label: "bash cat docs/a.md")])
        let first = try await producer.snapshot(request: request, principal: principal)
        XCTAssertEqual(first.toolResultRefs?.count, 1)
        let firstJSON = try XCTUnwrap(first.jsonValue["tool_result_refs"]?.arrayValue)
        XCTAssertEqual(firstJSON.count, 1)
        XCTAssertEqual(firstJSON[0]["record"]?.stringValue, "record://session/gb-main#3")

        await reader.set([
            BotToolResultRef(record: "record://session/gb-main#3", tool: "bash",
                             label: "bash cat docs/a.md"),
            BotToolResultRef(record: "record://session/gb-main#5", tool: "read",
                             label: "read notes/b.md"),
        ])
        let second = try await producer.snapshot(request: request, principal: principal)
        XCTAssertEqual(second.toolResultRefs?.count, 2,
                       "each snapshot must read the current index, no 15 s cache")
    }

    private actor FakeToolResultRefReader: BotToolResultRefReading {
        private var refs: [BotToolResultRef] = []
        func set(_ value: [BotToolResultRef]) { refs = value }
        func recentToolResultRefs(botID: String, sessionID: String,
                                  limit: Int) async -> [BotToolResultRef] {
            Array(refs.suffix(limit))
        }
    }
    private var sessionURL: URL {
        root.appendingPathComponent("materialized/home/sessions/gb-main/session.v4.jsonl")
    }

    private func writeSession() throws {
        var lines: [String] = []
        func line(_ object: [String: Any]) throws {
            lines.append(String(decoding: try JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]), as: UTF8.self))
        }
        try line(["type": "user/message", "seq": 1, "time": 1,
                  "data": ["content": [["type": "text", "text": "do work"]]]])
        try line(["type": "tool/call", "seq": 2, "time": 2,
                  "data": ["callId": "c1", "name": "bash",
                           "arguments": #"{"command":"cat docs/a.md"}"#]])
        try line(["type": "tool/result", "seq": 3, "time": 3,
                  "data": ["message": ["toolCallId": "c1", "isError": false,
                           "content": [["type": "text", "text": "A07_REF_BODY"]]]]])
        try line(["type": "tool/call", "seq": 4, "time": 4,
                  "data": ["callId": "c2", "name": "read",
                           "arguments": #"{"file_path":"notes/b.md"}"#]])
        try line(["type": "tool/result", "seq": 5, "time": 5,
                  "data": ["message": ["toolCallId": "c2", "isError": false,
                           "content": [["type": "text", "text": "READ_REF_BODY"]]]]])
        try line(["type": "tool/result", "seq": 6, "time": 6,
                  "data": ["message": ["toolCallId": "c1", "isError": true,
                           "content": [["type": "text", "text": "failed-body"]]]]])
        try line(["type": "tool/result", "seq": 7, "time": 7,
                  "data": ["message": ["toolCallId": "c1", "isError": false,
                           "content": [["type": "text", "text": "truncated-body reason=output-truncated"]]]]])
        try line(["type": "tool/result", "seq": 8, "time": 8,
                  "data": ["message": ["toolCallId": "c1", "isError": false,
                           "content": [["type": "text", "text": "[pdsh-redaction rules=x:1] body"]]]]])
        try "\(lines.joined(separator: "\n"))\n".write(to: sessionURL, atomically: true, encoding: .utf8)
    }

    private func appendSuccess(seq: Int, callId: String, path: String, text: String) throws {
        var values: [[String: Any]] = [
            ["type": "tool/call", "seq": seq, "time": seq,
             "data": ["callId": callId, "name": "read",
                      "arguments": "{\"file_path\":\"\(path)\"}"]],
            ["type": "tool/result", "seq": seq + 1, "time": seq + 1,
             "data": ["message": ["toolCallId": callId, "isError": false,
                      "content": [["type": "text", "text": text]]]]],
        ]
        values.sort { ($0["seq"] as! Int) < ($1["seq"] as! Int) }
        let existing = try String(contentsOf: sessionURL, encoding: .utf8)
        let appended = try values.map {
            String(decoding: try JSONSerialization.data(
                withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self)
        }.joined(separator: "\n")
        try (existing + appended + "\n").write(to: sessionURL, atomically: true, encoding: .utf8)
    }
}
