// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS Phase 0 probe app (PLAN W3-APP).
//
// Entry point. The app has five pages: Probes (the W3-PROBES suite on the
// device UI actor), Memory (real PhoneDSHHost boots with 20/50/100 MB
// synthetic overlays and a scripted session), Background (the background/lock
// matrix), Screen (the black low-brightness task screen) and Export (the
// aggregated JSON report).
//
// Every device-only number starts empty: nothing here claims iPhone behaviour
// until a run on a device records it.

import ProbeKit
import SwiftUI
import PhoneDSH
import PhoneDSHBLE
#if DEBUG
import BackgroundTasks
#endif
#if DEBUG
import PhoneDSHVenus
#endif

@main
struct PhoneDSHProbeApp: App {
    // Remote-notification registration and background task pushes (cloud-tasks.md §8).
    @UIApplicationDelegateAdaptor(ProbeAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()
    @State private var workspaceModels = WorkspaceModels.shared
    @State private var preferences = NativeChatPreferences.shared

    init() {
        #if DEBUG
        DebugEngineQuarantine.runIfRequested()   // DEBUG recovery: moves chat-host aside, then exits
        DebugChannel.shared.install()            // DEBUG developer control channel (spec/dev/debug-channel.md)
        #endif
        // P09 main-thread bound: start the hang evidence first, before any
        // scene work. The monitor writes through the same off-main status log
        // the chat pipeline uses, so a blocked main actor still leaves a trace.
        MainThreadHangMonitor.shared.start { line in
            ChatStatusLogWriter.shared.append(line)
        }
        MainThreadHangMonitor.mark("app.launch")
        MetricDiagnosticsRecorder.shared.start()
        // Local notification taps are received by the App delegate before the
        // SwiftUI scene is ready; install the one deep-link router here.
        BotNotificationRouter.shared.install()
        // P18/D2: copy legacy bare-sessionID stores into the phone scope once.
        // The old keys stay readable so a rollback still finds the pre-D2 data.
        WorkspaceStorageMigration.runIfNeeded()
        // The board's wake word 你好小智 starts a voice turn (tonolink-board.md §4.1). Started here,
        // not in a scene task, so a background relaunch by Bluetooth state restoration listens too.
        #if DEBUG
        // USB OTA diagnostics need exclusive ownership of the board's BLE ctrl connection.
        // The normal voice listener is restarted on the next ordinary app launch.
        if !Self.boardDiagnosticRequested {
            Task { @MainActor in TonoLinkVoiceHost.shared.start(); DeviceBotRegistry.shared.start() }
        }
        #else
        Task { @MainActor in TonoLinkVoiceHost.shared.start(); DeviceBotRegistry.shared.start() }
        #endif
        // The phone task queue follows the account from launch, a background launch by a
        // task push included. It starts no engine and no timer.
        Task { @MainActor in CloudTaskCenter.shared.start() }
        // PLAN §2.8: every channel (board, push, BGTask) delivers to the one
        // launch orchestrator entry. Installing here covers a background
        // relaunch by Bluetooth state restoration too.
        Task { @MainActor in EngineLaunchOrchestrator.shared.installWakeSources() }
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["PDSH_APPEARANCE"],
           let value = NativeAppearance(rawValue: raw) {
            NativeChatPreferences.shared.setAppearance(value)
        }
        Self.seedProviderFromEnvironment()
        Self.seedVisionFromFile()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // The native shell is a light design (hard-coded ink and
                // surface colors); without this the system's dark appearance
                // turns the page background black under a light layout.
                .preferredColorScheme(preferences.appearance.colorScheme)
                .environment(model)
                .environment(\.workspaceModels, workspaceModels)
                .onOpenURL { GmailSignIn.handleCallback($0) }
                // Single scene-phase observer. Chat keep-alive / park / resume
                // and the background-matrix runner each receive the phase once.
                // RootView and ChatPage do not observe scene phase.
                // `deliver` serializes and supersedes its own deliveries; the
                // Task here only leaves SwiftUI's synchronous callback.
                .onChange(of: scenePhase) { _, newPhase in
                    Task { @MainActor in
                        // I5: a scene-based SwiftUI App receives the background
                        // transition here, not in the app delegate. Project the
                        // earliest WakeDemand before the process can suspend.
                        if newPhase == .background {
                            await EngineLaunchOrchestrator.shared.appDidEnterBackground()
                        }
                        #if PDSH_ENABLE_DEVICE_TASKS
                        await DeviceTaskManager.shared.sceneActive(newPhase == .active)
                        #endif
                        await ProbeScenePhaseForwarding.deliver(
                            newPhase,
                            chat: { phase in
                                await ChatModel.shared.scenePhaseChanged(phase)
                                // The PC backend is a separate ChatModel; the
                                // foreground must also wake PCLinkClient and
                                // refill the follow stream.
                                if phase == .active {
                                    await workspaceModels.scenePhaseChanged(true)
                                    // One pull → admit → ack pass (cloud-tasks.md §7); off = no-op.
                                    CloudTaskCenter.shared.appBecameActive()
                                    // PLAN §2.1: foreground is one wake among
                                    // the channels; the orchestrator decides
                                    // boot/resume/sweep, never a call site.
                                    _ = await EngineLaunchOrchestrator.shared.wake(.foreground, lease: nil)
                                }
                            },
                            backgroundMatrix: { phase in
                                await model.scenePhaseChanged(phase)
                            })
                    }
                }
                .task {
                    #if PDSH_ENABLE_DEVICE_TASKS
                    await DeviceTaskManager.shared.sceneActive(scenePhase == .active)
                    // Opt-in test builds may negotiate experimental task discovery.
                    // BLE task grants remain unavailable while GAP-16 is open.
                    BLEDeviceStore.shared.setDeviceTaskDiscoveryEnabled(true)
                    #endif
                    model.refreshLockdown()
                    // The user's own boards: connected once means trusted, and they reconnect by themselves.
                    #if DEBUG
                    let runningBoardDiagnostic = Self.boardDiagnosticRequested
                    #else
                    let runningBoardDiagnostic = false
                    #endif
                    if !runningBoardDiagnostic {
                        BLEDeviceStore.shared.trustConnectedDevices = true
                        BLEDeviceStore.shared.reconnectRemembered()
                    }
                    await workspaceModels.startAtLaunch()
                    #if DEBUG
                    PCLinkDebugAutomation.shared.start(models: workspaceModels)
                    #endif
                    // Phase A always paints (Bot store + roster, snapshot,
                    // outbox scan) without waiting for the engine.
                    await ChatModel.shared.prepareLaunchContentForWake()
                    // PLAN §2.6: the phone engine starts silently when the
                    // phone segment is selected, at least one Bot exists, or
                    // the outbox / admission journal holds pending work — not
                    // only when the phone segment is selected.
                    if await workspaceModels.shouldStartPhoneEngineAtLaunch() {
                        _ = await EngineLaunchOrchestrator.shared.wake(.coldLaunch, lease: nil)
                    }
                }
                #if DEBUG
                .task {
                    guard !Self.boardDiagnosticRequested else { return }
                    await Self.bleAutoconnect()
                }
                .task {
                    // DEBUG only, launch argument `-pdsh-selftest-device-app 1`; bypasses the install approval card.
                    await DeviceAppSelfTest.runIfRequested()
                }
                .task {
                    // DEBUG only: prove the WakeDemand projection reaches the
                    // OS (BGAppRefresh + BGProcessing) and record what the
                    // scheduler reports as pending.
                    if ProcessInfo.processInfo.environment["PDSH_BG_PROJECTION_SELFTEST"] == "1" {
                        await Self.runBGProjectionSelfTest()
                    }
                }
                .task {
                    // DEBUG only, launch argument `-pdsh-cleanup-leaked-bots dry|run` (one-shot, see the file).
                    await DeviceBotLeakCleanup.runIfRequested()
                }
                .task {
                    // DEBUG only, launch argument `-pdsh-selftest-device-bot-chat 1`; auto-approves the install approval.
                    await DeviceBotChatSelfTest.runIfRequested()
                }
                .task {
                    if let mode = ProcessInfo.processInfo.environment["PDSH_TONOLINK_USB_OTA"] { await TonoLinkUSBOTADiagnostics.run(mode) }
                }
                .task {
                    if let mode = ProcessInfo.processInfo.environment[FirmwareBuilderDiagnostics.environmentKey] { await FirmwareBuilderDiagnostics.run(mode) }
                }
                .task {
                    // DEBUG device-test hook (spec/device/v1/xiaozhi-firmware.md §8): start the OTA relay so a
                    // board (or a test client on the Wi-Fi) can reach it headlessly. The wiring installs the
                    // SDK relay when a pack with sources_root is staged; this just switches it on.
                    if ProcessInfo.processInfo.environment["PDSH_XIAOZHI_RELAY"] == "on" {
                        try? await Task.sleep(for: .seconds(2))
                        await XiaozhiFirmwareModel.shared.startRelayForDiagnostics()
                    }
                }
                .task {
                    if let mac = ProcessInfo.processInfo.environment[XiaozhiE2EDiagnostics.environmentKey] { await XiaozhiE2EDiagnostics.run(mac: mac) }
                }
                #endif
        }
    }
}

