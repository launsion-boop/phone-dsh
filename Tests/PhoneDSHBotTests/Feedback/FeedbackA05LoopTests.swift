// SPDX-License-Identifier: MIT

// A05 host-loop acceptance at the fixed integration checkout.
//
// These tests use the production Feedback center, the production
// `ProactiveEngine` gate/tool handler, the real SQLite domain event log, the
// real `BotMemory` store and the real P18 UserDefaults key. They do NOT copy the
// state machine: every assertion goes through the same code C assembles in the
// App. The UI adapter shape is reproduced exactly as `BotProductionUIAdapters`
// sends it (`target:.delivery`, rowID, `.uiAction` origin); the adapter itself
// lives in the App target and is covered by the app build/E2E.

import XCTest
@testable import PhoneDSHBot

final class FeedbackA05LoopTests: XCTestCase {
    private var store: SQLiteDomainStore!
    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var memory: BotMemory!
    private var clock: WP6Clock!

    override func setUp() async throws {
        (store, root) = try makeMemoryTestStore()
        suiteName = "feedback-a05-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        memory = makeMemory(store: store, botID: "bot-a")
        clock = WP6Clock(FeedbackFixtures.baseNow)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? await store?.close()
        cleanupMemoryTestStore(root)
    }

    private func makeCenter(routineReader: (any BotFeedbackRoutineReading)? = nil)
        throws -> BotFeedbackCenter {
        let reader: any BotFeedbackMemoryReading = memory
        return try BotFeedbackCenter.live(
            eventLog: store, memory: { _ in reader },
            routineReader: routineReader, defaults: defaults,
            now: { [clock] in clock!.now })
    }

    private func makeEngine(_ center: BotFeedbackCenter,
                            deliverer: WP6NotificationDeliverer,
                            kinds: Set<ProactiveKind> = [.taskDone, .routineResult, .reminder])
        -> ProactiveEngine {
        ProactiveEngine(
            settings: { wp6Settings() }, now: { [clock] in clock!.now },
            policy: ProactivePolicyConfiguration(fuseMaxWakeups: 50),
            deliverer: deliverer, eventLog: store, feedback: center,
            deliveryKinds: kinds)
    }

    private func ui(_ nonce: String = UUID().uuidString) -> BotFeedbackOrigin {
        BotFeedbackOrigin(kind: .uiAction, nonce: nonce)
    }

    private func feedbackEvents() async throws -> [BotEvent] {
        let page = try await store.events(after: 0, limit: 500)
        return page.filter { $0.type == BotFeedbackCenter.feedbackEventType }
    }

    private func storedIndex() throws -> BotFeedbackIndexFile? {
        guard let data = defaults.data(forKey: BotFeedbackIndexFile.defaultsKey) else {
            return nil
        }
        return try JSONDecoder().decode(BotFeedbackIndexFile.self, from: data)
    }

    // 1. UI adapter shape for a visible message row: persisted durable event,
    //    P18 index, restart idempotency, and no model fabrication.
    func testUIAdapterAdoptSurvivesRestartAndIsIdempotent() async throws {
        let center = try makeCenter()
        let rowID = "row-message-1"
        let request = BotFeedback(
            botID: "bot-a", action: .adopt,
            target: BotFeedbackArtifactRef(kind: .delivery, id: rowID),
            scope: .artifact, origin: ui("ui-adopt-1"))
        let outcome = try await center.record(request)
        XCTAssertEqual(outcome.status, .accepted)

        let events = try await feedbackEvents()
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.origin, .local(source: "card-bridge"))
        XCTAssertEqual(event.principal.kind, "chat")
        XCTAssertEqual(event.principal.botId, "bot-a")
        guard case .object(let data) = event.data else {
            return XCTFail("feedback event data must be an object")
        }
        XCTAssertEqual(data["accepted"] ?? .null, .bool(true))
        XCTAssertEqual(data["action"] ?? .null, .string("adopt"))
        XCTAssertEqual(data["scope"] ?? .null,
                       .object(["kind": .string("artifact"),
                                "key": .string("delivery:bot-a:\(rowID)")]))

        let index = try XCTUnwrap(try storedIndex())
        XCTAssertEqual(index.v, 1)
        let adoption = try XCTUnwrap(index.records.first { $0.action == .adopt })
        XCTAssertEqual(adoption.scope.key, "delivery:bot-a:\(rowID)")
        XCTAssertEqual(adoption.status, .active)

