// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: recovery write-open seam.
//
// G2-FIX-93: the host may only abandon an interrupted step after the
// replacement Worker has had a real chance to run DSH's tool-journal
// reconcile. That reconcile runs on `sessionPersistence.open(id, "write")`,
// not on a history read or `session/follow`. The phone surface exposes exactly
// that write-open as a small authenticated route; this file holds the path,
// its bounded budget and the transport capability the host uses to call it.

/// Wire facts of the phone-only recovery write-open route.
public enum PhoneDSHRecoveryProtocol {
    /// Exact shared-API path served by `@phone-dsh/dsh-surface-phone`.
    public static let path = "/api/pdsh-recovery/reconcile"
    /// Phone-only path that resumes a stored session through DSH's own
    /// crash-recovery path so the pinned session layer appends its
    /// `interrupted` tail closers.
    public static let resumePath = "/api/pdsh-recovery/resume"
    /// Request and response media type.
    public static let contentType = "application/json"
    /// Default budget for one write-open, in milliseconds.
    ///
    /// The host's post-termination grace is `min(helloTimeout, 2 s)`; this
    /// leaves room for the route's final `close()` and the response round trip
    /// while ensuring the Worker stops before the host abandons the step.
    public static let defaultBudgetMilliseconds = 1_500
    /// Server-side clamp for a host-supplied budget.
    public static let maximumBudgetMilliseconds = 1_500
    /// Default budget for one DSH resume/repair. It runs the real
    /// `AgentLoop.resume` path, which also composes and disposes the temporary
    /// Agent, so it gets more room than a plain write-open.
    public static let defaultResumeBudgetMilliseconds = 3_000
    /// Server-side clamp for the resume/repair route.
    public static let maximumResumeBudgetMilliseconds = 5_000
    /// Smallest positive budget (a deadline always beats no deadline).
    public static let minimumBudgetMilliseconds = 1
}

/// Bounded time the Worker may spend on one recovery write-open.
///
/// The request carries it as the private JSON extension `timeoutMs`; the
/// server clamps it to ``PhoneDSHRecoveryProtocol/maximumBudgetMilliseconds``.
/// It is deliberately not part of the shared DSH API envelope.
public struct PhoneDSHRecoveryBudget: Equatable, Sendable {
    /// Milliseconds from request receipt to the route deadline.
    public var timeoutMilliseconds: Int

    /// Creates a budget, clamped to the protocol's accepted range.
    ///
    /// - Parameters:
    ///   - timeoutMilliseconds: requested budget.
    ///   - maximumMilliseconds: route-specific clamp (a resume may spend more
    ///     than a write-open because it also composes and disposes the Agent).
    public init(timeoutMilliseconds: Int,
                maximumMilliseconds: Int = PhoneDSHRecoveryProtocol.maximumBudgetMilliseconds) {
        self.timeoutMilliseconds = min(
            max(timeoutMilliseconds, PhoneDSHRecoveryProtocol.minimumBudgetMilliseconds),
            max(PhoneDSHRecoveryProtocol.minimumBudgetMilliseconds, maximumMilliseconds))
    }

    /// The default write-open budget, used by callers without a host deadline.
    public static let standard = PhoneDSHRecoveryBudget(
        timeoutMilliseconds: PhoneDSHRecoveryProtocol.defaultBudgetMilliseconds)

    /// The default resume/repair budget.
    public static let resumeDefault = PhoneDSHRecoveryBudget(
        timeoutMilliseconds: PhoneDSHRecoveryProtocol.defaultResumeBudgetMilliseconds,
        maximumMilliseconds: PhoneDSHRecoveryProtocol.maximumResumeBudgetMilliseconds)
}

/// A transport that can ask the Worker to open one stored session for writing.
///
/// The implementation is the ordered-channel transport; keeping this separate
/// from ``DSHRemoteTransport`` means ordinary fake transports remain unchanged
/// while the recovery path cannot silently fall back to a read-only call.
protocol PhoneDSHRecoveryCalling: Sendable {
    /// Opens `sessionID` for writing, runs the mounted tool-journal reconcile,
    /// and closes the write handle. No Agent is activated and no prompt runs.
    func reconcileSessionForRecovery(_ sessionID: String) async throws
    /// The same write-open with a host budget. The server clamps it, aborts
    /// the real reconcile/ack wait at the deadline and closes the writer
    /// before answering; it never reports success for a still-held handle.
    func reconcileSessionForRecovery(_ sessionID: String,
                                     budget: PhoneDSHRecoveryBudget) async throws
    /// Resumes `sessionID` through DSH's own crash-recovery path without
    /// publishing an Agent: it runs `AgentLoop.resume`'s durable first phase
    /// (open/read/`interruptedTurnClosers`/append/close), so a pending inbox
    /// prompt is preserved. It never creates or disposes an Agent. The pinned
    /// session layer appends the `interrupted` tail closers; Swift never writes
    /// a session record.
    func resumeSessionForRecovery(_ sessionID: String,
                                  budget: PhoneDSHRecoveryBudget) async throws
}

extension PhoneDSHRecoveryCalling {
    /// Compatibility default: a conformer that only implements the unbudgeted
    /// entry point keeps working (for example a small test transport).
    func reconcileSessionForRecovery(_ sessionID: String,
                                     budget: PhoneDSHRecoveryBudget) async throws {
        _ = budget
        try await reconcileSessionForRecovery(sessionID)
    }

    /// Compatibility default: an older test transport without the resume
    /// route fails loudly instead of silently treating a read as a repair.
    func resumeSessionForRecovery(_ sessionID: String,
                                  budget: PhoneDSHRecoveryBudget) async throws {
        _ = sessionID
        _ = budget
        throw PhoneDSHError.invalidState(
            "the transport has no DSH resume/repair route")
    }
}

// G2-FIX-93 follow-up: `ChannelDSHTransport` already implements this entry
// point, but a protocol's case cast only succeeds for a *nominal* conformance.
// Without this line the host's `base as? any PhoneDSHRecoveryCalling` silently
// failed for the production transport, so every recoverable step was abandoned.
extension ChannelDSHTransport: PhoneDSHRecoveryCalling {}