#if DEBUG
extension PhoneDSHProbeApp {
    /// 调试用:从环境变量一次性写入模型服务与密钥,避免把密钥敲进界面。
    /// 只在值变化时写,正常启动什么都不做。
    static func seedProviderFromEnvironment() {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["PDSH_SEED_PROVIDER_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return }
        let base = env["PDSH_SEED_PROVIDER_BASE"] ?? "https://api.deepseek.com/anthropic"
        let model = env["PDSH_SEED_PROVIDER_MODEL"] ?? "deepseek-chat"
        let name = env["PDSH_SEED_PROVIDER_NAME"] ?? "DeepSeek"
        let store = PhoneModelProviderSettings.shared
        let profile = ProviderProfile(id: "deepseek", displayName: name, baseURL: base, model: model)
        do {
            try store.upsert(profile, apiKey: key)
            try store.select(id: profile.id)
            let status = try store.apiKeyStatus(for: profile.id)
            ChatModel.appendDiagnostic(
                "provider seed: \(profile.id), model=\(profile.model), key=\(String(describing: status))")
        } catch {
            ChatModel.appendDiagnostic("provider seed failed: \(error)")
        }
    }
}

extension PhoneDSHProbeApp {
    /// Seeds UI-Venus settings from Library/Caches/vision-bootstrap.json (`PDSH_VISION_IMPORT=1`) so a
    /// key never has to be typed into the UI on a test phone. The file is deleted after reading.
    static func seedVisionFromFile() {
        guard ProcessInfo.processInfo.environment["PDSH_VISION_IMPORT"] == "1" else { return }
        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("vision-bootstrap.json")
        defer { try? FileManager.default.removeItem(at: file) }
        struct Import: Decodable { let baseURL: String; let model: String; let key: String }
        do {
            let value = try JSONDecoder().decode(Import.self, from: Data(contentsOf: file))
            try VenusSettings.shared.save(VenusConfiguration(baseURL: value.baseURL, model: value.model), key: value.key)
        } catch { /* Never log credential material. Settings supports correction. */ }
    }

