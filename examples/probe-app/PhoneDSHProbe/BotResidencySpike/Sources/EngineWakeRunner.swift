// SPDX-License-Identifier: MIT
//
// Engine-first-launch wake measurement runner (plan §2.4) — spike only.
//
// It measures, per scenario: wake -> host.start()/resume() return, whether
// WebContent was replaced, the backgroundTimeRemaining curve, whether a scene
// was connected, and whether the anchor was in a window. It boots even when the
// provisional lease rule would defer, and records `forcedForMeasurement`, so
// the caller gets a latency distribution instead of an empty run.
//
// It never edits production policy and never invents a physical-device wake:
// push and BGProcessing triggers come from the OS / operator, and the board
// scenario uses the audio-resident path at the same app entry a board wake uses.

#if BOT_RESIDENCY_SPIKE

import Foundation
import PhoneDSH
import PhoneDSHAgentCore
import PhoneDSHEngine
import PhoneDSHHarness
import ProbeKit
import SwiftUI
import UIKit

@MainActor
final class EngineWakeRunner: ObservableObject {
    static let shared = EngineWakeRunner()

    @Published private(set) var statusText = "Idle"
    @Published private(set) var phase = "idle"
    @Published private(set) var currentScenario: String?
    @Published private(set) var attemptsRecorded = 0

