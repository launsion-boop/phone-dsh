// SPDX-License-Identifier: MIT
// Real-time watch health: the row service's read failures must surface as a
// persistent `.degraded` verdict until the next successful rebuild, because
// the page's supervised loops (`BotChatModel.watchHealthProvider`) keep the
//「实时更新中断，正在重连」line armed across the poll that threw.
//
// The incremental read/projection machinery itself (shared rebuild, idle cache
// expiry, append-only reads, read-failure retention) is owned by
// `fix/streaming-performance-20261114` on main and covered by its own tests
// (`IncrementalSessionProjectionTests` in the SwiftPM suite and
// `BotProjectionReadCacheTests` in the hosted device suite). This file keeps
// only the realtime lane's own delta: `BotProductionWatchHealth`.

import Foundation
import PhoneDSHBot
import XCTest

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
}

/// Drives the real `BotProductionRowService` (the main-branch incremental
/// read caches) and pins the realtime lane's health verdict on top of it.
final class BotProductionRowWatchHealthTests: XCTestCase {
    private var root: URL!
    private var logURL: URL!
    private var domain: SQLiteDomainStore!
    private var rows: BotProductionRowService!

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
        return BotProductionRowService(environment: environment)
    }

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

    /// A successful poll reports `.healthy`; a read failure throws AND keeps a
    /// `.degraded` verdict (the thrown error is one-shot, the verdict is what
    /// the page polls); the next successful rebuild clears it.
    func testReadFailureMarksTheFeedDegradedAndRecoveryClearsIt() async throws {
        try writeLog([BotWatchFixture.header,
                      BotWatchFixture.line(BotWatchFixture.event(seq: 2, text: "第一条"))])
        rows = try await makeService()
        try await rows.start()

        let initial = try await rows.watch(after: 0)
        XCTAssertTrue(initial.rows.contains { rowText($0) == "第一条" })
        let cursor = initial.cursor
        let healthy = await rows.watchHealth()
        XCTAssertEqual(healthy, .healthy, "a successful rebuild reports healthy")

        // The live log disappears mid-watch: the read fails, the watch throws,
        // and the verdict stays degraded with a stable reason token.
        try FileManager.default.removeItem(at: logURL)
        do {
            _ = try await rows.watch(after: cursor)
            XCTFail("a missing live log must fail the read, not silently clear history")
        } catch {}
        guard case .degraded(let reason, let since) = await rows.watchHealth() else {
            return XCTFail("a failed read must report degraded health")
        }
        XCTAssertEqual(reason, "rebuild")
        XCTAssertGreaterThan(since, 0)

        // The log comes back with an appended line: the next poll recovers,
        // delivers the new row, and the verdict returns to `.healthy`.
        try writeLog([BotWatchFixture.header,
                      BotWatchFixture.line(BotWatchFixture.event(seq: 2, text: "第一条"))])
        try appendLog([BotWatchFixture.line(BotWatchFixture.event(seq: 3, text: "第二条"))])
        let recovered = try await rows.watch(after: cursor)
        XCTAssertTrue(recovered.rows.contains { rowText($0) == "第二条" })
        let recoveredHealth = await rows.watchHealth()
        XCTAssertEqual(recoveredHealth, .healthy, "a successful rebuild clears the verdict")
        try await domain.close()
    }

    /// The verdict is actor state, not a per-poll echo: a caller that only
    /// reads `watchHealth()` (the page's provider) sees the last outcome.
    func testHealthVerdictSurvivesASuccessfulNonRebuildingPoll() async throws {
        try writeLog([BotWatchFixture.header,
                      BotWatchFixture.line(BotWatchFixture.event(seq: 2, text: "第一条"))])
        rows = try await makeService()
        try await rows.start()
        let initial = try await rows.watch(after: 0)
        let unchanged = try await rows.watch(after: initial.cursor)
        XCTAssertTrue(unchanged.rows.isEmpty)
        let verdict = await rows.watchHealth()
        XCTAssertEqual(verdict, .healthy)
        try await domain.close()
    }
}
