// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — the ReadySweep contract: seven ordered, idempotent
// steps run once per (engine incarnation, wake) inside the remaining lease.
//
// host contract `spec/host/v1/README.md` §10.2 (P06); PLAN §2.1. The
// orchestrator owns steps 1–3 (native) and `BotRuntimeComposition` owns steps
// 4–7 (Bot); the orchestrator merges one report in this order.

import Foundation

/// The seven steps, in their fixed order (host §10.2 `steps[7]`, PLAN §2.1).
///
/// The raw values are the contract's step identifiers. They live here and
/// nowhere else: the golden test maps `steps[]`/`sweepVectors[].step` through
/// this single enum, so a contract rename touches one place.
public enum ReadySweepStep: String, CaseIterable, Codable, Sendable, Equatable {
    /// 1. The user's own queued outbox messages (highest priority).
    case userOutbox
    /// 2. The external-admission pass: already admitted voice/cloud requests.
    case externalAdmission
    /// 3. One cloud-task pull, skipped when this wake already pulled in 30 s.
    case cloudTaskPull
    /// 4. Bot held-inbox replay (device task results and other durable items).
    case botHeldInbox
    /// 5. Missed routines whose `nextRunAt` has passed (dnd / quiet hours keep
    ///    their existing constraints).
    case missedRoutines
    /// 6. Connector incremental scan (Gmail / GitHub) by persisted cursor.
    case connectorScan
    /// 7. Approval reminder reconciliation.
    case approvalReminderSync
    /// 8. The DSH schedule mirror (`engine.wakeHint` → WakeDemand): the host
    ///    confirms the engine is ready; the DSH runtime itself catches up the
    ///    overdue schedules (PLAN §2.9).
    case dshSchedule
    /// 9. Host-owned retries (engine backoff, outbox settle flush) that were
    ///    written as WakeDemands instead of living only in `Task.sleep`.
    case hostRetries

    /// Position in the fixed order, 1-based.
    public var ordinal: Int {
        (Self.allCases.firstIndex(of: self) ?? 0) + 1
    }
}

/// One step's result.
public enum ReadySweepOutcome: Sendable, Equatable {
    case ran
    case skipped(reason: String)
    case failed(reason: String)
}

/// `ReadySweepReport { steps: [(step, outcome)] }` (PLAN §4).
public struct ReadySweepReport: Sendable, Equatable {
    public struct StepResult: Sendable, Equatable {
        public let step: ReadySweepStep
        public let outcome: ReadySweepOutcome

        public init(step: ReadySweepStep, outcome: ReadySweepOutcome) {
            self.step = step
            self.outcome = outcome
        }
    }

    public var steps: [StepResult]

    public init(steps: [StepResult] = []) {
        self.steps = steps
    }

    public func outcome(for step: ReadySweepStep) -> ReadySweepOutcome? {
        steps.first { $0.step == step }?.outcome
    }

    public mutating func record(_ step: ReadySweepStep, _ outcome: ReadySweepOutcome) {
        steps.append(StepResult(step: step, outcome: outcome))
    }

    /// Steps in the contract's fixed order, regardless of completion order.
    public func ordered() -> ReadySweepReport {
        ReadySweepReport(steps: steps.sorted { $0.step.ordinal < $1.step.ordinal })
    }

    public var ranSteps: [ReadySweepStep] {
        steps.filter { $0.outcome == .ran }.map(\.step)
    }

    public var failedSteps: [ReadySweepStep] {
        steps.compactMap { result in
            if case .failed = result.outcome { return result.step }
            return nil
        }
    }
}

/// The one context handed to `BotRuntimeComposition.runReadySweep(_:)`
/// (PLAN §4).
///
/// `remainingMs` is a closure: the Bot side re-reads it before every step, so
/// the lease is a live value and never a number computed once at the start.
public struct ReadySweepContext: Sendable {
    public let wakeId: String
    public let reason: WakeReason
    public let engineIncarnation: Int
    public let remainingMs: @Sendable () -> Int64

    public init(wakeId: String, reason: WakeReason, engineIncarnation: Int,
                remainingMs: @escaping @Sendable () -> Int64) {
        self.wakeId = wakeId
        self.reason = reason
        self.engineIncarnation = engineIncarnation
        self.remainingMs = remainingMs
    }
}

/// Per-step lease gate (PLAN §2.1: check before each step; an unfinished step
/// is left whole for the next wake — never half-run).
///
/// Host §10.2 frozen r1: `shouldRun == remainingMs >= parkMarginMs + stepBudgetMs(step)`.
/// The budgets are the contract constants; the golden test reads them from
/// `constants.stepBudgetMs` instead of trusting this copy.
public enum ReadySweepPolicy {
    public static func stepBudgetMs(for step: ReadySweepStep) -> Int64 {
        switch step {
        case .userOutbox: return 2_000
        case .externalAdmission: return 2_000
        case .cloudTaskPull: return 5_000
        case .botHeldInbox: return 2_000
        case .missedRoutines: return 5_000
        case .connectorScan: return 10_000
        case .approvalReminderSync: return 1_000
        case .dshSchedule: return 2_000
        case .hostRetries: return 2_000
        }
    }

    public static func shouldRun(_ step: ReadySweepStep, remainingMs: Int64) -> Bool {
        remainingMs >= EngineLaunchThresholds.parkMarginMs + stepBudgetMs(for: step)
    }
}
