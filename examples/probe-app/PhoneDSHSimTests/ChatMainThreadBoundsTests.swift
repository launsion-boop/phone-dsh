// SPDX-License-Identifier: MIT
// P09 main-thread bound: incremental Markdown, off-main snapshot status/log
// and hang evidence regressions.

import Foundation
import ProbeKit
import XCTest

// MARK: - Markdown incremental equivalence

final class NativeMarkdownIncrementalSwiftTests: XCTestCase {
    private struct SeededRandom {
        var state: UInt64

        init(seed: UInt64) {
            state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        }

        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }

        mutating func int(upperBound: Int) -> Int {
            guard upperBound > 0 else { return 0 }
            return Int(next() % UInt64(upperBound))
        }
    }

    private let fixtures: [(String, String)] = [
        ("headings", """
        # 一级标题

        正文 **加粗** *斜体* ~~删除~~ `code` [链接](https://example.com)。

        ## 二级标题

        第二段。

        Setext 标题
        ===========

        下一段。

        ---

        结束。

        """),
        ("nested-lists", """
        - 第一项
          - 嵌套项
            继续缩进的段落
          - 另一个嵌套项

          1. 有序一
          2. 有序二

        - 第二项

        列表之后的一段普通文字。

        > 引用第一段
        >
        > 引用第二段

        结束。
        """),
        ("fenced-code-with-blank-lines", """
        前面

        ```swift
        func outer() {
            let value = 1

            let nested = \"\"\"
            blank line follows

            still code
            \"\"\"
        }
        ```

        中间

        ~~~
        tilde fence

        with a blank line
        ~~~

        后面
        """),
        ("table", """
        介绍

        | 左 | 右 |
        |:--|--:|
        | A | B |
        | C | D |

        表格之后
        """),
        ("indented-code", """
        段落

            code line one

            code line two

        后面
        """),
        ("math", """
        行内 $x^2$ 与 \\(y+1\\)

        $$
        y = mx + b

        z = 2
        $$

        数学之后

        ```math
        a^2 + b^2
        ```
        """),
        ("html-script", """
        介绍

        <script>
        var first = 1;

        var second = 2;
        </script>

        之后

        <div>
        普通 HTML 块

        仍然是 HTML 块
        </div>

        结尾
        """),
        ("link-references", """
        [alpha] 和 [beta]

        [alpha]: https://example.com/a
        [beta]: https://example.com/b

        [alpha] 再次出现

        """),
        ("long-single-paragraph", String(repeating: "这是一个没有空行的很长段落，包含 **加粗**、`code` 和普通文字。", count: 260)),
        ("plain-long-single-paragraph", String(repeating: "这是一个没有空行也没有行内标记的很长段落，只有普通文字和标点。", count: 260)),
        ("plain-double-spaces", String(repeating: "alpha  beta   gamma delta  ", count: 80)),
    ]

    func testIncrementalEqualsFullStreamingParseAtEveryChunk() {
        for (name, fixture) in fixtures {
            for seed in [1, 7, 42, 9_999] as [UInt64] {
                var parser = NativeMarkdownIncrementalParser()
                var assembled = ""
                for chunk in chunks(of: fixture, seed: seed, maxChunk: 19) {
                    assembled += chunk
                    let incremental = parser.append(chunk)
                    let expected = NativeMarkdownParser.parse(assembled, streaming: true)
                    XCTAssertEqual(incremental, expected,
                                   "fixture=\(name) seed=\(seed) length=\(assembled.utf8.count)")
                }
            }
        }
    }

    func testFenceSplitAcrossChunksKeepsOneCodeBlock() {
        let source = "说明\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\n结束\n"
        var parser = NativeMarkdownIncrementalParser()
        var assembled = ""
        // Deliberately split inside the opening fence and inside its blank line.
        for chunk in ["说明\n\n`", "`", "`swift\nlet a", " = 1\n\nlet b = 2\n", "```\n\n结束\n"] {
            assembled += chunk
            XCTAssertEqual(parser.append(chunk),
                           NativeMarkdownParser.parse(assembled, streaming: true))
        }
        XCTAssertTrue(parser.blocks.contains {
            guard case .code(let language, let text) = $0 else { return false }
            return language == "swift" && text.contains("let a = 1") && text.contains("let b = 2")
        })
    }

    // MARK: Perf guard

    func testPlainSingleParagraphStreamStaysLinear() {
        var text = ""
        text.reserveCapacity(210_000)
        for index in 0..<4_200 {
            text += "plain reasoning line \(index) with punctuation and spaces. "
        }
        let finalLength = text.utf8.count
        let bytes = Array(text.utf8)

        NativeMarkdownParseWork.reset()
        var parser = NativeMarkdownIncrementalParser()
        var index = 0
        var deltas = 0
        while index < bytes.count {
            let end = min(index + 40, bytes.count)
            let chunk = String(decoding: bytes[index..<end], as: UTF8.self)
            _ = parser.append(chunk)
            index = end
            deltas += 1
        }
        let parsed = NativeMarkdownParseWork.parsedCharacters
        print("MARKDOWN_PLAIN_PERF parsed=\(parsed) final=\(finalLength) ratio=\(Double(parsed) / Double(finalLength)) deltas=\(deltas) plain=\(parser.plainAppendCount) tailParses=\(parser.tailParseCount)")
        XCTAssertGreaterThanOrEqual(deltas, 5_000)
        XCTAssertLessThan(parsed, finalLength * 10,
                          "parsed=\(parsed) final=\(finalLength) deltas=\(deltas)")
        XCTAssertEqual(parser.blocks, NativeMarkdownParser.parse(text, streaming: true))
    }

    func testStreamingParseWorkStaysLinearForFiveThousandDeltas() {
        var text = ""
        text.reserveCapacity(220_000)
        for paragraph in 0..<500 {
            for line in 0..<5 {
                text += "p\(paragraph) l\(line) "
                text += String(repeating: "x", count: 78)
                text += "\n"
            }
            text += "\n"
        }
        let finalLength = text.utf8.count
        let bytes = Array(text.utf8)

        NativeMarkdownParseWork.reset()
        var parser = NativeMarkdownIncrementalParser()
        var index = 0
        var deltas = 0
        while index < bytes.count {
            let end = min(index + 40, bytes.count)
            let chunk = String(decoding: bytes[index..<end], as: UTF8.self)
            _ = parser.append(chunk)
            index = end
            deltas += 1
        }
        let parsed = NativeMarkdownParseWork.parsedCharacters
        XCTAssertGreaterThanOrEqual(deltas, 5_000)
        print("MARKDOWN_PERF parsed=\(parsed) final=\(finalLength) ratio=\(Double(parsed) / Double(finalLength)) deltas=\(deltas)")
        XCTAssertLessThan(parsed, finalLength * 10,
                          "parsed=\(parsed) final=\(finalLength) deltas=\(deltas)")
        XCTAssertEqual(parser.blocks, NativeMarkdownParser.parse(text, streaming: true))
    }

    private func chunks(of text: String, seed: UInt64, maxChunk: Int) -> [String] {
        var random = SeededRandom(seed: seed)
        var chunks: [String] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let remaining = text.distance(from: cursor, to: text.endIndex)
            let size = min(remaining, 1 + random.int(upperBound: maxChunk))
            let end = text.index(cursor, offsetBy: size)
            chunks.append(String(text[cursor..<end]))
            cursor = end
        }
        return chunks
    }
}

