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
        let writer = StatusLogWriter(url: url)
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
