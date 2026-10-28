// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — ProbeKit: host session used by the Memory and
// Background pages (PLAN W3-APP).
//
// `PhoneDSHHost` boots a real WKWebView engine, and the engine refuses to boot
// unless its view is attached to a window with at least one visible point
// (PLAN §2.5). This session owns a tiny transparent anchor view the App embeds
// at one point, creates the engine on the UI actor, attaches it before the host
// checks the precondition, and records the host event stream (controller
// transitions, WebContent terminations, restarts, fail-loud errors).

import Foundation
import UIKit
import PhoneDSH
import PhoneDSHEngine

/// Errors of the probe host session.
public enum ProbeHostError: Error, CustomStringConvertible, Sendable {
    case bundleMissing(String)
    case anchorNotAttached
    case notStarted
    case bootFailed(String)

    public var description: String {
        switch self {
        case .bundleMissing(let detail): return "the Worker bundle is missing: \(detail)"
        case .anchorNotAttached:
            return "the one-point probe host view is not attached to a window"
        case .notStarted: return "the probe host has not been started"
        case .bootFailed(let detail): return "the probe host failed to boot: \(detail)"
        }
    }
}

/// Locates the packed Worker assets copied into the app bundle.
public enum WorkerBundleLocator {
    /// The folder name `scripts/copy-bundle-assets.sh` fills.
    public static let directoryName = "worker"

    /// `true` when the static www, `worker-entry.js`, `image.tar.gz` and
    /// `lazy/` are all present in the app bundle.
    public static func bundle() -> PhoneDSHBundleLocation? {
        guard let staticDirectory = Bundle.main.url(forResource: directoryName,
                                                    withExtension: nil) else {
            return nil
        }
        let bundle = PhoneDSHBundleLocation(staticDirectory: staticDirectory)
        return bundle.exists() ? bundle : nil
    }

    /// Human-readable reason shown by the UI when the bundle is absent.
    public static func missingReason() -> String {
        guard let staticDirectory = Bundle.main.url(forResource: directoryName,
                                                    withExtension: nil) else {
            return "Bundle/worker was not copied into the app (run scripts/copy-bundle-assets.sh and rebuild)"
        }
        let bundle = PhoneDSHBundleLocation(staticDirectory: staticDirectory)
        var missing: [String] = []
        if !FileManager.default.fileExists(atPath: bundle.staticDirectory.path) {
            missing.append("worker/")
        }
        if !FileManager.default.fileExists(atPath: bundle.workerEntry.path) {
            missing.append("worker-entry.js")
        }
        if !FileManager.default.fileExists(atPath: bundle.imageArchive.path) {
            missing.append("image.tar.gz")
        }
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: bundle.lazyDirectory.path,
                                           isDirectory: &isDirectory)
            || !isDirectory.boolValue {
            missing.append("lazy/")
        }
        return "missing: " + missing.joined(separator: ", ")
    }
}

/// Owns the tiny visible view and the WKWebView engine created for it.
@MainActor
public final class VisibleEngineAnchor {
    /// One-point transparent view the App must keep in the view hierarchy.
    public let view: UIView
    public private(set) var engine: WebEngine?

    public init(side: CGFloat = 2) {
        view = UIView(frame: CGRect(x: 0, y: 0, width: side, height: side))
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
    }

    /// Whether the anchor is in a window (the engine precondition).
    public var isInWindow: Bool {
        view.window != nil
    }

    /// Creates the WKWebView engine and attaches it to the anchor.
    public func makeEngine(_ configuration: WebEngineConfiguration) -> WebEngine {
        let engine = WebEngine(configuration: configuration)
        engine.attach(to: view)
        self.engine = engine
        return engine
    }

    /// Recomputes the engine's visible-area precondition.
    @discardableResult
    public func refreshAttachment() -> Bool {
        engine?.refreshAttachmentState() ?? false
    }

    /// Releases the engine's web view (host teardown).
    public func shutdown() {
        engine?.shutdown()
        engine = nil
    }
}

/// One recorded host lifecycle transition.
public struct HostTransitionEntry: Codable, Equatable, Sendable {
    public var at: String
    public var kind: String
    public var from: String?
    public var to: String?
    public var detail: String?
}

/// A booted `PhoneDSHHost` plus its metrics.
@MainActor
public final class ProbeHostSession {
    /// Workspace root handed to the host (`Library/xl/<workspace_id>/`).
    public let workspaceRoot: URL
    /// The visible anchor the App must embed.
    public let anchor: VisibleEngineAnchor
    /// The facade, once started.
    public private(set) var host: PhoneDSHHost?
    /// Recorded controller/app transitions in event order.
    public private(set) var transitions: [HostTransitionEntry] = []
    /// Last fail-loud message, when one was published.
    public private(set) var lastError: String?
    /// Number of Worker HELLOs observed.
    public private(set) var workerHelloCount: UInt64 = 0
    /// Most recent diagnostics snapshot.
    public private(set) var lastDiagnostics: PhoneDSHDiagnostics?
    /// Time `start()` took, when it succeeded.
    public private(set) var bootSeconds: Double?
    /// Whether a host currently exists.
    public var isStarted: Bool { host != nil }

    private var eventTask: Task<Void, Never>?
    private let helloTimeout: TimeInterval

    public init(workspaceRoot: URL, helloTimeout: TimeInterval = 240,
                anchor: VisibleEngineAnchor? = nil) {
        self.workspaceRoot = workspaceRoot
        self.anchor = anchor ?? VisibleEngineAnchor()
        self.helloTimeout = helloTimeout
    }

