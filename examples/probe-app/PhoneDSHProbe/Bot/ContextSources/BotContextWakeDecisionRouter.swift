// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHBot

/// App-side wrapper over the testable package decision engine. It only adapts
/// the one `BotContextSourcesAssembly` (live consent/read view) and the Bot
/// unit's hidden routine runner; all bounds/dedupe/silence logic lives in
/// `BotContextWakeDecisionEngine`.
struct BotContextSourcesDecisionContext: BotContextWakeDecisionContextProviding {
    let assembly: BotContextSourcesAssembly

    func isStarted() async -> Bool {
        await assembly.isStarted()
    }

    func authorization(for source: BotContextSourceKind) async -> BotSourceAuthorizationState? {
        await assembly.authorization(for: source)
    }

    func activeObservation(botID: String, source: BotContextSourceKind,
                           kind: BotContextObservationKind) async -> BotContextObservationViewItem? {
        let view = await assembly.observationView(for: botID, sources: [source])
        return view.items.first { $0.state == .active && $0.kind == kind.rawValue }
    }
}

@MainActor
final class BotContextWakeDecisionRouter {
    typealias Runner = @Sendable (RoutineRunRequest) async -> RoutineExecutionResult

    private let engine: BotContextWakeDecisionEngine

    init(assembly: BotContextSourcesAssembly,
         now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
         runner: @escaping Runner) {
        engine = BotContextWakeDecisionEngine(
            context: BotContextSourcesDecisionContext(assembly: assembly),
            now: now, runner: runner)
    }

    @discardableResult
    func handle(_ signal: WakeSignal) async -> BotContextWakeDecisionOutcome {
        await engine.handle(botID: signal.botId, reason: signal.reason, at: signal.at)
    }

    func recentOutcomes() async -> [(at: Int64, outcome: BotContextWakeDecisionOutcome)] {
        await engine.recentOutcomes
    }
}
