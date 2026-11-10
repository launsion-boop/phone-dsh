// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHAgentCore

public struct BotMemoryWriteRequest: Sendable {
    public var text: String
    public var tier: BotMemoryTier
    public var scope: BotMemoryScope
    public var key: String?
    public var source: BotMemorySource
    public var sensitivity: BotMemorySensitivity
    public var importance: Double
    public var supersededBy: String?
    public var expiresAt: Int64?
    public var applicableWhen: String?
    public var notApplicableWhen: String?
    public var extractRunID: String?

    public init(
        text: String,
        tier: BotMemoryTier = .log,
        scope: BotMemoryScope = .agent,
        key: String? = nil,
        source: BotMemorySource,
        sensitivity: BotMemorySensitivity = .personal,
        importance: Double = 0.5,
        supersededBy: String? = nil,
        expiresAt: Int64? = nil,
        applicableWhen: String? = nil,
        notApplicableWhen: String? = nil,
        extractRunID: String? = nil
    ) {
        self.text = text
        self.tier = tier
        self.scope = scope
        self.key = key
        self.source = source
        self.sensitivity = sensitivity
        self.importance = importance
        self.supersededBy = supersededBy
        self.expiresAt = expiresAt
        self.applicableWhen = applicableWhen
        self.notApplicableWhen = notApplicableWhen
        self.extractRunID = extractRunID
    }
}

public struct BotMemoryWriteResult: Sendable, Equatable {
    public let ok: Bool
    public let code: String?
    public let error: String?
    public let factID: String?
    public let duplicated: Bool
    public let tier: BotMemoryTier
    public let scope: BotMemoryScope
    public let count: Int?

    public init(
        ok: Bool,
        code: String? = nil,
        error: String? = nil,
        factID: String? = nil,
        duplicated: Bool = false,
        tier: BotMemoryTier,
        scope: BotMemoryScope,
        count: Int? = nil
    ) {
        self.ok = ok
        self.code = code
        self.error = error
        self.factID = factID
        self.duplicated = duplicated
        self.tier = tier
        self.scope = scope
        self.count = count
    }
}

public struct BotMemoryForgetResult: Sendable, Equatable {
    public let ok: Bool
    public let error: String?
    public let removed: Int
    public let removedFacts: Int
    public let factIDs: [String]
    public let count: Int
    public let scope: BotMemoryScope

    public init(
        ok: Bool,
        error: String? = nil,
        removed: Int,
        factIDs: [String] = [],
        count: Int,
        scope: BotMemoryScope
    ) {
        self.ok = ok
        self.error = error
        self.removed = removed
        self.removedFacts = removed
        self.factIDs = factIDs
        self.count = count
        self.scope = scope
    }
}

public struct BotMemoryEraseResult: Sendable, Equatable {
    public let ok: Bool
    public let error: String?
    public let erased: Bool
    public let alreadyErased: Bool
    public let factID: String
    public let erasedAtMS: Int64?
    public let removed: Int
    public let removedFacts: Int
    public let count: Int
    public let scope: BotMemoryScope?
    public let tier: BotMemoryTier?

    public init(
        ok: Bool,
        error: String? = nil,
        erased: Bool = false,
        alreadyErased: Bool = false,
        factID: String,
        erasedAtMS: Int64? = nil,
        removed: Int = 0,
        count: Int,
        scope: BotMemoryScope? = nil,
        tier: BotMemoryTier? = nil
    ) {
        self.ok = ok
        self.error = error
        self.erased = erased
        self.alreadyErased = alreadyErased
        self.factID = factID
        self.erasedAtMS = erasedAtMS
        self.removed = removed
        self.removedFacts = removed
        self.count = count
        self.scope = scope
        self.tier = tier
    }
}

