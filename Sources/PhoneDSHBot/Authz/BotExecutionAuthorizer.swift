// SPDX-License-Identifier: MIT

import Foundation

public enum BotExecutionPrincipalKind: String, Codable, Sendable {
    case model
    case userUI = "user-ui"
    case system
    case unknown
}

public struct BotExecutionPrincipal: Sendable, Equatable {
    public let botId: String?
    public let sessionId: String?
    public let kind: BotExecutionPrincipalKind
    public let sessionKind: BotSessionKind?
    public let certain: Bool

    init(botId: String?, sessionId: String? = nil,
         kind: BotExecutionPrincipalKind = .model,
         sessionKind: BotSessionKind? = nil, certain: Bool = true) {
        self.botId = botId
        self.sessionId = sessionId
        self.kind = kind
        self.sessionKind = sessionKind
        self.certain = certain
    }

    init(gateway principal: BotGatewayPrincipal, certain: Bool = true) {
        self.init(botId: principal.botId, sessionId: principal.sessionId, kind: .model,
                  sessionKind: principal.kind, certain: certain)
    }

    static func userUI(botId: String, sessionId: String? = nil) -> BotExecutionPrincipal {
        BotExecutionPrincipal(botId: botId, sessionId: sessionId, kind: .userUI, certain: true)
    }
}

public struct BotExecutionDecision: Sendable, Equatable {
    public let allowed: Bool
    public let reason: String
    public let principal: BotExecutionPrincipal
    public let effects: [BotToolEffect]
    public let grants: [BotGrant]
    public let denied: Bool
    public let userUI: Bool
    public let readOnly: Bool
    public let autoPolicy: Bool

    public init(allowed: Bool, reason: String, principal: BotExecutionPrincipal,
                effects: [BotToolEffect], grants: [BotGrant] = [], denied: Bool = false,
                userUI: Bool = false, readOnly: Bool = false, autoPolicy: Bool = false) {
        self.allowed = allowed
        self.reason = reason
        self.principal = principal
        self.effects = effects
        self.grants = grants
        self.denied = denied
        self.userUI = userUI
        self.readOnly = readOnly
        self.autoPolicy = autoPolicy
    }
}

public struct BotExecutionAuthorizer: Sendable {
    public let grants: BotGrantStore

    public init(grants: BotGrantStore) {
        self.grants = grants
    }

