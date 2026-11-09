// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — App-layer resource meter (S1 round 8).
//
// Read-only measurement for the App's own display and its own UI degradation.
// It does not change admission, sub-agent caps, the host state machine or the
// memory-pressure action order: those are the host contract's
// (spec/v1/budgets.md §3/§4, BackgroundPolicies.swift, BudgetMonitor) and are
// not re-implemented here.
//
// Rules this file follows:
// * no workspace traversal of its own — the file list comes from round 6's
//   WorkspaceFileScanner snapshot;
// * WAL / response-log directory sizes are measured off the main thread at most
//   once per 30 s;
// * the diagnostic line contains numbers and enum names only (no path, file
//   name, prompt, answer or tool argument).

import Foundation
import Observation
import PhoneDSH
import struct PhoneDSHController.BudgetTable
import ProbeKit
import UIKit

/// One host-reported pair the App may read from the public diagnostics API.
/// `nil` means the host did not expose that number this boot.
private struct HostResourceMetrics {
    var engineHeapBytes: Int?
    var vfsBytes: Int?
}

/// Samples the App/host resources once per turn and grades them.
@MainActor
@Observable
final class ResourceMeter {
    /// The sampling period during an open turn (policy constant).
    static let samplingIntervalSeconds: TimeInterval = 30
    /// WAL / response-log directory scans never run more often than this.
    static let directorySampleIntervalSeconds: TimeInterval = 30

    /// The debounced band the UI shows (D.3).
    private(set) var level: ResourceLevel = .green
    /// Reasons of the latest raw classification, at the displayed band or above.
    private(set) var reasons: [ResourceReasonHit] = []
    /// The latest raw sample (also the source of the diagnostic line).
    private(set) var sample = ResourceSample()
    /// `true` between `.turnStarted` and `.turnEnded` / a cancelled or parked
    /// turn. Banners render only while this is `true`.
    private(set) var isTurnActive = false
    /// The effective, debounced classification of the latest sample.
    private(set) var classification = ResourceClassification(level: .green, reasons: [])
    /// Monotonic per-turn counter used by the diagnostics line.
    private(set) var sampledThisTurn = 0

    @ObservationIgnored private var workspaceBytes = 0
    @ObservationIgnored private var workspaceFileCount = 0
    @ObservationIgnored private var turnStartWorkspaceBytes = 0
    @ObservationIgnored private var webContentKills = 0
    @ObservationIgnored private var turnToken = 0
    @ObservationIgnored private var samplingTask: Task<Void, Never>?
    @ObservationIgnored private weak var host: PhoneDSHHost?
    @ObservationIgnored private var thresholds = ResourceThresholds.eightGB
    @ObservationIgnored private var debouncer = ResourceLevelDebouncer()
    @ObservationIgnored private var retainedRedReasons: [ResourceReasonHit] = []
    @ObservationIgnored private var directorySample: (at: Date, wal: Int, responseLog: Int)?
    @ObservationIgnored private var logSink: (String) -> Void = { _ in }
    @ObservationIgnored private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Binds the meter to one adopted host. Called after start and refresh, so
    /// a rebuilt host never keeps the old budget or diagnostics receiver.
    func attach(host: PhoneDSHHost, budgets: BudgetTable, workspaceRoot: URL,
                logSink: @escaping (String) -> Void) {
        self.host = host
        self.workspaceRoot = workspaceRoot
        self.logSink = logSink
        thresholds = ResourceThresholds(workspaceBudgetBytes: budgets.workspaceBytes,
                                        engineHeapBudgetBytes: budgets.engineHeapBytes,
                                        vfsBudgetBytes: budgets.vfsLogicalBytes)
        directorySample = nil
    }

    @ObservationIgnored private var workspaceRoot: URL?

    /// Reuses the round-6 scanner snapshot: no second traversal.
    func updateWorkspace(files: [WorkspaceFile]) {
        workspaceBytes = files.reduce(0) { total, file in
            total + max(0, file.size)
        }
        workspaceFileCount = files.count
    }

