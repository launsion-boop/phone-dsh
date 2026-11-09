// SPDX-License-Identifier: MIT

import Foundation

public struct BotApprovalOutcome: Codable, Sendable, Equatable {
    public let ok: Bool
    public let allowed: Bool
    public let approvalId: String?
    public let message: String?

    public init(ok: Bool, allowed: Bool, approvalId: String? = nil, message: String? = nil) {
        self.ok = ok
        self.allowed = allowed
        self.approvalId = approvalId
        self.message = message
    }

    public var jsonValue: BotJSONValue {
        var fields: [String: BotJSONValue] = ["ok": .bool(ok), "allowed": .bool(allowed)]
        if let approvalId { fields["approvalId"] = .string(approvalId) }
        if let message { fields["message"] = .string(message) }
        return .object(fields)
    }
}

public enum BotApprovalResolution: Sendable, Equatable {
    case resolved
    case stale(reason: String)
}

public actor BotApprovalCoordinator {
    /// One card stays pending for five minutes. Identity registrations inherit
    /// at least this lifetime (`BotAttributionRegistry.defaultTTLMilliseconds`)
    /// so an approval can always be resolved against its originating call.
    public static let defaultTimeoutMilliseconds: Int64 = 300_000

    private struct Pending {
        let principal: BotGatewayPrincipal
        let effects: [BotToolEffect]
        let digest: String
        let command: String
        let alwaysScope: String
        let deferConsumption: Bool
        let continuation: CheckedContinuation<BotApprovalOutcome, Never>
        var timeout: Task<Void, Never>?
    }

    private let grants: BotGrantStore
    private let authorizer: BotExecutionAuthorizer
    private let eventWriter: BotMCPEventWriter
    private let now: @Sendable () -> Int64
    private let approvalTimeoutMs: Int64
    private var pending: [String: Pending] = [:]

    public init(grants: BotGrantStore, eventWriter: BotMCPEventWriter,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
                approvalTimeoutMs: Int64 = BotApprovalCoordinator.defaultTimeoutMilliseconds) {
        self.grants = grants
        authorizer = BotExecutionAuthorizer(grants: grants)
        self.eventWriter = eventWriter
        self.now = now
        self.approvalTimeoutMs = max(1, approvalTimeoutMs)
    }

    public func standingDecision(call: BotResolvedToolCall, effects: [BotToolEffect],
                                 deferConsumption: Bool) async -> BotApprovalOutcome? {
        let decision = await authorizer.authorizeExecution(
            principal: BotExecutionPrincipal(gateway: call.principal), effects: effects,
            source: "approval-standing", argsDigest: call.attribution.argsDigest,
            consumeOnce: !deferConsumption)
        if decision.allowed {
            return BotApprovalOutcome(ok: true, allowed: true, message: decision.reason)
        }
        if decision.denied || decision.reason == "standing-deny" {
            return BotApprovalOutcome(ok: true, allowed: false, message: decision.reason)
        }
        return nil
    }

    public func request(call: BotResolvedToolCall, effects: [BotToolEffect],
                        action: String, detail: String, command: String,
                        alwaysScope: String) async -> BotApprovalOutcome {
        let deferConsumption = effects.allSatisfy { $0.execution != nil }
        if let standing = await standingDecision(
            call: call, effects: effects, deferConsumption: deferConsumption) { return standing }
        let approvalId = "approval-\(UUID().uuidString.lowercased())"
        let principal = call.principal
        let digest = call.attribution.argsDigest
        do {
            try await eventWriter.append(
                type: "approval.requested", principal: principal,
                data: .object([
                    "approvalID": .string(approvalId), "status": .string("pending"),
                    "action": .string(action), "detail": .string(detail),
                    "digest": .string(digest), "command": .string(command),
                    "alwaysScope": .string(alwaysScope),
                    "deferConsumption": .bool(deferConsumption),
                    "effects": .array(effects.map(Self.effectJSON)),
                ]))
        } catch {
            return BotApprovalOutcome(ok: false, allowed: false, message: "approval audit failed")
        }
        return await withCheckedContinuation { continuation in
            pending[approvalId] = Pending(
                principal: principal, effects: effects, digest: digest, command: command,
                alwaysScope: alwaysScope, deferConsumption: deferConsumption,
                continuation: continuation, timeout: nil)
            let timeoutMs = approvalTimeoutMs
            let timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                guard !Task.isCancelled else { return }
                await self?.expire(approvalId: approvalId)
            }
            pending[approvalId]?.timeout = timeout
        }
    }

    @discardableResult
    public func resolve(approvalId: String, decision: BotApprovalDecision,
                        digest: String) async -> BotApprovalResolution {
        guard let request = pending[approvalId] else { return .stale(reason: "unknown_approval") }
        guard let suppliedDigest = try? BotArgumentsDigest.validated(digest),
              suppliedDigest == request.digest else { return .stale(reason: "digest_mismatch") }
        pending.removeValue(forKey: approvalId)
        request.timeout?.cancel()
        var allowed = decision != .deny
        var createdGrantIDs: [String] = []
        var effectiveScope: BotGrantScope = .once
        do {
            if allowed {
                for effect in request.effects {
                    switch decision {
                    case .allowOnce:
                        effectiveScope = .once
                    case .always:
                        switch request.alwaysScope {
                        case "until": effectiveScope = .until
                        case "session": effectiveScope = .session
                        default: effectiveScope = .once
                        }
                    case .deny:
                        effectiveScope = .once
                    }
                    let grant = try await grants.add(BotGrant(
                        botId: request.principal.botId, tool: effect.tool, operation: effect.operation,
                        resource: effect.resource, scope: effectiveScope,
                        sessionId: request.principal.sessionId,
                        createdAt: now(), source: "approval-card", decision: .allow))
                    createdGrantIDs.append(grant.id)
                }
                if effectiveScope == .once, !request.deferConsumption {
                    guard try await grants.consumeOnceAtomically(ids: createdGrantIDs) else {
                        throw BotGrantError.invalidGrant
                    }
                }
            }
            try await eventWriter.append(
                type: "approval.decided", principal: request.principal,
                data: .object([
                    "approvalID": .string(approvalId), "decision": .string(decision.rawValue),
                    "status": .string(allowed ? "allowed" : "denied"),
                    "alwaysScope": .string(decision == .always ? request.alwaysScope : effectiveScope.rawValue),
                ]))
        } catch {
            allowed = false
            for id in createdGrantIDs { _ = try? await grants.revoke(id: id) }
        }
        request.continuation.resume(returning: BotApprovalOutcome(
            ok: allowed, allowed: allowed, approvalId: approvalId,
            message: allowed ? "allowed" : "approval denied"))
        return .resolved
    }

    @discardableResult
    public func cancel(approvalId: String) -> Bool {
        guard let request = pending.removeValue(forKey: approvalId) else { return false }
        request.timeout?.cancel()
        request.continuation.resume(returning: BotApprovalOutcome(
            ok: false, allowed: false, approvalId: approvalId, message: "approval cancelled"))
        return true
    }

    /// Cancels every pending card. A Worker restart calls this so no card can
    /// survive into a new incarnation; each card is closed as a visible
    /// cancelled decision and the UI gets one notice per session.
    @discardableResult
    public func cancelAll(reason: String = "worker_restarted") async -> Int {
        await cancelAll(
            matching: { _ in true }, reason: reason,
            noticeText: "The app restarted and cancelled the pending approval.")
    }

    /// Cancels only the pending cards owned by one Bot. The Bot deletion
    /// cascade calls this instead of scanning durable events and resolving
    /// each card. The semantics match the global ``cancelAll(reason:)``:
    /// waiters receive a denied/unavailable outcome and one durable
    /// `approval.decided` plus one `ui.notice` event is written per card.
    @discardableResult
    public func cancelAll(botID: String, reason: String = "bot_deleted") async -> Int {
        await cancelAll(
            matching: { $0.principal.botId == botID }, reason: reason,
            noticeText: "This Bot was deleted and its pending approval was cancelled.")
    }

    private func cancelAll(matching include: (Pending) -> Bool,
                           reason: String, noticeText: String) async -> Int {
        let requests = pending.filter { include($0.value) }
        guard !requests.isEmpty else { return 0 }
        for id in requests.keys { pending.removeValue(forKey: id) }
        for (id, request) in requests {
            request.timeout?.cancel()
            let data = BotJSONValue.object([
                "approvalID": .string(id), "decision": .string("deny"),
                "status": .string("cancelled"), "reason": .string(reason),
            ])
            try? await eventWriter.append(
                type: "approval.decided", principal: request.principal, data: data,
                eventId: "cancelled:\(id)")
            try? await eventWriter.append(
                type: "ui.notice", principal: request.principal,
                data: .object([
                    "id": .string("notice-\(id)"),
                    "kind": .string("approval_cancelled"),
                    "approvalID": .string(id),
                    "reason": .string(reason),
                    "text": .string(noticeText),
                ]),
                eventId: "notice:\(id)")
            request.continuation.resume(returning: BotApprovalOutcome(
                ok: false, allowed: false, approvalId: id, message: "approval unavailable"))
        }
        return requests.count
    }

    public func pendingDigest(approvalId: String) -> String? {
        pending[approvalId]?.digest
    }

    public var pendingIDs: [String] { pending.keys.sorted() }

    private func expire(approvalId: String) async {
        guard let request = pending.removeValue(forKey: approvalId) else { return }
        request.timeout?.cancel()
        do {
            try await eventWriter.append(
                type: "approval.decided", principal: request.principal,
                data: .object([
                    "approvalID": .string(approvalId), "decision": .string("deny"),
                    "status": .string("denied"), "timedOut": .bool(true),
                ]))
        } catch {}
        request.continuation.resume(returning: BotApprovalOutcome(
            ok: false, allowed: false, approvalId: approvalId, message: "approval timed out"))
    }

    private static func effectJSON(_ effect: BotToolEffect) -> BotJSONValue {
        .object([
            "tool": .string(effect.tool), "operation": .string(effect.operation),
            "resource": .string(effect.resource), "target": .string(effect.target),
            "mutability": .string(effect.mutability.rawValue), "policy": .string(effect.policy.rawValue),
            "label": .string(effect.label), "detail": .string(effect.detail),
            "ui": .bool(effect.ui), "known": .bool(effect.known), "isMcp": .bool(effect.isMcp),
            "execution": effect.execution.map(BotJSONValue.string) ?? .null,
        ])
    }
}

public actor BotMCPEventWriter {
    private let eventLog: any BotEventLog
    private let now: @Sendable () -> Int64

    public init(eventLog: any BotEventLog,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }) {
        self.eventLog = eventLog
        self.now = now
    }

    @discardableResult
    public func append(type: String, principal: BotGatewayPrincipal, data: BotJSONValue,
                       eventId: String = UUID().uuidString.lowercased(), origin: BotEventOrigin? = nil,
                       time: Int64? = nil) async throws -> Int {
        let id = "evt-\(type)-\(eventId)"
        let event = BotEvent(
            type: type, eventId: id, time: max(0, time ?? now()),
            origin: origin ?? .local(source: "mcp"),
            traceId: "trace-\(id)",
            principal: BotPrincipal(botId: principal.botId, sessionId: principal.sessionId,
                                    kind: principal.kind.rawValue, capabilities: principal.capabilities),
            causationId: nil, correlationId: principal.sessionId, data: data)
        return try await eventLog.append(event)
    }
}
