// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — ProbeKit: Background page runner (PLAN W3-APP).
//
// The matrix is background / lock × 10 minutes × with/without the iOS 26
// `BGContinuedProcessingTask` window:
//
//   background  — the operator presses Home; the App parks the host, records
//                 every controller transition and proxy sample it can observe,
//                 waits the required wall-clock duration and resumes on return.
//   lock        — the operator locks the phone; the runner additionally records
//                 `protectedDataDidBecomeUnavailable`/`Available` notifications
//                 as the lock signal.
//
// The App cannot lock the screen programmatically and cannot keep itself
// awake in the background; both are operator actions and the measured result
// is whatever the platform actually allowed. `heldFullWindow` is only true
// when the observed background interval reached the required duration.
// NOT_VERIFIED on an iPhone until a device run records it.

import Foundation
import Observation
import SwiftUI
import UIKit
import PhoneDSH

/// Background page runner.
@MainActor
@Observable
public final class BackgroundProbeRunner {
    /// Matrix row.
    public enum Scenario: String, CaseIterable, Sendable {
        case background
        case lock

        public var title: String {
            switch self {
            case .background: return "Background"
            case .lock: return "Lock"
            }
        }
    }

    /// Current phase shown by the UI.
    public enum Phase: String, Sendable {
        case idle
        case booting
        case waitingForBackground
        case backgrounded
        case recovering
        case finished
        case failed
    }

    /// The visible host view the App must embed.
    public let anchor: VisibleEngineAnchor
    /// Selected matrix row.
    public var scenario: Scenario = .background
    /// Whether the `BGContinuedProcessingTask` arm is requested.
    public var continuedProcessing = true
    /// Required in-background duration. 600 s is the PLAN matrix; the App also
    /// offers a short check that never counts as the full window.
    public var requiredSeconds: Double = 600

    /// The PLAN matrix window (10 minutes). A shorter run is a UI check and
    /// never marks a cell MEASURED.
    public static let planMatrixSeconds: Double = 600

    /// Current phase.
    public private(set) var phase: Phase = .idle
    /// One-line status.
    public private(set) var statusText = "Idle"
    /// Whether a run is in progress.
    public private(set) var isRunning = false
    /// Recorded lifecycle transitions of the current/last run.
    public private(set) var transitions: [BackgroundTransition] = []
    /// Measured background interval of the last completed run.
    public private(set) var observedBackgroundSeconds: Double?
    /// Whether the OS offered the continued-processing arm.
    public private(set) var openedArm: String?
    /// Whether a lock was observed during the last run.
    public private(set) var lockObserved = false
    /// Whether the host resumed after the run.
    public private(set) var recovered: Bool?
    /// Recovery duration of the last run.
    public private(set) var recoverySeconds: Double?
    /// Last fail-loud text (host or scheduler).
    public private(set) var lastError: String?
    /// Whether the packed Worker bundle is present.
    public private(set) var bundleInstalled: Bool
    /// Reason the bundle is missing, when it is.
    public let bundleDetail: String
    /// State text of the probe host.
    public private(set) var hostStateText = "not booted"

    private let store: DeviceReportStore
    private let baseRoot: URL
    private var hostSession: ProbeHostSession?
    private var scheduler: (any BackgroundTaskScheduling)?
    private var windowToken: BackgroundTaskToken?
    private var startedAt: Date?
    private var backgroundedAt: Date?
    private var sampleTask: Task<Void, Never>?
    private var parkTask: Task<Void, Never>?
    private var lockUnavailableObserver: NSObjectProtocol?
    private var lockAvailableObserver: NSObjectProtocol?
    private var closed = false

