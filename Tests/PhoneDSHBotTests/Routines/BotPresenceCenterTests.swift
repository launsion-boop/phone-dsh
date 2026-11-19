// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class BotPresenceCenterTests: XCTestCase {
    /// One off-main observation, returned as a single value so the read and
    /// the thread it ran on cannot be separated by the test.
    private struct OffMainRead: Sendable {
        var isMainThread: Bool
        var appActive: Bool
        var keepingAlive: Bool
        var context: BotPresenceCenter.Context
    }

    func testDefaultsAreForegroundAndNotKeepingAlive() {
        let center = BotPresenceCenter()
        XCTAssertTrue(center.appActive)
        XCTAssertFalse(center.keepingAlive)
        XCTAssertEqual(center.context(), .foreground)
        XCTAssertEqual(center.context(),
                       BotPresenceCenter.Context(appActive: true, keepingAlive: false))
    }

    func testUpdateWithoutArgumentsLeavesThePairAlone() {
        let center = BotPresenceCenter()
        center.update(appActive: false, keepingAlive: true)
        center.update()
        XCTAssertFalse(center.appActive)
        XCTAssertTrue(center.keepingAlive)
        XCTAssertEqual(center.context(),
                       BotPresenceCenter.Context(appActive: false, keepingAlive: true))
    }

    func testPartialUpdateChangesOnlyTheGivenFlag() {
        let center = BotPresenceCenter()

        center.update(appActive: false)
        XCTAssertFalse(center.appActive)
        XCTAssertFalse(center.keepingAlive)
        XCTAssertEqual(center.context(),
                       BotPresenceCenter.Context(appActive: false, keepingAlive: false))

        center.update(keepingAlive: true)
        XCTAssertFalse(center.appActive)
        XCTAssertTrue(center.keepingAlive)
        XCTAssertEqual(center.context(),
                       BotPresenceCenter.Context(appActive: false, keepingAlive: true))

        // Explicit false must clear a flag; only the other flag's update lands.
        center.update(appActive: true)
        XCTAssertTrue(center.appActive)
        XCTAssertTrue(center.keepingAlive)

        center.update(keepingAlive: false)
        XCTAssertTrue(center.appActive)
        XCTAssertFalse(center.keepingAlive)
        XCTAssertEqual(center.context(), .foreground)
    }

    func testContextNeverTearsWhileUpdatesCommitPairedFlags() {
        let center = BotPresenceCenter()
        // Every writer commits a pair whose two flags are equal, so any
        // observation with different flags is a pair no update produced. The
        // initial defaults (true, false) would be such a pair, so the baseline
        // starts from a committed equal pair.
        center.update(appActive: false, keepingAlive: false)

        let participants = 8
        let iterations = 20_000
        let tornReads = LockedCounter()

        // Every participant both commits paired updates and reads the pair, so
        // reads and writes overlap for the whole loop instead of depending on
        // one dispatch wave finishing before the next starts.
        DispatchQueue.concurrentPerform(iterations: participants) { slot in
            var value = slot.isMultiple(of: 2)
            for index in 0..<iterations {
                if index.isMultiple(of: 2) {
                    center.update(appActive: value, keepingAlive: value)
                    value.toggle()
                } else {
                    let context = center.context()
                    if context.appActive != context.keepingAlive {
                        tornReads.increment()
                    }
                }
            }
        }

        XCTAssertEqual(tornReads.value, 0,
                       "context() observed a flag pair that no update committed")
    }

    func testOffMainReadsSeeTheCommittedPair() async {
        let center = BotPresenceCenter()
        center.update(appActive: false, keepingAlive: true)

        let read = await Task.detached {
            OffMainRead(
                isMainThread: Thread.isMainThread,
                appActive: center.appActive,
                keepingAlive: center.keepingAlive,
                context: center.context())
        }.value

        XCTAssertFalse(read.isMainThread, "the read must run off the main thread")
        XCTAssertFalse(read.appActive)
        XCTAssertTrue(read.keepingAlive)
        XCTAssertEqual(read.context,
                       BotPresenceCenter.Context(appActive: false, keepingAlive: true))
    }

    func testOffMainWritesAreVisibleToSubsequentReads() async {
        let center = BotPresenceCenter()

        await Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            center.update(appActive: false)
            center.update(keepingAlive: true)
        }.value

        XCTAssertFalse(center.appActive)
        XCTAssertTrue(center.keepingAlive)
        XCTAssertEqual(center.context(),
                       BotPresenceCenter.Context(appActive: false, keepingAlive: true))
    }
}

/// Minimal thread-safe counter for the concurrent-read assertion.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        stored += 1
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
