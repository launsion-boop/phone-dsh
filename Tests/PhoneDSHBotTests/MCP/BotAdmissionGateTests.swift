// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// F-04: the signal-driven admission gate must resume at most once, tolerate a
/// cancellation before the waiter registers, ignore a late cancellation after
/// resolution, and leave no waiter entry behind.
final class BotAdmissionGateTests: XCTestCase {
    func testCancelBeforeRegistrationResolvesFalseWithoutLeaking() async {
        let gate = BotAdmissionGate()
        let task = Task { await gate.wait() }
        task.cancel()
        let result = await task.value
        XCTAssertFalse(result)
        let count = await gate.waiterCount
        XCTAssertEqual(count, 0)
    }

    func testCancelAfterRegistrationResolvesFalseAndCleansUp() async {
        let gate = BotAdmissionGate()
        let task = Task { await gate.wait() }
        try? await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()
        let result = await task.value
        XCTAssertFalse(result)
        let count = await gate.waiterCount
        XCTAssertEqual(count, 0)
    }

    func testLateCancelAfterOpenIsIgnoredAndDoesNotLeak() async {
        let gate = BotAdmissionGate()
        let task = Task { await gate.wait() }
        try? await Task.sleep(nanoseconds: 10_000_000)
        await gate.open()
        let result = await task.value
        XCTAssertTrue(result)
        task.cancel()
        let count = await gate.waiterCount
        XCTAssertEqual(count, 0)
    }

    func testFailResolvesFalseAndLeavesNoWaiter() async {
        let gate = BotAdmissionGate()
        let task = Task { await gate.wait() }
        try? await Task.sleep(nanoseconds: 10_000_000)
        await gate.fail()
        let result = await task.value
        XCTAssertFalse(result)
        let count = await gate.waiterCount
        XCTAssertEqual(count, 0)
    }
}
