// SPDX-License-Identifier: MIT
// Real-time regression: the Bot page's 800 ms watch used to re-read the whole
// session JSONL, the whole event journal and re-project everything on every
// poll. These tests drive the real incremental reader and the real
// `BotProductionRowService` against a temporary session log: an append must
// stay append-only, a truncation/rotation must re-parse from scratch, an
// unchanged file must cause zero byte reads, and a transient read failure must
// keep the last good projection and recover to `.healthy`.

import Foundation
import PhoneDSHBot
import XCTest

// MARK: - Test byte source

/// Wraps the production file IO, counts byte reads and can fail them on demand.
final class BotSessionLogTestIO: BotSessionLogReading, @unchecked Sendable {
    enum InjectedFailure: Error {
        case read
    }

    private let lock = NSLock()
    private var readCount = 0
    private var byteCount = 0
    private var stateCount = 0
    private var pendingFailures = 0
    private var fileMissing = false

    var readCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return readCount
    }

    var bytesRead: Int {
        lock.lock(); defer { lock.unlock() }
        return byteCount
    }

    var stateCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return stateCount
    }

    func failNextReads(_ count: Int) {
        lock.lock(); pendingFailures = count; lock.unlock()
    }

    func setFileMissing(_ missing: Bool) {
        lock.lock(); fileMissing = missing; lock.unlock()
    }

    func resetCounters() {
        lock.lock()
        readCount = 0
        byteCount = 0
        stateCount = 0
        lock.unlock()
    }

    func state(at url: URL) throws -> BotSessionLogFileState? {
        lock.lock()
        stateCount += 1
        let missing = fileMissing
        lock.unlock()
        if missing { return nil }
        return try BotSessionLogFileIO.live.state(at: url)
    }

    func read(at url: URL, offset: UInt64, maxBytes: Int) throws -> Data {
        lock.lock()
        readCount += 1
        let fail = pendingFailures > 0
        if fail { pendingFailures -= 1 }
        lock.unlock()
        if fail { throw InjectedFailure.read }
        let data = try BotSessionLogFileIO.live.read(
            at: url, offset: offset, maxBytes: maxBytes)
        lock.lock()
        byteCount += data.count
        lock.unlock()
        return data
    }
}

// MARK: - Fixtures

private enum BotWatchFixture {
    static let header =
        #"{"type":"session","version":4,"id":"main","createdAt":1,"isSeeded":false,"delegationDepth":0}"#

    static func event(seq: Int, text: String = "内容", type: String = "user/message") -> BotDSHSessionEvent {
        BotDSHSessionEvent(
            type: type, seq: seq, time: 1_000 + Int64(seq),
            data: [
                "role": .string("user"),
                "surfaceOp": .string("append"),
                "message": .object([
                    "role": .string("user"),
                    "content": .array([
                        .object(["type": .string("text"), "text": .string(text)]),
                    ]),
                ]),
            ],
            eventID: "session-\(seq)")
    }

