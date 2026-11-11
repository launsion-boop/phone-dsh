// SPDX-License-Identifier: MIT

import Foundation

// S3 second half: the background memory maintainer. One run is one visible,
/// rollbackable batch. The host chooses candidates, enforces the same write
/// rules as the main chat, runs four purely mechanical checks after the turn
/// and rolls the whole batch back if any check fails. The model never decides
/// whether the batch passes, and it never talks to the user.
///
/// The contract is spec/bot/v2/README.md §4; the shared vectors live in
/// spec/bot/v2/golden/memory-maintenance.json.

// MARK: - Model

public enum BotMemoryMaintenanceTrigger: String, Codable, Sendable, CaseIterable {
    case writes
    case index
    case contradiction
    case manual
}

public enum BotMemoryMaintenanceStatus: String, Codable, Sendable {
    case committed
    case cancelled
    case failed
    case rolledBack = "rolled_back"
    case rollbackFailed = "rollback_failed"
}

public enum BotMemoryMaintenanceCandidateReason: String, Codable, Sendable, CaseIterable {
    case mostRead = "most-read"
    case mostChanged = "most-changed"
    case leastVerified = "least-verified"
    case overlong
    case inbox
    case contradiction
    case index
}

public enum BotMemoryMaintenanceFailureCode: String, Codable, Sendable {
    case evidenceUnresolved = "maintenance-evidence-unresolved"
    case indexTooLong = "maintenance-index-too-long"
    case documentLongerThanEvidence = "maintenance-document-longer-than-evidence"
    case changeBudgetExceeded = "maintenance-change-budget-exceeded"
    case budgetExceeded = "maintenance-budget-exceeded"
    case rollbackConflict = "maintenance-rollback-conflict"
}

public struct BotMemoryMaintenanceCandidate: Codable, Sendable, Equatable {
    public var path: String
    public var reasons: [BotMemoryMaintenanceCandidateReason]

    public init(path: String, reasons: [BotMemoryMaintenanceCandidateReason]) {
        self.path = path
        self.reasons = Array(Set(reasons)).sorted { $0.rawValue < $1.rawValue }
    }

    enum CodingKeys: String, CodingKey {
        case path, reasons
    }
}

public struct BotMemoryMaintenanceChange: Codable, Sendable, Equatable {
    public var path: String
    public var scope: BotMemoryScope
    public var beforeVersion: Int
    public var afterVersion: Int
    public var deleted: Bool

    public init(path: String, scope: BotMemoryScope, beforeVersion: Int,
                afterVersion: Int, deleted: Bool) {
        self.path = path
        self.scope = scope
        self.beforeVersion = beforeVersion
        self.afterVersion = afterVersion
        self.deleted = deleted
    }

    enum CodingKeys: String, CodingKey {
        case path, scope, deleted
        case beforeVersion = "before_version"
        case afterVersion = "after_version"
    }
}

public struct BotMemoryMaintenanceChecks: Codable, Sendable, Equatable {
    public var referencesResolve: Bool
    public var indexWithinLimit: Bool
    public var documentsNotLongerThanEvidence: Bool
    public var changeBudgetWithinLimit: Bool

    public init(referencesResolve: Bool, indexWithinLimit: Bool,
                documentsNotLongerThanEvidence: Bool, changeBudgetWithinLimit: Bool) {
        self.referencesResolve = referencesResolve
        self.indexWithinLimit = indexWithinLimit
        self.documentsNotLongerThanEvidence = documentsNotLongerThanEvidence
        self.changeBudgetWithinLimit = changeBudgetWithinLimit
    }

    public static let passed = Self(
        referencesResolve: true, indexWithinLimit: true,
        documentsNotLongerThanEvidence: true, changeBudgetWithinLimit: true)

    public var passedAll: Bool {
        referencesResolve && indexWithinLimit
            && documentsNotLongerThanEvidence && changeBudgetWithinLimit
    }

    enum CodingKeys: String, CodingKey {
        case referencesResolve = "references_resolve"
        case indexWithinLimit = "index_within_limit"
        case documentsNotLongerThanEvidence = "documents_not_longer_than_evidence"
        case changeBudgetWithinLimit = "change_budget_within_limit"
    }
}

public struct BotMemoryMaintenanceBudget: Codable, Sendable, Equatable {
    public var runTokens: Int
    public var dailyTokens: Int
    public var tokensUsed: Int
    public var changedDocuments: Int
    public var changedScalars: Int

    public init(runTokens: Int, dailyTokens: Int, tokensUsed: Int = 0,
                changedDocuments: Int = 0, changedScalars: Int = 0) {
        self.runTokens = runTokens
        self.dailyTokens = dailyTokens
        self.tokensUsed = tokensUsed
        self.changedDocuments = changedDocuments
        self.changedScalars = changedScalars
    }

    enum CodingKeys: String, CodingKey {
        case runTokens = "run_tokens"
        case dailyTokens = "daily_tokens"
        case tokensUsed = "tokens_used"
        case changedDocuments = "changed_documents"
        case changedScalars = "changed_scalars"
    }
}

/// Read-only view of the shared daily maintenance budget for the memory page.
/// Spend comes from the LLM ledger under `memory-maintenance`, never from the
/// model's self-report.
public struct BotMemoryMaintenanceBudgetStatus: Sendable, Equatable {
    public var dailyTokensUsed: Int
    public var dailyTokenLimit: Int

    public init(dailyTokensUsed: Int, dailyTokenLimit: Int) {
        self.dailyTokensUsed = max(0, dailyTokensUsed)
        self.dailyTokenLimit = max(1, dailyTokenLimit)
    }

    public var exhausted: Bool { dailyTokensUsed >= dailyTokenLimit }
}

public struct BotMemoryMaintenanceStartBudget: Codable, Sendable, Equatable {
    public var runTokens: Int
    public var dailyTokens: Int

    public init(runTokens: Int, dailyTokens: Int) {
        self.runTokens = runTokens
        self.dailyTokens = dailyTokens
    }

    enum CodingKeys: String, CodingKey {
        case runTokens = "run_tokens"
        case dailyTokens = "daily_tokens"
    }
}

