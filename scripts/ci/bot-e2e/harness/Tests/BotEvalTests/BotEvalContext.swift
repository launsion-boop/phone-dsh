// SPDX-License-Identifier: MIT
// phone-dsh Bot eval runner — per-repeat state shared by the action executor.

import Foundation
@testable import BotEvalApp
import PhoneDSH
import PhoneDSHBot
import PhoneDSHHarness

@MainActor
final class EvalRunContext {
    let scenario: EvalScenario
    let plan: EvalPlan
    let composition: BotRuntimeComposition
    let host: PhoneDSHHost
    let store: SQLiteDomainStore
    let mock: MockModelUpstream?
    let credentialProvider: EvalModelCredentialProvider
    let workspaceRoot: URL
    let resultsDirectory: URL
    let fixturesRoot: URL
    let transcript: EvalJSONLWriter
    let botEvents: EvalJSONLWriter
    let redactor: (String) -> String
    let deferredSeeds: [EvalSeed]
    let schedulerClock: EvalSchedulerClock

    var aliases: [String: String] = [:]
    var policy = EvalApprovalPolicy(defaultDecision: "manual", rules: [])
    private var turnCounters: [String: Int] = [:]
    var replies: [EvalReply] = []
    private(set) var autoDecisions: [String] = []
    let mainBotID: String

    init(scenario: EvalScenario, plan: EvalPlan, composition: BotRuntimeComposition,
         host: PhoneDSHHost, store: SQLiteDomainStore, mock: MockModelUpstream?,
         credentialProvider: EvalModelCredentialProvider, workspaceRoot: URL,
         resultsDirectory: URL, fixturesRoot: URL, transcript: EvalJSONLWriter,
         botEvents: EvalJSONLWriter, redactor: @escaping (String) -> String,
         deferredSeeds: [EvalSeed], schedulerClock: EvalSchedulerClock) {
        self.scenario = scenario
        self.plan = plan
        self.composition = composition
        self.host = host
        self.store = store
        self.mock = mock
        self.credentialProvider = credentialProvider
        self.workspaceRoot = workspaceRoot
        self.resultsDirectory = resultsDirectory
        self.fixturesRoot = fixturesRoot
        self.transcript = transcript
        self.botEvents = botEvents
        self.redactor = redactor
        self.deferredSeeds = deferredSeeds
        self.schedulerClock = schedulerClock
        self.mainBotID = composition.rosterModel.mainBotID
            ?? composition.rosterModel.bots.first?.id
            ?? "main"
    }

    var knownBotIDs: [String] {
        var ids = [mainBotID]
        ids.append(contentsOf: composition.rosterModel.bots.map { $0.id })
        ids.append(contentsOf: aliases.values)
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    func botID(for raw: String?) throws -> String {
        let name = raw ?? "main"
        if name == "main" { return mainBotID }
        if let id = aliases[name] { return id }
        throw EvalRunnerError.invalid("unknown bot \(name)")
    }

    func unit(for botID: String) async throws -> BotRuntimeUnit {
        try await composition.ensureUnit(for: botID, reason: "eval")
    }

    func nextTurn(_ botID: String) -> Int {
        let next = (turnCounters[botID] ?? 0) + 1
        turnCounters[botID] = next
        return next
    }

    func actionTimeout(_ action: EvalAction) -> TimeInterval {
        action.timeoutS ?? scenario.timeoutS
    }

    func nonce(_ kind: String, action: EvalAction, repeat index: Int) -> String {
        let raw = "bot-eval:\(scenario.id):\(index):\(action.index ?? 0):\(kind)"
        let safe = raw.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar)
                || "-_.:".unicodeScalars.contains(scalar) {
                return Character(String(scalar))
            }
            return "_"
        }
        return String(safe)
    }

    func installMock(_ mock: EvalMock?) {
        self.mock?.script = EvalMockScripts.script(for: mock)
    }

    func lastCommitSeq() async throws -> Int {
        let events = try await BotProductionEventReader.all(domain: store)
        return events.last?.commitSeq ?? 0
    }

    func replies(after cursor: Int, botID: String, turn: Int,
                 action: EvalAction, repeat index: Int) async throws -> [EvalReply] {
        let events = try await BotProductionEventReader.all(domain: store)
        let fresh = events.filter { ($0.commitSeq ?? 0) > cursor }
        var result: [EvalReply] = []
        for event in fresh where event.type == "conversation.assistant_message" {
            guard event.principal.botId == botID,
                  let text = event.data["text"]?.stringValue, !text.isEmpty else { continue }
            result.append(EvalReply(
                botID: botID, text: text, turnNumber: turn,
                actionIndex: action.index ?? 0))
        }
        return result
    }

    /// One polling task per model action. It is canceled as soon as the action
    /// returns, so a policy cannot silently decide an approval from a later
    /// action.
    func startApprovalWatcher() -> Task<Void, Never> {
        let policy = self.policy
        let policyBot = policy.bot.flatMap { try? self.botID(for: $0) }
        return Task { @MainActor [weak self] in
            guard let self else { return }
            var handled = Set<String>()
            while !Task.isCancelled {
                let pending = await self.composition.runtime.approvals.pendingIDs
                if !pending.isEmpty {
                    let events = (try? await BotProductionEventReader.all(domain: self.store)) ?? []
                    let requested = events.filter { $0.type == "approval.requested" }
                    for id in pending where !handled.contains(id) {
                        guard let event = requested.last(where: {
                            $0.data["approvalID"]?.stringValue == id
                        }), let digest = await self.composition.runtime.approvals.pendingDigest(
                            approvalId: id) else { continue }
                        let tool = event.data["effects"]?.arrayValue?.first?
                            .objectValue?["tool"]?.stringValue ?? ""
                        guard let decision = policy.decide(tool: tool) else { continue }
                        handled.insert(id)
                        let botID = event.principal.botId ?? self.mainBotID
                        if let policyBot, botID != policyBot { continue }
                        guard let unit = try? await self.composition.ensureUnit(
                            for: botID, reason: "eval-approval") else { continue }
                        let result = try? await unit.rows.perform(BotUserAction(
                            nonce: "bot-eval-auto-\(id)", botID: botID, kind: .approval,
                            approvalID: id, decision: decision, digest: digest))
                        let allowed = result?.status ?? "failed"
                        self.autoDecisions.append("\(tool.isEmpty ? "unknown" : tool): \(allowed)")
                    }
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }
}

extension EvalApprovalPolicy {
    func decide(tool: String) -> BotApprovalDecision? {
        for rule in rules {
            if rule.tool == nil || rule.tool == tool || Self.bare(rule.tool ?? "") == Self.bare(tool) {
                return Self.map(rule.decision)
            }
        }
        return Self.map(defaultDecision)
    }

    private static func map(_ raw: String) -> BotApprovalDecision? {
        switch raw {
        case "allow_once": return .allowOnce
        case "always": return .always
        case "deny": return .deny
        default: return nil
        }
    }

    private static func bare(_ value: String) -> String {
        value.split(separator: "__").last.map(String.init) ?? value
    }
}
