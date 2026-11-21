// SPDX-License-Identifier: MIT
// Engine-first launch: a Bot send while the unit is not up is durable and
// queued, not a visible failure. The regression this pins is the old path:
// the unavailable planner returned an internal sentence, `perform` rolled the
// optimistic row back and the user saw the message disappear.

import Foundation
import XCTest

@MainActor
final class BotQueuedSendTests: XCTestCase {
    private func context() -> BotRuntimeContext {
        BotRuntimeContext(botID: "main", botName: "大肥鱼")
    }

    private func driver() -> BotChatDriver {
        BotChatDriver(
            history: { _, _ in BotUIHistoryPage(rows: [], nextCursor: nil, hasMore: false) },
            watch: { cursor in BotUIRowBatch(rows: [], deletes: [], cursor: cursor, reset: false) },
            // The engine/Bot unit is not up; the dispatcher already wrote the
            // pending-action row before asking the planner.
            perform: { _ in .rejected(reason: "unavailable") },
            stopCurrentTurn: { _ in },
            turnProcesses: { [:] },
            liveFrames: { AsyncStream { $0.finish() } },
            presentation: { BotRuntimePresentation() })
    }

    private func waitUntil(timeout: TimeInterval = 2,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "condition not met within \(timeout)s")
    }

    func testUnavailableSendStaysQueuedAndKeepsTheEcho() async throws {
        let model = BotChatModel(context: context(), driver: driver())
        model.send(text: "帮我看一下这封邮件")
        try await waitUntil {
            model.actionStates.values.contains(.queued)
        }
        XCTAssertTrue(model.actionStates.values.contains(.queued))
        XCTAssertFalse(model.actionStates.values.contains { state in
            if case .failed = state { return true }
            return false
        })
        XCTAssertNil(model.runtimeNotice, "an internal planner sentence must not reach the user")
        XCTAssertTrue(model.rows.contains { row in
            row.role == "user" && row.body["text"]?.string == "帮我看一下这封邮件"
        }, "the optimistic echo must stay visible while queued")
    }
}