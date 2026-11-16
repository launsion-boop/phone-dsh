// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

private actor A08WakeRecorder {
    private(set) var signals: [BotContextWake] = []
    func record(_ wake: BotContextWake) { signals.append(wake) }
    func count() -> Int { signals.count }
}

private actor A08DecisionRunner {
    private(set) var runs: [RoutineRunRequest] = []
    func run(_ request: RoutineRunRequest) -> RoutineExecutionResult {
        runs.append(request)
        return .success("[quiet]", quiet: true)
    }
    func count() -> Int { runs.count }
}

private struct A08DecisionContext: BotContextWakeDecisionContextProviding {
    let registry: BotContextSourceRegistry
    let ledger: BotContextConsentLedger

    func isStarted() async -> Bool { true }
    func authorization(for source: BotContextSourceKind) async -> BotSourceAuthorizationState? {
        await ledger.state(for: source)
    }
    func activeObservation(botID: String, source: BotContextSourceKind,
                           kind: BotContextObservationKind) async -> BotContextObservationViewItem? {
        await registry.observationView(for: botID, sources: [source]).items.first {
            $0.state == .active && $0.kind == kind.rawValue
        }
    }
}

final class ContextSourceA08EvidenceTests: XCTestCase {
    private let now: @Sendable () -> Int64 = { 7_000_000 }

    private func make() async throws
        -> (BotContextSourceRegistry, BotContextConsentLedger,
            FakeContextSource, A08WakeRecorder) {
        let fake = FakeContextSource(kind: .calendar, osStatus: .authorized)
        let ledger = BotContextConsentLedger(
            store: InMemoryBotContextSourceConsentStore(), now: now)
        let registry = BotContextSourceRegistry(
            ledger: ledger, audit: BotContextAuditLog(), now: now)
        _ = await ledger.load()
        try await registry.register(fake)
        _ = try await registry.requestConsent(source: .calendar, botID: "bot-a")
        let recorder = A08WakeRecorder()
        await registry.setWakeHandler { wake in
            Task { await recorder.record(wake) }
        }
        return (registry, ledger, fake, recorder)
    }

    /// Material, wake and recheck paths after revoke must not touch the
    /// provider. The only allowed call is the stop performed by revoke itself.
    func testRevokedMaterialWakeAndRecheckCallProviderZeroTimes() async throws {
        let (registry, ledger, fake, wakeRecorder) = try await make()
        let initial = try await fake.observation(
            id: "old-generation", observedAt: 7_000_001, wakeRequested: true)
        await fake.emit(initial)
        for _ in 0..<50 {
            let view = await registry.observationView(for: "bot-a", sources: [.calendar])
            if view.items.contains(where: { $0.state == .active }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await registry.revoke(source: .calendar, reason: "user-revoked")
        let before = await fake.counts()
        let wakesBefore = await wakeRecorder.count()

        // Material read: must fail and not invoke the adapter.
        do {
            _ = try await registry.observations(for: "bot-a", sources: [.calendar])
            XCTFail("revoked material read must fail")
        } catch {
            XCTAssertEqual(error as? BotContextSourceError, .revoked(.calendar))
        }
        let view = await registry.observationView(for: "bot-a", sources: [.calendar])
        XCTAssertFalse(view.items.contains { $0.state == .active })
        XCTAssertTrue(view.items.allSatisfy { $0.state == .inactive })

        // Recheck path: the registry gate L calls must return revoked without
        // touching the provider.
        let rechecks = await registry.recheck(botID: "bot-a", sources: [.calendar])
        XCTAssertEqual(rechecks.first?.state, .revoked)

        // Wake/decision path: a revoked source yields no active observation and
        // therefore runs zero decision turns.
        let runner = A08DecisionRunner()
        let engine = BotContextWakeDecisionEngine(
            context: A08DecisionContext(registry: registry, ledger: ledger),
            now: now,
            runner: { request in await runner.run(request) })
        let outcome = await engine.handle(
            botID: "bot-a", reason: "context:calendar:calendar.changed", at: now())
        XCTAssertEqual(outcome, .skipped(reason: "not-authorized"))
        let decisionRuns = await runner.count()
        XCTAssertEqual(decisionRuns, 0)
        let wakeCount = await wakeRecorder.count()
        XCTAssertEqual(wakeCount, wakesBefore)

        let after = await fake.counts()
        XCTAssertEqual(after.reads, before.reads)
        XCTAssertEqual(after.rechecks, before.rechecks)
        XCTAssertEqual(after.start, before.start)
        XCTAssertEqual(after.request, before.request)
        XCTAssertEqual(after.stop, before.stop, "revoke already stopped once; nothing else may stop it")
    }

    /// Legal re-consent advances generation; the old observation is not
    /// replayed and only a fresh-generation observation is readable.
    func testReconsentFreshGenerationOnlyAndOldNotReplayed() async throws {
        let (registry, ledger, fake, _) = try await make()
        let old = try await fake.observation(id: "generation-1", observedAt: 7_000_001)
        await fake.emit(old)
        await registry.revoke(source: .calendar, reason: "user-revoked")
        _ = try await registry.requestConsent(source: .calendar, botID: "bot-a")
        let current = await ledger.state(for: .calendar)
        let state = try XCTUnwrap(current)
        XCTAssertEqual(state.authorization, .authorized)
        XCTAssertEqual(state.permissionRevision, 3)
        let fresh = try await fake.observation(
            id: "generation-3", observedAt: 7_000_003)
        await fake.emit(fresh)
        var received: [BotContextObservation] = []
        for _ in 0..<50 {
            received = try await registry.observations(for: "bot-a", sources: [.calendar])
            if !received.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(received.map(\.id), ["generation-3"])
        XCTAssertFalse(received.contains { $0.id == old.id })
        let counts = await fake.counts()
        XCTAssertEqual(counts.start, 2, "one start per authorization generation")
    }
}
