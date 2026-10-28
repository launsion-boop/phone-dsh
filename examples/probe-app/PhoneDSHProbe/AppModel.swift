// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS Phase 0 probe app (PLAN W3-APP).
//
// App-wide state: the shared probe report, the device report store, the probe
// suite runner and the Memory/Background page runners. The environment label
// and the Lockdown Mode observation are refreshed on every foreground return.

import Observation
import ProbeKit
import SwiftUI
import PhoneDSH

/// An individually runnable probe group.
enum ProbeGroup: String, CaseIterable, Identifiable {
    case channel
    case isolationOff
    case throttling
    case jit
    case checkpoint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .channel: return "Channel (fetch/NDJSON/WS/COOP-COEP)"
        case .isolationOff: return "COOP/COEP off"
        case .throttling: return "Timer throttling"
        case .jit: return "JIT baseline"
        case .checkpoint: return "WorkspaceLog checkpoint"
        }
    }
}

/// Observable App model shared through the SwiftUI environment.
@MainActor
@Observable
final class AppModel {
    /// Shared Phase 0 probe report.
    let report: ProbeReport
    /// Aggregate report used by the Export page.
    let store: DeviceReportStore
    /// Probe suite runner.
    let probeRunner: ProbeSuiteRunner
    /// Visible one-point anchor the Probes page embeds for the probe WKWebViews.
    let probeAnchor = VisibleEngineAnchor()
    /// Memory page runner.
    let memory: MemoryProbeRunner
    /// Background page runner.
    let background: BackgroundProbeRunner

    /// Rows currently in the report.
    private(set) var probeRows: [ProbeRow] = []
    /// Aggregate counts.
    private(set) var probeSummary: ProbeSummary
    /// Whether a probe group is running.
    private(set) var probeRunning = false
    /// What is running right now.
    private(set) var probeStatusText = "No probe has run in this launch"
    /// Latest Lockdown Mode observation.
    private(set) var lockdown: DeviceReportLockdown
    /// A monotonic counter that invalidates the Export preview.
    private(set) var reportRevision: Int = 0

    init() {
        let report = ProbeReport()
        let store = DeviceReportStore(probes: report)
        self.report = report
        self.store = store
        self.probeRunner = ProbeSuiteRunner(report: report)
        self.memory = MemoryProbeRunner(store: store)
        self.background = BackgroundProbeRunner(store: store)
        self.probeSummary = report.summary()
        self.lockdown = DeviceReportLockdown.current()
        self.probeRows = report.snapshot()
        report.onChange = { [weak self] in
            Task { @MainActor in
                self?.reloadProbes()
            }
        }
    }

    /// Refreshes the cached probe rows and the report revision.
    func reloadProbes() {
        probeRows = report.snapshot()
        probeSummary = report.summary()
        reportRevision += 1
    }

    /// Runs the whole Phase 0 suite.
    func runAllProbes() {
        guard !probeRunning else { return }
        probeRunning = true
        probeStatusText = "Running the full suite"
        Task {
            await probeRunner.runAll(anchor: probeAnchor.view)
            probeRunning = false
            probeStatusText = "Suite finished"
            reloadProbes()
            refreshLockdown()
        }
    }

    /// Runs one probe group.
    func runProbe(_ group: ProbeGroup) {
        guard !probeRunning else { return }
        probeRunning = true
        probeStatusText = "Running \(group.title)"
        Task {
            switch group {
            case .channel:
                await probeRunner.runChannel(anchor: probeAnchor.view)
            case .isolationOff:
                await probeRunner.runIsolationOff(anchor: probeAnchor.view)
            case .throttling:
                await probeRunner.runThrottling(anchor: probeAnchor.view)
            case .jit:
                await probeRunner.runJIT(anchor: probeAnchor.view)
            case .checkpoint:
                await probeRunner.runCheckpoint()
            }
            probeRunning = false
            probeStatusText = "\(group.title) finished"
            reloadProbes()
        }
    }

    /// Clears the probe report (other sections are kept).
    func resetProbes() {
        guard !probeRunning else { return }
        report.reset()
        probeStatusText = "Probe report cleared"
        reloadProbes()
    }

    /// Re-reads the system Lockdown Mode flag.
    func refreshLockdown() {
        store.refreshLockdown()
        lockdown = store.lockdown
    }

    /// Forwards a scene-phase change to the background matrix.
    func scenePhaseChanged(_ phase: ScenePhase) async {
        if phase == .active { refreshLockdown() }
        await background.scenePhaseChanged(phase)
    }

    /// Writes and returns the aggregate report URL.
    func writeExport() -> URL {
        refreshLockdown()
        let url = store.writeExport()
        reportRevision += 1
        return url
    }

    /// Current export payload for the in-app preview.
    func exportPreview() -> String {
        guard let text = String(data: store.encoded(), encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