    /// Starts the per-turn sampling loop. Idempotent for one open turn.
    func beginTurn() {
        turnToken &+= 1
        let token = turnToken
        isTurnActive = true
        turnStartWorkspaceBytes = workspaceBytes
        webContentKills = 0
        sampledThisTurn = 0
        debouncer.reset(to: .green)
        retainedRedReasons = []
        samplingTask?.cancel()
        samplingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sampleNow()
            while !Task.isCancelled, self.turnToken == token {
                try? await Task.sleep(for: .seconds(ResourceMeter.samplingIntervalSeconds))
                guard !Task.isCancelled, self.turnToken == token, self.isTurnActive else { return }
                await self.sampleNow()
            }
        }
    }

    /// Ends the turn: cancel the loop and write the final line once.
    func endTurn() {
        guard isTurnActive else { return }
        isTurnActive = false
        samplingTask?.cancel()
        samplingTask = nil
        let token = turnToken
        Task { @MainActor [weak self] in
            guard let self, self.turnToken == token else { return }
            await self.sampleNow()
        }
    }

    /// A WebContent termination while a turn is open (counted for the red band
    /// and the diagnostic line).
    func recordWebContentTermination() {
        guard isTurnActive else { return }
        webContentKills += 1
    }

    /// One measurement. Directory sizes are produced off the main actor.
    @discardableResult
    func sampleNow() async -> ResourceClassification {
        var next = ResourceSample()
        next.thermal = Self.thermalState()
        let battery = Self.batterySnapshot()
        next.batteryLevel = battery.level
        next.isCharging = battery.charging
        next.lowPowerMode = battery.lowPowerMode
        next.workspaceBytes = workspaceBytes
        next.workspaceFileCount = workspaceFileCount
        next.turnWorkspaceBytes = max(0, workspaceBytes - turnStartWorkspaceBytes)
        next.webContentKills = webContentKills

        if let directories = await directorySizesIfDue() {
            next.walBytes = directories.wal
            next.responseLogBytes = directories.responseLog
        }
        if let host {
            let diagnostics = await host.diagnostics()
            let hostMetrics = HostResourceMetrics(
                engineHeapBytes: diagnostics.budget?.engineHeapBytesUsed,
                vfsBytes: diagnostics.budget?.vfsLogicalBytesUsed)
            next.engineHeapBytes = hostMetrics.engineHeapBytes
            next.vfsBytes = hostMetrics.vfsBytes
        }

        sample = next
        sampledThisTurn += 1
        let raw = ResourceLevelClassifier.classify(next, thresholds: thresholds)
        classification = raw
        let shown = debouncer.update(raw.level)
        level = shown
        if raw.reasons.contains(where: { $0.level == .red }) {
            retainedRedReasons = raw.reasons.filter { $0.level == .red }
        }
        if shown == .red, raw.level < .red {
            reasons = retainedRedReasons
        } else {
            reasons = raw.reasons.filter { $0.level == shown }
        }
        logSink(Self.logLine(sample: next, level: shown))
        return raw
    }

    // MARK: - Logging

    /// The fixed diagnostic shape. Every value is a number or an enum name.
    static func logLine(sample: ResourceSample, level: ResourceLevel) -> String {
        let battery = sample.batteryLevel.map { String(format: "%.2f", $0) } ?? "na"
        let charging = sample.isCharging.map { $0 ? "1" : "0" } ?? "na"
        let lowPower = sample.lowPowerMode.map { $0 ? "1" : "0" } ?? "na"
        let workspace: String
        if let bytes = sample.workspaceBytes {
            workspace = "\(bytes / (1024 * 1024))MB/\(sample.workspaceFileCount ?? 0)"
        } else {
            workspace = "na/na"
        }
        let wal = sample.walBytes.map { "\($0 / 1024)KB" } ?? "na"
        let responseLog = sample.responseLogBytes.map { "\($0 / (1024 * 1024))MB" } ?? "na"
        let turnWrite = sample.turnWorkspaceBytes.map { "+\($0 / (1024 * 1024))MB" } ?? "na"
        let kills = sample.webContentKills.map(String.init) ?? "na"
        let thermal = sample.thermal?.rawValue ?? "unknown"
        return "res level=\(level.rawValue) thermal=\(thermal) batt=\(battery)/charging=\(charging)"
            + "/lpm=\(lowPower) ws=\(workspace) wal=\(wal) rlog=\(responseLog)"
            + " turnWrite=\(turnWrite) wcKill=\(kills)"
    }

    // MARK: - Platform reads

    private static func thermalState() -> ResourceThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .critical
        }
    }

    private struct BatteryReading {
        var level: Double?
        var charging: Bool?
        var lowPowerMode: Bool
    }

    private static func batterySnapshot() -> BatteryReading {
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled {
            device.isBatteryMonitoringEnabled = true
        }
        let level: Double? = device.batteryLevel < 0 ? nil : Double(device.batteryLevel)
        let charging: Bool?
        switch device.batteryState {
        case .charging, .full: charging = true
        case .unplugged: charging = false
        case .unknown: charging = nil
        @unknown default: charging = nil
        }
        return BatteryReading(level: level,
                              charging: charging,
                              lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    // MARK: - File-system statistics (never on the main thread)

    private func directorySizesIfDue() async -> (wal: Int, responseLog: Int)? {
        guard let root = workspaceRoot else { return nil }
        let current = now()
        if let cached = directorySample,
           current.timeIntervalSince(cached.at) < Self.directorySampleIntervalSeconds {
            return (cached.wal, cached.responseLog)
        }
        let walDirectory = root.appendingPathComponent("wal", isDirectory: true)
        let responseLogDirectory = root.appendingPathComponent("response-log", isDirectory: true)
        let sizes = await Task.detached(priority: .utility) {
            (wal: Self.directoryBytes(walDirectory),
             responseLog: Self.directoryBytes(responseLogDirectory))
        }.value
        directorySample = (current, sizes.wal, sizes.responseLog)
        return sizes
    }

    /// Sum of regular-file bytes below `directory`; a missing directory is 0.
    nonisolated static func directoryBytes(_ directory: URL) -> Int {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true })
        else { return 0 }
        var total = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += max(0, values.fileSize ?? 0)
        }
        return total
    }
}
