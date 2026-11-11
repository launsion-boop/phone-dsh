// SPDX-License-Identifier: MIT
// W1-A: the read-only materialized-session projection. These tests drive the
// real JSONL decoder with DSH v4 line shapes, including a torn final line and a
// corrupt line, and prove the reader never writes back.

import XCTest
import ProbeKit

final class SessionProjectionReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-projection-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testListsBothLayoutsAndSummarizes() throws {
        let direct = root.appendingPathComponent("gb-main", isDirectory: true)
        try write(lines: baseLines(id: "gb-main", userText: "direct session"),
                  to: direct.appendingPathComponent("session.v4.jsonl"))
        let project = root.appendingPathComponent("proj-1", isDirectory: true)
            .appendingPathComponent("sess-2", isDirectory: true)
        try write(lines: baseLines(id: "sess-2", userText: "project session"),
                  to: project.appendingPathComponent("session.v3.jsonl"))

        let reader = SessionProjectionReader(sessionsRoot: root)
        let sessions = reader.listSessions()
        XCTAssertEqual(Set(sessions.map(\.id)), ["gb-main", "sess-2"])
        let main = try XCTUnwrap(sessions.first { $0.id == "gb-main" })
        XCTAssertEqual(main.title, "direct session")
        XCTAssertNil(main.project)
        XCTAssertFalse(main.running)
        XCTAssertFalse(main.blank)
        let nested = try XCTUnwrap(sessions.first { $0.id == "sess-2" })
        XCTAssertEqual(nested.project, "proj-1")
        XCTAssertEqual(nested.title, "project session")
    }

    func testTornFinalLineAndCorruptLineAreIgnored() throws {
        var lines = baseLines(id: "gb-main", userText: "hello")
        lines.insert("this is not json", at: 2)
        let directory = root.appendingPathComponent("gb-main", isDirectory: true)
        let file = directory.appendingPathComponent("session.v4.jsonl")
        try write(lines: lines, to: file, tornSuffix: "{\"seq\":99,\"type\":\"assistant/message\"")

        let reader = SessionProjectionReader(sessionsRoot: root)
        let page = try XCTUnwrap(reader.latestPage(sessionID: "gb-main"))
        XCTAssertTrue(page.items.contains { $0.text.contains("hello") })
        XCTAssertFalse(page.items.contains { $0.text.contains("\"seq\":99") })
        XCTAssertEqual(page.throughSeq, 6)
    }

    func testLatestPageAndBackwardPaging() throws {
        var lines = header(id: "gb-main")
        for seq in 2...40 {
            lines.append(line(seq: seq, type: "assistant/message",
                              data: "{\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"row \(seq)\"}]}}"))
        }
        let directory = root.appendingPathComponent("gb-main", isDirectory: true)
        try write(lines: lines,
                  to: directory.appendingPathComponent("session.v4.jsonl"))
        let reader = SessionProjectionReader(sessionsRoot: root)

        let latest = try XCTUnwrap(reader.latestPage(sessionID: "gb-main", maxRecords: 5))
        XCTAssertEqual(latest.items.count, 5)
        XCTAssertEqual(latest.throughSeq, 40)
        XCTAssertEqual(latest.beforeSeq, 36)
        XCTAssertTrue(latest.hasMore)

        let older = try XCTUnwrap(reader.page(sessionID: "gb-main",
                                              beforeSeq: 36, maxRecords: 5))
        XCTAssertEqual(older.throughSeq, 35)
        XCTAssertEqual(older.beforeSeq, 31)
        XCTAssertTrue(older.hasMore)
        XCTAssertFalse(older.items.contains { $0.text == "row 40" })
    }

    func testReaderNeverWritesMaterializedFiles() throws {
        let directory = root.appendingPathComponent("gb-main", isDirectory: true)
        let file = directory.appendingPathComponent("session.v4.jsonl")
        try write(lines: baseLines(id: "gb-main", userText: "read only"), to: file)
        let before = try Data(contentsOf: file)
        let attributesBefore = try FileManager.default
            .attributesOfItem(atPath: file.path)

        let reader = SessionProjectionReader(sessionsRoot: root)
        _ = reader.listSessions()
        _ = reader.latestPage(sessionID: "gb-main")
        _ = reader.page(sessionID: "gb-main", beforeSeq: 6)

        XCTAssertEqual(try Data(contentsOf: file), before)
        let attributesAfter = try FileManager.default
            .attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributesBefore[.modificationDate] as? Date,
                       attributesAfter[.modificationDate] as? Date)
    }

    func testUnknownSessionReturnsNil() {
        let reader = SessionProjectionReader(sessionsRoot: root)
        XCTAssertNil(reader.latestPage(sessionID: "missing"))
        XCTAssertNil(reader.page(sessionID: "missing", beforeSeq: 3))
        XCTAssertNil(reader.sessionFile(for: "../escape"))
    }

    // MARK: - Fixtures

    private func header(id: String) -> [String] {
        ["{\"createdAt\":1760000000000,\"id\":\"\(id)\",\"type\":\"session\",\"version\":4}"]
    }

    private func line(seq: Int, type: String, data: String,
                      surfaceOp: String = "\"append\"") -> String {
        "{\"data\":\(data),\"seq\":\(seq),\"surfaceOp\":\(surfaceOp),\"time\":\(1760000000000 + seq * 1000),\"type\":\"\(type)\"}"
    }

    private func baseLines(id: String, userText: String) -> [String] {
        var lines = header(id: id)
        lines.append(line(seq: 2, type: "turn/start", data: "{\"turn\":1}", surfaceOp: "null"))
        lines.append(line(seq: 3, type: "user/message",
                          data: "{\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"\(userText)\"}]},\"source\":{\"kind\":\"user\",\"rpcId\":\"rpc-1\"}}"))
        lines.append(line(seq: 4, type: "assistant/message",
                          data: "{\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"answer\"}]}}"))
        lines.append(line(seq: 5, type: "tool/call",
                          data: "{\"callId\":\"c1\",\"name\":\"read\",\"arguments\":\"{}\",\"step\":1,\"turn\":1}"))
        lines.append(line(seq: 6, type: "turn/end", data: "{\"turn\":1,\"reason\":{\"kind\":\"completed\"}}", surfaceOp: "null"))
        return lines
    }

    private func write(lines: [String], to file: URL,
                       tornSuffix: String? = nil) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var text = lines.joined(separator: "\n") + "\n"
        if let tornSuffix { text += tornSuffix } // deliberately no trailing newline
        try Data(text.utf8).write(to: file)
    }
}
