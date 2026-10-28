// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS probe app: full DSH Web surface host.
//
// The Web surface is not a remote DSH client and not a second chat stack. It
// is the same local `PhoneDSHHost` the native Chat page uses: one workspace
// root, one WAL, one model gateway, one credential provider and the linked
// `PDSHShellProvider`. The only difference is the page path
// (`/static/web/index.html` instead of the native `/static/index.html`) and
// that this model never opens a harness session: the Web client owns its
// session through the Worker's own session controller.
//
// Background/foreground is the same D14 park/resume as the native page. No
// silent-audio keep-alive is started here: the Web page is either visible or
// the host is parked.
//
// The complete DSH Web client stores its current session in localStorage
// (`dsh.sessions.current`). A park tears the WKWebView down and a resume asks
// the host to create a new engine, so the Web surface must keep the same
// origin and the same browser storage across that recreation. The model pins
// one loopback port for its lifetime and enables a persistent
// `WKWebsiteDataStore` on the Web engine only; the native recovery page keeps
// the engine's default non-persistent store. Without both, a resume lands on
// a new origin with empty storage and DSH creates a new session.

import Darwin
import Foundation
import Observation
import ProbeKit
import SwiftUI
import UIKit
import WebKit
import PhoneDSHAgentCore
import PhoneDSH
import PhoneDSHEngine
import PhoneDSHShell

/// The app-level surface switch. Only one of the two hosts may exist at once.
enum WebSurfaceMode: String {
    case web
    case nativeRecovery
}

@MainActor
@Observable
final class WebHostModel {
    static let shared = WebHostModel()
    /// The path the integration contract assigns to the complete DSH Web UI.
    static let webPagePath = WebHostConfiguration.pagePath

    /// Visible one-point anchor the engine is created against; the full-screen
    /// `WebSurfacePage` re-parents the same WKWebView after the host boots.
    let anchor = VisibleEngineAnchor()

    /// The live WKWebView engine, exposed so the SwiftUI surface can attach it.
    private(set) var engine: WebEngine?
    /// The native surface owns the app while the Web page is not being
    /// tested. Flip this to `.web` (or drop the override below) to bring the
    /// full DSH page back as the default surface.
    private(set) var mode: WebSurfaceMode = .nativeRecovery
    private(set) var hostState: PhoneDSHState = .stopped
    private(set) var statusLine = "正在准备本地 DSH…"
    private(set) var lastError: String?
    private(set) var parked = false
    /// Set by the page's model-service tab (through the native message bridge)
    /// or the surface menu. The sheet edits the same PhoneModelProviderSettings
    /// document and Keychain the native recovery page uses.
    var modelSettingsPresented = false
    /// Set by the surface menu. The page edits the same independent search
    /// document and dedicated Keychain service the Worker search router reads.
    var searchSettingsPresented = false
    /// Set by the Web MCP tab or the surface menu. The sheet edits the same
    /// Worker `mcp.json` registry and the dedicated MCP Keychain service.
    var mcpSettingsPresented = false
    /// Non-secret explanation of the last search launch decision (for example
    /// a corrupt search document or an unsupported follow-model service).
    private(set) var searchLaunchWarning: String?
    /// Non-secret explanation of the last MCP access decision.
    private(set) var mcpAccessWarning: String?
    /// Non-secret row fields the Web tab asked the native editor to finish.
    var mcpSettingsDraft: MCPControlDraft?

    /// The facade state under the name App surfaces commonly read.
    var state: PhoneDSHState { hostState }
    /// Whether a local host exists (running, parked or failed in memory).
    var isStarted: Bool { host != nil }

    private var host: PhoneDSHHost?
    private let mcpAccessSettings = PhoneMCPAccessSettings.shared
    /// The one exact-origin/path policy the running gateway and native editor
    /// share. Replaced on host start and updated in place on grants/revokes.
    private(set) var mcpAccessPolicy = MCPEgressPolicy()
    /// The one production controller behind the Web MCP bridge and the native
    /// sheet. It owns the same policy object the running gateway uses.
    @ObservationIgnored private var mcpControlStorage: MCPControlController?
    private var mcpControl: MCPControlController {
        if let mcpControlStorage { return mcpControlStorage }
        let controller = MCPControlController(
            settings: mcpAccessSettings,
            policy: mcpAccessPolicy,
            materializedHome: materializedHome,
            presentSettings: { [weak self] draft in
                self?.mcpSettingsDraft = draft
                self?.mcpSettingsPresented = true
            })
        mcpControlStorage = controller
        return controller
    }
    private var hostEventTask: Task<Void, Never>?
    private var settingsBridge: WebHostModelSettingsBridge?
    private var mcpSettingsBridge: MCPControlBridge?
    private var nativePreview: WebEngineNativePreview?
    private var directoryImport: WebEngineDirectoryImport?
    private var directoryImportHandler: WebEngineDirectoryImportScriptHandler?
    private var starting = false
    private var stopping = false
    /// True while `settleScenePhaseAfterStart` applies the scene request that
    /// arrived during a start/reset. Its park/resume chain runs with
    /// `starting` still set, so it must be allowed through the start guard.
    private var settlingStart = false
    private var switchingSurface = false
    /// One park/resume at a time. `stop()` waits on this token until the
    /// in-flight transition has really ended; the gate has no fixed deadline
    /// shorter than the host's own hello timeout.
    private let lifecycle = WebSurfaceLifecycleGate()
    private var foregroundResumeRequested = false
    private var backgroundParkRequested = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// The loopback port is allocated once and reused by every park/resume, so
    /// the Web page keeps one origin and its DSH session selection survives the
    /// engine recreation. A value of 0 falls back to an ephemeral port when the
    /// probe cannot bind one.
    private let loopbackPort: UInt16
    private static let loopbackPortDefaultsKey = WebHostConfiguration.loopbackPortDefaultsKey