/// Result of erasing one whole scope. `botID` identifies the authority that
/// performed the erase, not a per-Bot filter on user scope: `.user` always
/// removes the shared user facts that every Bot reads.
public struct BotMemoryEraseScopeResult: Sendable, Equatable {
    public let ok: Bool
    public let error: String?
    public let scope: BotMemoryScope
    public let botID: String
    public let removed: Int
    public let removedFacts: Int
    public let factIDs: [String]
    public let count: Int

    public init(
        ok: Bool,
        error: String? = nil,
        scope: BotMemoryScope,
        botID: String,
        removed: Int,
        factIDs: [String] = [],
        count: Int
    ) {
        self.ok = ok
        self.error = error
        self.scope = scope
        self.botID = botID
        self.removed = removed
        self.removedFacts = removed
        self.factIDs = factIDs
        self.count = count
    }
}

public actor BotMemory {
    private let store: any BotMemoryFactStore
    private let dataRoot: String
    private let botID: String
    private let language: BotMemoryPromptLanguage
    private let now: @Sendable () -> Int64
    private let writeMutex = BotMemoryAsyncMutex()

    public init(
        store: any BotMemoryFactStore,
        dataRoot: String,
        botID: String,
        language: BotMemoryPromptLanguage = .zh,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) {
        self.store = store
        self.dataRoot = dataRoot
        self.botID = botID
        self.language = language
        self.now = now
    }

    public func facts(scope: BotMemoryScope? = nil) async throws -> [BotMemoryFact] {
        try await store.facts(scope: scope)
    }

    public func injection(
        scopes: [BotMemoryScope] = BotMemoryScope.allCases,
        budget: Int = BotMemoryLimits.standard.total,
        language: BotMemoryPromptLanguage? = nil
    ) async throws -> BotMemoryInjection {
        var inputs: [BotMemoryScopeInput] = []
        for scope in scopes {
            inputs.append(BotMemoryScopeInput(
                scope: scope,
                root: root(for: scope),
                facts: try await store.facts(scope: scope)
            ))
        }
        return BotMemoryInjector.render(
            scopes: inputs,
            budget: budget,
            language: language ?? self.language,
            now: now()
        )
    }

    public func promptBlock(
        scopes: [BotMemoryScope] = BotMemoryScope.allCases,
        budget: Int = BotMemoryLimits.standard.total,
        language: BotMemoryPromptLanguage? = nil
    ) async throws -> String {
        try await injection(scopes: scopes, budget: budget, language: language).text
    }

    public func write(_ request: BotMemoryWriteRequest) async throws -> BotMemoryWriteResult {
        var downgraded = request.source
        downgraded.kind = .agentMessage
        return try await write(request, context: BotMemoryWriteContext(source: downgraded))
    }

    public func write(
        _ request: BotMemoryWriteRequest,
        context: BotMemoryWriteContext
    ) async throws -> BotMemoryWriteResult {
        try await writeMutex.withLock {
            try await performWrite(request, source: context.source)
        }
    }

    private func performWrite(
        _ request: BotMemoryWriteRequest,
        source verifiedSource: BotMemorySource
    ) async throws -> BotMemoryWriteResult {
        if verifiedSource.kind != .userTurn && (request.scope == .user || request.tier == .profile) {
            let kind = verifiedSource.kind.rawValue
            return BotMemoryWriteResult(
                ok: false,
                code: "memory-source-boundary",
                error: BotMemoryNormalizer.bilingual(
                    language,
                    zh: "來源 \(kind) 不能寫入 scope:\"user\" 或 tier:\"profile\"；請改用 scope:\"agent\" 的 tier:\"log\" 或 tier:\"note\"。",
                    en: "Source \(kind) cannot write scope:\"user\" or tier:\"profile\"; use scope:\"agent\" with tier:\"log\" or tier:\"note\"."
                ),
                tier: request.tier,
                scope: request.scope
            )
        }
        let normalized = BotMemoryNormalizer.normalizeFactText(request.text, language: language)
        guard normalized.ok else {
            return BotMemoryWriteResult(
                ok: false,
                code: normalized.code,
                error: normalized.error,
                tier: request.tier,
                scope: request.scope
            )
        }
        let allFacts = try await store.facts(scope: nil)
        let scopedFacts = allFacts.filter { $0.scope == request.scope }
        if request.tier == .profile,
           let existing = scopedFacts.first(where: {
               $0.tier == .profile && BotMemoryNormalizer.normalizeForgetText($0.text) == normalized.text
           }) {
            return BotMemoryWriteResult(
                ok: true,
                factID: existing.factID,
                duplicated: true,
                tier: request.tier,
                scope: request.scope,
                count: scopedFacts.count
            )
        }
        let noteKey = normalizedNoteKey(request.key) ?? dayString(now())
        if request.tier == .note,
           let existing = scopedFacts.first(where: {
               $0.tier == .note
                   && BotMemoryNormalizer.normalizeForgetText($0.text) == normalized.text
                   && (normalizedNoteKey($0.key) ?? "") == noteKey
           }) {
            return BotMemoryWriteResult(
                ok: true,
                factID: existing.factID,
                duplicated: true,
                tier: request.tier,
                scope: request.scope,
                count: scopedFacts.count
            )
        }
        let factID = try await uniqueFactID(existing: allFacts)
        var source = verifiedSource
        source.sessionID = trimmed(source.sessionID)
        source.turnID = trimmed(source.turnID)
        source.role = trimmed(source.role)?.lowercased()
        let fact = BotMemoryFact(
            factID: factID,
            text: normalized.text,
            learnedAtMS: now(),
            tier: request.tier,
            scope: request.scope,
            key: request.tier == .note ? noteKey : nil,
            trust: .string(source.kind == .userTurn ? "user" : "assistant"),
            sensitivity: request.sensitivity,
            importance: BotMemoryRecallIndex.normalizeImportance(request.importance),
            lastUsedMS: 0,
            extractor: "manual",
            source: source,
            supersededBy: trimmed(request.supersededBy),
            expiresAt: request.expiresAt.flatMap { $0 > 0 ? $0 : nil },
            applicableWhen: emptyAsNil(BotMemoryNormalizer.normalizeConditionText(request.applicableWhen)),
            notApplicableWhen: emptyAsNil(BotMemoryNormalizer.normalizeConditionText(request.notApplicableWhen)),
            extractRunID: trimmed(request.extractRunID)
        )
        try await store.append(fact)
        return BotMemoryWriteResult(
            ok: true,
            factID: factID,
            tier: request.tier,
            scope: request.scope,
            count: scopedFacts.count + 1
        )
    }

    public func forget(
        text: String? = nil,
        factID: String? = nil,
        scope: BotMemoryScope = .agent
    ) async throws -> BotMemoryForgetResult {
        if let requestedID = trimmed(factID) {
            for candidateScope in [scope, scope == .agent ? .user : .agent] {
                let facts = try await store.facts(scope: candidateScope)
                let targets = facts.filter { $0.factID == requestedID }
                if !targets.isEmpty {
                    let removal = try await store.remove(
                        factIDs: targets.map(\.factID),
                        scope: candidateScope,
                        tombstone: nil
                    )
                    return BotMemoryForgetResult(
                        ok: true,
                        removed: removal.removed.count,
                        factIDs: removal.removed.map(\.factID),
                        count: removal.count,
                        scope: candidateScope
                    )
                }
            }
            let count = try await store.facts(scope: scope).count
            return BotMemoryForgetResult(
                ok: false,
                error: "fact not found: \(requestedID)",
                removed: 0,
                count: count,
                scope: scope
            )
        }
        let needle = BotMemoryNormalizer.normalizeForgetText(text ?? "")
        if needle.isEmpty {
            return BotMemoryForgetResult(
                ok: false,
                error: BotMemoryNormalizer.bilingual(
                    language,
                    zh: "事實不能為空。",
                    en: "A memory fact cannot be empty."
                ),
                removed: 0,
                count: try await store.facts(scope: scope).count,
                scope: scope
            )
        }
        let facts = try await store.facts(scope: scope)
        let targets = facts.filter { BotMemoryNormalizer.normalizeForgetText($0.text) == needle }
        if targets.isEmpty {
            return BotMemoryForgetResult(ok: true, removed: 0, count: facts.count, scope: scope)
        }
        let removal = try await store.remove(factIDs: targets.map(\.factID), scope: scope, tombstone: nil)
        return BotMemoryForgetResult(
            ok: true,
            removed: removal.removed.count,
            factIDs: removal.removed.map(\.factID),
            count: removal.count,
            scope: scope
        )
    }

    public func erase(factID: String) async throws -> BotMemoryEraseResult {
        guard let id = trimmed(factID) else {
            return BotMemoryEraseResult(
                ok: false,
                error: "fact_id is required",
                factID: "",
                count: try await store.facts(scope: nil).count
            )
        }
        for scope in BotMemoryScope.allCases {
            let facts = try await store.facts(scope: scope)
            guard let target = facts.first(where: { $0.factID == id }) else { continue }
            let tombstone = BotMemoryTombstone(factID: id, erasedAtMS: now())
            let removal = try await store.remove(factIDs: [id], scope: scope, tombstone: tombstone)
            return BotMemoryEraseResult(
                ok: true,
                erased: true,
                factID: id,
                erasedAtMS: tombstone.erasedAtMS,
                removed: removal.removed.count,
                count: removal.count,
                scope: scope,
                tier: target.tier
            )
        }
        for scope in BotMemoryScope.allCases {
            if let tombstone = try await store.tombstone(factID: id, scope: scope) {
                return BotMemoryEraseResult(
                    ok: true,
                    alreadyErased: true,
                    factID: id,
                    erasedAtMS: tombstone.erasedAtMS,
                    count: try await store.facts(scope: scope).count,
                    scope: scope
                )
            }
        }
        return BotMemoryEraseResult(
            ok: false,
            error: "fact not found: \(id)",
            factID: id,
            count: try await store.facts(scope: .user).count,
            scope: .user
        )
    }

    /// Erases every durable fact in one scope with text-free tombstones.
    ///
    /// - `scope: .agent` affects **only the current Bot**: its private facts
    ///   disappear and future replay cannot resurrect them. Other Bots' agent
    ///   facts and the shared user scope are untouched.
    /// - `scope: .user` affects the **shared user memory** read by every Bot.
    ///   The current Bot's own agent facts are untouched.
    ///
    /// This is the whole-scope version of ``erase(factID:)``. Individual fact
    /// erasure remains id-addressed and scope-discovering. App-side callers
    /// should confirm the scope before calling because `user` is visible to all
    /// Bots.
    @discardableResult
    public func eraseAll(scope: BotMemoryScope) async throws -> BotMemoryEraseScopeResult {
        let removal = try await store.eraseAll(scope: scope)
        return BotMemoryEraseScopeResult(
            ok: true,
            scope: scope,
            botID: botID,
            removed: removal.removed.count,
            factIDs: removal.removed.map(\.factID),
            count: removal.count
        )
    }

    /// Searches memory. With `scope == nil` both stores are searched and the
    /// merged result reserves a slot for the missing scope (upstream
    /// `memory.cjs` merge behaviour). With an explicit scope only that store is
    /// searched, using the full `limit`; filtering a merged top-N would return
    /// fewer hits than the scope actually has.
    public func recall(
        _ query: String = "",
        limit: Int = 40,
        scope: BotMemoryScope? = nil,
        includeArchived: Bool = false,
        now explicitNow: Int64? = nil
    ) async throws -> [BotMemoryRecallHit] {
        let nowMS = explicitNow ?? now()
        let maximum = max(0, limit)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchedRecall = !trimmedQuery.isEmpty

        func ranked(for scope: BotMemoryScope) async throws -> [BotMemoryRankedFact] {
            BotMemoryRecallIndex(facts: try await store.facts(scope: scope)).search(
                query,
                limit: maximum,
                now: nowMS,
                includeArchived: includeArchived
            )
        }

        func touch(_ ranked: [BotMemoryRankedFact]) async throws {
            guard matchedRecall else { return }
            let ids = ranked.filter { $0.fact.archived != true }.map(\.fact.factID)
            guard !ids.isEmpty else { return }
            try? await store.touch(factIDs: ids, lastUsedMS: nowMS)
        }

        func hits(
            _ ranked: [BotMemoryRankedFact],
            sourcePrefix: String
        ) -> [BotMemoryRecallHit] {
            ranked.map {
                BotMemoryRecallHit(
                    ranked: $0,
                    sourcePrefix: sourcePrefix,
                    now: nowMS,
                    lastUsedMS: matchedRecall && $0.fact.archived != true ? nowMS : nil
                )
            }
        }

        if let scope {
            let scoped = try await ranked(for: scope)
            try await touch(scoped)
            return hits(scoped, sourcePrefix: scope == .agent ? "bot" : "user")
        }

        let agentRanked = try await ranked(for: .agent)
        let userRanked = try await ranked(for: .user)
        try await touch(agentRanked)
        try await touch(userRanked)
        let agentHits = hits(agentRanked, sourcePrefix: "bot")
        let userHits = hits(userRanked, sourcePrefix: "user")
        func sortHits(_ hits: inout [BotMemoryRecallHit]) {
            hits.sort { left, right in
                if left.score != right.score { return left.score > right.score }
                if left.learnedAtMS != right.learnedAtMS { return left.learnedAtMS > right.learnedAtMS }
                return left.factID < right.factID
            }
        }
        var merged = agentHits + userHits
        sortHits(&merged)
        var output = Array(merged.prefix(maximum))
        if !output.isEmpty, !agentHits.isEmpty, !userHits.isEmpty, maximum > 1 {
            let hasAgent = output.contains { $0.scope == .agent }
            let hasUser = output.contains { $0.scope == .user }
            if !hasAgent || !hasUser {
                if let missing = !hasAgent ? agentHits.first : userHits.first {
                    output[output.count - 1] = missing
                    sortHits(&output)
                }
            }
        }
        return output
    }

    private func root(for scope: BotMemoryScope) -> String {
        let root = URL(fileURLWithPath: dataRoot, isDirectory: true)
        if scope == .user {
            return root.appendingPathComponent("memory-user", isDirectory: true).path
        }
        return root
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent(botID, isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
            .path
    }

    private func uniqueFactID(existing: [BotMemoryFact]) async throws -> String {
        let existingIDs = Set(existing.map(\.factID))
        while true {
            var generator = SystemRandomNumberGenerator()
            let suffix = (0..<8).map { _ in
                String(format: "%02x", UInt8.random(in: UInt8.min...UInt8.max, using: &generator))
            }.joined()
            let candidate = "fact-\(suffix)"
            if existingIDs.contains(candidate) { continue }
            var erased = false
            for scope in BotMemoryScope.allCases {
                if try await store.tombstone(factID: candidate, scope: scope) != nil {
                    erased = true
                    break
                }
            }
            if !erased { return candidate }
        }
    }

    private func normalizedNoteKey(_ value: String?) -> String? {
        guard let value else { return nil }
        let folded = BotMemoryText.foldFactLines(value)
        return emptyAsNil(BotMemoryText.prefixCodePoints(folded, 200))
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        return emptyAsNil(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func emptyAsNil(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private func dayString(_ timestamp: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: Date(timeIntervalSince1970: Double(timestamp) / 1_000))
    }
}
