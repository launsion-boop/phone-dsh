// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// The connector incremental scan is pure orchestration: first scan only
/// establishes the cursor, later scans produce exactly one metadata-only
/// `connector-update` interval, and a cursor never advances before the durable
/// item exists. The cursor vectors themselves live in
/// `ConnectorCursorGoldenTests`.
final class ConnectorDeltaScannerTests: XCTestCase {
    func testFirstScanOnlyEstablishesTheCursorAndEmitsNothing() async throws {
        let store = MemoryConnectorCursorStore()
        let sink = RecordingConnectorSink()
        let client = ScriptedConnectorClient(
            connector: .gmail,
            results: [.success(.init(head: .gmail(historyId: "1000")))])
        let scanner = ConnectorDeltaScanner(clients: [client], cursors: store,
                                            sink: sink, now: { 1_000 })

        let results = await scanner.scan()

        XCTAssertEqual(results, [ConnectorScanResult(connector: .gmail,
                                                     outcome: .baselineEstablished)])
        let cursor = await store.cursor(for: .gmail)
        XCTAssertEqual(cursor?.cursor, .gmail(historyId: "1000"))
        XCTAssertEqual(cursor?.status, .established)
        XCTAssertNil(cursor?.lastError)
        let empty = await sink.records.isEmpty
        XCTAssertTrue(empty)
        let requestedCount = await client.requestedCursors.count
        XCTAssertEqual(requestedCount, 1)
        let requestedFirst = await client.requestedCursors.first ?? nil
        XCTAssertNil(requestedFirst)
    }

