// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — ProbeKit: Memory page runner (PLAN W3-APP).
//
// For one overlay level the runner:
//
//   1. boots the real `PhoneDSHHost` once on a fresh workspace so the
//      WorkspaceLog creates its manifest (recovery deletes an unmanifested
//      materialized tree);
//   2. writes 20/50/100 MB of deterministic synthetic files below the
//      materialized tree while no host is running;
//   3. boots the host again, which packs the overlay (gzip tar, D21) and makes
//      the Worker load it;
//   4. samples process proxy metrics and host diagnostics over the warmup and
//      a scripted long session that includes two planned WebContent restarts;
//   5. records the WebContent termination count, peak footprint, minimum
//      available memory and every sample in the exported report.
//
// The scripted session exercises host lifecycle and overlay reloads; it does
// not claim to be a model conversation (the probe app ships no model upstream).

import Foundation
import Observation
import UIKit
import PhoneDSH

/// Memory page runner.
@MainActor
@Observable
public final class MemoryProbeRunner {
    /// Coarse progress state shown by the UI.
    public enum Phase: String, Sendable {
        case idle
        case preparing
        case booting
        case sampling
        case restarting
        case finished
        case failed
    }

    /// Current phase.
    public private(set) var phase: Phase = .idle
    /// One-line progress text.
    public private(set) var statusText = "Idle"
    /// Overlay level of the current run, in MB.
    public private(set) var runningLevelMB: Int?
    /// Live samples of the current run.
    public private(set) var liveSamples: [MemorySample] = []
    /// The visible host view the App must embed.
    public let anchor: VisibleEngineAnchor
    /// Whether the packed Worker bundle is present.
    public private(set) var bundleInstalled: Bool
    /// Reason the bundle is missing, when it is.
    public let bundleDetail: String
    /// Wall clock of the last completed run.
    public private(set) var lastRunAt: String?

    private let store: DeviceReportStore
    private let baseRoot: URL
    private let warmupSeconds: Double
    private let sampleIntervalSeconds: Double
    private let stageSeconds: Double
    private let stageCount: Int
    private var hostSession: ProbeHostSession?
    private var runTask: Task<Void, Never>?

    /// Creates the runner.
    ///
    /// - Parameters:
    ///   - store: Report store shared with the App.
    ///   - baseRoot: Directory holding per-level workspaces (defaults to
    ///     `Library/xl/probe-memory` inside the app container).
    ///   - warmupSeconds / sampleIntervalSeconds / stageSeconds / stageCount:
    ///     scripted-session timing (tests may shorten them; the App uses the
    ///     defaults for a multi-minute run).
    public init(store: DeviceReportStore,
                baseRoot: URL? = nil,
                warmupSeconds: Double = 5,
                sampleIntervalSeconds: Double = 5,
                stageSeconds: Double = 15,
                stageCount: Int = 12) {
        self.store = store
        self.anchor = VisibleEngineAnchor()
        self.warmupSeconds = warmupSeconds
        self.sampleIntervalSeconds = sampleIntervalSeconds
        self.stageSeconds = stageSeconds
        self.stageCount = stageCount
        let resolved: URL
        if let baseRoot {
            resolved = baseRoot
        } else {
            let library = FileManager.default.urls(for: .libraryDirectory,
                                                   in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            resolved = library.appendingPathComponent("xl/probe-memory",
                                                      isDirectory: true)
        }
        self.baseRoot = resolved
        let installed = WorkerBundleLocator.bundle() != nil
        self.bundleInstalled = installed
        self.bundleDetail = installed ? "Worker bundle installed"
            : WorkerBundleLocator.missingReason()
    }

    /// Whether a run is in progress.
    public var isRunning: Bool {
        runTask != nil
    }

    // MARK: - Public actions

    /// Runs one overlay level: seed, boot, sample, scripted session, stop.
    public func run(levelMB: Int) {
        guard !isRunning else { return }
        guard SyntheticOverlay.levelsMB.contains(levelMB) else { return }
        liveSamples = []
        runningLevelMB = levelMB
        phase = .preparing
        statusText = "Preparing \(levelMB) MB synthetic overlay"
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.execute(levelMB: levelMB)
            self.runTask = nil
        }
    }