// MARK: - Transcript snapshot writer

final class TranscriptSnapshotWriterTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func settledItems() -> [ChatItem] {
        (0..<300).map { index in
            let kind: ChatItem.Kind
            switch index % 5 {
            case 0: kind = .user
            case 1: kind = .assistant
            case 2: kind = .reasoning
            case 3: kind = .toolCall
            default: kind = .toolResult(isError: false)
            }
            return ChatItem(id: "item-\(index)", kind: kind, title: "row \(index)",
                            text: "\(index):" + String(repeating: "z", count: 10_000))
        }
    }

    func testSubmitReturnsFastOnMainAndBytesMatchPreviousEncoder() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("session-a.json")
        let items = settledItems()
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let writer = TranscriptSnapshotWriter(isCurrentSession: { _, _ in true })

        XCTAssertTrue(Thread.isMainThread)
        let start = ProcessInfo.processInfo.systemUptime
        writer.submit(items: items, backend: .phone, sessionID: "session-a",
                      lastSeq: 42, url: url, capturedAt: capturedAt)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print("SNAPSHOT_SUBMIT_MS \(elapsed * 1_000)")
        XCTAssertLessThan(elapsed, 0.005, "main-actor snapshot submit took \(elapsed)s")

        writer.waitForIdle()
        let actual = try Data(contentsOf: url)
        let cached = items.map {
            CachedTranscriptItem(id: $0.id, kind: $0.kind.cachedTranscriptKindName,
                                 title: $0.title, text: $0.text)
        }
        let expected = try XCTUnwrap(CachedTranscriptCodec.encode(
            items: cached, backend: .phone, sessionID: "session-a",
            lastSeq: 42, capturedAt: capturedAt))
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(writer.stats().writes, 1)
    }

    func testWorkspaceDestinationIsResolvedOffMain() throws {
        let documents = try temporaryDirectory()
        let writer = TranscriptSnapshotWriter(isCurrentSession: { _, _ in true })
        let items = [ChatItem(id: "a", kind: .assistant, title: "Assistant", text: "hello")]
        writer.submit(items: items, backend: .phone, sessionID: "session-workspace",
                      lastSeq: 7, documentsDirectory: documents)
        writer.waitForIdle()
        let url = documents
            .appendingPathComponent("transcript-snapshots", isDirectory: true)
            .appendingPathComponent("phone", isDirectory: true)
            .appendingPathComponent("session-workspace.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let cached = items.map {
            CachedTranscriptItem(id: $0.id, kind: $0.kind.cachedTranscriptKindName,
                                 title: $0.title, text: $0.text)
        }
        let data = try Data(contentsOf: url)
        let decoded = try XCTUnwrap(CachedTranscriptCodec.decode(
            data, backend: .phone, sessionID: "session-workspace"))
        XCTAssertEqual(decoded.items, cached)
        XCTAssertEqual(decoded.lastSeq, 7)
    }

    func testQueuedSnapshotsCoalesceToTheLatest() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("session-a.json")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let callLock = NSLock()
        var calls = 0
        let writer = TranscriptSnapshotWriter(isCurrentSession: { _, _ in
            callLock.lock()
            calls += 1
            let call = calls
            callLock.unlock()
            if call == 1 {
                entered.signal()
                release.wait()
            }
            return true
        })
        writer.submit(items: [ChatItem(id: "a", kind: .assistant, title: "A", text: "first")],
                      backend: .phone, sessionID: "session-a", lastSeq: nil, url: url)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        // Two more submits while the first write is in flight: the second
        // queued one replaces the first, so only "third" is written last.
        writer.submit(items: [ChatItem(id: "a", kind: .assistant, title: "A", text: "second")],
                      backend: .phone, sessionID: "session-a", lastSeq: nil, url: url)
        writer.submit(items: [ChatItem(id: "a", kind: .assistant, title: "A", text: "third")],
                      backend: .phone, sessionID: "session-a", lastSeq: nil, url: url)
        release.signal()
        writer.waitForIdle()
        let decoded = try XCTUnwrap(CachedTranscriptCodec.decode(
            try Data(contentsOf: url), backend: .phone, sessionID: "session-a"))
        XCTAssertEqual(decoded.items.map(\.text), ["third"])
        XCTAssertEqual(writer.stats().coalesced, 1)
    }

    func testStaleWriteAfterSessionSwitchDoesNotOverwrite() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("session-a.json")
        var currentSession: String? = "session-a"
        let writer = TranscriptSnapshotWriter(isCurrentSession: { _, session in
            currentSession == session
        })
        let old = [ChatItem(id: "a-old", kind: .assistant, title: "Assistant", text: "old")]
        writer.submit(items: old, backend: .phone, sessionID: "session-a",
                      lastSeq: nil, url: url)
        writer.waitForIdle()
        let oldData = try Data(contentsOf: url)

        currentSession = "session-b"
        let newer = [ChatItem(id: "a-new", kind: .assistant, title: "Assistant", text: "new")]
        writer.submit(items: newer, backend: .phone, sessionID: "session-a",
                      lastSeq: nil, url: url)
        writer.waitForIdle()

        XCTAssertEqual(try Data(contentsOf: url), oldData)
        XCTAssertEqual(writer.stats().skipped, 1)
    }

    func testInvalidateDropsWriteThatAlreadyStartedEncoding() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("session-a.json")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let writer = TranscriptSnapshotWriter(isCurrentSession: { _, _ in
            entered.signal()
            release.wait()
            return true
        })
        writer.submit(items: [ChatItem(id: "a", kind: .assistant, title: "A", text: "stale")],
                      backend: .phone, sessionID: "session-a", lastSeq: nil, url: url)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        // The job has started (and passed the first session check); the epoch
        // check before the filesystem write must still reject it.
        writer.invalidate()
        release.signal()
        writer.waitForIdle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

