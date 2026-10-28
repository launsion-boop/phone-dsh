// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — ProbeKit: exported device report (PLAN W3-APP).
//
// One JSON document aggregates the three probe areas:
//
//   probes     — the Phase 0 suite rows (see ProbeReport)
//   memory     — WebContent terminations and process proxy metrics per overlay
//                level and for the scripted long session
//   background — the background/lock matrix cells, transitions and recoveries
//
// Every device-only number starts empty: the not-run defaults carry
// `status = NOT_VERIFIED` and no measured fields. The README documents the
// schema and the acceptance/device/<date>-<device>.json placement.

import Foundation
import UIKit
import WebKit

/// Application identity recorded in the report.
public struct DeviceReportApplication: Codable, Equatable, Sendable {
    public var bundleID: String
    public var displayName: String
    public var version: String
    public var build: String

    public init(bundleID: String, displayName: String, version: String, build: String) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.version = version
        self.build = build
    }
}

/// Device identity and memory capacity recorded in the report.
public struct DeviceReportDevice: Codable, Equatable, Sendable {
    public var model: String
    public var system: String
    public var name: String
    public var physicalMemoryBytes: Int64

    public init(model: String, system: String, name: String,
                physicalMemoryBytes: Int64) {
        self.model = model
        self.system = system
        self.name = name
        self.physicalMemoryBytes = physicalMemoryBytes
    }
}

/// Lockdown Mode observation.
public struct DeviceReportLockdown: Codable, Equatable, Sendable {
    /// Whether the system-wide Lockdown Mode flag is on.
    public var enabled: Bool
    /// Where the value came from (a public WebKit API, never a guess).
    public var source: String
    /// Whether the local DSH harness is expected to run (`!enabled`).
    public var localHarnessAvailable: Bool

    public init(enabled: Bool, source: String, localHarnessAvailable: Bool) {
        self.enabled = enabled
        self.source = source
        self.localHarnessAvailable = localHarnessAvailable
    }

    /// Reads `WKWebpagePreferences.isLockdownModeEnabled` from a fresh
    /// configuration. This is a system setting, not a device measurement.
    @MainActor
    public static func current() -> DeviceReportLockdown {
        let enabled = WKWebViewConfiguration()
            .defaultWebpagePreferences.isLockdownModeEnabled
        return DeviceReportLockdown(
            enabled: enabled,
            source: "WKWebpagePreferences.isLockdownModeEnabled",
            localHarnessAvailable: !enabled)
    }
}

/// One process-memory proxy sample.
public struct MemorySample: Codable, Equatable, Sendable {
    public var offsetSeconds: Double
    public var footprintBytes: Int64?
    public var availableBytes: Int64?
    public var hostState: String?
    public var vfsBytes: Int?
    public var sessionBytes: Int?
    public var walBytes: Int?
    public var webContentTerminations: UInt64?

    public init(offsetSeconds: Double, footprintBytes: Int64? = nil,
                availableBytes: Int64? = nil, hostState: String? = nil,
                vfsBytes: Int? = nil, sessionBytes: Int? = nil,
                walBytes: Int? = nil, webContentTerminations: UInt64? = nil) {
        self.offsetSeconds = offsetSeconds
        self.footprintBytes = footprintBytes
        self.availableBytes = availableBytes
        self.hostState = hostState
        self.vfsBytes = vfsBytes
        self.sessionBytes = sessionBytes
        self.walBytes = walBytes
        self.webContentTerminations = webContentTerminations
    }
}

/// Result of one synthetic overlay level.
public struct MemoryLevelResult: Codable, Equatable, Sendable {
    public var overlayMB: Int
    /// `NOT_VERIFIED`, `MEASURED`, `FAILED` or `SKIPPED`.
    public var status: String
    public var startedAt: String?
    public var durationSeconds: Double?
    public var bootSeconds: Double?
    public var webContentTerminations: UInt64?
    public var peakFootprintBytes: Int64?
    public var minAvailableBytes: Int64?
    public var samples: [MemorySample]
    public var detail: String?