    /// Creates the runner.
    public init(store: DeviceReportStore, baseRoot: URL? = nil) {
        self.store = store
        self.anchor = VisibleEngineAnchor()
        let resolved: URL
        if let baseRoot {
            resolved = baseRoot
        } else {
            let library = FileManager.default.urls(for: .libraryDirectory,
                                                   in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            resolved = library.appendingPathComponent("xl/probe-background",
                                                      isDirectory: true)
        }
        self.baseRoot = resolved
        let installed = WorkerBundleLocator.bundle() != nil
        self.bundleInstalled = installed
        self.bundleDetail = installed ? "Worker bundle installed"
            : WorkerBundleLocator.missingReason()
        installLockObservers()
    }

    // MARK: - Run control

    /// Starts one matrix cell. The operator then backgrounds or locks the App.
    public func start() {
        guard !isRunning else { return }
        guard WorkerBundleLocator.bundle() != nil else {
            statusText = "Worker bundle missing: \(bundleDetail)"
            phase = .failed
            return
        }
        isRunning = true
        closed = false
        startedAt = Date()
        backgroundedAt = nil
        observedBackgroundSeconds = nil
        openedArm = nil
        lockObserved = false
        recovered = nil
        recoverySeconds = nil
        lastError = nil
        transitions = []
        phase = .booting
        statusText = "Booting the probe host"

        scheduler = continuedProcessing
            ? PlatformBackgroundTaskScheduler()
            : NoopBackgroundTaskScheduler()

        Task { [weak self] in
            guard let self else { return }
            do {
                let session = ProbeHostSession(
                    workspaceRoot: self.baseRoot.appendingPathComponent("workspace",
                                                                       isDirectory: true),
                    anchor: self.anchor)
                self.hostSession = session
                try await self.waitForAnchor()
                try await session.start()
                self.hostStateText = await session.diagnostics()?.hostState?.rawValue
                    ?? "unknown"
                await self.openWindow()
                self.phase = .waitingForBackground
                self.statusText = self.scenario == .lock
                    ? "Lock the phone now and keep it locked for \(Int(self.requiredSeconds)) s"
                    : "Press Home now and keep the App in the background for \(Int(self.requiredSeconds)) s"
                self.record(kind: "run-started",
                            detail: "scenario=\(self.scenario.rawValue) arm=\(self.openedArm ?? "none") required=\(Int(self.requiredSeconds))s")
            } catch {
                self.fail("boot failed: \(error)")
            }
        }
    }

    /// Aborts an in-flight run and releases the host.
    public func cancel() {
        sampleTask?.cancel()
        sampleTask = nil
        parkTask?.cancel()
        parkTask = nil
        Task { [scheduler, windowToken] in
            if let scheduler, let windowToken {
                await scheduler.endBackgroundTask(windowToken)
            }
        }
        windowToken = nil
        Task { [hostSession] in
            await hostSession?.stop()
        }
        hostSession = nil
        isRunning = false
        phase = .idle
        statusText = "Cancelled"
    }

    /// Releases observations; call when the page disappears for good.
    public func teardown() {
        cancel()
        if let lockUnavailableObserver {
            NotificationCenter.default.removeObserver(lockUnavailableObserver)
            self.lockUnavailableObserver = nil
        }
        if let lockAvailableObserver {
            NotificationCenter.default.removeObserver(lockAvailableObserver)
            self.lockAvailableObserver = nil
        }
    }

    // MARK: - Scene phase

    /// Feeds every SwiftUI scene-phase change to the runner.
    public func scenePhaseChanged(_ scenePhase: ScenePhase) async {
        record(kind: "scene-phase", detail: String(describing: scenePhase))
        switch scenePhase {
        case .background:
            await handleBackground()
        case .active:
            await handleActive()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func handleBackground() async {
        guard isRunning, backgroundedAt == nil else { return }
        backgroundedAt = Date()
        phase = .backgrounded
        statusText = "Backgrounded: draining and sampling"
        record(kind: "app-backgrounded")
        if let session = hostSession {
            parkTask = Task { @MainActor [weak self] in
                do {
                    try await session.park()
                    self?.record(kind: "host-parked")
                    self?.hostStateText = await session.diagnostics()?.hostState?.rawValue
                        ?? "unknown"
                } catch {
                    self?.record(kind: "host-park-failed", detail: "\(error)")
                }
            }
        }
        sampleTask?.cancel()
        sampleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, self.isRunning, self.backgroundedAt != nil else { return }
                self.record(kind: "background-sample",
                            detail: "footprint=\(ProbeProcessMetrics.physicalFootprintBytes() ?? 0)")
            }
        }
    }

    private func handleActive() async {
        guard isRunning else { return }
        guard let backgroundedAt else {
            // Returned to the foreground without ever being backgrounded; the
            // run remains waiting for the operator.
            return
        }
        let observed = Date().timeIntervalSince(backgroundedAt)
        self.observedBackgroundSeconds = observed
        sampleTask?.cancel()
        sampleTask = nil
        parkTask?.cancel()
        parkTask = nil
        phase = .recovering
        statusText = "Recovering after \(String(format: "%.1f", observed)) s in the background"
        let clock = ContinuousClock()
        let started = clock.now
        var resumeError: String?
        if let session = hostSession {
            do {
                let diagnostics = await session.diagnostics()
                if diagnostics?.hostState == .parked {
                    try await session.resume()
                    recovered = true
                } else if diagnostics?.hostState == .running {
                    // The host never parked (a busy drain or a suspended
                    // process that kept running); there is nothing to resume.
                    recovered = true
                } else {
                    try await session.resume()
                    recovered = true
                }
            } catch {
                resumeError = "\(error)"
                lastError = resumeError
                recovered = false
                // A failed host needs the explicit user reset before booting.
                if let session = hostSession {
                    do {
                        try await session.userReset()
                        recovered = true
                        resumeError = nil
                    } catch {
                        lastError = "\(error)"
                    }
                }
            }
        } else {
            recovered = false
            resumeError = "no host session"
        }
        let elapsed = started.duration(to: clock.now)
        recoverySeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        hostStateText = await hostSession?.diagnostics()?.hostState?.rawValue ?? "not booted"
        record(kind: "app-active",
               detail: "recovered=\(recovered.map(String.init) ?? "unknown") recovery=\(String(format: "%.3f", recoverySeconds ?? 0))s")
        await finish(observedSeconds: observed, resumeError: resumeError)
    }

    // MARK: - Finish

    private func finish(observedSeconds: Double, resumeError: String?) async {
        sampleTask?.cancel()
        sampleTask = nil
        if let scheduler, let windowToken {
            await scheduler.endBackgroundTask(windowToken)
        }
        windowToken = nil
        let held = observedSeconds >= requiredSeconds
        let planMatrix = requiredSeconds >= Self.planMatrixSeconds
        let lockOK = scenario == .background || lockObserved
        let status: String
        if held && planMatrix && lockOK && recovered == true {
            status = "MEASURED"
        } else {
            status = "PARTIAL"
        }
        var detailParts: [String] = []
        if !held {
            detailParts.append("background interval \(String(format: "%.1f", observedSeconds)) s is shorter than the required \(Int(requiredSeconds)) s")
        }
        if scenario == .lock && !lockObserved {
            detailParts.append("no protected-data lock notification was observed")
        }
        if let resumeError {
            detailParts.append("recovery failed: \(resumeError)")
        }
        if !planMatrix {
            detailParts.append("the selected window is shorter than the PLAN 600 s matrix")
        }
        if let openedArm, continuedProcessing,
           openedArm != BackgroundTaskKind.continuedProcessing.rawValue {
            detailParts.append("BGContinuedProcessingTask was unavailable; the OS window fallback opened as \(openedArm)")
        }
        let cell = BackgroundCellResult(
            scenario: scenario.rawValue,
            continuedProcessing: continuedProcessing,
            status: status,
            arm: openedArm,
            requiredSeconds: requiredSeconds,
            observedBackgroundSeconds: observedSeconds,
            heldFullWindow: held,
            lockObserved: lockObserved,
            recovered: recovered,
            recoverySeconds: recoverySeconds,
            transitions: transitions,
            detail: detailParts.isEmpty ? "full window observed" : detailParts.joined(separator: "; "))
        store.updateBackgroundCell(cell)
        await hostSession?.stop()
        hostSession = nil
        isRunning = false
        phase = status == "MEASURED" ? .finished : .failed
        statusText = status == "MEASURED"
            ? "Measured: \(scenario.title) × \(Int(requiredSeconds)) s (\(openedArm ?? "none"))"
            : "Incomplete: " + detailParts.joined(separator: "; ")
    }

    private func fail(_ detail: String) {
        lastError = detail
        record(kind: "run-failed", detail: detail)
        store.updateBackgroundCell(BackgroundCellResult(
            scenario: scenario.rawValue,
            continuedProcessing: continuedProcessing,
            status: "FAILED",
            arm: openedArm,
            requiredSeconds: requiredSeconds,
            observedBackgroundSeconds: observedBackgroundSeconds,
            heldFullWindow: false,
            lockObserved: lockObserved,
            recovered: false,
            recoverySeconds: recoverySeconds,
            transitions: transitions,
            detail: detail))
        sampleTask?.cancel()
        sampleTask = nil
        if let scheduler, let windowToken {
            Task { await scheduler.endBackgroundTask(windowToken) }
        }
        windowToken = nil
        Task { [hostSession] in
            await hostSession?.stop()
        }
        hostSession = nil
        isRunning = false
        phase = .failed
        statusText = detail
    }

    // MARK: - Helpers

    private func waitForAnchor() async throws {
        for _ in 0..<100 {
            if anchor.isInWindow { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw ProbeHostError.anchorNotAttached
    }

    private func openWindow() async {
        guard let scheduler else { return }
        let token = await scheduler.beginBackgroundTask(
            name: "phone-dsh-probe-matrix") {
            // The probe records the expiration; it never extends work past it.
        }
        windowToken = token
        openedArm = token?.kind.rawValue ?? BackgroundTaskKind.none.rawValue
        record(kind: "os-window", detail: "kind=\(openedArm ?? "none")")
    }

    private func installLockObservers() {
        let center = NotificationCenter.default
        lockUnavailableObserver = center.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.lockObserved = true
                    self.record(kind: "locked")
                }
            }
        lockAvailableObserver = center.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.record(kind: "unlocked")
                }
            }
    }

    private func record(kind: String, detail: String? = nil) {
        transitions.append(BackgroundTransition(at: ProbeReport.timestamp(),
                                                kind: kind, detail: detail))
        if transitions.count > 500 {
            transitions.removeFirst(transitions.count - 500)
        }
        // Mirror host transitions into the same ordered list.
        if let session = hostSession {
            for entry in session.transitions where !transitions.contains(where: {
                $0.kind == entry.kind && $0.at == entry.at && $0.detail == entry.detail
            }) {
                transitions.append(BackgroundTransition(at: entry.at,
                                                        kind: entry.kind,
                                                        from: entry.from,
                                                        to: entry.to,
                                                        detail: entry.detail))
            }
        }
        if transitions.count > 500 {
            transitions.removeFirst(transitions.count - 500)
        }
    }
}
