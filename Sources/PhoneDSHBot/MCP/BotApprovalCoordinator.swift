// SPDX-License-Identifier: MIT

import Foundation

public struct BotApprovalOutcome: Codable, Sendable, Equatable {
    public let ok: Bool
    public let allowed: Bool
    public let approvalId: String?
    public let message: String?
    /// A durable (non-interactive) approval is waiting for the user. The tool
    /// call did not run and the current turn must stop instead of retrying.
    public let pending: Bool
    public let expiresAt: Int64?
    /// The actual user decision. It is only present after an interactive
    /// decision; the tool result carries it so the card can render the real
    /// grant ("allow once" vs "this conversation") instead of guessing.
    public let decision: BotApprovalDecision?
    /// The effective grant scope (`once`, `session` or `until`) for an allowed
    /// decision. `nil` for pending/denied outcomes.
    public let scope: String?
    /// Grants created by this decision that the waiting request must consume
    /// before it sends. Empty when the coordinator already consumed them or
    /// the decision was not a fresh `allowOnce` (for example a standing Grant).
    /// This keeps one durable egress approval usable for exactly one retried
    /// write even when the original request was aborted.
    public let onceGrantIDs: [String]

    public init(ok: Bool, allowed: Bool, approvalId: String? = nil,
                message: String? = nil, pending: Bool = false,
                expiresAt: Int64? = nil, decision: BotApprovalDecision? = nil,
                scope: String? = nil, onceGrantIDs: [String] = []) {
        self.ok = ok
        self.allowed = allowed
        self.approvalId = approvalId
        self.message = message
        self.pending = pending
        self.expiresAt = expiresAt
        self.decision = decision
        self.scope = scope
        self.onceGrantIDs = onceGrantIDs
    }

    public var jsonValue: BotJSONValue {
        var fields: [String: BotJSONValue] = [
            "ok": .bool(ok), "allowed": .bool(allowed), "pending": .bool(pending),
        ]
        if let approvalId { fields["approvalId"] = .string(approvalId) }
        if let message { fields["message"] = .string(message) }
        if let expiresAt { fields["expiresAt"] = .number(Double(expiresAt)) }
        if let decision { fields["approvalDecision"] = .string(decision.rawValue) }
        if let scope { fields["scope"] = .string(scope) }
        return .object(fields)
    }
}

public enum BotApprovalResolution: Sendable, Equatable {
    case resolved
    case stale(reason: String)
}

/// Whether one approval keeps the old five-minute card wait or becomes a
/// durable todo. Only a real foreground user turn is interactive; everything
/// else is background work whose user may be gone.
public enum BotApprovalPersistence: String, Sendable, Equatable {
    case interactive
    case durable

    public var isPersistent: Bool { self == .durable }
}

/// The stable view of a durable approval the task/routine resumers use. The
/// coordinator keeps it in memory while the process lives and rebuilds it from
/// `approval.requested` after a restart.
public struct BotDurableApprovalState: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case pending
        case allowed
        case denied
        case expired
        case cancelled
        case unknown
    }

    public let approvalID: String
    public let principal: BotGatewayPrincipal
    public let status: Status
    public let requestedAt: Int64
    public let expiresAt: Int64
    public let action: String
    public let detail: String
    public let command: String

    public init(approvalID: String, principal: BotGatewayPrincipal, status: Status,
                requestedAt: Int64, expiresAt: Int64, action: String,
                detail: String, command: String) {
        self.approvalID = approvalID
        self.principal = principal
        self.status = status
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
        self.action = action
        self.detail = detail
        self.command = command
    }
}

/// One terminal durable decision. Delivered to the task/routine resumer both
/// for a live decision and for a decision restored from the event log.
public struct BotApprovalResolutionNotice: Sendable, Equatable {
    public let approvalID: String
    public let principal: BotGatewayPrincipal
    public let allowed: Bool
    public let expired: Bool
    public let cancelled: Bool
    public let decision: BotApprovalDecision?
    public let decidedAt: Int64

    public init(approvalID: String, principal: BotGatewayPrincipal,
                allowed: Bool, expired: Bool = false, cancelled: Bool = false,
                decision: BotApprovalDecision? = nil, decidedAt: Int64 = 0) {
        self.approvalID = approvalID
        self.principal = principal
        self.allowed = allowed
        self.expired = expired
        self.cancelled = cancelled
        self.decision = decision
        self.decidedAt = decidedAt
    }
}

