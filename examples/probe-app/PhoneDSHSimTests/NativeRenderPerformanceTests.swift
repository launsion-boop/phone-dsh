// SPDX-License-Identifier: MIT

import Foundation
import UIKit
import XCTest

/// P09 render-performance tests: caches, the LCS short-circuit, the cached
/// timeline oracle and stable row identities.
final class NativeRenderPerformanceTests: XCTestCase {
    // MARK: - Markdown cache

    func testMarkdownParsesSameContentOnceAndReparsesOnRevision() {
        let cache = NativeMarkdownParseCache(countLimit: 16, totalCostLimit: 1_000_000)
        let source = "# 标题\n\n正文 **加粗**"

        let first = cache.blocks(for: source, itemID: "message-1", revision: 0, streaming: false)
        let second = cache.blocks(for: source, itemID: "message-1", revision: 0, streaming: false)

        XCTAssertEqual(cache.parseCount, 1)
        XCTAssertEqual(cache.hitCount, 1)
        XCTAssertEqual(second.count, first.count)

        _ = cache.blocks(for: source, itemID: "message-1", revision: 1, streaming: false)
        XCTAssertEqual(cache.parseCount, 2, "a content revision must invalidate the parse entry")
    }

    func testMarkdownCacheEnforcesCountAndCostLimitsAndPurgesOnMemoryWarning() {
        let cache = NativeMarkdownParseCache(countLimit: 2, totalCostLimit: 5_000)
        let body = String(repeating: "x", count: 2_000)
        for index in 0..<20 {
            _ = cache.blocks(for: body + "\(index)", itemID: "m\(index)",
                             revision: 0, streaming: false)
        }
        XCTAssertLessThanOrEqual(cache.count, 2)
        XCTAssertLessThanOrEqual(cache.approximateCost, 5_000)

        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification,
                                        object: nil)
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.approximateCost, 0)
    }

    func testStreamingEntryReusesOneSlot() {
        let cache = NativeMarkdownParseCache(countLimit: 8, totalCostLimit: 1_000_000)
        for revision in 0..<10 {
            _ = cache.blocks(for: "stream " + String(repeating: "x", count: revision),
                             itemID: "streaming-1", revision: revision, streaming: true)
        }
        XCTAssertEqual(cache.count, 1, "a streaming tail must overwrite its item slot")
        XCTAssertEqual(cache.parseCount, 10)
    }

    // MARK: - LCS short-circuit

    func testFiveThousandLineDiffSkipsLCSAndReturnsCounts() {
        let cache = NativeDiffLineCountsCache()
        let old = (0..<5_000).map { "old-\($0)" }.joined(separator: "\n")
        let new = (0..<5_000).map { "new-\($0)" }.joined(separator: "\n")

        let counts = cache.counts(old: old, new: new)

        XCTAssertEqual(counts.added, 5_000)
        XCTAssertEqual(counts.deleted, 5_000)
        XCTAssertEqual(cache.lcsRuns, 0, "no DP table may be built above 300 lines")
        XCTAssertEqual(cache.shortCircuits, 1)
    }

    func testSmallDiffMatchesOriginalLCSOracle() {
        let cases: [(String?, String)] = [
            (nil, "one\ntwo"),
            ("", "one\ntwo"),
            ("one\ntwo", "one\ntwo"),
            ("one\ntwo\nthree", "one\nthree"),
            ("a\nb\nc\nd", "a\nx\nc\ny\nd"),
            ("same\r\nline", "same\nline"),
        ]
        for (old, new) in cases {
            let cache = NativeDiffLineCountsCache()
            let cached = cache.counts(old: old, new: new)
            let oracle = originalLineCounts(old: old, new: new)
            XCTAssertEqual(cached.added, oracle.added, "old=\(String(describing: old)) new=\(new)")
            XCTAssertEqual(cached.deleted, oracle.deleted, "old=\(String(describing: old)) new=\(new)")
            XCTAssertEqual(cache.lcsRuns, 1)
        }
    }

    // MARK: - Timeline cache

    func testTimelineCacheReusesRowsAndMatchesOriginalProjection() {
        var items = timelineFixture()
        let changes = NativeChangesCache()
        let cache = NativeTimelineCache(changesCache: changes)
        let facts = timelineFacts()

        let first = cache.snapshot(items: items, itemsRevision: 1, foldedTurns: [],
                                   endReasons: facts.endReasons,
                                   startTimes: facts.startTimes, endTimes: facts.endTimes)
        let second = cache.snapshot(items: items, itemsRevision: 1, foldedTurns: [],
                                    endReasons: facts.endReasons,
                                    startTimes: facts.startTimes, endTimes: facts.endTimes)

        XCTAssertEqual(cache.rebuildCount, 1, "an unchanged items revision must not regroup")
        XCTAssertEqual(first.rows, second.rows)
        XCTAssertEqual(first.rows, originalRows(from: items,
                                                foldedTurns: [],
                                                state: stateResolver(facts)))

        // Append a row.
        var appended = items
        appended.append(makeItem(id: "a2", kind: .assistant, turn: 2, text: "second answer"))
        let appendedSnapshot = cache.snapshot(items: appended, itemsRevision: 2, foldedTurns: [],
                                               endReasons: facts.endReasons,
                                               startTimes: facts.startTimes, endTimes: facts.endTimes)
        XCTAssertEqual(cache.rebuildCount, 2)
        XCTAssertEqual(appendedSnapshot.rows,
                       originalRows(from: appended, foldedTurns: [], state: stateResolver(facts)))

        // Stream into the last assistant row.
        var streamed = appended
        streamed[streamed.count - 1].text += "!"
        streamed[streamed.count - 1].bumpRenderRevision()
        let streamedSnapshot = cache.snapshot(items: streamed, itemsRevision: 3, foldedTurns: [],
                                               endReasons: facts.endReasons,
                                               startTimes: facts.startTimes, endTimes: facts.endTimes)
        XCTAssertEqual(streamedSnapshot.rows,
                       originalRows(from: streamed, foldedTurns: [], state: stateResolver(facts)))
        XCTAssertEqual(streamedSnapshot.scrollSignature,
                       streamed.filter { $0.kind != .status }.map(\.id).joined(separator: ",")
                       + "|" + (streamedSnapshot.visibleItems.last?.text ?? ""))

        // Folded turns change grouping too.
        let folded = cache.snapshot(items: streamed, itemsRevision: 3, foldedTurns: [1],
                                    endReasons: facts.endReasons,
                                    startTimes: facts.startTimes, endTimes: facts.endTimes)
        XCTAssertEqual(cache.rebuildCount, 4)
        XCTAssertEqual(folded.rows, originalRows(from: streamed, foldedTurns: [1],
                                                 state: stateResolver(facts)))
    }

    func testTimelineCacheRecomputesAfterItemModification() {
        var items = timelineFixture()
        let facts = timelineFacts()
        let cache = NativeTimelineCache(changesCache: NativeChangesCache())

        _ = cache.snapshot(items: items, itemsRevision: 1, foldedTurns: [],
                           endReasons: facts.endReasons,
                           startTimes: facts.startTimes, endTimes: facts.endTimes)
        guard let index = items.firstIndex(where: { $0.id == "a1" }) else {
            return XCTFail("fixture is missing the first answer")
        }
        items[index].text = "answer one, revised"
        items[index].bumpRenderRevision()

        let modified = cache.snapshot(items: items, itemsRevision: 2, foldedTurns: [],
                                      endReasons: facts.endReasons,
                                      startTimes: facts.startTimes, endTimes: facts.endTimes)
        XCTAssertEqual(cache.rebuildCount, 2)
        XCTAssertEqual(modified.rows, originalRows(from: items, foldedTurns: [],
                                                   state: stateResolver(facts)))
        XCTAssertEqual(modified.scrollSignature,
                       items.filter { $0.kind != .status }.map(\.id).joined(separator: ",")
                       + "|answer two")
    }

    // MARK: - Re-created rows and cache identity

    func testRecreatedChatItemDoesNotReuseMarkdownParseCache() {
        let cache = NativeMarkdownParseCache(countLimit: 16, totalCostLimit: 1_000_000)
        let first = ChatItem(id: "same-id", kind: .assistant, title: "Assistant", text: "# 第一版")
        let second = ChatItem(id: "same-id", kind: .assistant, title: "Assistant", text: "## 第二版")
        XCTAssertNotEqual(first.renderRevision, second.renderRevision,
                          "a re-created instance must carry a fresh revision")
        let copy = first
        XCTAssertEqual(copy.renderRevision, first.renderRevision,
                       "a value copy keeps the same revision")

        let firstBlocks = cache.blocks(for: first.text, itemID: first.id,
                                       revision: first.renderRevision, streaming: false)
        let secondBlocks = cache.blocks(for: second.text, itemID: second.id,
                                        revision: second.renderRevision, streaming: false)
        XCTAssertEqual(cache.parseCount, 2,
                       "same id + different text must not reuse the old parse")

        guard let firstBlock = firstBlocks.first,
              case .heading(let firstLevel, _) = firstBlock,
              let secondBlock = secondBlocks.first,
              case .heading(let secondLevel, _) = secondBlock else {
            return XCTFail("fixtures must parse into headings")
        }
        XCTAssertEqual([firstLevel, secondLevel], [1, 2])

        _ = cache.blocks(for: second.text, itemID: second.id,
                         revision: second.renderRevision, streaming: false)
        XCTAssertEqual(cache.parseCount, 2, "the same instance's unchanged content must hit")
        XCTAssertEqual(cache.missCount, 1,
                       "only the first lookup of this key inserts a parse entry")
    }

    func testBumpedItemRevisionCannotCollideWithRecreatedInstance() {
        let cache = NativeMarkdownParseCache(countLimit: 16, totalCostLimit: 1_000_000)
        let source = "# 同一段正文"

        var streamed = ChatItem(id: "bumped-same-id", kind: .assistant,
                                title: "Assistant", text: source)
        var revisions: Set<Int> = [streamed.renderRevision]
        for _ in 0..<5 {
            streamed.bumpRenderRevision()
            revisions.insert(streamed.renderRevision)
        }
        XCTAssertEqual(revisions.count, 6, "every bump takes a fresh global revision")

        // Under a per-item `&+= 1` these allocations would advance the global
        // source into the range the streamed instance already occupies.
        for index in 0..<4 {
            _ = ChatItem(id: "filler-\(index)", kind: .assistant, title: "Assistant", text: "")
        }

        let rebuilt = ChatItem(id: streamed.id, kind: .assistant,
                               title: "Assistant", text: source)
        XCTAssertFalse(revisions.contains(rebuilt.renderRevision),
                       "a re-created instance must never reuse a bumped revision")
        XCTAssertGreaterThan(rebuilt.renderRevision, revisions.max() ?? 0,
                             "the global source is monotonic across instances")

        _ = cache.blocks(for: streamed.text, itemID: streamed.id,
                         revision: streamed.renderRevision, streaming: false)
        XCTAssertEqual(cache.parseCount, 1)
        _ = cache.blocks(for: rebuilt.text, itemID: rebuilt.id,
                         revision: rebuilt.renderRevision, streaming: false)
        XCTAssertEqual(cache.parseCount, 2,
                       "same id + same text must reparse under the new revision")
        XCTAssertEqual(cache.missCount, 1,
                       "the stale entry's revision must not be served")
    }

    func testRecreatedChatItemDoesNotReuseRowSummaryCache() {
        let cache = NativeRowSummaryCache(countLimit: 16, totalCostLimit: 100_000)
        let firstTool = ChatItem(id: "tool-same", kind: .toolCall, title: "Tool", text: "first")
        let secondTool = ChatItem(id: "tool-same", kind: .toolCall, title: "Tool", text: "second")
        XCTAssertNotEqual(firstTool.renderRevision, secondTool.renderRevision)

        var toolComputations = 0
        let firstSummary = cache.toolSummary(for: firstTool) {
            toolComputations += 1
            return "tool:\(firstTool.text)"
        }
        let secondSummary = cache.toolSummary(for: secondTool) {
            toolComputations += 1
            return "tool:\(secondTool.text)"
        }
        XCTAssertEqual([firstSummary, secondSummary], ["tool:first", "tool:second"])
        XCTAssertEqual(toolComputations, 2)

        XCTAssertEqual(cache.toolSummary(for: secondTool) {
            toolComputations += 1
            return "unexpected"
        }, "tool:second")
        XCTAssertEqual(toolComputations, 2, "an unchanged instance must hit the summary cache")

        let firstThinking = ChatItem(id: "think-same", kind: .reasoning, title: "思考",
                                     text: "第一段\n\n旧内容")
        let secondThinking = ChatItem(id: "think-same", kind: .reasoning, title: "思考",
                                      text: "第二版\n\n新内容")
        XCTAssertEqual(cache.thinkingSummary(for: firstThinking), "第一段")
        XCTAssertEqual(cache.thinkingSummary(for: secondThinking), "第二版")
        XCTAssertEqual(cache.thinkingSummary(for: secondThinking), "第二版")
        XCTAssertEqual(cache.missCount, 4,
                       "two tool rows plus two re-created thinking rows, no stale hits")
    }

    func testRecreatedChatItemDoesNotReuseTurnChangesCache() {
        let changes = NativeChangesCache()
        let cache = NativeTimelineCache(changesCache: changes)
        let facts = timelineFacts()

        func snapshot(_ items: [ChatItem], revision: Int) -> NativeTimelineSnapshot {
            cache.snapshot(items: items, itemsRevision: revision, foldedTurns: [],
                           endReasons: facts.endReasons,
                           startTimes: facts.startTimes, endTimes: facts.endTimes)
        }

        let firstTool = writeTool(id: "write-same", content: "first line")
        let firstAnswer = makeItem(id: "answer-same", kind: .assistant, turn: 1, text: "done")
        let first = snapshot([firstTool, firstAnswer], revision: 1)
        XCTAssertEqual(first.turnFacts[1]?.changes?.files.first?.newText, "first line")
        XCTAssertEqual(changes.missCount, 1)

        let secondTool = writeTool(id: "write-same", content: "second line")
        let secondAnswer = makeItem(id: "answer-same", kind: .assistant, turn: 1, text: "done")
        XCTAssertNotEqual(firstTool.renderRevision, secondTool.renderRevision)
        let second = snapshot([secondTool, secondAnswer], revision: 2)
        XCTAssertEqual(second.turnFacts[1]?.changes?.files.first?.newText, "second line",
                       "same id + different tool content must not reuse the old changes")
        XCTAssertEqual(changes.missCount, 2)

        _ = snapshot([secondTool, secondAnswer], revision: 3)
        XCTAssertEqual(changes.missCount, 2, "unchanged instances must hit the changes cache")
        XCTAssertEqual(cache.rebuildCount, 3)
    }

    // MARK: - Stable identities

    func testToolGroupIdIsStableWhenMembersAreAppended() {
        let first = makeItem(id: "tool-1", kind: .toolCall, turn: 1, text: "{}")
        let second = makeItem(id: "tool-2", kind: .toolResult(isError: false), turn: 1, text: "ok")
        let one = NativeTranscriptRow.tools([first])
        let two = NativeTranscriptRow.tools([first, second])

        XCTAssertEqual(one.id, two.id)
        XCTAssertEqual(one.scrollTargetID, one.id)
        XCTAssertTrue(one.id.hasPrefix("tool-run-1-"))
    }

    func testContextGroupIdMatchesScrollTarget() {
        let context = makeItem(id: "ctx-1", kind: .context, turn: nil, text: "ctx")
        let row = NativeTranscriptRow.contexts([context])

        XCTAssertEqual(row.id, "context-group-ctx-1")
        XCTAssertEqual(row.scrollTargetID, row.id)
        XCTAssertFalse(row.id.hasPrefix("context-group-context-"))
    }

    func testEveryRowKindExposesTheSameForEachAndScrollTargetID() {
        var item = makeItem(id: "assistant", kind: .assistant, turn: 1, text: "done")
        item.streaming = false
        let rows: [NativeTranscriptRow] = [
            .item(item),
            .contexts([makeItem(id: "ctx", kind: .context, turn: nil, text: "")]),
            .tools([makeItem(id: "tool", kind: .toolCall, turn: 1, text: "")]),
            .turnProcess(1),
            .turnTail(1),
        ]
        for row in rows {
            XCTAssertEqual(row.scrollTargetID, row.id)
        }
        XCTAssertEqual(rows.map(\.id).count, Set(rows.map(\.id)).count)
    }

    // MARK: - Highlight cache

    func testHighlightComputesOnceAndReusesRegexes() {
        NativeCodeHighlighter.resetForTesting()
        let source = "func greet() -> String { return \"hi\" } // comment"
        let first = NativeCodeHighlighter.attributed(source, language: "swift")
        let second = NativeCodeHighlighter.attributed(source, language: "swift")

        XCTAssertEqual(NativeCodeHighlighter.computeCount, 1)
        XCTAssertEqual(String(first.characters), String(second.characters))
        XCTAssertEqual(String(first.characters), source)
        let other = NativeCodeHighlighter.attributed(source, language: "typescript")
        XCTAssertEqual(NativeCodeHighlighter.computeCount, 2)
        XCTAssertEqual(String(other.characters), source)
    }

    // MARK: - Helpers

    private struct TimelineFacts {
        var endReasons: [Int: String]
        var startTimes: [Int: Date]
        var endTimes: [Int: Date]
    }

    private func timelineFacts() -> TimelineFacts {
        let start = Date(timeIntervalSince1970: 1_000)
        return TimelineFacts(endReasons: [1: "completed", 2: "aborted"],
                             startTimes: [1: start, 2: start.addingTimeInterval(10)],
                             endTimes: [1: start.addingTimeInterval(4),
                                        2: start.addingTimeInterval(12)])
    }

    private func stateResolver(_ facts: TimelineFacts) -> (Int) -> NativeTurnProcessState? {
        { turn in
            NativeTurnStateResolver.resolve(turn: turn, endReasons: facts.endReasons,
                                            startTimes: facts.startTimes, endTimes: facts.endTimes)
        }
    }

    private func timelineFixture() -> [ChatItem] {
        var user = makeItem(id: "u1", kind: .user, turn: 1, text: "question")
        user.timestamp = Date(timeIntervalSince1970: 1_000)
        var reasoning = makeItem(id: "r1", kind: .reasoning, turn: 1, text: "thinking")
        reasoning.streaming = true
        var toolCall = makeItem(id: "t1", kind: .toolCall, turn: 1, text: "{}")
        toolCall.toolName = "write"
        toolCall.toolState = .ok
        toolCall.arguments = .object(["file_path": .string("a.md"), "content": .string("one\ntwo")])
        var toolResult = makeItem(id: "t2", kind: .toolResult(isError: false), turn: 1, text: "ok")
        toolResult.toolName = "write"
        toolResult.toolState = .ok
        var answer = makeItem(id: "a1", kind: .assistant, turn: 1, text: "answer one")
        answer.streaming = false
        var context = makeItem(id: "c1", kind: .context, turn: nil, text: "ctx")
        context.sourceKind = "goal"
        var secondUser = makeItem(id: "u2", kind: .user, turn: 2, text: "again")
        secondUser.timestamp = Date(timeIntervalSince1970: 1_010)
        var secondAnswer = makeItem(id: "a2", kind: .assistant, turn: 2, text: "answer two")
        secondAnswer.streaming = false
        var status = makeItem(id: "s1", kind: .status, turn: nil, text: "status")
        status.title = "Host"
        return [user, reasoning, toolCall, toolResult, answer, context, secondUser, secondAnswer, status]
    }

    private func makeItem(id: String, kind: ChatItem.Kind, turn: Int?, text: String) -> ChatItem {
        var item = ChatItem(id: id, kind: kind, title: "row", text: text)
        item.turn = turn
        item.timestamp = Date(timeIntervalSince1970: 1_000)
        return item
    }

    private func writeTool(id: String, content: String) -> ChatItem {
        var item = makeItem(id: id, kind: .toolCall, turn: 1, text: "")
        item.toolName = "write"
        item.toolState = .ok
        item.arguments = .object([
            "file_path": .string("a.md"),
            "content": .string(content),
        ])
        return item
    }

    /// The pre-S1 `ChatPage.timelineRows` implementation, kept as the oracle.
    private func originalRows(from items: [ChatItem], foldedTurns: Set<Int>,
                              state: (Int) -> NativeTurnProcessState?) -> [NativeTranscriptRow] {
        let visibleItems = items.filter { $0.kind != .status }
        var rows: [NativeTranscriptRow] = []
        var lastTurn: Int?
        var pendingTurnControl: Int?
        let answerIDs: [Int: String] = Dictionary(
            grouping: visibleItems.filter { $0.turn != nil && $0.kind == .assistant },
            by: { $0.turn! }).compactMapValues { $0.last?.id }
        let rowItems = visibleItems.filter { item in
            guard let turn = item.turn, foldedTurns.contains(turn),
                  let answerID = answerIDs[turn] else { return true }
            if item.kind == .user || item.kind == .context { return true }
            return item.id == answerID
        }
        for item in rowItems {
            if item.kind == .user, let previous = lastTurn, item.turn != previous,
               let previousState = state(previous), previousState != .running {
                rows.append(.turnTail(previous))
                lastTurn = nil
            }
            if let turn = item.turn, turn != lastTurn {
                if let previous = lastTurn, previous != turn, state(previous) != nil {
                    rows.append(.turnTail(previous))
                }
                lastTurn = turn
                pendingTurnControl = state(turn) != nil ? turn : nil
            }
            if let pending = pendingTurnControl,
               item.kind != .user, item.kind != .context {
                rows.append(.turnProcess(pending))
                pendingTurnControl = nil
            }
            if item.kind == .context {
                if case .contexts(let previous)? = rows.last {
                    rows[rows.count - 1] = .contexts(previous + [item])
                } else {
                    rows.append(.contexts([item]))
                }
            } else if isProcessKind(item.kind) {
                if case .tools(let previous)? = rows.last {
                    rows[rows.count - 1] = .tools(previous + [item])
                } else {
                    rows.append(.tools([item]))
                }
            } else {
                rows.append(.item(item))
            }
        }
        if let lastTurn, state(lastTurn) != nil {
            rows.append(.turnTail(lastTurn))
        }
        return rows
    }

    private func isProcessKind(_ kind: ChatItem.Kind) -> Bool {
        switch kind {
        case .reasoning, .toolCall, .toolResult: return true
        default: return false
        }
    }

    /// The pre-S1 LCS implementation, kept as the oracle for small diffs.
    private func originalLineCounts(old: String?, new: String) -> (added: Int, deleted: Int) {
        let oldLines = (old ?? "").components(separatedBy: .newlines)
        let newLines = new.components(separatedBy: .newlines)
        var table = Array(repeating: Array(repeating: 0, count: newLines.count + 1),
                          count: oldLines.count + 1)
        if oldLines.count > 0, newLines.count > 0 {
            for i in stride(from: oldLines.count - 1, through: 0, by: -1) {
                for j in stride(from: newLines.count - 1, through: 0, by: -1) {
                    table[i][j] = oldLines[i] == newLines[j]
                        ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        let common = table[0][0]
        return (newLines.count - common, oldLines.count - common)
    }
}
