// SPDX-License-Identifier: MIT

import PhoneDSHAgentCore
import ProbeKit
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

    private func entry(_ session: String, _ state: SendOutboxState) -> SendOutboxEntry {
        SendOutboxEntry(rpcId: "6b1e0f2a-93c4-4d7e-a5b6-0c1d2e3f4a5b", sessionId: session,
                        text: "x", createdAtMs: 1, state: state, attempts: 0)
    }

    /// PC-20261122-outbox-lost-target: only this engine's not-found verdict
    /// for a queued entry is proof for `queued → targetLost`.
    func testOnlyAQueuedEntryOfAKnownMissingSessionIsProvenLost() {
        var holds = OutboxActivationHolds()
        holds.beginPass(incarnation: 5)
        holds.hold("busy")
        XCTAssertFalse(holds.provesTargetLost(entry("busy", .queued)),
                       "a transient activation failure is not proof")
        holds.markMissing("lost")
        XCTAssertTrue(holds.provesTargetLost(entry("lost", .queued)))
        for state in [SendOutboxState.submitting, .accepted, .outcomeUnknown, .targetLost] {
            XCTAssertFalse(holds.provesTargetLost(entry("lost", state)), state.rawValue)
        }
        XCTAssertFalse(holds.provesTargetLost(entry("live", .queued)))
        holds.beginPass(incarnation: 5)
        XCTAssertTrue(holds.provesTargetLost(entry("lost", .queued)), "same engine, same verdict")
        holds.beginPass(incarnation: 6)
        XCTAssertFalse(holds.provesTargetLost(entry("lost", .queued)),
                       "a new engine must answer again before anything is marked")
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