    let anchor = VisibleEngineAnchor()
    let visibleContainer = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))

    private(set) var configuration: EngineWakeConfiguration?
    private(set) var deviceToken: String?
    private(set) var deviceTokenError: String?
    private(set) var lanPort: UInt16?

    private let thresholds = EngineWakeThresholds()
    private let keepAlive = SilentAudioKeepAlive()
    private let mock = MockModelUpstream()
    private let lanListener = EngineWakeLANListener()
    private let processStartedUptime = ProcessInfo.processInfo.systemUptime

    private var store: EngineWakeEvidenceStore?
    private var offscreen: SpikeOffscreenEngineWindow?
    private var host: PhoneDSHHost?
    private var scenarios: [EngineWakeScenarioRecord] = []
    private var backgroundSamples: [EngineWakeBackgroundSample] = []
    private var samplerTask: Task<Void, Never>?
    private var samplingStartedAt = Date()
    private var pendingTrigger: EngineWakePendingTrigger?
    private var pendingProbe: EngineWakePendingProbe?
    private var started = false
    private var finished = false
    private var currentScenePhase: ScenePhase = .inactive
    private var lastStateWrite = Date.distantPast
    private var syntheticBoardTask: Task<Void, Never>?

    private init() {}

    var isArmedOnly: Bool {
        configuration?.armOnly == true || EngineWakeMode.isArmOnly
    }

    // MARK: - Entry

    func startFromLaunch() {
        guard !started else { return }
        started = true
        Task { @MainActor in await self.run() }
    }

    func visibleContainerDidAppear() {
        moveAnchorToVisibleIfPossible()
    }

    func scenePhaseChanged(_ phase: ScenePhase) async {
        currentScenePhase = phase
        store?.appendEvent(kind: "scene-phase", detail: String(describing: phase))
        switch phase {
        case .background:
            break
        case .active:
            moveAnchorToVisibleIfPossible()
        default:
            break
        }
        writeState(force: true)
    }

    func recordDeviceToken(_ token: String) {
        deviceToken = token
        writeState(force: true)
    }

    func recordDeviceTokenError(_ message: String) {
        deviceTokenError = message
        store?.appendEvent(kind: "device-token-error", detail: message)
        writeState(force: true)
    }

    // MARK: - Run

    private func run() async {
        let arguments = ProcessInfo.processInfo.arguments
        let parsed = (try? EngineWakeConfiguration.parse(arguments))
            ?? EngineWakeArmedStore.load()
        guard let configuration = parsed else {
            phase = "aborted"
            statusText = "No engine-wake configuration (launch with --mode engine-wake)"
            return
        }
        self.configuration = configuration
        offscreen = SpikeOffscreenEngineWindow(anchor: anchor)
        do {
            store = try EngineWakeEvidenceStore(runID: configuration.runID)
        } catch {
            phase = "aborted"
            statusText = "evidence directory failed: \(error)"
            return
        }
        guard let store else { return }
        let ids = configuration.scenarios.compactMap(EngineWakeScenarioID.init(rawValue:))
        scenarios = ids.map { EngineWakeScenarioRecord(id: $0.rawValue) }
        store.appendEvent(kind: "engine-wake-start",
                          detail: "scenarios=\(configuration.scenarios.joined(separator: ",")) "
                            + "class=\(EngineWakeDeviceClass.current)")

        if !anchor.isInWindow {
            _ = offscreen?.attach()
        }
        installLANListener(port: configuration.lanPort)
        writeState(phase: "starting",
                   detail: "anchorInWindow=\(anchor.isInWindow) scene=\(hasConnectedScene)")

        if configuration.armOnly || EngineWakeMode.isArmOnly {
            // Persist the run for the push relaunch, but not the arm-only flag:
            // the relaunched process must execute the scenarios.
            var armedConfiguration = configuration
            armedConfiguration.armOnly = false
            self.configuration = armedConfiguration
            try? EngineWakeArmedStore.save(armedConfiguration)
            UIApplication.shared.registerForRemoteNotifications()
            phase = "armed"
            statusText = "Armed. The host command will terminate this process; "
                + "send the content-available push afterwards."
            writeState(phase: "armed",
                       detail: "deviceToken=\(deviceToken ?? "pending")")
            return
        }

        UIApplication.shared.registerForRemoteNotifications()

        for (index, scenario) in ids.enumerated() {
            if finished { break }
            scenarios[index] = await runScenario(scenario, record: scenarios[index])
            statusText = "Finished \(scenario.rawValue)"
            moveAnchorToVisibleIfPossible()
            writeState(force: true)
        }

        await finish()
    }

    private func runScenario(_ scenario: EngineWakeScenarioID,
                             record initialRecord: EngineWakeScenarioRecord) async
        -> EngineWakeScenarioRecord {
        var record = initialRecord
        pendingProbe = nil
        currentScenario = scenario.rawValue
        record.status = "running"
        phase = "scenario"
        statusText = "Measuring \(scenario.rawValue)"
        writeState(force: true)

        switch scenario {
        case .pushColdStart:
            await prepareAbsentHost()
            let attemptCount = scenario.expectsColdProcess ? 1 : (configuration?.iterations ?? 1)
            for index in 1...max(1, attemptCount) {
                setPendingTrigger(id: "push-cold-\(index)", kind: "push",
                                  instructions: "Send one APNs content-available (background) push "
                                    + "to \(Bundle.main.bundleIdentifier ?? "this app") now. "
                                    + "The process must not already be running.")
                guard let trigger = await waitForTrigger(timeout: 300) else {
                    record.notes.append("no push arrived within 300 s")
                    break
                }
                clearPendingTrigger()
                let attempt = await measure(trigger, scenario: scenario, attemptIndex: index,
                                            residentAudio: keepAlive.isRendering)
                record.attempts.append(attempt)
                attemptsRecorded += 1
                break // a cold process exists only once per launch
            }

        case .pushParkedResume:
            await ensureParkedHost()
            let attemptCount = configuration?.iterations ?? 1
            for index in 1...max(1, attemptCount) {
                setPendingTrigger(id: "push-resume-\(index)", kind: "push",
                                  instructions: "Send one APNs content-available push. The host is "
                                    + "parked (engine released); the app process is alive.")
                guard let trigger = await waitForTrigger(timeout: 300) else {
                    record.notes.append("no push arrived within 300 s")
                    break
                }
                clearPendingTrigger()
                let attempt = await measure(trigger, scenario: scenario, attemptIndex: index,
                                            residentAudio: keepAlive.isRendering)
                record.attempts.append(attempt)
                attemptsRecorded += 1
                if index < attemptCount { await parkHost() }
            }

        case .bgProcessingColdStart:
            await prepareAbsentHost()
            setPendingTrigger(id: "bgprocessing-1", kind: "bgprocessing",
                              instructions: "Let the system run the submitted BGProcessingTask, or "
                                + "simulate it from Xcode (Debug > Simulate Background Task) with "
                                + "identifier \(EngineWakeBGTask.identifier).")
            EngineWakeBGTask.submit()
            if let trigger = await waitForTrigger(timeout: 600) {
                clearPendingTrigger()
                let attempt = await measure(trigger, scenario: scenario, attemptIndex: 1,
                                            residentAudio: false)
                record.attempts.append(attempt)
                attemptsRecorded += 1
            } else {
                record.notes.append("BGProcessingTask did not launch within 600 s")
            }

        case .boardWakeColdStart:
            await prepareAbsentHost()
            do {
                try keepAlive.start(owner: "engine-wake-board")
                keepAlive.hideNowPlaying()
            } catch {
                record.notes.append("audio keep-alive failed: \(error)")
            }
            setPendingTrigger(id: "board-1", kind: "board",
                              instructions: "Trigger the board wake. With no board attached the "
                                + "spike synthesises it in 3 s at the same audio-resident entry.")
            syntheticBoardTask?.cancel()
            syntheticBoardTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                EngineWakeTriggerBus.shared.deliver(.boardWake)
                self.store?.appendEvent(
                    kind: "synthetic-board-wake",
                    detail: "no BLE radio in the spike; same entry as the board path")
            }
            if let trigger = await waitForTrigger(timeout: 30) {
                clearPendingTrigger()
                let attempt = await measure(trigger, scenario: scenario, attemptIndex: 1,
                                            residentAudio: keepAlive.isRendering)
                record.attempts.append(attempt)
                attemptsRecorded += 1
            } else {
                record.notes.append("board wake was not observed within 30 s")
            }
            keepAlive.stop(owner: "engine-wake-board")

        case .lanResident:
            await ensureRunningHost()
            if host != nil {
                let attempt = readyAttempt(scenario: scenario, trigger: "lan-http",
                                           residentAudio: keepAlive.isRendering)
                record.attempts.append(attempt)
                attemptsRecorded += 1
            } else {
                record.notes.append("host was not running for the resident probe")
            }
            let index = configuration?.iterations ?? 1
            for probeIndex in 1...max(1, index) {
                await requestProbe(scenario: scenario, probeIndex: probeIndex, delay: 0)
                try? await Task.sleep(for: .seconds(30))
            }

        case .lanSuspended:
            await ensureParkedHost()
            setPendingTrigger(id: "lan-suspended-home", kind: "lan",
                              instructions: "Press Home now and leave the device locked. "
                                + "The helper will probe the local port, then ask for the "
                                + "cloud-task push fallback.")
            await waitForBackground(timeout: 120)
            if currentScenePhase != .background {
                record.notes.append("the app never entered the background; the suspended "
                    + "probe was not attempted")
            } else {
                keepAlive.stop(owner: "engine-wake-board")
                await parkHost()
                await requestProbe(scenario: scenario, probeIndex: 1, delay: 10)
                setPendingTrigger(id: "lan-suspended-push", kind: "push",
                                  instructions: "The helper has probed the suspended app. Send the "
                                    + "cloud-task push (same v1 payload) to wake it.")
                if let trigger = await waitForTrigger(timeout: 300) {
                    clearPendingTrigger()
                    let attempt = await measure(trigger, scenario: scenario, attemptIndex: 1,
                                                residentAudio: false)
                    record.attempts.append(attempt)
                    attemptsRecorded += 1
                } else {
                    record.notes.append("cloud-task push fallback did not arrive within 300 s")
                }
            }
        }

        record.status = record.attempts.isEmpty ? "NOT_RUN" : "COMPLETE"
        phase = "between"
        return record
    }

    private func finish() async {
        guard !finished else { return }
        finished = true
        samplerTask?.cancel()
        syntheticBoardTask?.cancel()
        if let configuration, let store {
            let report = EngineWakeReport(
                runID: configuration.runID,
                deviceClass: EngineWakeDeviceClass.current,
                configuration: configuration,
                thresholds: thresholds,
                scenarios: scenarios)
            store.writeReport(report)
        }
        phase = "complete"
        statusText = "Measurement complete; the host command writes the verdict."
        writeState(phase: "complete", detail: "attempts=\(attemptsRecorded)")
        EngineWakeArmedStore.clear()
        EngineWakeBackgroundAssertion.shared.end()
        keepAlive.stop(owner: "engine-wake-board")
        lanListener.stop()
        try? await host?.park()
        host = nil
        anchor.shutdown()
        offscreen?.teardown()
        mock.stop()
    }

    private func fail(_ reason: String) async {
        phase = "aborted"
        statusText = reason
        guard let store else { return }
        store.appendEvent(kind: "aborted", detail: reason)
        if let configuration {
            store.writeReport(EngineWakeReport(
                runID: configuration.runID,
                deviceClass: EngineWakeDeviceClass.current,
                configuration: configuration,
                thresholds: thresholds,
                scenarios: scenarios))
        }
        writeState(phase: "aborted", detail: reason)
        EngineWakeArmedStore.clear()
    }

    // MARK: - Host

    private func prepareAbsentHost() async {
        if let host {
            try? await host.park()
            try? await host.stop()
            self.host = nil
            anchor.shutdown()
        }
        _ = offscreen?.attach()
    }

    private func ensureRunningHost() async {
        if host == nil {
            do {
                host = try makeHost()
                try await host?.start()
            } catch {
                store?.appendEvent(kind: "host-start-failed", detail: String(describing: error))
            }
        } else {
            let state = await host?.state
            if state != .running { try? await host?.start() }
        }
        _ = offscreen?.attach()
    }

    private func ensureParkedHost() async {
        if host == nil {
            await ensureRunningHost()
        }
        await parkHost()
    }

    private func parkHost() async {
        guard let host else { return }
        let state = await host.state
        if state == .running || state == .starting {
            try? await host.park()
        }
    }

    private func makeHost() throws -> PhoneDSHHost {
        guard let store else { throw EngineWakeRunError.noStore }
        guard let bundle = WorkerBundleLocator.bundle() else {
            throw EngineWakeRunError.failed(WorkerBundleLocator.missingReason())
        }
        let workspace = store.root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        // A stopped host keeps no model server; starting a second listener would
        // leak the first port.
        mock.stop()
        mock.script = .generic(
            command: "printf engine-wake > engine-wake.txt && cat engine-wake.txt",
            toolText: "ENGINE_WAKE_TOOL",
            finalText: "ENGINE_WAKE_DELIVERED")
        let mockURL = try mock.start()
        var configuration = PhoneDSHConfiguration(
            workspaceRoot: workspace,
            token: "",
            origin: URL(string: "http://127.0.0.1:1")!,
            bundle: bundle,
            allowedModelHosts: ["http://127.0.0.1:\(mock.port)"],
            credentialProvider: StaticCredentialProvider([
                CredentialScope(service: "127.0.0.1"):
                    Credential(kind: .apiKey(header: "x-api-key"),
                               value: "engine-wake-host-fixture"),
            ]),
            drainDeadline: 2,
            helloTimeout: 60)
        configuration.engine.bootTimeout = 60
        configuration.engine.environment = [
            "DEEPSEEK_BASE_URL": mockURL.absoluteString,
            "DEEPSEEK_API_KEY": "engine-wake-worker-placeholder",
            "DSH_TELEMETRY_DISABLED": "1",
        ]
        return PhoneDSHHost(configuration: configuration,
                            engineFactory: { [anchor] configuration in
            await anchor.makeEngine(configuration)
        })
    }

    // MARK: - Measurement

    private func measure(_ trigger: EngineWakeTrigger,
                         scenario: EngineWakeScenarioID,
                         attemptIndex: Int,
                         residentAudio: Bool) async -> EngineWakeAttempt {
        let triggeredAt = Date()
        let stateBefore = await hostStateName()
        let pidBefore = anchor.engine.flatMap { BotResidencyWebContentPID.read(from: $0.view) }
        let sceneConnected = hasConnectedScene
        let offscreenUsed = offscreen?.isHostingAnchor ?? false
        let lease = currentLeaseRemainingMs()
        let secondsSinceProcessStart = ProcessInfo.processInfo.systemUptime - processStartedUptime
        let wasRunning = secondsSinceProcessStart > 30

        var attempt = EngineWakeAttempt(
            attempt: attemptIndex,
            trigger: trigger.name,
            triggeredAt: BotResidencyTime.string(triggeredAt),
            hostStateBefore: stateBefore,
            decision: EngineWakePolicy.decide(
                scenario: scenario, hostState: stateBefore,
                leaseRemainingMs: lease, foreground: currentScenePhase == .active,
                residentAudio: residentAudio),
            processWasRunning: wasRunning,
            sceneConnectedAtTrigger: sceneConnected,
            offscreenWindowUsed: offscreenUsed,
            residentAudio: residentAudio,
            leaseRemainingMsAtTrigger: lease)
        attempt.forcedForMeasurement = !EngineWakePolicy.allowsImmediateAction(
            scenario: scenario, hostState: stateBefore, leaseRemainingMs: lease,
            foreground: currentScenePhase == .active, residentAudio: residentAudio)

        if !anchor.isInWindow {
            _ = offscreen?.attach()
        }
        startBackgroundSampling()
        do {
            if host == nil {
                host = try makeHost()
                try await host?.start()
            } else {
                let state = await host?.state
                // Already ready: the scenario measures the wake path up to ready.
                if state != .running { try await host?.start() }
            }
        } catch {
            attempt.error = String(describing: error)
            store?.appendEvent(kind: "wake-boot-failed", detail: String(describing: error))
        }
        let returned = Date()
        attempt.hostStartReturnedAt = attempt.error == nil
            ? BotResidencyTime.string(returned) : nil
        attempt.wakeToHostStartMs = attempt.error == nil
            ? returned.timeIntervalSince(triggeredAt) * 1000 : nil
        attempt.anchorInWindowAfterBoot = anchor.isInWindow
        let pidAfter = anchor.engine.flatMap { BotResidencyWebContentPID.read(from: $0.view) }
        attempt.webContentPIDBefore = pidBefore
        attempt.webContentPIDAfter = pidAfter
        attempt.webContentTerminated = pidBefore != nil && pidAfter != nil && pidBefore != pidAfter
        attempt.backgroundTimeRemainingCurve = stopBackgroundSampling()
        EngineWakeBackgroundAssertion.shared.end()
        store?.appendEvent(
            kind: "attempt",
            detail: "\(scenario.rawValue) trigger=\(trigger.name) "
                + "ms=\(attempt.wakeToHostStartMs.map { String(format: "%.1f", $0) } ?? "nil") "
                + "anchor=\(attempt.anchorInWindowAfterBoot) "
                + "error=\(attempt.error ?? "none")")
        return attempt
    }

    private func readyAttempt(scenario: EngineWakeScenarioID, trigger: String,
                              residentAudio: Bool) -> EngineWakeAttempt {
        let now = Date()
        var attempt = EngineWakeAttempt(
            attempt: 1,
            trigger: trigger,
            triggeredAt: BotResidencyTime.string(now),
            hostStateBefore: "running",
            decision: "ready",
            processWasRunning: true,
            sceneConnectedAtTrigger: hasConnectedScene,
            offscreenWindowUsed: offscreen?.isHostingAnchor ?? false,
            residentAudio: residentAudio,
            leaseRemainingMsAtTrigger: currentLeaseRemainingMs())
        attempt.hostStartReturnedAt = BotResidencyTime.string(now)
        attempt.wakeToHostStartMs = 0
        attempt.anchorInWindowAfterBoot = anchor.isInWindow
        attempt.webContentPIDAfter = anchor.engine.flatMap {
            BotResidencyWebContentPID.read(from: $0.view)
        }
        return attempt
    }

    private func requestProbe(scenario: EngineWakeScenarioID, probeIndex: Int,
                              delay: Double) async {
        guard let port = lanPort else {
            store?.appendEvent(kind: "lan-probe-unavailable",
                               detail: "listener did not bind a port")
            return
        }
        pendingProbe = EngineWakePendingProbe(
            id: "\(scenario.rawValue)-\(probeIndex)",
            scenario: scenario.rawValue,
            port: port,
            probeDelaySeconds: delay)
        writeState(force: true)
    }

    // MARK: - Trigger / state

    private func waitForTrigger(timeout: TimeInterval) async -> EngineWakeTrigger? {
        await EngineWakeTriggerBus.shared.wait(timeout: timeout)
    }

    private func setPendingTrigger(id: String, kind: String, instructions: String) {
        pendingTrigger = EngineWakePendingTrigger(id: id, kind: kind,
                                                  instructions: instructions)
        writeState(force: true)
    }

    private func clearPendingTrigger() {
        pendingTrigger = nil
        pendingProbe = nil
        writeState(force: true)
    }

    private func waitForBackground(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while currentScenePhase != .background, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func hostStateName() async -> String {
        guard let host else { return "absent" }
        let diagnostics = await host.diagnostics()
        if let state = diagnostics.hostState { return state.rawValue }
        return await host.state.rawValue
    }

    private var hasConnectedScene: Bool {
        UIApplication.shared.connectedScenes.contains {
            $0.activationState == .foregroundActive
                || $0.activationState == .foregroundInactive
                || $0.activationState == .background
        }
    }

    private func currentLeaseRemainingMs() -> Int64? {
        guard UIApplication.shared.applicationState != .active else { return nil }
        let remaining = UIApplication.shared.backgroundTimeRemaining
        guard remaining.isFinite, remaining < 1_000_000 else { return nil }
        return Int64((remaining * 1000).rounded())
    }

    private func moveAnchorToVisibleIfPossible() {
        guard let offscreen, offscreen.isHostingAnchor,
              visibleContainer.window != nil,
              phase != "scenario" else { return }
        offscreen.moveAnchor(to: visibleContainer)
        store?.appendEvent(kind: "anchor-moved-to-visible")
    }

    private func startBackgroundSampling() {
        samplerTask?.cancel()
        backgroundSamples = []
        samplingStartedAt = Date()
        samplerTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                let atMs = Date().timeIntervalSince(self.samplingStartedAt) * 1000
                self.backgroundSamples.append(
                    EngineWakeBackgroundSample(atMs: atMs,
                                               remainingMs: self.currentLeaseRemainingMs()))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func stopBackgroundSampling() -> [EngineWakeBackgroundSample] {
        samplerTask?.cancel()
        samplerTask = nil
        return backgroundSamples
    }

    private func installLANListener(port: UInt16) {
        lanListener.onReady = { [weak self] port in
            guard let self else { return }
            self.lanPort = port
            self.store?.appendEvent(kind: "lan-listener-ready", detail: "port=\(port)")
            self.writeState(force: true)
        }
        lanListener.onFailure = { [weak self] message in
            self?.store?.appendEvent(kind: "lan-listener-failed", detail: message)
        }
        lanListener.onRequest = { [weak self] request in
            self?.store?.appendEvent(kind: "lan-request", detail: String(request.prefix(300)))
        }
        lanListener.start(preferredPort: port)
    }

    private func writeState(phase: String? = nil, detail: String? = nil, force: Bool = false) {
        guard let configuration, let store else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastStateWrite) >= 1 else { return }
        lastStateWrite = now
        if let phase { self.phase = phase }
        var state = EngineWakeState(runID: configuration.runID,
                                    deviceClass: EngineWakeDeviceClass.current,
                                    phase: self.phase)
        state.currentScenario = currentScenario
        state.detail = detail ?? statusText
        state.pendingTrigger = pendingTrigger
        state.pendingProbe = pendingProbe
        state.deviceToken = deviceToken
        state.lanPort = lanPort
        store.writeState(state)
    }
}

