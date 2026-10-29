// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHController: host and step state
// machines, fences and budgets.
//
// PLAN §2.4/§2.5 (D13/D14/D15). The controller observes host signals, owns the
// nine host states and the seven progress step states plus the terminal
// `abandoned` owner record, persists step records under
// `Library/xl/<workspace_id>/steps/`, serializes side effects behind a fence
// token and enforces the budget table.
//
// W2-CONTROLLER: the state machines, fence, ledger, budgets and restart
// scheduler are implemented in the sibling files of this module; this file
// keeps the landed W0 types and the budget table of PLAN §2.5.

import Foundation
import PhoneDSHWire

/// Host lifecycle state (PLAN §2.5).
public enum HostState: String, CaseIterable, Codable, Sendable {
    case running
    /// Admission is closed, in-flight work drains and the epoch flushes; the
    /// transitional path lasts at most 20 s.
    case draining
    case parked
    case recovering
    /// 429 or no network path; returns to running when the path recovers.
    case backoff
    case handingOff
    case remote
    case reclaiming
    /// Fail loud: user action is required before admission opens again.
    case failed
}

/// Per-step state (PLAN §2.4, D13).
///
/// Worker-executed `bash -c` steps go `tool_dispatched → wal_written →
/// journaled`; the other states exist for host-executed read-only
/// accelerators. `abandoned` is the terminal state the host records after a
/// Worker termination window expires without a terminal journal record: it is
/// not a tool result and never fabricates completion evidence.
///
/// The raw values are the canonical state names of spec/v1/exec.md §4, which
/// appear verbatim in the persisted step records, so external readers can parse
/// them by the specification.
public enum StepState: String, CaseIterable, Codable, Sendable {
    case modelStreaming = "model_streaming"
    case toolDispatched = "tool_dispatched"
    case execRunning = "exec_running"
    case exitPersisted = "exit_persisted"
    case checkpointApplied = "checkpoint_applied"
    case walWritten = "wal_written"
    case journaled = "journaled"
    /// The host gave up ownership of a step after a Worker termination window;
    /// the interrupted call has no terminal journal record and no tool result.
    case abandoned = "abandoned"

    /// `true` for the two states after which no further transition is allowed.
    /// `journaled` is the successful terminal state; `abandoned` is the
    /// terminal state of a step the host explicitly gave up.
    public var isTerminal: Bool {
        self == .journaled || self == .abandoned
    }
}

/// Execution authority (PLAN §2.4/§2.5).
public struct FenceToken: Equatable, Sendable {
    public var owner: String
    public var generation: UInt64
    public var walSeq: UInt64

    public init(owner: String, generation: UInt64, walSeq: UInt64) {
        self.owner = owner
        self.generation = generation
        self.walSeq = walSeq
    }

    /// The channel representation used by HELLO and FENCE frames.
    public var wireFence: Fence {
        Fence(owner: owner, generation: generation, walSeq: walSeq)
    }
}

/// Scene phase observed from the host OS (PLAN §2.5).
public enum ScenePhase: String, CaseIterable, Codable, Sendable {
    case active
    case inactive
    case background
}

/// Thermal pressure observed from the host OS; mirrors the four documented
/// system levels (PLAN §2.5).
public enum ThermalPressure: String, CaseIterable, Codable, Sendable {
    case nominal
    case fair
    case serious
    case critical
}

/// Battery and low-power-mode snapshot (PLAN §2.5).
public struct BatterySnapshot: Equatable, Sendable {
    /// 0...1, or `nil` when the platform does not report a level.
    public var level: Double?
    public var isLowPowerModeEnabled: Bool
    public var isCharging: Bool

    public init(level: Double?, isLowPowerModeEnabled: Bool, isCharging: Bool) {
        self.level = level
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.isCharging = isCharging
    }
}

/// Network path status; mirrors the documented NWPathMonitor cases (PLAN §2.5).
public enum NetworkPathStatus: String, CaseIterable, Codable, Sendable {
    case satisfied
    case unsatisfied
    case requiresConnection
}

