// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHEngine: WKWebView host.
//
// PLAN §2.1/§2.5. The engine owns the WKWebView, loads the Worker page from
// the single loopback origin and reports boot/termination/restart events to
// the controller and facade. The controller decides when to restart; the
// engine never restarts on its own.
//
// Visibility requirement: attach the view to a window with at least one point
// of visible area (``WebEngine/attach(to:)``). WebKit throttles timers and
// backgrounds a WKWebView that is detached from a window or fully clipped;
// keeping a 1 pt, alpha 0.01 view in the hierarchy is the documented way to
// keep the Worker running while the UI shows a placeholder. This is
// NOT_VERIFIED on an iPhone: the engine only reports the precondition through
// ``WebEngine/isAttachedWithVisibleArea`` so the controller can close admission.
//
// The geometric check is only half of the precondition: WebKit also throttles a
// page whose hosting window is not occlusion-visible (`NSWindow.occlusionState`)
// even though the view is in the hierarchy. An app that runs its main event
// loop satisfies that; an XCTest process must dispatch AppKit events while it
// waits (``WebEngineAppKitEventPump``). ``WebEngine/isVisibleForWebKit`` and
// ``WebEngine/waitForVisiblePage(timeout:)`` expose the full check, and boot
// warns when the window is occlusion-hidden. See `docs/architecture.md`, page
// visibility.
//
// NOT_VERIFIED: no behaviour in this file has been run on an iPhone.

import Foundation
import WebKit
#if canImport(UIKit)
import UIKit
#endif

/// The engine surface the controller and facade depend on (W0 skeleton;
/// extended, never renamed).
public protocol WebEngineControlling: Sendable {
    /// Whether the current WKWebView has Lockdown Mode enabled.
    var isLockdownModeEnabled: Bool { get }
    /// Whether the view is attached to a window with the required visible area.
    var isAttachedWithVisibleArea: Bool { get }
    /// Loads the page at `url` from the loopback origin.
    func load(_ url: URL) async throws
    /// Boots the worker entry with the given configuration.
    func bootWorker(_ configuration: WebEngineConfiguration) async throws
    /// Plans a WebContent restart (PLAN §2.5: at most every 2 h at a tool-call
    /// boundary), draining the controller before the view is reconstructed.
    func restart() async throws
}

/// Terminal teardown hook for a handoff, run after the page/Worker was
/// destroyed.
///
/// A handoff must terminate the Worker/WebContent, not merely drop the host's
/// reference: the App may still retain the `WKWebView`. This hook only removes
/// the bridge and finishes the engine streams; the caller runs
/// ``WebEngineWorkerTerminating/terminateWorker()`` first and propagates any
/// failure here as a refused handoff. The real ``WebEngine`` conforms by
/// running ``WebEngine/shutdown()``.
public protocol WebEngineShutdownRequesting: Sendable {
    /// Stops loading, removes the bridge and finishes the engine streams.
    func shutdownWorker() async throws
}

/// Planned-restart hook the controller calls at a tool-call boundary.
///
/// The engine exposes the same method as ``WebEngine/restart(reason:)``; the
/// W2 controller's restart scheduler is the only caller. The returned report
/// carries the measured cold-start duration for diagnostics.
public protocol WebEngineRestartRequesting: Sendable {
    func restart(reason: WebEngineRestartReason) async throws -> WebEngineRestartReport
}

/// Two-phase Worker termination used by the drain escalation.
///
/// The combined ``WebEngineRestartRequesting/restart(reason:)`` lever navigates
/// straight to the replacement page. That is too late for a drain that must
/// first stop the old Worker, wait for its already-acknowledged inbound
/// writes, and only then repack the overlay the replacement mounts. This
/// protocol exposes the first phase alone: destroy the live Worker execution
/// context and leave the view on an empty document. The caller boots the
/// replacement afterwards with the same engine.
///
/// A conforming engine must not start a recovery boot of its own when this is
/// called: the escalation owns the sequence and will call
/// ``WebEngineRestartRequesting/restart(reason:)`` or ``bootWorker(_:)``.
public protocol WebEngineWorkerTerminating: Sendable {
    /// Stops the current page/Worker and waits for the navigation away from it.
    func terminateWorker() async throws
}

