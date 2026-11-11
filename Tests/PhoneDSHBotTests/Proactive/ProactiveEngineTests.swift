// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class ProactiveEngineTests: XCTestCase {
    private let now = wp6Date(2026, 5, 12, 12)

    private func candidate(_ key: String, kind: ProactiveKind = .taskDone,
                           botId: String = "bot-1", createdAt: Int64? = nil) -> ProactiveCandidate {
        ProactiveCandidate(id: key, kind: kind, botId: botId, dedupeKey: key,
                           trigger: "test", createdAt: createdAt ?? now,
                           taskId: key, status: "completed")
    }

    private func policy(fuse: Int = 4) -> ProactivePolicyConfiguration {
        ProactivePolicyConfiguration(fuseMaxWakeups: fuse)
    }

    func testOnlyInterruptRoutineCandidatesCanNotify() async {
        let deliverer = WP6NotificationDeliverer()
        let engine = ProactiveEngine(settings: { wp6Settings() }, now: { self.now }, deliverer: deliverer)
        var held = candidate("held", kind: .routineResult)
        held.delivery = .held
        held.resultExcerpt = "result"
        let heldDecision = await engine.consider(held)
        XCTAssertEqual(heldDecision.reason, "routine-held")

        var quiet = candidate("quiet", kind: .routineResult)
        quiet.delivery = .interrupt
        quiet.quiet = true
        let quietDecision = await engine.consider(quiet)
        XCTAssertEqual(quietDecision.reason, "routine-quiet")

        var interrupt = candidate("interrupt", kind: .routineResult)
        interrupt.delivery = .interrupt
        interrupt.title = "Digest"
        interrupt.resultExcerpt = "First sentence. Second sentence."
        interrupt.rowId = "routine-run-daily-1"
        let accepted = await engine.consider(interrupt)
        XCTAssertEqual(accepted.decision, .did)
        XCTAssertEqual(deliverer.notifications.count, 1)
        XCTAssertEqual(deliverer.notifications[0].body, "First sentence.")
        XCTAssertEqual(deliverer.notifications[0].deepLink,
                       "phonedsh://bot/bot-1/row/routine-run-daily-1")
    }

    func testDndAndQuietHoursRemainHardLimits() async {
        let dndEngine = ProactiveEngine(settings: { wp6Settings(dnd: true) }, now: { self.now },
                                        policy: policy(), deliverer: WP6NotificationDeliverer())
        await WP6AssertEqual(await dndEngine.consider(candidate("dnd")).reason, "dnd")

        let quietAt = wp6Date(2026, 5, 12, 23, 30)
        let quietEngine = ProactiveEngine(
            settings: { wp6Settings(quietStart: "23:00", quietEnd: "08:00") },
            now: { quietAt }, policy: policy(), deliverer: WP6NotificationDeliverer())
        await WP6AssertEqual(await quietEngine.consider(candidate("quiet", createdAt: quietAt)).reason,
                             "quiet-hours")

        let reminderDeliverer = WP6NotificationDeliverer()
        let reminderEngine = ProactiveEngine(settings: { wp6Settings(dnd: true) }, now: { self.now },
                                             policy: policy(), deliverer: reminderDeliverer,
                                             deliveryKinds: [.reminder])
        let reminder = ProactiveCandidate(kind: .reminder, botId: "bot-1",
                                          createdAt: self.now, reminderId: "rem-1",
                                          allowDuringDnd: true)
        let decision = await reminderEngine.consider(reminder)
        XCTAssertEqual(decision.decision, .did)
        XCTAssertEqual(reminderDeliverer.notifications.count, 1)
    }

    func testRepeatedCandidatesAndOldCreatedAtAreNotSuppressed() async {
        let engine = ProactiveEngine(settings: { wp6Settings(mode: .would) }, now: { self.now },
                                     policy: policy(fuse: 10))
        let seen = candidate("seen-1")
        await WP6AssertEqual(await engine.consider(seen).reason, "would-mode")
        await WP6AssertEqual(await engine.consider(seen).reason, "would-mode")
        let old = candidate("old", createdAt: now - 86_400_001)
        await WP6AssertEqual(await engine.consider(old).reason, "would-mode")
    }

    func testWouldModeRecordsFuseAccountingAndRestartRebuildsIt() async {
        let log = WP6EventLog()
        let engine = ProactiveEngine(settings: { wp6Settings(mode: .would) }, now: { self.now },
                                     policy: policy(fuse: 2), eventLog: log)
        await WP6AssertEqual(await engine.consider(candidate("seen-1")).reason, "would-mode")
        await WP6AssertEqual(await engine.consider(candidate("seen-2")).reason, "would-mode")
        await WP6AssertEqual(await engine.consider(candidate("seen-3")).reason, "fuse")

        let restoredLog = WP6EventLog(events: [
            wp6Consideration(at: now - 120_000, commitSeq: 1),
            wp6Consideration(at: now - 60_000, commitSeq: 2),
        ])
        let restored = ProactiveEngine(settings: { wp6Settings(mode: .would) }, now: { self.now },
                                       policy: policy(fuse: 2), eventLog: restoredLog)
        await WP6AssertEqual(await restored.restoreAccounting(), 2)
        await WP6AssertEqual(await restored.consider(candidate("fuse-after-restore")).reason, "fuse")

        let staleLog = WP6EventLog(events: [
            wp6Consideration(at: now - 1_000_000, commitSeq: 1),
        ])
        let stale = ProactiveEngine(settings: { wp6Settings(mode: .would) }, now: { self.now },
                                    policy: policy(fuse: 1), eventLog: staleLog)
        await WP6AssertEqual(await stale.restoreAccounting(), 0)
        await WP6AssertEqual(await stale.consider(candidate("outside-window")).reason, "would-mode")
    }

    func testOnModeDeliveryFailureDoesNotRecordFuseAndOffModeNeverDelivers() async {
        let deliverer = WP6NotificationDeliverer()
        deliverer.result = ProactiveDeliveryResult(delivered: false, error: "denied")
        let engine = ProactiveEngine(settings: { wp6Settings() }, now: { self.now },
                                     policy: policy(fuse: 1), deliverer: deliverer)
        await WP6AssertEqual(await engine.consider(candidate("failed")).reason, "delivery-failed")
        deliverer.result = ProactiveDeliveryResult(delivered: true)
        let delivered = await engine.consider(candidate("delivered"))
        XCTAssertEqual(delivered.decision, .did)
        XCTAssertEqual(deliverer.notifications.count, 2)

        let offDeliverer = WP6NotificationDeliverer()
        let off = ProactiveEngine(settings: { wp6Settings(mode: .off) }, now: { self.now },
                                  deliverer: offDeliverer)
        await WP6AssertEqual(await off.consider(candidate("off")).reason, "mode-off")
        XCTAssertEqual(offDeliverer.notifications.count, 0)
    }
}