    public init(overlayMB: Int, status: String, startedAt: String? = nil,
                durationSeconds: Double? = nil, bootSeconds: Double? = nil,
                webContentTerminations: UInt64? = nil,
                peakFootprintBytes: Int64? = nil, minAvailableBytes: Int64? = nil,
                samples: [MemorySample] = [], detail: String? = nil) {
        self.overlayMB = overlayMB
        self.status = status
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.bootSeconds = bootSeconds
        self.webContentTerminations = webContentTerminations
        self.peakFootprintBytes = peakFootprintBytes
        self.minAvailableBytes = minAvailableBytes
        self.samples = samples
        self.detail = detail
    }
}

/// Result of the scripted long session.
public struct MemorySessionResult: Codable, Equatable, Sendable {
    public var status: String
    public var startedAt: String?
    public var durationSeconds: Double?
    public var plannedRestarts: Int?
    public var webContentTerminations: UInt64?
    public var peakFootprintBytes: Int64?
    public var minAvailableBytes: Int64?
    public var samples: [MemorySample]
    public var detail: String?

    public init(status: String, startedAt: String? = nil,
                durationSeconds: Double? = nil, plannedRestarts: Int? = nil,
                webContentTerminations: UInt64? = nil,
                peakFootprintBytes: Int64? = nil, minAvailableBytes: Int64? = nil,
                samples: [MemorySample] = [], detail: String? = nil) {
        self.status = status
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.plannedRestarts = plannedRestarts
        self.webContentTerminations = webContentTerminations
        self.peakFootprintBytes = peakFootprintBytes
        self.minAvailableBytes = minAvailableBytes
        self.samples = samples
        self.detail = detail
    }
}

/// Memory page section.
public struct MemoryReportSection: Codable, Equatable, Sendable {
    public var levels: [MemoryLevelResult]
    public var session: MemorySessionResult
    public var notes: [String]

    public init(levels: [MemoryLevelResult], session: MemorySessionResult,
                notes: [String]) {
        self.levels = levels
        self.session = session
        self.notes = notes
    }

    /// Default before any run: every level and the session NOT_VERIFIED.
    public static func notVerified() -> MemoryReportSection {
        MemoryReportSection(
            levels: SyntheticOverlay.levelsMB.map {
                MemoryLevelResult(overlayMB: $0, status: "NOT_VERIFIED")
            },
            session: MemorySessionResult(status: "NOT_VERIFIED"),
            notes: [
                "Numbers are empty until the Memory page records a run.",
                "The overlay is a synthetic materialized-tree fixture; it is not a real session workload.",
                "The probe app ships no model upstream, so the scripted session exercises host lifecycle and overlay reloads, not model turns.",
            ])
    }
}

/// One recorded lifecycle transition of a background cell.
public struct BackgroundTransition: Codable, Equatable, Sendable {
    public var at: String
    public var kind: String
    public var from: String?
    public var to: String?
    public var detail: String?

    public init(at: String, kind: String, from: String? = nil,
                to: String? = nil, detail: String? = nil) {
        self.at = at
        self.kind = kind
        self.from = from
        self.to = to
        self.detail = detail
    }
}

/// One cell of the background/lock matrix.
public struct BackgroundCellResult: Codable, Equatable, Sendable {
    /// `background` or `lock`.
    public var scenario: String
    /// Whether the `BGContinuedProcessingTask` arm was selected.
    public var continuedProcessing: Bool
    /// `NOT_VERIFIED`, `MEASURED`, `PARTIAL` or `FAILED`.
    public var status: String
    /// The OS window that actually opened (`continued-processing`,
    /// `background-task` or `none`).
    public var arm: String?
    /// Required in-background duration (PLAN: 10 minutes = 600 s).
    public var requiredSeconds: Double
    public var observedBackgroundSeconds: Double?
    public var heldFullWindow: Bool?
    /// Whether a lock was observed through protected-data notifications.
    public var lockObserved: Bool?
    public var recovered: Bool?
    public var recoverySeconds: Double?
    public var transitions: [BackgroundTransition]
    public var detail: String?

    public init(scenario: String, continuedProcessing: Bool, status: String,
                arm: String? = nil, requiredSeconds: Double,
                observedBackgroundSeconds: Double? = nil,
                heldFullWindow: Bool? = nil, lockObserved: Bool? = nil,
                recovered: Bool? = nil, recoverySeconds: Double? = nil,
                transitions: [BackgroundTransition] = [], detail: String? = nil) {
        self.scenario = scenario
        self.continuedProcessing = continuedProcessing
        self.status = status
        self.arm = arm
        self.requiredSeconds = requiredSeconds
        self.observedBackgroundSeconds = observedBackgroundSeconds
        self.heldFullWindow = heldFullWindow
        self.lockObserved = lockObserved
        self.recovered = recovered
        self.recoverySeconds = recoverySeconds
        self.transitions = transitions
        self.detail = detail
    }
}

