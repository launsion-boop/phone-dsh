// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHController: budget table and monitor.
//
// PLAN §2.5 and spec/v1/budgets.md §4. The tier rows below are the
// constants of budgets.md; they are checked, never measured. Under memory
// pressure the monitor emits exactly one action per evaluation in the fixed
// order clearTmp -> plannedRestart -> handoff, and fails loud only when the
// hard cap is still exceeded after the handoff action.

import Foundation
import PhoneDSHLog
import PhoneDSHWire

extension DeviceTier {
    /// Physical memory ceiling of the tier, in bytes (budgets.md §4).
    public var physicalMemoryBytes: Int {
        switch self {
        case .threeGB: return 3 * 1024 * 1024 * 1024
        case .fourGB: return 4 * 1024 * 1024 * 1024
        case .sixGB: return 6 * 1024 * 1024 * 1024
        case .eightGB: return 8 * 1024 * 1024 * 1024
        case .twelveGB: return 12 * 1024 * 1024 * 1024
        }
    }

    /// The tier for a physical memory ceiling (budgets.md §4): the 8 GiB row
    /// is the default, a lower row applies below 8 GiB, and the 12 GiB row
    /// applies only at or above 12 GiB.
    public static func forPhysicalMemory(_ bytes: UInt64) -> DeviceTier {
        let gib = UInt64(1024 * 1024 * 1024)
        if bytes >= 12 * gib { return .twelveGB }
        if bytes >= 8 * gib { return .eightGB }
        if bytes >= 6 * gib { return .sixGB }
        if bytes >= 4 * gib { return .fourGB }
        return .threeGB
    }
}

extension BudgetTable {
    /// The 12 GiB row of budgets.md §4. Workspace = 2 × 256 MiB + 64 MiB.
    public static let twelveGB = BudgetTable(
        engineHeapBytes: 832 * 1024 * 1024,
        vfsLogicalBytes: 768 * 1024 * 1024,
        workspaceBytes: 576 * 1024 * 1024,
        sessionBytes: 96 * 1024 * 1024,
        tmpBytes: 96 * 1024 * 1024,
        singleFileBytes: 256 * 1024 * 1024,
        wasiHotInstanceBytes: 640 * 1024 * 1024,
        appProcessBytes: 540 * 1024 * 1024,
        peakFraction: 0.5,
        maxSubAgents: 2,
        thermalFairSubAgents: 1,
        loopbackRoundTripP95Milliseconds: 5,
        plannedRestartIntervalSeconds: 2 * 60 * 60,
        recoveryBaseSeconds: 3,
        recoverySecondsPerMegabyte: 0.05,
        maximumSingleFileBytes: 256 * 1024 * 1024
    )

    /// The 6 GiB row of budgets.md §4. Workspace = 2 × 48 MiB + 24 MiB.
    public static let sixGB = BudgetTable(
        engineHeapBytes: 256 * 1024 * 1024,
        vfsLogicalBytes: 200 * 1024 * 1024,
        workspaceBytes: 120 * 1024 * 1024,
        sessionBytes: 40 * 1024 * 1024,
        tmpBytes: 40 * 1024 * 1024,
        singleFileBytes: 48 * 1024 * 1024,
        wasiHotInstanceBytes: 200 * 1024 * 1024,
        appProcessBytes: 140 * 1024 * 1024,
        peakFraction: 0.5,
        maxSubAgents: 2,
        thermalFairSubAgents: 1,
        loopbackRoundTripP95Milliseconds: 5,
        plannedRestartIntervalSeconds: 2 * 60 * 60,
        recoveryBaseSeconds: 3,
        recoverySecondsPerMegabyte: 0.05,
        maximumSingleFileBytes: 128 * 1024 * 1024
    )

    /// The 4 GiB row of budgets.md §4. Workspace = 2 × 32 MiB + 16 MiB; the
    /// single-file budget is gated to the tier default.
    public static let fourGB = BudgetTable(
        engineHeapBytes: 192 * 1024 * 1024,
        vfsLogicalBytes: 144 * 1024 * 1024,
        workspaceBytes: 80 * 1024 * 1024,
        sessionBytes: 32 * 1024 * 1024,
        tmpBytes: 32 * 1024 * 1024,
        singleFileBytes: 32 * 1024 * 1024,
        wasiHotInstanceBytes: 144 * 1024 * 1024,
        appProcessBytes: 120 * 1024 * 1024,
        peakFraction: 0.5,
        maxSubAgents: 1,
        thermalFairSubAgents: 1,
        loopbackRoundTripP95Milliseconds: 5,
        plannedRestartIntervalSeconds: 2 * 60 * 60,
        recoveryBaseSeconds: 3,
        recoverySecondsPerMegabyte: 0.05,
        maximumSingleFileBytes: 32 * 1024 * 1024
    )