/// Result of the host-side Bot egress write approval.
public enum BotEgressApproval: Sendable, Equatable {
    /// No Bot `bash` call is live; the request is workbench traffic and keeps
    /// the matrix's ordinary allow-list behaviour.
    case notBot
    /// The write is attributable to a Bot and the user (now or earlier)
    /// authorized this host + method.
    case allowed
    /// Fail closed with a stable lower-snake cause. Besides the approval
    /// outcomes (`egress_approval_denied`, `bot_egress_ambiguous`,
    /// `bot_egress_unattributed`), a Task session without
    /// `task.network-write` is `task_network_write_denied` before any card.
    /// A durable egress todo keeps the `egress_approval_denied` class (403);
    /// its message says the write is pending and the task will resume.
    case denied(code: String, message: String)
}

/// Cancellation bridge between the `/v1/http` consumer and the pending Bot
/// approval card. `BotApprovalCoordinator` creates the card id inside
/// `request`, so the id is delivered through `onPending`; a cancellation that
/// arrives before that id is remembered and applied as soon as it appears.
/// Durable approvals are not cancelled by a consumer that went away.
public final class BotEgressApprovalCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let approvals: BotApprovalCoordinator
    private var approvalID: String?
    private var cancelled = false

    public init(approvals: BotApprovalCoordinator) {
        self.approvals = approvals
    }

    /// Records the id of the freshly created card, cancelling it immediately
    /// when the consumer already went away.
    public func set(approvalID id: String) {
        lock.lock()
        let shouldCancel = cancelled
        if !shouldCancel { approvalID = id }
        lock.unlock()
        if shouldCancel {
            Task { await approvals.cancel(approvalId: id) }
        }
    }

    /// Drops the id after a terminal decision; cancellation is a no-op then.
    public func clear() {
        lock.lock()
        approvalID = nil
        lock.unlock()
    }

    /// Cancels the pending card if it exists, or arms cancellation for a card
    /// that is about to be created.
    public func cancel() {
        lock.lock()
        cancelled = true
        let id = approvalID
        approvalID = nil
        lock.unlock()
        if let id {
            Task { await approvals.cancel(approvalId: id) }
        }
    }
}

