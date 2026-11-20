// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — the app's owner of the phone task queue.
//
// spec/v1/cloud-tasks.md §7–§8. One `CloudTaskCoordinator` for the app, built
// without the engine: it pulls tasks left by the user's other signed-in
// devices, writes them into the external admission journal and acknowledges
// them. It has no timer and never polls. A pass runs when the app becomes
// active, after sign-in, when the switch is turned on, after a task push, and
// once when APNs hands over a new device token (so the address reaches the
// cloud). It never boots the engine: admitted records go to the existing
// dispatch entry, which keeps its own §10.1 eligibility.

import Foundation
import Observation
import PhoneDSH
import ProbeKit
import UIKit

/// The signed-in tono account, read from the session record at the moment of use.
enum CloudTaskAccount {
    /// `user_id` of the stored session record, or nil when signed out, when the
    /// record carries no user id, or when the Keychain cannot be read now.
    static func signedInUserID() async -> String? {
        guard TonoAccountSession.shared.hasSession else { return nil }
        return await Task.detached(priority: .utility) {
            (try? KeychainTonoAccountSessionStore().load())
                .flatMap { $0 }
                .flatMap(TonoAccountProtocol.decodeRecord)?.userID
        }.value
    }

    static func signedInPrincipal() async -> String? {
        ExternalAdmissionRequest.accountPrincipal(userID: await signedInUserID())
    }
}

@MainActor
@Observable
final class CloudTaskCenter {
    static let shared = CloudTaskCenter()

    /// The user's switch (library preference `phone-dsh.cloud-tasks.enabled.v1`; absent = off).
    private(set) var enabled: Bool
    private(set) var signedIn: Bool
    private(set) var statusText: String
    private(set) var busy = false

    @ObservationIgnored private let coordinator: CloudTaskCoordinator
    @ObservationIgnored private let bridge: CloudTaskAdmissionBridge
    @ObservationIgnored private var accountWatch: Task<Void, Never>?
    @ObservationIgnored private var registeredToken: Data?
    /// When the last pull → admit → ack pass finished (`nil`: none this
    /// process). ReadySweep step 3 skips the pull inside
    /// `EngineLaunchThresholds.cloudPullFreshnessMs` of this instant.
    private(set) var lastPullAt: Date?
    /// The background task that keeps this process alive for a push wake. It is
    /// ended only after the engine is parked at the lease deadline.
    @ObservationIgnored private var pushBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    private init() {
        let bridge = CloudTaskAdmissionBridge(
            journal: ChatModel.shared.externalAdmissionJournal,
            signedInUserID: { await CloudTaskAccount.signedInUserID() },
            presence: { target in await ChatModel.shared.cloudTaskTargetPresence(target) })
        self.bridge = bridge
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            .flatMap { (1...32).contains($0.utf8.count) ? $0 : nil } ?? "0"
        coordinator = CloudTaskCoordinator(
            configuration: .init(appVersion: version),
            host: bridge.host(),
            tokens: TonoAccountSession.shared,
            transport: URLSessionCloudTaskTransport(),
            keyStore: KeychainCloudTaskKeyStore())
        enabled = coordinator.isEnabled
        signedIn = TonoAccountSession.shared.hasSession
        statusText = CloudTaskStatusText.describe(
            enabled: coordinator.isEnabled, signedIn: TonoAccountSession.shared.hasSession, status: nil)
    }

    /// Called once at launch. Follows the account: a sign-in runs a pass, a
    /// sign-out (the user's, or one the account service forced) cancels that
    /// account's admitted records.
    func start() {
        guard accountWatch == nil else { return }
        accountWatch = Task { @MainActor [weak self] in
            var previous: Bool?
            for await state in await TonoAccountSession.shared.states() {
                guard let self else { return }
                let nowSignedIn: Bool
                if case .signedIn = state { nowSignedIn = true } else { nowSignedIn = false }
                self.signedIn = nowSignedIn
                // Also at launch: an account that ended while the app was not running.
                await self.bridge.cancelAdmissionsOfSignedOutAccounts()
                self.updatePushRegistration()
                if previous == false, nowSignedIn {
                    await self.run(.signedIn)
                } else {
                    self.refreshStatus(nil)
                }
                previous = nowSignedIn
            }
        }
    }

    // MARK: - Triggers

    func appBecameActive() {
        Task { await run(.appActive) }
    }

