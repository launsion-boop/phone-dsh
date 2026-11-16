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
        XCTAssertTrue(needles.contains("QUOKKA"),
                      "script-boundary segmentation must yield the Latin run")
    }

    /// Boundary matrix for the generic segmentation: script changes,
    /// punctuation/emoji, pure Latin words, Han runs, short words and digit
    /// runs. No language-specific or marker-shaped special case.
    func testGenericNeedleBoundaries() {
        func needles(_ content: String) -> Set<String> {
            SQLiteBotMemoryDocumentStore.erasureNeedles(in: content)
        }
        XCTAssertTrue(needles("记住的随机词：QUOKKA_AHA_9D2，写好了。").contains("QUOKKA"))
        XCTAssertTrue(needles("记住：КВОККА_ТЕСТ_9，写好了。").contains("КВОККА"))
        XCTAssertTrue(needles("记住：ماركر_اختبار，写好了。").contains("اختبار"))
        XCTAssertTrue(needles("🔥 QUOKKA 🔥（重要）").contains("QUOKKA"))
        XCTAssertTrue(needles("随机词QUOKKA写好了").contains("QUOKKA"))
        XCTAssertTrue(needles("随机词QUOKKAКВОККА").contains("КВОККА"))
        XCTAssertTrue(needles("remember this").contains("remember"))
        XCTAssertTrue(needles("记住这个随机词").contains("记住这个随机词"))
        XCTAssertFalse(needles("the and for").contains("the"))
        XCTAssertFalse(needles("the and for").contains("and"))
        XCTAssertTrue(SQLiteBotMemoryDocumentStore
            .scriptBoundaryCandidates(in: "1234567890").isEmpty,
            "the script-boundary mechanism never yields a pure numeric run")
        XCTAssertFalse(needles("记住").contains("记住"),
                       "short words are below the six-scalar threshold")
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
                "type": "text", "text": "the and for",
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
        XCTAssertTrue(text.contains("the and for"),
                      "short common words must not become erasure targets")
        let lines = BotSessionLogReader.lines(from: Data(text.utf8))
        for seq in [3, 4, 5] {
            XCTAssertEqual(lines.first { $0.seq == seq }?.erased, true)
        }
        XCTAssertEqual(lines.first { $0.seq == 6 }?.erased, false)
        let continuation = try XCTUnwrap(capturedContinuation)
        XCTAssertFalse(continuation.contains("КВОККА"))
        XCTAssertFalse(continuation.contains("اختبار"))
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
