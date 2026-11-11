// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

private actor RoutineCancelGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var waiting = 0
    private(set) var reasons: [String] = []

    func wait() async {
        waiting += 1
        await withCheckedContinuation { continuation = $0 }
    }

    func open(reason: String) {
        reasons.append(reason)
        let next = continuation
        continuation = nil
        next?.resume()
    }
}

final class RoutineCancelTests: XCTestCase {
    func testManualCancellationUsesTheUserCancelChain() async throws {
        let root = try wp6TempDirectory(self)
        let now = wp6Date(2026, 5, 12, 12)
        let clock = WP6Clock(now)
        let machine = try wp6Machine(root: root)
        let inbox = try wp6Inbox(root: root)
        let sink = WP6RoutineSink()
        _ = try await machine.create(
            botId: "bot-a", title: "Long run", prompt: "wait",
            schedule: .interval(everyMinutes: 5, timezone: "UTC"),
            now: now - 600_000, id: "long")
        let gate = RoutineCancelGate()
        let scheduler = RoutineScheduler(
            botId: "bot-a", machine: machine, inbox: inbox, sink: sink,
            runner: { _ in
                await gate.wait()
                return RoutineExecutionResult(status: .cancelled)
            },
            cancelRunner: { cancellation in
                await gate.open(reason: cancellation.reason)
                return RoutineCancellationResult(cancelled: true)
            },
            available: { _ in true }, settings: { wp6Settings() }, now: { clock.now })
        let tick = Task { try await scheduler.tick() }
        for _ in 0..<200 {
            if await gate.waiting > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let waiting = await gate.waiting
        XCTAssertEqual(waiting, 1)

        let cancelled = await scheduler.cancelRunning(routineId: "long")
        XCTAssertTrue(cancelled.cancelled)
        let reasons = await gate.reasons
        XCTAssertEqual(reasons, ["user"])
        try await tick.value
        let routine = try await machine.get(botId: "bot-a", routineId: "long")
        XCTAssertEqual(routine?.runState?.status, .cancelled)
        XCTAssertEqual(routine?.lastResult?.status, .cancelled)
        let delivery = try await machine.delivery("long:1", botId: "bot-a")
        XCTAssertEqual(delivery?.cancelOrigin, "user")

        let missing = await scheduler.cancelRunning(routineId: "missing")
        XCTAssertFalse(missing.cancelled)
    }
}
