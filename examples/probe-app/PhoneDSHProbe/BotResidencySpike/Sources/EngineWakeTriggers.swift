// SPDX-License-Identifier: MIT
//
// Engine-first-launch wake measurement: trigger bus, BGProcessing task and the
// UIKit delegate that receives a background push. Spike-only.
//
// The spike records a wake event; it does not run the production cloud-task
// pull/admit/ack path and it never synthesises an APNs push on a physical
// device. A simulator run may inject one with `xcrun simctl push` purely to
// exercise this code, and is reported as NOT_RUN.

#if BOT_RESIDENCY_SPIKE

import BackgroundTasks
import ProbeKit
import UIKit

/// Holds the system background-time assertion for a push wake, mirroring the
/// production `beginBackgroundTask` around the cloud-task pass.
@MainActor
final class EngineWakeBackgroundAssertion {
    static let shared = EngineWakeBackgroundAssertion()
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    func begin(_ name: String) {
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            Task { @MainActor in
                EngineWakeBackgroundAssertion.shared.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

enum EngineWakeTrigger {
    case push(payload: [AnyHashable: Any])
    case bgProcessing
    case boardWake
    case lan(scenario: String)

    var name: String {
        switch self {
        case .push: return "apns-content-available"
        case .bgProcessing: return "bgprocessing"
        case .boardWake: return "board-audio"
        case .lan: return "lan-http"
        }
    }
}

@MainActor
final class EngineWakeTriggerBus {
    static let shared = EngineWakeTriggerBus()

    private var waiters: [UUID: CheckedContinuation<EngineWakeTrigger?, Never>] = [:]
    private var buffered: EngineWakeTrigger?

    private init() {}

    func deliver(_ trigger: EngineWakeTrigger) {
        if !waiters.isEmpty {
            let id = waiters.keys.first!
            waiters.removeValue(forKey: id)?.resume(returning: trigger)
        } else {
            buffered = trigger
        }
    }

    func wait(timeout: TimeInterval) async -> EngineWakeTrigger? {
        if let buffered {
            self.buffered = nil
            return buffered
        }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters[id] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self else { return }
                self.waiters.removeValue(forKey: id)?.resume(returning: nil)
            }
        }
    }
}

/// Completes a BGTask exactly once even when the expiration handler races the
/// runner's own completion.
final class EngineWakeTaskCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func finish(_ task: BGTask, success: Bool) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        task.setTaskCompleted(success: success)
    }
}

enum EngineWakeBGTask {
    static var identifier: String {
        (Bundle.main.bundleIdentifier ?? "dev.phone-dsh.bot-residency-spike")
            + ".engine-wake.bgprocessing"
    }

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let completion = EngineWakeTaskCompletion()
            task.expirationHandler = {
                completion.finish(task, success: false)
            }
            Task { @MainActor in
                EngineWakeTriggerBus.shared.deliver(.bgProcessing)
                // Give the runner enough time to boot and record the attempt.
                // The handler does not extend this beyond the OS grant.
                try? await Task.sleep(for: .seconds(25))
                completion.finish(task, success: true)
            }
        }
    }

    static func submit(earliestBeginDate: Date = Date(timeIntervalSinceNow: 60)) {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = earliestBeginDate
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NSLog("engine-wake BGProcessingTask submit failed: %@", String(describing: error))
        }
    }
}

enum EngineWakeMode {
    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--mode"), index + 1 < arguments.count,
           arguments[index + 1] == "engine-wake" {
            return true
        }
        // A background push relaunch does not repeat the devicectl/simctl
        // arguments; the armed configuration written by the first launch does.
        return EngineWakeArmedStore.exists()
    }

    static var isArmOnly: Bool {
        ProcessInfo.processInfo.arguments.contains("--arm-only")
    }
}

final class EngineWakeAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                     [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        EngineWakeBGTask.register()
        guard EngineWakeMode.isEnabled else { return true }
        Task { @MainActor in
            EngineWakeRunner.shared.startFromLaunch()
        }
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            EngineWakeRunner.shared.recordDeviceToken(token)
        }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in
            EngineWakeRunner.shared.recordDeviceTokenError(String(describing: error))
        }
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler:
                     @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            EngineWakeBackgroundAssertion.shared.begin("engine-wake-push")
            EngineWakeTriggerBus.shared.deliver(.push(payload: userInfo))
            completionHandler(.newData)
        }
    }
}
#endif