public struct BotMemoryMaintenanceStart: Codable, Sendable, Equatable {
    public var batchID: String
    public var botID: String
    public var trigger: BotMemoryMaintenanceTrigger
    public var startedAtMS: Int64
    public var maintainerSessionID: String
    public var candidates: [BotMemoryMaintenanceCandidate]
    public var budget: BotMemoryMaintenanceStartBudget

    public init(batchID: String, botID: String, trigger: BotMemoryMaintenanceTrigger,
                startedAtMS: Int64, maintainerSessionID: String,
                candidates: [BotMemoryMaintenanceCandidate],
                budget: BotMemoryMaintenanceStartBudget) {
        self.batchID = batchID
        self.botID = botID
        self.trigger = trigger
        self.startedAtMS = startedAtMS
        self.maintainerSessionID = maintainerSessionID
        self.candidates = candidates
        self.budget = budget
    }

    enum CodingKeys: String, CodingKey {
        case batchID = "batch_id"
        case botID = "bot_id"
        case trigger
        case startedAtMS = "started_at_ms"
        case maintainerSessionID = "maintainer_session_id"
        case candidates, budget
    }
}

public struct BotMemoryMaintenanceBatch: Codable, Sendable, Equatable {
    public var batchID: String
    public var botID: String
    public var status: BotMemoryMaintenanceStatus
    public var trigger: BotMemoryMaintenanceTrigger
    public var startedAtMS: Int64
    public var finishedAtMS: Int64
    public var maintainerSessionID: String
    public var changes: [BotMemoryMaintenanceChange]
    public var checks: BotMemoryMaintenanceChecks
    public var budget: BotMemoryMaintenanceBudget
    public var failureCode: String?
    public var notification: Bool
    public var userScopeOwner: Bool

    public init(batchID: String, botID: String, status: BotMemoryMaintenanceStatus,
                trigger: BotMemoryMaintenanceTrigger, startedAtMS: Int64,
                finishedAtMS: Int64, maintainerSessionID: String,
                changes: [BotMemoryMaintenanceChange],
                checks: BotMemoryMaintenanceChecks,
                budget: BotMemoryMaintenanceBudget, failureCode: String?,
                notification: Bool, userScopeOwner: Bool) {
        self.batchID = batchID
        self.botID = botID
        self.status = status
        self.trigger = trigger
        self.startedAtMS = startedAtMS
        self.finishedAtMS = finishedAtMS
        self.maintainerSessionID = maintainerSessionID
        self.changes = changes
        self.checks = checks
        self.budget = budget
        self.failureCode = failureCode
        self.notification = notification
        self.userScopeOwner = userScopeOwner
    }

    enum CodingKeys: String, CodingKey {
        case batchID = "batch_id"
        case botID = "bot_id"
        case status, trigger, changes, checks, budget, notification
        case startedAtMS = "started_at_ms"
        case finishedAtMS = "finished_at_ms"
        case maintainerSessionID = "maintainer_session_id"
        case failureCode = "failure_code"
        case userScopeOwner = "user_scope_owner"
    }
}

public struct BotMemoryMaintenanceRestore: Codable, Sendable, Equatable {
    public var path: String
    public var fromVersion: Int
    public var toVersion: Int

    public init(path: String, fromVersion: Int, toVersion: Int) {
        self.path = path
        self.fromVersion = fromVersion
        self.toVersion = toVersion
    }

    enum CodingKeys: String, CodingKey {
        case path
        case fromVersion = "from_version"
        case toVersion = "to_version"
    }
}

public struct BotMemoryMaintenanceRollback: Codable, Sendable, Equatable {
    public var batchID: String
    public var botID: String
    public var rolledBackAtMS: Int64
    public var restored: [BotMemoryMaintenanceRestore]
    public var conflicts: [String]

    public init(batchID: String, botID: String, rolledBackAtMS: Int64,
                restored: [BotMemoryMaintenanceRestore], conflicts: [String]) {
        self.batchID = batchID
        self.botID = botID
        self.rolledBackAtMS = rolledBackAtMS
        self.restored = restored
        self.conflicts = conflicts
    }

    enum CodingKeys: String, CodingKey {
        case batchID = "batch_id"
        case botID = "bot_id"
        case rolledBackAtMS = "rolled_back_at_ms"
        case restored, conflicts
    }
}

/// What the memory page reads: the batch plus any later rollback record.
public struct BotMemoryMaintenanceBatchView: Sendable, Equatable {
    public var batch: BotMemoryMaintenanceBatch
    public var rollback: BotMemoryMaintenanceRollback?

    public init(batch: BotMemoryMaintenanceBatch,
                rollback: BotMemoryMaintenanceRollback? = nil) {
        self.batch = batch
        self.rollback = rollback
    }

    public var isRolledBack: Bool {
        rollback != nil || batch.status == .rolledBack || batch.status == .rollbackFailed
    }

    public var canRollback: Bool {
        rollback == nil && !batch.changes.isEmpty
            && (batch.status == .committed || batch.status == .cancelled
                || batch.status == .failed)
    }
}

// MARK: - Settings (P18 key)

public struct BotMemoryMaintenanceSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var runTokenBudget: Int
    public var dailyTokenBudget: Int

    public init(enabled: Bool = false, runTokenBudget: Int = 32_000,
                dailyTokenBudget: Int = 96_000) {
        self.enabled = enabled
        self.runTokenBudget = max(1, runTokenBudget)
        self.dailyTokenBudget = max(1, dailyTokenBudget)
    }

    public static let standard = Self()
    /// All Bots share this one switch; documented in spec/bot/v2 §4.8.
    public static let defaultsKey = "phone-dsh.bot.memory-maintenance.v1"

    enum CodingKeys: String, CodingKey {
        case enabled
        case runTokenBudget = "runTokenBudget"
        case dailyTokenBudget = "dailyTokenBudget"
    }
}

public final class BotMemoryMaintenanceSettingsStore: @unchecked Sendable {
    public static let shared = BotMemoryMaintenanceSettingsStore()

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard,
                key: String = BotMemoryMaintenanceSettings.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    public func settings() -> BotMemoryMaintenanceSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(
                BotMemoryMaintenanceSettings.self, from: data) else {
            return .standard
        }
        return BotMemoryMaintenanceSettings(
            enabled: decoded.enabled,
            runTokenBudget: max(1, decoded.runTokenBudget),
            dailyTokenBudget: max(1, decoded.dailyTokenBudget))
    }

    public func save(_ settings: BotMemoryMaintenanceSettings) {
        let normalized = BotMemoryMaintenanceSettings(
            enabled: settings.enabled,
            runTokenBudget: max(1, settings.runTokenBudget),
            dailyTokenBudget: max(1, settings.dailyTokenBudget))
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        defaults.set(data, forKey: key)
    }
}

