// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — App-side resource grading (S1 round 8).
//
// Pure classification of one runtime sample into green / yellow / red.
// The thresholds are policy constants kept in one place so a real-device
// calibration is a one-struct edit; they are not measurements. The App only
// measures, displays and throttles its own UI here. Thermal/battery/memory
// enforcement belongs to the host contract (spec/v1/budgets.md §3/§4) and is
// deliberately not duplicated in this file.

import Foundation

/// The three App-side resource bands.
///
/// `Comparable` is the merge rule: when several metrics disagree the highest
/// band wins.
public enum ResourceLevel: Int, Comparable, CaseIterable, Codable, Sendable {
    case green = 0
    case yellow = 1
    case red = 2

    public static func < (lhs: ResourceLevel, rhs: ResourceLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Maximum UI refresh rate for streamed transcript text.
    ///
    /// Green keeps the historical smoothness (20 updates/s); a loaded phone
    /// drops to 10/s, which is the contract for yellow and above.
    public var streamUpdatesPerSecond: Int {
        self == .green ? 20 : 10
    }

    /// The same cap as nanoseconds, for the coalescing task.
    public var streamUpdateIntervalNanoseconds: UInt64 {
        1_000_000_000 / UInt64(streamUpdatesPerSecond)
    }
}

/// `ProcessInfo.ThermalState` mapped without importing the platform enum into
/// the pure classifier. An unknown future value maps to `.critical` in the
/// App adapter, never to a lower band.
public enum ResourceThermalState: String, CaseIterable, Codable, Sendable {
    case nominal
    case fair
    case serious
    case critical
}

/// Why a sample was graded above green. Raw values are ASCII enum names so a
/// diagnostic line never carries user text.
public enum ResourceReason: String, CaseIterable, Codable, Hashable, Sendable {
    case workspacePressure
    case turnWritePressure
    case engineHeapPressure
    case vfsPressure
    case webContentTerminated
    case thermalFair
    case thermalSerious
    case thermalCritical
    case lowBattery
    case lowPowerMode

    /// User-facing (simplified Chinese, like the rest of the App copy).
    public var displayText: String {
        switch self {
        case .workspacePressure: return "工作区占用接近上限"
        case .turnWritePressure: return "本轮工作区写入超过 100 MB"
        case .engineHeapPressure: return "引擎内存占用过高"
        case .vfsPressure: return "存储空间占用过高"
        case .webContentTerminated: return "WebContent 被系统回收过"
        case .thermalFair: return "设备温度偏高"
        case .thermalSerious: return "温度过高"
        case .thermalCritical: return "温度极高"
        case .lowBattery: return "电量低于 10% 且未充电"
        case .lowPowerMode: return "已开启低电量模式"
        }
    }

    /// Stable order used by the banner: high bands first.
    static func sortedForDisplay(_ hits: [ResourceReasonHit]) -> [ResourceReasonHit] {
        let order = Dictionary(uniqueKeysWithValues: allCases.enumerated().map { ($1, $0) })
        return hits.sorted {
            if $0.level != $1.level { return $0.level > $1.level }
            return (order[$0.reason] ?? 0) < (order[$1.reason] ?? 0)
        }
    }
}

/// One reason that fired, with the band it actually reached.
///
/// The band belongs to the measurement, not to the reason: a workspace at
/// 40 % is a yellow reason while the same workspace at 90 % is red. Keeping
/// the pair prevents a yellow reason from being shown in a red headline.
public struct ResourceReasonHit: Equatable, Hashable, Sendable {
    public var reason: ResourceReason
    public var level: ResourceLevel

    public init(_ reason: ResourceReason, level: ResourceLevel) {
        self.reason = reason
        self.level = level
    }

    public var displayText: String { reason.displayText }
}

/// One read-only measurement of the App process and its runtimes.
///
/// Every field is optional: a metric the host or the platform does not expose
/// is `nil` and takes no part in the grading ("a missing metric never decides a
/// band"). The fields are deliberately plain numbers/booleans; no path, file
/// name, prompt or argument is carried here.
public struct ResourceSample: Equatable, Sendable {
    public var thermal: ResourceThermalState?
    public var batteryLevel: Double?
    public var isCharging: Bool?
    public var lowPowerMode: Bool?
    public var workspaceBytes: Int?
    public var workspaceFileCount: Int?
    /// Net workspace growth since the open turn started (never negative).
    public var turnWorkspaceBytes: Int?
    public var walBytes: Int?
    public var responseLogBytes: Int?
    /// Host-reported engine heap, when the host has reported one.
    public var engineHeapBytes: Int?
    /// Host-reported logical VFS bytes, when its diagnostics expose them.
    public var vfsBytes: Int?
    /// WebContent terminations observed during the open turn.
    public var webContentKills: Int?

