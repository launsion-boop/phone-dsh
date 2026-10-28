// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — ProbeKit: Phase 0 probe report (PLAN W3-APP, G0).
//
// One report row per probe. Each row carries the metric, the G0 threshold that
// applies (when PLAN §2.5 / §3–§5 or a landed work package defines one), the
// PASS/FAIL/INFO status and the environment that produced it. Rows are written
// after every probe so a later crash still leaves the measurements that ran.
//
// Device-only values are never invented: a probe that has not run produces no
// row, and the aggregate report marks the section NOT_VERIFIED until a real
// run records a number.

import Foundation

/// Environment label recorded in every row and in the exported report.
public enum ProbeEnvironment {
    /// `ios-simulator` on the simulator, `ios-device` on a physical iPhone.
    public static var current: String {
        #if targetEnvironment(simulator)
        return "ios-simulator"
        #else
        return "ios-device"
        #endif
    }

    /// Human-readable platform name for the report header.
    public static var platform: String {
        #if targetEnvironment(simulator)
        return "iOS Simulator"
        #else
        return "iOS"
        #endif
    }
}

/// One JSON-compatible metric value.
public enum ProbeValue: Equatable, Sendable {
    case int(Int)
    case double(Double)
    case bool(Bool)
    case text(String)
    case null

    /// Text shown in the probe list.
    public var displayText: String {
        switch self {
        case .int(let value): return String(value)
        case .double(let value):
            if value.isFinite == false { return "n/a" }
            let rounded = (value * 100).rounded() / 100
            return String(rounded)
        case .bool(let value): return value ? "true" : "false"
        case .text(let value): return value
        case .null: return "—"
        }
    }

    var jsonObject: Any {
        switch self {
        case .int(let value): return value
        case .double(let value): return value
        case .bool(let value): return value
        case .text(let value): return value
        case .null: return NSNull()
        }
    }

    init(any value: Any?) {
        switch value {
        case let value as Bool: self = .bool(value)
        case let value as Int: self = .int(value)
        case let value as Int64: self = .int(Int(value))
        case let value as UInt64: self = .int(Int(clamping: value))
        case let value as Double: self = .double(value)
        case let value as String: self = .text(value)
        default: self = .null
        }
    }
}

