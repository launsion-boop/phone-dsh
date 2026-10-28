// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: iOS 26 continued processing.
//
// PLAN W6-BACKGROUND. This file is compiled only for iOS with the
// BackgroundTasks framework. `BGContinuedProcessingTask` is used *only* as the
// drain window: the launch handler does no tool work, no Worker boot and no
// model request. It attaches the launched task to the window, reports progress
// while the ordinary controller drain runs, and completes it when the drain
// ends. If the App is launched with a stale handler the task completes
// immediately instead of taking over execution.
//
// NOT_VERIFIED: device/simulator scheduling, live-activity UI and the
// Info.plist `BGTaskSchedulerPermittedIdentifiers` entry. The identifier family
// is `<bundle id>.continued-processing.drain.*`; the App must list it.

#if canImport(UIKit) && canImport(BackgroundTasks) && os(iOS) && !targetEnvironment(macCatalyst)

import BackgroundTasks
import Foundation

/// One submitted iOS 26 continued-processing task acting as the drain window.
@available(iOS 26.0, *)
final class ContinuedProcessingDrainWindow: @unchecked Sendable {
    /// Wildcard identifier family registered with `BGTaskScheduler`.
    static let identifierPrefix =
        (Bundle.main.bundleIdentifier ?? "local.phone-dsh.phone-dsh")
        + ".continued-processing.drain.*"

    private enum WindowError: Error {
        case registrationRefused
    }

    /// Registration is process-global and must run at most once; registering
    /// the same identifier twice makes iOS terminate the App.
    private static let registration: Result<Void, WindowError> = {
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: ContinuedProcessingDrainWindow.identifierPrefix,
            using: nil) { task in
                guard let continued = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                ContinuedProcessingDrainWindow.registry.deliver(continued)
            }
        return registered ? .success(()) : .failure(.registrationRefused)
    }()

    private static let registry = Registry()

    private let lock = NSLock()
    /// Full concrete identifier submitted to the scheduler.
    let identifier: String
    private let expiration: @Sendable () -> Void
    private var task: BGContinuedProcessingTask?
    private var fraction: Double = 0
    private var finished = false
    private var completedSuccessfully = false

    private init(identifier: String, expiration: @escaping @Sendable () -> Void) {
        self.identifier = identifier
        self.expiration = expiration
    }

    /// Submits one continued-processing request.
    ///
    /// - Returns: `nil` when the framework refuses registration/submission so
    ///   the scheduler can fall back to `beginBackgroundTask`.
    static func begin(name: String,
                      expiration: @escaping @Sendable () -> Void)
        -> ContinuedProcessingDrainWindow? {
        guard case .success = registration else { return nil }
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let identifier = String(identifierPrefix.dropLast()) + suffix
        let window = ContinuedProcessingDrainWindow(identifier: identifier,
                                                    expiration: expiration)
        registry.add(window)
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Draining task",
            subtitle: name)
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            registry.forget(window)
            return nil
        }
        return window
    }

    /// Reports the drain window progress. iOS requires this for a continued
    /// processing task; it is window progress, not tool/work progress.
    func report(progress fraction: Double) {
        let clamped = min(1, max(0, fraction))
        let launched: BGContinuedProcessingTask? = lock.withLock {
            self.fraction = clamped
            guard let current = self.task, !finished else { return nil }
            current.progress.totalUnitCount = 100
            current.progress.completedUnitCount = Int64(clamped * 100)
            return current
        }
        _ = launched
    }

    /// Attaches the launched task; a late launch for an already closed window
    /// completes successfully and does nothing else.
    fileprivate func attach(_ launched: BGContinuedProcessingTask) {
        let result: (alreadyFinished: Bool, success: Bool) = lock.withLock {
            task = launched
            return (finished, completedSuccessfully)
        }
        if result.alreadyFinished {
            launched.setTaskCompleted(success: result.success)
            return
        }
        launched.progress.totalUnitCount = 100
        launched.progress.completedUnitCount = Int64(min(1, max(0, fraction)) * 100)
        launched.expirationHandler = { [expiration] in
            // The drainer forces the controller deadline and closes the window;
            // this handler never continues work on its own.
            expiration()
        }
    }

    /// Completes the launched task (if any) and forgets the window.
    func finish(success: Bool) {
        let launched: BGContinuedProcessingTask? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            completedSuccessfully = success
            if let task {
                task.progress.completedUnitCount = task.progress.totalUnitCount
            }
            return task
        }
        Self.registry.forget(self)
        guard let launched else { return }
        launched.expirationHandler = nil
        launched.setTaskCompleted(success: success)
    }

    /// Identifier → window lookup for the launch handler.
    fileprivate final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var windows: [String: ContinuedProcessingDrainWindow] = [:]

        func add(_ window: ContinuedProcessingDrainWindow) {
            lock.withLock { windows[window.identifier] = window }
        }

        func forget(_ window: ContinuedProcessingDrainWindow) {
            lock.withLock { windows.removeValue(forKey: window.identifier) }
        }

        func deliver(_ task: BGContinuedProcessingTask) {
            let window: ContinuedProcessingDrainWindow? = lock.withLock {
                windows[task.identifier]
            }
            guard let window else {
                // No drain is waiting (stale launch after the App resumed):
                // complete the window without executing anything.
                task.setTaskCompleted(success: true)
                return
            }
            window.attach(task)
        }
    }
}

#endif
