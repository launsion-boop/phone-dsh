// SPDX-License-Identifier: MIT
//
// S1-C.1: draining coalesced streamed text at any cadence must produce exactly
// the transcript that applying every delta one by one would produce.

import XCTest

final class NativeStreamAccumulatorTests: XCTestCase {
    private func items() -> [ChatItem] {
        [
            ChatItem(id: "assistant-1", kind: .assistant, title: "Assistant",
                     text: "", streaming: true),
            ChatItem(id: "reasoning-1", kind: .reasoning, title: "思考",
                     text: "", streaming: true),
            ChatItem(id: "tool-1", kind: .toolCall, title: "Tool call: bash",
                     text: "", streaming: false),
        ]
    }

    private struct Event {
        enum Kind {
            case delta(itemID: String, text: String)
            case toolOutput(itemID: String, text: String)
            case finish(itemID: String)
        }
        let kind: Kind
    }

    /// The reference implementation: apply each event as it arrives.
    private func applyIndividually(_ events: [Event]) -> [ChatItem] {
        var result = items()
        for event in events {
            switch event.kind {
            case .delta(let itemID, let text):
                guard let index = result.firstIndex(where: { $0.id == itemID }) else { continue }
                result[index].text += text
            case .toolOutput(let itemID, let text):
                guard let index = result.firstIndex(where: { $0.id == itemID }) else { continue }
                result[index].toolOutput = text
            case .finish(let itemID):
                guard let index = result.firstIndex(where: { $0.id == itemID }) else { continue }
                result[index].streaming = false
            }
        }
        return result
    }

    /// The coalesced path: buffer deltas between drains; non-delta events force
    /// a drain first, exactly as `ChatModel.handle` does.
    private func applyCoalesced(_ events: [Event],
                                drainEvery: Int) -> [ChatItem] {
        var result = items()
        var buffer = NativeStreamAccumulator()
        var buffered = 0
        for event in events {
            switch event.kind {
            case .delta(let itemID, let text):
                buffer.append(text, to: itemID)
                buffered += 1
                if buffered % drainEvery == 0 {
                    result.applyStreamChunks(buffer.take())
                }
            case .toolOutput, .finish:
                result.applyStreamChunks(buffer.take())
                switch event.kind {
                case .toolOutput(let itemID, let text):
                    if let index = result.firstIndex(where: { $0.id == itemID }) {
                        result[index].toolOutput = text
                    }
                case .finish(let itemID):
                    if let index = result.firstIndex(where: { $0.id == itemID }) {
                        result[index].streaming = false
                    }
                case .delta:
                    break
                }
            }
        }
        result.applyStreamChunks(buffer.take())
        return result
    }

    func testCoalescedFinalTextEqualsApplyingEachEvent() {
        var events: [Event] = []
        let tokens = ["Hel", "lo", ", ", "wor", "ld", "!", "\n", "第二", "行"]
        for token in tokens {
            events.append(Event(kind: .delta(itemID: "assistant-1", text: token)))
            events.append(Event(kind: .delta(itemID: "reasoning-1", text: "t")))
        }
        events.append(Event(kind: .toolOutput(itemID: "tool-1", text: "exit 0")))
        events.append(Event(kind: .delta(itemID: "assistant-1", text: " tail")))
        events.append(Event(kind: .finish(itemID: "assistant-1")))
        events.append(Event(kind: .delta(itemID: "reasoning-1", text: "done")))

        let oracle = applyIndividually(events)
        for drainEvery in [1, 2, 3, 7, 100] {
            let coalesced = applyCoalesced(events, drainEvery: drainEvery)
            XCTAssertEqual(coalesced.map(\.id), oracle.map(\.id))
            XCTAssertEqual(coalesced.map(\.text), oracle.map(\.text),
                           "draining every \(drainEvery) deltas changed the final text")
            XCTAssertEqual(coalesced.map(\.toolOutput), oracle.map(\.toolOutput))
            XCTAssertEqual(coalesced.map(\.streaming), oracle.map(\.streaming))
        }
    }

    func testAdjacentChunksMergeButOrderAcrossRowsIsKept() {
        var buffer = NativeStreamAccumulator()
        buffer.append("a", to: "assistant-1")
        buffer.append("b", to: "assistant-1")
        buffer.append("c", to: "reasoning-1")
        buffer.append("d", to: "assistant-1")
        let chunks = buffer.take()
        XCTAssertEqual(chunks, [
            NativeStreamAccumulator.Chunk(itemID: "assistant-1", text: "ab"),
            NativeStreamAccumulator.Chunk(itemID: "reasoning-1", text: "c"),
            NativeStreamAccumulator.Chunk(itemID: "assistant-1", text: "d"),
        ])
        XCTAssertTrue(buffer.isEmpty)
    }