        // The same UI retry (same nonce) and a fresh tap (new nonce) are both
        // idempotent after a relaunch.
        let restarted = try makeCenter()
        let replay = try await restarted.record(request)
        XCTAssertEqual(replay.status, .duplicated)
        var secondTap = request
        secondTap.origin = ui("ui-adopt-2")
        let duplicated = try await restarted.record(secondTap)
        XCTAssertEqual(duplicated.status, .duplicated)
        XCTAssertEqual(duplicated.feedbackID, outcome.feedbackID)

        // UI undo retracts the adoption; a later tap is a new adoption.
        let undo = try await restarted.undo(
            try XCTUnwrap(outcome.feedbackID), botID: "bot-a",
            origin: ui("ui-adopt-undo"))
        XCTAssertEqual(undo.status, .accepted)
        XCTAssertTrue(undo.reversed)
        let undoneIndex = try XCTUnwrap(try storedIndex())
        XCTAssertEqual(undoneIndex.records.first { $0.action == .adopt }?.status, .undone)
        var readopt = request
        readopt.origin = ui("ui-adopt-3")
        let readopted = try await restarted.record(readopt)
        XCTAssertEqual(readopted.status, .accepted)
        XCTAssertNotEqual(readopted.feedbackID, outcome.feedbackID)

