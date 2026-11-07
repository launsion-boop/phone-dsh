// SPDX-License-Identifier: MIT

import XCTest

@MainActor
final class BotChatModelTests: XCTestCase {
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
