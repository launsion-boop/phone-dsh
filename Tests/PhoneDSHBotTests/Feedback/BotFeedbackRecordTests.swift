// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotFeedbackRecordTests: XCTestCase {
    private func makeCenter(
        _ clock: WP6Clock,
        store: InMemoryBotFeedbackStore = InMemoryBotFeedbackStore(),
        eventLog: (any BotEventLog)? = nil
    ) -> BotFeedbackCenter {
        BotFeedbackCenter(store: store, eventLog: eventLog, memory: nil,
                          now: { clock.now })
    }

    private func indexDelivery(_ center: BotFeedbackCenter,
                               _ candidate: ProactiveCandidate,
                               at: Int64) async -> ProactiveDecision {
        let decision = FeedbackFixtures.deliveredDecision(candidate, at: at)
        await center.noteConsidered(decision, candidate: candidate)
        return decision
    }

    func testAdoptionBindsDeliveryAndIsIdempotent() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let store = InMemoryBotFeedbackStore()
        let center = makeCenter(clock, store: store)
        let candidate = FeedbackFixtures.candidate("task-1")
        let decision = await indexDelivery(center, candidate, at: clock.now)

        let first = try await center.record(FeedbackFixtures.adopt(decision, nonce: "ui-1"))
        XCTAssertEqual(first.status, .accepted)
        XCTAssertEqual(first.action, .adopt)
        XCTAssertEqual(first.classKey, "proactive:task-done")
        let firstID = try XCTUnwrap(first.feedbackID)

        let replay = try await center.record(FeedbackFixtures.adopt(decision, nonce: "ui-1"))
        XCTAssertEqual(replay.status, .duplicated)
        XCTAssertEqual(replay.feedbackID, firstID)

        let sameEffect = try await center.record(FeedbackFixtures.adopt(decision, nonce: "ui-2"))
        XCTAssertEqual(sameEffect.status, .duplicated)
        XCTAssertEqual(sameEffect.feedbackID, firstID)

        let index = await store.currentIndex()
        XCTAssertEqual(index?.records.filter { $0.action == .adopt }.count, 1)
        XCTAssertEqual(index?.records.first { $0.action == .adopt }?.scope.key,
                       "proactive:bot-1:task-1")
        XCTAssertEqual(index?.records.first { $0.action == .adopt }?.status, .active)
    }

    func testAdoptionRejectsFabricatedTargetWithoutStateChange() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let store = InMemoryBotFeedbackStore()
        let center = makeCenter(clock, store: store)
        let decision = FeedbackFixtures.deliveredDecision(
            FeedbackFixtures.candidate("ghost"), at: clock.now)
        let outcome = try await center.record(FeedbackFixtures.adopt(decision))
        XCTAssertEqual(outcome.status, .rejected)
        XCTAssertEqual(outcome.code, "target-unresolved")
        let index = await store.currentIndex()
        XCTAssertEqual(index?.records.count ?? 0, 0)
    }

    func testSuppressionScopesDoNotCloseOtherGoals() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let deliverer = WP6NotificationDeliverer()
        let store = InMemoryBotFeedbackStore()
        let center = makeCenter(clock, store: store)
        let engine = ProactiveEngine(
            settings: { wp6Settings() }, now: { clock.now },
            policy: ProactivePolicyConfiguration(fuseMaxWakeups: 50),
            deliverer: deliverer, feedback: center)

        let routineA = FeedbackFixtures.candidate("routine-a", kind: .routineResult,
                                                  routineId: "r-a")
        let routineB = FeedbackFixtures.candidate("routine-b", kind: .routineResult,
                                                  routineId: "r-b")
        let task = FeedbackFixtures.candidate("task-1")
        let decisionA = await engine.consider(routineA)
        let decisionB = await engine.consider(routineB)
        let decisionTask = await engine.consider(task)
        XCTAssertEqual(decisionA.decision, .did)
        XCTAssertEqual(decisionB.decision, .did)
        XCTAssertEqual(decisionTask.decision, .did)

        let suppression = try await center.record(
            FeedbackFixtures.suppress(decisionA, scope: .routine, nonce: "ui-stop-a"))
        XCTAssertEqual(suppression.status, .accepted)
        XCTAssertEqual(suppression.classKey, "routine:r-a")

        clock.advance(60_000)
        let heldA = await engine.consider(
            FeedbackFixtures.candidate("routine-a-2", kind: .routineResult, routineId: "r-a"))
        XCTAssertEqual(heldA.decision, .skip)
        XCTAssertEqual(heldA.reason, "feedback-held")

        let stillB = await engine.consider(
            FeedbackFixtures.candidate("routine-b-2", kind: .routineResult, routineId: "r-b"))
        XCTAssertEqual(stillB.decision, .did)
        let stillTask = await engine.consider(FeedbackFixtures.candidate("task-2"))
        XCTAssertEqual(stillTask.decision, .did)

        let undo = try await center.undo(try XCTUnwrap(suppression.feedbackID))
        XCTAssertEqual(undo.status, .accepted)
        XCTAssertTrue(undo.reversed)
        clock.advance(60_000)
        let restored = await engine.consider(
            FeedbackFixtures.candidate("routine-a-3", kind: .routineResult, routineId: "r-a"))
        XCTAssertEqual(restored.decision, .did)
    }

    func testCrossBotUserPreferenceAppliesToEveryBotAndCanBeRolledBack() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let store = InMemoryBotFeedbackStore()
        let center = makeCenter(clock, store: store)
        let delivererA = WP6NotificationDeliverer()
        let delivererB = WP6NotificationDeliverer()
        let engineA = ProactiveEngine(
            settings: { wp6Settings() }, now: { clock.now },
            policy: ProactivePolicyConfiguration(fuseMaxWakeups: 50),
            deliverer: delivererA, feedback: center)
        let engineB = ProactiveEngine(
            settings: { wp6Settings() }, now: { clock.now },
            policy: ProactivePolicyConfiguration(fuseMaxWakeups: 50),
            deliverer: delivererB, feedback: center)
        let candidateA = FeedbackFixtures.candidate("task-a", botId: "bot-a")
        let decisionA = await engineA.consider(candidateA)
        XCTAssertEqual(decisionA.decision, .did)
        let suppression = try await center.record(
            FeedbackFixtures.suppress(decisionA, scope: .user, nonce: "ui-kind"))
        XCTAssertEqual(suppression.status, .accepted)
        XCTAssertEqual(suppression.classKey, "proactive:task-done")

        clock.advance(60_000)
        let heldB = await engineB.consider(
            FeedbackFixtures.candidate("task-b1", botId: "bot-b"))
        XCTAssertEqual(heldB.reason, "feedback-held")
        let routineB = await engineB.consider(
            FeedbackFixtures.candidate("routine-b", kind: .routineResult,
                                       botId: "bot-b", routineId: "r-b"))
        XCTAssertEqual(routineB.decision, .did)

        let preferences = try await center.preferences(botID: "bot-b", scope: nil)
        XCTAssertEqual(preferences.active.count, 1)
        XCTAssertEqual(preferences.active.first?.scopeKind, .user)

        _ = try await center.undo(try XCTUnwrap(suppression.feedbackID))
        clock.advance(60_000)
        let deliveredB = await engineB.consider(
            FeedbackFixtures.candidate("task-b2", botId: "bot-b"))
        XCTAssertEqual(deliveredB.decision, .did)
    }

    func testUserScopeRejectsBotLocalClass() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let store = InMemoryBotFeedbackStore()
        let center = makeCenter(clock, store: store)
        let deliverer = WP6NotificationDeliverer()
        let engine = ProactiveEngine(
            settings: { wp6Settings() }, now: { clock.now },
            policy: ProactivePolicyConfiguration(fuseMaxWakeups: 50),
            deliverer: deliverer, feedback: center)
        let decision = await engine.consider(
            FeedbackFixtures.candidate("routine-a", kind: .routineResult, routineId: "r-a"))
        let outcome = try await center.record(
            FeedbackFixtures.suppress(decision, scope: .user))
        XCTAssertEqual(outcome.status, .rejected)
        XCTAssertEqual(outcome.code, "scope-not-shareable")
        let active = try await center.preferences(botID: "bot-1", scope: nil).active
        XCTAssertEqual(active.count, 0)
    }

    func testSuppressionRejectsUnresolvedTarget() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let store = InMemoryBotFeedbackStore()
        let center = makeCenter(clock, store: store)
        let decision = FeedbackFixtures.deliveredDecision(
            FeedbackFixtures.candidate("never-delivered"), at: clock.now)
        let outcome = try await center.record(
            FeedbackFixtures.suppress(decision, scope: .artifact))
        XCTAssertEqual(outcome.code, "target-unresolved")
        let active = try await center.preferences(botID: "bot-1", scope: nil).active
        XCTAssertEqual(active.count, 0)
    }

    func testOriginAndNonceValidation() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let store = InMemoryBotFeedbackStore()
        let center = makeCenter(clock, store: store)
        let candidate = FeedbackFixtures.candidate("task-1")
        let decision = await indexDelivery(center, candidate, at: clock.now)

        var noSession = FeedbackFixtures.adopt(decision, nonce: "ui-x")
        noSession.origin = BotFeedbackOrigin(kind: .userChatTurn, sessionID: nil,
                                             nonce: "ui-x")
        let noSessionOutcome = try await center.record(noSession)
        XCTAssertEqual(noSessionOutcome.code, "origin-unverified")

        var emptyNonce = FeedbackFixtures.adopt(decision, nonce: "  ")
        emptyNonce.origin.nonce = "  "
        let emptyNonceOutcome = try await center.record(emptyNonce)
        XCTAssertEqual(emptyNonceOutcome.code, "nonce-required")

        var otherBot = FeedbackFixtures.adopt(decision, nonce: "ui-y")
        otherBot.botID = "bot-2"
        let otherBotOutcome = try await center.record(otherBot)
        XCTAssertEqual(otherBotOutcome.code, "target-unresolved")
    }

    func testAdoptionScopeMustBeArtifact() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let store = InMemoryBotFeedbackStore()
        let center = makeCenter(clock, store: store)
        let decision = await indexDelivery(center,
                                           FeedbackFixtures.candidate("task-1"), at: clock.now)
        var request = FeedbackFixtures.adopt(decision)
        request.scope = .class
        let outcome = try await center.record(request)
        XCTAssertEqual(outcome.code, "scope-invalid")
    }

    func testDuplicateSuppressionKeepsOneActivePreference() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let store = InMemoryBotFeedbackStore()
        let center = makeCenter(clock, store: store)
        let decision = await indexDelivery(center,
                                           FeedbackFixtures.candidate("task-1"), at: clock.now)
        let first = try await center.record(
            FeedbackFixtures.suppress(decision, scope: .artifact, nonce: "ui-1"))
        let second = try await center.record(
            FeedbackFixtures.suppress(decision, scope: .artifact, nonce: "ui-2"))
        XCTAssertEqual(second.status, .duplicated)
        XCTAssertEqual(second.feedbackID, first.feedbackID)
        let active = try await center.preferences(botID: "bot-1", scope: nil).active
        XCTAssertEqual(active.count, 1)
    }
}
