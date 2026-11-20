// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// The connector incremental scan is pure orchestration: first scan only
/// establishes the cursor, later scans produce exactly one metadata-only
/// `connector-update` interval, and a cursor never advances before the durable
/// item exists.
final class ConnectorDeltaScannerTests: XCTestCase {
    func testFirstScanOnlyEstablishesTheCursorAndEmitsNothing() async throws {
        let store = MemoryConnectorCursorStore()
        let sink = RecordingConnectorSink()
        let client = ScriptedConnectorClient(connector: .gmail,
                                             results: [.success(.init(cursor: "1000"))])
        let scanner = ConnectorDeltaScanner(clients: [client], cursors: store,
                                            sink: sink, now: { 1_000 })

        let results = await scanner.scan()

        XCTAssertEqual(results, [ConnectorScanResult(connector: .gmail,
                                                     outcome: .baselineEstablished)])
        let cursor = await store.cursor(for: .gmail)
        XCTAssertEqual(cursor?.cursor, "1000")
        XCTAssertEqual(cursor?.status, .established)
        XCTAssertNil(cursor?.lastError)
        let records = await sink.records
        XCTAssertTrue(records.isEmpty)
        let requested = await client.requestedCursors
        XCTAssertEqual(requested.count, 1)
        XCTAssertNil(requested[0])
    }