/// WKWebView host used by the DSH facade.
///
/// The object is isolated to ``WebEngineUIActor`` (the standard UI actor);
/// every other engine value is a plain `Sendable` value and can be read from
/// any task. The web view must be attached with
/// ``attach(to:)`` before the Worker is booted.
@WebEngineUIActor
public final class WebEngine: NSObject {
    /// Name of the WKScriptMessageHandler bridge the page posts to.
    public static let scriptMessageHandlerName = "xlEngine"
    /// Minimum visible attachment area, in points.
    public static let requiredVisibleAreaPoints = WebEngineConfiguration.requiredVisibleAreaPoints

    /// The boot configuration last passed to ``bootWorker(_:)``.
    public private(set) var configuration: WebEngineConfiguration
    /// The hosted web view. Attach it with ``attach(to:)``.
    public let view: WKWebView
    /// One subscription created at engine creation; use ``eventStream()`` for
    /// additional independent subscriptions.
    public nonisolated let events: WebEngineEvents
    /// Latest boot status reported by the page.
    public nonisolated var lastBootStatus: WebEngineBootStatus? {
        readable.bootStatus
    }
    /// Number of WebContent terminations observed in this engine's lifetime.
    public nonisolated var terminationCount: UInt64 {
        readable.terminationCount
    }
    /// Whether the system-wide Lockdown Mode flag is on.
    public nonisolated var isLockdownModeEnabled: Bool {
        readable.isLockdownModeEnabled
    }
    /// Whether the hosting window is visible to the user.
    ///
    /// macOS: the window's `occlusionState` contains `.visible`. iOS: the app
    /// is `.active`. `nil` when the view is not in a window or the platform has
    /// no equivalent signal. Read the value through
    /// ``WebEngine/refreshAttachmentState()`` or the visibility sampling APIs.
    public nonisolated var isWindowOcclusionVisible: Bool? {
        readable.isWindowOcclusionVisible
    }
    /// The full window-level WebKit visibility precondition.
    ///
    /// Attached with a visible area **and** occlusion-visible. This is the
    /// production requirement: an app that runs its main event loop satisfies
    /// it automatically. Use ``WebEngine/waitForVisiblePage(timeout:)`` for the
    /// complete check including the page's `document.visibilityState`.
    public nonisolated var isVisibleForWebKit: Bool {
        guard readable.isAttachedWithVisibleArea else { return false }
        return readable.isWindowOcclusionVisible ?? true
    }
    /// Capability flags the facade consults before starting the local harness.
    public nonisolated var capabilities: WebEngineCapabilities {
        WebEngineCapabilities(
            lockdownModeEnabled: readable.isLockdownModeEnabled,
            contentJavaScriptEnabled: true,
            minimumVisibleAreaPoints: WebEngineConfiguration.requiredVisibleAreaPoints)
    }

    private let eventBus: WebEngineEventBus
    private let readable: WebEngineReadableState
    private let lockdownModeProvider: (@Sendable () -> Bool)?
    private let messageForwarder: ScriptMessageForwarder
    /// File input, download/share and external-link policy for this page.
    public private(set) var fileBridge: WebEngineFileBridge? = nil
#if canImport(UIKit)
    /// Removes WebKit's form-assistant bar from this engine's web view only.
    private var formAccessorySuppressor: WebEngineFormAccessorySuppressor?
#endif

    private var currentBootID: String
    private var bootStatusValue: WebEngineBootStatus?
    private var bootReadyEmitted = false
    private var terminationCountValue: UInt64 = 0
    private var pendingNavigation: PendingNavigation?
    private var bootWaiters: [UUID: BootWaiter] = [:]

