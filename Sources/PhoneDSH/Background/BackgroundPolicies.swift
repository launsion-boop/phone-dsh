// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: thermal and battery policies.
//
// PLAN §2.5 and budgets.md §3/§4:
//
//   thermal fair        -> sub-agent cap 1
//   thermal serious     -> sub-agent cap 1, pause new work at the next
//                          tool-call boundary, no optional accelerators,
//                          suggest a handoff
//   thermal critical    -> same as serious
//   battery < 20 % and not charging, or Low Power Mode
//                       -> sub-agent cap 1, no optional accelerators
//
// The policy is a pure function of the observed signals and the budget table.
// It never raises a budget: the returned cap is always between 1 and
// `BudgetTable.maxSubAgents` (the lowest tier row already caps at one).

import Foundation
import PhoneDSHController

/// The one decision the lifecycle gate and UI need from the environment.
public enum BackgroundPolicyAction: String, CaseIterable, Codable, Sendable {
    /// No pressure: use the budget table's sub-agent cap.
    case run
    /// Lower the sub-agent cap and/or drop optional accelerators.
    case limitSubAgents
    /// Pause new work at the next tool-call boundary (serious/critical heat).
    case pauseAtNextBoundary
    /// Stop starting new local work and suggest a handoff to the remote.
    case suggestHandoff
}

/// Evaluation of thermal + battery signals against one budget table.
public struct BackgroundPolicyDecision: Equatable, Sendable {
    /// The most urgent effect of the current environment.
    public var action: BackgroundPolicyAction
    /// Sub-agent concurrency cap; `1...BudgetTable.maxSubAgents`.
    public var subAgentCap: Int
    /// `true` when the lifecycle gate must send LIFECYCLE `pause` at the next
    /// tool-call boundary and must not start new sub-agents or parallel
    /// accelerators.
    public var pausesNewWork: Bool
    /// `false` when optional read-only accelerators must not be started.
    public var allowsOptionalAccelerators: Bool
    /// `true` when the UI should offer a handoff to the remote.
    public var suggestsHandoff: Bool
    /// Machine-readable reasons, in evaluation order.
    public var reasons: [String]

    public init(action: BackgroundPolicyAction, subAgentCap: Int,
                pausesNewWork: Bool, allowsOptionalAccelerators: Bool,
                suggestsHandoff: Bool, reasons: [String]) {
        self.action = action
        self.subAgentCap = subAgentCap
        self.pausesNewWork = pausesNewWork
        self.allowsOptionalAccelerators = allowsOptionalAccelerators
        self.suggestsHandoff = suggestsHandoff
        self.reasons = reasons
    }

    /// `true` when the environment needs no restriction beyond the table.
    public var isNominal: Bool { action == .run }
}

/// Pure thermal/battery policy table.
public enum BackgroundPolicies {
    /// Battery fraction below which the App limits concurrency while not
    /// charging (budgets.md §3).
    public static let lowBatteryThreshold: Double = 0.2

    /// Evaluates the environment.
    ///
    /// - Parameters:
    ///   - thermal: `ProcessInfo.thermalState` mapped to ``ThermalPressure``.
    ///   - battery: Battery level, charging state and Low Power Mode.
    ///   - budgets: The tier row; the cap is never raised above it.
    public static func evaluate(thermal: ThermalPressure,
                                battery: BatterySnapshot,
                                budgets: BudgetTable = .eightGB)
        -> BackgroundPolicyDecision {
        let tableCap = max(1, budgets.maxSubAgents)
        let fairCap = min(tableCap, max(1, budgets.thermalFairSubAgents))
        var cap = tableCap
        var reasons: [String] = []
        var pausesNewWork = false
        var allowsOptionalAccelerators = true
        var suggestsHandoff = false
        var action = BackgroundPolicyAction.run

        switch thermal {
        case .nominal:
            break
        case .fair:
            cap = min(cap, fairCap)
            reasons.append("thermal fair")
            action = .limitSubAgents
        case .serious, .critical:
            cap = min(cap, fairCap)
            pausesNewWork = true
            allowsOptionalAccelerators = false
            suggestsHandoff = true
            reasons.append("thermal \(thermal.rawValue)")
            action = .suggestHandoff
        }

        let lowBattery = (battery.level.map { $0 < lowBatteryThreshold } ?? false)
            && !battery.isCharging
        if lowBattery {
            cap = min(cap, 1)
            allowsOptionalAccelerators = false
            reasons.append("battery below 20 percent and not charging")
            if action == .run { action = .limitSubAgents }
        }
        if battery.isLowPowerModeEnabled {
            cap = min(cap, 1)
            allowsOptionalAccelerators = false
            reasons.append("low power mode")
            if action == .run { action = .limitSubAgents }
        }

        // Budgets are never raised by an environmental signal.
        cap = max(1, min(cap, tableCap))
        return BackgroundPolicyDecision(
            action: action,
            subAgentCap: cap,
            pausesNewWork: pausesNewWork,
            allowsOptionalAccelerators: allowsOptionalAccelerators,
            suggestsHandoff: suggestsHandoff,
            reasons: reasons)
    }
}
