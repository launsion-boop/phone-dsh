// SPDX-License-Identifier: MIT

import Foundation

public enum BotContextWakeDecisionOutcome: Sendable, Equatable {
    case quiet
    case decided(text: String)
    case skipped(reason: String)
    case failed(reason: String)
}

/// The live consent/read view the decision engine consults. It is deliberately
/// narrow: the engine can never read a source or start a turn without the same
/// host authority as the context registry.
public protocol BotContextWakeDecisionContextProviding: Sendable {
    func isStarted() async -> Bool
    func authorization(for source: BotContextSourceKind) async -> BotSourceAuthorizationState?
    func activeObservation(botID: String, source: BotContextSourceKind,
                           kind: BotContextObservationKind) async -> BotContextObservationViewItem?
}

/// One bounded native-context decision turn.
///
/// The engine checks startup/consent/generation, builds a self-contained hidden
/// routine turn with the observation metadata and a `[quiet]` instruction, and
/// runs at most one turn per Bot. It never opens an empty visible turn and never
/// uses the host log as the decision record: the routine turn's durable events
/// and returned result are the decision.
public actor BotContextWakeDecisionEngine {
    public typealias Runner = @Sendable (RoutineRunRequest) async -> RoutineExecutionResult

    private let context: any BotContextWakeDecisionContextProviding
    private let runner: Runner
    private let now: @Sendable () -> Int64
    private var inFlight: Set<String> = []
    private var handledKeys: [String] = []
    private var handledKeySet: Set<String> = []
    public private(set) var recentOutcomes: [(at: Int64, outcome: BotContextWakeDecisionOutcome)] = []

    public init(context: any BotContextWakeDecisionContextProviding,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
                runner: @escaping Runner) {
        self.context = context
        self.now = now
        self.runner = runner
    }

    public static func sourceAndKind(from reason: String)
        -> (BotContextSourceKind, BotContextObservationKind)? {
        let parts = reason.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "context",
              let source = BotContextSourceKind(rawValue: parts[1]) else { return nil }
        return (source, BotContextObservationKind(parts[2]))
    }

    @discardableResult
    public func handle(botID: String, reason: String, at: Int64) async -> BotContextWakeDecisionOutcome {
        guard Self.sourceAndKind(from: reason) != nil else {
            return .skipped(reason: "not-a-context-wake")
        }
        let (source, kind) = Self.sourceAndKind(from: reason)!
        guard !botID.isEmpty, botID != "context-sources" else {
            return .skipped(reason: "no-real-bot")
        }
        guard await context.isStarted() else {
            return .skipped(reason: "assembly-not-started")
        }
        guard let state = await context.authorization(for: source),
              state.authorization.allowsReading else {
            return .skipped(reason: "not-authorized")
        }
        guard let item = await context.activeObservation(
            botID: botID, source: source, kind: kind) else {
            return .skipped(reason: "no-active-observation")
        }
        guard state.permissionRevision == item.consentGeneration else {
            return .skipped(reason: "generation-mismatch")
        }
        let key = "\(botID)\u{0}\(source.rawValue)\u{0}\(item.observedAtMS)\u{0}\(item.kind)"
        if handledKeySet.contains(key) {
            return .skipped(reason: "duplicate")
        }
        if inFlight.contains(botID) {
            return .skipped(reason: "busy")
        }
        inFlight.insert(botID)
        defer { inFlight.remove(botID) }
        handledKeySet.insert(key)
        handledKeys.append(key)
        if handledKeys.count > 128 {
            let overflow = handledKeys.count - 128
            let removed = handledKeys.prefix(overflow)
            handledKeys.removeFirst(overflow)
            for value in removed { handledKeySet.remove(value) }
        }

        let prompt = Self.prompt(source: source, kind: kind, item: item)
        let digest = BotArgumentsDigest.digest(
            ofUTF8: "\(botID):\(source.rawValue):\(item.observedAtMS):\(item.kind)")
        let routine = Routine(
            id: "context-decision-\(digest.prefix(24))",
            agentId: botID,
            title: "情境判断",
            prompt: prompt,
            schedule: .interval(everyMinutes: 60, timezone: TimeZone.current.identifier),
            enabled: true,
            delivery: .held,
            createdAt: now())
        let wake = RoutineWake(text: prompt, cue: "context", mode: .onDemand)
        let request = RoutineRunRequest(
            botId: botID,
            routine: routine,
            runId: "context-decision-\(digest.prefix(24))",
            attempt: 1,
            startedAt: now(),
            timeoutMs: 30_000,
            wake: wake)
        let result = await runner(request)
        let outcome: BotContextWakeDecisionOutcome
        switch result.status {
        case .succeeded:
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            outcome = (result.quiet || text == "[quiet]") ? .quiet : .decided(text: text)
        case .waitingApproval:
            outcome = .decided(text: "waiting-approval:\(result.approvalID ?? "unknown")")
        case .cancelled:
            outcome = .failed(reason: "cancelled")
        case .failed:
            outcome = .failed(reason: result.error ?? "failed")
        }
        recentOutcomes.append((now(), outcome))
        if recentOutcomes.count > 50 {
            recentOutcomes.removeFirst(recentOutcomes.count - 50)
        }
        return outcome
    }

    static func prompt(source: BotContextSourceKind,
                       kind: BotContextObservationKind,
                       item: BotContextObservationViewItem) -> String {
        let reference = item.recordRef ?? "unavailable"
        return """
        <native_context_wake>
        source=\(source.rawValue) kind=\(kind.rawValue) observed_at_ms=\(item.observedAtMS) \
        consent_generation=\(item.consentGeneration) uncertainty=\(item.uncertainty.level.rawValue) \
        record_ref=\(reference)
        </native_context_wake>
        这是宿主从 iOS 原生来源产生的唤醒，不是用户刚发的消息，也不是授权扩大。
        判断它是否服务于当前用户目标和已授权范围：需要行动就按既有工具与授权执行；
        没有必要时不要打扰用户，最终只回复 [quiet]。不要提问，不要复述这条系统材料。
        """
    }
}