extension ProbeValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .text(value)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .text(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// One threshold a probe is compared against.
public struct ProbeThreshold: Equatable, Sendable {
    /// Comparison direction. `.notApplicable` is used for descriptive bounds
    /// such as the recovery target `a + k × MB`, which has no single number.
    public enum Comparison: String, Sendable {
        case lessThanOrEqual = "<="
        case greaterThanOrEqual = ">="
        case equals = "=="
        case notApplicable = "n/a"
    }

    /// Threshold name.
    public var name: String
    /// Threshold value; `.text` for descriptive bounds.
    public var value: ProbeValue
    /// Unit of `value` and `measured`.
    public var unit: String
    /// Source of the bound (PLAN section / spec file).
    public var source: String
    /// Comparison direction.
    public var comparison: Comparison
    /// Measured value, or `.null` when the probe only reports information.
    public var measured: ProbeValue
    /// Whether the bound is a G0 gate. A non-gating threshold never changes
    /// the row status.
    public var gating: Bool

    public init(name: String, value: ProbeValue, unit: String, source: String,
                comparison: Comparison, measured: ProbeValue, gating: Bool) {
        self.name = name
        self.value = value
        self.unit = unit
        self.source = source
        self.comparison = comparison
        self.measured = measured
        self.gating = gating
    }

    /// Numeric comparison result, or `nil` when either side is not numeric.
    public var met: Bool? {
        guard case .double(let bound) = value else {
            if case .int(let bound) = value {
                return compare(bound: Double(bound))
            }
            return nil
        }
        return compare(bound: bound)
    }

    private func compare(bound: Double) -> Bool? {
        let actual: Double
        switch measured {
        case .double(let value): actual = value
        case .int(let value): actual = Double(value)
        default: return nil
        }
        switch comparison {
        case .lessThanOrEqual: return actual <= bound
        case .greaterThanOrEqual: return actual >= bound
        case .equals: return abs(actual - bound) < 0.000_001
        case .notApplicable: return nil
        }
    }

    public static func atMost(name: String, value: Double, unit: String, source: String,
                              measured: Double, gating: Bool) -> ProbeThreshold {
        ProbeThreshold(name: name, value: .double(value), unit: unit, source: source,
                       comparison: .lessThanOrEqual,
                       measured: measured >= 0 ? .double(measured) : .null,
                       gating: gating)
    }
}

extension ProbeThreshold: Codable {
    private enum CodingKeys: String, CodingKey {
        case name, value, unit, source, comparison, measured, met, gating
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.value = try container.decode(ProbeValue.self, forKey: .value)
        self.unit = try container.decode(String.self, forKey: .unit)
        self.source = try container.decode(String.self, forKey: .source)
        let comparisonRaw = try container.decodeIfPresent(String.self, forKey: .comparison)
            ?? Comparison.notApplicable.rawValue
        self.comparison = Comparison(rawValue: comparisonRaw) ?? .notApplicable
        self.measured = try container.decodeIfPresent(ProbeValue.self, forKey: .measured) ?? .null
        self.gating = try container.decode(Bool.self, forKey: .gating)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(value, forKey: .value)
        try container.encode(unit, forKey: .unit)
        try container.encode(source, forKey: .source)
        try container.encode(comparison.rawValue, forKey: .comparison)
        try container.encode(measured, forKey: .measured)
        if let met {
            try container.encode(met, forKey: .met)
        } else {
            try container.encodeNil(forKey: .met)
        }
        try container.encode(gating, forKey: .gating)
    }
}

/// Row status.
public enum ProbeStatus: String, Codable, Equatable, Sendable {
    case pass = "PASS"
    case fail = "FAIL"
    case info = "INFO"
}

/// One probe result.
public struct ProbeRow: Codable, Equatable, Sendable {
    public var probe: String
    public var kind: String
    public var status: ProbeStatus
    public var gating: Bool
    public var metrics: [String: ProbeValue]
    public var threshold: ProbeThreshold?
    public var detail: String
    public var recordedAt: String
    public var environment: String
}

public extension ProbeRow {
    /// Builds a row for a suite assembled outside the App's probe pages
    /// (the W3-SIM simulator gate: smoke and kill reports). The stored row
    /// shape is the one the Probes page and `probe-report.json` already use,
    /// so `scripts/ci/sim.sh` can print every suite with one table.
    static func suiteRow(probe: String,
                         kind: String,
                         status: ProbeStatus,
                         gating: Bool,
                         metrics: [String: ProbeValue],
                         threshold: ProbeThreshold?,
                         detail: String,
                         environment: String = ProbeEnvironment.current) -> ProbeRow {
        ProbeRow(probe: probe, kind: kind, status: status, gating: gating,
                 metrics: metrics, threshold: threshold, detail: detail,
                 recordedAt: ProbeReport.timestamp(), environment: environment)
    }
}

/// Aggregate counts of one report.
public struct ProbeSummary: Codable, Equatable, Sendable {
    public var pass: Int
    public var fail: Int
    public var info: Int
    public var g0Passed: Bool
    public var failedGatingProbes: [String]
}

/// A G0 bound listed in the report header even before a run.
public struct G0Threshold: Codable, Equatable, Sendable {
    public var name: String
    public var value: ProbeValue
    public var unit: String
    public var source: String
    public var gating: Bool
}

/// The JSON document written to `Documents/pdsh-reports/probe-report.json`.
public struct ProbeReportDocument: Codable, Equatable, Sendable {
    public var schema: Int
    public var generatedAt: String
    public var platform: String
    public var osVersion: String
    public var environment: String
    public var g0Thresholds: [G0Threshold]
    public var summary: ProbeSummary
    public var rows: [ProbeRow]
}

/// Thread-safe probe report.
public final class ProbeReport: @unchecked Sendable {
    /// G0 bounds from PLAN §2.5 and spec/v1/budgets.md §4. Listed in
    /// every report even before the probes run.
    public static let g0Thresholds: [G0Threshold] = [
        G0Threshold(name: "loopback_round_trip_p95", value: .double(5.0),
                    unit: "ms", source: "PLAN §2.5 and spec/v1/budgets.md §4",
                    gating: true),
        G0Threshold(name: "checkpoint_100_files", value: .double(100.0),
                    unit: "ms",
                    source: "PLAN W1-LOG (informational materialization bound)",
                    gating: false),
        G0Threshold(name: "recovery_time_target",
                    value: .text("a + k*MB, a <= 3 s, k <= 0.05 s/MB"),
                    unit: "s", source: "PLAN §2.5 and spec/v1/budgets.md §4",
                    gating: false),
    ]

    private let lock = NSLock()
    private var rows: [ProbeRow] = []
    private let directory: URL
    private let environment: String

    /// File the report is written to after every row.
    public let fileURL: URL

    /// Called after every mutation; the App hops to the main actor itself.
    public var onChange: (@Sendable () -> Void)?

    /// Creates the report under `Documents/pdsh-reports/` by default.
    public init(directory: URL? = nil, environment: String = ProbeEnvironment.current) {
        let resolved: URL
        if let directory {
            resolved = directory
        } else {
            let documents = FileManager.default.urls(for: .documentDirectory,
                                                     in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            resolved = documents.appendingPathComponent("pdsh-reports", isDirectory: true)
        }
        self.directory = resolved
        self.environment = environment
        self.fileURL = resolved.appendingPathComponent("probe-report.json")
        try? FileManager.default.createDirectory(at: resolved,
                                                 withIntermediateDirectories: true)
        write()
    }

    /// Directory holding the report (also used by the export view).
    public var reportDirectory: URL { directory }

    /// Starts a fresh report.
    public func reset() {
        lock.lock()
        rows.removeAll()
        lock.unlock()
        write()
        onChange?()
    }

    /// Appends one row and rewrites the report atomically.
    public func record(probe: String,
                       kind: String,
                       status: ProbeStatus,
                       gating: Bool,
                       metrics: [String: ProbeValue],
                       threshold: ProbeThreshold? = nil,
                       detail: String = "") {
        let row = ProbeRow(probe: probe, kind: kind, status: status, gating: gating,
                           metrics: metrics, threshold: threshold, detail: detail,
                           recordedAt: Self.timestamp(), environment: environment)
        lock.lock()
        rows.append(row)
        lock.unlock()
        write()
        onChange?()
    }

    /// Convenience overload taking untyped metric values.
    public func record(probe: String,
                       kind: String,
                       status: ProbeStatus,
                       gating: Bool,
                       metrics: [String: Any],
                       threshold: ProbeThreshold? = nil,
                       detail: String = "") {
        var converted: [String: ProbeValue] = [:]
        for (key, value) in metrics { converted[key] = ProbeValue(any: value) }
        record(probe: probe, kind: kind, status: status, gating: gating,
               metrics: converted, threshold: threshold, detail: detail)
    }

    /// Rows recorded so far, in completion order.
    public func snapshot() -> [ProbeRow] {
        lock.lock()
        defer { lock.unlock() }
        return rows
    }

    /// Aggregate counts.
    public func summary() -> ProbeSummary {
        let current = snapshot()
        let pass = current.filter { $0.status == .pass }.count
        let fail = current.filter { $0.status == .fail }.count
        let info = current.filter { $0.status == .info }.count
        let failedGating = current.filter { $0.gating && $0.status == .fail }.map(\.probe)
        return ProbeSummary(pass: pass, fail: fail, info: info,
                            g0Passed: failedGating.isEmpty,
                            failedGatingProbes: failedGating)
    }

    /// Builds the JSON document.
    public func document() -> ProbeReportDocument {
        ProbeReportDocument(schema: 1,
                            generatedAt: Self.timestamp(),
                            platform: ProbeEnvironment.platform,
                            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                            environment: environment,
                            g0Thresholds: Self.g0Thresholds,
                            summary: summary(),
                            rows: snapshot())
    }

    /// Current report encoded as pretty JSON.
    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(document())) ?? Data("{}".utf8)
    }

    /// Writes the report atomically.
    @discardableResult
    public func write() -> URL {
        let data = encoded()
        try? data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    /// Timestamp helper shared by the report and the aggregate exporter.
    public static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// Builds a row status from a correctness predicate and an optional threshold.
///
/// Correctness always gates; a non-gating (informational) threshold never
/// changes the status.
public func probeStatus(correct: Bool, threshold: ProbeThreshold? = nil) -> ProbeStatus {
    guard correct else { return .fail }
    guard let threshold else { return .pass }
    guard threshold.gating else { return .info }
    guard let met = threshold.met else { return .info }
    return met ? .pass : .fail
}