/// Background page section.
public struct BackgroundReportSection: Codable, Equatable, Sendable {
    public var requiredDurationSeconds: Double
    public var cells: [BackgroundCellResult]
    public var notes: [String]

    public init(requiredDurationSeconds: Double, cells: [BackgroundCellResult],
                notes: [String]) {
        self.requiredDurationSeconds = requiredDurationSeconds
        self.cells = cells
        self.notes = notes
    }

    public static func notVerified(requiredDurationSeconds: Double = 600) -> BackgroundReportSection {
        var cells: [BackgroundCellResult] = []
        for scenario in ["background", "lock"] {
            for continued in [true, false] {
                cells.append(BackgroundCellResult(
                    scenario: scenario,
                    continuedProcessing: continued,
                    status: "NOT_VERIFIED",
                    requiredSeconds: requiredDurationSeconds))
            }
        }
        return BackgroundReportSection(
            requiredDurationSeconds: requiredDurationSeconds,
            cells: cells,
            notes: [
                "Numbers are empty until the Background page records a real background/lock run.",
                "The App cannot lock the screen programmatically; the operator locks the phone and the probe records protected-data notifications.",
                "BGContinuedProcessingTask scheduling, background suspension and recovery are NOT_VERIFIED until measured on a device.",
            ])
    }

    /// Index of a matrix cell.
    public func index(scenario: String, continuedProcessing: Bool) -> Int? {
        cells.firstIndex {
            $0.scenario == scenario && $0.continuedProcessing == continuedProcessing
        }
    }
}

/// Task screen state in the report.
public struct TaskScreenReport: Codable, Equatable, Sendable {
    public var presented: Bool
    public var minimumBrightness: Double
    public var note: String

    public init(presented: Bool, minimumBrightness: Double = 0, note: String) {
        self.presented = presented
        self.minimumBrightness = minimumBrightness
        self.note = note
    }
}

/// The exported report document.
public struct DeviceReportDocument: Codable, Equatable, Sendable {
    public var schema: Int
    public var product: String
    public var generatedAt: String
    public var environment: String
    public var status: String
    public var application: DeviceReportApplication
    public var device: DeviceReportDevice
    public var lockdown: DeviceReportLockdown
    public var probes: ProbeReportDocument
    public var memory: MemoryReportSection
    public var background: BackgroundReportSection
    public var taskScreen: TaskScreenReport
    public var notes: [String]
}

/// Builds and exports the aggregate report. The App keeps one instance.
@MainActor
public final class DeviceReportStore {
    /// The Phase 0 probe report.
    public let probes: ProbeReport
    /// Memory section (starts NOT_VERIFIED).
    public private(set) var memory: MemoryReportSection
    /// Background section (starts NOT_VERIFIED).
    public private(set) var background: BackgroundReportSection
    /// Lockdown observation.
    public private(set) var lockdown: DeviceReportLockdown
    /// Whether the black task screen has been presented this session.
    public private(set) var taskScreenPresented = false
    /// Task screen minimum brightness.
    public private(set) var taskScreenMinimumBrightness: Double = 0
    /// Environment label (`ios-simulator` / `ios-device`).
    public let environment: String
    /// Directory the export file is written to.
    public let directory: URL

    /// Creates the store; `probes` is shared with the probe runner.
    public init(probes: ProbeReport,
                environment: String = ProbeEnvironment.current,
                directory: URL? = nil) {
        self.probes = probes
        self.environment = environment
        self.memory = .notVerified()
        self.background = .notVerified()
        self.lockdown = DeviceReportLockdown.current()
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
        try? FileManager.default.createDirectory(at: resolved,
                                                 withIntermediateDirectories: true)
    }

    /// Refreshes the Lockdown Mode observation.
    public func refreshLockdown() {
        lockdown = DeviceReportLockdown.current()
    }

    /// Replaces the Memory section.
    public func updateMemory(_ section: MemoryReportSection) {
        memory = section
    }

    /// Replaces the Background section.
    public func updateBackground(_ section: BackgroundReportSection) {
        background = section
    }

