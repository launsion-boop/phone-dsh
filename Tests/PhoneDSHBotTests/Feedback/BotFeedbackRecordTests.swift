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

    func testUserScopeDerivesKindLevelClassNotRoutineId() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let deliverer = WP6NotificationDeliverer()
        let store = InMemoryBotFeedbackStore()
        let center = makeCenter(clock, store: store)
        let engine = ProactiveEngine(
            settings: { wp6Settings() }, now: { clock.now },
            policy: ProactivePolicyConfiguration(fuseMaxWakeups: 50),
            deliverer: deliverer, feedback: center)
        let routineA = await engine.consider(
            FeedbackFixtures.candidate("routine-a", kind: .routineResult, routineId: "r-a"))
        XCTAssertEqual(routineA.decision, .did)
        let outcome = try await center.record(
            FeedbackFixtures.suppress(routineA, scope: .user))
        XCTAssertEqual(outcome.status, .accepted)
        XCTAssertEqual(outcome.classKey, "proactive:routine-result",
                       "user scope is the kind-level class, never routine:<id>")
        let active = try await center.preferences(botID: "bot-1", scope: nil).active
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.classKey, "proactive:routine-result")

        clock.advance(60_000)
        let siblingRoutine = await engine.consider(
            FeedbackFixtures.candidate("routine-b", kind: .routineResult, routineId: "r-b"))
        XCTAssertEqual(siblingRoutine.reason, "feedback-held",
                       "kind-level routine-result preference covers this Bot's routine results")
        let task = await engine.consider(FeedbackFixtures.candidate("task-1"))
        XCTAssertEqual(task.decision, .did, "other kinds are untouched")
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
        XCTAssertEqual(noSessionOutcome.code, "permission-denied")

        var emptyNonce = FeedbackFixtures.adopt(decision, nonce: "  ")
        emptyNonce.origin.nonce = "  "
        let emptyNonceOutcome = try await center.record(emptyNonce)
        XCTAssertEqual(emptyNonceOutcome.code, "insufficient-evidence")

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
        XCTAssertEqual(outcome.code, "target-unresolved")
    }

    // ROOT-REVIEW-POINTS R4: the model's interpretation of the user's words is
    // never trusted. A real user-chat origin proves the source, not the target;
    // a wrong or unknown target must stay unresolved and change nothing.

    func testChatOriginDoesNotRescueAWrongTarget() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let store = InMemoryBotFeedbackStore()
        let center = makeCenter(clock, store: store)
        _ = await indexDelivery(center, FeedbackFixtures.candidate("real"), at: clock.now)

        var wrong = FeedbackFixtures.adopt(
            FeedbackFixtures.deliveredDecision(FeedbackFixtures.candidate("ghost"),
                                               at: clock.now),
            nonce: "chat-wrong")
        wrong.origin = FeedbackFixtures.chatOrigin("chat-wrong")
        let adopted = try await center.record(wrong)
        XCTAssertEqual(adopted.status, .rejected)
        XCTAssertEqual(adopted.code, "target-unresolved")

        var wrongSuppress = FeedbackFixtures.suppress(
            FeedbackFixtures.deliveredDecision(FeedbackFixtures.candidate("ghost-2"),
                                               at: clock.now),
            scope: .class, nonce: "chat-wrong-2")
        wrongSuppress.origin = FeedbackFixtures.chatOrigin("chat-wrong-2")
        let suppressed = try await center.record(wrongSuppress)
        XCTAssertEqual(suppressed.status, .rejected)
        XCTAssertEqual(suppressed.code, "target-unresolved")
        let active = try await center.preferences(botID: "bot-1", scope: nil).active
        XCTAssertEqual(active.count, 0)
    }

    // Q1 P1-3: the production UI maps a message/attachment row to
    // target .delivery with the row id. Adoption of that visible row is a real
    // user action; suppression/correction cannot invent a class or a memory
    // version, so they fail with actionable codes instead of target-unresolved.

    func testUIAdoptsAVisibleMessageRow() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let store = InMemoryBotFeedbackStore()
        let center = makeCenter(clock, store: store)
        let request = BotFeedback(
            botID: "bot-1", action: .adopt,
            target: BotFeedbackArtifactRef(kind: .delivery, id: "row-msg-1"),
            scope: .artifact, origin: FeedbackFixtures.uiOrigin("ui-row-1"))
        let outcome = try await center.record(request)
        XCTAssertEqual(outcome.status, .accepted)
        let currentIndex = await store.currentIndex()
        let index = try XCTUnwrap(currentIndex)
        let adoption = try XCTUnwrap(index.records.first { $0.action == .adopt })
        XCTAssertEqual(adoption.scope.key, "delivery:bot-1:row-msg-1")

        let replay = try await center.record(request)
        XCTAssertEqual(replay.status, .duplicated)
        XCTAssertEqual(replay.feedbackID, outcome.feedbackID)

        var modelRequest = request
        modelRequest.origin = FeedbackFixtures.chatOrigin("chat-row-1")
        modelRequest.origin.nonce = "chat-row-1"
        let modelOutcome = try await center.record(modelRequest)
        XCTAssertEqual(modelOutcome.code, "target-unresolved",
                       "a model turn cannot adopt a fabricated row artifact")
    }

    func testUISuppressOnAMessageRowIsAmbiguous() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let store = InMemoryBotFeedbackStore()
        let center = makeCenter(clock, store: store)
        let request = BotFeedback(
            botID: "bot-1", action: .suppress,
            target: BotFeedbackArtifactRef(kind: .delivery, id: "row-msg-2"),
            scope: .artifact, origin: FeedbackFixtures.uiOrigin("ui-row-2"))
        let outcome = try await center.record(request)
        XCTAssertEqual(outcome.status, .rejected)
        XCTAssertEqual(outcome.code, "ambiguous-scope")
        let active = try await center.preferences(botID: "bot-1", scope: nil).active
        XCTAssertEqual(active.count, 0)

        var modelRequest = request
        modelRequest.origin = FeedbackFixtures.chatOrigin("chat-row-2")
        modelRequest.origin.nonce = "chat-row-2"
        let modelOutcome = try await center.record(modelRequest)
        XCTAssertEqual(modelOutcome.code, "target-unresolved")
    }

    func testUISuppressOnAProactiveRowStillResolves() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let deliverer = WP6NotificationDeliverer()
        let store = InMemoryBotFeedbackStore()
        let center = makeCenter(clock, store: store)
        let engine = ProactiveEngine(
            settings: { wp6Settings() }, now: { clock.now },
            policy: ProactivePolicyConfiguration(fuseMaxWakeups: 50),
            deliverer: deliverer, feedback: center)
        var candidate = FeedbackFixtures.candidate("weekly-1")
        candidate.rowId = "row-proactive-1"
        let delivered = await engine.consider(candidate)
        XCTAssertEqual(delivered.decision, .did)
        let request = BotFeedback(
            botID: "bot-1", action: .suppress,
            target: BotFeedbackArtifactRef(kind: .delivery, id: "row-proactive-1"),
            scope: .artifact, origin: FeedbackFixtures.uiOrigin("ui-row-3"))
        let outcome = try await center.record(request)
        XCTAssertEqual(outcome.status, .accepted)
        clock.advance(60_000)
        let held = await engine.consider(FeedbackFixtures.candidate("weekly-1"))
        XCTAssertEqual(held.reason, "feedback-held")
    }

    // U's new automation-row dialog sends the row id with `.class` (per
    // routine) or `.user` (kind-level across Bots). Both must resolve through
    // the proactive delivery index, not fall back to "no target".
    func testUIUsesRoutineClassScopeFromAutomationRow() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let deliverer = WP6NotificationDeliverer()
        let store = InMemoryBotFeedbackStore()
        let center = makeCenter(clock, store: store)
        let engine = ProactiveEngine(
            settings: { wp6Settings() }, now: { clock.now },
            policy: ProactivePolicyConfiguration(fuseMaxWakeups: 50),
            deliverer: deliverer, feedback: center)
        var routineA = FeedbackFixtures.candidate(
            "routine-a-run-1", kind: .routineResult, botId: "bot-1",
            routineId: "routine-a")
        routineA.rowId = "row-routine-a"
        let first = await engine.consider(routineA)
        XCTAssertEqual(first.decision, .did)
        let siblingFirst = await engine.consider(FeedbackFixtures.candidate(
            "routine-b-run-1", kind: .routineResult, botId: "bot-1",
            routineId: "routine-b"))
        XCTAssertEqual(siblingFirst.decision, .did)

        let request = BotFeedback(
            botID: "bot-1", action: .suppress,
            target: BotFeedbackArtifactRef(kind: .delivery, id: "row-routine-a"),
            scope: .class, origin: FeedbackFixtures.uiOrigin("ui-class-row"))
        let outcome = try await center.record(request)
        XCTAssertEqual(outcome.status, .accepted,
                       "code=\(outcome.code ?? "nil")")
        XCTAssertEqual(outcome.classKey, "routine:routine-a")

        clock.advance(60_000)
        let held = await engine.consider(FeedbackFixtures.candidate(
            "routine-a-run-2", kind: .routineResult, botId: "bot-1",
            routineId: "routine-a"))
        XCTAssertEqual(held.reason, "feedback-held")
        let sibling = await engine.consider(FeedbackFixtures.candidate(
            "routine-b-run-2", kind: .routineResult, botId: "bot-1",
            routineId: "routine-b"))
        XCTAssertEqual(sibling.decision, .did)
    }

    func testUIUserScopeFromAutomationRowUsesKindClass() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let delivererA = WP6NotificationDeliverer()
        let delivererB = WP6NotificationDeliverer()
        let store = InMemoryBotFeedbackStore()
        let center = makeCenter(clock, store: store)
        let engineA = ProactiveEngine(
            settings: { wp6Settings() }, now: { clock.now },
            policy: ProactivePolicyConfiguration(fuseMaxWakeups: 50),
            deliverer: delivererA, feedback: center)
        let engineB = ProactiveEngine(
            settings: { wp6Settings() }, now: { clock.now },
            policy: ProactivePolicyConfiguration(fuseMaxWakeups: 50),
            deliverer: delivererB, feedback: center)
        var routineA = FeedbackFixtures.candidate(
            "routine-a-run-1", kind: .routineResult, botId: "bot-a",
            routineId: "routine-a")
        routineA.rowId = "row-routine-a"
        let firstA = await engineA.consider(routineA)
        XCTAssertEqual(firstA.decision, .did)

        let request = BotFeedback(
            botID: "bot-a", action: .suppress,
            target: BotFeedbackArtifactRef(kind: .delivery, id: "row-routine-a"),
            scope: .user, origin: FeedbackFixtures.uiOrigin("ui-user-row"))
        let outcome = try await center.record(request)
        XCTAssertEqual(outcome.status, .accepted,
                       "code=\(outcome.code ?? "nil")")
        XCTAssertEqual(outcome.classKey, "proactive:routine-result")

        clock.advance(60_000)
        let heldB = await engineB.consider(FeedbackFixtures.candidate(
            "routine-b-run-1", kind: .routineResult, botId: "bot-b",
            routineId: "routine-b"))
        XCTAssertEqual(heldB.reason, "feedback-held")
        let taskB = await engineB.consider(
            FeedbackFixtures.candidate("task-b1", botId: "bot-b"))
        XCTAssertEqual(taskB.decision, .did)
    }

    func testUICorrectOnAMessageRowAsksForAMemoryVersion() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let store = InMemoryBotFeedbackStore()
        let center = makeCenter(clock, store: store)
        let request = BotFeedback(
            botID: "bot-1", action: .correct,
            target: BotFeedbackArtifactRef(kind: .delivery, id: "row-msg-3"),
            scope: .artifact, origin: FeedbackFixtures.uiOrigin("ui-row-4"))
        let outcome = try await center.record(request)
        XCTAssertEqual(outcome.status, .rejected)
        XCTAssertEqual(outcome.code, "target-unresolved")
        let disputed = try await center.disputedRefs(paths: [])
        XCTAssertTrue(disputed.isEmpty)
    }

    // R5: a kind-only class is too wide to apply from a model request. It must
    // stay ambiguous (no state change) unless the user picks the scope in UI.
    func testClassScopeOnKindOnlyTargetIsAmbiguous() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let store = InMemoryBotFeedbackStore()
        let center = makeCenter(clock, store: store)
        let decision = await indexDelivery(center,
                                           FeedbackFixtures.candidate("task-1"),
                                           at: clock.now)
        let outcome = try await center.record(
            FeedbackFixtures.suppress(decision, scope: .class, nonce: "kind-class"))
        XCTAssertEqual(outcome.status, .rejected)
        XCTAssertEqual(outcome.code, "ambiguous-scope")
        let active = try await center.preferences(botID: "bot-1", scope: nil).active
        XCTAssertEqual(active.count, 0)
    }

    // R5: only a host-verified UI action can create a cross-Bot preference; a
    // chat utterance that the model interpreted is source evidence, not scope
    // authority.
    func testChatOriginUserScopeRequiresConfirmation() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let store = InMemoryBotFeedbackStore()
        let center = makeCenter(clock, store: store)
        let decision = await indexDelivery(center,
                                           FeedbackFixtures.candidate("task-1"),
                                           at: clock.now)
        var request = FeedbackFixtures.suppress(decision, scope: .user,
                                                nonce: "chat-user")
        request.origin = FeedbackFixtures.chatOrigin("chat-user")
        let outcome = try await center.record(request)
        XCTAssertEqual(outcome.status, .rejected)
        XCTAssertEqual(outcome.code, "scope-requires-confirmation")
        let active = try await center.preferences(botID: "bot-1", scope: nil).active
        XCTAssertEqual(active.count, 0)
    }

    // R5: routine classes are narrow and isolated per routine id.
    func testRoutineClassIsIsolatedPerRoutine() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let deliverer = WP6NotificationDeliverer()
        let store = InMemoryBotFeedbackStore()
        let center = makeCenter(clock, store: store)
        let engine = ProactiveEngine(
            settings: { wp6Settings() }, now: { clock.now },
            policy: ProactivePolicyConfiguration(fuseMaxWakeups: 50),
            deliverer: deliverer, feedback: center)
        let first = await engine.consider(
            FeedbackFixtures.candidate("routine-1", kind: .routineResult, routineId: "r-1"))
        let sibling = await engine.consider(
            FeedbackFixtures.candidate("routine-2", kind: .routineResult, routineId: "r-2"))
        XCTAssertEqual(first.decision, .did)
        XCTAssertEqual(sibling.decision, .did)
        let suppression = try await center.record(
            FeedbackFixtures.suppress(first, scope: .class, nonce: "narrow-class"))
        XCTAssertEqual(suppression.status, .accepted)
        XCTAssertEqual(suppression.classKey, "routine:r-1")
        clock.advance(60_000)
        let held = await engine.consider(
            FeedbackFixtures.candidate("routine-3", kind: .routineResult, routineId: "r-1"))
        XCTAssertEqual(held.reason, "feedback-held")
        let other = await engine.consider(
            FeedbackFixtures.candidate("routine-4", kind: .routineResult, routineId: "r-2"))
        XCTAssertEqual(other.decision, .did)
    }

    // R4: suppressing one artifact must not leak to another target of the same
    // kind; only the referenced delivery's key is matched.
    func testArtifactScopeDoesNotTouchAnotherSameKindTarget() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let deliverer = WP6NotificationDeliverer()
        let store = InMemoryBotFeedbackStore()
        let center = makeCenter(clock, store: store)
        let engine = ProactiveEngine(
            settings: { wp6Settings() }, now: { clock.now },
            policy: ProactivePolicyConfiguration(fuseMaxWakeups: 50),
            deliverer: deliverer, feedback: center)
        let first = await engine.consider(FeedbackFixtures.candidate("weekly-report-1"))
        let sibling = await engine.consider(FeedbackFixtures.candidate("weekly-report-2"))
        XCTAssertEqual(first.decision, .did)
        XCTAssertEqual(sibling.decision, .did)
        let suppression = try await center.record(
            FeedbackFixtures.suppress(first, scope: .artifact, nonce: "one-target"))
        XCTAssertEqual(suppression.status, .accepted)

        clock.advance(60_000)
        let sameTarget = await engine.consider(
            FeedbackFixtures.candidate("weekly-report-1"))
        XCTAssertEqual(sameTarget.reason, "feedback-held")
        let otherTarget = await engine.consider(
            FeedbackFixtures.candidate("weekly-report-3"))
        XCTAssertEqual(otherTarget.decision, .did)
    }

    // R4: scope=user on the only shareable kind class must not become "all
    // proactive": other kinds and Bot-local classes keep their own behaviour.
    func testUserScopeKindClassDoesNotBecomeAllProactive() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let deliverer = WP6NotificationDeliverer()
        let store = InMemoryBotFeedbackStore()
        let center = makeCenter(clock, store: store)
        let engine = ProactiveEngine(
            settings: { wp6Settings() }, now: { clock.now },
            policy: ProactivePolicyConfiguration(fuseMaxWakeups: 50),
            deliverer: deliverer, feedback: center)
        let task = await engine.consider(FeedbackFixtures.candidate("task-1"))
        XCTAssertEqual(task.decision, .did)
        let suppression = try await center.record(
            FeedbackFixtures.suppress(task, scope: .user, nonce: "kind-only"))
        XCTAssertEqual(suppression.status, .accepted)

        clock.advance(60_000)
        let sameKind = await engine.consider(FeedbackFixtures.candidate("task-2"))
        XCTAssertEqual(sameKind.reason, "feedback-held")
        let routine = await engine.consider(
            FeedbackFixtures.candidate("routine-1", kind: .routineResult, routineId: "r-1"))
        XCTAssertEqual(routine.decision, .did)
        let reminder = await engine.consider(
            FeedbackFixtures.candidate("reminder-1", kind: .reminder, reminderId: "rem-1"))
        XCTAssertNotEqual(reminder.reason, "feedback-held")
    }

    // R4: an ambiguous/wider request is left unapplied (the host cannot confirm
    // the user's meaning), rather than silently widened to everything.
    func testWideningNeedsUIConfirmationAndStaysBounded() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let deliverer = WP6NotificationDeliverer()
        let store = InMemoryBotFeedbackStore()
        let center = makeCenter(clock, store: store)
        let engine = ProactiveEngine(
            settings: { wp6Settings() }, now: { clock.now },
            policy: ProactivePolicyConfiguration(fuseMaxWakeups: 50),
            deliverer: deliverer, feedback: center,
            deliveryKinds: [.taskDone, .routineResult, .reminder])
        let routine = await engine.consider(
            FeedbackFixtures.candidate("routine-1", kind: .routineResult, routineId: "r-1"))
        XCTAssertEqual(routine.decision, .did)
        let reminder = await engine.consider(
            FeedbackFixtures.candidate("reminder-1", kind: .reminder, reminderId: "rem-1"))
        XCTAssertEqual(reminder.decision, .did)
        let task = await engine.consider(FeedbackFixtures.candidate("task-1"))
        XCTAssertEqual(task.decision, .did)

        // A chat utterance cannot widen the scope by itself.
        var chatWide = FeedbackFixtures.suppress(routine, scope: .user,
                                                 nonce: "wide-chat")
        chatWide.origin = FeedbackFixtures.chatOrigin("wide-chat")
        let chatOutcome = try await center.record(chatWide)
        XCTAssertEqual(chatOutcome.code, "scope-requires-confirmation")
        let activeAfterChat = try await center.preferences(botID: "bot-1", scope: nil).active
        XCTAssertEqual(activeAfterChat.count, 0)

        // An explicit UI choice creates the kind-level routine-result class,
        // and only that kind is affected.
        let routineUser = try await center.record(
            FeedbackFixtures.suppress(routine, scope: .user, nonce: "wide-ui-routine"))
        XCTAssertEqual(routineUser.status, .accepted)
        XCTAssertEqual(routineUser.classKey, "proactive:routine-result")
        let reminderUser = try await center.record(
            FeedbackFixtures.suppress(reminder, scope: .user, nonce: "wide-ui-reminder"))
        XCTAssertEqual(reminderUser.status, .accepted)
        XCTAssertEqual(reminderUser.classKey, "proactive:reminder")

        clock.advance(60_000)
        let routineAgain = await engine.consider(
            FeedbackFixtures.candidate("routine-2", kind: .routineResult, routineId: "r-1"))
        XCTAssertEqual(routineAgain.reason, "feedback-held")
        let reminderAgain = await engine.consider(
            FeedbackFixtures.candidate("reminder-2", kind: .reminder, reminderId: "rem-2"))
        XCTAssertEqual(reminderAgain.reason, "feedback-held")
        let taskAgain = await engine.consider(FeedbackFixtures.candidate("task-2"))
        XCTAssertEqual(taskAgain.decision, .did,
                       "kind-level user preferences never suppress another kind")
    }

    // R4: no business-word blacklist. Identical handling for an arbitrary
    // report-looking key and an unrelated key; only the referenced id counts.
    func testNoBusinessKeywordSpecialCaseInSuppression() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let deliverer = WP6NotificationDeliverer()
        let store = InMemoryBotFeedbackStore()
        let center = makeCenter(clock, store: store)
        let engine = ProactiveEngine(
            settings: { wp6Settings() }, now: { clock.now },
            policy: ProactivePolicyConfiguration(fuseMaxWakeups: 50),
            deliverer: deliverer, feedback: center)
        let report = await engine.consider(
            FeedbackFixtures.candidate("周报-每周一"))
        let unrelated = await engine.consider(
            FeedbackFixtures.candidate("task-unrelated"))
        XCTAssertEqual(report.decision, .did)
        XCTAssertEqual(unrelated.decision, .did)
        let suppression = try await center.record(
            FeedbackFixtures.suppress(report, scope: .artifact, nonce: "keyword-free"))
        XCTAssertEqual(suppression.status, .accepted)
        clock.advance(60_000)
        let reportAgain = await engine.consider(
            FeedbackFixtures.candidate("周报-每周一"))
        XCTAssertEqual(reportAgain.reason, "feedback-held")
        let unrelatedAgain = await engine.consider(
            FeedbackFixtures.candidate("task-unrelated-2"))
        XCTAssertEqual(unrelatedAgain.decision, .did)
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
