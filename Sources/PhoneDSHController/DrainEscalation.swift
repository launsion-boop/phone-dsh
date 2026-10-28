// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHController: drain escalation budget.
//
// PLAN §2.5 / D14 and budgets.md §3 give one 20 s drain window. The drain has
// two layers of work:
//
//   1. cooperative: close admission, ask the DSH session to abort, wait for it
//      to journal its own terminal `turn/end` (G2-FIX-9);
//   2. escalation: when the Worker cannot run the cancel RPC at all (a blocked
//      job owns the execution channel), terminate the Worker/WebContent and
//      let the fresh DSH incarnation journal the terminal record, then verify
//      it (G2-FIX-105).
//
// Without a single owner of the split, the escalation phase has no deadline:
// the host either waits forever for a cancel the jammed Worker can never
// process or fails loud at the last millisecond with no bounded room left to
// terminate and verify. This type is that owner: it reserves the teardown tail,
// carves the escalation allowance out of the same window and exposes the
// absolute instants the facade's abort loop must use. It is a pure value so the
// budget is identical for every abort reason (wall/request budget, user cancel,
// background drain) and deterministic in tests.

import Foundation

/// The bounded budget of one D14 drain that must escalate.
public struct DrainEscalationPlan: Equatable, Sendable {
    /// Maximum number of Worker/WebContent terminations one drain may perform.
    ///
    /// The first attempt is the normal path; one retry absorbs a restart whose
    /// replacement Worker did not come up. More than that cannot fit a bounded
    /// window and would turn a failure into a boot loop.
    public static let maximumWorkerTerminations = 2

    /// The controller's absolute drain deadline (`Draining` started here).
    public let deadline: Date
    /// The configured drain window in seconds (the controller's 20 s default).
    public let windowSeconds: TimeInterval
    /// Window tail kept for the epoch close, the seal and the channel teardown.
    public let teardownReserve: TimeInterval
    /// Window share reserved for one terminate + fresh-Worker + verify attempt.
    public let escalationAllowance: TimeInterval

    /// Creates the budget for one drain window.
    ///
    /// - Parameters:
    ///   - deadline: the controller's absolute drain deadline.
    ///   - window: the configured drain window in seconds.
    public init(deadline: Date, window: TimeInterval) {
        let window = max(0, window)
        self.deadline = deadline
        self.windowSeconds = window
        // 10% (clamped to 0.25–2 s) is enough for the D18 epoch close and the
        // local seal after the journal is terminal; it must never be spent on a
        // Worker that refuses to settle.
        self.teardownReserve = min(2.0, max(0.25, window * 0.1))
        // 60% (clamped to 1.5–12 s) is the bounded escalation area. A healthy
        // cancel settles in milliseconds, so the cooperative phase never needs
        // half the window; the escalation needs the room for a real WebContent
        // reboot plus the replacement Worker's own session recovery. The clamp
        // keeps a short window usable and a long one from postponing the
        // escalation until only the fail-loud branch can run.
        self.escalationAllowance = min(12.0, max(1.5, window * 0.6))
    }

    /// The instant after which no more terminal-journal waiting is allowed.
    ///
    /// Everything before this instant belongs to the abort loop (cooperative
    /// cancel, then escalation); the tail afterwards belongs to the D18 epoch
    /// close and teardown. An open turn at this instant is fail loud.
    public var verifyDeadline: Date {
        deadline.addingTimeInterval(-teardownReserve)
    }

    /// The instant at which an unsettled open turn must escalate.
    ///
    /// Before it the host keeps the cooperative `session/cancel` path; at or
    /// after it the drain terminates the Worker/WebContent deterministically.
    /// The escalation allowance before ``verifyDeadline`` is what bounds the
    /// termination, the fresh-Worker wait and the bounded re-drive.
    public var escalationDeadline: Date {
        verifyDeadline.addingTimeInterval(-escalationAllowance)
    }

    /// The budget of one cooperative cancel RPC, never past the escalation
    /// point: a jammed Worker must not consume the escalation allowance.
    ///
    /// - Parameter now: the current instant.
    /// - Returns: seconds to wait, `0` when the escalation point has passed.
    public func cancelBudget(now: Date) -> TimeInterval {
        max(0, min(2.0, escalationDeadline.timeIntervalSince(now)))
    }

    /// Whether the drain must terminate the Worker/WebContent now.
    ///
    /// - Parameters:
    ///   - now: the current instant.
    ///   - attempts: escalation attempts already performed by this drain.
    /// - Returns: `true` while an escalation attempt is still in budget.
    public func shouldEscalate(now: Date, attempts: Int) -> Bool {
        now >= escalationDeadline
            && now < verifyDeadline
            && attempts < Self.maximumWorkerTerminations
    }
}