    /// Records that the black task screen was presented.
    public func noteTaskScreenPresented(minimumBrightness: Double) {
        taskScreenPresented = true
        taskScreenMinimumBrightness = minimumBrightness
    }

    /// One cell update for the Background page.
    public func updateBackgroundCell(_ cell: BackgroundCellResult) {
        if let index = background.index(scenario: cell.scenario,
                                        continuedProcessing: cell.continuedProcessing) {
            background.cells[index] = cell
        }
    }

    /// One level update for the Memory page.
    public func updateMemoryLevel(_ result: MemoryLevelResult) {
        if let index = memory.levels.firstIndex(where: { $0.overlayMB == result.overlayMB }) {
            memory.levels[index] = result
        }
    }

    /// Updates the scripted session result.
    public func updateMemorySession(_ result: MemorySessionResult) {
        memory.session = result
    }

    /// Top-level status: NOT_VERIFIED until a run exists, MEASURED only when
    /// every section ran, PARTIAL in between.
    public var status: String {
        let anyProbe = probes.snapshot().isEmpty == false
        let anyMemory = memory.levels.contains { $0.status != "NOT_VERIFIED" }
            || memory.session.status != "NOT_VERIFIED"
        let anyBackground = background.cells.contains { $0.status != "NOT_VERIFIED" }
        guard anyProbe || anyMemory || anyBackground else { return "NOT_VERIFIED" }
        let memoryMeasured = memory.levels.allSatisfy { $0.status == "MEASURED" }
            && memory.session.status == "MEASURED"
        let backgroundMeasured = background.cells.allSatisfy { $0.status == "MEASURED" }
        return anyProbe && memoryMeasured && backgroundMeasured ? "MEASURED" : "PARTIAL"
    }

    /// Builds the aggregate document.
    public func document() -> DeviceReportDocument {
        DeviceReportDocument(
            schema: 1,
            product: "phone-dsh-probe",
            generatedAt: ProbeReport.timestamp(),
            environment: environment,
            status: status,
            application: Self.application(),
            device: Self.device(),
            lockdown: lockdown,
            probes: probes.document(),
            memory: memory,
            background: background,
            taskScreen: TaskScreenReport(
                presented: taskScreenPresented,
                minimumBrightness: taskScreenMinimumBrightness,
                note: "Pure-black low-brightness task screen from PhoneDSH Background; screen dimming is best effort and NOT_VERIFIED on a device."),
            notes: [
                "Device-only values are absent until a run records them; each section carries its own status.",
                "This App build runs with environment=\(environment); it does not claim measured iPhone behaviour unless the row was produced on a device.",
                "The probe app ships no model upstream; the scripted session exercises host lifecycle and overlay reloads, not model turns.",
            ])
    }

    /// Encoded aggregate report.
    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(document())) ?? Data("{}".utf8)
    }

    /// Writes the aggregate report and returns its URL. The suggested file
    /// name is `<date>-<device>.json` (README: copy it to
    /// `acceptance/device/` in the repository).
    public func writeExport() -> URL {
        let url = directory.appendingPathComponent(Self.exportFileName())
        try? encoded().write(to: url, options: .atomic)
        return url
    }

    /// `<yyyy-MM-dd>-<model>.json`, with the hardware model sanitized.
    public static func exportFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let model = Self.device().model
            .replacingOccurrences(of: ",", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return "\(formatter.string(from: date))-\(model).json"
    }

    // MARK: - Identity

    /// Bundle identity read from Info.plist.
    public static func application() -> DeviceReportApplication {
        let info = Bundle.main.infoDictionary ?? [:]
        return DeviceReportApplication(
            bundleID: info["CFBundleIdentifier"] as? String ?? "unknown",
            displayName: info["CFBundleDisplayName"] as? String
                ?? info["CFBundleName"] as? String ?? "PhoneDSHProbe",
            version: info["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info["CFBundleVersion"] as? String ?? "unknown")
    }

    /// Device identity through public APIs.
    public static func device() -> DeviceReportDevice {
        let device = UIDevice.current
        return DeviceReportDevice(
            model: hardwareModel(),
            system: "\(device.systemName) \(device.systemVersion)",
            name: device.name,
            physicalMemoryBytes: ProbeProcessMetrics.physicalMemoryBytes())
    }

    /// Hardware identifier (`uname(2).machine`, e.g. `iPhone17,1`).
    public static func hardwareModel() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}