/// Memory proxy sample (PLAN §2.5): VFS bytes by path prefix, session bytes and
/// the number of WebContent terminations seen in this boot.
public struct MemoryProxySample: Equatable, Sendable {
    public var vfsBytesByPrefix: [String: Int]
    public var sessionBytes: Int
    public var webContentTerminations: UInt64
    /// Sampled WebContent heap occupancy, when the engine can report it.
    ///
    /// This is the budget proxy for the append-amplification case: a worker
    /// that publishes a complete post-write file for every appended chunk can
    /// exceed the engine heap while the steady-state VFS bytes stay under the
    /// VFS cap. The facade feeds this from the engine memory probe; a `nil`
    /// sample means the engine did not report one and only the VFS proxy is
    /// evaluated.
    public var engineHeapBytes: Int?

    public init(vfsBytesByPrefix: [String: Int], sessionBytes: Int,
                webContentTerminations: UInt64, engineHeapBytes: Int? = nil) {
        self.vfsBytesByPrefix = vfsBytesByPrefix
        self.sessionBytes = sessionBytes
        self.webContentTerminations = webContentTerminations
        self.engineHeapBytes = engineHeapBytes
    }
}

/// WebContent process termination observation (PLAN §2.5).
public struct WebContentTermination: Equatable, Sendable {
    public var wasForeground: Bool
    public var terminationCount: UInt64

    public init(wasForeground: Bool, terminationCount: UInt64) {
        self.wasForeground = wasForeground
        self.terminationCount = terminationCount
    }
}

/// Background task expiration warning (PLAN §2.5).
public struct BackgroundTaskExpiration: Equatable, Sendable {
    public var taskID: String
    public var remainingSeconds: TimeInterval

    public init(taskID: String, remainingSeconds: TimeInterval) {
        self.taskID = taskID
        self.remainingSeconds = remainingSeconds
    }
}

/// Host signals that drive the state machine (PLAN §2.5).
///
/// Each stream is a long-lived observation feed; implementations may finish or
/// throw while the host is suspended and must be re-subscribed. The App (or the
/// facade) adapts UIApplication/ProcessInfo/NWPathMonitor/WebKit callbacks to
/// these streams; ``RecordedSignals`` is the deterministic test double and
/// ``SignalBus`` merges several sources. The controller itself never imports
/// UIKit/AppKit; D14 transitions are applied through
/// ``HostStateMachine/handle(_:)``.
public protocol HostSignals: Sendable {
    var scenePhase: AsyncStream<ScenePhase> { get }
    var thermal: AsyncStream<ThermalPressure> { get }
    var battery: AsyncStream<BatterySnapshot> { get }
    var path: AsyncStream<NetworkPathStatus> { get }
    var memoryProxy: AsyncStream<MemoryProxySample> { get }
    var webContentTerminated: AsyncStream<WebContentTermination> { get }
    var backgroundTaskExpiring: AsyncStream<BackgroundTaskExpiration> { get }
}

/// Device memory tier for the budget table (PLAN §2.5: tiered by model,
/// default 8 GB).
public enum DeviceTier: String, CaseIterable, Codable, Sendable {
    /// 3 GiB or less (budgets.md §4 `< 3 GiB` row).
    case threeGB = "3gb"
    case fourGB = "4gb"
    case sixGB = "6gb"
    case eightGB = "8gb"
    /// 12 GiB or more (budgets.md §4, selected only at or above 12 GiB).
    case twelveGB = "12gb"

    /// The plan's default is the 8 GB tier.
    public static let `default`: DeviceTier = .eightGB
}

/// Budget constants of PLAN §2.5, keyed by device tier.
///
/// The tier rows are the constants of spec/v1/budgets.md §4. The
/// single-file budget is configurable by the host within
/// ``minimumSingleFileLimitBytes``...``absoluteMaximumSingleFileBytes``; the
/// workspace bucket, the VFS logical cap and the engine heap grow with it via
/// ``withSingleFileLimit(_:)`` so the advertised cap is always reachable.
public struct BudgetTable: Equatable, Sendable {
    public let engineHeapBytes: Int
    public let vfsLogicalBytes: Int
    public let workspaceBytes: Int
    public let sessionBytes: Int
    public let tmpBytes: Int
    public let singleFileBytes: Int
    /// Highest single-file budget this tier may be configured with. The 4 GiB
    /// and ≤3 GiB tiers are gated to their defaults; the larger tiers may raise
    /// the cap up to the absolute maximum.
    public let maximumSingleFileBytes: Int
    public let wasiHotInstanceBytes: Int
    public let appProcessBytes: Int
    public let peakFraction: Double
    public let maxSubAgents: Int
    public let thermalFairSubAgents: Int
    public let loopbackRoundTripP95Milliseconds: Int
    public let plannedRestartIntervalSeconds: Int
    public let recoveryBaseSeconds: TimeInterval
    public let recoverySecondsPerMegabyte: Double