    /// The ≤3 GiB row of budgets.md §4. Workspace = 2 × 16 MiB + 16 MiB; the
    /// single-file budget is gated to the tier default.
    public static let threeGB = BudgetTable(
        engineHeapBytes: 144 * 1024 * 1024,
        vfsLogicalBytes: 96 * 1024 * 1024,
        workspaceBytes: 48 * 1024 * 1024,
        sessionBytes: 24 * 1024 * 1024,
        tmpBytes: 24 * 1024 * 1024,
        singleFileBytes: 16 * 1024 * 1024,
        wasiHotInstanceBytes: 96 * 1024 * 1024,
        appProcessBytes: 100 * 1024 * 1024,
        peakFraction: 0.5,
        maxSubAgents: 1,
        thermalFairSubAgents: 1,
        loopbackRoundTripP95Milliseconds: 5,
        plannedRestartIntervalSeconds: 2 * 60 * 60,
        recoveryBaseSeconds: 3,
        recoverySecondsPerMegabyte: 0.05,
        maximumSingleFileBytes: 16 * 1024 * 1024
    )

    /// Peak process allowance of the tier (budgets.md §4 "Peak").
    public func peakProcessBytes(for tier: DeviceTier) -> Int {
        Int(Double(tier.physicalMemoryBytes) * peakFraction)
    }

    /// Headroom the tier keeps above two maximum files in the workspace bucket.
    /// The default rows encode 32 / 24 / 16 / 16 MiB.
    public var workspaceHeadroomBytes: Int {
        max(0, workspaceBytes - 2 * singleFileBytes)
    }

    /// Heap headroom above the VFS logical cap (JS runtime, model chunk).
    public var engineHeapHeadroomBytes: Int {
        max(0, engineHeapBytes - vfsLogicalBytes)
    }

    /// The recovery target `a + k × MB` for a materialized tree of
    /// `megabytes` MiB (budgets.md §4).
    public func recoveryTimeTargetSeconds(forMaterializedMegabytes megabytes: Double)
        -> TimeInterval {
        recoveryBaseSeconds + recoverySecondsPerMegabyte * max(0, megabytes)
    }

    /// Whether the row is internally coherent: the workspace holds two files at
    /// the cap, the VFS cap covers the three buckets and the engine heap
    /// covers the VFS.
    public var isCoherent: Bool {
        singleFileBytes >= BudgetTable.minimumSingleFileLimitBytes
            && singleFileBytes <= maximumSingleFileBytes
            && workspaceBytes >= 2 * singleFileBytes
            && vfsLogicalBytes >= workspaceBytes + sessionBytes + tmpBytes
            && engineHeapBytes >= vfsLogicalBytes
    }

    /// Applies a host-configurable single-file budget without ever lowering a
    /// bucket. The requested value is clamped to the tier gate; workspace, VFS
    /// logical bytes, the engine heap and the WASI instance grow when needed so
    /// ``isCoherent`` stays true for every accepted value.
    public func withSingleFileLimit(_ requestedBytes: Int) -> BudgetTable {
        let ceiling = min(maximumSingleFileBytes,
                          BudgetTable.absoluteMaximumSingleFileBytes)
        let floor = min(BudgetTable.minimumSingleFileLimitBytes, ceiling)
        let limit = min(max(requestedBytes, floor), ceiling)
        let requiredWorkspace = 2 * limit + workspaceHeadroomBytes
        let requiredVFS = requiredWorkspace + sessionBytes + tmpBytes
        let requiredHeap = requiredVFS + engineHeapHeadroomBytes
        return BudgetTable(
            engineHeapBytes: max(engineHeapBytes, requiredHeap),
            vfsLogicalBytes: max(vfsLogicalBytes, requiredVFS),
            workspaceBytes: max(workspaceBytes, requiredWorkspace),
            sessionBytes: sessionBytes,
            tmpBytes: tmpBytes,
            singleFileBytes: limit,
            // The WASI hot instance follows the tier row (260 MB at 8 GiB,
            // 640 MB at 12 GiB); it is a tool-worker memory ceiling, not a
            // mirror of the VFS, and budgets.md §4 keeps it below it.
            wasiHotInstanceBytes: wasiHotInstanceBytes,
            appProcessBytes: appProcessBytes,
            peakFraction: peakFraction,
            maxSubAgents: maxSubAgents,
            thermalFairSubAgents: thermalFairSubAgents,
            loopbackRoundTripP95Milliseconds: loopbackRoundTripP95Milliseconds,
            plannedRestartIntervalSeconds: plannedRestartIntervalSeconds,
            recoveryBaseSeconds: recoveryBaseSeconds,
            recoverySecondsPerMegabyte: recoverySecondsPerMegabyte,
            maximumSingleFileBytes: maximumSingleFileBytes)
    }
}