    func testSecondScanProducesOneMetadataOnlyRecordKeyedByTheCursorInterval() async throws {
        let store = MemoryConnectorCursorStore()
        await store.seed(.gmail, cursor: .gmail(historyId: "100"))
        let sink = RecordingConnectorSink()
        let page = ConnectorDeltaPage(head: .gmail(historyId: "200"), items: [
            .init(id: "m1", at: 10, from: "QA <qa@example.com>", subject: "One"),
            .init(id: "m2", at: 20, from: "Ops <ops@example.com>", subject: "Two"),
        ])
        let client = ScriptedConnectorClient(connector: .gmail, results: [.success(page)])
        let scanner = ConnectorDeltaScanner(clients: [client], cursors: store,
                                            sink: sink, now: { 1_000 })

        let results = await scanner.scan()

        XCTAssertEqual(results, [ConnectorScanResult(connector: .gmail,
                                                     outcome: .enqueued(count: 2))])
        let records = await sink.records
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.connector, .gmail)
        XCTAssertEqual(record.cursorFrom, "100")
        XCTAssertEqual(record.cursorTo, "200")
        XCTAssertEqual(record.requestID, "gmail:100:200")
        XCTAssertEqual(record.itemID, "connector-update:gmail:100:200")
        XCTAssertEqual(record.items.map(\.id), ["m1", "m2"])
        XCTAssertEqual(record.items.first?.from, "QA <qa@example.com>")
        XCTAssertEqual(record.items.first?.subject, "One")
        XCTAssertEqual(record.count, 2)
        let cursor = await store.cursor(for: .gmail)
        XCTAssertEqual(cursor?.cursor, .gmail(historyId: "200"))
        XCTAssertNil(cursor?.lastError)
    }

    func testGitHubSinceAdvanceEmitsAndLastModifiedAloneDoesNot() async throws {
        let store = MemoryConnectorCursorStore()
        await store.seed(.github, cursor: .github(
            since: "2026-11-19T00:00:00Z",
            lastModified: "Thu, 19 Nov 2026 00:00:00 GMT"))
        let sink = RecordingConnectorSink()
        let client = ScriptedConnectorClient(connector: .github, results: [
            .success(.init(
                head: .github(since: "2026-11-20T00:00:00Z",
                              lastModified: "Fri, 20 Nov 2026 00:00:00 GMT"),
                items: [.init(id: "n1", at: 10, repo: "octo/repo", title: "CI failed")])),
            .success(.init(
                head: .github(since: "2026-11-20T00:00:00Z",
                              lastModified: "Fri, 20 Nov 2026 06:00:00 GMT"))),
        ])
        let scanner = ConnectorDeltaScanner(clients: [client], cursors: store,
                                            sink: sink, now: { 1_000 })

        await WP6AssertEqual(await scanner.scan(),
                             [ConnectorScanResult(connector: .github,
                                                  outcome: .enqueued(count: 1))])
        let recorded = await sink.records
        let record = try XCTUnwrap(recorded.first)
        XCTAssertEqual(record.cursorFrom, "2026-11-19T00:00:00Z")
        XCTAssertEqual(record.cursorTo, "2026-11-20T00:00:00Z")
        XCTAssertEqual(record.items.first?.repo, "octo/repo")

        // The second scan advances only lastModified: the record updates but no
        // connectorUpdate is emitted.
        await WP6AssertEqual(await scanner.scan(),
                             [ConnectorScanResult(connector: .github,
                                                  outcome: .noNewItems(cursorAdvanced: false))])
        let recordCount = await sink.records.count
        XCTAssertEqual(recordCount, 1)
        let cursor = await store.cursor(for: .github)
        XCTAssertEqual(cursor?.cursor, .github(
            since: "2026-11-20T00:00:00Z",
            lastModified: "Fri, 20 Nov 2026 06:00:00 GMT"))
    }

    func testEmptyDeltaAdvancesTheCursorWithNoItem() async throws {
        let store = MemoryConnectorCursorStore()
        await store.seed(.github, cursor: .github(
            since: "2026-11-20T00:00:00Z",
            lastModified: "Thu, 20 Nov 2026 00:00:00 GMT"))
        let sink = RecordingConnectorSink()
        let client = ScriptedConnectorClient(
            connector: .github,
            results: [.success(.init(
                head: .github(since: "2026-11-20T01:00:00Z",
                              lastModified: "Thu, 20 Nov 2026 01:00:00 GMT")))])
        let scanner = ConnectorDeltaScanner(clients: [client], cursors: store,
                                            sink: sink, now: { 1_000 })

        let results = await scanner.scan()

        XCTAssertEqual(results, [ConnectorScanResult(connector: .github,
                                                     outcome: .noNewItems(cursorAdvanced: true))])
        let empty = await sink.records.isEmpty
        XCTAssertTrue(empty)
        let cursor = await store.cursor(for: .github)
        XCTAssertEqual(cursor?.cursor, .github(
            since: "2026-11-20T01:00:00Z",
            lastModified: "Thu, 20 Nov 2026 01:00:00 GMT"))
    }

    func testAnUnchangedCursorReportsNoAdvance() async throws {
        let store = MemoryConnectorCursorStore()
        await store.seed(.gmail, cursor: .gmail(historyId: "100"))
        let sink = RecordingConnectorSink()
        let client = ScriptedConnectorClient(
            connector: .gmail,
            results: [.success(.init(head: .gmail(historyId: "100")))])
        let scanner = ConnectorDeltaScanner(clients: [client], cursors: store,
                                            sink: sink, now: { 1_000 })

        await WP6AssertEqual(await scanner.scan(),
                       [ConnectorScanResult(connector: .gmail,
                                            outcome: .noNewItems(cursorAdvanced: false))])
        let empty = await sink.records.isEmpty
        XCTAssertTrue(empty)
        let cursor = await store.cursor(for: .gmail)
        XCTAssertEqual(cursor?.status, .established)
        XCTAssertNil(cursor?.lastError)
    }

    func testADuplicateIntervalStillAdvancesTheCursor() async throws {
        let store = MemoryConnectorCursorStore()
        await store.seed(.gmail, cursor: .gmail(historyId: "100"))
        let sink = RecordingConnectorSink()
        await sink.markDuplicate("gmail:100:200")
        let client = ScriptedConnectorClient(
            connector: .gmail,
            results: [.success(.init(head: .gmail(historyId: "200"),
                                     items: [.init(id: "m1", at: 1)]))])
        let scanner = ConnectorDeltaScanner(clients: [client], cursors: store,
                                            sink: sink, now: { 1_000 })

        await WP6AssertEqual(await scanner.scan(),
                       [ConnectorScanResult(connector: .gmail, outcome: .duplicate(count: 1))])
        let cursor = await store.cursor(for: .gmail)
        XCTAssertEqual(cursor?.cursor, .gmail(historyId: "200"))
    }

    func testUnauthorizedIsSkippedAndKeepsTheCursor() async throws {
        let store = MemoryConnectorCursorStore()
        await store.seed(.gmail, cursor: .gmail(historyId: "100"))
        let sink = RecordingConnectorSink()
        let client = ScriptedConnectorClient(
            connector: .gmail,
            results: [.failure(ConnectorClientFailure.unauthorized)])
        let scanner = ConnectorDeltaScanner(clients: [client], cursors: store,
                                            sink: sink, now: { 1_000 })

        await WP6AssertEqual(await scanner.scan(),
                       [ConnectorScanResult(connector: .gmail,
                                            outcome: .skipped(reason: "unauthorized"))])
        let cursor = await store.cursor(for: .gmail)
        XCTAssertEqual(cursor?.cursor, .gmail(historyId: "100"))
        let empty = await sink.records.isEmpty
        XCTAssertTrue(empty)
    }

    func testAnInvalidCursorResetsToTheHeadAndEmitsNothing() async throws {
        let store = MemoryConnectorCursorStore()
        await store.seed(.gmail, cursor: .gmail(historyId: "100"))
        let sink = RecordingConnectorSink()
        let client = ScriptedConnectorClient(
            connector: .gmail,
            results: [.failure(ConnectorClientFailure.cursorInvalid(
                head: .gmail(historyId: "900")))])
        let scanner = ConnectorDeltaScanner(clients: [client], cursors: store,
                                            sink: sink, now: { 1_000 })

        await WP6AssertEqual(await scanner.scan(),
                       [ConnectorScanResult(connector: .gmail,
                                            outcome: .reset(reason: "cursor-invalid"))])
        let cursor = await store.cursor(for: .gmail)
        XCTAssertEqual(cursor?.cursor, .gmail(historyId: "900"))
        XCTAssertEqual(cursor?.status, .reset)
        XCTAssertEqual(cursor?.lastError, .cursorInvalid)
        let empty = await sink.records.isEmpty
        XCTAssertTrue(empty)
    }

    func testACorruptStoredRecordResetsSilentlyAndEmitsNothing() async throws {
        let store = MemoryConnectorCursorStore()
        await store.markCorrupt(.gmail)
        let sink = RecordingConnectorSink()
        let client = ScriptedConnectorClient(
            connector: .gmail,
            results: [.success(.init(head: .gmail(historyId: "900")))])
        let scanner = ConnectorDeltaScanner(clients: [client], cursors: store,
                                            sink: sink, now: { 1_000 })

        await WP6AssertEqual(await scanner.scan(),
                       [ConnectorScanResult(connector: .gmail,
                                            outcome: .reset(reason: "cursor-invalid"))])
        let empty = await sink.records.isEmpty
        XCTAssertTrue(empty)
        let corruptRequestCursor = await client.requestedCursors.first ?? nil
        XCTAssertNil(corruptRequestCursor,
                       "a corrupt cursor must not be used as a request cursor")
        let cursor = await store.cursor(for: .gmail)
        XCTAssertEqual(cursor?.cursor, .gmail(historyId: "900"))
        XCTAssertEqual(cursor?.status, .reset)
        XCTAssertEqual(cursor?.lastError, .cursorInvalid)
    }

    func testAGmailCursorRegressionResetsSilently() async throws {
        let store = MemoryConnectorCursorStore()
        await store.seed(.gmail, cursor: .gmail(historyId: "200"))
        let sink = RecordingConnectorSink()
        let client = ScriptedConnectorClient(
            connector: .gmail,
            results: [.success(.init(head: .gmail(historyId: "150"),
                                     items: [.init(id: "m1", at: 1)]))])
        let scanner = ConnectorDeltaScanner(clients: [client], cursors: store,
                                            sink: sink, now: { 1_000 })

        await WP6AssertEqual(await scanner.scan(),
                       [ConnectorScanResult(connector: .gmail,
                                            outcome: .reset(reason: "cursor-regressed"))])
        let cursor = await store.cursor(for: .gmail)
        XCTAssertEqual(cursor?.cursor, .gmail(historyId: "150"))
        XCTAssertEqual(cursor?.status, .reset)
        XCTAssertEqual(cursor?.lastError, .cursorRegressed)
        let empty = await sink.records.isEmpty
        XCTAssertTrue(empty)
    }

    func testMoreThanTwentyItemsAreCappedAndDuplicateIdsCollapse() async throws {
        let store = MemoryConnectorCursorStore()
        await store.seed(.github, cursor: .github(
            since: "2026-11-19T00:00:00Z", lastModified: nil))
        let sink = RecordingConnectorSink()
        var items: [ConnectorMetadataItem] = (0..<25).map {
            .init(id: "n\($0)", at: Int64($0), repo: "octo/repo", title: "Item \($0)")
        }
        items.append(.init(id: "n3", at: 99, repo: "octo/repo", title: "duplicate"))
        let client = ScriptedConnectorClient(
            connector: .github,
            results: [.success(.init(head: .github(
                since: "2026-11-20T00:00:00Z", lastModified: nil), items: items))])
        let scanner = ConnectorDeltaScanner(clients: [client], cursors: store,
                                            sink: sink, now: { 1_000 })

        await WP6AssertEqual(await scanner.scan(),
                       [ConnectorScanResult(connector: .github, outcome: .enqueued(count: 20))])
        let records = await sink.records
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.items.count, 20)
        XCTAssertEqual(Set(record.items.map(\.id)).count, 20)
        XCTAssertEqual(record.items.first?.repo, "octo/repo")
        XCTAssertEqual(record.items.first?.title, "Item 0")
    }

    func testOneConnectorFailureDoesNotBlockAnother() async throws {
        let store = MemoryConnectorCursorStore()
        let sink = RecordingConnectorSink()
        let gmail = ScriptedConnectorClient(
            connector: .gmail,
            results: [.failure(ConnectorClientFailure.unavailable)])
        let github = ScriptedConnectorClient(
            connector: .github,
            results: [.success(.init(head: .github(
                since: "2026-11-20T00:00:00Z", lastModified: nil)))])
        let scanner = ConnectorDeltaScanner(clients: [gmail, github], cursors: store,
                                            sink: sink, now: { 1_000 })

        let results = await scanner.scan()

        XCTAssertEqual(results, [
            ConnectorScanResult(connector: .gmail, outcome: .failed(reason: "unavailable")),
            ConnectorScanResult(connector: .github, outcome: .baselineEstablished),
        ])
        let cursor = await store.cursor(for: .github)
        XCTAssertEqual(cursor?.cursor, .github(
            since: "2026-11-20T00:00:00Z", lastModified: nil))
    }

    func testAnEnqueueFailureKeepsTheCursorAndRecordsTheScanFailure() async throws {
        struct SinkDown: Error {}
        let store = MemoryConnectorCursorStore()
        await store.seed(.gmail, cursor: .gmail(historyId: "100"))
        let sink = RecordingConnectorSink()
        await sink.failNextEnqueue(with: SinkDown())
        let client = ScriptedConnectorClient(
            connector: .gmail,
            results: [.success(.init(head: .gmail(historyId: "200"),
                                     items: [.init(id: "m1", at: 1)]))])
        let scanner = ConnectorDeltaScanner(clients: [client], cursors: store,
                                            sink: sink, now: { 1_000 })

        await WP6AssertEqual(await scanner.scan(),
                       [ConnectorScanResult(connector: .gmail, outcome: .failed(reason: "enqueue"))])
        let cursor = await store.cursor(for: .gmail)
        XCTAssertEqual(cursor?.cursor, .gmail(historyId: "100"),
                       "the cursor may only advance after the durable item")
        XCTAssertEqual(cursor?.lastError, .scanFailed)
    }
}

    func testAnUnreadableCursorIsSkippedAsGateAndLeavesEverythingUntouched() async throws {
        let store = MemoryConnectorCursorStore()
        await store.seed(.gmail, cursor: .gmail(historyId: "100"))
        await store.markUnreadable(.gmail)
        let sink = RecordingConnectorSink()
        let client = ScriptedConnectorClient(
            connector: .gmail,
            results: [.success(.init(head: .gmail(historyId: "200"),
                                     items: [.init(id: "m1", at: 1)]))])
        let scanner = ConnectorDeltaScanner(clients: [client], cursors: store,
                                            sink: sink, now: { 1_000 })

        await WP6AssertEqual(await scanner.scan(),
                             [ConnectorScanResult(connector: .gmail,
                                                  outcome: .skipped(reason: "gate"))])
        let empty = await sink.records.isEmpty
        XCTAssertTrue(empty)
        let cursor = await store.cursor(for: .gmail)
        XCTAssertEqual(cursor?.cursor, .gmail(historyId: "100"),
                       "an unreadable cursor must not be overwritten")
        let requestedCount = await client.requestedCursors.count
        XCTAssertEqual(requestedCount, 0,
                       "no fetch may run against a cursor that cannot be read")
    }