// MARK: - Status log, hang monitor, MetricKit

final class StatusAndHangMonitorTests: XCTestCase {
    private final class LineBox {
        private let lock = NSLock()
        private var lines: [String] = []

        func append(_ line: String) {
            lock.lock(); lines.append(line); lock.unlock()
        }

        var snapshot: [String] {
            lock.lock(); defer { lock.unlock() }
            return lines
        }
    }

    func testStatusLogKeepsBothLineFormats() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("status-\(UUID().uuidString).log")
        let writer = ChatStatusLogWriter(url: url)
        writer.append("plain status")
        writer.appendRaw("raw diagnostic")
        writer.waitForIdle()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(" plain status\n"))
        XCTAssertTrue(text.hasSuffix("raw diagnostic\n"))
        try? FileManager.default.removeItem(at: url)
    }

    func testHangMonitorRecordsOneStartEndPairWithMarker() {
        XCTAssertTrue(Thread.isMainThread, "the test itself blocks the main queue")
        let lines = LineBox()
        let monitor = MainThreadHangMonitor(pingInterval: 0.05, hangThreshold: 0.25)
        monitor.start { line in lines.append(line) }
        monitor.mark("test.hang.marker")

        Thread.sleep(forTimeInterval: 1.1)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !lines.snapshot.contains(where: { $0.hasPrefix("main-hang end") }) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        monitor.stop()
        let captured = lines.snapshot
        let starts = captured.filter { $0.hasPrefix("main-hang start") }
        let ends = captured.filter { $0.hasPrefix("main-hang end") }
        XCTAssertEqual(starts.count, 1, "lines=\(captured)")
        XCTAssertEqual(ends.count, 1, "lines=\(captured)")
        XCTAssertTrue(starts.first?.contains("marker=test.hang.marker") == true, "lines=\(captured)")
        XCTAssertTrue(ends.first?.contains("marker=test.hang.marker") == true, "lines=\(captured)")
        XCTAssertTrue(ends.first?.contains(" ms=") == true)
    }

    func testMetricDiagnosticsKeepNewestTwentyFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("metrics-\(UUID().uuidString)", isDirectory: true)
        let recorder = MetricDiagnosticsRecorder(directory: directory)
        for index in 0..<25 {
            let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            recorder.record(Data("payload-\(index)".utf8), at: date)
        }
        recorder.waitForIdle()

        let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                                includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(MetricDiagnosticsRecorder.filePrefix) }
        XCTAssertEqual(files.count, MetricDiagnosticsRecorder.maxFiles)
        let payloads = try files.compactMap { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertTrue(payloads.contains("payload-24"))
        XCTAssertFalse(payloads.contains("payload-0"))
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Timeline tail reuse

final class NativeTimelineTailUpdateTests: XCTestCase {
    func testStreamingDeltaReusesEveryRowExceptTheTail() {
        var items: [ChatItem] = []
        for index in 0..<299 {
            let kind: ChatItem.Kind = index % 3 == 0 ? .user : (index % 3 == 1 ? .assistant : .reasoning)
            var item = ChatItem(id: "row-\(index)", kind: kind, title: "row",
                                text: "content \(index)")
            item.turn = index / 2
            items.append(item)
        }
        var streaming = ChatItem(id: "tail", kind: .assistant, title: "Assistant",
                                 text: "hello", streaming: true)
        streaming.turn = 150
        items.append(streaming)

        let cache = NativeTimelineCache(changesCache: NativeChangesCache())
        let first = cache.snapshot(items: items, itemsRevision: 1, foldedTurns: [],
                                   endReasons: [:], startTimes: [:], endTimes: [:])
        XCTAssertEqual(cache.fullRebuildCount, 1)
        XCTAssertEqual(cache.tailUpdateCount, 0)

        var changed = items
        changed[changed.count - 1].text += " world"
        changed[changed.count - 1].bumpRenderRevision()
        let second = cache.snapshot(items: changed, itemsRevision: 2, foldedTurns: [],
                                    endReasons: [:], startTimes: [:], endTimes: [:])

        XCTAssertEqual(cache.tailUpdateCount, 1)
        XCTAssertEqual(cache.fullRebuildCount, 1)
        XCTAssertEqual(cache.rebuildCount, 2)
        XCTAssertEqual(Array(second.rows.dropLast()), Array(first.rows.dropLast()))
        XCTAssertEqual(second.visibleItems.last?.text, "hello world")
        XCTAssertEqual(second.scrollSignature,
                       second.visibleItems.map(\.id).joined(separator: ",") + "|hello world")
        XCTAssertEqual(second.turnFacts, first.turnFacts)
    }

    func testMiddleChangeStillFallsBackToFullGrouping() {
        var items: [ChatItem] = []
        for index in 0..<20 {
            var item = ChatItem(id: "row-\(index)", kind: .assistant, title: "row",
                                text: "content \(index)")
            item.turn = index
            items.append(item)
        }
        let cache = NativeTimelineCache(changesCache: NativeChangesCache())
        _ = cache.snapshot(items: items, itemsRevision: 1, foldedTurns: [],
                           endReasons: [:], startTimes: [:], endTimes: [:])
        items[0].text = "changed"
        items[0].bumpRenderRevision()
        _ = cache.snapshot(items: items, itemsRevision: 2, foldedTurns: [],
                           endReasons: [:], startTimes: [:], endTimes: [:])
        XCTAssertEqual(cache.fullRebuildCount, 2)
        XCTAssertEqual(cache.tailUpdateCount, 0)
    }
}

// MARK: - Background transcript gate

final class ChatTranscriptBackgroundGateTests: XCTestCase {
    /// Mirrors `ChatModel.items`: any mutation bumps the revision the timeline
    /// cache keys on, so a status row is never free.
    private final class TranscriptBox {
        var items: [ChatItem] = [] {
            didSet { itemsRevision &+= 1 }
        }
        private(set) var itemsRevision = 0
    }

    /// Mirrors `ChatModel.appendStatus`: the gate decides, the observed array
    /// is only written when it returns a row.
    private func appendStatus(_ text: String, gate: inout ChatTranscriptGate,
                              to box: TranscriptBox) {
        if let row = gate.statusRow(text) { box.items.append(row) }
    }

    func testStatusRowWhileInactiveDoesNotChangeItemsRevision() {
        let box = TranscriptBox()
        box.items = [ChatItem(id: "answer", kind: .assistant, title: "DSH", text: "完成")]
        let revision = box.itemsRevision
        var gate = ChatTranscriptGate(isForeground: false)

        XCTAssertFalse(gate.admitsStatusRow)
        XCTAssertNil(gate.statusRow("Booting the host (Worker bundle + image)…"))
        appendStatus("Booting the host (Worker bundle + image)…", gate: &gate, to: box)
        XCTAssertEqual(box.itemsRevision, revision,
                       "a status line appended while hidden must not invalidate the page")
        XCTAssertEqual(box.items.count, 1)

        gate.isForeground = true
        XCTAssertTrue(gate.admitsStatusRow)
        appendStatus("Session resumed", gate: &gate, to: box)
        XCTAssertEqual(box.itemsRevision, revision + 1)
        XCTAssertEqual(box.items.count, 2)
        XCTAssertEqual(box.items.last?.kind, .status)
        XCTAssertEqual(box.items.last?.title, "Host")
        XCTAssertEqual(box.items.last?.text, "Session resumed")
    }

    func testHistoryAdoptionIsParkedWhileInactive() {
        var gate = ChatTranscriptGate(isForeground: false)
        XCTAssertFalse(gate.takeAdoptionSlot())
        XCTAssertEqual(gate.deferredAdoptions, 1)
        XCTAssertFalse(gate.takeAdoptionSlot())
        XCTAssertEqual(gate.deferredAdoptions, 2)

        gate.isForeground = true
        XCTAssertTrue(gate.takeAdoptionSlot())
        XCTAssertEqual(gate.deferredAdoptions, 2, "the commit is not a deferral")
    }
}

// MARK: - Bounded render window

final class NativeTranscriptRenderWindowTests: XCTestCase {
    func testSixHundredRowTranscriptRendersOnlyTheTailWindow() {
        let limit = NativeTranscriptRenderWindow.initialRows
        let range = NativeTranscriptRenderWindow.tailRange(rowCount: 600, limit: limit)
        XCTAssertEqual(range.count, limit)
        XCTAssertEqual(range.upperBound, 600)
        XCTAssertEqual(range.lowerBound, 600 - limit)
        XCTAssertLessThan(range.count, 600 / 4, "600 rows must not reach one body pass")
    }

    func testShortTranscriptRendersEverything() {
        for count in [0, 1, NativeTranscriptRenderWindow.initialRows - 1,
                      NativeTranscriptRenderWindow.initialRows,
                      NativeTranscriptRenderWindow.initialRows + 1] {
            let range = NativeTranscriptRenderWindow.tailRange(
                rowCount: count, limit: NativeTranscriptRenderWindow.initialRows)
            XCTAssertEqual(range.lowerBound, max(0, count - NativeTranscriptRenderWindow.initialRows))
            XCTAssertEqual(range.upperBound, count)
        }
    }

    func testLoadEarlierGrowsTheWindowOnePageAtATimeAndReachesTheStart() {
        let rowCount = 600
        var limit = NativeTranscriptRenderWindow.initialRows
        var steps = 0
        while NativeTranscriptRenderWindow.tailRange(rowCount: rowCount, limit: limit).lowerBound > 0 {
            let next = NativeTranscriptRenderWindow.grownLimit(limit, rowCount: rowCount)
            XCTAssertGreaterThan(next, limit, "each sentinel pass must add rows")
            XCTAssertLessThanOrEqual(next - limit, NativeTranscriptRenderWindow.pageRows)
            limit = next
            steps += 1
            XCTAssertLessThan(steps, 20, "paging must reach the start")
        }
        XCTAssertEqual(NativeTranscriptRenderWindow.tailRange(rowCount: rowCount, limit: limit).count,
                       rowCount)
    }

    func testHostPageShowsThePrependedRowsOnceEveryLoadedRowIsRendered() {
        // The reader reached row 0 of 600 loaded rows, so the window covers
        // them all; a host page prepends 60 and the window must include it.
        let limit = NativeTranscriptRenderWindow.growing(600, by: 60, rowCount: 660)
        XCTAssertEqual(limit, 660)
        XCTAssertEqual(NativeTranscriptRenderWindow.tailRange(rowCount: 660, limit: limit).lowerBound, 0)
    }
}

// MARK: - Per-turn facts from the snapshot

final class NativeTimelineTurnFactsTests: XCTestCase {
    private func makeItem(id: String, kind: ChatItem.Kind, turn: Int?,
                          text: String = "") -> ChatItem {
        var item = ChatItem(id: id, kind: kind, title: "row", text: text)
        item.turn = turn
        item.timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        return item
    }

    private func usage(input: Int, output: Int) -> NativeTurnUsage {
        var usage = NativeTurnUsage()
        usage.uncachedInputTokens = input
        usage.outputTokens = output
        usage.totalTokens = input + output
        return usage
    }

    private func factFixture() -> [ChatItem] {
        var items: [ChatItem] = []
        items.append(makeItem(id: "u1", kind: .user, turn: nil, text: "第一问"))
        items.append(makeItem(id: "r1", kind: .reasoning, turn: 1, text: "思考"))
        var tool = makeItem(id: "t1", kind: .toolCall, turn: 1)
        tool.toolName = "read"
        tool.toolState = .ok
        items.append(tool)
        var answer = makeItem(id: "a1", kind: .assistant, turn: 1, text: "第一答")
        answer.messageID = "m1"
        answer.turnUsage = usage(input: 10, output: 5)
        items.append(answer)

        items.append(makeItem(id: "u2", kind: .user, turn: nil, text: "第二问"))
        var firstHalf = makeItem(id: "a2a", kind: .assistant, turn: 2, text: "第二答上")
        firstHalf.messageID = "m2"
        firstHalf.turnUsage = usage(input: 20, output: 6)
        items.append(firstHalf)
        var secondHalf = makeItem(id: "a2b", kind: .assistant, turn: 2, text: "第二答下")
        secondHalf.messageID = "m2"
        secondHalf.turnUsage = usage(input: 20, output: 6)
        items.append(secondHalf)

        items.append(makeItem(id: "u3", kind: .user, turn: nil, text: "第三问"))
        items.append(makeItem(id: "r3", kind: .reasoning, turn: 3, text: "再想"))
        var orphanUsage = makeItem(id: "x3", kind: .toolResult(isError: false), turn: 3, text: "ok")
        orphanUsage.turnUsage = usage(input: 1, output: 1)
        items.append(orphanUsage)
        items.append(makeItem(id: "a3", kind: .assistant, turn: 3, text: "第三答"))

        items.append(makeItem(id: "u4", kind: .user, turn: nil, text: "第四问"))
        items.append(makeItem(id: "a4", kind: .assistant, turn: 4, text: "第四答"))
        return items
    }

    /// The pre-change `ChatPage.turnHasProcess`, kept as the oracle.
    private func originalHasProcess(_ turn: Int, in items: [ChatItem]) -> Bool {
        guard let answerID = items.last(where: {
            $0.turn == turn && $0.kind == .assistant
        })?.id else { return false }
        return items.contains { item in
            item.turn == turn && item.id != answerID
                && item.kind != .user && item.kind != .context
        }
    }

    func testCopyTextUsageAndProcessComeFromTheSnapshotAndMatchTheOldBody() {
        let items = factFixture()
        let visible = items.filter { $0.kind != .status }
        let cache = NativeTimelineCache(changesCache: NativeChangesCache())
        let snapshot = cache.snapshot(items: items, itemsRevision: 1, foldedTurns: [],
                                      endReasons: [1: "completed", 2: "completed",
                                                   3: "completed", 4: "completed"],
                                      startTimes: [:], endTimes: [:])

        for turn in 1...4 {
            let facts = snapshot.turnFacts[turn]
            XCTAssertNotNil(facts, "turn \(turn) must carry snapshot facts")
            let expectedAnswer = visible.last { $0.turn == turn && $0.kind == .assistant }
            XCTAssertEqual(facts?.closingAssistantID, expectedAnswer?.id)
            XCTAssertEqual(facts?.closingMessageID, expectedAnswer?.messageID)
            XCTAssertEqual(facts?.closingTimestamp, expectedAnswer?.timestamp)
            XCTAssertEqual(facts?.hasProcess, originalHasProcess(turn, in: visible),
                           "turn \(turn) foldability must match the old scan")
            XCTAssertEqual(facts?.copyText,
                           visible.filter { $0.turn == turn && $0.kind == .assistant }
                               .map(\.text).joined(separator: "\n\n"))
            XCTAssertEqual(facts?.usage,
                           NativeTranscriptProjector.usage(forTurn: turn, in: visible),
                           "turn \(turn) usage must match the projector")
        }

        XCTAssertEqual(snapshot.turnFacts[1]?.copyText, "第一答")
        XCTAssertEqual(snapshot.turnFacts[2]?.copyText, "第二答上\n\n第二答下")
        // Two rows share one message id: the projector counts it once.
        XCTAssertEqual(snapshot.turnFacts[2]?.usage, usage(input: 20, output: 6))
        XCTAssertTrue(snapshot.turnFacts[1]?.hasProcess ?? false)
        XCTAssertTrue(snapshot.turnFacts[2]?.hasProcess ?? false,
                      "a second assistant row is process the old scan counted")
        XCTAssertFalse(snapshot.turnFacts[4]?.hasProcess ?? true)
        XCTAssertNil(snapshot.turnFacts[4]?.usage)
    }

    func testFoldedTurnStillCarriesTheWholeCopyText() {
        var items = factFixture()
        // A tool call belonging to the folded section must not reach copy.
        var hiddenTool = makeItem(id: "hidden-tool", kind: .toolCall, turn: 1, text: "")
        hiddenTool.toolName = "bash"
        hiddenTool.toolState = .ok
        items.insert(hiddenTool, at: 2)
        let cache = NativeTimelineCache(changesCache: NativeChangesCache())
        let snapshot = cache.snapshot(items: items, itemsRevision: 1, foldedTurns: [1],
                                      endReasons: [1: "completed"], startTimes: [:], endTimes: [:])
        XCTAssertEqual(snapshot.turnFacts[1]?.copyText, "第一答")
        XCTAssertTrue(snapshot.turnFacts[1]?.hasProcess ?? false)
        XCTAssertFalse(snapshot.rows.contains {
            if case .tools(let group) = $0 { return group.contains { $0.id == "hidden-tool" } }
            return false
        }, "a folded turn must not render its process rows")
    }

    func testSixHundredRowTranscriptSnapshotStaysBoundedAndCarriesOneFactPerTurn() {
        var items: [ChatItem] = []
        for turn in 0..<200 {
            items.append(makeItem(id: "u\(turn)", kind: .user, turn: nil, text: "q\(turn)"))
            items.append(makeItem(id: "r\(turn)", kind: .reasoning, turn: turn, text: "think"))
            var answer = makeItem(id: "a\(turn)", kind: .assistant, turn: turn, text: "answer \(turn)")
            answer.messageID = "m\(turn)"
            answer.turnUsage = usage(input: turn, output: turn)
            items.append(answer)
        }
        XCTAssertEqual(items.count, 600)
        let cache = NativeTimelineCache(changesCache: NativeChangesCache())
        let endReasons = Dictionary(uniqueKeysWithValues: (0..<200).map { ($0, "completed") })
        let snapshot = cache.snapshot(items: items, itemsRevision: 1, foldedTurns: [],
                                      endReasons: endReasons, startTimes: [:], endTimes: [:])

        let window = NativeTranscriptRenderWindow.tailRange(
            rowCount: snapshot.rows.count, limit: NativeTranscriptRenderWindow.initialRows)
        XCTAssertLessThanOrEqual(window.count, NativeTranscriptRenderWindow.initialRows)

        XCTAssertEqual(snapshot.turnFacts.count, 200)
        XCTAssertEqual(snapshot.turnFacts[7]?.copyText, "answer 7")
        XCTAssertEqual(snapshot.turnFacts[7]?.usage, usage(input: 7, output: 7))
        XCTAssertEqual(snapshot.turnFacts[199]?.closingAssistantID, "a199")
    }
}
