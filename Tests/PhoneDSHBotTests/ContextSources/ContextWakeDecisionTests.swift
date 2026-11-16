// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

private actor DecisionContextFake: BotContextWakeDecisionContextProviding {
    var started = true
    var state: BotSourceAuthorizationState?
    var item: BotContextObservationViewItem?

    func set(started: Bool, state: BotSourceAuthorizationState?, item: BotContextObservationViewItem?) {
        self.started = started
        self.state = state
        self.item = item
    }

    func isStarted() async -> Bool { started }

    func authorization(for source: BotContextSourceKind) async -> BotSourceAuthorizationState? {
        state
    }

    func activeObservation(botID: String, source: BotContextSourceKind,
                           kind: BotContextObservationKind) async -> BotContextObservationViewItem? {
        guard item?.kind == kind.rawValue, item?.source == source else { return nil }
        return item
    }
}

private actor DecisionRunnerFake {
    private(set) var requests: [RoutineRunRequest] = []
    var result: RoutineExecutionResult

    init(result: RoutineExecutionResult) { self.result = result }
    func run(_ request: RoutineRunRequest) -> RoutineExecutionResult {
        requests.append(request)
        return result
    }
    func count() -> Int { requests.count }
    func all() -> [RoutineRunRequest] { requests }
}

final class ContextWakeDecisionTests: XCTestCase {
    private let now: @Sendable () -> Int64 = { 4_000_000 }

    private func state(generation: Int = 1,
                       authorization: BotSourceAuthorization = .authorized)
        -> BotSourceAuthorizationState {
        BotSourceAuthorizationState(
            source: .locationFence, authorization: authorization,
            permissionRevision: generation, updatedAt: now(),
            updatedBy: .user)
    }

    private func item(generation: Int = 1) -> BotContextObservationViewItem {
        BotContextObservationViewItem(
            source: .locationFence, kind: "location.entered",
            observedAtMS: 4_000_001,
            sourceVersion: .unversioned(),
            uncertainty: BotContextUncertainty(level: .medium, reason: "sim"),
            recordRef: "record://event/7",
            state: .active,
            consentGeneration: generation)
    }

    private func makeEngine(context: DecisionContextFake,
                            runner: DecisionRunnerFake) -> BotContextWakeDecisionEngine {
        BotContextWakeDecisionEngine(context: context, now: now) { request in
            await runner.run(request)
        }
    }

    func testAuthorizedActiveObservationRunsOneHiddenDecisionTurn() async throws {
        let context = DecisionContextFake()
        let runner = DecisionRunnerFake(result: .success("[quiet]", quiet: true))
        await context.set(started: true, state: state(), item: item())
        let engine = makeEngine(context: context, runner: runner)

        let outcome = await engine.handle(
            botID: "bot-a", reason: "context:location-fence:location.entered", at: 4_000_001)
        XCTAssertEqual(outcome, .quiet)
        let runCount = await runner.count()
        XCTAssertEqual(runCount, 1)
        let requests = await runner.all()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.botId, "bot-a")
        XCTAssertEqual(request.routine.delivery, .held)
        XCTAssertTrue(request.wake.text.contains("<native_context_wake>"))
        XCTAssertTrue(request.wake.text.contains("source=location-fence"))
        XCTAssertTrue(request.wake.text.contains("kind=location.entered"))
        XCTAssertTrue(request.wake.text.contains("consent_generation=1"))
        XCTAssertTrue(request.wake.text.contains("record_ref=record://event/7"))
        XCTAssertTrue(request.wake.text.contains("[quiet]"))
        XCTAssertFalse(request.wake.text.contains("payload"))
        let outcomes = await engine.recentOutcomes
        XCTAssertEqual(outcomes.count, 1)
    }

    func testNoConsentSkipsWithoutRunningATurn() async throws {
        let context = DecisionContextFake()
        let runner = DecisionRunnerFake(result: .success("should not run"))
        await context.set(started: true, state: state(authorization: .revoked), item: item())
        let engine = makeEngine(context: context, runner: runner)
        let outcome = await engine.handle(
            botID: "bot-a", reason: "context:location-fence:location.entered", at: 4_000_001)
        XCTAssertEqual(outcome, .skipped(reason: "not-authorized"))
        let zeroRuns = await runner.count()
        XCTAssertEqual(zeroRuns, 0)
    }

    func testNoActiveObservationOrGenerationMismatchSkips() async throws {
        let context = DecisionContextFake()
        let runner = DecisionRunnerFake(result: .success("should not run"))
        await context.set(started: true, state: state(generation: 2), item: item(generation: 1))
        let engine = makeEngine(context: context, runner: runner)
        let outcome = await engine.handle(
            botID: "bot-a", reason: "context:location-fence:location.entered", at: 4_000_001)
        XCTAssertEqual(outcome, .skipped(reason: "generation-mismatch"))
        let zeroRuns = await runner.count()
        XCTAssertEqual(zeroRuns, 0)

        await context.set(started: true, state: state(generation: 1), item: nil)
        let noObservation = await engine.handle(
            botID: "bot-a", reason: "context:location-fence:location.entered", at: 4_000_001)
        XCTAssertEqual(noObservation, .skipped(reason: "no-active-observation"))
        let stillZero = await runner.count()
        XCTAssertEqual(stillZero, 0)
    }

    func testDuplicateObservationIsBoundedToOnce() async throws {
        let context = DecisionContextFake()
        let runner = DecisionRunnerFake(result: .success("[quiet]", quiet: true))
        await context.set(started: true, state: state(), item: item())
        let engine = makeEngine(context: context, runner: runner)
        _ = await engine.handle(
            botID: "bot-a", reason: "context:location-fence:location.entered", at: 4_000_001)
        let second = await engine.handle(
            botID: "bot-a", reason: "context:location-fence:location.entered", at: 4_000_001)
        XCTAssertEqual(second, .skipped(reason: "duplicate"))
        let oneRun = await runner.count()
        XCTAssertEqual(oneRun, 1)
    }

    func testNonQuietTextIsADecisionNotAHostLog() async throws {
        let context = DecisionContextFake()
        let runner = DecisionRunnerFake(result: .success("带工牌"))
        await context.set(started: true, state: state(), item: item())
        let engine = makeEngine(context: context, runner: runner)
        let outcome = await engine.handle(
            botID: "bot-a", reason: "context:location-fence:location.entered", at: 4_000_001)
        XCTAssertEqual(outcome, .decided(text: "带工牌"))
        let outcomes = await engine.recentOutcomes
        XCTAssertEqual(outcomes.count, 1)
    }

    func testUnknownWakeReasonAndUnstartedAssemblySkip() async throws {
        let context = DecisionContextFake()
        let runner = DecisionRunnerFake(result: .success("nope"))
        await context.set(started: false, state: nil, item: nil)
        let engine = makeEngine(context: context, runner: runner)
        let wrong = await engine.handle(
            botID: "bot-a", reason: "proactive:something", at: 1)
        XCTAssertEqual(wrong, .skipped(reason: "not-a-context-wake"))
        let unstarted = await engine.handle(
            botID: "bot-a", reason: "context:location-fence:location.entered", at: 1)
        XCTAssertEqual(unstarted, .skipped(reason: "assembly-not-started"))
        let zeroRuns = await runner.count()
        XCTAssertEqual(zeroRuns, 0)
    }
}