    /// The settings switch.
    func setEnabled(_ value: Bool) async {
        busy = true
        defer { busy = false }
        let report = await coordinator.setEnabled(value)
        enabled = coordinator.isEnabled
        updatePushRegistration()
        if value {
            finish(report)
        } else {
            statusText = CloudTaskStatusText.describeTurnedOff(status: report.status)
        }
    }

    /// Before the account signs out, while its token still works: the cloud
    /// forgets this phone (§2). Call ``accountDidSignOut()`` after the session is cleared.
    func accountWillSignOut() async {
        await coordinator.accountWillSignOut()
    }

    func accountDidSignOut() async {
        signedIn = false
        await bridge.cancelAdmissionsOfSignedOutAccounts()
        updatePushRegistration()
        refreshStatus(nil)
    }

    /// §8: one pull → admit → ack pass for a task push; any other payload is not ours.
    ///
    /// After the pass (the durable part, unchanged), a wake lease built from
    /// `beginBackgroundTask` asks the launch orchestrator to boot or resume the
    /// engine (host §10.2). The fetch is completed only after the host is
    /// parked at `deadline − parkMarginMs`; a lease too short for the engine
    /// transition behaves exactly like the pre-wake path and books a
    /// `BGProcessingTask` instead.
    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let report = await coordinator.handleRemoteNotification(userInfo) else { return .noData }
        finish(report)
        let result: UIBackgroundFetchResult
        switch report.status {
        case .ready:
            result = report.pulled > 0 || report.terminalSettled > 0 ? .newData : .noData
        case .disabled, .signedOut:
            result = .noData
        case .unavailable, .deviceLimit, .storeUnavailable, .failed:
            result = .failed
        }
        // A disabled or signed-out device has no work to wake for: keep the
        // pre-wake behaviour (the pass above already did nothing).
        if enabled, signedIn { await orchestratePushWake() }
        return result
    }

    /// One pull pass for the launch orchestrator's ReadySweep step 3. Returns
    /// false when the switch is off or no account is signed in (nothing sent).
    func runWakePull() async -> Bool {
        guard enabled, signedIn else { return false }
        finish(await coordinator.run(.appActive))
        return true
    }

    // MARK: - Push wake lease (host §10.2)

    /// Asks the orchestrator for one `.cloudTaskPush` wake inside the OS window
    /// and parks before it closes. Returns after the park.
    private func orchestratePushWake() async {
        let hostState = ChatModel.shared.engineHostState
        let requiredMs = hostState == .parked
            ? EngineLaunchThresholds.minLeaseForResumeMs
            : EngineLaunchThresholds.minLeaseForColdBootMs
        let remaining = UIApplication.shared.backgroundTimeRemaining
        // A lease too short (or not granted at all) is the pre-wake path: the
        // pass above already did pull → admit → ack, and the engine-free work
        // is left to the next foreground / processing task.
        guard remaining.isFinite, remaining * 1000 >= Double(requiredMs),
              pushBackgroundTask == .invalid else {
            _ = EngineLaunchProcessingTask.submit()
            return
        }
        pushBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "cloud-task-wake") { [weak self] in
            Task { @MainActor in
                await ChatModel.shared.parkForWakeDeadline()
                self?.endPushBackgroundTask()
            }
        }
        guard pushBackgroundTask != .invalid else {
            _ = EngineLaunchProcessingTask.submit()
            return
        }
        let grantedAt = Date()
        let lease = WakeLease(reason: .cloudTaskPush,
                              grantedAtMs: Int64(grantedAt.timeIntervalSince1970 * 1000),
                              deadlineMs: Int64(grantedAt.timeIntervalSince1970 * 1000)
                                  + Int64(min(remaining, 35) * 1000))
        let outcome = await EngineLaunchOrchestrator.shared.wake(.cloudTaskPush, lease: lease)
        // The lease was enough for the decision; a native-only answer has no
        // engine to park, so the window closes right away.
        switch outcome.decision {
        case .ready, .boot, .resume:
            // R16: release the window as soon as the sweep is done; only a
            // running turn may use the rest of it, up to deadline − margin.
            await ChatModel.shared.finishWakeLeaseWindow(deadlineMs: lease.deadlineMs)
        case .nativeOnly:
            _ = EngineLaunchProcessingTask.submit()
        case .deferred, .needsAttention:
            break
        }
        endPushBackgroundTask()
    }

    private func endPushBackgroundTask() {
        guard pushBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(pushBackgroundTask)
        pushBackgroundTask = .invalid
    }

    // MARK: - Push address

    func didRegisterForRemoteNotifications(deviceToken: Data) {
        guard let topic = Bundle.main.bundleIdentifier else { return }
        let changed = registeredToken != deviceToken
        registeredToken = deviceToken
        Task {
            let accepted = await coordinator.setPush(CloudTaskPush(
                environment: Self.apnsEnvironment, topic: topic, deviceToken: deviceToken))
            // The registration body changed: one pass sends the address to the cloud.
            if accepted, changed { await run(.appActive) }
        }
    }

    func didFailToRegisterForRemoteNotifications() {
        registeredToken = nil
        Task { await coordinator.setPush(nil) }
    }

    /// Registers for remote notifications only while the feature is on and an
    /// account is signed in. A background push needs no notification permission,
    /// and none is requested here.
    private func updatePushRegistration() {
        if enabled, signedIn {
            UIApplication.shared.registerForRemoteNotifications()
        } else {
            UIApplication.shared.unregisterForRemoteNotifications()
            registeredToken = nil
            Task { await coordinator.setPush(nil) }
        }
    }

    /// `aps-environment` of the profile this build was signed with; a build
    /// without an embedded profile (simulator, App Store) falls back to the configuration.
    private static let apnsEnvironment: CloudTaskPush.Environment = {
        if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url) {
            let text = String(decoding: data, as: UTF8.self)
            if let key = text.range(of: "<key>aps-environment</key>"),
               let open = text.range(of: "<string>", range: key.upperBound..<text.endIndex),
               let close = text.range(of: "</string>", range: open.upperBound..<text.endIndex) {
                return text[open.upperBound..<close.lowerBound] == "production" ? .production : .development
            }
        }
        #if DEBUG
        return .development
        #else
        return .production
        #endif
    }()

    // MARK: - One pass

    private func run(_ trigger: CloudTaskTrigger) async {
        finish(await coordinator.run(trigger))
    }

    private func finish(_ report: CloudTaskPassReport) {
        lastPullAt = Date()
        refreshStatus(report.status)
        // Admitted records go to the existing dispatch entry; it decides when they run.
        if !report.admitted.isEmpty { ChatModel.shared.scheduleExternalAdmissionPass() }
    }

    private func refreshStatus(_ status: CloudTaskStatus?) {
        enabled = coordinator.isEnabled
        statusText = CloudTaskStatusText.describe(enabled: enabled, signedIn: signedIn, status: status)
    }
}