/// Memory-pressure actions, in the fixed order of budgets.md §4.
public enum BudgetAction: String, CaseIterable, Codable, Equatable, Sendable {
    /// Clear the volatile `/dsh/tmp` prefix.
    case clearTmp
    /// Planned WebContent restart at the next tool-call boundary.
    case plannedRestart
    /// Hand execution authority to the remote.
    case handoff
}

/// One monitor evaluation. At most one action is returned per evaluation so
/// the caller can re-measure and stop as soon as the headroom is restored.
public struct BudgetDecision: Equatable, Sendable {
    /// The next action, `nil` when within budget or when the hard cap failed.
    public var action: BudgetAction?
    /// `true` when the hard cap is still exceeded after the handoff action.
    public var hardFail: Bool
    public var reason: String
    public var vfsBytes: Int
    public var vfsLimitBytes: Int
    public var webContentTerminations: UInt64
    /// Engine heap sample of this evaluation, when one was reported.
    public var engineHeapBytes: Int?
    /// Engine heap budget of the tier.
    public var engineHeapLimitBytes: Int
    /// Actions already emitted for the current pressure episode.
    public var actionsTaken: [BudgetAction]

    public init(action: BudgetAction? = nil, hardFail: Bool = false,
                reason: String = "", vfsBytes: Int = 0, vfsLimitBytes: Int = 0,
                webContentTerminations: UInt64 = 0, engineHeapBytes: Int? = nil,
                engineHeapLimitBytes: Int = 0,
                actionsTaken: [BudgetAction] = []) {
        self.action = action
        self.hardFail = hardFail
        self.reason = reason
        self.vfsBytes = vfsBytes
        self.vfsLimitBytes = vfsLimitBytes
        self.webContentTerminations = webContentTerminations
        self.engineHeapBytes = engineHeapBytes
        self.engineHeapLimitBytes = engineHeapLimitBytes
        self.actionsTaken = actionsTaken
    }

    /// `true` when the monitor has nothing to do.
    public var isClear: Bool { action == nil && !hardFail }
}

extension MemoryProxySample {
    /// Adapts the landed `WorkspaceLog.metrics()` snapshot to the memory proxy
    /// sample (PLAN §2.5). `sessionBytes` reports the session subtree and is
    /// also present under `/dsh/home/sessions` for per-prefix checks.
    public init(metrics: WorkspaceLogMetrics, webContentTerminations: UInt64,
                engineHeapBytes: Int? = nil) {
        self.init(
            vfsBytesByPrefix: [
                "/dsh/workspace": metrics.workspaceBytes,
                "/dsh/home/sessions": metrics.homeSessionsBytes,
                "/dsh/home": metrics.otherBytes,
                "/dsh/tmp": metrics.tmpBytes,
            ],
            sessionBytes: metrics.homeSessionsBytes,
            webContentTerminations: webContentTerminations,
            engineHeapBytes: engineHeapBytes)
    }
}