// MARK: - Fakes

actor MemoryConnectorCursorStore: ConnectorCursorStoring {
    private var cursors: [ConnectorKind: ConnectorCursorState] = [:]
    private var corrupt = Set<ConnectorKind>()
    private var unreadable = Set<ConnectorKind>()

    func load(_ connector: ConnectorKind) async throws -> ConnectorCursorLoad {
        if unreadable.contains(connector) {
            throw ConnectorCursorStoreError.unavailable
        }
        if corrupt.contains(connector) { return .corrupt }
        if let state = cursors[connector] { return .stored(state) }
        return .absent
    }

    func save(_ state: ConnectorCursorState) async throws {
        corrupt.remove(state.connector)
        cursors[state.connector] = state
    }

    func clear(_ connector: ConnectorKind) async throws {
        cursors.removeValue(forKey: connector)
        corrupt.remove(connector)
    }

    func seed(_ connector: ConnectorKind, cursor: ConnectorCursorValue,
              status: ConnectorCursorState.Status = .established) {
        cursors[connector] = ConnectorCursorState(
            connector: connector, cursor: cursor, updatedAt: 1, status: status)
    }

    func markCorrupt(_ connector: ConnectorKind) { corrupt.insert(connector) }
    func markUnreadable(_ connector: ConnectorKind) { unreadable.insert(connector) }
    func cursor(for connector: ConnectorKind) -> ConnectorCursorState? { cursors[connector] }
}