    /// Same workspace the native Chat page uses: one VFS, one recovery path.
    let workspaceRoot: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory,
                                                 in: .userDomainMask)[0]
        return documents.appendingPathComponent("chat-host", isDirectory: true)
    }()

    /// The Worker `/dsh/workspace` and `/dsh/home` mounts, materialized on disk.
    /// The read-only accelerator provider and the Quick Look resolver must use
    /// these exact directories, not the WAL root above them.
    private var materializedWorkspace: URL {
        workspaceRoot.appendingPathComponent("materialized", isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
    }

    private var materializedHome: URL {
        workspaceRoot.appendingPathComponent("materialized", isDirectory: true)
            .appendingPathComponent("home", isDirectory: true)
    }

    private init() {
        loopbackPort = Self.resolveLoopbackPort()
        if ProcessInfo.processInfo.environment["PDSH_DEBUG_FORCE_NATIVE"] == "1" {
            mode = .nativeRecovery
        }
    }

    // MARK: - Lifecycle

    /// Boots the local Worker and loads the complete Web page. Idempotent while
    /// the host is starting or running; a parked host is resumed instead.
    func start() async {
        guard mode == .web, !stopping, !switchingSurface else { return }
        await startHost()
    }

    private func startHost() async {
        // All five entries — start, the failed reset below, park, resume and
        // stop — share one lifecycle token. Start waits for an in-flight
        // park/resume and claims the token before it touches `host`, `anchor`
        // or `engine`. The failed reset used to run with only the `starting`
        // flag: a retry that arrived while a background drain or a foreground
        // resume was still running could shut the anchor down underneath the
        // transition driving the same host. Waiting on the token (not a flag
        // check) makes the reset the next transition instead of an overlap.
        guard !starting, !stopping else { return }
        starting = true
        defer { starting = false }
        guard await lifecycle.acquire(stopping: stopping) else { return }
        var tokenHeld = true
        defer { if tokenHeld { lifecycle.end() } }
        // `stop()` may have set `stopping` while this start was waiting for a
        // park/resume to release the token. Leave the host untouched; stop now
        // owns the next move.
        guard !stopping else { return }

        if let host {
            var failed = hostState == .failed
            if !failed { failed = await host.state == .failed }
            if failed {
                // The "retry" action must actually recover a failed host; a
                // plain start() is idempotent and would be a no-op here.
                hostState = .failed
                statusLine = "正在重置失败的本地 Web 主机…"
                removePageHandlers()
                anchor.shutdown()
                engine = nil
                parked = false
                do {
                    try await host.userReset()
                    hostState = .running
                    lastError = nil
                    statusLine = "本地 DSH Web 已恢复"
                    // Hand the token to the shared settle helper: it parks the
                    // just-recovered host in the background or releases the
                    // token for the next transition.
                    tokenHeld = false
                    await settleScenePhaseAfterStart(host)
                } catch {
                    if await host.state == .failed { hostState = .failed }
                    reportError("Web 主机重置失败：\(error)")
                }
                return
            }
            if parked {
                // Start already owns the token; resume under it instead of
                // dropping the request because the gate is held.
                tokenHeld = false
                await resumeHost(host, holdingToken: true)
            }
            return
        }
        lastError = nil

        await waitForAnchor()
        guard anchor.isInWindow else {
            reportError("Web 容器还没有进入窗口，请稍后重试。")
            return
        }
        let egressHosts = Set(
            ChatSettings.egressAllow
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty })
        // One model authority for Web and native recovery: the provider document
        // in UserDefaults plus each profile's Keychain item. A missing key is an
        // honest "not configured" state, not a startup failure: the complete Web
        // page still boots so the user can open the native configuration sheet
        // from its model-service tab. Model requests then fail closed in the
        // gateway with the credential provider's unauthorized error.
        let settings = PhoneModelProviderSettings.shared
        var selectedProfile: ProviderProfile?
        var launchPlan = ModelProviderLaunchPlan()
        do {
            let snapshot = try settings.load()
            if let profile = snapshot.selected {
                var plan = ModelProviderLaunchPlan()
                try settings.apply(to: &plan, egressAllowHosts: egressHosts)
                selectedProfile = profile
                launchPlan = plan
            } else {
                launchPlan.credentialProvider = settings
                    .makeEgressOnlyCredentialProvider(egressAllowHosts: egressHosts)
            }
        } catch {
            // A malformed document must not brick the page. Boot the host with
            // an egress-only provider; the native page is the repair surface.
            launchPlan = ModelProviderLaunchPlan(
                credentialProvider: settings
                    .makeEgressOnlyCredentialProvider(egressAllowHosts: egressHosts))
        }
        // One search authority for Web and native recovery. Independent mode
        // adds its exact route to the gateway allow-list and wraps only that
        // credential provider; follow-model stays the explicit model fallback
        // and is limited to the official Messages endpoint.
        let searchPlan = WebSearchHostConfiguration.apply(to: &launchPlan,
                                                          modelProfile: selectedProfile)
        searchLaunchWarning = searchPlan.warning
        // One MCP authority for Web and native recovery. Drop grants whose
        // materialized Worker row is gone (for example a removal made through
        // a direct Remote call rather than the UI), then build the live policy.
        mcpAccessSettings.reconcile(materializedHome: materializedHome)
        mcpControl.refreshPolicy()
        let mcpPolicy = MCPHostConfiguration.apply(to: &launchPlan,
                                                   settings: mcpAccessSettings,
                                                   policy: mcpControl.policy)
        mcpAccessPolicy = mcpPolicy
        mcpAccessWarning = nil

        guard let bundle = WorkerBundleLocator.bundle() else {
            reportError("Worker 资源缺失，暂时无法加载完整 DSH 页面。")
            return
        }
        let webPage = bundle.staticDirectory
            .appendingPathComponent("web", isDirectory: true)
            .appendingPathComponent("index.html", isDirectory: false)
        guard FileManager.default.fileExists(atPath: webPage.path) else {
            reportError("完整 DSH Web 页面尚未打包；请重新生成 App 资源。")
            return
        }
        do {
            try FileManager.default.createDirectory(at: workspaceRoot,
                                                    withIntermediateDirectories: true)
        } catch {
            reportError("无法创建工作区：\(error.localizedDescription)")
            return
        }

        // The launch plan is the model authority: a missing key still boots
        // the complete page (gateway closed until the native sheet configures
        // a provider), and a selected profile supplies the exact allow-list,
        // credential provider and non-secret Worker environment.
        var environment: [String: String] = [
            // The host gateway injects the real key; the Worker never holds it.
            "DEEPSEEK_API_KEY": "phone-host-injects-key",
            "DSH_TELEMETRY_DISABLED": "1",
        ]
        // The launch plan carries both the model projection and the resolved
        // search provider/endpoint/placeholder; merge it even when no model
        // service is selected so independent search can still be configured.
        environment.merge(launchPlan.environment) { _, new in new }
        if let profile = selectedProfile {
            environment["DEEPSEEK_BASE_URL"] = profile.baseURL
            environment["PDSH_MODEL_NAME"] = profile.model
        } else {
            // The agent-default-model row still needs a non-empty id. No
            // credential is configured, so the first request fails explicitly
            // instead of falling back to an old key or a stale endpoint.
            environment["PDSH_MODEL_NAME"] = "deepseek-flash"
        }
        // One production assembly shared with the full-Web simulator suite:
        // complete page path, pinned loopback origin, persistent WebEngine
        // store and the WAL-materialized read-only PDSHShellProvider. The
        // App injects its model launch plan and environment here instead of
        // keeping a second inline host assembly.
        let configuration = WebHostConfiguration.make(
            workspaceRoot: workspaceRoot,
            bundle: bundle,
            modelName: selectedProfile?.model ?? "",
            credentialProvider: launchPlan.credentialProvider,
            egressHosts: egressHosts,
            loopbackPort: loopbackPort,
            allowedModelHosts: launchPlan.allowedModelHosts,
            egressAuthorizer: mcpPolicy,
            environment: environment).configuration

        let newHost = PhoneDSHHost(
            configuration: configuration,
            engineFactory: WebHostConfiguration.engineFactory(anchor: anchor) { [weak self] engine in
                guard let self else { return }
                self.removePageHandlers()
                Self.installViewportCover(on: engine)
                self.engine = engine
                self.installSettingsBridge(on: engine)
                self.installPageHandlers(on: engine)
            })
        observe(newHost)
        statusLine = "正在启动本地 Worker 与完整 Web 页面…"
        do {
            try await newHost.start()
            host = newHost
            hostState = .running
            statusLine = "本地 DSH Web 已连接"
            // A scene change can arrive while `newHost.start()` is suspended.
            // Apply the latest request now that a host exists, so a boot that
            // finished in the background is parked immediately instead of
            // staying running until the next scene callback. The settle helper
            // takes ownership of the token this start still holds.
            tokenHeld = false
            await settleScenePhaseAfterStart(newHost)
        } catch {
            hostEventTask?.cancel()
            hostEventTask = nil
            try? await newHost.stop()
            host = nil
            removePageHandlers()
            anchor.shutdown()
            engine = nil
            parked = false
            foregroundResumeRequested = false
            backgroundParkRequested = false
            endBackgroundTask()
            hostState = .failed
            reportError("Web 主机启动失败：\(error)")
        }
    }

    /// Applies the scene request that may have arrived during `start()`.
    ///
    /// The start path used to ignore `.background` because `host` was still
    /// nil, then leave the freshly booted host running forever. The request is
    /// recorded in `scenePhaseChanged` even before the host exists; this is
    /// where the just-booted host catches up. The caller hands the lifecycle
    /// token to this helper, which always releases it exactly once: by parking
    /// under the same token, or directly when no park is needed.
    private func settleScenePhaseAfterStart(_ host: PhoneDSHHost) async {
        settlingStart = true
        defer { settlingStart = false }
        let inBackground = backgroundParkRequested
            || UIApplication.shared.applicationState == .background
        backgroundParkRequested = false
        foregroundResumeRequested = false
        if inBackground {
            await parkHost(host, holdingToken: true)
        } else {
            endBackgroundTask()
            lifecycle.end()
        }
    }

    /// Stops the whole host. Called before the explicit native recovery page
    /// takes over, so the app can never run two hosts or two sessions.
    func stop() async {
        guard !stopping else { return }
        stopping = true
        defer { stopping = false }
        // Take the same token every other transition uses. This waits for an
        // in-flight boot, failed reset, park drain or resume (up to
        // `helloTimeout`) to really end instead of polling `starting` and then
        // calling `host.stop()` beside a transition that is still running.
        // Holding the token also keeps a scene callback from starting a new
        // park/resume while this teardown is inside `host.stop()`.
        await lifecycle.acquireExclusive()
        defer { lifecycle.end() }
        if let host {
            do {
                try await host.stop()
            } catch {
                reportError("停止 Web 主机时报告错误：\(error)")
            }
        }
        hostEventTask?.cancel()
        hostEventTask = nil
        host = nil
        removePageHandlers()
        anchor.shutdown()
        engine = nil
        parked = false
        foregroundResumeRequested = false
        backgroundParkRequested = false
        hostState = .stopped
        statusLine = "本地 DSH Web 已停止"
        endBackgroundTask()
    }

    /// Switches to the native Chat page as an explicit recovery path. The Web
    /// host is fully stopped first; the native model starts only when the user
    /// presses its own start button.
    func enterNativeRecovery() async {
        guard mode == .web, !stopping, !switchingSurface else { return }
        switchingSurface = true
        defer { switchingSurface = false }
        await stop()
        guard host == nil, engine == nil else { return }
        mode = .nativeRecovery
        statusLine = "原生恢复界面"
    }

    /// Returns from the native recovery page to the Web surface. The native
    /// host is stopped first; if it is busy the switch is refused instead of
    /// running both hosts.
    ///
    /// NOT ENABLED: the product decision is native-only, so no screen calls
    /// this and the shell shows no entry to the Web surface. The method and the
    /// `WKWebView` path stay in place deliberately — they are the fallback if
    /// the native surface ever has to be dropped, and deleting them would take
    /// the loopback/bridge work with them. Keep `WebSurfaceMode` at
    /// `.nativeRecovery`; wiring an entry here needs a product decision first.
    func enterWebSurface() async {
        guard mode == .nativeRecovery, !switchingSurface else { return }
        switchingSurface = true
        defer { switchingSurface = false }
        // A native start/stop in flight has not assigned its host yet, so
        // `isStarted` would be false while the native side is still booting.
        // Refuse the switch instead of racing two hosts into existence.
        guard !ChatModel.shared.busy else {
            lastError = "原生页面正在启动或停止，请完成后再返回 Web。"
            return
        }
        if ChatModel.shared.isStarted {
            await ChatModel.shared.stop()
            guard !ChatModel.shared.isStarted else {
                lastError = "原生会话仍在运行，请先结束当前操作再返回 Web。"
                return
            }
        }
        // `ChatModel.stop()` stops the host but leaves the engine attached to
        // its anchor. Release that WKWebView explicitly before the Web host
        // creates its own: otherwise the old Worker page stays alive beside
        // the new engine and repeated switches accumulate both views and
        // Workers.
        ChatModel.shared.anchor.shutdown()
        mode = .web
        // The host boot has its own `starting` guard; let scene changes reach
        // it while it boots, so backgrounding still parks the one host.
        switchingSurface = false
        await startHost()
    }

    // MARK: - Scene phase (D14 park / resume)

    /// Drives the Web host in the foreground/background. In native recovery
    /// mode the same scene change belongs to `ChatModel`, never to both.
    ///
    /// A scene change is recorded even when `start()` has not assigned its
    /// host yet. `startHost()` calls ``settleScenePhaseAfterStart(_:)`` once
    /// the host exists, so a boot that finishes while the app is in the
    /// background is parked instead of silently staying running.
    func scenePhaseChanged(_ phase: ScenePhase) async {
        if switchingSurface { return }
        if mode == .nativeRecovery {
            await ChatModel.shared.scenePhaseChanged(phase)
            return
        }
        switch phase {
        case .background:
            foregroundResumeRequested = false
            backgroundParkRequested = true
        case .active:
            backgroundParkRequested = false
            foregroundResumeRequested = true
        case .inactive:
            return
        @unknown default:
            return
        }
        guard !stopping else { return }
        // A failed-host reset keeps the existing host assigned while it
        // awaits `userReset()`. Do not park or resume that host from a scene
        // callback; `settleScenePhaseAfterStart` applies the recorded phase
        // after the serialized reset/boot finishes. A background scene during
        // the reset still needs the extra execution time.
        if starting {
            if phase == .background {
                beginBackgroundTask()
            } else if phase == .active {
                endBackgroundTask()
            }
            return
        }
        guard let host else {
            // A boot without an assigned host was handled by the `starting`
            // branch above; there is nothing to park or resume here.
            if phase == .active { endBackgroundTask() }
            return
        }
        switch phase {
        case .background:
            if lifecycle.isTransitioning { return }
            // A Failed controller has no Parked edge. Parking it would move
            // only the facade to `.stopped` while the machine stays `Failed`;
            // the next resume() then throws and the retry path is lost. Keep
            // the failure (and its explicit userReset() retry) intact.
            if hostState == .failed {
                parked = false
                backgroundParkRequested = false
                foregroundResumeRequested = false
                endBackgroundTask()
                return
            }
            guard !parked else {
                backgroundParkRequested = false
                return
            }
            beginBackgroundTask()
            await parkHost(host)
        case .active:
            if lifecycle.isTransitioning { return }
            if hostState == .failed {
                parked = false
                foregroundResumeRequested = false
                backgroundParkRequested = false
                endBackgroundTask()
                return
            }
            guard parked else {
                foregroundResumeRequested = false
                endBackgroundTask()
                return
            }
            await resumeHost(host)
        default:
            break
        }
    }

    private func parkHost(_ host: PhoneDSHHost, holdingToken: Bool = false) async {
        // A scene callback never calls this while `startHost` is booting; only
        // the start's settle chain runs with `starting` still set. That chain
        // reaches the shared token instead of a flag check; the token is what
        // guarantees no overlap, and an in-flight start/reset holds it, so this
        // park waits and then re-checks `stopping` before touching the host.
        guard holdingToken || settlingStart || !starting else { return }
        var tokenHeld = holdingToken
        defer { if tokenHeld { lifecycle.end() } }
        if tokenHeld {
            // The start helper handed us the token; a teardown may have been
            // requested while the boot/reset was finishing.
            guard !stopping else { return }
        } else {
            guard await lifecycle.acquire(stopping: stopping) else { return }
            tokenHeld = true
            // `stop()` may have claimed the next move while this park was
            // waiting for the token.
            guard !stopping else { return }
        }

        // `hostState` normally carries the failure, but the event stream can
        // lag slightly behind the actor. Read the host while the token is
        // held, so a failed reset cannot change it underneath this decision.
        var failed = hostState == .failed
        if !failed { failed = await host.state == .failed }
        guard WebSurfaceLifecyclePolicy.allowsPark(hostFailed: failed) else {
            // Do not turn a retryable Failed host into a "parked" one: end the
            // background assertion, clear the stale flag and leave the failure
            // for `startHost()` -> `userReset()`.
            parked = false
            backgroundParkRequested = false
            foregroundResumeRequested = false
            endBackgroundTask()
            return
        }
        statusLine = "App 进入后台：正在暂停本地 DSH（先给在途工作排水）…"
        do {
            try await host.park()
            // A park on a controller that failed during the drain must not be
            // recorded as resumable.
            if await host.state == .failed {
                parked = false
                hostState = .failed
                reportError("暂停时本地 DSH 进入失败状态；请重试或切换原生恢复")
            } else {
                parked = true
                removePageHandlers()
                anchor.shutdown()
                engine = nil
                if hostState != .failed { hostState = .stopped }
                statusLine = "本地 DSH 已暂停；回到 App 后沿同一 WAL 恢复"
            }
        } catch {
            parked = false
            if await host.state == .failed { hostState = .failed }
            reportError("暂停失败：\(error)")
        }
        endBackgroundTask()
        let shouldResume = foregroundResumeRequested
        foregroundResumeRequested = false
        let shouldParkAgain = backgroundParkRequested
        backgroundParkRequested = false
        tokenHeld = false
        lifecycle.end()
        guard !stopping else { return }
        if shouldResume && parked {
            await resumeHost(host)
        } else if shouldParkAgain && !parked {
            await parkHost(host)
        }
    }

    private func resumeHost(_ host: PhoneDSHHost, holdingToken: Bool = false) async {
        // Same rule as park: the shared token serializes a resume with start,
        // reset and teardown. A scene-driven resume observes `starting`; only
        // the start's own settle chain/handoff may run while it is still set.
        guard holdingToken || settlingStart || !starting else { return }
        var tokenHeld = holdingToken
        defer { if tokenHeld { lifecycle.end() } }
        if tokenHeld {
            guard !stopping else { return }
        } else {
            guard await lifecycle.acquire(stopping: stopping) else { return }
            tokenHeld = true
            guard !stopping else { return }
        }

        var failed = hostState == .failed
        if !failed { failed = await host.state == .failed }
        guard WebSurfaceLifecyclePolicy.allowsResume(parked: parked, hostFailed: failed) else {
            if failed { parked = false }
            return
        }
        statusLine = "正在恢复同一本地 DSH 主机…"
        do {
            try await host.resume()
            // The host really left Parked. A teardown requested while resume
            // was in flight owns the next move: it waits on this token and
            // then calls host.stop(), so do not leave a stale parked flag.
            parked = false
            lastError = nil
            statusLine = stopping
                ? "本地 DSH Web 正在停止…"
                : "本地 DSH Web 已恢复"
        } catch {
            // Never keep a failed resume marked parked: the retry path must
            // call host.userReset(), not another resume() that would throw.
            parked = false
            if await host.state == .failed { hostState = .failed }
            reportError("恢复失败：\(error)")
        }
        endBackgroundTask()
        let shouldPark = backgroundParkRequested
        foregroundResumeRequested = false
        backgroundParkRequested = false
        tokenHeld = false
        lifecycle.end()
        guard !stopping else { return }
        if shouldPark && !parked { await parkHost(host) }
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "phone-dsh.web.park") { [weak self] in
                _ = Task { @MainActor in self?.endBackgroundTask() }
            }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Host events

    private func observe(_ host: PhoneDSHHost) {
        hostEventTask?.cancel()
        let stream = host.eventStream()
        hostEventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .stateChanged(_, let to):
                    self.hostState = to
                case .error(let message):
                    self.reportError("引擎停了")
                case .webContentTerminated(let count):
                    self.mcpControlStorage?.abandonOpenTransactions()
                    self.statusLine = "WebContent 已重启（\(count)）；同一 Worker 会话继续"
                case .restarted:
                    self.statusLine = "Worker 已重启；Web 页面沿同一会话恢复"
                default:
                    break
                }
            }
        }
    }

    private func reportError(_ text: String) {
        lastError = text
        statusLine = text
    }

    // MARK: - Native pages over this Web host

    /// Stops and starts the one Web host so a saved model-service change takes
    /// effect. The workspace, WAL, session JSONL and the pinned loopback origin
    /// stay the same, and the persistent website store keeps
    /// `dsh.sessions.current`, so the page resumes the existing session.
    func restartForConfigurationChange() async {
        guard mode == .web else { return }
        modelSettingsPresented = false
        await stop()
        await start()
    }

    private func installSettingsBridge(on engine: WebEngine) {
        let bridge = WebHostModelSettingsBridge(model: self)
        engine.view.configuration.userContentController.add(
            bridge, name: WebHostModelSettingsBridge.messageHandlerName)
        settingsBridge = bridge
        let mcpBridge = MCPControlBridge(controller: mcpControl)
        let contentController = engine.view.configuration.userContentController
        contentController.addUserScript(
            WKUserScript(source: MCPControlBridge.pageLifecycleScript(),
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: true))
        if #available(iOS 14.0, *) {
            contentController.addScriptMessageHandler(
                mcpBridge, contentWorld: .page,
                name: MCPControlBridge.messageHandlerName)
        }
        mcpSettingsBridge = mcpBridge
    }

    /// Detach every page handler this host installed. The engine itself is
    /// about to be shut down or replaced; leaving a handler on a dead web view
    /// would keep the bridge (and through it the host) alive.
    private func removePageHandlers() {
        // Close an in-flight MCP grant transaction before the page handler is
        // detached. A reload/crash must not leave an exact egress grant and a
        // staged Keychain account with no page able to commit or roll it back.
        mcpSettingsBridge?.close()
        if let engine {
            nativePreview?.uninstall()
            let controller = engine.view.configuration.userContentController
            controller.removeScriptMessageHandler(
                forName: WebEngineDirectoryImport.messageHandlerName)
            controller.removeScriptMessageHandler(
                forName: WebHostModelSettingsBridge.messageHandlerName)
            if #available(iOS 14.0, *) {
                controller.removeScriptMessageHandler(
                    forName: MCPControlBridge.messageHandlerName)
            }
        }
        settingsBridge = nil
        mcpSettingsBridge = nil
        nativePreview = nil
        directoryImport = nil
        directoryImportHandler = nil
    }

    /// Install Quick Look and the Files directory importer on the engine
    /// before the page loads. Both bridges resolve the current Worker transport
    /// lazily, so the page can render its real actions on the first pass instead
    /// of waiting for a later re-render after the host boots.
    private func installPageHandlers(on engine: WebEngine) {
        let workspace = materializedWorkspace
        let resolver = WebEngineNativePreviewResolver(
            currentSessionID: { [weak self] in
                await self?.currentWebSessionID()
            },
            workspacePath: { [weak self] sessionID, path in
                guard let self else {
                    throw PhoneDSHError.invalidState("the local Web host is not running")
                }
                return try await self.workspaceFileAbsolutePath(sessionID: sessionID,
                                                               path: path)
            })
        let preview = WebEngineNativePreview(resolver: resolver,
                                             workspaceDirectory: workspace)
        preview.install(on: engine.view)
        nativePreview = preview

        let sink = WebHostLazyDirectoryImportSink { [weak self] in
            guard let self else {
                throw PhoneDSHError.invalidState("the local Web host is not running")
            }
            return try await self.makeTransportForPage()
        }
        let importer = WebEngineDirectoryImport(webView: engine.view, sink: sink)
        let handler = WebEngineDirectoryImportScriptHandler(importer: importer)
        engine.view.configuration.userContentController.addScriptMessageHandler(
            handler,
            contentWorld: .page,
            name: WebEngineDirectoryImport.messageHandlerName)
        directoryImport = importer
        directoryImportHandler = handler
    }

    func makeTransportForPage() async throws -> any DSHRemoteTransport {
        guard let host else {
            throw PhoneDSHError.invalidState("the local Web host is not running")
        }
        return try await host.makeTransport()
    }

    /// Reload the native grant document into the live policy. Called by the
    /// native MCP editor and the page bridge after every committed change.
    func refreshMCPAccessPolicy() {
        mcpControl.refreshPolicy()
        mcpAccessPolicy = mcpControl.policy
        mcpAccessWarning = nil
    }

    @discardableResult
    func grantMCPAccess(serverName: String,
                        url: String,
                        headers: [String],
                        values: [String: String] = [:]) throws -> PhoneMCPAccessGrant {
        let grant = try mcpControl.grant(serverName: serverName,
                                         url: url,
                                         headers: headers,
                                         values: values)
        mcpAccessPolicy = mcpControl.policy
        return grant
    }

    func revokeMCPAccess(serverName: String) throws {
        try mcpControl.revoke(serverName: serverName)
        mcpAccessPolicy = mcpControl.policy
    }

    func reconcileMCPAccess(existingServers: [String: String]) {
        do {
            _ = try mcpControl.reconcile(existingServers: existingServers)
            mcpAccessPolicy = mcpControl.policy
        } catch {
            mcpAccessWarning = error.localizedDescription
        }
    }

    /// Resolve a page path through the Worker's own `workspaceFiles/stat`.
    private func workspaceFileAbsolutePath(sessionID: String,
                                           path: String) async throws -> String {
        let transport = try await makeTransportForPage()
        let result = try await transport.call(
            "workspaceFiles/stat",
            args: .object([
                "workspaceFileScopeId": .string(sessionID),
                "path": .string(path),
            ]))
        guard let absolute = result["absolutePath"]?.stringValue else {
            throw PhoneDSHError.invalidResponse(
                "workspaceFiles/stat returned no absolutePath")
        }
        return absolute
    }

    /// Read the session the complete Web page currently shows from its own
    /// persisted selection. This is the same localStorage key the DSH Web
    /// client writes; the native resolver never invents a session id.
    private func currentWebSessionID() async -> String? {
        guard let view = engine?.view else { return nil }
        let script = """
        (() => {
          try {
            const raw = localStorage.getItem('dsh.sessions.current');
            if (!raw) return null;
            const value = JSON.parse(raw);
            return value && typeof value.sessionId === 'string' ? value.sessionId : null;
          } catch (error) { return null; }
        })()
        """
        return await withCheckedContinuation { continuation in
            view.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
    }

    // MARK: - Stable loopback origin

    /// Reuses the port this install used last time when it is still free.
    ///
    /// The selection is persisted so an App relaunch normally keeps the same
    /// origin as well. A collision falls back to a newly probed port; the
    /// in-process park/resume path never re-probes, which is what keeps
    /// `dsh.sessions.current` attached to one origin.
    private static func resolveLoopbackPort() -> UInt16 {
        let defaults = UserDefaults.standard
        let saved = defaults.integer(forKey: loopbackPortDefaultsKey)
        if saved >= 1024, saved <= Int(UInt16.max),
           isLoopbackPortAvailable(UInt16(saved)) {
            return UInt16(saved)
        }
        let free = freeLoopbackPort()
        if free != 0 {
            defaults.set(Int(free), forKey: loopbackPortDefaultsKey)
        }
        return free
    }

    private static func isLoopbackPortAvailable(_ port: UInt16) -> Bool {
        guard let descriptor = boundLoopbackSocket(port: port) else { return false }
        Darwin.close(descriptor)
        return true
    }

    private static func freeLoopbackPort() -> UInt16 {
        guard let descriptor = boundLoopbackSocket(port: 0) else { return 0 }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard result == 0 else { return 0 }
        return UInt16(bigEndian: address.sin_port)
    }

    /// Binds (but does not listen on) `127.0.0.1:port`; `0` asks the kernel
    /// for a free port. The descriptor is returned so the caller can read the
    /// bound port or close it; the actual listener binds the same port later.
    private static func boundLoopbackSocket(port: UInt16) -> Int32? {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var reuse: Int32 = 1
        _ = Darwin.setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse,
                              socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        return descriptor
    }

    private func waitForAnchor() async {
        let deadline = Date().addingTimeInterval(2)
        while !anchor.isInWindow && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// The complete Web page must be allowed to paint under the notch/home
    /// indicator; `viewport-fit=cover` makes its CSS `env(safe-area-inset-*)`
    /// values match the full-screen WKWebView.
    private static func installViewportCover(on engine: WebEngine) {
        let source = """
        (function () {
          function apply() {
            var meta = document.querySelector('meta[name="viewport"]');
            if (!meta) {
              meta = document.createElement('meta');
              meta.setAttribute('name', 'viewport');
              (document.head || document.documentElement).appendChild(meta);
            }
            var content = meta.getAttribute('content') || 'width=device-width, initial-scale=1';
            if (content.indexOf('viewport-fit') === -1) {
              meta.setAttribute('content', content + ', viewport-fit=cover');
            }
          }
          apply();
          window.addEventListener('load', apply);
        })();
        """
        engine.view.configuration.userContentController.addUserScript(
            WKUserScript(source: source,
                         injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true))
    }
}

/// Lazily resolves the one Worker transport when the first directory-import
/// message arrives. The page handler is installed before boot; no session,
/// workspace or transport is created until the user picks a folder.
private final class WebHostLazyDirectoryImportSink: WebEngineDirectoryImportSink, @unchecked Sendable {
    private let lock = NSLock()
    private var sink: PhoneDSHWorkspaceImportSink?
    private let transportProvider: @Sendable () async throws -> any DSHRemoteTransport

    init(transportProvider: @escaping @Sendable () async throws -> any DSHRemoteTransport) {
        self.transportProvider = transportProvider
    }

    func begin(_ manifest: WebEngineDirectoryImportManifest) async throws -> String {
        try await resolvedSink().begin(manifest)
    }

    func write(importID: String, path: String, offset: Int, data: Data) async throws {
        try await resolvedSink().write(importID: importID, path: path,
                                       offset: offset, data: data)
    }

    func commit(importID: String) async throws -> WebEngineDirectoryImportResult {
        try await resolvedSink().commit(importID: importID)
    }

    func abort(importID: String) async {
        guard let resolved = try? await resolvedSink() else { return }
        await resolved.abort(importID: importID)
    }

    private func resolvedSink() async throws -> PhoneDSHWorkspaceImportSink {
        lock.lock()
        let existing = sink
        lock.unlock()
        if let existing { return existing }
        let transport = try await transportProvider()
        let created = PhoneDSHWorkspaceImportSink(transport: transport)
        lock.lock()
        if let current = sink {
            lock.unlock()
            return current
        }
        sink = created
        lock.unlock()
        return created
    }
}

/// The page's real "open native model settings" action. The phone model tab
/// posts `{v: 1, action: "open-model-settings"}` only when this handler exists;
/// it is installed on the same WKWebView as the DSH page and never starts a
/// second host.
@MainActor
private final class WebHostModelSettingsBridge: NSObject, WKScriptMessageHandler {
    static let messageHandlerName = "pdshOpenModelSettings"

    private weak var model: WebHostModel?

    init(model: WebHostModel) {
        self.model = model
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        // The phone settings tab posts `{v: 1, action: ...}`. An absent or
        // unrecognised action keeps the original model-settings behaviour.
        let action = (message.body as? [String: Any])?["action"] as? String
        switch action {
        case "open-search-settings":
            model?.searchSettingsPresented = true
        case "enter-native-recovery":
            guard let model else { return }
            Task { await model.enterNativeRecovery() }
        default:
            model?.modelSettingsPresented = true
        }
    }
}
