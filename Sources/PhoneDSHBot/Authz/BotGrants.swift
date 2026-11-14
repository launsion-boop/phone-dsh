// SPDX-License-Identifier: MIT

import Foundation

public enum BotGrantScope: String, Codable, Sendable {
    case once
    case session
    case until
}

public enum BotGrantDecision: String, Codable, Sendable {
    case allow
    case deny
}

public struct BotGrant: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let botId: String
    public let tool: String
    public let operation: String
    public let resource: String
    public let scope: BotGrantScope
    public let sessionId: String?
    public let expiresAt: Int64?
    public let createdAt: Int64
    public let source: String
    public let decision: BotGrantDecision

    public init(id: String = "", botId: String, tool: String, operation: String,
                resource: String, scope: BotGrantScope, sessionId: String? = nil,
                expiresAt: Int64? = nil, createdAt: Int64 = 0, source: String = "approval",
                decision: BotGrantDecision) {
        self.id = id
        self.botId = botId
        self.tool = tool
        self.operation = operation
        self.resource = resource
        self.scope = scope
        self.sessionId = sessionId
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.source = source
        self.decision = decision
    }
}

public enum BotGrantError: Error, Sendable, Equatable {
    case invalidGrant
    case invalidExpiry
}

public enum BotResourceNormalizer {
    public static func normalize(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        if text.hasSuffix("/**") {
            let base = normalize(String(text.dropLast(3)))
            return base.isEmpty ? "" : base + "/**"
        }
        let expanded = (text as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath {
            return (expanded as NSString).standardizingPath
        }
        return text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}

public actor BotGrantStore {
    public static let onceTTLMilliseconds: Int64 = 2 * 60 * 1_000
    public static let sessionTTLMilliseconds: Int64 = 24 * 60 * 60 * 1_000
    public static let untilTTLMilliseconds: Int64 = 30 * 24 * 60 * 60 * 1_000
    public static let maximumGrants = 500

    private enum RecoveryState {
        case pending
        case ready
        case failed(BotGrantRecoveryError)
    }

    private struct Mutation<T> {
        let grants: [BotGrant]
        let result: T
        let audits: [(event: String, grant: BotGrant, reason: String)]
    }

    private let now: @Sendable () -> Int64
    private let audit: (any BotAuditRecording)?
    private let eventLog: (any BotEventLog)?
    private var grants: [BotGrant] = []
    private var recoveryState: RecoveryState
    private var recoveryInProgress = false
    private var recoveryWaiters: [CheckedContinuation<Void, Never>] = []
    private var mutationInProgress = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var consumingOnceIDs: Set<String> = []

    init(now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
         audit: (any BotAuditRecording)? = nil) {
        self.now = now
        self.audit = audit
        if let domainStore = (audit as? BotAuditLog)?.domainStore {
            eventLog = domainStore
            recoveryState = .pending
        } else {
            eventLog = nil
            recoveryState = .ready
        }
    }

    public init(domainStore: SQLiteDomainStore,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
                audit: (any BotAuditRecording)? = nil) {
        self.now = now
        self.audit = audit ?? BotAuditLog(eventLog: domainStore)
        eventLog = domainStore
        recoveryState = .pending
    }

    init(eventLog: any BotEventLog,
         now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
         audit: (any BotAuditRecording)? = nil) {
        self.now = now
        self.audit = audit
        self.eventLog = eventLog
        recoveryState = .pending
    }

    public func recover() async throws {
        guard let eventLog else { return }
        switch recoveryState {
        case .ready:
            return
        case let .failed(error):
            throw error
        case .pending:
            break
        }
        if recoveryInProgress {
            await withCheckedContinuation { recoveryWaiters.append($0) }
            switch recoveryState {
            case .ready:
                return
            case let .failed(error):
                throw error
            case .pending:
                throw BotGrantRecoveryError.replayFailed("recovery finished without a result")
            }
        }

        recoveryInProgress = true
        do {
            let replay = try await Self.replay(eventLog: eventLog)
            let restored: [BotGrant]
            if replay.sawEvents {
                guard let snapshot = replay.snapshot else {
                    throw BotGrantRecoveryError.missingSnapshot
                }
                restored = try BotGrantSnapshot.decode(snapshot, now: now())
            } else {
                let emptySnapshot = try BotGrantSnapshot.event(grants: [], at: now())
                _ = try await eventLog.append(emptySnapshot)
                restored = []
            }
            grants = restored
            recoveryState = .ready
            finishRecovery()
        } catch {
            let recoveryError = error as? BotGrantRecoveryError
                ?? .replayFailed(String(describing: error))
            recoveryState = .failed(recoveryError)
            finishRecovery()
            throw recoveryError
        }
    }

    @discardableResult
    public func add(_ raw: BotGrant) async throws -> BotGrant {
        let added: BotGrant? = try await mutate { current in
            let timestamp = now()
            let botId = raw.botId.trimmingCharacters(in: .whitespacesAndNewlines)
            let tool = raw.tool.trimmingCharacters(in: .whitespacesAndNewlines)
            let resource = BotResourceNormalizer.normalize(raw.resource)
            guard !botId.isEmpty, !tool.isEmpty, !resource.isEmpty else {
                throw BotGrantError.invalidGrant
            }
            let createdAt = raw.createdAt == 0 ? timestamp : raw.createdAt
            let operation = raw.operation.trimmingCharacters(in: .whitespacesAndNewlines)
            let expiry = try raw.expiresAt ?? defaultExpiry(scope: raw.scope, createdAt: createdAt)
            guard expiry > timestamp else { throw BotGrantError.invalidExpiry }
            let sessionId = raw.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
            let source = raw.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let grant = BotGrant(id: raw.id.isEmpty ? Self.newID() : raw.id,
                                 botId: botId, tool: tool,
                                 operation: operation.isEmpty ? "unknown" : operation,
                                 resource: resource, scope: raw.scope,
                                 sessionId: sessionId?.isEmpty == false ? sessionId : nil,
                                 expiresAt: expiry, createdAt: createdAt,
                                 source: source.isEmpty ? "approval" : source,
                                 decision: raw.decision)
            if let index = current.firstIndex(where: {
                $0.botId == grant.botId && $0.tool == grant.tool && $0.operation == grant.operation
                    && $0.resource == grant.resource && $0.decision == grant.decision
                    && $0.scope == grant.scope
                    && (grant.scope != .session || $0.sessionId == grant.sessionId)
            }) {
                let existing = current[index]
                let extendedExpiry = max(existing.expiresAt ?? Int64.max, grant.expiresAt ?? Int64.max)
                let extended = BotGrant(id: existing.id, botId: existing.botId, tool: existing.tool,
                                        operation: existing.operation, resource: existing.resource,
                                        scope: existing.scope, sessionId: existing.sessionId,
                                        expiresAt: extendedExpiry == Int64.max ? nil : extendedExpiry,
                                        createdAt: existing.createdAt, source: existing.source,
                                        decision: existing.decision)
                var updated = current
                updated[index] = extended
                return Mutation(grants: updated, result: extended,
                                audits: [("grant.added", extended, "extended")])
            }
            guard !current.contains(where: { $0.id == grant.id }) else {
                throw BotGrantError.invalidGrant
            }
            let updated = Array((current + [grant]).suffix(Self.maximumGrants))
            return Mutation(grants: updated, result: grant,
                            audits: [("grant.added", grant, "created")])
        }
        guard let added else { throw BotGrantError.invalidGrant }
        return added
    }

    public func find(botId: String, sessionId: String?, effect: BotToolEffect) -> BotGrant? {
        guard case .ready = recoveryState else { return nil }
        let wantedBot = botId.trimmingCharacters(in: .whitespacesAndNewlines)
        let wantedResource = BotResourceNormalizer.normalize(effect.resource)
        guard !wantedBot.isEmpty, !effect.tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !wantedResource.isEmpty else { return nil }
        let timestamp = now()
        return grants.filter {
            !consumingOnceIDs.contains($0.id)
        }.filter {
            $0.expiresAt == nil || $0.expiresAt! > timestamp
        }.filter {
            $0.botId == wantedBot || ($0.botId == "*" && $0.decision == .deny)
        }.filter {
            $0.scope != .session || ($0.sessionId != nil && $0.sessionId == sessionId)
        }.filter {
            ($0.tool == "*" || $0.tool == effect.tool)
                && ($0.operation == "*" || $0.operation == effect.operation)
                && ($0.resource == "*" || $0.resource == wantedResource)
        }.sorted { lhs, rhs in
            if lhs.decision != rhs.decision { return lhs.decision == .deny }
            return specificity(lhs) > specificity(rhs)
        }.first
    }

    @discardableResult
    public func consume(id: String) async throws -> Bool {
        try await consumeOnceAtomically(ids: [id])
    }

    internal func consumeOnceAtomically(ids: [String]) async throws -> Bool {
        try await recover()
        let uniqueIDs = Set(ids)
        guard !uniqueIDs.isEmpty else { return true }
        let current = activeGrants()
        guard uniqueIDs.allSatisfy({ id in
            current.contains { $0.id == id && $0.scope == .once }
        }), consumingOnceIDs.isDisjoint(with: uniqueIDs) else { return false }

        consumingOnceIDs.formUnion(uniqueIDs)
        await acquireMutation()
        defer {
            consumingOnceIDs.subtract(uniqueIDs)
            releaseMutation()
        }
        let latest = activeGrants()
        guard uniqueIDs.allSatisfy({ id in
            latest.contains { $0.id == id && $0.scope == .once }
        }) else { return false }
        let removed = latest.filter { uniqueIDs.contains($0.id) }
        let updated = latest.filter { !uniqueIDs.contains($0.id) }
        try await persist(updated)
        grants = updated
        for grant in removed {
            await recordGrant(event: "grant.consumed", grant: grant, reason: "used-once")
        }
        return true
    }

    internal var auditRecorder: (any BotAuditRecording)? { audit }

    @discardableResult
    public func revoke(id: String) async throws -> Bool {
        try await mutate { current in
            guard let index = current.firstIndex(where: { $0.id == id }) else { return nil }
            let removed = current[index]
            var updated = current
            updated.remove(at: index)
            return Mutation(grants: updated, result: true,
                            audits: [("grant.revoked", removed, "user-revoked")])
        } ?? false
    }

    @discardableResult
    public func revokeBot(_ botId: String) async throws -> Int {
        try await mutate { current in
            let removed = current.filter { $0.botId == botId }
            guard !removed.isEmpty else { return nil }
            let updated = current.filter { $0.botId != botId }
            return Mutation(grants: updated, result: removed.count,
                            audits: removed.map { ("grant.revoked", $0, "bot-deleted") })
        } ?? 0
    }

    @discardableResult
    public func revokeSession(_ sessionId: String, botId: String? = nil) async throws -> Int {
        try await mutate { current in
            let removed = current.filter {
                $0.scope == .session && $0.sessionId == sessionId && (botId == nil || $0.botId == botId)
            }
            guard !removed.isEmpty else { return nil }
            let updated = current.filter {
                !($0.scope == .session && $0.sessionId == sessionId
                    && (botId == nil || $0.botId == botId))
            }
            return Mutation(grants: updated, result: removed.count,
                            audits: removed.map { ("grant.revoked", $0, "session-ended") })
        } ?? 0
    }

    public func list(botId: String? = nil) -> [BotGrant] {
        guard case .ready = recoveryState else { return [] }
        return activeGrants().filter { botId == nil || $0.botId == botId }
            .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    public func prune() -> Int {
        guard case .ready = recoveryState else { return 0 }
        let timestamp = now()
        let before = grants.count
        grants.removeAll {
            !consumingOnceIDs.contains($0.id) && $0.expiresAt != nil && $0.expiresAt! <= timestamp
        }
        return before - grants.count
    }

    internal func recordGrant(event: String, grant: BotGrant, reason: String) async {
        guard let audit else { return }
        let effect = BotToolEffect(tool: grant.tool, operation: grant.operation,
                                   resource: grant.resource, mutability: .write, policy: .ask)
        let record = BotAuditRecord(at: now(), event: event, source: grant.source,
                                    decision: grant.decision,
                                    principal: BotAuditPrincipal(botId: grant.botId,
                                                                 sessionId: grant.sessionId,
                                                                 kind: "ipc", certain: true),
                                    effects: [BotExecutionAuditing.effect(effect, argsDigest: nil)],
                                    grants: [BotExecutionAuditing.grant(grant)], reason: reason)
        await audit.append(record)
    }

    private func mutate<T>(
        _ body: ([BotGrant]) throws -> Mutation<T>?
    ) async throws -> T? {
        try await recover()
        await acquireMutation()
        do {
            guard let mutation = try body(activeGrants()) else {
                releaseMutation()
                return nil
            }
            try await persist(mutation.grants)
            grants = mutation.grants
            for audit in mutation.audits {
                await recordGrant(event: audit.event, grant: audit.grant, reason: audit.reason)
            }
            releaseMutation()
            return mutation.result
        } catch {
            releaseMutation()
            throw error
        }
    }

    private func persist(_ updated: [BotGrant]) async throws {
        guard let eventLog else { return }
        let snapshot = try BotGrantSnapshot.event(grants: updated, at: now())
        _ = try await eventLog.append(snapshot)
    }

    private func activeGrants() -> [BotGrant] {
        let timestamp = now()
        return grants.filter { $0.expiresAt == nil || $0.expiresAt! > timestamp }
    }

    private func acquireMutation() async {
        if !mutationInProgress {
            mutationInProgress = true
            return
        }
        await withCheckedContinuation { mutationWaiters.append($0) }
    }

    private func releaseMutation() {
        if mutationWaiters.isEmpty {
            mutationInProgress = false
        } else {
            mutationWaiters.removeFirst().resume()
        }
    }

    private func finishRecovery() {
        recoveryInProgress = false
        let waiters = recoveryWaiters
        recoveryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private static func replay(
        eventLog: any BotEventLog
    ) async throws -> (sawEvents: Bool, snapshot: BotEvent?) {
        var after = 0
        var sawEvents = false
        var snapshot: BotEvent?
        while true {
            let page = try await eventLog.events(after: after, limit: 500)
            guard !page.isEmpty else { break }
            sawEvents = true
            for event in page where event.type == BotGrantSnapshot.eventType {
                snapshot = event
            }
            guard let next = page.last?.commitSeq, next > after else {
                throw BotGrantRecoveryError.invalidSnapshot("event replay returned an invalid cursor")
            }
            after = next
            if page.count < 500 { break }
        }
        return (sawEvents, snapshot)
    }

    private func defaultExpiry(scope: BotGrantScope, createdAt: Int64) throws -> Int64 {
        let ttl: Int64
        switch scope {
        case .once: ttl = Self.onceTTLMilliseconds
        case .session: ttl = Self.sessionTTLMilliseconds
        case .until: ttl = Self.untilTTLMilliseconds
        }
        let result = createdAt.addingReportingOverflow(ttl)
        guard !result.overflow else { throw BotGrantError.invalidExpiry }
        return result.partialValue
    }

    private func specificity(_ grant: BotGrant) -> Int {
        (grant.botId == "*" ? 0 : 100) + (grant.tool == "*" ? 0 : 10)
            + (grant.operation == "*" ? 0 : 5) + 1
    }

    private static func newID() -> String {
        var generator = SystemRandomNumberGenerator()
        let suffix = (0..<8).map { _ in
            String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
        }.joined()
        return "grant-\(suffix)"
    }
}

internal enum BotExecutionAuditing {
    static func effect(_ effect: BotToolEffect, argsDigest: String?) -> BotAuditEffect {
        BotAuditEffect(tool: effect.tool, operation: effect.operation,
                       resourceDigest: BotArgumentsDigest.digest(ofUTF8: effect.resource),
                       argsDigest: argsDigest, mutability: effect.mutability, policy: effect.policy)
    }

    static func grant(_ grant: BotGrant) -> BotAuditGrant {
        BotAuditGrant(id: grant.id, scope: grant.scope, decision: grant.decision,
                      resourceDigest: BotArgumentsDigest.digest(ofUTF8: grant.resource))
    }
}
