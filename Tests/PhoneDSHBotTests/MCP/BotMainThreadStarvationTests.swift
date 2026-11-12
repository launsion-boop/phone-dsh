// SPDX-License-Identifier: MIT
//
// sim-fix-rt F2: a Bot `tools/call` must not need the main actor.
//
// The production composition is `@MainActor`. It used to answer both the
// per-caller catalog check (`roster()`) and the readiness probe from the main
// actor, so a blocked UI thread held Task/AwaitTask/ask_user until the Worker's
// 130 s deadline. The fixed composition publishes readiness through a
// nonisolated snapshot and keeps `roster()` off the main actor; this test
// exercises the same two seams with a deliberately blocked main thread.

import Foundation
import XCTest
@testable import PhoneDSHBot

private final class MainBlockStarted: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    func mark() { lock.lock(); started = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return started }
}

final class BotMainThreadStarvationTests: XCTestCase {
    func testNonUIToolReturnsWhileTheMainActorIsBlocked() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(
            botId: "main", sessionId: "gb-main", kind: .chat)
        await beginUserTurn(fixture.runtime)

        // The fixed composition: roster is an actor read, readiness is a lock
        // snapshot, and neither hops onto the main actor.
        await fixture.runtime.registerTeamTools(BotTeamTools(host: FakeBotTeamHost()))
        let readiness = BotRuntimeReadinessState(ready: true)
        await fixture.runtime.setRuntimeReadinessProbe { timeout in
            await BotRuntimeReadiness.wait(
                timeoutMilliseconds: timeout, pollMilliseconds: 10, state: readiness)
        }

        let started = MainBlockStarted()
        let blocker = Task.detached {
            await MainActor.run {
                started.mark()
                Thread.sleep(forTimeInterval: 1.5)
            }
        }
        defer { blocker.cancel() }
        for _ in 0..<200 where !started.value {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(started.value, "the main-actor block did not start")

        let clock = Date()
        let result = try await registerAndExecute(
            fixture.runtime, name: "ListRoutines")
        let elapsed = Date().timeIntervalSince(clock)
        XCTAssertNil(result.isError, "a non-UI tool must still run while the UI is blocked")
        XCTAssertLessThan(elapsed, 0.8,
                          "the tool path waited for the blocked main actor")
        await blocker.value
    }

    /// The snapshot wait itself must observe its deadline while the main actor
    /// is blocked. This is the primitive the composition probe uses.
    func testReadinessSnapshotWaitIsBoundedWhileMainActorIsBlocked() async throws {
        let readiness = BotRuntimeReadinessState(ready: false)
        let started = MainBlockStarted()
        let blocker = Task.detached {
            await MainActor.run {
                started.mark()
                Thread.sleep(forTimeInterval: 0.8)
            }
        }
        defer { blocker.cancel() }
        for _ in 0..<200 where !started.value {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        let clock = Date()
        let ready = await BotRuntimeReadiness.wait(
            timeoutMilliseconds: 100, pollMilliseconds: 10, state: readiness)
        let elapsed = Date().timeIntervalSince(clock)
        XCTAssertFalse(ready)
        XCTAssertLessThan(elapsed, 0.4,
                          "the readiness deadline must not wait for the main actor")
        await blocker.value
    }
}