    /// Creates the WKWebView with the phone-DSH configuration.
    ///
    /// - Parameters:
    ///   - configuration: Loopback origin, page/asset paths and boot inputs.
    ///   - lockdownModeProvider: Optional test/embedding override for the
    ///     system Lockdown Mode flag. The default reads
    ///     `WKWebpagePreferences.isLockdownModeEnabled`.
    public init(configuration: WebEngineConfiguration,
                lockdownModeProvider: (@Sendable () -> Bool)? = nil) {
        let eventBus = WebEngineEventBus()
        let readable = WebEngineReadableState()

        let webConfiguration = WKWebViewConfiguration()
        // The native page uses the in-memory store. A complete DSH Web surface
        // opts in to the persistent store so its localStorage session
        // selection survives the WKWebView recreation on park/resume.
        webConfiguration.websiteDataStore = configuration.usesPersistentWebsiteDataStore
            ? WKWebsiteDataStore.default() : WKWebsiteDataStore.nonPersistent()
        webConfiguration.preferences.javaScriptEnabled = true
        webConfiguration.defaultWebpagePreferences.allowsContentJavaScript = true
        webConfiguration.limitsNavigationsToAppBoundDomains = false
        #if os(iOS) || os(visionOS)
        // Background keep-alive: the host may start a silent <audio> loop in
        // the page so WebKit holds its own media assertion for the WebContent
        // process while the app is hidden. Playback must be startable from
        // script (no user gesture) and inline.
        webConfiguration.allowsInlineMediaPlayback = true
        webConfiguration.mediaTypesRequiringUserActionForPlayback = []
        // Keep the page scheduled when the view is idle or detached: the host
        // keeps the app itself alive in the background (audio session), and
        // this is the sanctioned way to let the Worker keep running there
        // without any media playback the system would list as Now Playing.
        if #available(iOS 17.0, *) {
            webConfiguration.preferences.inactiveSchedulingPolicy = .none
        }
        #endif

        let webView = WKWebView(frame: .zero, configuration: webConfiguration)
        let forwarder = ScriptMessageForwarder()
        webConfiguration.userContentController.add(forwarder,
                                                   name: WebEngine.scriptMessageHandlerName)
        webConfiguration.userContentController.addUserScript(
            WKUserScript(
                source: WebEngineScripts.observabilityBridge(
                    handlerName: WebEngine.scriptMessageHandlerName),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true))

        self.configuration = configuration
        self.view = webView
        self.eventBus = eventBus
        self.events = eventBus.makeStream()
        self.readable = readable
        self.lockdownModeProvider = lockdownModeProvider
        self.messageForwarder = forwarder
        self.currentBootID = configuration.bootID ?? WebEngineBootID.make()
        self.bootStatusValue = nil
        super.init()

