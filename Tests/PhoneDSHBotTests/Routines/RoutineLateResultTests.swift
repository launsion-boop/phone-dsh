// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class RoutineLateResultTests: XCTestCase {
    func testLateResultCannotOverwriteAttemptWithoutDeliveryLedger() async throws {
        let root = try wp6TempDirectory(self)
        let now = wp6Date(2026, 5, 12, 12)
        let machine = try wp6Machine(root: root)
        _ = try await machine.create(botId: "bot-a", title: "Idempotent", prompt: "work",
                                     schedule: .interval(everyMinutes: 5), idempotent: true,
                                     now: now, id: "late")
        _ = try await machine.begin(botId: "bot-a", routineId: "late", startedAt: now, runId: "run-1")
        _ = try await machine.recover(botId: "bot-a", now: now + 1)
        _ = try await machine.begin(botId: "bot-a", routineId: "late", startedAt: now + 2, runId: "run-2")

        let lateResult = try await machine.finish(botId: "bot-a", routineId: "late",
                                                  status: .succeeded, text: "late result",
                                                  finishedAt: now + 3, attempt: 1, runId: "run-1")
        let late = try XCTUnwrap(lateResult)
        XCTAssertTrue(late.ignored)
        XCTAssertNil(late.delivery)
        let current = try await machine.get(botId: "bot-a", routineId: "late")
        XCTAssertEqual(current?.runState?.attempt, 2)
        XCTAssertEqual(current?.runState?.status, .started)
        XCTAssertEqual(current?.lastResult?.text, "")

        let completed = try await machine.finish(botId: "bot-a", routineId: "late",
                                                 status: .succeeded, text: "current",
                                                 finishedAt: now + 4, attempt: 2, runId: "run-2")
        let currentFinish = try XCTUnwrap(completed)
        XCTAssertFalse(currentFinish.ignored)
        XCTAssertEqual(currentFinish.delivery?.text, "current")
    }
}
