// SPDX-License-Identifier: MIT

import PhoneDSHAgentCore
import XCTest

/// Real-device regression (iPhone19,4, 2026-11-22): six queued sends targeted a session that only
/// existed in a quarantined engine. Each drain painted that session's cached tail
/// (「显示上次对话 · 引擎后台启动中…」), the open failed `session/not-found`, and the drain stopped,
/// so the live session's sends never went out either.
final class OutboxActivationHoldsTests: XCTestCase {
    func testAHeldSessionNeverHoldsAnotherSession() {
        var holds = OutboxActivationHolds()
        holds.beginPass(incarnation: 1)
        holds.hold("lost")
        XCTAssertTrue(holds.isHeld("lost"))
        XCTAssertFalse(holds.isHeld("live"))
    }

    func testAHoldLastsOnePass() {
        var holds = OutboxActivationHolds()
        holds.beginPass(incarnation: 1)
        holds.hold("busy")
        holds.beginPass(incarnation: 1)
        XCTAssertFalse(holds.isHeld("busy"), "a transient failure is retried on the next drain")
    }

    func testAMissingSessionIsNotAskedAgainByTheSameEngine() {
        var holds = OutboxActivationHolds()
        holds.beginPass(incarnation: 3)
        holds.markMissing("lost")
        XCTAssertTrue(holds.isHeld("lost"))
        holds.beginPass(incarnation: 3)
        XCTAssertTrue(holds.isKnownMissing("lost"))
        XCTAssertFalse(holds.isHeld("lost"), "the held set is per pass; activation consults isKnownMissing")
    }

    func testANewEngineAsksOnceMore() {
        var holds = OutboxActivationHolds()
        holds.beginPass(incarnation: 3)
        holds.markMissing("lost")
        holds.beginPass(incarnation: 4)
        XCTAssertFalse(holds.isKnownMissing("lost"))
    }

    func testOnlyTheEngineNotFoundCodeMarksASessionMissing() {
        XCTAssertTrue(ChatSessionBoot.isMissingSession(
            DSHRemoteError(code: "session/not-found", message: "x").providerError))
        for error: Error in [ProviderError.unavailable(retryAfter: nil),
                             DSHRemoteError(code: "gateway/internal", message: "x").providerError,
                             CancellationError()] {
            XCTAssertFalse(ChatSessionBoot.isMissingSession(error), "\(error)")
        }
    }
}