    func testEmptyDeltasAreNoOpsAndTakeClears() {
        var buffer = NativeStreamAccumulator()
        buffer.append("", to: "assistant-1")
        XCTAssertTrue(buffer.isEmpty)
        buffer.append("x", to: "assistant-1")
        XCTAssertEqual(buffer.take(), [NativeStreamAccumulator.Chunk(itemID: "assistant-1", text: "x")])
        XCTAssertEqual(buffer.take(), [])
    }

    func testChunkForAReplacedRowIsDroppedWithoutLosingOtherRows() {
        var result = items()
        result.removeAll { $0.id == "assistant-1" }
        var buffer = NativeStreamAccumulator()
        buffer.append("stale", to: "assistant-1")
        buffer.append("kept", to: "reasoning-1")
        result.applyStreamChunks(buffer.take())
        XCTAssertEqual(result.first(where: { $0.id == "reasoning-1" })?.text, "kept")
        XCTAssertFalse(result.contains { $0.id == "assistant-1" })
    }

    func testRevisionIsBumpedOnlyForRowsThatReceivedText() {
        var result = items()
        let before = result.map(\.renderRevision)
        var buffer = NativeStreamAccumulator()
        buffer.append("x", to: "assistant-1")
        result.applyStreamChunks(buffer.take())
        XCTAssertNotEqual(result[0].renderRevision, before[0])
        XCTAssertEqual(result[1].renderRevision, before[1])
        XCTAssertEqual(result[2].renderRevision, before[2])
    }
}

// MARK: - Large tool output folding (S1-C.2)

final class NativeToolOutputFoldTests: XCTestCase {
    func testShortOutputIsNotFolded() {
        let fold = NativeToolOutputFold(text: "line 1\nline 2")
        XCTAssertFalse(fold.isFolded)
        XCTAssertEqual(fold.collapsedText, "line 1\nline 2")
        XCTAssertEqual(fold.hiddenLineCount, 0)
        XCTAssertEqual(fold.hiddenByteCount, 0)
    }

    func testLongOutputKeepsHeadAndTail() {
        let lines = (0..<300).map { "line \($0)" }
        let text = lines.joined(separator: "\n")
        let fold = NativeToolOutputFold(text: text)
        XCTAssertTrue(fold.isFolded)
        XCTAssertEqual(fold.hiddenLineCount, 100)
        XCTAssertEqual(fold.hiddenByteCount, 0)
        XCTAssertTrue(fold.collapsedText.hasPrefix("line 0\n"))
        XCTAssertTrue(fold.collapsedText.hasSuffix("\nline 299"))
        XCTAssertTrue(fold.collapsedText.contains("其余 100 行未显示"))
        XCTAssertFalse(fold.collapsedText.contains("line 150"))
    }

    func testByteOnlyOverflowFoldsInsideASingleHugeLine() {
        let text = "START" + String(repeating: "x", count: 40_000) + "END"
        let fold = NativeToolOutputFold(text: text)
        XCTAssertTrue(fold.isFolded)
        XCTAssertEqual(fold.hiddenLineCount, 0)
        XCTAssertGreaterThan(fold.hiddenByteCount, 0)
        XCTAssertTrue(fold.collapsedText.hasPrefix("START"))
        XCTAssertTrue(fold.collapsedText.hasSuffix("END"))
        XCTAssertTrue(fold.collapsedText.contains("字节未显示"))
        XCTAssertLessThan(fold.collapsedText.utf8.count, 9_000)
    }

    func testByteSlicesRespectCharacterBoundaries() {
        let text = String(repeating: "字🙂", count: 5_000)
        let fold = NativeToolOutputFold(text: text, maximumLines: 200, maximumBytes: 1_000)
        XCTAssertTrue(fold.isFolded)
        XCTAssertLessThanOrEqual(fold.collapsedText.utf8.count, 1_000 + 200)
        XCTAssertFalse(fold.collapsedText.contains("\u{FFFD}"),
                       "a byte slice must not split a UTF-8 scalar")
        XCTAssertEqual(NativeToolOutputFold.bytePrefix("ab字", maximumBytes: 4), "ab")
        XCTAssertEqual(NativeToolOutputFold.bytePrefix("ab字", maximumBytes: 5), "ab字")
        XCTAssertEqual(NativeToolOutputFold.byteSuffix("ab字", maximumBytes: 3), "字")
        XCTAssertEqual(NativeToolOutputFold.byteSuffix("ab字", maximumBytes: 5), "ab字")
    }
}