// MARK: - Record reading

/// The two record capabilities the mechanical checks need. `BotRecordService`
/// conforms in this file; tests can provide a deterministic double.
public protocol BotMemoryMaintenanceRecordReading: Sendable {
    func resolveEvidence(_ references: [String], callerBotID: String,
                         callerSessionID: String) async throws -> BotRecordEvidence
    /// Canonical readable text of one record, used only for the
    /// "document not longer than its evidence" check.
    func recordText(_ reference: String, callerSessionID: String) async throws -> String
}

extension BotRecordService: BotMemoryMaintenanceRecordReading {
    /// Reads one reference through the same read-only command the agent uses.
    /// Output is JSON (`{"ok":true,"data":{"lines":[{"raw":…}]}}`); the raw
    /// line is the record's original JSON. The caller session must be claimed.
    public func recordText(_ reference: String, callerSessionID: String) async throws -> String {
        let output = await execute(
            arguments: ["read", reference, "--around", "0"],
            callerSessionID: callerSessionID)
        guard output.exitCode == 0,
              let data = output.stdout.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let lines = payload["lines"] as? [[String: Any]],
              let raw = lines.first?["raw"] as? String else {
            throw BotMemoryMaintenanceError.recordUnavailable(reference)
        }
        return BotMemoryMaintenanceText.readableText(raw: raw)
    }
}

/// The one host seam the controller needs. `BotDSHRemoteRuntime` implements it;
/// unit tests use a deterministic fake that performs memory writes directly.
public protocol BotMemoryMaintenanceTurnRunning: Sendable {
    func ensureMaintenanceSession() async throws -> String
    func runMaintenanceTurn(prompt: String, batchID: String) async throws -> BotRemoteTurnResult
    func cancelMaintenanceTurn() async
    func mainTurnIsBusy() async -> Bool
}

extension BotDSHRemoteRuntime: BotMemoryMaintenanceTurnRunning {
    public func mainTurnIsBusy() async -> Bool { isMainTurnBusy() }
}

public enum BotMemoryMaintenanceError: Error, Sendable, Equatable, CustomStringConvertible {
    case recordUnavailable(String)
    case alreadyRunning(String)

    public var description: String {
        switch self {
        case .recordUnavailable(let reference):
            return "record text is unavailable for \(reference)"
        case .alreadyRunning(let batchID):
            return "a maintenance batch is already running: \(batchID)"
        }
    }
}

enum BotMemoryMaintenanceText {
    static func scalarCount(_ text: String) -> Int {
        text.unicodeScalars.count
    }

    /// Extract the human-readable part of a record line. Prefers message text
    /// blocks, then plain text fields, then falls back to the canonical JSON of
    /// `data` so the check still has a stable upper bound.
    static func readableText(raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return raw
        }
        let payload = (object["data"] as? [String: Any]) ?? object
        if let blocks = payload["content"] as? [[String: Any]] {
            let text = blocks.compactMap { block -> String? in
                block["type"] as? String == "text" ? block["text"] as? String : nil
            }.joined()
            if !text.isEmpty { return text }
        }
        if let message = payload["message"] as? [String: Any] {
            if let blocks = message["content"] as? [[String: Any]] {
                let text = blocks.compactMap { block -> String? in
                    block["type"] as? String == "text" ? block["text"] as? String : nil
                }.joined()
                if !text.isEmpty { return text }
            }
            if let text = message["text"] as? String, !text.isEmpty { return text }
        }
        if let text = payload["text"] as? String, !text.isEmpty { return text }
        if let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return raw
    }

    /// Host-built maintainer prompt. Terminal states only: no step-by-step
    /// process. Candidate paths are domain-constrained memory paths and are
    /// embedded literally; the preset carries the static rules.
    static func prompt(
        batchID: String,
        botID: String,
        candidates: [BotMemoryMaintenanceCandidate],
        trigger: BotMemoryMaintenanceTrigger,
        settings: BotMemoryMaintenanceSettings,
        userScopeOwner: Bool
    ) -> String {
        let candidateLines = candidates.map { candidate in
            "- \(candidate.path)（\(candidate.reasons.map(\.rawValue).joined(separator: "、"))）"
        }.joined(separator: "\n")
        let userRoot = userScopeOwner
            ? "可以整理 user/，但写 user/ 的每次写入必须带至少一条指向用户本人消息的 record:// 引用。"
            : "你是非主 Bot：只整理 agent/，user/ 只读，写入 user/ 会被拒绝。"
        return """
        这次后台整理是一个批次：\(batchID)。只处理下面这些候选，不要全量扫描记忆。

        候选：
        \(candidateLines.isEmpty ? "- （没有候选；只做一致性核验）" : candidateLines)

        触发原因：\(trigger.rawValue)。单次预算：\(settings.runTokenBudget) token；每日预算：\(settings.dailyTokensDescription)。
        \(userRoot)

        交给你的终态，不是步骤：
        - 记忆与原始记录一致；过时或冲突的内容已修正。
        - 判断不了的明确标为不确定，并在文档里保留两种说法和各自的记录引用。
        - 索引在 1,500 字以内；细节下沉到文档。
        - 上次整理以来记录里出现过、没记下来、以后不会再出现的东西，已补上。
        - agent/inbox/ 里的 Task 和 routine 提交已合入（或明确丢弃）。

        写记忆和普通回合相同：每次 UpdateMemory 都带刚读到的 expected_version；信任由引用推导；
        写 user/ 需要用户消息引用。版本冲突就放弃这一份，下次再看，不要重试同一条。
        可以用 bash 的 `phone record search` / `phone record read` 查看原始记录；不要调用其他工具。
        不要给用户发消息，不要派 Task，不要改 routine；结束时只写一句你实际完成的结果。
        """
    }
}

extension BotMemoryMaintenanceSettings {
    var dailyTokensDescription: String { "\(dailyTokenBudget) token" }
}

// MARK: - Controller

