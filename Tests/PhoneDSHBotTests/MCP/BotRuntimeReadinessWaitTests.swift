// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

private actor ReadinessFlag {
    private var ready = false
    private var terminal = false

    func setReady() { ready = true }
    func setTerminal() { terminal = true }
    func isReady() -> Bool { ready }
    func isTerminal() -> Bool { terminal }
}

/// The composition's readiness wait must be bounded above by its budget and
/// must stop early on a terminal state; otherwise a recovering runtime would
/// still hold the Worker client for its 130 s deadline.
final class BotRuntimeReadinessWaitTests: XCTestCase {
    func testWaitReturnsWhenTheRuntimeBecomesReady() async {
        let flag = ReadinessFlag()
        Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            await flag.setReady()
        }
        let ready = await BotRuntimeReadiness.wait(
            timeoutMilliseconds: 2_000, pollMilliseconds: 20,
            isReady: { await flag.isReady() },
            isTerminal: { await flag.isTerminal() })
        XCTAssertTrue(ready)
    }

    func testWaitGivesUpAtTheBudget() async {
        let started = Date()
        let ready = await BotRuntimeReadiness.wait(
            timeoutMilliseconds: 150, pollMilliseconds: 20,
            isReady: { false }, isTerminal: { false })
        XCTAssertFalse(ready)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }

    func testWaitStopsImmediatelyOnATerminalState() async {
        let flag = ReadinessFlag()
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            await flag.setTerminal()
        }
        let started = Date()
        let ready = await BotRuntimeReadiness.wait(
            timeoutMilliseconds: 5_000, pollMilliseconds: 20,
            isReady: { await flag.isReady() },
            isTerminal: { await flag.isTerminal() })
        XCTAssertFalse(ready)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }
}