enum EngineWakePolicy {
    static func decide(scenario: EngineWakeScenarioID, hostState: String,
                       leaseRemainingMs: Int64?, foreground: Bool,
                       residentAudio: Bool) -> String {
        let thresholds = EngineWakeThresholds()
        switch hostState {
        case "running": return "ready"
        case "parked":
            let enough = (leaseRemainingMs ?? 0) >= thresholds.minLeaseForResumeMs
            return foreground || residentAudio || enough ? "resume" : "nativeOnly"
        case "failed": return "needsAttention"
        default:
            let enough = (leaseRemainingMs ?? 0) >= thresholds.minLeaseForColdBootMs
            return foreground || residentAudio || enough ? "boot" : "nativeOnly"
        }
    }

    static func allowsImmediateAction(scenario: EngineWakeScenarioID, hostState: String,
                                      leaseRemainingMs: Int64?, foreground: Bool,
                                      residentAudio: Bool) -> Bool {
        let decision = decide(scenario: scenario, hostState: hostState,
                              leaseRemainingMs: leaseRemainingMs,
                              foreground: foreground, residentAudio: residentAudio)
        return decision == "boot" || decision == "resume" || decision == "ready"
    }
}

private enum EngineWakeRunError: Error, CustomStringConvertible {
    case noStore
    case failed(String)

    var description: String {
        switch self {
        case .noStore: return "no evidence store"
        case .failed(let detail): return detail
        }
    }
}
#endif
