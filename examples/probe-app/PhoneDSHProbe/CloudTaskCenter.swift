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
    @ObservationIgnored private var pushInFlight = false

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

    /// One pull → admit → ack; any remaining eligible fetch time can run a
    /// wake. UIKit's 30 s ceiling includes the pull, and the assertion's
    /// expiration handler can end it sooner.
    func handleRemoteNotification(_ userInfo: [AnyHashable: Any], receivedAtMs: Int64) async -> UIBackgroundFetchResult {
        guard CloudTasks.isTaskPush(userInfo), !pushInFlight else { return .noData }
        pushInFlight = true
        defer { pushInFlight = false }

        let orchestration = EngineLaunchOrchestrator.shared
        let revocation = WakeLease.Revocation()
        let lease = WakeLease(reason: .cloudTaskPush, grantedAtMs: receivedAtMs,
                              deadlineMs: receivedAtMs + 30_000, revocation: revocation)
        // A Task on this actor starts after the assertion is requested below.
        var assertion: UIBackgroundTaskIdentifier = .invalid
        let push = Task { @MainActor in
            await runPush(lease, engineAllowed: assertion != .invalid)
        }
        let cancelPush: @Sendable () -> Void = {
            revocation.revoke()
            push.cancel()
        }
        assertion = UIApplication.shared.beginBackgroundTask(withName: "cloud-task-wake") {
            cancelPush()
            Task { @MainActor in orchestration.cancelWake(lease) }
        }

        let cutoffMs = max(0, lease.remainingMs() - EngineLaunchThresholds.parkMarginMs)
        let cutoff = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(cutoffMs)) } catch { return }
            cancelPush()
            orchestration.cancelWake(lease)
        }
        let result = await push.value
        cutoff.cancel()
        if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) }
        return result
    }

    private func runPush(_ lease: WakeLease, engineAllowed: Bool) async -> UIBackgroundFetchResult {
        let report = await coordinator.run(.push, cancelWithCaller: true)
        finish(report, dispatch: false)
        let result: UIBackgroundFetchResult
        switch report.status {
        case .ready:
            result = report.pulled > 0 || report.terminalSettled > 0 ? .newData : .noData
        case .disabled, .signedOut:
            return .noData
        case .unavailable, .deviceLimit, .storeUnavailable, .failed:
            result = .failed
        }
        guard enabled, signedIn else { return result }
        let requiredMs = ChatModel.shared.engineHostState == .parked
            ? EngineLaunchThresholds.minLeaseForResumeMs
            : EngineLaunchThresholds.minLeaseForColdBootMs
        guard engineAllowed, !Task.isCancelled, lease.remainingMs() >= requiredMs else {
            _ = EngineLaunchProcessingTask.submit()
            return result
        }

        let outcome = await EngineLaunchOrchestrator.shared.wake(.cloudTaskPush, lease: lease)
        if lease.isExpired() {
            await ChatModel.shared.parkForWakeDeadline()
            _ = EngineLaunchProcessingTask.submit()
            return result
        }
        switch outcome.decision {
        case .ready, .boot, .resume:
            await ChatModel.shared.finishWakeLeaseWindow(deadlineMs: lease.deadlineMs)
            if lease.isExpired() { await ChatModel.shared.parkForWakeDeadline() }
        case .nativeOnly:
            _ = EngineLaunchProcessingTask.submit()
        case .deferred, .needsAttention:
            break
        }
        return result
    }

    /// ReadySweep step 3, using the existing durable pull path.
    func runWakePull() async -> Bool {
        guard enabled, signedIn else { return false }
        let report = await coordinator.run(.appActive, cancelWithCaller: true)
        guard !Task.isCancelled else { return false }
        finish(report)
        return report.status == .ready
    }

    /// Expiry-only callbacks may pull and durably admit; dispatch waits for an
    /// eligible engine wake. Cancellation leaves unacknowledged leases retryable.
    func pullForBackgroundTask() async -> Bool {
        guard enabled, signedIn else { return true }
        let report = await coordinator.run(.appActive, cancelWithCaller: true)
        guard !Task.isCancelled else { return false }
        finish(report, dispatch: false)
        return report.status == .ready
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

    private func finish(_ report: CloudTaskPassReport, dispatch: Bool = true) {
        if report.status == .ready { lastPullAt = Date() }
        refreshStatus(report.status)
        // Admitted records go to the existing dispatch entry; it decides when they run.
        if dispatch, !report.admitted.isEmpty { ChatModel.shared.scheduleExternalAdmissionPass() }
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
        // Both callbacks are expiry-only. Neither has a measurable lease.
        EngineLaunchProcessingTask.register {
            await EngineLaunchOrchestrator.shared.runExpiryOnlyWake()
        }
        EngineLaunchRefreshTask.register {
            await EngineLaunchOrchestrator.shared.runExpiryOnlyWake()
        }
        return true
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
        let receivedAtMs = WakeLease.nowMs()
        Task { @MainActor in
            completionHandler(await CloudTaskCenter.shared.handleRemoteNotification(userInfo, receivedAtMs: receivedAtMs))
        }
    }
}