    static func line(_ event: BotDSHSessionEvent) -> String {
        (try? JSONEncoder().encode(event)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static func lines(_ events: [BotDSHSessionEvent]) -> [String] {
        events.map(line)
    }
}

private final class BotWatchLineBox: @unchecked Sendable {
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

// MARK: - Incremental session-log tail

final class BotSessionLogTailTests: XCTestCase {
    private var root: URL!
    private var logURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-bot-tail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        logURL = root.appendingPathComponent("session.v4.jsonl")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testIncrementalAppendMatchesColdParse() throws {
        let firstBatch = [
            BotWatchFixture.header,
            BotWatchFixture.line(BotWatchFixture.event(seq: 2, text: "第一条")),
            "this is not json",
            BotWatchFixture.line(BotWatchFixture.event(seq: 3, text: "第二条")),
        ]
        try write(firstBatch, to: logURL)
        let io = BotSessionLogTestIO()
        var tail = BotSessionLogTail(io: io)
        let cold = try tail.refresh(logURL, needRecords: true)
        XCTAssertTrue(cold.reparsed, "a cache miss must parse the file from byte 0")

        io.resetCounters()
        let secondBatch = [
            BotWatchFixture.line(BotWatchFixture.event(seq: 4, text: "第三条")),
            "",
            BotWatchFixture.line(BotWatchFixture.event(seq: 5, text: "第四条")),
            #"{"seq":99,"type":"assistant/message"}"#,
        ]
        let appendedBytes = secondBatch.reduce(0) { $0 + $1.utf8.count + 1 }
        try append(secondBatch, to: logURL)
        let incremental = try tail.refresh(logURL, needRecords: true)
        XCTAssertFalse(incremental.reparsed, "an append must not re-parse the whole file")
        XCTAssertEqual(incremental.newLines, secondBatch.count)
        // The appended bytes plus the one bounded prefix read that proves the
        // path still names the same file (the rotation guard). The prefix read
        // is capped at 1 KiB, so a small transcript reads its head twice.
        let afterBytes = Int(cold.size) + appendedBytes
        let fingerprintBytes = min(afterBytes, BotSessionLogTail.fingerprintBytes)
        XCTAssertEqual(io.bytesRead, fingerprintBytes + appendedBytes,
                       "an append must not read the transcript again")
        XCTAssertEqual(tail.size(of: logURL), incremental.size)

        // The same file through a cold parse and a cold reader must agree with
        // the incremental result: event order and diagnostics included.
        let full = try Data(contentsOf: logURL)
        let reference = BotDSHSessionEvent.parseJSONL(full)
        XCTAssertEqual(incremental.events, reference.events)
        XCTAssertEqual(incremental.diagnostics, reference.diagnostics)

        var coldTail = BotSessionLogTail(io: BotSessionLogTestIO())
        let coldAgain = try coldTail.refresh(logURL, needRecords: true)
        XCTAssertEqual(incremental.events, coldAgain.events)
        XCTAssertEqual(incremental.diagnostics, coldAgain.diagnostics)
        XCTAssertEqual(incremental.records, coldAgain.records)
    }

    func testTruncationAndRotationReparseFromScratch() throws {
        try write([
            BotWatchFixture.header,
            BotWatchFixture.line(BotWatchFixture.event(seq: 2)),
            BotWatchFixture.line(BotWatchFixture.event(seq: 3)),
            BotWatchFixture.line(BotWatchFixture.event(seq: 4)),
            BotWatchFixture.line(BotWatchFixture.event(seq: 5)),
        ], to: logURL)
        let io = BotSessionLogTestIO()
        var tail = BotSessionLogTail(io: io)
        _ = try tail.refresh(logURL, needRecords: true)

        // Shrink: the byte offset is ahead of the new size.
        try write([
            BotWatchFixture.header,
            BotWatchFixture.line(BotWatchFixture.event(seq: 2)),
        ], to: logURL)
        let truncated = try tail.refresh(logURL, needRecords: true)
        XCTAssertTrue(truncated.reparsed)
        XCTAssertEqual(truncated.events.map(\.seq), [2])
        XCTAssertEqual(truncated.events, coldParse(logURL).events)

        // Same-size replacement with a different prefix (fingerprint). The
        // event text keeps the encoded line length identical, so only the
        // prefix fingerprint can catch it.
        try write([
            BotWatchFixture.header,
            BotWatchFixture.line(BotWatchFixture.event(seq: 9, text: "aaa")),
        ], to: logURL)
        _ = try tail.refresh(logURL, needRecords: true)
        try write([
            BotWatchFixture.header,
            BotWatchFixture.line(BotWatchFixture.event(seq: 9, text: "bbb")),
        ], to: logURL)
        let replaced = try tail.refresh(logURL, needRecords: true)
        XCTAssertTrue(replaced.reparsed, "a changed prefix must force a full re-parse")
        XCTAssertEqual(replaced.events, coldParse(logURL).events)

        // Atomic replacement changes the inode as well.
        try Data(("""
        \(BotWatchFixture.header)
        \(BotWatchFixture.line(BotWatchFixture.event(seq: 11, text: "轮换")))
        """ + "\n").utf8).write(to: logURL, options: .atomic)
        let rotated = try tail.refresh(logURL, needRecords: true)
        XCTAssertTrue(rotated.reparsed)
        XCTAssertEqual(rotated.events, coldParse(logURL).events)
    }

    func testUnchangedPollReadsNoBytes() throws {
        try write([
            BotWatchFixture.header,
            BotWatchFixture.line(BotWatchFixture.event(seq: 2)),
            BotWatchFixture.line(BotWatchFixture.event(seq: 3)),
        ], to: logURL)
        let io = BotSessionLogTestIO()
        var tail = BotSessionLogTail(io: io)
        let first = try tail.refresh(logURL, needRecords: true)
        XCTAssertFalse(first.events.isEmpty)

        io.resetCounters()
        let second = try tail.refresh(logURL, needRecords: true)
        XCTAssertEqual(io.readCalls, 0, "an unchanged size+mtime must not open the file")
        XCTAssertEqual(second.newLines, 0)
        XCTAssertFalse(second.reparsed)
        XCTAssertEqual(second.events, first.events)
        XCTAssertEqual(second.records, first.records)
    }

    func testEmptyFileThenFirstWriteStillSkipsTheSessionHeader() throws {
        // The Worker creates the session file before its first line lands. The
        // later append must still treat the first record as the header, or the
        // header would be reported as a skipped record forever.
        try Data().write(to: logURL)
        let io = BotSessionLogTestIO()
        var tail = BotSessionLogTail(io: io)
        let empty = try tail.refresh(logURL, needRecords: true)
        XCTAssertTrue(empty.events.isEmpty)
        XCTAssertEqual(empty.newLines, 0)

        try append([
            BotWatchFixture.header,
            BotWatchFixture.line(BotWatchFixture.event(seq: 2)),
        ], to: logURL)
        let first = try tail.refresh(logURL, needRecords: true)
        XCTAssertFalse(first.reparsed)
        XCTAssertEqual(first.events.map(\.seq), [2])
        XCTAssertEqual(first.diagnostics, .empty)
        XCTAssertEqual(first.events, coldParse(logURL).events)
    }

    func testReadFailureKeepsEventsAndRecovers() throws {
        try write([
            BotWatchFixture.header,
            BotWatchFixture.line(BotWatchFixture.event(seq: 2)),
        ], to: logURL)
        let io = BotSessionLogTestIO()
        var tail = BotSessionLogTail(io: io)
        let first = try tail.refresh(logURL, needRecords: true)

        try append([BotWatchFixture.line(BotWatchFixture.event(seq: 3))], to: logURL)
        io.failNextReads(1)
        XCTAssertThrowsError(try tail.refresh(logURL, needRecords: true))

        let recovered = try tail.refresh(logURL, needRecords: true)
        XCTAssertEqual(recovered.events.map(\.seq), [2, 3])
        XCTAssertEqual(recovered.events.prefix(first.events.count).map(\.seq),
                       first.events.map(\.seq))
        XCTAssertEqual(recovered.events, coldParse(logURL).events)
    }

    // MARK: Helpers

    private func coldParse(_ url: URL) -> BotDSHSessionLogParseResult {
        (try? Data(contentsOf: url)).map(BotDSHSessionEvent.parseJSONL)
            ?? BotDSHSessionLogParseResult(events: [])
    }

    private func write(_ lines: [String], to url: URL) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    private func append(_ lines: [String], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }
}

// MARK: - Row service polling

final class BotProductionRowWatchTests: XCTestCase {
    private var root: URL!
    private var logURL: URL!
    private var domain: SQLiteDomainStore!
    private var rows: BotProductionRowService!
    private var io: BotSessionLogTestIO!

    private func makeService() async throws -> BotProductionRowService {
        domain = try SQLiteDomainStore(
            fileURL: root.appendingPathComponent("domain.sqlite"),
            now: { 5_000 }, startsBackgroundIntegrityCheck: false)
        let environment = BotProductionEnvironment(
            domain: domain, botID: "main", sessionID: "main",
            routineMachine: RoutineMachine(store: SQLiteRoutineStore(domainStore: domain)),
            memory: BotMemory(
                store: SQLiteBotMemoryDocumentStore(
                    eventLog: domain, botID: "main", now: { 5_000 }),
                botID: "main", now: { 5_000 }),
            grants: BotGrantStore(domainStore: domain, now: { 5_000 }),
            sessionLogURL: logURL, workspaceRoot: root)
        io = BotSessionLogTestIO()
        return BotProductionRowService(environment: environment, logIO: io)
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-bot-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        logURL = root.appendingPathComponent("session.v4.jsonl")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        domain = nil
    }

    func testNoOpPollReturnsEmptyBatchAndReadsNothing() async throws {
        try writeLog([BotWatchFixture.header,
                      BotWatchFixture.line(BotWatchFixture.event(seq: 2, text: "第一条"))])
        rows = try await makeService()
        try await rows.start()

        let initial = try await rows.watch(after: 0)
        XCTAssertTrue(initial.reset, "the first poll is the page's reset snapshot")
        let cursor = initial.cursor
        io.resetCounters()

        let started = Date()
        let noop = try await rows.watch(after: cursor)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(noop.rows.isEmpty)
        XCTAssertTrue(noop.deletes.isEmpty)
        XCTAssertFalse(noop.reset, "a no-op poll must not reset the page")
        XCTAssertEqual(noop.cursor, cursor)
        XCTAssertEqual(io.readCalls, 0, "an unchanged log must not be read")
        XCTAssertLessThan(elapsed, 0.5)

        let health = await rows.watchHealth()
        XCTAssertEqual(health, .healthy)
        let poll = await rows.lastWatchPoll()
        XCTAssertEqual(poll?.newLines, 0)
        XCTAssertEqual(poll?.verdict, "ok")
        let line = poll?.logLine ?? ""
        XCTAssertTrue(line.hasPrefix("bot-watch ms="), line)
        XCTAssertTrue(line.hasSuffix("verdict=ok"), line)
        XCTAssertTrue(line.contains("newLines=0"), line)
        XCTAssertTrue(line.contains("sessionBytes=\(poll?.sessionBytes ?? 0)"), line)
        try await domain.close()
    }

    func testTransientReadFailureKeepsProjectionAndRecovers() async throws {
        try writeLog([BotWatchFixture.header,
                      BotWatchFixture.line(BotWatchFixture.event(seq: 2, text: "第一条"))])
        rows = try await makeService()
        try await rows.start()
        let initial = try await rows.watch(after: 0)
        let cursor = initial.cursor
        XCTAssertTrue(initial.rows.contains { rowText($0) == "第一条" })

        io.failNextReads(1)
        try appendLog([BotWatchFixture.line(BotWatchFixture.event(seq: 3, text: "第二条"))])
        let degraded = try await rows.watch(after: cursor)
        XCTAssertFalse(degraded.reset, "a failed read must not reset the transcript")
        XCTAssertTrue(degraded.rows.isEmpty)
        XCTAssertEqual(degraded.cursor, cursor)
        guard case .degraded(let reason, let since) = await rows.watchHealth() else {
            return XCTFail("a failed read must report degraded health")
        }
        XCTAssertEqual(reason, "session-log")
        XCTAssertGreaterThan(since, 0)

        // The short backoff suppresses the expensive read; a poll inside the
        // window is cheap and keeps the caller's cursor.
        io.resetCounters()
        let backedOff = try await rows.watch(after: cursor)
        XCTAssertTrue(backedOff.rows.isEmpty)
        XCTAssertEqual(io.readCalls, 0, "the backoff poll must not touch the file")

        // The next poll after the backoff retries and restores `.healthy`; the
        // previously projected row is still there.
        try await Task.sleep(nanoseconds: 350_000_000)
        let recovered = try await rows.watch(after: cursor)
        XCTAssertTrue(recovered.rows.contains { rowText($0) == "第二条" })
        let recoveredHealth = await rows.watchHealth()
        XCTAssertEqual(recoveredHealth, .healthy)
        let history = try await rows.history(before: nil, limit: 10)
        XCTAssertTrue(history.rows.contains { rowText($0) == "第一条" })
        XCTAssertTrue(history.rows.contains { rowText($0) == "第二条" })
        try await domain.close()
    }

    func testInstrumentationLineGoesToTheDiagnosticChannel() async throws {
        try writeLog([BotWatchFixture.header,
                      BotWatchFixture.line(BotWatchFixture.event(seq: 2, text: "第一条"))])
        let box = BotWatchLineBox()
        await MainActor.run { BotRebindDiagnostics.sink = { box.append($0) } }
        addTeardownBlock {
            await MainActor.run { BotRebindDiagnostics.sink = nil }
        }
        rows = try await makeService()
        try await rows.start()
        _ = try await rows.watch(after: 0)
        let lines = box.snapshot.filter { $0.hasPrefix("bot-watch ") }
        XCTAssertEqual(lines.count, 1, "one line per poll, got \(lines)")
        XCTAssertTrue(lines[0].contains("verdict=ok"))
        try await domain.close()
    }

    // MARK: Helpers

    private func writeLog(_ lines: [String]) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: logURL)
    }

    private func appendLog(_ lines: [String]) throws {
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private func rowText(_ row: BotRow) -> String? {
        row.body["text"]?.stringValue
    }
}
