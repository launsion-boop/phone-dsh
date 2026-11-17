// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// AHA-ERASURE regression: a marker written inside CJK prose must still erase
/// the session lines that mention it (session titles, the assistant reply) and
/// must not be carried into the next session epoch by the continuation seam.
final class MemoryErasureSessionLogTests: XCTestCase {
    private var store: SQLiteDomainStore!
    private var root: URL!
    private var memory: BotMemory!

    private let marker = "QUOKKA_AHA_9D2"
    private let unrelated = "UNRELATED_KEEP_9Z9"
    private var sessionDirectory: URL {
        root.appendingPathComponent(
            "materialized/home/sessions/project/gb-main", isDirectory: true)
    }
    private var sessionLogURL: URL {
        sessionDirectory.appendingPathComponent("session.v4.jsonl")
    }

    override func setUp() async throws {
        (store, root) = try makeMemoryTestStore()
        memory = makeMemory(store: store, botID: "main")
        try FileManager.default.createDirectory(
            at: sessionDirectory, withIntermediateDirectories: true)
        try writeSessionLog(lines: standardSessionLines())
    }

    override func tearDown() async throws {
        try? await store?.close()
        cleanupMemoryTestStore(root)
    }

    func testNeedlesExtractAMarkerEmbeddedInCJKProse() {
        let needles = SQLiteBotMemoryDocumentStore.erasureNeedles(
            in: "记住的随机词：\(marker)，已经写进记忆。")
        XCTAssertTrue(needles.contains("QUOKKA_AHA_9D2"),
                      "the long identifier run is a candidate regardless of language")
    }

    /// Distinctiveness matrix: the original rule (token >= 8 scalars that
    /// contains '_' or a digit) with generic token boundaries. Plain words,
    /// long ones included, never become erasure targets.
    func testDistinctiveIdentifierBoundaries() {
        func needles(_ content: String) -> Set<String> {
            SQLiteBotMemoryDocumentStore.erasureNeedles(in: content)
        }
        // An identifier embedded in CJK prose stays whole.
        XCTAssertTrue(needles("记住的随机词：QUOKKA_AHA_9D2，写好了。")
            .contains("QUOKKA_AHA_9D2"))
        XCTAssertTrue(needles("随机词QUOKKA_AHA_9D2写好了").contains("QUOKKA_AHA_9D2"))
        // Cyrillic / Arabic identifiers with '_' or a digit.
        XCTAssertTrue(needles("记住：КВОККА_ТЕСТ_9，写好了。").contains("КВОККА_ТЕСТ_9"))
        XCTAssertTrue(needles("记住：ماركر_اختبار，写好了。").contains("ماركر_اختبار"))
        // Kana / Hangul identifiers with '_' or a digit.
        XCTAssertTrue(needles("これは テスト_ID_9 です").contains("テスト_ID_9"))
        XCTAssertTrue(needles("이것은 한국어_ID_9 입니다").contains("한국어_ID_9"))
        // Emoji and dotted identifiers keep the identifier intact.
        XCTAssertTrue(needles("🔥QUOKKA_AHA_9D2🔥").contains("QUOKKA_AHA_9D2"))
        XCTAssertTrue(needles("file report.v2.final saved").contains("report.v2.final"))
        // Plain words, even long ones, are not distinctive.
        for word in ["implementation", "documentation", "remember", "important"] {
            XCTAssertFalse(needles("x \(word) y").contains(word), word)
        }
        // Different identifiers must not imply each other.
        XCTAssertFalse(needles("QUOKKA_AHA_9D2").contains("QUOKKA_OTHER_ID"))
        XCTAssertFalse(needles("QUOKKA_OTHER_ID").contains("QUOKKA_AHA_9D2"))
        // Pure numeric tokens and short words stay out of the identifier set.
        XCTAssertTrue(SQLiteBotMemoryDocumentStore
            .identifierCandidates(in: "1234567890").isEmpty)
        XCTAssertFalse(needles("the and for").contains("the"))
    }