/// One Bot's maintainer: candidate selection, triggers, budget, the hidden
/// turn, the four mechanical checks, batch rollback and the one-line held
/// notice. The controller is an actor; a run is serialized by `activeBatchID`.
public actor BotMemoryMaintenanceController {
    public static let maximumCandidates = 12
    public static let maximumChangedDocuments = 12
    public static let maximumChangedScalars = 24_000
    public static let writesTrigger = 40
    public static let indexTriggerScalars = 1_350
    public static let overlongDocumentScalars = 4_000
    /// Quiet time after a main-chat turn before the app-alive opportunity.
    public static let quietIntervalMilliseconds: Int64 = 60_000

    private let store: SQLiteDomainStore
    private let botID: String
    private let memory: BotMemory
    private let runtime: BotMCPRuntime
    private let remote: any BotMemoryMaintenanceTurnRunning
    private let settingsStore: BotMemoryMaintenanceSettingsStore
    private let recordReading: (any BotMemoryMaintenanceRecordReading)?
    private let isMainBot: @Sendable () -> Bool
    private let isAppActive: @Sendable () -> Bool
    private let notify: @Sendable (String) async -> Void
    private let now: @Sendable () -> Int64

    private var activeBatchID: String?
    private var quietTask: Task<Void, Never>?

    public init(
        store: SQLiteDomainStore,
        botID: String,
        memory: BotMemory,
        runtime: BotMCPRuntime,
        remote: any BotMemoryMaintenanceTurnRunning,
        settingsStore: BotMemoryMaintenanceSettingsStore = .shared,
        recordReading: (any BotMemoryMaintenanceRecordReading)? = nil,
        isMainBot: @escaping @Sendable () -> Bool = { true },
        isAppActive: @escaping @Sendable () -> Bool = { true },
        notify: @escaping @Sendable (String) async -> Void = { _ in },
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) {
        self.store = store
        self.botID = botID
        self.memory = memory
        self.runtime = runtime
        self.remote = remote
        self.settingsStore = settingsStore
        self.recordReading = recordReading
        self.isMainBot = isMainBot
        self.isAppActive = isAppActive
        self.notify = notify
        self.now = now
    }

    // MARK: Settings and history

    public func settings() -> BotMemoryMaintenanceSettings {
        settingsStore.settings()
    }

    public func saveSettings(_ settings: BotMemoryMaintenanceSettings) {
        settingsStore.save(settings)
    }

    public func setEnabled(_ enabled: Bool) {
        var settings = settingsStore.settings()
        settings.enabled = enabled
        settingsStore.save(settings)
    }

    /// Daily spend for this Bot's maintenance purpose. The switch is shared,
    /// but each Bot's daily budget is its own (spec/bot/v2 §4.6).
    public func budgetStatus() async -> BotMemoryMaintenanceBudgetStatus {
        let settings = settingsStore.settings()
        let usage = await budgetUsage(sessionID: "", since: 0, now: now())
        return BotMemoryMaintenanceBudgetStatus(
            dailyTokensUsed: usage.daily,
            dailyTokenLimit: settings.dailyTokenBudget)
    }

    public func lastBatch() async throws -> BotMemoryMaintenanceBatchView? {
        let events = try await allEvents()
        let batches = Self.batches(in: events)
        guard let newest = batches.last else { return nil }
        return Self.view(for: newest, in: events)
    }

    public func batchHistory(limit: Int = 5) async throws -> [BotMemoryMaintenanceBatchView] {
        let events = try await allEvents()
        return Self.batches(in: events).suffix(max(0, limit)).reversed()
            .map { Self.view(for: $0, in: events) }
    }

    // MARK: Yield to the main chat

    /// Cancel the quiet timer and any running batch; committed writes stay.
    public func noteUserTurnStarted() async {
        quietTask?.cancel()
        quietTask = nil
        guard activeBatchID != nil else { return }
        await remote.cancelMaintenanceTurn()
    }

    /// Schedule the app-alive opportunity after the main chat goes quiet.
    public func noteUserTurnFinished() {
        quietTask?.cancel()
        let interval = Self.quietIntervalMilliseconds
        quietTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000)
            guard !Task.isCancelled else { return }
            await self?.maybeRun(reason: "quiet")
        }
    }

    public func stop() {
        quietTask?.cancel()
        quietTask = nil
    }

    // MARK: Triggers

    /// Runs only when the switch is on, the app is active, the main chat is
    /// idle, no approval is pending and a trigger fires. Returns nil when it
    /// does not run.
    @discardableResult
    public func maybeRun(reason: String = "opportunity") async -> BotMemoryMaintenanceBatchView? {
        guard activeBatchID == nil else { return nil }
        let settings = settingsStore.settings()
        guard settings.enabled, isAppActive() else { return nil }
        guard await !(await remote.mainTurnIsBusy()) else { return nil }
        guard await runtime.approvals.pendingIDs.isEmpty else { return nil }
        // A batch over the daily cap is pointless: it would be rolled back.
        // Do not start one, and let the memory page show the exhausted budget.
        guard await !(await dailyBudgetExhausted(settings: settings)) else { return nil }
        guard let trigger = await fireTrigger() else { return nil }
        return await run(trigger: trigger, settings: settings)
    }

    /// Explicit run. `force` exists for the eval self-check and manual
    /// verification; production callers use `maybeRun`.
    @discardableResult
    public func runNow(trigger: BotMemoryMaintenanceTrigger = .manual,
                       force: Bool = false) async -> BotMemoryMaintenanceBatchView? {
        guard activeBatchID == nil else { return nil }
        let settings = settingsStore.settings()
        if !force {
            guard settings.enabled, isAppActive() else { return nil }
            guard await !(await remote.mainTurnIsBusy()) else { return nil }
            guard await runtime.approvals.pendingIDs.isEmpty else { return nil }
            guard await !(await dailyBudgetExhausted(settings: settings)) else { return nil }
        }
        return await run(trigger: trigger, settings: settings)
    }

    private func dailyBudgetExhausted(
        settings: BotMemoryMaintenanceSettings
    ) async -> Bool {
        let usage = await budgetUsage(sessionID: "", since: 0, now: now())
        return usage.daily >= settings.dailyTokenBudget
    }

    private func fireTrigger() async -> BotMemoryMaintenanceTrigger? {
        let events = try? await allEvents()
        guard let events else { return nil }
        if Self.hasUnresolvedContradiction(in: events) { return .contradiction }
        if let usage = try? await indexScalars(), usage >= Self.indexTriggerScalars {
            return .index
        }
        let since = Self.lastFinishedCommitSeq(in: events)
        let writes = events.filter {
            ($0.commitSeq ?? 0) > since
                && ($0.type == "memory.document_written" || $0.type == "memory.document_deleted")
        }.count
        if writes > Self.writesTrigger { return .writes }
        return nil
    }

    // MARK: One run

    private func run(trigger: BotMemoryMaintenanceTrigger,
                     settings: BotMemoryMaintenanceSettings) async -> BotMemoryMaintenanceBatchView? {
        guard activeBatchID == nil else { return nil }
        let batchID = "mm-" + UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
            .prefix(32)
        activeBatchID = batchID
        defer { activeBatchID = nil }

        let startedAt = now()
        let candidates = (try? await candidates()) ?? []
        let userScopeOwner = isMainBot()
        let maintainerSession: String
        do {
            maintainerSession = try await remote.ensureMaintenanceSession()
        } catch {
            return nil
        }
        let previousLive = (try? await memory.documents(scope: nil)) ?? []
        var beforeVersions: [String: Int] = [:]
        for document in previousLive { beforeVersions[document.path] = document.version }

        let start = BotMemoryMaintenanceStart(
            batchID: batchID, botID: botID, trigger: trigger,
            startedAtMS: startedAt, maintainerSessionID: maintainerSession,
            candidates: candidates,
            budget: BotMemoryMaintenanceStartBudget(
                runTokens: settings.runTokenBudget,
                dailyTokens: settings.dailyTokenBudget))
        guard (try? await append(
            type: "memory.maintenance_started",
            eventID: "memory.maintenance_started:\(batchID)",
            data: start, at: startedAt, batchID: batchID,
            sessionID: maintainerSession)) != nil else {
            return nil
        }

        let prompt = BotMemoryMaintenanceText.prompt(
            batchID: batchID, botID: botID, candidates: candidates,
            trigger: trigger, settings: settings, userScopeOwner: userScopeOwner)
        let turnResult: BotRemoteTurnResult?
        do {
            turnResult = try await remote.runMaintenanceTurn(
                prompt: prompt, batchID: batchID)
        } catch {
            turnResult = nil
        }

        // Collect exactly this batch's writes from the durable events.
        let afterEvents = (try? await allEvents()) ?? []
        let writes = afterEvents.filter {
            $0.correlationId == "memory-maintenance:\(batchID)"
                && ($0.type == "memory.document_written" || $0.type == "memory.document_deleted")
        }
        let changes = Self.changes(in: writes)
        // One path counts once, by its last live version (spec/bot/v2 §4.2).
        var lastContent: [String: String] = [:]
        for event in writes.sorted(by: { ($0.commitSeq ?? 0) < ($1.commitSeq ?? 0) })
        where event.type == "memory.document_written" {
            guard let path = event.data["path"]?.stringValue,
                  let content = event.data["content"]?.stringValue else { continue }
            lastContent[path] = content
        }
        let writtenScalars = lastContent.values
            .reduce(0) { $0 + BotMemoryMaintenanceText.scalarCount($1) }

        var checks = BotMemoryMaintenanceChecks(
            referencesResolve: false, indexWithinLimit: false,
            documentsNotLongerThanEvidence: false, changeBudgetWithinLimit: false)
        var failure: BotMemoryMaintenanceFailureCode?

        let hasEvidence = writes.contains {
            !($0.data["evidence"]?.arrayValue ?? []).isEmpty
        }
        // Check 1: every evidence reference still resolves for this Bot.
        if let recordReading {
            checks.referencesResolve = await Self.referencesResolve(
                writes, botID: botID, sessionID: maintainerSession,
                reading: recordReading)
            // Check 3: a document with evidence is not longer than that evidence.
            checks.documentsNotLongerThanEvidence = await Self.documentsNotLongerThanEvidence(
                writes, sessionID: maintainerSession, reading: recordReading)
        } else {
            // Fail closed when there is evidence and no reader; an empty batch
            // still passes.
            checks.referencesResolve = !hasEvidence
            checks.documentsNotLongerThanEvidence = !hasEvidence
        }
        // Check 2: both indexes within 1,500 scalars.
        checks.indexWithinLimit = await Self.indexesWithinLimit(memory: memory)
        // Check 4: one run changes at most 12 documents / 24,000 scalars.
        checks.changeBudgetWithinLimit =
            changes.count <= Self.maximumChangedDocuments
            && writtenScalars <= Self.maximumChangedScalars

        if !checks.referencesResolve {
            failure = .evidenceUnresolved
        } else if !checks.indexWithinLimit {
            failure = .indexTooLong
        } else if !checks.documentsNotLongerThanEvidence {
            failure = .documentLongerThanEvidence
        } else if !checks.changeBudgetWithinLimit {
            failure = .changeBudgetExceeded
        }

        // Budget: per-run usage reads the ledger under the maintenance purpose.
        let usage = await budgetUsage(
            sessionID: maintainerSession, since: startedAt, now: now())
        var budget = BotMemoryMaintenanceBudget(
            runTokens: settings.runTokenBudget,
            dailyTokens: settings.dailyTokenBudget,
            tokensUsed: usage.run,
            changedDocuments: changes.count,
            changedScalars: writtenScalars)
        if failure == nil, usage.run > settings.runTokenBudget
            || usage.daily > settings.dailyTokenBudget {
            failure = .budgetExceeded
        }

        let cancelled = turnResult?.status == "cancelled"
        var status: BotMemoryMaintenanceStatus
        if failure != nil {
            // Whole-batch rollback before the finished event. Any committed
            // write that conflicts with a later writer stays and is reported.
            let rollback = await rollback(
                batchID: batchID, changes: changes, beforeVersions: beforeVersions,
                sessionID: maintainerSession)
            if let rollback, !rollback.conflicts.isEmpty {
                status = .rollbackFailed
                failure = failure ?? .rollbackConflict
            } else {
                status = .rolledBack
            }
        } else if cancelled {
            status = .cancelled
        } else if turnResult == nil || turnResult?.status != "completed" {
            status = .failed
        } else {
            status = .committed
        }

        let changedIndex = changes.contains {
            $0.path == "user/INDEX.md" || $0.path == "agent/INDEX.md"
        }
        let changedUser = changes.contains { $0.scope == .user }
        let shouldNotify = failure == nil
            && (status == .committed || status == .cancelled)
            && (changedIndex || changedUser)

        let finishedAt = now()
        let batch = BotMemoryMaintenanceBatch(
            batchID: batchID, botID: botID, status: status, trigger: trigger,
            startedAtMS: startedAt, finishedAtMS: finishedAt,
            maintainerSessionID: maintainerSession, changes: changes,
            checks: checks, budget: budget,
            failureCode: failure?.rawValue,
            notification: shouldNotify, userScopeOwner: userScopeOwner)
        _ = try? await append(
            type: "memory.maintenance_finished",
            eventID: "memory.maintenance_finished:\(batchID)",
            data: batch, at: finishedAt, batchID: batchID,
            sessionID: maintainerSession)

        // A rolled-back batch did not process its contradictions; leave the
        // review requests pending for the next run.
        if status == .committed || status == .cancelled {
            try? await resolveReviewRequests(
                changed: changes, deleted: Set(changes.filter(\.deleted).map(\.path)),
                batchID: batchID, sessionID: maintainerSession)
        }
        if shouldNotify {
            await notify(Self.noticeLine(batch: batch))
        }
        let events = (try? await allEvents()) ?? afterEvents
        return Self.view(
            for: batch,
            in: events + [])
    }

    /// Roll back one batch to the live versions captured at batch start.
    /// Used by both the mechanical-check failure path and the memory page.
    @discardableResult
    public func rollback(batchID: String) async throws -> BotMemoryMaintenanceRollback? {
        let events = try await allEvents()
        guard let batch = Self.batches(in: events).last(where: { $0.batchID == batchID }) else {
            return nil
        }
        // Reconstruct before versions from the batch's own write events.
        var beforeVersions: [String: Int] = [:]
        for event in events where event.correlationId == "memory-maintenance:\(batchID)" {
            guard event.type == "memory.document_written" || event.type == "memory.document_deleted",
                  let path = event.data["path"]?.stringValue,
                  let expected = event.data["expected_version"]?.intValue else { continue }
            if beforeVersions[path] == nil { beforeVersions[path] = expected }
        }
        return await rollback(batchID: batchID, changes: batch.changes,
                              beforeVersions: beforeVersions,
                              sessionID: batch.maintainerSessionID)
    }

    private func rollback(
        batchID: String,
        changes: [BotMemoryMaintenanceChange],
        beforeVersions: [String: Int],
        sessionID: String?
    ) async -> BotMemoryMaintenanceRollback? {
        var restored: [BotMemoryMaintenanceRestore] = []
        var conflicts: [String] = []
        let context = BotMemoryWriteContext(
            botID: botID, sessionID: nil, authorKind: .ui,
            source: BotMemorySource(kind: .agentMessage, sessionID: nil, turnID: nil, role: "ui"),
            trust: nil, isMainBot: true, batchID: nil, isHostRollback: true)
        for change in changes.sorted(by: { $0.path < $1.path }) {
            let live = try? await memory.read(path: change.path)
            let liveDocument: BotMemoryDocumentVersion?
            switch live {
            case .document(let document)?: liveDocument = document
            case .directory?, .failure?, nil: liveDocument = nil
            }
            let before = beforeVersions[change.path] ?? change.beforeVersion
            if change.deleted {
                // The batch's last action removed the document. A live
                // document means a later writer recreated it; do not overwrite.
                guard liveDocument == nil else {
                    conflicts.append(change.path)
                    continue
                }
                if before == 0 {
                    // Written and removed within the batch: the rollback target
                    // is absence, which is the live state already. There is no
                    // new version to record.
                    continue
                }
                let result = try? await memory.write(
                    BotMemoryWriteRequest(
                        action: .restore, path: change.path,
                        expectedVersion: 0, restoreVersion: before),
                    context: context)
                if result?.ok == true, let version = result?.version {
                    restored.append(BotMemoryMaintenanceRestore(
                        path: change.path, fromVersion: change.afterVersion,
                        toVersion: version))
                } else {
                    conflicts.append(change.path)
                }
                continue
            }
            guard let liveDocument, liveDocument.version == change.afterVersion else {
                conflicts.append(change.path)
                continue
            }
            if before == 0 {
                let result = try? await memory.forget(
                    path: change.path, expectedVersion: liveDocument.version)
                if result?.ok == true {
                    restored.append(BotMemoryMaintenanceRestore(
                        path: change.path, fromVersion: change.afterVersion,
                        toVersion: 0))
                } else {
                    conflicts.append(change.path)
                }
            } else {
                let result = try? await memory.write(
                    BotMemoryWriteRequest(
                        action: .restore, path: change.path,
                        expectedVersion: liveDocument.version, restoreVersion: before),
                    context: context)
                if result?.ok == true, let version = result?.version {
                    restored.append(BotMemoryMaintenanceRestore(
                        path: change.path, fromVersion: change.afterVersion,
                        toVersion: version))
                } else {
                    conflicts.append(change.path)
                }
            }
        }
        let record = BotMemoryMaintenanceRollback(
            batchID: batchID, botID: botID, rolledBackAtMS: now(),
            restored: restored, conflicts: conflicts)
        _ = try? await append(
            type: "memory.maintenance_rolled_back",
            eventID: "memory.maintenance_rolled_back:\(batchID):\(record.rolledBackAtMS)",
            data: record, at: record.rolledBackAtMS, batchID: batchID,
            sessionID: sessionID)
        return record
    }

    // MARK: Candidates

    /// Host-selected candidates, never a full scan. The order and caps are the
    /// frozen contract (spec/bot/v2 §4.6).
    public func candidates() async throws -> [BotMemoryMaintenanceCandidate] {
        let events = try await allEvents()
        let documents = try await memory.documents(scope: nil)
        var ordered: [String] = []
        var reasons: [String: [BotMemoryMaintenanceCandidateReason]] = [:]

        func add(_ path: String, _ reason: BotMemoryMaintenanceCandidateReason) {
            guard ordered.count < 64 else { return }
            if reasons[path] == nil { ordered.append(path) }
            var current = reasons[path] ?? []
            if !current.contains(reason) { current.append(reason) }
            reasons[path] = current
        }

        // Inbox submissions first: one representative document per session.
        let inbox = Dictionary(grouping: documents.filter {
            $0.path.hasPrefix("agent/inbox/")
        }, by: { document -> String in
            let rest = document.path.dropFirst("agent/inbox/".count)
            if let head = rest.split(separator: "/").first { return String(head) }
            return String(rest)
        })
        for session in inbox.keys.sorted() {
            if let first = inbox[session]?.map(\BotMemoryDocument.path).sorted().first {
                add(first, .inbox)
            }
        }

        let pendingReviews = Self.pendingReviewPaths(in: events)
        for path in pendingReviews.sorted() { add(path, .contradiction) }

        // Index proximity.
        for document in documents where BotMemoryAuthorizer.isIndex(document.path) {
            if BotMemoryMaintenanceText.scalarCount(document.content) >= Self.indexTriggerScalars {
                add(document.path, .index)
            }
        }

        // Most read: durable ReadMemory calls naming a path.
        var readCounts: [String: Int] = [:]
        for event in events where event.type == "conversation.tool_call" {
            let name = event.data["name"]?.stringValue ?? ""
            guard name == "ReadMemory" || name.hasSuffix("__ReadMemory") else { continue }
            guard let arguments = event.data["arguments"]?.stringValue,
                  let raw = arguments.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
                  let path = object["path"] as? String else { continue }
            readCounts[path, default: 0] += 1
        }
        for (path, _) in readCounts.sorted(by: { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }) where documents.contains(where: { $0.path == path }) {
            add(path, .mostRead)
        }

        // Most changed.
        var changeCounts: [String: Int] = [:]
        for event in events where event.type == "memory.document_written" {
            guard let path = event.data["path"]?.stringValue else { continue }
            changeCounts[path, default: 0] += 1
        }
        for (path, _) in changeCounts.sorted(by: { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }) where documents.contains(where: { $0.path == path }) {
            add(path, .mostChanged)
        }

        // Least verified: evidence-bearing documents the most recent
        // successfully committed batch did not verify, oldest first.
        let verified = Set(Self.batches(in: events)
            .last { $0.status == .committed }?
            .changes.map(\.path) ?? [])
        let leastVerified = documents
            .filter { !$0.evidence.isEmpty && !verified.contains($0.path) }
            .sorted { $0.updatedAtMS < $1.updatedAtMS }
        for document in leastVerified { add(document.path, .leastVerified) }

        // Overlong.
        for document in documents
            where BotMemoryMaintenanceText.scalarCount(document.content)
                > Self.overlongDocumentScalars {
            add(document.path, .overlong)
        }

        let nonMain = !isMainBot()
        return ordered
            .filter { !nonMain || BotMemoryAuthorizer.scope(of: $0) != .user }
            .prefix(Self.maximumCandidates)
            .map { BotMemoryMaintenanceCandidate(
                path: $0, reasons: Array((reasons[$0] ?? []).prefix(4))) }
    }

    // MARK: Checks

    private static func referencesResolve(
        _ writes: [BotEvent], botID: String, sessionID: String,
        reading: any BotMemoryMaintenanceRecordReading
    ) async -> Bool {
        for event in writes {
            let evidence = event.data["evidence"]?.arrayValue?
                .compactMap(\.stringValue) ?? []
            guard !evidence.isEmpty else { continue }
            guard let derived = try? await reading.resolveEvidence(
                evidence, callerBotID: botID, callerSessionID: sessionID) else {
                return false
            }
            // The write recorded the trust its evidence implied; the check
            // re-derives it rather than trusting the write.
            if let stored = event.data["trust"]?.stringValue,
               let expected = BotRecordTrust(rawValue: stored),
               derived.trust != expected {
                return false
            }
        }
        return true
    }

    private static func indexesWithinLimit(memory: BotMemory) async -> Bool {
        for path in ["user/INDEX.md", "agent/INDEX.md"] {
            guard let document = try? await memory.read(path: path) else { return false }
            switch document {
            case .document(let version):
                if BotMemoryMaintenanceText.scalarCount(version.content)
                    > BotMemoryAuthorizer.indexLimit { return false }
            case .directory, .failure:
                return false
            }
        }
        return true
    }

    private static func documentsNotLongerThanEvidence(
        _ writes: [BotEvent], sessionID: String,
        reading: any BotMemoryMaintenanceRecordReading
    ) async -> Bool {
        for event in writes where event.type == "memory.document_written" {
            let evidence = event.data["evidence"]?.arrayValue?
                .compactMap(\.stringValue) ?? []
            guard !evidence.isEmpty,
                  let content = event.data["content"]?.stringValue else { continue }
            var total = 0
            var failed = false
            for reference in Set(evidence) {
                guard let text = try? await reading.recordText(
                    reference, callerSessionID: sessionID) else {
                    failed = true
                    break
                }
                total += BotMemoryMaintenanceText.scalarCount(text)
            }
            if failed { return false }
            if BotMemoryMaintenanceText.scalarCount(content) > total { return false }
        }
        return true
    }

    // MARK: Ledger

    /// Per-run and UTC-day token usage for the dedicated maintenance purpose.
    /// Read from the LLM ledger, never from the model's self-report.
    private func budgetUsage(sessionID: String, since: Int64, now: Int64)
        async -> (run: Int, daily: Int) {
        let ledger = BotLLMLedger(eventLog: store)
        guard let records = try? await ledger.records(limit: 100_000) else {
            return (0, 0)
        }
        let nowDate = Date(timeIntervalSince1970: Double(now) / 1_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let dayStart = Int64((calendar.startOfDay(for: nowDate).timeIntervalSince1970 * 1_000).rounded())
        var run = 0
        var daily = 0
        for record in records
        where record.purpose == .memoryMaintenance && record.botId == botID {
            guard let date = BotLLMLedgerRecord.date(from: record.ts) else { continue }
            let at = Int64((date.timeIntervalSince1970 * 1_000).rounded())
            let tokens = record.inputTokens + record.outputTokens
                + record.cacheReadTokens + record.cacheWriteTokens
            if at >= dayStart, at <= now { daily += tokens }
            if record.sessionId == sessionID, at >= since, at <= now { run += tokens }
        }
        return (run, daily)
    }

    // MARK: Event helpers

    private func allEvents() async throws -> [BotEvent] {
        var result: [BotEvent] = []
        var cursor = 0
        while true {
            let page = try await store.events(after: cursor, limit: 500)
            guard !page.isEmpty else { return result }
            result.append(contentsOf: page)
            guard let last = page.last?.commitSeq else { return result }
            cursor = last
            if page.count < 500 { return result }
        }
    }

    private func append<T: Encodable>(
        type: String, eventID: String, data: T, at: Int64, batchID: String,
        sessionID: String?
    ) async throws -> Int {
        let value = try Self.jsonValue(data)
        let event = BotEvent(
            type: type, eventId: eventID, time: max(0, at),
            origin: .local(source: "memory-service"),
            traceId: "memory-maintenance:\(batchID)",
            principal: BotPrincipal(
                botId: botID, sessionId: sessionID,
                kind: "maintainer"),
            causationId: nil,
            correlationId: "memory-maintenance:\(batchID)",
            data: value)
        return try await store.append(event)
    }

    static func jsonValue<T: Encodable>(_ value: T) throws -> BotJSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try BotJSONValue.parse(encoder.encode(value))
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: BotJSONValue) -> T? {
        guard let raw = try? data.encoded() else { return nil }
        return try? JSONDecoder().decode(type, from: raw)
    }

    /// Batch writes in commit order, collapsed by path: before = the first
    /// expected version, after = the last version.
    static func changes(in events: [BotEvent]) -> [BotMemoryMaintenanceChange] {
        var order: [String] = []
        var byPath: [String: BotMemoryMaintenanceChange] = [:]
        for event in events.sorted(by: { ($0.commitSeq ?? 0) < ($1.commitSeq ?? 0) }) {
            guard let path = event.data["path"]?.stringValue,
                  let scopeName = event.data["scope"]?.stringValue,
                  let scope = BotMemoryScope(rawValue: scopeName),
                  let expected = event.data["expected_version"]?.intValue,
                  let version = event.data["version"]?.intValue else { continue }
            let deleted = event.type == "memory.document_deleted"
            if var existing = byPath[path] {
                existing.afterVersion = version
                existing.deleted = deleted
                byPath[path] = existing
            } else {
                order.append(path)
                byPath[path] = BotMemoryMaintenanceChange(
                    path: path, scope: scope, beforeVersion: expected,
                    afterVersion: version, deleted: deleted)
            }
        }
        return order.compactMap { byPath[$0] }
    }

    static func batches(in events: [BotEvent]) -> [BotMemoryMaintenanceBatch] {
        events.compactMap { event -> BotMemoryMaintenanceBatch? in
            guard event.type == "memory.maintenance_finished" else { return nil }
            return decode(BotMemoryMaintenanceBatch.self, from: event.data)
        }
    }

    static func view(
        for batch: BotMemoryMaintenanceBatch, in events: [BotEvent]
    ) -> BotMemoryMaintenanceBatchView {
        let rollback = events.compactMap { event -> BotMemoryMaintenanceRollback? in
            guard event.type == "memory.maintenance_rolled_back" else { return nil }
            return decode(BotMemoryMaintenanceRollback.self, from: event.data)
        }.last { $0.batchID == batch.batchID }
        return BotMemoryMaintenanceBatchView(batch: batch, rollback: rollback)
    }

    static func lastFinishedCommitSeq(in events: [BotEvent]) -> Int {
        events.last { $0.type == "memory.maintenance_finished" }?.commitSeq ?? 0
    }

    static func pendingReviewPaths(in events: [BotEvent]) -> Set<String> {
        var pending: Set<String> = []
        for event in events.sorted(by: { ($0.commitSeq ?? 0) < ($1.commitSeq ?? 0) }) {
            switch event.type {
            case "memory.review_requested":
                if let path = event.data["path"]?.stringValue { pending.insert(path) }
            case "memory.review_resolved":
                if let path = event.data["path"]?.stringValue { pending.remove(path) }
            default:
                continue
            }
        }
        return pending
    }

    static func hasUnresolvedContradiction(in events: [BotEvent]) -> Bool {
        !pendingReviewPaths(in: events).isEmpty
    }

    private func indexScalars() async throws -> Int {
        let documents = try await memory.documents(scope: nil)
        return documents.filter { BotMemoryAuthorizer.isIndex($0.path) }
            .map { BotMemoryMaintenanceText.scalarCount($0.content) }
            .max() ?? 0
    }

    private func resolveReviewRequests(
        changed: [BotMemoryMaintenanceChange], deleted: Set<String>,
        batchID: String, sessionID: String
    ) async throws {
        let events = try await allEvents()
        let pending = Self.pendingReviewPaths(in: events)
        let at = now()
        for change in changed where pending.contains(change.path) {
            let outcome = deleted.contains(change.path) ? "dropped" : "resolved"
            let value = BotJSONValue.object([
                "path": .string(change.path),
                "batch_id": .string(batchID),
                "outcome": .string(outcome),
                "resolved_at_ms": .number(Double(at)),
            ])
            let event = BotEvent(
                type: "memory.review_resolved",
                eventId: "memory.review_resolved:\(batchID):\(change.path)",
                time: at,
                origin: .local(source: "memory-service"),
                traceId: "memory-maintenance:\(batchID)",
                principal: BotPrincipal(
                    botId: botID,
                    sessionId: sessionID,
                    kind: "maintainer"),
                causationId: nil,
                correlationId: "memory-maintenance:\(batchID)",
                data: value)
            _ = try? await store.append(event)
        }
    }

    static func noticeLine(batch: BotMemoryMaintenanceBatch) -> String {
        let status: String
        switch batch.status {
        case .committed: status = "已完成"
        case .cancelled: status = "已取消（已写入的保留）"
        case .failed: status = "未完成"
        case .rolledBack: status = "未通过检查，已整批回滚"
        case .rollbackFailed: status = "回滚有冲突，需要查看"
        }
        let paths = batch.changes.map(\.path).prefix(4).joined(separator: "、")
        let suffix = batch.changes.count > 4 ? "…" : ""
        return "记忆整理：\(status)，更改 \(batch.changes.count) 份文档（\(paths)\(suffix)）。"
    }
}