    /// Runs the scripted long session without a synthetic overlay.
    public func runLongSession() {
        guard !isRunning else { return }
        liveSamples = []
        runningLevelMB = nil
        phase = .preparing
        statusText = "Preparing the scripted long session"
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.executeSessionOnly()
            self.runTask = nil
        }
    }

    /// Cancels the in-flight run and stops the host.
    public func cancel() {
        runTask?.cancel()
        runTask = nil
        Task { [hostSession] in
            await hostSession?.stop()
        }
        hostSession = nil
        phase = .idle
        statusText = "Cancelled"
    }

    // MARK: - Execution

    private func execute(levelMB: Int) async {
        guard WorkerBundleLocator.bundle() != nil else {
            phase = .failed
            statusText = "Worker bundle missing: \(bundleDetail)"
            store.updateMemoryLevel(MemoryLevelResult(
                overlayMB: levelMB, status: "FAILED",
                detail: "Worker bundle missing: \(bundleDetail)"))
            return
        }
        let workspaceRoot = baseRoot.appendingPathComponent("level-\(levelMB)",
                                                            isDirectory: true)
        let manifest = workspaceRoot.appendingPathComponent("manifest.json")
        let fileManager = FileManager.default
        let startedAt = Date()
        var samples: [MemorySample] = []
        var sessionRestarts = 0
        var peakFootprint: Int64 = 0
        var minAvailable: Int64 = .max
        var terminations: UInt64 = 0
        var bootSeconds: Double?

        do {
            try fileManager.createDirectory(at: workspaceRoot,
                                            withIntermediateDirectories: true)
            try await waitForAnchor()

            // 1. First boot creates the manifest; recovery would otherwise
            //    delete an unmanifested materialized tree.
            if !fileManager.fileExists(atPath: manifest.path) {
                phase = .booting
                statusText = "First boot: creating the workspace manifest"
                let seeding = ProbeHostSession(workspaceRoot: workspaceRoot,
                                               anchor: anchor)
                hostSession = seeding
                try await seeding.start()
                bootSeconds = seeding.bootSeconds
                await seeding.stop()
                hostSession = nil
            }
            try Task.checkCancellation()

            // 2. Seed the synthetic materialized tree.
            phase = .preparing
            let overlayDirectory = workspaceRoot
                .appendingPathComponent("materialized/workspace/overlay",
                                        isDirectory: true)
            if fileManager.fileExists(atPath: overlayDirectory.path) {
                try? fileManager.removeItem(at: overlayDirectory)
            }
            let seeded = try await Task.detached(priority: .userInitiated) {
                try SyntheticOverlay.write(levelMB: levelMB, to: workspaceRoot)
            }.value
            statusText = "Seeded \(seeded.bytes / (1024 * 1024)) MB in \(seeded.files) files"
            try Task.checkCancellation()

            // 3. Second boot loads the synthetic overlay.
            phase = .booting
            let session = ProbeHostSession(workspaceRoot: workspaceRoot,
                                           anchor: anchor)
            hostSession = session
            try await session.start()
            bootSeconds = session.bootSeconds
            phase = .sampling
            statusText = "Warming up with the \(levelMB) MB overlay"
            try await wait(seconds: warmupSeconds)
            var sample = await currentSample(session: session, startedAt: startedAt)
            samples.append(sample)
            liveSamples.append(sample)
            peakFootprint = max(peakFootprint, sample.footprintBytes ?? 0)
            if let available = sample.availableBytes { minAvailable = min(minAvailable, available) }
            terminations = max(terminations, sample.webContentTerminations ?? 0)

            // 4. Scripted long session with planned restarts.
            for stage in 0..<stageCount {
                try Task.checkCancellation()
                if stage > 0 && stage % 3 == 0 {
                    phase = .restarting
                    statusText = "Planned restart \(stage / 3) at stage \(stage)"
                    try await session.plannedRestart(reason: "probe-stage-\(stage)")
                    sessionRestarts += 1
                    phase = .sampling
                }
                try await wait(seconds: stageSeconds)
                sample = await currentSample(session: session, startedAt: startedAt)
                samples.append(sample)
                liveSamples.append(sample)
                peakFootprint = max(peakFootprint, sample.footprintBytes ?? 0)
                if let available = sample.availableBytes {
                    minAvailable = min(minAvailable, available)
                }
                terminations = max(terminations,
                                   sample.webContentTerminations ?? terminations)
                statusText = "Stage \(stage + 1)/\(stageCount)"
            }

            let finalDiagnostics = await session.diagnostics()
            terminations = max(terminations,
                               finalDiagnostics?.webContentTerminations ?? 0)
            await session.stop()
            hostSession = nil
            try Task.checkCancellation()

            let measured = MemoryLevelResult(
                overlayMB: levelMB,
                status: "MEASURED",
                startedAt: ProbeReport.timestamp(startedAt),
                durationSeconds: Date().timeIntervalSince(startedAt),
                bootSeconds: bootSeconds,
                webContentTerminations: terminations,
                peakFootprintBytes: peakFootprint > 0 ? peakFootprint : nil,
                minAvailableBytes: minAvailable == .max ? nil : minAvailable,
                samples: samples,
                detail: "synthetic overlay \(levelMB) MB + scripted host session with \(sessionRestarts) planned restart(s); proxy metrics only")
            store.updateMemoryLevel(measured)
            store.updateMemorySession(MemorySessionResult(
                status: "MEASURED",
                startedAt: measured.startedAt,
                durationSeconds: measured.durationSeconds,
                plannedRestarts: sessionRestarts,
                webContentTerminations: terminations,
                peakFootprintBytes: measured.peakFootprintBytes,
                minAvailableBytes: measured.minAvailableBytes,
                samples: samples,
                detail: "scripted lifecycle session at the \(levelMB) MB overlay level"))
            lastRunAt = ProbeReport.timestamp()
            phase = .finished
            statusText = "Finished \(levelMB) MB: peak \(Self.mb(peakFootprint)), terminations \(terminations)"
        } catch is CancellationError {
            await hostSession?.stop()
            hostSession = nil
            phase = .idle
            statusText = "Cancelled"
        } catch {
            terminations = max(terminations,
                               await hostSession?.diagnostics()?.webContentTerminations ?? 0)
            await hostSession?.stop()
            hostSession = nil
            let failed = MemoryLevelResult(
                overlayMB: levelMB,
                status: "FAILED",
                startedAt: ProbeReport.timestamp(startedAt),
                durationSeconds: Date().timeIntervalSince(startedAt),
                bootSeconds: bootSeconds,
                webContentTerminations: terminations,
                peakFootprintBytes: peakFootprint > 0 ? peakFootprint : nil,
                minAvailableBytes: minAvailable == .max ? nil : minAvailable,
                samples: samples,
                detail: "FAILED: \(error)")
            store.updateMemoryLevel(failed)
            lastRunAt = ProbeReport.timestamp()
            phase = .failed
            statusText = "FAILED: \(error)"
        }
    }

    private func executeSessionOnly() async {
        guard WorkerBundleLocator.bundle() != nil else {
            phase = .failed
            statusText = "Worker bundle missing: \(bundleDetail)"
            store.updateMemorySession(MemorySessionResult(
                status: "FAILED", detail: "Worker bundle missing: \(bundleDetail)"))
            return
        }
        let workspaceRoot = baseRoot.appendingPathComponent("session", isDirectory: true)
        let startedAt = Date()
        var samples: [MemorySample] = []
        var restarts = 0
        var peakFootprint: Int64 = 0
        var minAvailable: Int64 = .max
        var terminations: UInt64 = 0
        do {
            try FileManager.default.createDirectory(at: workspaceRoot,
                                                    withIntermediateDirectories: true)
            try await waitForAnchor()
            phase = .booting
            statusText = "Booting the scripted session host"
            let session = ProbeHostSession(workspaceRoot: workspaceRoot,
                                           anchor: anchor)
            hostSession = session
            try await session.start()
            phase = .sampling
            for stage in 0..<stageCount {
                try Task.checkCancellation()
                if stage > 0 && stage % 3 == 0 {
                    phase = .restarting
                    statusText = "Planned restart \(stage / 3) at stage \(stage)"
                    try await session.plannedRestart(reason: "probe-session-\(stage)")
                    restarts += 1
                    phase = .sampling
                }
                try await wait(seconds: stageSeconds)
                let sample = await currentSample(session: session, startedAt: startedAt)
                samples.append(sample)
                liveSamples.append(sample)
                peakFootprint = max(peakFootprint, sample.footprintBytes ?? 0)
                if let available = sample.availableBytes {
                    minAvailable = min(minAvailable, available)
                }
                terminations = max(terminations,
                                   sample.webContentTerminations ?? terminations)
                statusText = "Session stage \(stage + 1)/\(stageCount)"
            }
            terminations = max(terminations,
                               await session.diagnostics()?.webContentTerminations ?? 0)
            await session.stop()
            hostSession = nil
            store.updateMemorySession(MemorySessionResult(
                status: "MEASURED",
                startedAt: ProbeReport.timestamp(startedAt),
                durationSeconds: Date().timeIntervalSince(startedAt),
                plannedRestarts: restarts,
                webContentTerminations: terminations,
                peakFootprintBytes: peakFootprint > 0 ? peakFootprint : nil,
                minAvailableBytes: minAvailable == .max ? nil : minAvailable,
                samples: samples,
                detail: "scripted lifecycle session without a synthetic overlay"))
            lastRunAt = ProbeReport.timestamp()
            phase = .finished
            statusText = "Session finished: peak \(Self.mb(peakFootprint))"
        } catch is CancellationError {
            await hostSession?.stop()
            hostSession = nil
            phase = .idle
            statusText = "Cancelled"
        } catch {
            await hostSession?.stop()
            hostSession = nil
            store.updateMemorySession(MemorySessionResult(
                status: "FAILED",
                startedAt: ProbeReport.timestamp(startedAt),
                durationSeconds: Date().timeIntervalSince(startedAt),
                plannedRestarts: restarts,
                webContentTerminations: terminations,
                samples: samples,
                detail: "FAILED: \(error)"))
            lastRunAt = ProbeReport.timestamp()
            phase = .failed
            statusText = "FAILED: \(error)"
        }
    }

    // MARK: - Helpers

    private func waitForAnchor() async throws {
        for _ in 0..<100 {
            if anchor.isInWindow { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw ProbeHostError.anchorNotAttached
    }

    private func wait(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    private func currentSample(session: ProbeHostSession,
                               startedAt: Date) async -> MemorySample {
        let diagnostics = await session.diagnostics()
        return MemorySample(
            offsetSeconds: Date().timeIntervalSince(startedAt),
            footprintBytes: ProbeProcessMetrics.physicalFootprintBytes(),
            availableBytes: ProbeProcessMetrics.availableMemoryBytes(),
            hostState: diagnostics?.hostState?.rawValue,
            vfsBytes: diagnostics?.budget?.vfsLogicalBytesUsed,
            sessionBytes: diagnostics?.budget?.sessionBytesUsed,
            walBytes: diagnostics?.budget?.walBytesUsed,
            webContentTerminations: diagnostics?.webContentTerminations)
    }

    private static func mb(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "n/a" }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}