    public init(thermal: ResourceThermalState? = nil,
                batteryLevel: Double? = nil,
                isCharging: Bool? = nil,
                lowPowerMode: Bool? = nil,
                workspaceBytes: Int? = nil,
                workspaceFileCount: Int? = nil,
                turnWorkspaceBytes: Int? = nil,
                walBytes: Int? = nil,
                responseLogBytes: Int? = nil,
                engineHeapBytes: Int? = nil,
                vfsBytes: Int? = nil,
                webContentKills: Int? = nil) {
        self.thermal = thermal
        self.batteryLevel = batteryLevel
        self.isCharging = isCharging
        self.lowPowerMode = lowPowerMode
        self.workspaceBytes = workspaceBytes
        self.workspaceFileCount = workspaceFileCount
        self.turnWorkspaceBytes = turnWorkspaceBytes
        self.walBytes = walBytes
        self.responseLogBytes = responseLogBytes
        self.engineHeapBytes = engineHeapBytes
        self.vfsBytes = vfsBytes
        self.webContentKills = webContentKills
    }
}

/// The one place the grading thresholds live.
///
/// The workspace fractions are relative to the tier's `Engine budgets`
/// workspace bucket, so the same percentages follow an 8 GiB / 288 MiB phone
/// to any other row. The engine-heap and VFS budgets are the tier's own rows.
public struct ResourceThresholds: Equatable, Sendable {
    public var workspaceBudgetBytes: Int
    public var engineHeapBudgetBytes: Int
    public var vfsBudgetBytes: Int
    /// `<= 60 %` green, `> 60 %` yellow, `> 85 %` red.
    public var workspaceYellowFraction: Double
    public var workspaceRedFraction: Double
    /// `<= 100 MB` green, `> 100 MB` yellow, `> 250 MB` red.
    public var turnWriteYellowBytes: Int
    public var turnWriteRedBytes: Int
    /// `<= 75 %` green, `> 75 %` yellow, `> 90 %` red.
    public var heapYellowFraction: Double
    public var heapRedFraction: Double
    public var vfsYellowFraction: Double
    public var vfsRedFraction: Double
    /// Below this fraction while not charging: yellow.
    public var batteryYellowFraction: Double

    public init(workspaceBudgetBytes: Int = 288 * 1024 * 1024,
                engineHeapBudgetBytes: Int = 448 * 1024 * 1024,
                vfsBudgetBytes: Int = 388 * 1024 * 1024,
                workspaceYellowFraction: Double = 0.60,
                workspaceRedFraction: Double = 0.85,
                turnWriteYellowBytes: Int = 100 * 1024 * 1024,
                turnWriteRedBytes: Int = 250 * 1024 * 1024,
                heapYellowFraction: Double = 0.75,
                heapRedFraction: Double = 0.90,
                vfsYellowFraction: Double = 0.75,
                vfsRedFraction: Double = 0.90,
                batteryYellowFraction: Double = 0.10) {
        self.workspaceBudgetBytes = workspaceBudgetBytes
        self.engineHeapBudgetBytes = engineHeapBudgetBytes
        self.vfsBudgetBytes = vfsBudgetBytes
        self.workspaceYellowFraction = workspaceYellowFraction
        self.workspaceRedFraction = workspaceRedFraction
        self.turnWriteYellowBytes = turnWriteYellowBytes
        self.turnWriteRedBytes = turnWriteRedBytes
        self.heapYellowFraction = heapYellowFraction
        self.heapRedFraction = heapRedFraction
        self.vfsYellowFraction = vfsYellowFraction
        self.vfsRedFraction = vfsRedFraction
        self.batteryYellowFraction = batteryYellowFraction
    }

    /// The 8 GiB default row (budgets.md §4).
    public static let eightGB = ResourceThresholds()
}

/// The result of grading one sample: the highest band plus every reason that
/// fired, in stable display order.
public struct ResourceClassification: Equatable, Sendable {
    public var level: ResourceLevel
    public var reasons: [ResourceReasonHit]

    public init(level: ResourceLevel, reasons: [ResourceReasonHit]) {
        self.level = level
        self.reasons = reasons
    }