    public func authorizeExecution(principal: BotExecutionPrincipal?, effects: [BotToolEffect],
                                   source: String = "execution", argsDigest: String? = nil,
                                   consumeOnce: Bool = true) async -> BotExecutionDecision {
        let resolvedPrincipal = principal ?? BotExecutionPrincipal(botId: nil, kind: .unknown, certain: false)
        do {
            try await grants.recover()
        } catch {
            return await decision(false, "grant-recovery-failed", principal: resolvedPrincipal,
                                  effects: effects, source: source, argsDigest: nil)
        }
        var normalizedDigest: String?
        if let argsDigest {
            guard let digest = try? BotArgumentsDigest.validated(argsDigest) else {
                return await decision(false, "invalid-arguments-digest", principal: resolvedPrincipal,
                                      effects: effects, source: source, argsDigest: nil)
            }
            normalizedDigest = digest
        }
        guard !effects.isEmpty else {
            return await decision(false, "empty-effects", principal: resolvedPrincipal,
                                  effects: [], source: source, argsDigest: normalizedDigest)
        }
        var normalizedEffects: [BotToolEffect] = []
        for effect in effects {
            let tool = effect.tool.trimmingCharacters(in: .whitespacesAndNewlines)
            let resource = BotResourceNormalizer.normalize(effect.resource)
            guard !tool.isEmpty, !resource.isEmpty else {
                return await decision(false, "invalid-effect", principal: resolvedPrincipal,
                                      effects: effects, source: source, argsDigest: normalizedDigest)
            }
            normalizedEffects.append(BotToolEffect(tool: tool,
                operation: effect.operation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "unknown" : effect.operation.trimmingCharacters(in: .whitespacesAndNewlines),
                resource: resource, target: effect.target, mutability: effect.mutability,
                policy: effect.policy, label: effect.label, detail: effect.detail, ui: effect.ui,
                execution: effect.execution, known: effect.known, isMcp: effect.isMcp))
        }
        guard let botId = resolvedPrincipal.botId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !botId.isEmpty else {
            return await decision(false, "unattributed", principal: resolvedPrincipal,
                                  effects: normalizedEffects, source: source, argsDigest: normalizedDigest)
        }
        guard resolvedPrincipal.certain, resolvedPrincipal.kind != .unknown else {
            return await decision(false, "uncertain-attribution", principal: resolvedPrincipal,
                                  effects: normalizedEffects, source: source, argsDigest: normalizedDigest)
        }

        for effect in normalizedEffects {
            if let grant = await grants.find(botId: botId, sessionId: resolvedPrincipal.sessionId, effect: effect),
               grant.decision == .deny {
                return await decision(false, "standing-deny", principal: resolvedPrincipal,
                                      effects: normalizedEffects, grants: [grant], denied: true,
                                      source: source, argsDigest: normalizedDigest)
            }
        }

        if resolvedPrincipal.kind == .userUI {
            return await decision(true, "user-initiated UI action", principal: resolvedPrincipal,
                                  effects: normalizedEffects, userUI: true,
                                  readOnly: !normalizedEffects.contains(where: { $0.mutability != .read }),
                                  source: source, argsDigest: normalizedDigest)
        }
        let writes = normalizedEffects.filter { $0.mutability != .read }
        var hits: [BotGrant] = []
        var hitIDs: Set<String> = []
        for effect in normalizedEffects where effect.policy == .ask {
            guard let grant = await grants.find(botId: botId, sessionId: resolvedPrincipal.sessionId,
                                                effect: effect) else {
                return await decision(false, "missing-grant", principal: resolvedPrincipal,
                                      effects: normalizedEffects, source: source, argsDigest: normalizedDigest)
            }
            if hitIDs.insert(grant.id).inserted { hits.append(grant) }
        }
        if consumeOnce {
            let onceIDs = hits.filter { $0.scope == .once }.map(\.id)
            do {
                guard try await grants.consumeOnceAtomically(ids: onceIDs) else {
                    return await decision(false, "once-grant-consumed", principal: resolvedPrincipal,
                                          effects: normalizedEffects, source: source, argsDigest: normalizedDigest)
                }
            } catch {
                return await decision(false, "grant-persistence-failed", principal: resolvedPrincipal,
                                      effects: normalizedEffects, source: source, argsDigest: normalizedDigest)
            }
        }
        let auto = writes.contains { $0.policy == .auto }
        let reason = auto ? (hits.isEmpty ? "auto-policy" : "auto-policy; grant matched") : "grant matched"
        return await decision(true, reason, principal: resolvedPrincipal,
                              effects: normalizedEffects, grants: hits,
                              readOnly: writes.isEmpty, autoPolicy: auto,
                              source: source, argsDigest: normalizedDigest)
    }

    private func decision(_ allowed: Bool, _ reason: String, principal: BotExecutionPrincipal,
                          effects: [BotToolEffect], grants: [BotGrant] = [], denied: Bool = false,
                          userUI: Bool = false, readOnly: Bool = false, autoPolicy: Bool = false,
                          source: String, argsDigest: String?) async -> BotExecutionDecision {
        let result = BotExecutionDecision(allowed: allowed, reason: reason, principal: principal,
                                          effects: effects, grants: grants, denied: denied,
                                          userUI: userUI, readOnly: readOnly, autoPolicy: autoPolicy)
        let record = BotAuditRecord(at: Int64(Date().timeIntervalSince1970 * 1_000), source: source,
                                    decision: allowed ? .allow : .deny,
                                    principal: BotAuditPrincipal(botId: principal.botId,
                                                                 sessionId: principal.sessionId,
                                                                 kind: principal.kind.rawValue,
                                                                 sessionKind: principal.sessionKind,
                                                                 certain: principal.certain),
                                    effects: effects.map { BotExecutionAuditing.effect($0, argsDigest: argsDigest) },
                                    grants: grants.map(BotExecutionAuditing.grant), reason: reason)
        if let audit = await self.grants.auditRecorder { await audit.append(record) }
        return result
    }
}