        forwarder.engine = self
        // The bridge owns navigation policy/file input/downloads and forwards
        // the page-load callbacks to this engine (boot/restart stay here).
        let bridge = WebEngineFileBridge(loopbackOrigin: configuration.origin)
        bridge.engine = self
        fileBridge = bridge
        webView.navigationDelegate = bridge
        #if canImport(UIKit)
        webView.uiDelegate = bridge
        #endif
        refreshCapabilities()
        #if canImport(UIKit)
        // Install before the first focus so the form-assistant bar never
        // appears; didFinish and the keyboard notification re-check idempotently.
        formAccessorySuppressor = WebEngineFormAccessorySuppressor(webView: webView)
        #endif
    }

    // MARK: - Visibility

    /// Attaches the web view to `host` with a one-point visible frame.
    ///
    /// The view keeps the configured visible area (one point by default) and
    /// `alpha` 0.01 so the host UI can draw a placeholder over it. A WKWebView
    /// that is detached from a window or fully clipped may have its timers
    /// throttled and its Worker suspended by WebKit; this attachment is the
    /// documented precondition. Whether a one-point view is enough on a real
    /// iPhone is NOT_VERIFIED and must be checked by the Phase 0 probes.
    public func attach(to host: WebEngineHostView) {
        if view.superview !== host {
            view.removeFromSuperview()
            host.addSubview(view)
        }
        let side = max(WebEngineConfiguration.requiredVisibleAreaPoints,
                       configuration.visibleAreaPoints)
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = CGRect(x: 0, y: 0, width: side, height: side)
#if canImport(UIKit)
        view.alpha = 0.01
#else
        view.alphaValue = 0.01
#endif
        view.isHidden = false
        refreshAttachmentState()
#if canImport(UIKit)
        formAccessorySuppressor?.refresh()
#endif
    }

    /// Removes the web view from its superview.
    public func detach() {
        view.removeFromSuperview()
        refreshAttachmentState()
    }

    /// Recomputes ``isAttachedWithVisibleArea`` after window/layout changes.
    ///
    /// Also refreshes ``isWindowOcclusionVisible``: on macOS the window's
    /// occlusion state and on iOS the app's foreground state. The geometric
    /// attachment check stays exactly as before; the occlusion signal is the
    /// second half of ``isVisibleForWebKit``.
    @discardableResult
    public func refreshAttachmentState() -> Bool {
#if canImport(UIKit)
        let inWindow = view.superview != nil && view.window != nil && !view.isHidden
        let foreground: Bool? = view.window == nil
            ? nil : (UIApplication.shared.applicationState == .active)
        readable.setWindowOcclusionVisible(foreground)
#else
        let inWindow = view.superview != nil && view.window != nil
            && !view.isHiddenOrHasHiddenAncestor
        let occlusion = view.window.map { $0.occlusionState.contains(.visible) }
        readable.setWindowOcclusionVisible(occlusion)
#endif
        let largeEnough = view.frame.width >= WebEngineConfiguration.requiredVisibleAreaPoints
            && view.frame.height >= WebEngineConfiguration.requiredVisibleAreaPoints
        let attached = inWindow && largeEnough
        readable.setAttachedWithVisibleArea(attached)
        return attached
    }

    // MARK: - Capabilities

    /// Re-reads the system Lockdown Mode flag and returns the new capabilities.
    @discardableResult
    public func refreshCapabilities() -> WebEngineCapabilities {
        let enabled = lockdownModeProvider?()
            ?? view.configuration.defaultWebpagePreferences.isLockdownModeEnabled
        readable.setLockdownModeEnabled(enabled)
        return capabilities
    }

    // MARK: - Loading and boot

    /// Loads a page URL exactly as supplied.
    ///
    /// Use ``WebEngineConfiguration/makePageURL(bootID:)`` to build a URL that
    /// carries the loopback token and boot inputs. This method waits for the
    /// main-frame navigation, not for the Worker boot message; subscribe to
    /// ``events`` or call ``bootWorker(_:)`` for the boot handshake.
    public nonisolated func load(_ url: URL) async throws {
        try await loadOnUI(url)
    }

    /// Boots the Worker page for `configuration` and waits until the page
    /// reports ready.
    public nonisolated func bootWorker(_ configuration: WebEngineConfiguration) async throws {
        try await bootWorkerOnUI(configuration)
    }

    /// Reloads the page and waits for the next boot-ready, reporting the
    /// measured cold-start duration. See ``WebEngineRestartRequesting``.
    public nonisolated func restart(reason: WebEngineRestartReason) async throws
        -> WebEngineRestartReport {
        try await restartOnUI(reason: reason)
    }

    /// Stops the current Worker/page without booting a replacement.
    ///
    /// The drain escalation calls this first so the old execution context can
    /// no longer write to the WAL or run a tool, then waits for the accepted
    /// inbound writes and repacks the overlay before it boots the fresh Worker.
    /// Navigating to an empty document destroys the page's Worker and closes
    /// its ordered-channel WebSocket; it is not a crash report and must not
    /// trigger the host's automatic termination recovery.
    public nonisolated func terminateWorker() async throws {
        try await terminateWorkerOnUI()
    }

    /// Recovery after ``webViewWebContentProcessDidTerminate(_:)``.
    ///
    /// The controller asks for this only after it has closed admission and
    /// flushed the current step. The engine reloads the page with a fresh
    /// `boot_id` and therefore a fresh overlay URL; the page's bootstrap then
    /// posts its `init` frame to the new Worker exactly as on a cold boot, so
    /// no state from the terminated WebContent process is reused.
    public nonisolated func recoverFromTermination() async throws -> WebEngineRestartReport {
        try await restartOnUI(reason: .webContentTerminated)
    }

    /// Creates one additional independent event subscription.
    public nonisolated func eventStream() -> WebEngineEvents {
        eventBus.makeStream()
    }

    /// ``WebEngineShutdownRequesting`` bridge to the actor-isolated
    /// ``shutdown()``. A handoff awaits this after
    /// ``WebEngineWorkerTerminating/terminateWorker()`` and before sending the
    /// fence CAS. A shutdown failure is propagated so the handoff fails closed.
    public nonisolated func shutdownWorker() async throws {
        await shutdown()
    }

    // MARK: - JIT probe

    /// Runs an informational tight-loop plus JSON benchmark in the page.
    ///
    /// The first call has no stored baseline and reports `ratio == nil`; the
    /// engine stores the measurement as a process-lifetime baseline and later
    /// calls report `baseline / measured` (above 1 is faster). This value never
    /// changes engine behaviour.
    public nonisolated func runJITProbe() async throws -> WebEngineJITProbeResult {
        try await runJITProbeOnUI()
    }

    // MARK: - Teardown

    /// Stops loading, removes the bridge and finishes the event streams.
    public func shutdown() {
        if let pending = pendingNavigation {
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: WebEngineError.navigationSuperseded)
            pendingNavigation = nil
        }
        failBootWaiters(WebEngineError.navigationSuperseded)
        view.stopLoading()
        view.navigationDelegate = nil
        #if canImport(UIKit)
        view.uiDelegate = nil
        formAccessorySuppressor?.invalidate()
        formAccessorySuppressor = nil
        #endif
        fileBridge?.cleanup()
        fileBridge = nil
        messageForwarder.engine = nil
        view.configuration.userContentController
            .removeScriptMessageHandler(forName: WebEngine.scriptMessageHandlerName)
        view.removeFromSuperview()
        readable.setAttachedWithVisibleArea(false)
        readable.setWindowOcclusionVisible(nil)
        eventBus.finish()
    }

    // MARK: - UI-actor implementation

    private func loadOnUI(_ url: URL) async throws {
        let bootID = Self.queryValue(named: "boot_id", in: url).flatMap {
            WebEngineConfiguration.isValidBootID($0) ? $0 : nil
        }
        try await performLoad(url, bootID: bootID)
    }

    private func bootWorkerOnUI(_ configuration: WebEngineConfiguration) async throws {
        self.configuration = configuration
        // The bridge was built in `init` from the pre-boot placeholder origin.
        // The host binds the real listener only now, so navigation policy must
        // adopt the same origin before the page loads; otherwise the real
        // `/static/index.html` is treated as an external link and cancelled.
        fileBridge?.updateLoopbackOrigin(configuration.origin)
        _ = refreshCapabilities()
        warnIfNotVisibleForWebKit()
        let bootID = configuration.bootID ?? WebEngineBootID.make()
        let url = try configuration.makePageURL(bootID: bootID)
        try await performLoad(url, bootID: bootID)
        _ = try await waitForBootReady(timeout: configuration.bootTimeout)
    }

    /// Destroys the live page/Worker and waits for the empty-document
    /// navigation to commit. Navigation is what tears down the page's Worker
    /// and its WebSocket; `stopLoading()` alone would leave the old document
    /// alive.
    private func terminateWorkerOnUI() async throws {
        if let pending = pendingNavigation {
            pendingNavigation = nil
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: WebEngineError.navigationSuperseded)
        }
        failBootWaiters(WebEngineError.navigationSuperseded)
        bootReadyEmitted = false
        let status = WebEngineBootStatus(state: .booting, bootID: currentBootID,
                                         detail: "the Worker was terminated for drain escalation")
        bootStatusValue = status
        readable.setBootStatus(status)
        view.stopLoading()
        guard let blank = URL(string: "about:blank") else {
            throw WebEngineError.invalidConfiguration("about:blank is not a valid URL")
        }
        try await performLoad(blank, bootID: nil)
    }

    private func restartOnUI(reason: WebEngineRestartReason) async throws
        -> WebEngineRestartReport {
        let clock = ContinuousClock()
        let start = clock.now
        _ = refreshCapabilities()
        warnIfNotVisibleForWebKit()
        let bootID = WebEngineBootID.make()
        let url = try configuration.makePageURL(bootID: bootID)
        try await performLoad(url, bootID: bootID)
        _ = try await waitForBootReady(timeout: configuration.bootTimeout)
        let report = WebEngineRestartReport(reason: reason, bootID: bootID,
                                            duration: start.duration(to: clock.now))
        eventBus.send(.restarted(report))
        return report
    }

    /// Warns (never refuses) when the page cannot be visible to WebKit.
    ///
    /// The facade already refuses a boot without a visible attachment area
    /// (`PhoneDSHError.engineNotAttached`); direct engine callers and the
    /// harnesses get this explicit warning for the occlusion half. A production
    /// app that runs its main event loop never sees it; an XCTest harness that
    /// does not pump AppKit events does, which is the actionable signal for the
    /// "Worker hangs" failure mode.
    private func warnIfNotVisibleForWebKit() {
        refreshAttachmentState()
        guard isAttachedWithVisibleArea else {
            emitConsole(level: .warning,
                        text: "the WKWebView is not attached to a window with a visible "
                            + "area; WebKit throttles or suspends a detached page (PLAN §2.5)")
            return
        }
        guard isWindowOcclusionVisible == false else { return }
        emitConsole(level: .warning,
                    text: "the WKWebView window is not occlusion-visible; WebKit throttles "
                        + "a hidden page (timers, fetch-body reads and Worker scheduling "
                        + "stop). An app that runs its main event loop satisfies this; a "
                        + "macOS XCTest harness must pump AppKit events while it waits "
                        + "(WebEngineAppKitEventPump). See docs/architecture.md, page visibility.")
    }

    private func performLoad(_ url: URL, bootID: String?) async throws {
        let timeout = max(1, configuration.bootTimeout)
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            if let pending = pendingNavigation {
                pending.timeoutTask.cancel()
                pending.continuation.resume(throwing: WebEngineError.navigationSuperseded)
                pendingNavigation = nil
            }
            beginBootCycle(bootID: bootID)
            let identifier = UUID()
            let timeoutTask = Task { @WebEngineUIActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, !Task.isCancelled else { return }
                self.finishNavigation(
                    identifier: identifier,
                    result: .failure(WebEngineError.navigationTimedOut(timeout)))
            }
            pendingNavigation = PendingNavigation(identifier: identifier, url: url,
                                                  continuation: continuation,
                                                  timeoutTask: timeoutTask)
            view.load(URLRequest(url: url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: timeout))
        }
    }

    private func beginBootCycle(bootID: String?) {
        if let bootID {
            currentBootID = bootID
        }
        bootReadyEmitted = false
        let status = WebEngineBootStatus(state: .booting, bootID: currentBootID)
        bootStatusValue = status
        readable.setBootStatus(status)
        failBootWaiters(WebEngineError.bootSuperseded)
    }

    private func finishNavigation(identifier: UUID, result: Result<Void, Error>) {
        guard let pending = pendingNavigation, pending.identifier == identifier else { return }
        pendingNavigation = nil
        pending.timeoutTask.cancel()
        switch result {
        case .success:
            pending.continuation.resume()
            eventBus.send(.loaded(pending.url))
            refreshAttachmentState()
        case .failure(let error):
            pending.continuation.resume(throwing: error)
            emitConsole(level: .error, text: "page navigation failed: \(error)")
            failBootWaiters(error)
        }
    }

    private func waitForBootReady(timeout: TimeInterval) async throws -> WebEngineBootStatus {
        if let status = bootStatusValue, status.state == .ready {
            return status
        }
        let identifier = UUID()
        let budget = max(1, timeout)
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { @WebEngineUIActor [weak self] in
                try? await Task.sleep(for: .seconds(budget))
                guard let self, !Task.isCancelled else { return }
                guard let waiter = self.bootWaiters.removeValue(forKey: identifier) else {
                    return
                }
                waiter.continuation.resume(
                    throwing: WebEngineError.bootTimedOut(budget))
            }
            bootWaiters[identifier] = BootWaiter(continuation: continuation,
                                                 timeoutTask: timeoutTask)
        }
    }

    private func resolveBootWaiters(with status: WebEngineBootStatus) {
        let waiters = bootWaiters
        bootWaiters.removeAll()
        for (_, waiter) in waiters {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: status)
        }
    }

    private func failBootWaiters(_ error: Error) {
        let waiters = bootWaiters
        bootWaiters.removeAll()
        for (_, waiter) in waiters {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(throwing: error)
        }
    }

    // MARK: - Message bridge

    fileprivate func didReceiveScriptMessage(_ message: WKScriptMessage) {
        guard message.webView === view, message.frameInfo.isMainFrame else { return }
        let body = message.body
        if let text = body as? String {
            emitConsole(level: .log, text: text)
            return
        }
        guard let record = body as? [String: Any] else { return }
        let kind = (record["kind"] as? String) ?? (record["type"] as? String) ?? ""
        switch kind.lowercased() {
        case "boot":
            handleBootMessage(record)
        case "console":
            let rawLevel = (record["level"] as? String) ?? "log"
            let level = WebEngineConsoleLine.Level(rawValue: rawLevel.lowercased()) ?? .log
            let text = (record["text"] as? String) ?? ""
            emitConsole(level: level, text: text)
        default:
            if record["state"] is String {
                handleBootMessage(record)
            }
        }
    }

    private func handleBootMessage(_ record: [String: Any]) {
        let reportedBootID = (record["boot_id"] as? String) ?? (record["bootID"] as? String)
        if let reportedBootID, reportedBootID.isEmpty == false,
           reportedBootID != currentBootID {
            // A previous page's late message after a reload: ignore it.
            return
        }
        let state = ((record["state"] as? String) ?? "").lowercased()
        let detail = (record["detail"] as? String) ?? (record["message"] as? String)
        switch state {
        case "ready", "bootready", "worker_ready":
            let status = WebEngineBootStatus(state: .ready,
                                             bootID: reportedBootID ?? currentBootID,
                                             detail: detail)
            bootStatusValue = status
            readable.setBootStatus(status)
            if bootReadyEmitted == false {
                bootReadyEmitted = true
                eventBus.send(.bootReady(status))
            }
            resolveBootWaiters(with: status)
        case "failed", "error":
            let status = WebEngineBootStatus(state: .failed,
                                             bootID: reportedBootID ?? currentBootID,
                                             detail: detail)
            bootStatusValue = status
            readable.setBootStatus(status)
            emitConsole(level: .error,
                        text: "worker boot failed: \(detail ?? "unknown error")")
            failBootWaiters(WebEngineError.bootFailed(detail ?? "unknown error"))
        case "booting", "starting", "loading":
            let status = WebEngineBootStatus(state: .booting,
                                             bootID: reportedBootID ?? currentBootID,
                                             detail: detail)
            bootStatusValue = status
            readable.setBootStatus(status)
        default:
            emitConsole(level: .log, text: "unrecognised boot message: \(record)")
        }
    }

    private func emitConsole(level: WebEngineConsoleLine.Level, text: String) {
        eventBus.send(.consoleLine(WebEngineConsoleLine(level: level, text: text)))
    }

    // MARK: - JIT probe

    private func runJITProbeOnUI() async throws -> WebEngineJITProbeResult {
        let result: Any?
        do {
            result = try await view.evaluateJavaScript(WebEngineScripts.jitBenchmark,
                                                       in: nil,
                                                       contentWorld: .page)
        } catch {
            throw WebEngineError.scriptEvaluationFailed(error.localizedDescription)
        }
        guard let record = result as? [String: Any],
              let milliseconds = Self.doubleValue(record["milliseconds"]),
              milliseconds > 0 else {
            throw WebEngineError.scriptEvaluationFailed("the benchmark returned no duration")
        }
        let iterations = Self.intValue(record["iterations"]) ?? 0
        let storedBaseline = configuration.jitBaselineMilliseconds
            ?? readable.jitBaselineMilliseconds
        if storedBaseline == nil {
            readable.setJITBaselineMilliseconds(milliseconds)
        }
        let ratio: Double?
        if let storedBaseline, storedBaseline > 0, milliseconds > 0 {
            ratio = storedBaseline / milliseconds
        } else {
            ratio = nil
        }
        return WebEngineJITProbeResult(measuredMilliseconds: milliseconds,
                                       baselineMilliseconds: storedBaseline,
                                       ratio: ratio,
                                       iterations: iterations)
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let integer = value as? Int { return Double(integer) }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let integer = value as? Int { return integer }
        return nil
    }

    private static func queryValue(named name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }
}