    /// Reasons at the winning band, for the banner headline.
    public var topReasons: [ResourceReasonHit] {
        reasons.filter { $0.level == level }
    }
}

public enum ResourceLevelClassifier {
    /// Grades `sample`; any metric at a higher band raises the whole result.
    ///
    /// Boundary rules follow the published table: green owns the threshold
    /// itself (`<= 60 %`, `<= 100 MB`, `<= 75 %`, 0 kills, `nominal`/`fair`),
    /// yellow starts strictly above it, and red is strictly above its own
    /// threshold. `fair` is log-only and never changes the band: the host
    /// contract owns the one-sub-agent cap it implies.
    public static func classify(_ sample: ResourceSample,
                                thresholds: ResourceThresholds = .eightGB)
        -> ResourceClassification {
        var level = ResourceLevel.green
        var reasons: [ResourceReasonHit] = []

        func raise(_ reason: ResourceReason, to band: ResourceLevel) {
            reasons.append(ResourceReasonHit(reason, level: band))
            if band > level { level = band }
        }

        if let bytes = sample.workspaceBytes, bytes >= 0,
           thresholds.workspaceBudgetBytes > 0 {
            let ratio = Double(bytes) / Double(thresholds.workspaceBudgetBytes)
            if ratio > thresholds.workspaceRedFraction {
                raise(.workspacePressure, to: .red)
            } else if ratio > thresholds.workspaceYellowFraction {
                raise(.workspacePressure, to: .yellow)
            }
        }

        if let added = sample.turnWorkspaceBytes, added > 0 {
            if added > thresholds.turnWriteRedBytes {
                raise(.turnWritePressure, to: .red)
            } else if added > thresholds.turnWriteYellowBytes {
                raise(.turnWritePressure, to: .yellow)
            }
        }

        if let heap = sample.engineHeapBytes, heap >= 0,
           thresholds.engineHeapBudgetBytes > 0 {
            let ratio = Double(heap) / Double(thresholds.engineHeapBudgetBytes)
            if ratio > thresholds.heapRedFraction {
                raise(.engineHeapPressure, to: .red)
            } else if ratio > thresholds.heapYellowFraction {
                raise(.engineHeapPressure, to: .yellow)
            }
        }

        if let vfs = sample.vfsBytes, vfs >= 0, thresholds.vfsBudgetBytes > 0 {
            let ratio = Double(vfs) / Double(thresholds.vfsBudgetBytes)
            if ratio > thresholds.vfsRedFraction {
                raise(.vfsPressure, to: .red)
            } else if ratio > thresholds.vfsYellowFraction {
                raise(.vfsPressure, to: .yellow)
            }
        }

        if let kills = sample.webContentKills {
            if kills >= 2 {
                raise(.webContentTerminated, to: .red)
            } else if kills == 1 {
                raise(.webContentTerminated, to: .yellow)
            }
        }

        switch sample.thermal {
        case .some(.fair), .some(.nominal), .none:
            // `fair` is recorded by the diagnostic line only; it does not move
            // the App band. The host contract (spec/v1/budgets.md) is what caps
            // a sub-agent to one when the device is merely warm.
            break
        case .some(.serious):
            raise(.thermalSerious, to: .yellow)
        case .some(.critical):
            raise(.thermalCritical, to: .red)
        }

        if let battery = sample.batteryLevel, sample.isCharging == false,
           battery < thresholds.batteryYellowFraction {
            raise(.lowBattery, to: .yellow)
        }
        if sample.lowPowerMode == true {
            raise(.lowPowerMode, to: .yellow)
        }

        return ResourceClassification(level: level,
                                       reasons: ResourceReason.sortedForDisplay(reasons))
    }
}

/// Hysteresis for the App's displayed band (S1-D.3).
///
/// Upgrades apply immediately; a downgrade applies only after the sampled
/// band stayed lower for two consecutive samples. The pending downgrade is
/// keyed by the exact target band, so `red → yellow → green` cannot skip the
/// yellow step in one cycle (and `red → green → green` can drop straight to
/// green once both samples agree).
public struct ResourceLevelDebouncer: Equatable, Sendable {
    public private(set) var level: ResourceLevel
    private var pendingLevel: ResourceLevel?
    private var pendingCount = 0

    /// Number of consecutive samples a lower band must be observed before the
    /// displayed band drops.
    public var downgradeSamples: Int

    public init(initial: ResourceLevel = .green, downgradeSamples: Int = 2) {
        self.level = initial
        self.downgradeSamples = max(1, downgradeSamples)
    }

    /// Feeds one classification band and returns the band the App should show.
    @discardableResult
    public mutating func update(_ sampled: ResourceLevel) -> ResourceLevel {
        if sampled > level {
            level = sampled
            pendingLevel = nil
            pendingCount = 0
            return level
        }
        if sampled == level {
            pendingLevel = nil
            pendingCount = 0
            return level
        }
        if pendingLevel == sampled {
            pendingCount += 1
        } else {
            pendingLevel = sampled
            pendingCount = 1
        }
        if pendingCount >= downgradeSamples {
            level = sampled
            pendingLevel = nil
            pendingCount = 0
        }
        return level
    }

    /// Drops the pending downgrade, for a new turn or an explicit reset.
    public mutating func reset(to newLevel: ResourceLevel? = nil) {
        if let newLevel { level = newLevel }
        pendingLevel = nil
        pendingCount = 0
    }
}