public actor BotApprovalCoordinator {
    /// One interactive card stays pending for five minutes. Identity
    /// registrations inherit at least this lifetime
    /// (`BotAttributionRegistry.defaultTTLMilliseconds`) so an interactive
    /// approval can always be resolved against its originating call. Durable
    /// approvals never hold a tool call across this window (§2.7).
    public static let defaultTimeoutMilliseconds: Int64 = 300_000
    /// A durable todo is a rejection after 24 hours. Expiry writes its own
    /// status instead of pretending the user denied it.
    public static let defaultDurableExpiryMilliseconds: Int64 = 24 * 60 * 60 * 1_000

    private struct Pending {
        let principal: BotGatewayPrincipal
        /// The call whose registration produced this card. `/identity/cancel`
        /// uses it to cancel exactly that call's interactive approvals.
        let callId: String
        let effects: [BotToolEffect]
        let digest: String
        let action: String
        let detail: String
        let command: String
        let alwaysScope: String
        let deferConsumption: Bool
        let persistent: Bool
        let origin: String
        let requestedAt: Int64
        let expiresAt: Int64
        var continuation: CheckedContinuation<BotApprovalOutcome, Never>?
        var timeout: Task<Void, Never>?
        /// Bounded interactive wait for a durable egress approval. It is
        /// cancelled when the decision arrives; a timeout leaves the card
        /// pending so the approved retry can consume its once Grant.
        var waitTimeout: Task<Void, Never>?
    }

    private let grants: BotGrantStore
    private let authorizer: BotExecutionAuthorizer
    private let eventWriter: BotMCPEventWriter
    private let eventLog: (any BotEventLog)?
    private let now: @Sendable () -> Int64
    private let approvalTimeoutMs: Int64
    private let durableExpiryMs: Int64
    private var pending: [String: Pending] = [:]
    /// Terminal durable decisions restored from the log. The resumers use this
    /// to reconcile a task/routine that parked before the process restarted.
    private var decisions: [String: BotApprovalResolutionNotice] = [:]
    private var lastDecisionBySession: [String: BotApprovalResolutionNotice] = [:]
    private var pendingNotices: [BotApprovalResolutionNotice] = []
    private var resolutionHandler: (@Sendable (BotApprovalResolutionNotice) async -> Void)?
    private var restored = false
    private var restoring = false

    public init(grants: BotGrantStore, eventWriter: BotMCPEventWriter,
                eventLog: (any BotEventLog)? = nil,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
                approvalTimeoutMs: Int64 = BotApprovalCoordinator.defaultTimeoutMilliseconds,
                durableExpiryMs: Int64 = BotApprovalCoordinator.defaultDurableExpiryMilliseconds) {
        self.grants = grants
        authorizer = BotExecutionAuthorizer(grants: grants)
        self.eventWriter = eventWriter
        self.eventLog = eventLog
        self.now = now
        self.approvalTimeoutMs = max(1, approvalTimeoutMs)
        self.durableExpiryMs = max(1, durableExpiryMs)
    }

    /// Installs the task/routine wake seam. A handler installed after a
    /// restored expiry still receives the queued notices.
    public func setResolutionHandler(
        _ handler: (@Sendable (BotApprovalResolutionNotice) async -> Void)?
    ) async {
        resolutionHandler = handler
        guard handler != nil else { return }
        let queued = pendingNotices
        pendingNotices.removeAll()
        for notice in queued { await handler?(notice) }
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
                        alwaysScope: String,
                        persistence: BotApprovalPersistence = .interactive,
                        origin: String = "structural",
                        onPending: (@Sendable (String) -> Void)? = nil,
                        interactiveWaitMilliseconds: Int64 = 0) async -> BotApprovalOutcome {
        await ensureRestored()
        let deferConsumption = effects.allSatisfy { $0.execution != nil }
        if let standing = await standingDecision(
            call: call, effects: effects, deferConsumption: deferConsumption) { return standing }
        // One Bot write already has a pending card for the same host+method.
        // Do not create a second card when the model retries while the user is
        // deciding; the first card's decision authorizes the retry.
        if origin == "egress",
           let existing = matchingPendingEgress(principal: call.principal, effects: effects) {
            return Self.pendingOutcome(
                approvalId: existing.id, expiresAt: existing.expiresAt)
        }
        let approvalId = "approval-\(UUID().uuidString.lowercased())"
        let principal = call.principal
        let digest = call.attribution.argsDigest
        let requestedAt = now()
        let expiresAt = persistence.isPersistent ? requestedAt + durableExpiryMs : 0
        var data: [String: BotJSONValue] = [
            "approvalID": .string(approvalId), "status": .string("pending"),
            "action": .string(action), "detail": .string(detail),
            "digest": .string(digest), "command": .string(command),
            "alwaysScope": .string(alwaysScope),
            "deferConsumption": .bool(deferConsumption),
            "effects": .array(effects.map(Self.effectJSON)),
            "persistent": .bool(persistence.isPersistent),
            "kind": .string(principal.kind.rawValue),
            "origin": .string(origin),
            "requestedAt": .number(Double(requestedAt)),
        ]
        if persistence.isPersistent {
            data["expiresAt"] = .number(Double(expiresAt))
        }
        do {
            try await eventWriter.append(
                type: "approval.requested", principal: principal, data: .object(data))
        } catch {
            return BotApprovalOutcome(ok: false, allowed: false, message: "approval audit failed")
        }
        if persistence.isPersistent {
            // The worker must not keep a tool call blocked for five minutes.
            // Return immediately (or after a short bounded wait for a present
            // user); the user decision later wakes the parked task/routine, or
            // leaves the once Grant for an egress retry.
            pending[approvalId] = Pending(
                principal: principal, callId: call.callId, effects: effects, digest: digest,
                action: action, detail: detail, command: command,
                alwaysScope: alwaysScope, deferConsumption: deferConsumption,
                persistent: true, origin: origin, requestedAt: requestedAt,
                expiresAt: expiresAt, continuation: nil, timeout: nil,
                waitTimeout: nil)
            scheduleExpiry(approvalId: approvalId, expiresAt: expiresAt)
            onPending?(approvalId)
            let pendingOutcome = Self.pendingOutcome(
                approvalId: approvalId, expiresAt: expiresAt)
            let wait = max(0, interactiveWaitMilliseconds)
            guard wait > 0 else { return pendingOutcome }
            return await withCheckedContinuation { continuation in
                guard var current = pending[approvalId] else {
                    continuation.resume(returning: pendingOutcome)
                    return
                }
                current.continuation = continuation
                let timeout = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000)
                    guard !Task.isCancelled else { return }
                    await self?.expireDurableWait(approvalId: approvalId)
                }
                current.waitTimeout = timeout
                pending[approvalId] = current
            }
        }
        return await withCheckedContinuation { continuation in
            pending[approvalId] = Pending(
                principal: principal, callId: call.callId, effects: effects, digest: digest,
                action: action, detail: detail, command: command,
                alwaysScope: alwaysScope, deferConsumption: deferConsumption,
                persistent: false, origin: origin, requestedAt: requestedAt,
                expiresAt: 0, continuation: continuation, timeout: nil,
                waitTimeout: nil)
            onPending?(approvalId)
            let timeoutMs = approvalTimeoutMs
            let timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                guard !Task.isCancelled else { return }
                await self?.expireInteractive(approvalId: approvalId)
            }
            pending[approvalId]?.timeout = timeout
        }
    }

    private static func pendingOutcome(approvalId: String,
                                       expiresAt: Int64) -> BotApprovalOutcome {
        BotApprovalOutcome(
            ok: true, allowed: false, approvalId: approvalId,
            message: "approval pending", pending: true, expiresAt: expiresAt)
    }

    /// The oldest durable egress card for the same Bot session, operation and
    /// host resource. An egress retry reuses it instead of stacking cards.
    private func matchingPendingEgress(
        principal: BotGatewayPrincipal, effects: [BotToolEffect]
    ) -> (id: String, expiresAt: Int64)? {
        guard let effect = effects.first else { return nil }
        let matches = pending
            .filter { _, request in
                request.persistent && request.origin == "egress"
                    && request.principal.botId == principal.botId
                    && request.principal.sessionId == principal.sessionId
                    && request.effects.contains {
                        $0.operation == effect.operation && $0.resource == effect.resource
                    }
            }
            .sorted { ($0.value.requestedAt, $0.key) < ($1.value.requestedAt, $1.key) }
        guard let first = matches.first else { return nil }
        return (first.key, first.value.expiresAt)
    }

    @discardableResult
    public func resolve(approvalId: String, decision: BotApprovalDecision,
                        digest: String) async -> BotApprovalResolution {
        await ensureRestored()
        guard var request = pending[approvalId] else {
            if let notice = decisions[approvalId] {
                return .stale(reason: notice.expired ? "expired"
                    : notice.cancelled ? "cancelled" : "already_decided")
            }
            return .stale(reason: "unknown_approval")
        }
        guard let suppliedDigest = try? BotArgumentsDigest.validated(digest),
              suppliedDigest == request.digest else { return .stale(reason: "digest_mismatch") }
        if request.persistent, request.expiresAt > 0, now() >= request.expiresAt {
            await expireDurable(approvalId: approvalId)
            return .stale(reason: "expired")
        }
        pending.removeValue(forKey: approvalId)
        request.timeout?.cancel()
        request.waitTimeout?.cancel()
        var allowed = decision != .deny
        var createdGrantIDs: [String] = []
        var effectiveScope: BotGrantScope = .once
        let eventID = "decided:\(approvalId)"
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
                    // A once decision is exact to this call. A standing
                    // decision stores the effect's stable grant scope when it
                    // has one (images use model:image, so the next photo in the
                    // session/until scope is covered); bash and memory keep
                    // their exact resource unless they opt in.
                    let storedResource = effectiveScope == .once
                        ? effect.resource
                        : (effect.grantResource ?? effect.resource)
                    let grant = try await grants.add(BotGrant(
                        botId: request.principal.botId, tool: effect.tool, operation: effect.operation,
                        resource: storedResource, scope: effectiveScope,
                        sessionId: request.principal.sessionId,
                        createdAt: now(), source: "approval-card", decision: .allow))
                    createdGrantIDs.append(grant.id)
                }
                // A durable approval's first attempt was already stopped. The
                // once grant must survive for the resumed turn to consume it;
                // consuming here would make the retry ask again. Interactive
                // approvals keep the old consume-at-decision behaviour.
                if effectiveScope == .once, !request.deferConsumption, !request.persistent {
                    guard try await grants.consumeOnceAtomically(ids: createdGrantIDs) else {
                        throw BotGrantError.invalidGrant
                    }
                }
            }
            var decisionData: [String: BotJSONValue] = [
                "approvalID": .string(approvalId), "decision": .string(decision.rawValue),
                "status": .string(allowed ? "allowed" : "denied"),
                "alwaysScope": .string(decision == .always ? request.alwaysScope : effectiveScope.rawValue),
            ]
            if request.persistent {
                decisionData["persistent"] = .bool(true)
                decisionData["kind"] = .string(request.principal.kind.rawValue)
            }
            try await eventWriter.append(
                type: "approval.decided", principal: request.principal,
                data: .object(decisionData), eventId: eventID)
        } catch {
            allowed = false
            for id in createdGrantIDs { _ = try? await grants.revoke(id: id) }
            if request.persistent {
                pending[approvalId] = request
                scheduleExpiry(approvalId: approvalId, expiresAt: request.expiresAt)
                return .stale(reason: "audit_failed")
            }
        }
        let outcome = BotApprovalOutcome(
            ok: allowed, allowed: allowed, approvalId: approvalId,
            message: allowed ? "allowed" : "approval denied",
            decision: decision, scope: allowed ? effectiveScope.rawValue : nil,
            onceGrantIDs: allowed && effectiveScope == .once
                && request.persistent && request.origin == "egress"
                ? createdGrantIDs : [])
        request.continuation?.resume(returning: outcome)
        if request.persistent {
            let notice = BotApprovalResolutionNotice(
                approvalID: approvalId, principal: request.principal,
                allowed: allowed, decision: decision, decidedAt: now())
            record(notice)
            await deliver(notice)
        }
        return .resolved
    }

    @discardableResult
    public func cancel(approvalId: String) async -> Bool {
        await ensureRestored()
        guard let request = pending[approvalId], !request.persistent else { return false }
        pending.removeValue(forKey: approvalId)
        request.timeout?.cancel()
        // A cancelled card is still a decided card: the row must not stay
        // pending after the consumer (Worker `/v1/http` request, turn abort,
        // or a replacement host) went away.
        try? await eventWriter.append(
            type: "approval.decided", principal: request.principal,
            data: .object([
                "approvalID": .string(approvalId), "decision": .string("deny"),
                "status": .string("cancelled"), "reason": .string("consumer_cancelled"),
            ]),
            eventId: "cancelled:\(approvalId)")
        request.continuation?.resume(returning: BotApprovalOutcome(
            ok: false, allowed: false, approvalId: approvalId, message: "approval cancelled"))
        return true
    }

    /// Cancels a durable todo for an explicit stop (task stop, routine cancel,
    /// Bot deletion). The waiter is a parked task/routine, not a live fetch.
    @discardableResult
    public func cancelPersistent(approvalId: String, reason: String) async -> Bool {
        await ensureRestored()
        guard let request = pending[approvalId], request.persistent else { return false }
        pending.removeValue(forKey: approvalId)
        request.timeout?.cancel()
        request.waitTimeout?.cancel()
        try? await eventWriter.append(
            type: "approval.decided", principal: request.principal,
            data: .object([
                "approvalID": .string(approvalId), "decision": .string("deny"),
                "status": .string("cancelled"), "reason": .string(reason),
                "persistent": .bool(true),
            ]),
            eventId: "cancelled:\(approvalId)")
        let notice = BotApprovalResolutionNotice(
            approvalID: approvalId, principal: request.principal,
            allowed: false, cancelled: true, decision: .deny, decidedAt: now())
        request.continuation?.resume(returning: BotApprovalOutcome(
            ok: false, allowed: false, approvalId: approvalId,
            message: "approval cancelled"))
        record(notice)
        await deliver(notice)
        return true
    }

    /// Cancels every pending card. A Worker restart calls
    /// ``cancelInteractive(reason:)`` instead so durable todos survive.
    @discardableResult
    public func cancelAll(reason: String = "worker_restarted") async -> Int {
        await cancelAll(
            matching: { _ in true }, reason: reason,
            noticeText: Self.cancellationNotice(reason))
    }

    /// Cancels only interactive pending cards; durable todos are preserved
    /// across an App/Worker restart (§2.7).
    @discardableResult
    public func cancelInteractive(reason: String = "worker_restarted") async -> Int {
        await cancelAll(
            matching: { !$0.persistent }, reason: reason,
            noticeText: Self.cancellationNotice(reason))
    }

    /// Ends the interactive approvals that belong to one cancelled
    /// registration (`/identity/cancel`, mcp-endpoint.md §3). Every match is
    /// closed through ``cancel(approvalId:)``: one `approval.decided` with
    /// `deny`/`cancelled`/`consumer_cancelled`, and the waiting request gets
    /// `approval cancelled`. Durable todos are never cancelled this way.
    @discardableResult
    public func cancelInteractive(sessionId: String, callId: String) async -> Int {
        await ensureRestored()
        let matches = pending.filter {
            !$0.value.persistent && $0.value.principal.sessionId == sessionId
                && $0.value.callId == callId
        }.keys
        var cancelled = 0
        for id in matches {
            if await cancel(approvalId: id) { cancelled += 1 }
        }
        return cancelled
    }

    /// Cancels only the pending cards owned by one Bot. The Bot deletion
    /// cascade calls this instead of scanning durable events and resolving
    /// each card. Durable todos are cancelled too: Bot deletion is an explicit
    /// terminal condition.
    @discardableResult
    public func cancelAll(botID: String, reason: String = "bot_deleted") async -> Int {
        await cancelAll(
            matching: { $0.principal.botId == botID }, reason: reason,
            noticeText: Self.cancellationNotice(reason))
    }

    /// The one user-facing cancellation sentence. Approval history maps the
    /// durable `reason` through ``BotApprovalReceipt/cancellationReason(_:)``;
    /// the notice shown in the chat must use the same wording instead of a
    /// second hardcoded English string.
    static func cancellationNotice(_ reason: String) -> String {
        let sentence = BotApprovalReceipt.cancellationReason(reason) ?? "审批已取消"
        return sentence.hasSuffix("。") ? sentence : sentence + "。"
    }

    private func cancelAll(matching include: (Pending) -> Bool,
                           reason: String, noticeText: String) async -> Int {
        await ensureRestored()
        let requests = pending.filter { include($0.value) }
        guard !requests.isEmpty else { return 0 }
        for id in requests.keys { pending.removeValue(forKey: id) }
        for (id, request) in requests {
            request.timeout?.cancel()
            request.waitTimeout?.cancel()
            var data: [String: BotJSONValue] = [
                "approvalID": .string(id), "decision": .string("deny"),
                "status": .string("cancelled"), "reason": .string(reason),
            ]
            if request.persistent { data["persistent"] = .bool(true) }
            try? await eventWriter.append(
                type: "approval.decided", principal: request.principal, data: .object(data),
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
            request.continuation?.resume(returning: BotApprovalOutcome(
                ok: false, allowed: false, approvalId: id, message: "approval unavailable"))
            if request.persistent {
                let notice = BotApprovalResolutionNotice(
                    approvalID: id, principal: request.principal,
                    allowed: false, cancelled: true, decision: .deny, decidedAt: now())
                record(notice)
                await deliver(notice)
            }
        }
        return requests.count
    }

    public func pendingDigest(approvalId: String) -> String? {
        pending[approvalId]?.digest
    }

    /// Consumes the grants a durable egress decision handed to the waiting
    /// request. `true` when every grant was still available and is now used.
    /// A false result means a concurrent retry already consumed it; the
    /// caller must fail closed instead of sending a second write.
    public func consumeOnceGrants(_ ids: [String]) async -> Bool {
        guard !ids.isEmpty else { return true }
        return (try? await grants.consumeOnceAtomically(ids: ids)) ?? false
    }

    public var pendingIDs: [String] { pending.keys.sorted() }

    /// The durable todo one session is waiting on, if any. A task/routine that
    /// ended its turn checks this before deciding its terminal state.
    public func pendingApproval(sessionId: String) async -> BotDurableApprovalState? {
        await ensureRestored()
        let matches = pending
            .filter { $0.value.persistent && $0.value.principal.sessionId == sessionId }
            .sorted { ($0.value.requestedAt, $0.key) < ($1.value.requestedAt, $1.key) }
        guard let match = matches.first else { return nil }
        return state(id: match.key, request: match.value)
    }

    /// A pending todo or the most recent durable decision for this session.
    /// The task/routine park code uses it to close the "decision landed before
    /// the turn finished parking" race.
    public func pendingOrRecentApproval(sessionId: String) async -> BotDurableApprovalState? {
        if let pending = await pendingApproval(sessionId: sessionId) { return pending }
        await ensureRestored()
        guard let notice = lastDecisionBySession[sessionId] else { return nil }
        // Only close the tiny "decision won the race with the turn ending"
        // window. An old decision from an unrelated earlier task must not park
        // a fresh turn.
        guard notice.decidedAt > 0, now() - notice.decidedAt <= 120_000 else { return nil }
        return BotDurableApprovalState(
            approvalID: notice.approvalID, principal: notice.principal,
            status: notice.cancelled ? .cancelled
                : notice.expired ? .expired
                : notice.allowed ? .allowed : .denied,
            requestedAt: 0, expiresAt: 0, action: "", detail: "", command: "")
    }

    public func durableStatus(approvalId: String) async -> BotDurableApprovalState.Status {
        await ensureRestored()
        if let request = pending[approvalId], request.persistent { return .pending }
        guard let notice = decisions[approvalId] else { return .unknown }
        if notice.cancelled { return .cancelled }
        if notice.expired { return .expired }
        return notice.allowed ? .allowed : .denied
    }

    /// Every pending durable todo in stable request order. The App uses it to
    /// schedule/cancel the local "approval waiting" reminder.
    public func pendingNotificationRecords() async -> [BotApprovalNotificationRecord] {
        await ensureRestored()
        return pending
            .filter { $0.value.persistent }
            .map { id, request in
                BotApprovalNotificationRecord(
                    approvalID: id, botID: request.principal.botId,
                    action: request.action, detail: request.detail,
                    command: request.command, requestedAt: request.requestedAt,
                    expiresAt: request.expiresAt)
            }
            .sorted { ($0.requestedAt, $0.approvalID) < ($1.requestedAt, $1.approvalID) }
    }

    /// Rebuilds durable todos and terminal decisions from the log. Safe to
    /// call on every Worker rebind; already loaded ids are skipped. Requests
    /// written by an older build (no `persistent`) are closed as cancelled
    /// rather than left on a card that can never be answered.
    public func restoreDurable() async {
        await ensureRestored()
    }

    private func ensureRestored() async {
        guard !restored, !restoring, let eventLog else {
            if eventLog == nil { restored = true }
            return
        }
        restoring = true
        defer {
            restoring = false
            restored = true
        }
        var requested: [String: BotEvent] = [:]
        var decided: Set<String> = []
        var cursor = 0
        while true {
            let events: [BotEvent]
            do {
                events = try await eventLog.events(after: cursor, limit: 1_000)
            } catch {
                break
            }
            for event in events {
                guard let id = event.data["approvalID"]?.stringValue else { continue }
                switch event.type {
                case "approval.requested":
                    requested[id] = event
                case "approval.decided":
                    decided.insert(id)
                    if let request = requested[id], isPersistent(request) {
                        record(Self.notice(from: event, request: request))
                    }
                default:
                    break
                }
            }
            guard events.count == 1_000, let last = events.last?.commitSeq else { break }
            cursor = last
        }
        var notices: [BotApprovalResolutionNotice] = []
        for (id, event) in requested where !decided.contains(id) {
            guard !pending.keys.contains(id) else { continue }
            guard isPersistent(event) else {
                let principal = Self.principal(from: event)
                try? await eventWriter.append(
                    type: "approval.decided", principal: principal,
                    data: .object([
                        "approvalID": .string(id), "decision": .string("deny"),
                        "status": .string("cancelled"),
                        "reason": .string("worker_restarted"),
                    ]),
                    eventId: "cancelled:\(id)")
                try? await eventWriter.append(
                    type: "ui.notice", principal: principal,
                    data: .object([
                        "id": .string("notice-\(id)"),
                        "kind": .string("approval_cancelled"),
                        "approvalID": .string(id),
                        "reason": .string("worker_restarted"),
                        "text": .string(Self.cancellationNotice("worker_restarted")),
                    ]),
                    eventId: "notice:\(id)")
                continue
            }
            let request = Self.restoredPending(from: event)
            if request.expiresAt > 0, now() >= request.expiresAt {
                try? await eventWriter.append(
                    type: "approval.decided", principal: request.principal,
                    data: .object([
                        "approvalID": .string(id), "decision": .string("deny"),
                        "status": .string("expired"), "reason": .string("approval_expired"),
                        "expired": .bool(true), "timedOut": .bool(false),
                        "persistent": .bool(true),
                    ]),
                    eventId: "expired:\(id)")
                let notice = BotApprovalResolutionNotice(
                    approvalID: id, principal: request.principal,
                    allowed: false, expired: true, decision: .deny, decidedAt: now())
                record(notice)
                notices.append(notice)
                continue
            }
            pending[id] = request
            scheduleExpiry(approvalId: id, expiresAt: request.expiresAt)
        }
        for notice in notices { await deliver(notice) }
    }

    private func isPersistent(_ event: BotEvent) -> Bool {
        event.data["persistent"]?.boolValue == true
    }

    private static func principal(from event: BotEvent) -> BotGatewayPrincipal {
        BotGatewayPrincipal(
            botId: event.principal.botId ?? "main",
            sessionId: event.principal.sessionId ?? "gb-main",
            kind: BotSessionKind(rawValue: event.principal.kind) ?? .chat,
            capabilities: event.principal.capabilities,
            expiresAt: Int64.max,
            incarnation: "restored")
    }

    private static func restoredPending(from event: BotEvent) -> Pending {
        let data = event.data
        let effects: [BotToolEffect]
        if case .array(let raw)? = data["effects"],
           let decoded = try? JSONDecoder().decode(
               [BotToolEffect].self, from: BotJSONValue.array(raw).encoded()) {
            effects = decoded
        } else {
            effects = []
        }
        let requestedAt = data["requestedAt"]?.intValue.map(Int64.init) ?? event.time
        let expiresAt = data["expiresAt"]?.intValue.map(Int64.init)
            ?? (requestedAt + defaultDurableExpiryMilliseconds)
        return Pending(
            principal: principal(from: event),
            // Durable todos are never cancelled by `/identity/cancel`, so the
            // event log does not need to persist a call id for them.
            callId: "",
            effects: effects,
            digest: data["digest"]?.stringValue ?? "",
            action: data["action"]?.stringValue ?? "",
            detail: data["detail"]?.stringValue ?? "",
            command: data["command"]?.stringValue ?? "",
            alwaysScope: data["alwaysScope"]?.stringValue ?? "until",
            deferConsumption: data["deferConsumption"]?.boolValue ?? true,
            persistent: true,
            origin: data["origin"]?.stringValue ?? "structural",
            requestedAt: requestedAt, expiresAt: expiresAt,
            continuation: nil, timeout: nil, waitTimeout: nil)
    }

    private static func notice(from event: BotEvent,
                               request: BotEvent) -> BotApprovalResolutionNotice {
        let status = event.data["status"]?.stringValue ?? "denied"
        let decision = event.data["decision"]?.stringValue.flatMap(BotApprovalDecision.init(rawValue:))
        return BotApprovalResolutionNotice(
            approvalID: event.data["approvalID"]?.stringValue ?? "",
            principal: principal(from: request),
            allowed: status == "allowed",
            expired: status == "expired" || event.data["expired"]?.boolValue == true,
            cancelled: status == "cancelled",
            decision: decision, decidedAt: event.time)
    }

    private func state(id: String, request: Pending) -> BotDurableApprovalState {
        BotDurableApprovalState(
            approvalID: id, principal: request.principal, status: .pending,
            requestedAt: request.requestedAt, expiresAt: request.expiresAt,
            action: request.action, detail: request.detail, command: request.command)
    }

    private func record(_ notice: BotApprovalResolutionNotice) {
        decisions[notice.approvalID] = notice
        lastDecisionBySession[notice.principal.sessionId] = notice
        if decisions.count > 512 {
            let excess = decisions.count - 512
            for id in decisions.keys.prefix(excess) { decisions.removeValue(forKey: id) }
        }
        if lastDecisionBySession.count > 512 {
            let excess = lastDecisionBySession.count - 512
            for id in lastDecisionBySession.keys.prefix(excess) {
                lastDecisionBySession.removeValue(forKey: id)
            }
        }
    }

    private func deliver(_ notice: BotApprovalResolutionNotice) async {
        guard let resolutionHandler else {
            pendingNotices.append(notice)
            return
        }
        await resolutionHandler(notice)
    }

    private func scheduleExpiry(approvalId: String, expiresAt: Int64) {
        let delay = max(1, expiresAt - now())
        let timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            guard !Task.isCancelled else { return }
            await self?.expireDurable(approvalId: approvalId)
        }
        pending[approvalId]?.timeout = timeout
    }

    private func expireDurable(approvalId: String) async {
        guard let request = pending[approvalId], request.persistent else { return }
        pending.removeValue(forKey: approvalId)
        request.timeout?.cancel()
        request.waitTimeout?.cancel()
        try? await eventWriter.append(
            type: "approval.decided", principal: request.principal,
            data: .object([
                "approvalID": .string(approvalId), "decision": .string("deny"),
                "status": .string("expired"), "reason": .string("approval_expired"),
                "expired": .bool(true), "timedOut": .bool(false),
                "persistent": .bool(true),
            ]),
            eventId: "expired:\(approvalId)")
        request.continuation?.resume(returning: BotApprovalOutcome(
            ok: false, allowed: false, approvalId: approvalId,
            message: "approval expired"))
        let notice = BotApprovalResolutionNotice(
            approvalID: approvalId, principal: request.principal,
            allowed: false, expired: true, decision: .deny, decidedAt: now())
        record(notice)
        await deliver(notice)
    }

    /// The bounded egress wait elapsed while the card is still pending. Leave
    /// the durable card in place (and its once Grant uncreated) so the user can
    /// still approve; the retried write then consumes that Grant.
    private func expireDurableWait(approvalId: String) async {
        guard var request = pending[approvalId], request.persistent,
              let continuation = request.continuation else { return }
        request.continuation = nil
        request.waitTimeout = nil
        pending[approvalId] = request
        continuation.resume(returning: Self.pendingOutcome(
            approvalId: approvalId, expiresAt: request.expiresAt))
    }

    private func expireInteractive(approvalId: String) async {
        guard let request = pending.removeValue(forKey: approvalId), !request.persistent else { return }
        request.timeout?.cancel()
        do {
            try await eventWriter.append(
                type: "approval.decided", principal: request.principal,
                data: .object([
                    "approvalID": .string(approvalId), "decision": .string("deny"),
                    "status": .string("denied"), "timedOut": .bool(true),
                ]))
        } catch {}
        request.continuation?.resume(returning: BotApprovalOutcome(
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