    /// Smallest host-configurable single-file budget (16 MiB).
    public static let minimumSingleFileLimitBytes = 16 * 1024 * 1024
    /// Largest host-configurable single-file budget (256 MiB).
    public static let absoluteMaximumSingleFileBytes = 256 * 1024 * 1024

    /// The 8 GB row of budgets.md §4. The workspace bucket holds two files at
    /// the 128 MiB cap plus 32 MiB of headroom (288 = 2 × 128 + 32); the app
    /// process allows the 60 s video encoder (+80 MB).
    public static let eightGB = BudgetTable(
        engineHeapBytes: 448 * 1024 * 1024,
        vfsLogicalBytes: 388 * 1024 * 1024,
        workspaceBytes: 288 * 1024 * 1024,
        sessionBytes: 50 * 1024 * 1024,
        tmpBytes: 50 * 1024 * 1024,
        singleFileBytes: 128 * 1024 * 1024,
        wasiHotInstanceBytes: 260 * 1024 * 1024,
        appProcessBytes: 230 * 1024 * 1024,
        peakFraction: 0.5,
        maxSubAgents: 2,
        thermalFairSubAgents: 1,
        loopbackRoundTripP95Milliseconds: 5,
        plannedRestartIntervalSeconds: 2 * 60 * 60,
        recoveryBaseSeconds: 3,
        recoverySecondsPerMegabyte: 0.05,
        maximumSingleFileBytes: 128 * 1024 * 1024
    )

    /// Tier lookup; the PLAN §2.5 row is `.eightGB`.
    public static let byTier: [DeviceTier: BudgetTable] = [
        .threeGB: .threeGB,
        .fourGB: .fourGB,
        .sixGB: .sixGB,
        .eightGB: .eightGB,
        .twelveGB: .twelveGB,
    ]

    /// Returns the budget row for a tier (the 8 GB row when unknown).
    public static func table(for tier: DeviceTier) -> BudgetTable {
        byTier[tier] ?? .eightGB
    }

    public init(engineHeapBytes: Int, vfsLogicalBytes: Int, workspaceBytes: Int,
                sessionBytes: Int, tmpBytes: Int, singleFileBytes: Int,
                wasiHotInstanceBytes: Int, appProcessBytes: Int, peakFraction: Double,
                maxSubAgents: Int, thermalFairSubAgents: Int,
                loopbackRoundTripP95Milliseconds: Int, plannedRestartIntervalSeconds: Int,
                recoveryBaseSeconds: TimeInterval, recoverySecondsPerMegabyte: Double,
                maximumSingleFileBytes: Int? = nil) {
        self.engineHeapBytes = engineHeapBytes
        self.vfsLogicalBytes = vfsLogicalBytes
        self.workspaceBytes = workspaceBytes
        self.sessionBytes = sessionBytes
        self.tmpBytes = tmpBytes
        self.singleFileBytes = singleFileBytes
        self.maximumSingleFileBytes = max(singleFileBytes,
                                          maximumSingleFileBytes ?? singleFileBytes)
        self.wasiHotInstanceBytes = wasiHotInstanceBytes
        self.appProcessBytes = appProcessBytes
        self.peakFraction = peakFraction
        self.maxSubAgents = maxSubAgents
        self.thermalFairSubAgents = thermalFairSubAgents
        self.loopbackRoundTripP95Milliseconds = loopbackRoundTripP95Milliseconds
        self.plannedRestartIntervalSeconds = plannedRestartIntervalSeconds
        self.recoveryBaseSeconds = recoveryBaseSeconds
        self.recoverySecondsPerMegabyte = recoverySecondsPerMegabyte
    }
}
