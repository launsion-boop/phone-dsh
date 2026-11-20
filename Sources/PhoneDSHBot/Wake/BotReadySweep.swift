// SPDX-License-Identifier: MIT

import Foundation

/// The four ReadySweep steps the Bot side owns (PLAN §2.1 steps 4–7).
///
/// The shared nine-step enum lives in `ProbeKit/Lifecycle` (owned by
/// ios-launch); these raw values are the single place the Bot side names its
/// own steps, so a contract rename is a one-line change here plus the mapping
/// in `BotRuntimeComposition.runReadySweep(_:)`. The order is fixed by the
/// contract and must not be reordered.
public enum BotReadySweepStep: String, CaseIterable, Codable, Sendable, Equatable {
    /// 4. Replay pending held-inbox items (device task results and other
    ///    durable held items) through the Bot's own wake path.
    case botHeldInbox
    /// 5. Catch up routines whose `nextRunAt` already passed. Several missed
    ///    occurrences of one routine run once; quiet hours / dnd / the
    ///    existing claim lease keep their normal constraints.
    case missedRoutines
    /// 6. Connector incremental scan (Gmail / GitHub) by persisted cursor.
    case connectorScan
    /// 7. Approval reminder reconciliation.
    case approvalReminderSync

    /// Position inside the Bot-owned slice, 1-based.
    public var ordinal: Int {
        (Self.allCases.firstIndex(of: self) ?? 0) + 1
    }
}

/// The closed skip vocabulary of host §10.2.5 (only these four reasons exist
/// for a ReadySweep step). The Bot side can produce `lease` and `no-work`;
/// `already-pulled` and `gate` belong to the native steps.
public enum BotReadySweepSkipReason: String, Sendable, Equatable {
    case lease
    case noWork = "no-work"
    case gate
}

/// One Bot-owned step's outcome. Mirrors the shared `ReadySweepOutcome` shape
/// so the composition can map it without re-deciding anything.
public enum BotReadySweepOutcome: Sendable, Equatable {
    case ran
    case skipped(BotReadySweepSkipReason)
    case failed(reason: String)

    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// The Bot-side report. It only ever contains steps 4–7; the orchestrator
/// merges it into the full nine-step report.
public struct BotReadySweepReport: Sendable, Equatable {
    public struct StepResult: Sendable, Equatable {
        public let step: BotReadySweepStep
        public let outcome: BotReadySweepOutcome

        public init(step: BotReadySweepStep, outcome: BotReadySweepOutcome) {
            self.step = step
            self.outcome = outcome
        }
    }

    public var steps: [StepResult]

    public init(steps: [StepResult] = []) {
        self.steps = steps
    }

    public func outcome(for step: BotReadySweepStep) -> BotReadySweepOutcome? {
        steps.first { $0.step == step }?.outcome
    }

    public mutating func record(_ step: BotReadySweepStep, _ outcome: BotReadySweepOutcome) {
        steps.append(StepResult(step: step, outcome: outcome))
    }

    public var ranSteps: [BotReadySweepStep] {
        steps.filter { $0.outcome == .ran }.map(\.step)
    }

    public var skippedSteps: [BotReadySweepStep] {
        steps.compactMap { result in
            if case .skipped = result.outcome { return result.step }
            return nil
        }
    }

    public var failedSteps: [BotReadySweepStep] {
        steps.compactMap { result in
            if case .failed = result.outcome { return result.step }
            return nil
        }
    }

    /// Steps in the contract's fixed order, whatever order completion reported.
    public func ordered() -> BotReadySweepReport {
        BotReadySweepReport(steps: steps.sorted { $0.step.ordinal < $1.step.ordinal })
    }
}

/// The live lease gate. `remainingMs` is re-read before every step; `shouldRun`
/// is the contract's `ReadySweepPolicy` adapted by the caller, so this type
/// never carries a second threshold table.
public struct BotReadySweepBudget: Sendable {
    public var remainingMs: @Sendable () -> Int64
    public var shouldRun: @Sendable (BotReadySweepStep, Int64) -> Bool

    public init(remainingMs: @escaping @Sendable () -> Int64,
                shouldRun: @escaping @Sendable (BotReadySweepStep, Int64) -> Bool) {
        self.remainingMs = remainingMs
        self.shouldRun = shouldRun
    }
}

/// What one step actually did. A step with nothing to do reports `none`, which
/// the contract records as `skipped(reason: "no-work")` (host §10.2.5).
public enum BotReadySweepWork: Sendable, Equatable {
    case done
    case none
    /// Every unit of this step was gated (for example an unreadable cursor
    /// record during data protection): report the contract's `gate`, not a
    /// failure, and retry after the gate clears.
    case gated
}

/// Runs the Bot-owned steps sequentially, once each, checking the remaining
/// lease immediately before every step.
///
/// Rules (contract §10.2 / PLAN §2.1):
/// - a step whose budget is not available is reported `skipped(.lease)` and
///   is not started at all (never half-run);
/// - every step is attempted at most once per call, in fixed order;
/// - a failing step is reported `failed` and does not prevent the remaining
///   steps from running (each step is independently idempotent);
/// - cancellation is not in the closed skip vocabulary; it is recorded as an
///   internal failure (`failed("cancelled")`) and retried by the next wake.
public struct BotReadySweepRunner: Sendable {
    public typealias StepAction = @Sendable (BotReadySweepStep) async throws -> BotReadySweepWork

    public let budget: BotReadySweepBudget
    private let action: StepAction

    public init(budget: BotReadySweepBudget, action: @escaping StepAction) {
        self.budget = budget
        self.action = action
    }

    public func run() async -> BotReadySweepReport {
        var report = BotReadySweepReport()
        for step in BotReadySweepStep.allCases {
            let remaining = budget.remainingMs()
            guard budget.shouldRun(step, remaining) else {
                report.record(step, .skipped(.lease))
                continue
            }
            do {
                switch try await action(step) {
                case .done:
                    report.record(step, .ran)
                case .none:
                    report.record(step, .skipped(.noWork))
                case .gated:
                    report.record(step, .skipped(.gate))
                }
            } catch is CancellationError {
                // Cancellation is not one of the closed skip reasons; keep it
                // as an internal failure so the next wake retries the step.
                report.record(step, .failed(reason: Self.cancelledReason))
            } catch {
                report.record(step, .failed(reason: Self.errorToken(error)))
            }
        }
        return report
    }

    public static let cancelledReason = "cancelled"

    /// Type names only: an error message can carry request content, a path or
    /// a token fragment, and the report is diagnostic surface.
    static func errorToken(_ error: Error) -> String {
        String(describing: type(of: error))
    }
}
