// SPDX-License-Identifier: MIT
import Foundation
import PhoneDSHAgentCore
import ProbeKit
import XCTest

@MainActor
final class ChatEventPumpTests: XCTestCase {
    func testBufferedReplayLetsMainQueueRunWithoutDroppingEvents() async {
        var received: [UInt64] = []
        var countAtHeartbeat: Int?
        var current = true
        await ChatEventPump.run(after: nil, isCurrent: { current }, events: { _ in
            AsyncThrowingStream { continuation in
                for seq in 1...1_000 { continuation.yield(self.event(UInt64(seq))) }
                continuation.finish()
            }
        }, synchronize: { XCTFail("replay should not reconnect"); return nil }, handle: { event in
            received.append(event.seq!)
            if received.count == 1 {
                DispatchQueue.main.async { countAtHeartbeat = received.count }
            }
            if received.count == 1_000 { current = false }
        }, interrupted: { _ in XCTFail("unexpected interruption") }, recovered: {})
        XCTAssertEqual(received, (1...1_000).map(UInt64.init))
        XCTAssertNotNil(countAtHeartbeat)
        XCTAssertLessThan(countAtHeartbeat ?? 1_000, 1_000,
                          "an already buffered replay must yield to main-queue input")
    }

    private enum Failure: Error { case disconnected, snapshotUnavailable }

    private func event(_ seq: UInt64) -> HarnessEvent {
        HarnessEvent(seq: seq, time: Date(), kind: .sessionStatus("ready"))
    }

    func testInterruptionSynchronizesMissedTerminalStateBeforeReopeningAtSnapshotCursor() async {
        var current = true
        var running = true
        var cursors: [UInt64?] = []
        var received: [UInt64] = []
        var actions: [String] = []
        await ChatEventPump.run(after: 8, retryDelay: .milliseconds(1), isCurrent: { current }, events: { after in
            cursors.append(after)
            return AsyncThrowingStream { continuation in
                if cursors.count == 1 {
                    continuation.yield(self.event(9))
                    continuation.finish(throwing: Failure.disconnected)
                } else {
                    XCTAssertFalse(running, "the missed turn/end is reconciled before subscribing")
                    continuation.yield(self.event(20)) // replayed snapshot tail
                    continuation.yield(self.event(21))
                    continuation.finish()
                }
            }
        }, synchronize: {
            actions.append("snapshot")
            running = false
            return 20
        }, handle: { event in
            received.append(event.seq!)
            if event.seq == 21 { current = false }
        }, interrupted: { _ in actions.append("interrupted") }, recovered: { actions.append("recovered") })
        XCTAssertEqual(cursors, [8, 20])
        XCTAssertEqual(received, [9, 21], "snapshot events must not be applied twice")
        XCTAssertEqual(actions, ["interrupted", "snapshot", "recovered"])
        XCTAssertFalse(running)
    }

    func testSnapshotFailureKeepsRecoveryPendingWithoutOpeningAnUnsynchronizedStream() async {
        var current = true
        var opens = 0
        var snapshots = 0
        var recoveries = 0
        var interruptions = 0
        await ChatEventPump.run(after: 1, retryDelay: .milliseconds(1), isCurrent: { current }, events: { after in
            opens += 1
            return AsyncThrowingStream { continuation in
                if opens == 1 { continuation.finish(throwing: Failure.disconnected) }
                else {
                    XCTAssertEqual(after, 30)
                    continuation.yield(self.event(31))
                    continuation.finish()
                }
            }
        }, synchronize: {
            snapshots += 1
            if snapshots == 1 { throw Failure.snapshotUnavailable }
            return 30
        }, handle: { _ in current = false }, interrupted: { _ in interruptions += 1 }, recovered: { recoveries += 1 })
        XCTAssertEqual(opens, 2)
        XCTAssertEqual(snapshots, 2)
        XCTAssertEqual(recoveries, 1)
        XCTAssertEqual(interruptions, 2)
    }

    func testCleanEOFAlsoSynchronizesAndKeepsAnActuallyRunningTurnRunning() async {
        var current = true
        var running = true
        var opens = 0
        var synchronized = false
        await ChatEventPump.run(after: nil, retryDelay: .milliseconds(1), isCurrent: { current }, events: { _ in
            opens += 1
            return AsyncThrowingStream { continuation in
                if opens == 2 { continuation.yield(self.event(2)) }
                continuation.finish()
            }
        }, synchronize: {
            synchronized = true
            running = true
            return 1
        }, handle: { _ in current = false }, interrupted: { _ in }, recovered: { XCTAssertTrue(running) })
        XCTAssertTrue(synchronized)
        XCTAssertEqual(opens, 2)
    }

    func testSessionSwitchDuringSnapshotDoesNotRecoverOrReopenThePreviousSession() async {
        var current = true
        var opens = 0
        var recoveries = 0
        await ChatEventPump.run(after: nil, retryDelay: .milliseconds(1), isCurrent: { current }, events: { _ in
            opens += 1
            return AsyncThrowingStream { $0.finish(throwing: Failure.disconnected) }
        }, synchronize: {
            current = false
            return 100
        }, handle: { _ in XCTFail("stale event") }, interrupted: { _ in }, recovered: { recoveries += 1 })
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(recoveries, 0)
    }

    func testCancellationDuringBackoffStopsWithoutSynchronizingOrReopening() async {
        let interrupted = expectation(description: "interrupted")
        var opens = 0
        var snapshots = 0
        let task = Task {
            await ChatEventPump.run(after: nil, retryDelay: .seconds(5), isCurrent: { true }, events: { _ in
                opens += 1
                return AsyncThrowingStream { $0.finish(throwing: Failure.disconnected) }
            }, synchronize: { snapshots += 1; return nil }, handle: { _ in },
               interrupted: { _ in interrupted.fulfill() }, recovered: {})
        }
        await fulfillment(of: [interrupted], timeout: 2)
        task.cancel()
        await task.value
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(snapshots, 0)
    }
}