/// UIKit hands remote-notification registration and background pushes to the
/// application delegate only.
final class ProbeAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Host §10.2 / PLAN §2.3: register the engine-launch BGProcessing task
        // before launch finishes. The handler asks for exactly one
        // `.bgProcessing` wake and parks before completing the OS task.
        EngineLaunchProcessingTask.register(Self.engineWakeRunner(.bgProcessing))
        // §10.3.4: the refresh arm carries the earliest WakeDemand due time
        // when the App is suspended (needs UIBackgroundModes: fetch).
        EngineLaunchRefreshTask.register(Self.engineWakeRunner(.bgAppRefresh))
        return true
    }

    /// One BGTask window → one orchestrator wake with a lease built from the
    /// window, then park before the task completes.
    private static func engineWakeRunner(_ reason: WakeReason) -> EngineLaunchProcessingTask.Runner {
        { window in
            let grantedAtMs = WakeLease.nowMs()
            let deadlineMs = grantedAtMs
                + Int64(max(0, window.deadline.timeIntervalSinceNow) * 1000)
            let lease = WakeLease(reason: reason,
                                  grantedAtMs: grantedAtMs,
                                  deadlineMs: deadlineMs)
            let outcome = await EngineLaunchOrchestrator.shared.wake(reason, lease: lease)
            // R17: do not interrupt a turn the sweep just started; park now
            // only when nothing is running, otherwise at deadline − margin.
            await ChatModel.shared.finishWakeLeaseWindow(deadlineMs: lease.deadlineMs)
            return outcome.decision != .needsAttention
        }
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        CloudTaskCenter.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        CloudTaskCenter.shared.didFailToRegisterForRemoteNotifications()
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            completionHandler(await CloudTaskCenter.shared.handleRemoteNotification(userInfo))
        }
    }
}
