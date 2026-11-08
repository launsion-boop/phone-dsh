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

    private func policy(budget: Int = 12, quota: Int = 10, cooldown: Int64 = 0,
                        fuse: Int = 4) -> ProactivePolicyConfiguration {
        ProactivePolicyConfiguration(dailyBudget: budget,
                                     quotas: [.taskDone: quota, .routineResult: quota,
                                              .idleCheckin: quota, .reminder: quota],
                                     cooldownsMs: [.taskDone: cooldown, .routineResult: cooldown,
                                                   .idleCheckin: cooldown, .reminder: cooldown],
                                     fuseMaxWakeups: fuse)
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

    func testDndQuietTTLQuotaCooldownAndGlobalBudgetRules() async {
        let dndEngine = ProactiveEngine(settings: { wp6Settings(dnd: true) }, now: { self.now },
                                        policy: policy(), deliverer: WP6NotificationDeliverer())
        await WP6AssertEqual(await dndEngine.consider(candidate("dnd")).reason, "dnd")

        let quietAt = wp6Date(2026, 5, 12, 23, 30)
        let quietEngine = ProactiveEngine(
            settings: { wp6Settings(quietStart: "23:00", quietEnd: "08:00") },
            now: { quietAt }, policy: policy(), deliverer: WP6NotificationDeliverer())
        await WP6AssertEqual(await quietEngine.consider(candidate("quiet", createdAt: quietAt)).reason, "quiet-hours")

        let ttlEngine = ProactiveEngine(settings: { wp6Settings() }, now: { self.now }, policy: policy())
        await WP6AssertEqual(await ttlEngine.consider(candidate("old", createdAt: now - 86_400_001)).reason,
                       "ttl-expired")

        let quotaEngine = ProactiveEngine(settings: { wp6Settings(mode: .would) }, now: { self.now },
                                          policy: policy(quota: 1))
        _ = await quotaEngine.consider(candidate("quota-1"))
        await WP6AssertEqual(await quotaEngine.consider(candidate("quota-2")).reason, "quota")

        let cooldownEngine = ProactiveEngine(settings: { wp6Settings(mode: .would) }, now: { self.now },
                                             policy: policy(cooldown: 1_000))
        _ = await cooldownEngine.consider(candidate("cooldown-1"))
        await WP6AssertEqual(await cooldownEngine.consider(candidate("cooldown-2")).reason, "cooldown")

        let budgetEngine = ProactiveEngine(settings: { wp6Settings(mode: .would) }, now: { self.now },
                                           policy: policy(budget: 1))
        _ = await budgetEngine.consider(candidate("budget-1"))
        await WP6AssertEqual(await budgetEngine.consider(candidate("budget-2")).reason, "global-budget")
    }

    func testWouldModeSpendsAccountingAndRestartRebuildsAllCounters() async {
        let log = WP6EventLog()
        let engine = ProactiveEngine(settings: { wp6Settings(mode: .would) }, now: { self.now },
                                     policy: policy(budget: 2, fuse: 10), eventLog: log)
        _ = await engine.consider(candidate("seen-1"))
        _ = await engine.consider(candidate("seen-2"))
        await WP6AssertEqual(await engine.budgetSpent(), 2)
        await WP6AssertEqual(await engine.consider(candidate("seen-1")).reason, "duplicate")
        await WP6AssertEqual(await engine.consider(candidate("new-over-budget")).reason, "global-budget")

        let restoredLog = WP6EventLog(events: [
            wp6Consideration(at: now - 120_000, commitSeq: 1, dedupeKey: "seen-1"),
            wp6Consideration(at: now - 60_000, commitSeq: 2, dedupeKey: "seen-2"),
        ])
        let restored = ProactiveEngine(settings: { wp6Settings(mode: .would) }, now: { self.now },
                                       policy: policy(budget: 2, fuse: 10), eventLog: restoredLog)
        await WP6AssertEqual(await restored.restoreAccounting(), 2)
        await WP6AssertEqual(await restored.budgetSpent(), 2)
        await WP6AssertEqual(await restored.consider(candidate("seen-1")).reason, "duplicate")
        await WP6AssertEqual(await restored.consider(candidate("new-over-budget")).reason, "global-budget")

        let fusedLog = WP6EventLog(events: [
            wp6Consideration(at: now - 120_000, commitSeq: 1, dedupeKey: "seen-1"),
            wp6Consideration(at: now - 60_000, commitSeq: 2, dedupeKey: "seen-2"),
        ])
        let fused = ProactiveEngine(settings: { wp6Settings(mode: .would) }, now: { self.now },
                                    policy: policy(budget: 50, fuse: 2), eventLog: fusedLog)
        _ = await fused.restoreAccounting()
        await WP6AssertEqual(await fused.consider(candidate("fuse-1")).reason, "fuse")
    }

    func testOnModeDeliveryFailureDoesNotSpendBudgetAndOffModeNeverDelivers() async {
        let deliverer = WP6NotificationDeliverer()
        deliverer.result = ProactiveDeliveryResult(delivered: false, error: "denied")
        let engine = ProactiveEngine(settings: { wp6Settings() }, now: { self.now },
                                     policy: policy(budget: 1), deliverer: deliverer)
        let failed = await engine.consider(candidate("failed"))
        XCTAssertEqual(failed.reason, "delivery-failed")
        await WP6AssertEqual(await engine.budgetSpent(), 0)
        XCTAssertEqual(deliverer.notifications.count, 1)

        let offDeliverer = WP6NotificationDeliverer()
        let off = ProactiveEngine(settings: { wp6Settings(mode: .off) }, now: { self.now },
                                  deliverer: offDeliverer)
        await WP6AssertEqual(await off.consider(candidate("off")).reason, "mode-off")
        XCTAssertEqual(offDeliverer.notifications.count, 0)
    }
}