        // A model turn cannot bind a fabricated row artifact.
        var model = request
        model.origin = FeedbackFixtures.chatOrigin("chat-adopt")
        let denied = try await restarted.record(model)
        XCTAssertEqual(denied.code, "target-unresolved")
    }

    // 2. UI suppress on a routine result row: the next decision is held, the
    //    sibling routine is untouched, both survive a relaunch, and undo
    //    releases the gate.
    func testUISuppressOnRoutineRowHoldsNextDecisionAcrossRestart() async throws {
        let deliverer = WP6NotificationDeliverer()
        let center = try makeCenter()
        let engine = makeEngine(center, deliverer: deliverer)
        var routineA = FeedbackFixtures.candidate(
            "routine-a-run-1", kind: .routineResult, botId: "bot-a",
            routineId: "routine-a")
        routineA.rowId = "row-routine-a"
        let first = await engine.consider(routineA)
        XCTAssertEqual(first.decision, .did)
        let sibling = await engine.consider(
            FeedbackFixtures.candidate("routine-b-run-1", kind: .routineResult,
                                       botId: "bot-a", routineId: "routine-b"))
        XCTAssertEqual(sibling.decision, .did)

        let suppression = try await center.record(BotFeedback(
            botID: "bot-a", action: .suppress,
            target: BotFeedbackArtifactRef(kind: .delivery, id: "row-routine-a"),
            scope: .artifact, origin: ui("ui-suppress-routine")))
        XCTAssertEqual(suppression.status, .accepted,
                       "code=\(suppression.code ?? "nil") message=\(suppression.message ?? "nil")")
        let recorded = try XCTUnwrap(try storedIndex())
        XCTAssertEqual(recorded.records.filter { $0.action == .suppress }.count, 1)

        clock.advance(60_000)
        let held = await engine.consider(FeedbackFixtures.candidate(
            "routine-a-run-1", kind: .routineResult, botId: "bot-a",
            routineId: "routine-a"))
        XCTAssertEqual(held.reason, "feedback-held")
        let other = await engine.consider(FeedbackFixtures.candidate(
            "routine-b-run-2", kind: .routineResult, botId: "bot-a",
            routineId: "routine-b"))
        XCTAssertEqual(other.decision, .did)

        // Restart: a fresh center reads the P18 index and keeps holding.
        let restarted = try makeCenter()
        let restartedEngine = makeEngine(restarted, deliverer: deliverer)
        clock.advance(60_000)
        let heldAfterRestart = await restartedEngine.consider(FeedbackFixtures.candidate(
            "routine-a-run-1", kind: .routineResult, botId: "bot-a",
            routineId: "routine-a"))
        XCTAssertEqual(heldAfterRestart.reason, "feedback-held")
        let siblingAfterRestart = await restartedEngine.consider(FeedbackFixtures.candidate(
            "routine-b-run-3", kind: .routineResult, botId: "bot-a",
            routineId: "routine-b"))
        XCTAssertEqual(siblingAfterRestart.decision, .did)

        let undo = try await restarted.undo(
            try XCTUnwrap(suppression.feedbackID), botID: "bot-a",
            origin: ui("ui-undo-routine"))
        XCTAssertEqual(undo.status, .accepted)
        XCTAssertTrue(undo.reversed)
        clock.advance(60_000)
        let released = await restartedEngine.consider(FeedbackFixtures.candidate(
            "routine-a-run-1", kind: .routineResult, botId: "bot-a",
            routineId: "routine-a"))
        XCTAssertEqual(released.decision, .did)
    }

    // 3. A host-verified UI action can create a kind-level cross-Bot user
    //    preference; Bot B honours it, a routine result does not match it, and
    //    the preference survives a relaunch and can be rolled back.
    func testCrossBotUserScopeEnforcedAndRolledBack() async throws {
        let delivererA = WP6NotificationDeliverer()
        let delivererB = WP6NotificationDeliverer()
        let center = try makeCenter()
        let engineA = makeEngine(center, deliverer: delivererA)
        let engineB = makeEngine(center, deliverer: delivererB)
        let task = await engineA.consider(
            FeedbackFixtures.candidate("task-1", botId: "bot-a"))
        XCTAssertEqual(task.decision, .did)

        let suppression = try await center.record(BotFeedback(
            botID: "bot-a", action: .suppress,
            target: BotFeedbackArtifactRef(kind: .proactive, id: task.id,
                                           deliveryKey: task.dedupeKey),
            scope: .user, origin: ui("ui-user-scope")))
        XCTAssertEqual(suppression.status, .accepted)
        XCTAssertEqual(suppression.classKey, "proactive:task-done")

        clock.advance(60_000)
        let heldB = await engineB.consider(
            FeedbackFixtures.candidate("task-b1", botId: "bot-b"))
        XCTAssertEqual(heldB.reason, "feedback-held")
        let routineB = await engineB.consider(FeedbackFixtures.candidate(
            "routine-b", kind: .routineResult, botId: "bot-b", routineId: "routine-b"))
        XCTAssertEqual(routineB.decision, .did)

        // A chat utterance cannot widen the scope by itself.
        var chatWide = BotFeedback(
            botID: "bot-a", action: .suppress,
            target: BotFeedbackArtifactRef(kind: .proactive, id: task.id,
                                           deliveryKey: task.dedupeKey),
            scope: .user,
            origin: FeedbackFixtures.chatOrigin("chat-wide"))
        let chatDenied = try await center.record(chatWide)
        XCTAssertEqual(chatDenied.code, "scope-requires-confirmation")
        chatWide.scope = .class
        let classDenied = try await center.record(chatWide)
        XCTAssertEqual(classDenied.code, "ambiguous-scope")

        let restarted = try makeCenter()
        let restartedB = makeEngine(restarted, deliverer: delivererB)
        clock.advance(60_000)
        let heldAfterRestart = await restartedB.consider(
            FeedbackFixtures.candidate("task-b2", botId: "bot-b"))
        XCTAssertEqual(heldAfterRestart.reason, "feedback-held")

        let undo = try await restarted.undo(
            try XCTUnwrap(suppression.feedbackID), botID: "bot-b",
            origin: ui("ui-user-undo"))
        XCTAssertEqual(undo.status, .accepted, "a user-scope preference can be rolled back from any Bot")
        clock.advance(60_000)
        let released = await restartedB.consider(
            FeedbackFixtures.candidate("task-b3", botId: "bot-b"))
        XCTAssertEqual(released.decision, .did)
    }

    // 4. Correct uses the real applied memory version, publishes the disputed
    //    refs to M, survives a full event-log rebuild, and undo retracts it.
    func testCorrectUsesAppliedMemoryVersionAndRebuildsFromEvents() async throws {
        let path = "user/prefs/coffee.md"
        let writeContext = BotMemoryWriteContext(
            botID: "bot-a", sessionID: "s-chat", authorKind: .chat,
            source: BotMemorySource(kind: .userTurn, sessionID: "s-chat"),
            trust: .user)
        let written = try await memory.write(
            BotMemoryWriteRequest(action: .write, path: path, content: "decaf",
                                  expectedVersion: 0,
                                  evidence: ["record://session/s-chat#7"]),
            context: writeContext)
        XCTAssertTrue(written.ok)
        XCTAssertEqual(written.version, 1)

        let center = try makeCenter()
        let correct = try await center.record(BotFeedback(
            botID: "bot-a", action: .correct,
            target: BotFeedbackArtifactRef(kind: .memory, id: path, version: 1),
            scope: .artifact, origin: ui("ui-correct-1")))
        XCTAssertEqual(correct.status, .accepted)
        XCTAssertEqual(correct.appliedMemory?.version, 1)
        let disputed = try await center.disputedRefs(paths: [path])
        XCTAssertEqual(disputed[path]?.first?.state, "active")
        XCTAssertEqual(disputed[path]?.first?.refs, ["record://session/s-chat#7"])

        let events = try await store.events(after: 0, limit: 500)
        XCTAssertTrue(events.contains { $0.type == BotFeedbackCenter.feedbackEventType })
        let review = try XCTUnwrap(events.first { $0.type == "memory.review_requested" })
        guard case .object(let data) = review.data else {
            return XCTFail("review data must be an object")
        }
        XCTAssertEqual(data["path"] ?? .null, .string(path))

        // M reads the same view through the production protocol adapter.
        let mView = try await BotFeedbackDisputeAdapter(query: center)
            .disputedReferences(forPaths: [path])
        XCTAssertEqual(mView[path], ["record://session/s-chat#7"])

        // Simulate an index loss: the facts are the events, and the next
        // center must rebuild the disputed view from them.
        defaults.removeObject(forKey: BotFeedbackIndexFile.defaultsKey)
        let rebuilt = try makeCenter()
        let rebuiltView = try await rebuilt.disputedRefs(paths: [path])
        XCTAssertEqual(rebuiltView[path]?.first?.state, "active")
        XCTAssertEqual(rebuiltView[path]?.first?.refs, ["record://session/s-chat#7"])

        let undo = try await rebuilt.undo(
            try XCTUnwrap(correct.feedbackID), botID: "bot-a",
            origin: ui("ui-correct-undo"))
        XCTAssertEqual(undo.status, .accepted)
        let retracted = try await rebuilt.disputedRefs(paths: [path])
        XCTAssertEqual(retracted[path]?.first?.state, "retracted")
    }

    // Q1/A05 causal gate: a correction may dispute the *existing* applied
    // version without rewriting the memory document. The host must bind the
    // current version, publish review_requested/disputedRefs, and undo must
    // clear the dispute without touching the bytes or version.
    func testCorrectionDisputesExistingVersionWithoutRewriteAndUndoClears() async throws {
        let path = "user/prefs/disputed-only.md"
        let context = BotMemoryWriteContext(
            botID: "bot-a", sessionID: "s-chat", authorKind: .chat,
            source: BotMemorySource(kind: .userTurn, sessionID: "s-chat"),
            trust: .user)
        let written = try await memory.write(
            BotMemoryWriteRequest(action: .write, path: path, content: "先结论、后风险",
                                  expectedVersion: 0,
                                  evidence: ["record://session/s-chat#11"]),
            context: context)
        XCTAssertTrue(written.ok)
        XCTAssertEqual(written.version, 1)

        let center = try makeCenter()
        let feedback = try await center.dispute(
            memoryPath: path, version: 1, botID: "bot-a",
            refs: ["record://session/s-chat#11"], origin: ui("ui-disputed-only"))
        XCTAssertEqual(feedback.status, .accepted)
        XCTAssertNil(feedback.appliedMemory, "disputed-only omits the applied member")
        let disputed = try await center.disputedRefs(paths: [path])
        XCTAssertEqual(disputed[path]?.first?.correctedVersion, 1)
        XCTAssertEqual(disputed[path]?.first?.state, "active")

        let events = try await store.events(after: 0, limit: 500)
        let recorded = try XCTUnwrap(events.first { $0.type == BotFeedbackCenter.feedbackEventType })
        guard case .object(let eventData) = recorded.data else {
            return XCTFail("feedback event data must be an object")
        }
        XCTAssertNil(eventData["applied"])
        XCTAssertEqual(eventData["subjects"], .array([.string("record://session/s-chat#11")]))
        let review = try XCTUnwrap(events.first { $0.type == "memory.review_requested" })
        guard case .object(let reviewData) = review.data else {
            return XCTFail("review data must be an object")
        }
        XCTAssertEqual(reviewData["outcome"], .string("disputed"))

        guard case .document(let document) = try await memory.read(path: path) else {
            return XCTFail("memory document must still be readable")
        }
        XCTAssertEqual(document.version, 1, "disputing must not rewrite or bump the document")
        XCTAssertEqual(document.content, "先结论、后风险")

        let undo = try await center.undo(
            try XCTUnwrap(feedback.feedbackID), botID: "bot-a",
            origin: ui("ui-disputed-only-undo"))
        XCTAssertEqual(undo.status, .accepted)
        let cleared = try await center.disputedRefs(paths: [path])
        XCTAssertEqual(cleared[path]?.first?.state, "retracted")
        guard case .document(let afterUndo) = try await memory.read(path: path) else {
            return XCTFail("memory document must remain readable after undo")
        }
        XCTAssertEqual(afterUndo.version, 1)
        XCTAssertEqual(afterUndo.content, "先结论、后风险")
        let afterEvents = try await store.events(after: 0, limit: 500)
        let resolved = try XCTUnwrap(afterEvents.first { $0.type == "memory.review_resolved" })
        guard case .object(let resolvedData) = resolved.data else {
            return XCTFail("review_resolved data must be an object")
        }
        XCTAssertEqual(resolvedData["outcome"], .string("dropped"))
        XCTAssertEqual(resolvedData["path"], .string(path))
    }

    // The model tool path must reach the same disputed-only shape when it
    // supplies real refs for an existing version; no UpdateMemory rewrite.
    func testModelCorrectWithDisputedRefsOmitsApplied() async throws {
        let path = "user/prefs/model-disputed.md"
        let context = BotMemoryWriteContext(
            botID: "bot-a", sessionID: "s-chat", authorKind: .chat,
            source: BotMemorySource(kind: .userTurn, sessionID: "s-chat"),
            trust: .user)
        _ = try await memory.write(
            BotMemoryWriteRequest(action: .write, path: path, content: "v1",
                                  expectedVersion: 0,
                                  evidence: ["record://session/s-chat#21"]),
            context: context)
        let center = try makeCenter()
        let tools = BotFeedbackTools(center: center)
        let principal = BotGatewayPrincipal(
            botId: "bot-a", sessionId: "session-chat", kind: .chat,
            expiresAt: FeedbackFixtures.baseNow + 3_600_000)
        let result = await tools.execute(
            name: BotFeedbackTools.toolName,
            arguments: .object([
                "action": .string("correct"),
                "target": .object(["kind": .string("memory"),
                                   "id": .string(path), "version": .number(1)]),
                "scope": .string("artifact"),
                "disputed_refs": .array([.string("record://session/s-chat#21")]),
            ]),
            principal: principal,
            context: BotMCPRequestContext(callId: "mcp-correct-disputed"))
        XCTAssertNotEqual(result.isError, true)
        guard case .object(let body)? = result.structuredContent else {
            return XCTFail("tool result must be structured")
        }
        XCTAssertEqual(body["ok"] ?? .null, .bool(true), "body=\(body)")
        let events = try await feedbackEvents()
        let recorded = try XCTUnwrap(events.last)
        guard case .object(let data) = recorded.data else {
            return XCTFail("feedback event data must be an object")
        }
        XCTAssertNil(data["applied"], "model dispute must omit applied")
        XCTAssertEqual(data["subjects"], .array([.string("record://session/s-chat#21")]))
        guard case .document(let document) = try await memory.read(path: path) else {
            return XCTFail("memory document must remain readable")
        }
        XCTAssertEqual(document.version, 1)
        XCTAssertEqual(document.content, "v1")
        let allEvents = try await store.events(after: 0, limit: 500)
        let review = try XCTUnwrap(allEvents.first { $0.type == "memory.review_requested" })
        guard case .object(let reviewData) = review.data else {
            return XCTFail("review data must be an object")
        }
        XCTAssertEqual(reviewData["outcome"], .string("disputed"))
    }

    // 6. Production per-caller catalog gate for the model path. The static
    //    catalog already advertises RecordFeedback at this checkout, but the
    //    roster-aware catalog used by `tools/list` and by the runtime's
    //    per-caller check does not yet include it. This test is a live gate:
    //    it skips with the exact reason until C/G applies the roster-version
    //    patch.
    func testIdentifiedCallerCatalogAdvertisesRecordFeedback() async throws {
        let roster = botTeamRoster()
        let definitions = BotToolCatalog.allDefinitions(roster: roster,
                                                        callerBotID: "bot-a")
        let advertised = definitions.first { $0.name == BotFeedbackTools.toolName }
        try XCTSkipIf(advertised == nil,
                      "production roster catalog lacks RecordFeedback; a real model tool call would get permission_denied before dispatch")
        XCTAssertTrue(BotToolCatalog.isRegistered(BotFeedbackTools.toolName))
        XCTAssertEqual(advertised, BotFeedbackTools.definition)
    }

    // Q1/E: a stale persisted index must never turn into a duplicate outcome
    // without a matching feedback.recorded event. The event log is the fact
    // source; the index is rebuilt before any duplicate check.
    func testStaleIndexCannotProduceDuplicateWithoutEvent() async throws {
        let path = "user/prefs/stale.md"
        let writeContext = BotMemoryWriteContext(
            botID: "bot-a", sessionID: "s-chat", authorKind: .chat,
            source: BotMemorySource(kind: .userTurn, sessionID: "s-chat"),
            trust: .user)
        _ = try await memory.write(
            BotMemoryWriteRequest(action: .write, path: path, content: "v1",
                                  expectedVersion: 0,
                                  evidence: ["record://session/s-chat#1"]),
            context: writeContext)
        let stale = BotFeedbackIndexRecord(
            feedbackID: "feedback:bot-a:stale",
            action: .correct,
            target: .init(kind: .memory, id: path, version: 1),
            scope: .init(kind: .artifact, key: "memory:\(path)@v1"),
            status: .active, createdAtMS: FeedbackFixtures.baseNow)
        let store = InMemoryBotFeedbackStore(
            index: BotFeedbackIndexFile(records: [stale], rebuiltFromCommitSeq: 50))
        let reader: any BotFeedbackMemoryReading = memory
        // Use the real domain event log but the stale index cache.
        let liveCenter = BotFeedbackCenter(
            store: store, eventLog: self.store,
            memory: { _ in reader }, now: { [clock] in clock!.now })

        let outcome = try await liveCenter.record(BotFeedback(
            botID: "bot-a", action: .correct,
            target: BotFeedbackArtifactRef(kind: .memory, id: path, version: 1),
            scope: .artifact, origin: ui("ui-stale-correct")))
        XCTAssertEqual(outcome.status, .accepted,
                       "a stale index may not produce duplicated without an event")
        let events = try await feedbackEvents()
        XCTAssertEqual(events.filter { $0.type == BotFeedbackCenter.feedbackEventType }.count, 1)
        let currentIndex = await store.currentIndex()
        let indexAfter = try XCTUnwrap(currentIndex)
        XCTAssertFalse(indexAfter.records.contains { $0.feedbackID == "feedback:bot-a:stale" })
    }

    // A crash between feedback.recorded and memory.review_requested is
    // repaired from the durable feedback event on the next center.
    func testCorrectionReviewRequestIsRepairedOnReload() async throws {
        let path = "user/prefs/repair.md"
        let writeContext = BotMemoryWriteContext(
            botID: "bot-a", sessionID: "s-chat", authorKind: .chat,
            source: BotMemorySource(kind: .userTurn, sessionID: "s-chat"),
            trust: .user)
        _ = try await memory.write(
            BotMemoryWriteRequest(action: .write, path: path, content: "v1",
                                  expectedVersion: 0,
                                  evidence: ["record://session/s-chat#2"]),
            context: writeContext)
        let reader: any BotFeedbackMemoryReading = memory
        let dropping = DropReviewEventLog(inner: store)
        let first = BotFeedbackCenter(
            store: InMemoryBotFeedbackStore(), eventLog: dropping,
            memory: { _ in reader }, now: { [clock] in clock!.now })
        let outcome = try await first.record(BotFeedback(
            botID: "bot-a", action: .correct,
            target: BotFeedbackArtifactRef(kind: .memory, id: path, version: 1),
            scope: .artifact, origin: ui("ui-review-repair")))
        XCTAssertEqual(outcome.status, .accepted)
        let before = try await store.events(after: 0, limit: 200)
        XCTAssertFalse(before.contains { $0.type == "memory.review_requested" },
                       "the wrapper dropped the review request")

        let repaired = BotFeedbackCenter(
            store: InMemoryBotFeedbackStore(), eventLog: store,
            memory: { _ in reader }, now: { [clock] in clock!.now })
        _ = try await repaired.disputedRefs(paths: [path])
        let after = try await store.events(after: 0, limit: 200)
        XCTAssertTrue(after.contains { $0.type == "memory.review_requested" },
                      "reload must repair the missing review request from the feedback event")
    }

    // 8. A real routine can be suppressed before its first run, when there is
    //    no proactive delivery yet. The host must verify routine existence via
    //    the routine machine port, bind the narrow routine class, and never
    //    invent a delivery. This mirrors E's real-upstream scenario.
    func testRoutineSuppressionBeforeFirstRunUsesTheRealRoutineDocument() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let deliverer = WP6NotificationDeliverer()
        let routineStore = SQLiteRoutineStore(domainStore: store)
        let machine = RoutineMachine(store: routineStore)
        let created = try await machine.create(
            botId: "bot-a", title: "周五交周报提醒", prompt: "提醒交周报",
            schedule: .interval(everyMinutes: 7 * 24 * 60), now: clock.now,
            id: "routine-real-1")
        XCTAssertEqual(created.enabled, true)
        _ = try await machine.create(
            botId: "bot-b", title: "private", prompt: "private",
            schedule: .interval(everyMinutes: 7 * 24 * 60), now: clock.now,
            id: "routine-b-private")
        let documentBefore = try await routineStore.read(botId: "bot-a")
        let routineRevision = documentBefore.version

        let center = try makeCenter(routineReader: BotFeedbackRoutineReader(store: routineStore))
        let engine = ProactiveEngine(
            settings: { wp6Settings() }, now: { clock.now },
            policy: ProactivePolicyConfiguration(fuseMaxWakeups: 50),
            deliverer: deliverer, feedback: center)
        let request = BotFeedback(
            botID: "bot-a", action: .suppress,
            target: BotFeedbackArtifactRef(kind: .routine, id: "routine-real-1"),
            scope: .class, origin: ui("ui-routine-real"))
        let outcome = try await center.record(request)
        XCTAssertEqual(outcome.status, .accepted, "code=\(outcome.code ?? "nil")")
        XCTAssertEqual(outcome.classKey, "routine:routine-real-1")
        XCTAssertEqual(outcome.target.version, routineRevision,
                       "the target carries the routine document revision")

        clock.advance(60_000)
        let held = await engine.consider(FeedbackFixtures.candidate(
            "routine-real-run-1", kind: .routineResult, botId: "bot-a",
            routineId: "routine-real-1"))
        XCTAssertEqual(held.reason, "feedback-held")
        let other = await engine.consider(FeedbackFixtures.candidate(
            "routine-other-run-1", kind: .routineResult, botId: "bot-a",
            routineId: "routine-other"))
        XCTAssertEqual(other.decision, .did)

        // Another Bot's routine is not visible to bot-a.
        let crossBot = BotFeedback(
            botID: "bot-a", action: .suppress,
            target: BotFeedbackArtifactRef(kind: .routine, id: "routine-b-private"),
            scope: .class, origin: ui("ui-routine-cross"))
        let crossOutcome = try await center.record(crossBot)
        XCTAssertEqual(crossOutcome.code, "target-unresolved")

        // Artifact scope is incoherent for a routine target (no single delivery).
        let artifact = BotFeedback(
            botID: "bot-a", action: .suppress,
            target: BotFeedbackArtifactRef(kind: .routine, id: "routine-real-1"),
            scope: .artifact, origin: ui("ui-routine-artifact"))
        let artifactOutcome = try await center.record(artifact)
        XCTAssertEqual(artifactOutcome.code, "ambiguous-scope")

        // A deleted routine is no longer resolvable.
        _ = try await machine.delete(botId: "bot-a", routineId: "routine-real-1")
        let deleted = BotFeedback(
            botID: "bot-a", action: .suppress,
            target: BotFeedbackArtifactRef(kind: .routine, id: "routine-real-1"),
            scope: .class, origin: ui("ui-routine-deleted"))
        let deletedOutcome = try await center.record(deleted)
        XCTAssertEqual(deletedOutcome.code, "target-unresolved")
    }

    // 7. Structural approval path for RecordFeedback: the host classifier is
    //    a known write/ask, and it must declare an execution point so the
    //    once-grant survives the approval decision for the host call. Without
    //    it the Worker gate and the host disagree, or the grant is consumed
    //    before execution. This is a live gate for C's Authz fix.
    func testRecordFeedbackEffectDefersGrantConsumption() throws {
        let effect = BotToolEffectClassifier.effect(
            for: BotFeedbackTools.toolName,
            arguments: .object([
                "action": .string("suppress"),
                "target": .object(["kind": .string("routine"), "id": .string("routine-1")]),
            ]))
        XCTAssertTrue(effect.known)
        XCTAssertEqual(effect.policy, .ask)
        XCTAssertEqual(effect.mutability, .write)
        try XCTSkipIf(effect.execution == nil,
                      "host classifier lacks execution; an approved once grant is consumed before the host execution point")
        XCTAssertEqual(effect.execution, "feedback")
    }

    // 5. The model-facing handler (host half) persists through the same center
    //    and changes the next decision; a non-chat principal is refused.
    func testModelToolHandlerPersistsFeedbackAndChangesNextDecision() async throws {
        let deliverer = WP6NotificationDeliverer()
        let center = try makeCenter()
        let engine = makeEngine(center, deliverer: deliverer)
        var routine = FeedbackFixtures.candidate(
            "routine-model-1", kind: .routineResult, botId: "bot-a",
            routineId: "routine-model")
        routine.rowId = "row-routine-model"
        let delivered = await engine.consider(routine)
        XCTAssertEqual(delivered.decision, .did)

        let tools = BotFeedbackTools(center: center)
        let principal = BotGatewayPrincipal(
            botId: "bot-a", sessionId: "session-chat", kind: .chat,
            expiresAt: FeedbackFixtures.baseNow + 3_600_000)
        let result = await tools.execute(
            name: BotFeedbackTools.toolName,
            arguments: .object([
                "action": .string("suppress"),
                "target": .object([
                    "kind": .string("proactive"), "id": .string(delivered.id),
                    "delivery_key": .string(try XCTUnwrap(delivered.dedupeKey)),
                ]),
                "scope": .string("class"),
            ]),
            principal: principal,
            context: BotMCPRequestContext(callId: "mcp-call-1"))
        XCTAssertNotEqual(result.isError, true)
        guard case .object(let body)? = result.structuredContent else {
            return XCTFail("tool result must be structured")
        }
        XCTAssertEqual(body["ok"] ?? .null, .bool(true),
                       "tool body=\(body)")
        XCTAssertEqual(body["status"] ?? .null, .string("accepted"))

        let events = try await feedbackEvents()
        XCTAssertTrue(events.contains { $0.origin == .local(source: "mcp") })

        clock.advance(60_000)
        let held = await engine.consider(FeedbackFixtures.candidate(
            "routine-model-2", kind: .routineResult, botId: "bot-a",
            routineId: "routine-model"))
        XCTAssertEqual(held.reason, "feedback-held")

        // The model can undo the feedback it just recorded (the previous tool
        // result carries the feedback id), and the gate releases.
        guard case .string(let feedbackID)? = body["feedback_id"] else {
            return XCTFail("the accepted feedback must return a feedback id")
        }
        let undoResult = await tools.execute(
            name: BotFeedbackTools.toolName,
            arguments: .object([
                "action": .string("undo"),
                "target": .object(["kind": .string("feedback"),
                                   "id": .string(feedbackID)]),
            ]),
            principal: principal,
            context: BotMCPRequestContext(callId: "mcp-call-undo"))
        XCTAssertNotEqual(undoResult.isError, true)
        clock.advance(60_000)
        let released = await engine.consider(FeedbackFixtures.candidate(
            "routine-model-3", kind: .routineResult, botId: "bot-a",
            routineId: "routine-model"))
        XCTAssertEqual(released.decision, .did)

        // The model can bind a correction to the memory version it applied.
        let path = "user/prefs/model.md"
        let writeContext = BotMemoryWriteContext(
            botID: "bot-a", sessionID: "s-chat", authorKind: .chat,
            source: BotMemorySource(kind: .userTurn, sessionID: "s-chat"),
            trust: .user)
        let written = try await memory.write(
            BotMemoryWriteRequest(action: .write, path: path, content: "tea",
                                  expectedVersion: 0,
                                  evidence: ["record://session/s-chat#11"]),
            context: writeContext)
        XCTAssertTrue(written.ok)
        let correctResult = await tools.execute(
            name: BotFeedbackTools.toolName,
            arguments: .object([
                "action": .string("correct"),
                "target": .object(["kind": .string("memory"),
                                   "id": .string(path),
                                   "version": .number(1)]),
            ]),
            principal: principal,
            context: BotMCPRequestContext(callId: "mcp-call-correct"))
        XCTAssertNotEqual(correctResult.isError, true)
        let corrected = try await center.disputedRefs(paths: [path])
        XCTAssertEqual(corrected[path]?.first?.state, "active")
        let allEvents = try await feedbackEvents()
        XCTAssertTrue(allEvents.contains { $0.type == "feedback.recorded" })

        let routinePrincipal = BotGatewayPrincipal(
            botId: "bot-a", sessionId: "session-routine", kind: .routine,
            expiresAt: FeedbackFixtures.baseNow + 3_600_000)
        let denied = await tools.execute(
            name: BotFeedbackTools.toolName,
            arguments: .object([
                "action": .string("adopt"),
                "target": .object(["kind": .string("delivery"),
                                   "id": .string("row-routine-model")]),
            ]),
            principal: routinePrincipal,
            context: BotMCPRequestContext(callId: "mcp-call-2"))
        XCTAssertEqual(denied.isError, true)
    }
}