    #if DEBUG
    /// A headless board diagnostic owns the board's BLE ctrl connection for its whole run.
    static var boardDiagnosticRequested: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["PDSH_TONOLINK_USB_OTA"] != nil || environment[FirmwareBuilderDiagnostics.environmentKey] != nil
    }
    #endif

    /// DEBUG only: seed one future demand, project it onto the OS channels,
    /// and record `BGTaskScheduler`'s pending requests for evidence.
    @MainActor static func runBGProjectionSelfTest() async {
        let key = "projection-selftest"
        let dueAt = WakeDemandLedger.nowMs() + 120_000
        await EngineLaunchOrchestrator.shared.upsertWakeDemand(WakeDemand(
            source: .dshSchedule, key: key, dueAtMs: dueAt,
            kind: .once, userVisible: false))
        await EngineLaunchOrchestrator.shared.appDidEnterBackground()
        try? await Task.sleep(for: .seconds(1))
        let pending: [BGTaskRequest] = await withCheckedContinuation { continuation in
            BGTaskScheduler.shared.getPendingTaskRequests { continuation.resume(returning: $0) }
        }
        let rows: [[String: Any]] = pending.map { request in
            ["identifier": request.identifier,
             "earliestBeginDate": request.earliestBeginDate.map(\.timeIntervalSince1970) ?? -1]
        }
        let payload: [String: Any] = ["dueAtMs": dueAt, "requests": rows]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("pdsh-reports", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("bg-projection.json"))
        NSLog("PDSH_BG_PROJECTION %@", String(data: data, encoding: .utf8) ?? "")
        await EngineLaunchOrchestrator.shared.removeWakeDemand(source: .dshSchedule, key: key)
    }

    /// `PDSH_BLE_AUTOCONNECT=<name substring>` scans in-app and connects the first match through the
    /// ordinary BLE device store (Link tools such as light.set, and the board's HID bond).
    @MainActor static func bleAutoconnect() async {
        guard let want = ProcessInfo.processInfo.environment["PDSH_BLE_AUTOCONNECT"], !want.isEmpty else { return }
        let store = BLEDeviceStore.shared
        for _ in 0..<6 {
            store.scan()
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(500))
                if let device = store.devices.first(where: { $0.name.localizedCaseInsensitiveContains(want) }) {
                    if device.state == "未连接" { store.connect(device.id) }
                    return
                }
            }
        }
    }
}
#endif
