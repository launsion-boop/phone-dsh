// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class BotSessionErasurePlannerTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bot-session-erasure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("materialized/home/sessions/gb-main", isDirectory: true),
            withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// The original user turn is cited as a record; DSH also keeps a copy in an
    /// `agent/inbox/spliced` event. Erasing the record must tombstone the splice
    /// line as well so the original text cannot be read back from the log.
    func testSpliceCopyOfAnErasedMessageIsIncluded() throws {
        let sessionURL = root.appendingPathComponent(
            "materialized/home/sessions/gb-main/session.v4.jsonl")
        let message = """
        {"type":"user/message","seq":1,"time":1000,"surfaceOp":"append","data":{"content":[{"type":"text","text":"remember QUOKKA_7F3A9 now"}],"source":{"kind":"user","rpcId":"user-action:abc"},"role":"user","id":"message-1"}}
        """
        let splice = """
        {"type":"agent/inbox/spliced","seq":2,"time":1001,"data":{"target":"next-turn","start":0,"inserted":[{"content":[{"type":"text","text":"remember QUOKKA_7F3A9 now"}],"source":{"kind":"user","rpcId":"user-action:abc"},"role":"user","id":"message-1"}]}}
        """
        let unrelated = """
        {"type":"agent/inbox/spliced","seq":3,"time":1002,"data":{"target":"next-turn","start":0,"inserted":[{"content":[{"type":"text","text":"a different message"}],"source":{"kind":"user","rpcId":"user-action:other"},"role":"user","id":"message-2"}]}}
        """
        let assistant = """
        {"type":"assistant/message","seq":4,"time":1003,"data":{"message":{"role":"assistant","content":[{"type":"text","text":"ordinary reply"}]}}}
        """
        try [message, splice, unrelated, assistant].joined(separator: "\n")
            .appending("\n").write(to: sessionURL, atomically: true, encoding: .utf8)

        let planner = BotSessionErasurePlanner(workspaceRoot: root)
        let scan = planner.scan(
            botID: "main", ownedSessionIDs: ["gb-main"], needles: [],
            records: ["record://session/gb-main#1"])
        let target = try XCTUnwrap(scan.targets.first)
        XCTAssertEqual(target.seqs, [1, 2])
        let tombstones = planner.tombstoneLines(
            sessionID: "gb-main", erasedSeqs: Set(target.seqs), erasureID: "erasure-test")
        XCTAssertEqual(tombstones.map(\.seq), [1, 2])
        XCTAssertFalse(String(decoding: tombstones.map(\.data).joined(), as: UTF8.self)
            .contains("QUOKKA_7F3A9"))
    }

    /// A needle hit in a canonical message still covers its splice copy, even
    /// when the record itself was never cited.
    func testSpliceCopyOfANeedleHitIsIncluded() throws {
        let sessionURL = root.appendingPathComponent(
            "materialized/home/sessions/gb-main/session.v4.jsonl")
        let message = """
        {"type":"user/message","seq":5,"time":2000,"surfaceOp":"append","data":{"content":[{"type":"text","text":"BANANA_9C2 preference"}],"source":{"kind":"user","rpcId":"user-action:banana"},"role":"user","id":"message-5"}}
        """
        let splice = """
        {"type":"agent/inbox/spliced","seq":6,"time":2001,"data":{"target":"next-turn","start":0,"inserted":[{"content":[{"type":"text","text":"BANANA_9C2 preference"}],"source":{"kind":"user","rpcId":"user-action:banana"},"role":"user","id":"message-5"}]}}
        """
        try [message, splice].joined(separator: "\n").appending("\n")
            .write(to: sessionURL, atomically: true, encoding: .utf8)

        let scan = BotSessionErasurePlanner(workspaceRoot: root).scan(
            botID: "main", ownedSessionIDs: ["gb-main"], needles: ["BANANA_9C2"], records: [])
        XCTAssertEqual(scan.targets.first?.seqs, [5, 6])
    }
}