/// Consumes the memory proxy metrics and emits the budgets.md §4 actions.
public actor BudgetMonitor {
    /// Repeated WebContent terminations are treated as memory pressure; this
    /// is a controller policy constant, not a measurement.
    public static let defaultTerminationThreshold: UInt64 = 3

    public let table: BudgetTable
    public let terminationThreshold: UInt64
    /// Actions emitted in the current pressure episode, in order.
    public private(set) var actionsTaken: [BudgetAction] = []

    public init(table: BudgetTable = .eightGB,
                terminationThreshold: UInt64 = BudgetMonitor.defaultTerminationThreshold) {
        self.table = table
        self.terminationThreshold = max(1, terminationThreshold)
    }

    /// Evaluates one proxy sample and consumes the next action in the fixed
    /// order. A sample within budget clears the episode.
    ///
    /// This is the only method that advances ``actionsTaken``: call it after
    /// acting on the previous decision and re-measuring. Read-only snapshots
    /// (diagnostics) use ``preview(_:)`` so polling never escalates the
    /// episode.
    public func evaluate(_ sample: MemoryProxySample) -> BudgetDecision {
        let outcome = decision(for: sample, actions: actionsTaken)
        actionsTaken = outcome.actions
        return outcome.decision
    }

    /// Computes the next decision for a sample without consuming the pressure
    /// episode. A repeated call returns the same action; only ``evaluate(_:)``
    /// advances the clear-tmp -> planned-restart -> handoff order.
    public func preview(_ sample: MemoryProxySample) -> BudgetDecision {
        decision(for: sample, actions: actionsTaken).decision
    }

    private func decision(for sample: MemoryProxySample,
                          actions: [BudgetAction])
        -> (decision: BudgetDecision, actions: [BudgetAction]) {
        var actions = actions
        let workspace = sample.vfsBytesByPrefix["/dsh/workspace"] ?? 0
        let sessions = max(sample.vfsBytesByPrefix["/dsh/home/sessions"] ?? 0,
                           sample.sessionBytes)
        let tmp = sample.vfsBytesByPrefix["/dsh/tmp"] ?? 0
        let total = sample.vfsBytesByPrefix.values.reduce(0, +)
        let exceeds = total > table.vfsLogicalBytes ||
            workspace > table.workspaceBytes ||
            sessions > table.sessionBytes ||
            tmp > table.tmpBytes
        let heapExceeds = sample.engineHeapBytes.map { $0 > table.engineHeapBytes } ?? false
        let terminationPressure = sample.webContentTerminations >= terminationThreshold

        func withinBudget(_ reason: String) -> (decision: BudgetDecision,
                                               actions: [BudgetAction]) {
            (BudgetDecision(reason: reason, vfsBytes: total,
                            vfsLimitBytes: table.vfsLogicalBytes,
                            webContentTerminations: sample.webContentTerminations,
                            engineHeapBytes: sample.engineHeapBytes,
                            engineHeapLimitBytes: table.engineHeapBytes,
                            actionsTaken: actions), actions)
        }

        guard exceeds || heapExceeds || terminationPressure else {
            actions.removeAll()
            return withinBudget("within budget")
        }

        if actions.isEmpty {
            if exceeds {
                actions.append(.clearTmp)
                return decision(.clearTmp, reason: "VFS bytes exceed the budget",
                                total: total, sample: sample, actions: actions)
            }
            if heapExceeds {
                actions.append(.clearTmp)
                return decision(.clearTmp,
                                reason: "engine heap exceeds the budget",
                                total: total, sample: sample, actions: actions)
            }
            actions.append(.plannedRestart)
            return decision(.plannedRestart,
                            reason: "repeated WebContent terminations",
                            total: total, sample: sample, actions: actions)
        }

        switch actions.last {
        case .clearTmp:
            actions.append(.plannedRestart)
            return decision(.plannedRestart,
                            reason: "memory pressure persists after tmp clear",
                            total: total, sample: sample, actions: actions)
        case .plannedRestart:
            actions.append(.handoff)
            return decision(.handoff,
                            reason: "memory pressure persists after planned restart",
                            total: total, sample: sample, actions: actions)
        case .handoff:
            return (BudgetDecision(action: nil, hardFail: true,
                                   reason: "hard cap still exceeded after handoff",
                                   vfsBytes: total,
                                   vfsLimitBytes: table.vfsLogicalBytes,
                                   webContentTerminations: sample.webContentTerminations,
                                   engineHeapBytes: sample.engineHeapBytes,
                                   engineHeapLimitBytes: table.engineHeapBytes,
                                   actionsTaken: actions), actions)
        case nil:
            return withinBudget("within budget")
        }
    }

    /// Convenience for the `WorkspaceLog.metrics()` snapshot.
    public func evaluate(metrics: WorkspaceLogMetrics,
                         webContentTerminations: UInt64) -> BudgetDecision {
        evaluate(MemoryProxySample(metrics: metrics,
                                   webContentTerminations: webContentTerminations))
    }

    /// Evaluates the `WorkspaceLog.metrics()` snapshot of the workspace log.
    /// `WorkspaceLogging` does not (yet) declare `metrics()`, so the concrete
    /// landed facade type is accepted rather than widening the protocol here.
    public func evaluate(workspaceLog: WorkspaceLog,
                         webContentTerminations: UInt64) async throws -> BudgetDecision {
        let metrics = try await workspaceLog.metrics()
        return evaluate(metrics: metrics,
                        webContentTerminations: webContentTerminations)
    }

    /// Clears the pressure episode (new foreground session, metrics recovered).
    public func reset() {
        actionsTaken.removeAll()
    }

    private func decision(_ action: BudgetAction, reason: String, total: Int,
                          sample: MemoryProxySample, actions: [BudgetAction])
        -> (decision: BudgetDecision, actions: [BudgetAction]) {
        (BudgetDecision(action: action, hardFail: false, reason: reason,
                        vfsBytes: total, vfsLimitBytes: table.vfsLogicalBytes,
                        webContentTerminations: sample.webContentTerminations,
                        engineHeapBytes: sample.engineHeapBytes,
                        engineHeapLimitBytes: table.engineHeapBytes,
                        actionsTaken: actions), actions)
    }
}