    // MARK: - Lifecycle

    /// Boots the host with the bundled Worker image. Throws when the bundle is
    /// absent or the host fails loud; the caller records the row.
    public func start() async throws {
        guard let bundle = WorkerBundleLocator.bundle() else {
            throw ProbeHostError.bundleMissing(WorkerBundleLocator.missingReason())
        }
        guard anchor.isInWindow else {
            throw ProbeHostError.anchorNotAttached
        }
        try FileManager.default.createDirectory(at: workspaceRoot,
                                                withIntermediateDirectories: true)

        var configuration = PhoneDSHConfiguration(
            workspaceRoot: workspaceRoot,
            // Empty token: the loopback server generates a fresh 128-bit
            // per-start token and the host injects it into the Worker.
            token: "",
            origin: URL(string: "http://127.0.0.1:1")!,
            bundle: bundle,
            allowedModelHosts: [],
            helloTimeout: helloTimeout)
        configuration.engine.bootTimeout = helloTimeout
        // The probe has no model upstream of its own; a Worker boot does not
        // need one. Do not inject fake credentials.
        let anchor = self.anchor
        let sessionHost = PhoneDSHHost(configuration: configuration,
                                       engineFactory: { configuration in
            await anchor.makeEngine(configuration)
        })
        let clock = ContinuousClock()
        let started = clock.now
        do {
            try await sessionHost.start()
        } catch {
            host = nil
            lastError = String(describing: error)
            throw ProbeHostError.bootFailed(String(describing: error))
        }
        let elapsed = started.duration(to: clock.now)
        bootSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        host = sessionHost
        subscribe(to: sessionHost)
        lastDiagnostics = await sessionHost.diagnostics()
        workerHelloCount = lastDiagnostics?.workerHelloCount ?? 0
    }

    /// Drains and parks the host (fast background path).
    public func park() async throws {
        guard let host else { throw ProbeHostError.notStarted }
        try await host.park()
        lastDiagnostics = await host.diagnostics()
    }

    /// Resumes a parked host.
    public func resume() async throws {
        guard let host else { throw ProbeHostError.notStarted }
        let clock = ContinuousClock()
        let started = clock.now
        try await host.resume()
        let elapsed = started.duration(to: clock.now)
        bootSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        lastDiagnostics = await host.diagnostics()
    }

    /// D24 planned restart (overlay rebuild + Worker reboot).
    public func plannedRestart(reason: String) async throws {
        guard let host else { throw ProbeHostError.notStarted }
        try await host.plannedRestart(reason: reason)
        lastDiagnostics = await host.diagnostics()
        workerHelloCount = lastDiagnostics?.workerHelloCount ?? workerHelloCount
    }

    /// Clears a fail-loud host after the user acknowledged it.
    public func userReset() async throws {
        guard let host else { throw ProbeHostError.notStarted }
        try await host.userReset()
        lastDiagnostics = await host.diagnostics()
    }

    /// Stops the host and releases the engine.
    public func stop() async {
        eventTask?.cancel()
        eventTask = nil
        if let host {
            try? await host.stop()
        }
        host = nil
        anchor.shutdown()
        lastDiagnostics = nil
    }

    /// Fresh diagnostics snapshot, or `nil` before the first boot.
    public func diagnostics() async -> PhoneDSHDiagnostics? {
        guard let host else { return nil }
        lastDiagnostics = await host.diagnostics()
        return lastDiagnostics
    }

    // MARK: - Events

    private func subscribe(to host: PhoneDSHHost) {
        eventTask?.cancel()
        eventTask = Task { @MainActor [weak self] in
            for await event in host.eventStream() {
                guard let self else { return }
                self.record(event)
            }
        }
    }

    private func record(_ event: PhoneDSHEvent) {
        switch event {
        case .stateChanged(let from, let to):
            append(kind: "app-state", from: from.rawValue, to: to.rawValue)
        case .hostTransition(let record):
            append(kind: "controller", from: record.from.rawValue,
                   to: record.to.rawValue, detail: record.signal)
        case .webContentTerminated(let count):
            append(kind: "webcontent-terminated", detail: "count=\(count)")
        case .restarted(let report):
            append(kind: "restarted", detail: "reason=\(report.reason.rawValue) boot=\(report.bootID) seconds=\(report.durationSeconds)")
        case .workerHello(let hello):
            workerHelloCount = hello.count
            append(kind: "worker-hello", detail: "count=\(hello.count)")
        case .gatewayResponse(let receipt):
            append(kind: "gateway-response",
                   detail: "disposition=\(receipt.disposition.rawValue) status=\(receipt.status) bytes=\(receipt.bodyBytes)")
        case .channelConnected(let count):
            append(kind: "channel-connected", detail: "count=\(count)")
        case .budget(let decision):
            append(kind: "budget", detail: "action=\(String(describing: decision.action)) hardFail=\(decision.hardFail)")
        case .console:
            break
        case .orphanStepsSettled(let settlement):
            append(kind: "orphan-steps-settled",
                   detail: "reason=\(settlement.reason) count=\(settlement.count)")
        case .error(let message):
            lastError = message
            append(kind: "error", detail: message)
        }
    }

    private func append(kind: String, from: String? = nil, to: String? = nil,
                        detail: String? = nil) {
        transitions.append(HostTransitionEntry(at: ProbeReport.timestamp(),
                                               kind: kind, from: from, to: to,
                                               detail: detail))
        // Bound the in-memory list; the exported report only needs a window.
        if transitions.count > 500 {
            transitions.removeFirst(transitions.count - 500)
        }
    }
}
