// SPDX-License-Identifier: MIT

import XCTest

@MainActor
final class BotChatModelTests: XCTestCase {
    func testSameTextFromSeparateSendsReconcilesByNonce() {
        let model = BotChatModel(fixtureActions: true)
        model.send(text: "same text")
        model.send(text: "same text")
        let pending = model.rows
        for (index, local) in pending.enumerated() {
            var durable = BotUIRow.text(id: "row-\(index)", seq: index + 1, role: "user", text: "same text")
            durable.chatActionNonce = String(local.id.dropFirst("local-".count))
            model.apply(BotUIRowBatch(rows: [durable], deletes: [], cursor: index + 1, reset: false))
            XCTAssertFalse(model.rows.contains { $0.id == local.id })
            XCTAssertEqual(model.rows.count, 2)
        }
        XCTAssertEqual(model.rows.map(\.id), ["row-0", "row-1"])
    }

    func testHistoryUsesRowAnchorAfterLiveUpdates() async {
        let rows = (0..<52).map { index in
            BotUIRow.text(id: "row-\(index)", seq: index, role: "user", text: "Message \(index)")
        }
        let driver = BotChatDriver(
            history: { anchor, limit in
                XCTAssertEqual(anchor, "row-2")
                XCTAssertEqual(limit, 50)
                return BotUIHistoryPage(rows: Array(rows.prefix(2)), nextCursor: "row-0", hasMore: false)
            },
            watch: { _ in BotUIRowBatch(rows: [], deletes: [], cursor: 0, reset: false) },
            perform: { _ in .rejected(reason: "unused") },
            stopCurrentTurn: { _ in })
        let model = BotChatModel(driver: driver)
        model.apply(BotUIRowBatch(rows: rows, deletes: [], cursor: 99, reset: true))
        XCTAssertEqual(model.rows.count, 50)
        XCTAssertTrue(model.hasMoreHistory)
        model.apply(BotUIRowBatch(rows: [], deletes: [], cursor: 100, reset: false))
        await model.loadHistory()
        XCTAssertEqual(model.rows, rows)
        XCTAssertFalse(model.hasMoreHistory)
        XCTAssertNil(model.runtimeNotice)
    }

    /// Regression for the removed production fallback: without a driver the
    /// model must report a failed action and never fabricate an accepted event.
    func testWithoutDriverFailsClosed() async throws {
        let model = BotChatModel()
        model.send(text: "没有 driver 不应被接受")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(model.actionStates.values.contains {
            if case .failed = $0 { return true }
            return false
        }, "missing driver must produce a failed action state")
        XCTAssertFalse(model.rows.contains { row in
            row.provenance.eventIDs.contains { $0.hasPrefix("evt-action-") }
        }, "missing driver must never fabricate an accepted event")
    }
}