// MARK: - Delegates

extension WebEngine: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
#if canImport(UIKit)
        if webView === view {
            formAccessorySuppressor?.refresh()
        }
#endif
        guard webView === view, let pending = pendingNavigation else { return }
        finishNavigation(identifier: pending.identifier, result: .success(()))
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                        withError error: Error) {
        guard webView === view, let pending = pendingNavigation else { return }
        finishNavigation(identifier: pending.identifier,
                         result: .failure(WebEngineError.navigationFailed(
                            error.localizedDescription)))
    }

    public func webView(_ webView: WKWebView,
                        didFailProvisionalNavigation navigation: WKNavigation!,
                        withError error: Error) {
        guard webView === view, let pending = pendingNavigation else { return }
        finishNavigation(identifier: pending.identifier,
                         result: .failure(WebEngineError.navigationFailed(
                            error.localizedDescription)))
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === view else { return }
        if let pending = pendingNavigation {
            pendingNavigation = nil
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: WebEngineError.contentProcessTerminated)
        }
        terminationCountValue += 1
        readable.setTerminationCount(terminationCountValue)
        bootReadyEmitted = false
        let status = WebEngineBootStatus(state: .booting, bootID: currentBootID,
                                         detail: "the WebContent process terminated")
        bootStatusValue = status
        readable.setBootStatus(status)
        failBootWaiters(WebEngineError.contentProcessTerminated)
        eventBus.send(.terminated(terminationCountValue))
    }
}

// MARK: - Protocol conformance

extension WebEngine: WebEngineControlling {
    public nonisolated var isAttachedWithVisibleArea: Bool {
        readable.isAttachedWithVisibleArea
    }

    public nonisolated func restart() async throws {
        _ = try await restart(reason: .planned)
    }
}

extension WebEngine: WebEngineRestartRequesting {}
extension WebEngine: WebEngineWorkerTerminating {}

extension WebEngine: WebEngineShutdownRequesting {}

// MARK: - Supporting types

/// Weak bridge from the user content controller back to the engine; the
/// controller retains this object, so it must not retain the engine.
@WebEngineUIActor
private final class ScriptMessageForwarder: NSObject, WKScriptMessageHandler {
    weak var engine: WebEngine?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        engine?.didReceiveScriptMessage(message)
    }
}

private struct PendingNavigation {
    let identifier: UUID
    let url: URL
    let continuation: CheckedContinuation<Void, Error>
    let timeoutTask: Task<Void, Never>
}

private struct BootWaiter {
    let continuation: CheckedContinuation<WebEngineBootStatus, Error>
    let timeoutTask: Task<Void, Never>
}