    func testSecondScanProducesOneMetadataOnlyRecordKeyedByTheCursorInterval() async throws {
        let store = MemoryConnectorCursorStore()
        try await store.save(.init(connector: .gmail, cursor: "100", updatedAt: 1))
        let sink = RecordingConnectorSink()
        let page = ConnectorDeltaPage(cursor: "200", items: [
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
        XCTAssertEqual(cursor?.cursor, "200")
        XCTAssertNil(cursor?.lastError)
    }

    func testEmptyDeltaAdvancesTheCursorWithNoItem() async throws {
        let store = MemoryConnectorCursorStore()
        try await store.save(.init(connector: .github, cursor: "2026-11-20T00:00:00Z", updatedAt: 1))
        let sink = RecordingConnectorSink()
        let client = ScriptedConnectorClient(
            connector: .github,
            results: [.success(.init(cursor: "2026-11-20T01:00:00Z"))])
        let scanner = ConnectorDeltaScanner(clients: [client], cursors: store,
                                            sink: sink, now: { 1_000 })

        let results = await scanner.scan()

        XCTAssertEqual(results, [ConnectorScanResult(connector: .github,
                                                     outcome: .noNewItems(cursorAdvanced: true))])
        await XCTAssertTrueAsync(await sink.records.isEmpty)
        await WP6AssertEqual(await store.cursor(for: .github)?.cursor, "2026-11-20T01:00:00Z")
    }

    func testAnUnchangedCursorReportsNoAdvance() async throws {
        let store = MemoryConnectorCursorStore()
        try await store.save(.init(connector: .github, cursor: "same", updatedAt: 1))
        let sink = RecordingConnectorSink()
        let client = ScriptedConnectorClient(connector: .github,
                                             results: [.success(.init(cursor: "same"))])
        let scanner = ConnectorDeltaScanner(clients: [client], cursors: store,
                                            sink: sink, now: { 1_000 })

        await WP6AssertEqual(await scanner.scan(),
                       [ConnectorScanResult(connector: .github,
                                            outcome: .noNewItems(cursorAdvanced: false))])
        await XCTAssertTrueAsync(await sink.records.isEmpty)
    }

    func testAnUnchangedGmailHeadIsNoNewItemsNotARegression() async throws {
        let store = MemoryConnectorCursorStore()
        try await store.save(.init(connector: .gmail, cursor: "100", updatedAt: 1))
        let sink = RecordingConnectorSink()
        let client = ScriptedConnectorClient(connector: .gmail,
                                             results: [.success(.init(cursor: "100"))])
        let scanner = ConnectorDeltaScanner(clients: [client], cursors: store,
                                            sink: sink, now: { 1_000 })

        await WP6AssertEqual(await scanner.scan(),
                             [ConnectorScanResult(connector: .gmail,
                                                  outcome: .noNewItems(cursorAdvanced: false))])
        let cursor = await store.cursor(for: .gmail)
        XCTAssertEqual(cursor?.cursor, "100")
        XCTAssertEqual(cursor?.status, .established)
        XCTAssertNil(cursor?.lastError)
        await XCTAssertTrueAsync(await sink.records.isEmpty)
    }

    func testADuplicateIntervalStillAdvancesTheCursor() async throws {
        let store = MemoryConnectorCursorStore()
        try await store.save(.init(connector: .gmail, cursor: "100", updatedAt: 1))
        let sink = RecordingConnectorSink()
        await sink.markDuplicate("gmail:100:200")
        let client = ScriptedConnectorClient(
            connector: .gmail,
            results: [.success(.init(cursor: "200", items: [.init(id: "m1", at: 1)]))])
        let scanner = ConnectorDeltaScanner(clients: [client], cursors: store,
                                            sink: sink, now: { 1_000 })

        await WP6AssertEqual(await scanner.scan(),
                       [ConnectorScanResult(connector: .gmail, outcome: .duplicate(count: 1))])
        await WP6AssertEqual(await store.cursor(for: .gmail)?.cursor, "200")
    }

    func testUnauthorizedIsSkippedAndKeepsTheCursor() async throws {
        let store = MemoryConnectorCursorStore()
        try await store.save(.init(connector: .gmail, cursor: "100", updatedAt: 1))
        let sink = RecordingConnectorSink()
        let client = ScriptedConnectorClient(connector: .gmail,
                                             results: [.failure(ConnectorClientFailure.unauthorized)])
        let scanner = ConnectorDeltaScanner(clients: [client], cursors: store,
                                            sink: sink, now: { 1_000 })

        await WP6AssertEqual(await scanner.scan(),
                       [ConnectorScanResult(connector: .gmail,
                                            outcome: .skipped(reason: "unauthorized"))])
        await WP6AssertEqual(await store.cursor(for: .gmail)?.cursor, "100")
        await XCTAssertTrueAsync(await sink.records.isEmpty)
    }

    func testAnInvalidCursorResetsToTheHeadAndEmitsNothing() async throws {
        let store = MemoryConnectorCursorStore()
        try await store.save(.init(connector: .gmail, cursor: "100", updatedAt: 1))
        let sink = RecordingConnectorSink()
        let client = ScriptedConnectorClient(
            connector: .gmail,
            results: [.failure(ConnectorClientFailure.cursorInvalid(head: "900"))])
        let scanner = ConnectorDeltaScanner(clients: [client], cursors: store,
                                            sink: sink, now: { 1_000 })

        await WP6AssertEqual(await scanner.scan(),
                       [ConnectorScanResult(connector: .gmail,
                                            outcome: .reset(reason: "cursor-invalid"))])
        let cursor = await store.cursor(for: .gmail)
        XCTAssertEqual(cursor?.cursor, "900")
        XCTAssertEqual(cursor?.status, .reset)
        XCTAssertEqual(cursor?.lastError, .cursorInvalid)
        await XCTAssertTrueAsync(await sink.records.isEmpty)
    }

    func testAGmailCursorRegressionResetsSilently() async throws {
        let store = MemoryConnectorCursorStore()
        try await store.save(.init(connector: .gmail, cursor: "200", updatedAt: 1))
        let sink = RecordingConnectorSink()
        let client = ScriptedConnectorClient(
            connector: .gmail,
            results: [.success(.init(cursor: "150", items: [.init(id: "m1", at: 1)]))])
        let scanner = ConnectorDeltaScanner(clients: [client], cursors: store,
                                            sink: sink, now: { 1_000 })

        await WP6AssertEqual(await scanner.scan(),
                       [ConnectorScanResult(connector: .gmail,
                                            outcome: .reset(reason: "cursor-regressed"))])
        let cursor = await store.cursor(for: .gmail)
        XCTAssertEqual(cursor?.cursor, "150")
        XCTAssertEqual(cursor?.status, .reset)
        XCTAssertEqual(cursor?.lastError, .cursorRegressed)
        await XCTAssertTrueAsync(await sink.records.isEmpty)
    }

    func testMoreThanTwentyItemsAreCappedAndDuplicateIdsCollapse() async throws {
        let store = MemoryConnectorCursorStore()
        try await store.save(.init(connector: .github, cursor: "old", updatedAt: 1))
        let sink = RecordingConnectorSink()
        var items: [ConnectorMetadataItem] = (0..<25).map {
            .init(id: "n\($0)", at: Int64($0), repo: "octo/repo", title: "Item \($0)")
        }
        items.append(.init(id: "n3", at: 99, repo: "octo/repo", title: "duplicate"))
        let client = ScriptedConnectorClient(
            connector: .github,
            results: [.success(.init(cursor: "new", items: items))])
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
            connector: .github, results: [.success(.init(cursor: "head"))])
        let scanner = ConnectorDeltaScanner(clients: [gmail, github], cursors: store,
                                            sink: sink, now: { 1_000 })

        let results = await scanner.scan()

        XCTAssertEqual(results, [
            ConnectorScanResult(connector: .gmail, outcome: .failed(reason: "unavailable")),
            ConnectorScanResult(connector: .github, outcome: .baselineEstablished),
        ])
        await WP6AssertEqual(await store.cursor(for: .github)?.cursor, "head")
    }

    func testAnEnqueueFailureKeepsTheCursorAndRecordsTheScanFailure() async throws {
        struct SinkDown: Error {}
        let store = MemoryConnectorCursorStore()
        try await store.save(.init(connector: .gmail, cursor: "100", updatedAt: 1))
        let sink = RecordingConnectorSink()
        await sink.failNextEnqueue(with: SinkDown())
        let client = ScriptedConnectorClient(
            connector: .gmail,
            results: [.success(.init(cursor: "200", items: [.init(id: "m1", at: 1)]))])
        let scanner = ConnectorDeltaScanner(clients: [client], cursors: store,
                                            sink: sink, now: { 1_000 })

        await WP6AssertEqual(await scanner.scan(),
                       [ConnectorScanResult(connector: .gmail, outcome: .failed(reason: "enqueue"))])
        let cursor = await store.cursor(for: .gmail)
        XCTAssertEqual(cursor?.cursor, "100", "the cursor may only advance after the durable item")
        XCTAssertEqual(cursor?.lastError, .scanFailed)
    }
}

// MARK: - Fakes

actor MemoryConnectorCursorStore: ConnectorCursorStoring {
    private var cursors: [ConnectorKind: ConnectorCursorState] = [:]

    func cursor(for connector: ConnectorKind) async -> ConnectorCursorState? {
        cursors[connector]
    }

    func save(_ state: ConnectorCursorState) async throws {
        cursors[state.connector] = state
    }

    func clear(_ connector: ConnectorKind) async throws {
        cursors.removeValue(forKey: connector)
    }
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