actor RecordingConnectorSink: ConnectorUpdateEnqueuing {
    private(set) var records: [ConnectorUpdateRecord] = []
    private var duplicates = Set<String>()
    private var nextFailure: Error?
    private var seenRequestIDs = Set<String>()

    func markDuplicate(_ requestID: String) { duplicates.insert(requestID) }
    func failNextEnqueue(with error: Error) { nextFailure = error }

    func enqueue(_ update: ConnectorUpdateRecord) async throws -> Bool {
        if let failure = nextFailure {
            nextFailure = nil
            throw failure
        }
        guard seenRequestIDs.insert(update.requestID).inserted,
              !duplicates.contains(update.requestID) else { return false }
        records.append(update)
        return true
    }
}

actor ScriptedConnectorClient: ConnectorDeltaClient {
    nonisolated let connector: ConnectorKind
    private var results: [Result<ConnectorDeltaPage, Error>]
    private(set) var requestedCursors: [ConnectorCursorState?] = []

    init(connector: ConnectorKind, results: [Result<ConnectorDeltaPage, Error>]) {
        self.connector = connector
        self.results = results
    }

    func fetchDelta(cursor: ConnectorCursorState?) async throws -> ConnectorDeltaPage {
        requestedCursors.append(cursor)
        guard !results.isEmpty else { throw ConnectorClientFailure.unavailable }
        let next = results.removeFirst()
        return try next.get()
    }
}
