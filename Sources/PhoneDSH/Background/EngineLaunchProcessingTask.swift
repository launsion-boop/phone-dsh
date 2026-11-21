// SPDX-License-Identifier: MIT
// BGTaskScheduler delivers expiry, but exposes no clock for its window.
import Foundation

/// Synchronizes the runner and OS expiration callback, including expiry before
/// the task handle is installed. Only the winner reports completion.
final class BackgroundWakeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var work: Task<Void, Never>?

    var isOpen: Bool { lock.withLock { !completed } }

    func attach(_ task: Task<Void, Never>) {
        let cancel = lock.withLock {
            guard !completed else { return true }
            work = task
            return false
        }
        if cancel { task.cancel() }
    }

    func finish(expired: Bool, complete: () -> Void) {
        let result: (won: Bool, work: Task<Void, Never>?) = lock.withLock {
            guard !completed else { return (false, nil) }
            completed = true
            defer { work = nil }
            return (true, work)
        }
        guard result.won else { return }
        if expired { result.work?.cancel() }
        complete()
    }
}

#if canImport(UIKit) && canImport(BackgroundTasks) && os(iOS) && !targetEnvironment(macCatalyst)
import BackgroundTasks
import UIKit

private final class BackgroundWakeRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private var attempted = false

    func begin() -> Bool {
        lock.withLock {
            guard !attempted else { return false }
            attempted = true
            return true
        }
    }
}

private func runBackgroundWake(_ task: BGTask, runner: @escaping EngineLaunchProcessingTask.Runner) {
    let gate = BackgroundWakeCompletion()
    task.expirationHandler = {
        gate.finish(expired: true) { task.setTaskCompleted(success: false) }
    }
    gate.attach(Task {
        guard gate.isOpen, !Task.isCancelled else { return }
        let success = await runner()
        gate.finish(expired: false) { task.setTaskCompleted(success: success) }
    })
}

/// Registers and submits the engine-launch `BGProcessingTask`.
public enum EngineLaunchProcessingTask {
    /// Concrete identifier; must equal an entry in
    /// `BGTaskSchedulerPermittedIdentifiers`.
    public static var identifier: String {
        let bundle = Bundle.main.bundleIdentifier ?? "dev.phone-dsh.probe"
        return bundle + ".engine-launch.processing"
    }

    public typealias Runner = @Sendable () async -> Bool
    private static let registration = BackgroundWakeRegistration()

    /// Registers the launch handler. Call before the App finishes launching.
    /// Returns false when the system refuses the identifier (missing plist
    /// entry, wrong OS, already registered).
    @discardableResult public static func register(_ runner: @escaping Runner) -> Bool {
        guard registration.begin() else { return false }
        return BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier, using: nil
        ) { task in
            guard let processing = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            runBackgroundWake(processing, runner: runner)
        }
    }

    /// Books one later processing window. Returns false when the system
    /// refuses the request; a refused booking is not a lost task (the durable
    /// journal/outbox still holds it and the next foreground returns to it).
    @discardableResult
    public static func submit(earliestBeginDate: Date? = nil) -> Bool {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = earliestBeginDate ?? Date().addingTimeInterval(15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            return false
        }
    }

    /// Drops a pending request when the demand ledger no longer has a future
    /// due time (PLAN §2.9 I5: re-project on every ledger change).
    public static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}

/// The `BGAppRefreshTask` arm of the wake projection (PLAN §2.9 channel
/// table): the same window shape as processing, but a refresh task is the
/// system's brief background channel and needs `UIBackgroundModes: fetch`.
public enum EngineLaunchRefreshTask {
    private static let registration = BackgroundWakeRegistration()

    public static var identifier: String {
        let bundle = Bundle.main.bundleIdentifier ?? "dev.phone-dsh.probe"
        return bundle + ".engine-launch.refresh"
    }

    @discardableResult
    public static func register(_ runner: @escaping EngineLaunchProcessingTask.Runner) -> Bool {
        guard registration.begin() else { return false }
        return BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier, using: nil
        ) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            runBackgroundWake(refresh, runner: runner)
        }
    }

    @discardableResult
    public static func submit(earliestBeginDate: Date?) -> Bool {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = earliestBeginDate ?? Date().addingTimeInterval(15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            return false
        }
    }

    public static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}

#else

public enum EngineLaunchProcessingTask {
    public static var identifier: String { "engine-launch.processing" }
    public typealias Runner = @Sendable () async -> Bool

    @discardableResult
    public static func register(_ runner: @escaping Runner) -> Bool { false }

    @discardableResult
    public static func submit(earliestBeginDate: Date? = nil) -> Bool { false }

    public static func cancel() {}
}

public enum EngineLaunchRefreshTask {
    public static var identifier: String { "engine-launch.refresh" }

    @discardableResult
    public static func register(_ runner: @escaping EngineLaunchProcessingTask.Runner) -> Bool { false }

    @discardableResult
    public static func submit(earliestBeginDate: Date? = nil) -> Bool { false }

    public static func cancel() {}
}

#endif