    func testScopeErasureTombstonesTitleAndAssistantMarkerLines() async throws {
        let context = BotMemoryWriteContext(
            botID: "main", sessionID: "gb-main", authorKind: .chat,
            source: BotMemorySource(kind: .userTurn, sessionID: "gb-main"),
            trust: .user)
        let written = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: "user/notes/random-word.md",
                content: "记住的随机词：\(marker)，已经写进记忆。",
                expectedVersion: 0,
                evidence: ["record://session/gb-main#3"]),
            context: context)
        XCTAssertTrue(written.ok, "\(String(describing: written.code))")

        var capturedContinuation: String?
        let eraser: BotSessionEraser = { [marker] request in
            let planner = BotSessionErasurePlanner(workspaceRoot: self.root)
            let scan = planner.scan(
                botID: request.botID, ownedSessionIDs: ["gb-main"],
                needles: request.needles, records: request.records)
            let target = scan.targets.first { $0.sessionID == "gb-main" }
            capturedContinuation = planner.continuation(
                sessionID: "gb-main", erasedSeqs: Set(target?.seqs ?? []))
            try self.applyTombstones(target, workspaceRoot: self.root)
            return BotSessionErasureReport(
                erasedSessionRecords: (target?.seqs ?? []).map {
                    BotErasureEventData.ErasedSessionRecord(
                        record: "record://session/gb-main#\($0)",
                        sessionId: "gb-main", seq: $0)
                })
        }

        let outcome = try await memory.erase(scope: .user, sessionEraser: eraser)
        XCTAssertTrue(outcome.ok, outcome.error ?? "")

        let text = try String(contentsOf: sessionLogURL, encoding: .utf8)
        XCTAssertFalse(text.contains(marker),
                       "every session line that mentions the marker must be tombstoned")
        XCTAssertTrue(text.contains(unrelated),
                      "an unrelated line must survive")

        let lines = BotSessionLogReader.lines(from: Data(text.utf8))
        for seq in [3, 4, 5] {
            XCTAssertEqual(lines.first { $0.seq == seq }?.erased, true,
                           "seq \(seq) must be a tombstone")
        }
        XCTAssertEqual(lines.first { $0.seq == 6 }?.erased, false)

        let continuation = try XCTUnwrap(capturedContinuation)
        XCTAssertFalse(continuation.contains(marker),
                       "the continuation seam must not carry an erased assistant line")
    }

    /// Counter-case: plain marker lines are already covered, and a document
    /// that does not contain the marker is neither erased nor its session lines
    /// touched.
    func testUnrelatedDocumentLeavesSessionLogAlone() async throws {
        let context = BotMemoryWriteContext(
            botID: "main", sessionID: "gb-main", authorKind: .chat,
            source: BotMemorySource(kind: .userTurn, sessionID: "gb-main"),
            trust: .user)
        let written = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: "agent/notes/other.md",
                content: "只记一个无关事实。", expectedVersion: 0),
            context: context)
        XCTAssertTrue(written.ok, "\(String(describing: written.code))")

        let eraser: BotSessionEraser = { request in
            let planner = BotSessionErasurePlanner(workspaceRoot: self.root)
            let scan = planner.scan(
                botID: request.botID, ownedSessionIDs: ["gb-main"],
                needles: request.needles, records: request.records)
            XCTAssertTrue(scan.targets.isEmpty,
                          "a marker-free document must not target marker lines")
            return BotSessionErasureReport()
        }
        let outcome = try await memory.erase(scope: .agent, sessionEraser: eraser)
        XCTAssertTrue(outcome.ok, outcome.error ?? "")
        let text = try String(contentsOf: sessionLogURL, encoding: .utf8)
        XCTAssertTrue(text.contains(marker), "nothing was erased, so nothing changed")
    }

    /// The same mechanism, not a marker-shape rule: Cyrillic and Arabic runs
    /// next to CJK punctuation are discovered, while short ASCII words in an
    /// unrelated line are not.
    func testMultilingualMarkersUseTheSameMechanism() async throws {
        let cyrillic = "КВОККА_ТЕСТ_9"
        let arabic = "ماركر_اختبار"
        try writeSessionLog(lines: [
            ["type": "session", "version": 4, "id": "gb-main"],
            ["type": "user/message", "seq": 3, "time": MemoryTestFixtures.now,
             "data": ["message": ["role": "user", "content": [[
                "type": "text", "text": "记住 \(cyrillic) 和 \(arabic)。",
             ]]]]],
            ["type": "session/title", "seq": 4, "time": MemoryTestFixtures.now,
             "data": ["title": "记住词 \(cyrillic) / \(arabic)"]],
            ["type": "assistant/message", "seq": 5, "time": MemoryTestFixtures.now,
             "data": ["message": ["role": "assistant", "content": [[
                "type": "text", "text": "记住了：\(cyrillic) 和 \(arabic)。",
             ]]]]],
            ["type": "user/message", "seq": 6, "time": MemoryTestFixtures.now,
             "data": ["message": ["role": "user", "content": [[
                "type": "text", "text": "remember important documents",
             ]]]]],
        ])
        let context = BotMemoryWriteContext(
            botID: "main", sessionID: "gb-main", authorKind: .chat,
            source: BotMemorySource(kind: .userTurn, sessionID: "gb-main"),
            trust: .user)
        let written = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: "user/notes/multilingual.md",
                content: "\(cyrillic) 与 \(arabic) 是两个随机词。",
                expectedVersion: 0,
                evidence: ["record://session/gb-main#3"]),
            context: context)
        XCTAssertTrue(written.ok, "\(String(describing: written.code))")

        var capturedContinuation: String?
        let eraser: BotSessionEraser = { request in
            let planner = BotSessionErasurePlanner(workspaceRoot: self.root)
            let scan = planner.scan(
                botID: request.botID, ownedSessionIDs: ["gb-main"],
                needles: request.needles, records: request.records)
            let target = scan.targets.first { $0.sessionID == "gb-main" }
            capturedContinuation = planner.continuation(
                sessionID: "gb-main", erasedSeqs: Set(target?.seqs ?? []))
            try self.applyTombstones(target, workspaceRoot: self.root)
            return BotSessionErasureReport(
                erasedSessionRecords: (target?.seqs ?? []).map {
                    BotErasureEventData.ErasedSessionRecord(
                        record: "record://session/gb-main#\($0)",
                        sessionId: "gb-main", seq: $0)
                })
        }
        let outcome = try await memory.erase(scope: .user, sessionEraser: eraser)
        XCTAssertTrue(outcome.ok, outcome.error ?? "")

        let text = try String(contentsOf: sessionLogURL, encoding: .utf8)
        XCTAssertFalse(text.contains("КВОККА"), "Cyrillic marker run must be tombstoned")
        XCTAssertFalse(text.contains("اختبار"), "Arabic marker run must be tombstoned")
        XCTAssertTrue(text.contains("remember important documents"),
                      "ordinary 6-11 scalar words must not become erasure targets")
        let lines = BotSessionLogReader.lines(from: Data(text.utf8))
        for seq in [3, 4, 5] {
            XCTAssertEqual(lines.first { $0.seq == seq }?.erased, true)
        }
        XCTAssertEqual(lines.first { $0.seq == 6 }?.erased, false)
        let continuation = try XCTUnwrap(capturedContinuation)
        XCTAssertFalse(continuation.contains("КВОККА"))
        XCTAssertFalse(continuation.contains("اختبار"))
    }

    /// Data-integrity negatives: erasing one document must not erase lines
    /// that merely share ordinary words or a different identifier.
    func testEraseOnlyTombstonesLinesForThatDocument() async throws {
        let context = BotMemoryWriteContext(
            botID: "main", sessionID: "gb-main", authorKind: .chat,
            source: BotMemorySource(kind: .userTurn, sessionID: "gb-main"),
            trust: .user)
        let documents: [(String, String)] = [
            ("user/notes/meeting.md", "meeting plan A"),
            ("user/notes/marker.md", "QUOKKA_AHA_9D2"),
            ("user/notes/kana.md", "テスト_ID_9"),
            ("user/notes/hangul.md", "한국어_ID_9"),
        ]
        for (path, content) in documents {
            let written = try await memory.write(
                BotMemoryWriteRequest(
                    action: .write, path: path, content: content,
                    expectedVersion: 0, evidence: ["record://session/gb-main#3"]),
                context: context)
            XCTAssertTrue(written.ok, "\(path): \(String(describing: written.code))")
        }
        let sessionLines = [
            "meeting plan A",
            "meeting client B",
            "QUOKKA_AHA_9D2",
            "QUOKKA_OTHER_ID",
            "テスト_ID_9",
            "한국어_ID_9",
            "implementation documentation",
            "unrelated line stays",
        ]
        var lines: [[String: Any]] = [["type": "session", "version": 4, "id": "gb-main"]]
        for (offset, text) in sessionLines.enumerated() {
            lines.append([
                "type": "assistant/message", "seq": offset + 3,
                "time": MemoryTestFixtures.now,
                "data": ["message": ["role": "assistant", "content": [[
                    "type": "text", "text": text,
                ]]]],
            ])
        }
        try writeSessionLog(lines: lines)
        // Every document cites the first line as evidence, so that line is a
        // record target; the test still distinguishes content/identifier hits.
        var continuation: String?
        let eraser: BotSessionEraser = { request in
            let planner = BotSessionErasurePlanner(workspaceRoot: self.root)
            let scan = planner.scan(
                botID: request.botID, ownedSessionIDs: ["gb-main"],
                needles: request.needles, records: request.records)
            let target = scan.targets.first { $0.sessionID == "gb-main" }
            continuation = planner.continuation(
                sessionID: "gb-main", erasedSeqs: Set(target?.seqs ?? []))
            try self.applyTombstones(target, workspaceRoot: self.root)
            return BotSessionErasureReport(
                erasedSessionRecords: (target?.seqs ?? []).map {
                    BotErasureEventData.ErasedSessionRecord(
                        record: "record://session/gb-main#\($0)",
                        sessionId: "gb-main", seq: $0)
                })
        }
        let outcome = try await memory.erase(scope: .user, sessionEraser: eraser)
        XCTAssertTrue(outcome.ok, outcome.error ?? "")
        let parsed = BotSessionLogReader.lines(
            from: Data(try String(contentsOf: sessionLogURL, encoding: .utf8).utf8))
        func isErased(_ seq: Int) -> Bool { parsed.first { $0.seq == seq }?.erased == true }
        XCTAssertTrue(isErased(3), "meeting plan A")
        XCTAssertFalse(isErased(4), "meeting client B must survive")
        XCTAssertTrue(isErased(5), "QUOKKA_AHA_9D2")
        XCTAssertFalse(isErased(6), "QUOKKA_OTHER_ID must not cross-erase")
        XCTAssertTrue(isErased(7), "Kana identifier")
        XCTAssertTrue(isErased(8), "Hangul identifier")
        XCTAssertFalse(isErased(9), "plain long words must not be needles")
        XCTAssertFalse(isErased(10), "unrelated line")
        let seam = try XCTUnwrap(continuation)
        XCTAssertFalse(seam.contains("QUOKKA_AHA_9D2"))
        XCTAssertTrue(seam.contains("meeting client B"))
    }

    /// PR #187 review item 7: a Han date is prose, not an identifier. The
    /// digit-only token rule made "2026年11月16日" a substring needle, so
    /// erasing a document could delete another conversation that merely
    /// mentioned the same date. The fix is the general predicate (a needle
    /// needs a letter plus '_' or an ASCII letter), not a date special case.
    func testChineseDateStaysOutOfTheErasureNeedles() async throws {
        let date = "2026年11月16日"
        let content = "会议记录：\(date) 上午评审，地点 A 座。"
        let needles = SQLiteBotMemoryDocumentStore.erasureNeedles(in: content)
        XCTAssertFalse(needles.contains(date),
                       "a date is not a distinctive identifier")
        XCTAssertFalse(needles.contains("\(date) 上午评审，地点"),
                       "an author phrase is not a needle fragment")

        var lines = standardSessionLines()
        lines.append([
            "type": "user/message", "seq": 7, "time": MemoryTestFixtures.now,
            "data": ["message": ["role": "user", "content": [[
                "type": "text", "text": "\(date) 是项目里程碑。",
            ]]]],
        ])
        try writeSessionLog(lines: lines)
        let context = BotMemoryWriteContext(
            botID: "main", sessionID: "gb-main", authorKind: .chat,
            source: BotMemorySource(kind: .userTurn, sessionID: "gb-main"),
            trust: .user)
        let written = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: "agent/notes/meeting.md",
                content: content, expectedVersion: 0),
            context: context)
        XCTAssertTrue(written.ok, "\(String(describing: written.code))")

        let eraser: BotSessionEraser = { request in
            XCTAssertFalse(request.needles.contains(date),
                           "the date must not travel as an erasure needle")
            let planner = BotSessionErasurePlanner(workspaceRoot: self.root)
            let scan = planner.scan(
                botID: request.botID, ownedSessionIDs: ["gb-main"],
                needles: request.needles, records: request.records)
            XCTAssertTrue(scan.targets.isEmpty,
                          "another conversation's date line must stay out of the erasure set")
            return BotSessionErasureReport()
        }
        let outcome = try await memory.erase(scope: .agent, sessionEraser: eraser)
        XCTAssertTrue(outcome.ok, outcome.error ?? "")
        let text = try String(contentsOf: sessionLogURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\(date) 是项目里程碑"),
                      "the unrelated conversation line must survive")
    }

    // MARK: - Helpers

    private func standardSessionLines() -> [[String: Any]] {
        [
            ["type": "session", "version": 4, "id": "gb-main"],
            ["type": "user/message", "seq": 3, "time": MemoryTestFixtures.now,
             "data": ["message": ["role": "user", "content": [[
                "type": "text",
                "text": "请记住这个随机词：\(marker)。用 UpdateMemory 写入记忆。",
             ]]]]],
            ["type": "session/title", "seq": 4, "time": MemoryTestFixtures.now,
             "data": ["title": "记住随机词 \(marker)", "messageSeqs": [3]]],
            ["type": "assistant/message", "seq": 5, "time": MemoryTestFixtures.now,
             "data": ["message": ["role": "assistant", "content": [[
                "type": "text",
                "text": "记住了：\(marker)，已经写进记忆里存好了。",
             ]]]]],
            ["type": "user/message", "seq": 6, "time": MemoryTestFixtures.now,
             "data": ["message": ["role": "user", "content": [[
                "type": "text", "text": unrelated,
             ]]]]],
        ]
    }

    private func writeSessionLog(lines: [[String: Any]]) throws {
        let text = try lines.map {
            String(decoding: try JSONSerialization.data(
                withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        try text.write(to: sessionLogURL, atomically: true, encoding: .utf8)
    }

    private func applyTombstones(_ target: BotSessionErasureTarget?,
                                 workspaceRoot: URL) throws {
        guard let target, !target.seqs.isEmpty else { return }
        let url = sessionLogURL
        let data = try Data(contentsOf: url)
        let planner = BotSessionErasurePlanner(workspaceRoot: workspaceRoot)
        let replacements = planner.tombstoneLines(
            sessionID: target.sessionID, erasedSeqs: Set(target.seqs),
            erasureID: "session-erasure-regression")
        let bySeq = Dictionary(uniqueKeysWithValues: replacements.map { ($0.seq, $0.data) })
        var output = Data()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            if line.isEmpty { continue }
            let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            let seq = (object?["seq"] as? NSNumber)?.intValue
            let replacement = seq.flatMap { bySeq[$0] }
            output.append(replacement ?? Data(line))
            output.append(0x0A)
        }
        try output.write(to: url, options: .atomic)
    }
}
