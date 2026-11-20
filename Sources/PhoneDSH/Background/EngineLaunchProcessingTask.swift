// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — the `BGProcessingTask` window used when a wake's lease
// was too short to boot the engine (PLAN §2.3, host §10.2).
//
// The App submits one request after such a wake; the system later launches the
// App in the background and hands over a processing window. This file owns the
// BackgroundTasks details only. The runner (the App) decides what to do with
// the window — it asks `EngineLaunchOrchestrator` for one `.bgProcessing` wake
// with a lease built from this window — and this wrapper completes the OS task
// exactly once.
//
// The Info.plist `BGTaskSchedulerPermittedIdentifiers` must list the concrete
// identifier. NOT_VERIFIED on a device: scheduling and entitlement behaviour.

import Foundation

#if canImport(UIKit) && canImport(BackgroundTasks) && os(iOS) && !targetEnvironment(macCatalyst)
import BackgroundTasks
import UIKit

/// One `BGProcessingTask` execution window.
public struct EngineLaunchProcessingWindow: Sendable {
    /// When the window opened.
    public let grantedAt: Date
    /// Conservative lease deadline for this window. The OS expiry callback may
    /// arrive earlier; ``isExpired`` reports that.
    public let deadline: Date
    /// True once the OS asked the task to finish.
    public let isExpired: @Sendable () -> Bool
}

/// Registers and submits the engine-launch `BGProcessingTask`.
public enum EngineLaunchProcessingTask {
    /// Concrete identifier; must equal an entry in
    /// `BGTaskSchedulerPermittedIdentifiers`.
    public static var identifier: String {
        let bundle = Bundle.main.bundleIdentifier ?? "dev.phone-dsh.probe"
        return bundle + ".engine-launch.processing"
    }

    /// Conservative window assumed when the system does not reveal its own
    /// budget up front. The freeze only needs a lease large enough to clear
    /// the cold-boot threshold; the expiry callback shortens it.
    public static let assumedWindowSeconds: TimeInterval = 25

    /// Runs one window. Returns whether the wake should be reported as success.
    public typealias Runner = @Sendable (EngineLaunchProcessingWindow) async -> Bool

    private static let state = ProcessingState()

    /// Registers the launch handler. Call before the App finishes launching.
    /// Returns false when the system refuses the identifier (missing plist
    /// entry, wrong OS, already registered).
    @discardableResult public static func register(_ runner: @escaping Runner) -> Bool {
        state.setRunner(runner)
        guard state.markRegistered() else { return false }
        return BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier, using: nil
        ) { task in
            guard let processing = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            run(processing)
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

    private static func run(_ task: BGProcessingTask) {
        guard let runner = state.runner() else {
            task.setTaskCompleted(success: false)
            return
        }
        let gate = CompletionGate()
        let grantedAt = Date()
        let window = EngineLaunchProcessingWindow(
            grantedAt: grantedAt,
            deadline: grantedAt.addingTimeInterval(assumedWindowSeconds),
            isExpired: { gate.isExpired })
        task.expirationHandler = { gate.finish(task, success: false) }
        Task {
            let success = await runner(window)
            gate.finish(task, success: success)
        }
    }
}

/// Holder for the runner and the registration flag.
private final class ProcessingState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRunner: EngineLaunchProcessingTask.Runner?
    private var registered = false

    func setRunner(_ runner: @escaping EngineLaunchProcessingTask.Runner) {
        lock.withLock { storedRunner = runner }
    }

    func runner() -> EngineLaunchProcessingTask.Runner? {
        lock.withLock { storedRunner }
    }

    func markRegistered() -> Bool {
        lock.withLock {
            if registered { return false }
            registered = true
            return true
        }
    }
}

/// Completes the OS task at most once, from either the runner or the expiry
/// handler.
private final class CompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var expired = false

    var isExpired: Bool {
        lock.withLock { expired }
    }

    func finish(_ task: BGProcessingTask, success: Bool) {
        let shouldComplete: Bool = lock.withLock {
            expired = true
            if completed { return false }
            completed = true
            return true
        }
        if shouldComplete { task.setTaskCompleted(success: success) }
    }
}

/// The `BGAppRefreshTask` arm of the wake projection (PLAN §2.9 channel
/// table): the same window shape as processing, but a refresh task is the
/// system's normal "run briefly in the background" channel and needs
/// `UIBackgroundModes: fetch`. Register and submit exactly like the processing
/// arm; the App's runner asks for one `.scheduledDemand` wake.
public enum EngineLaunchRefreshTask {
    public static var identifier: String {
        let bundle = Bundle.main.bundleIdentifier ?? "dev.phone-dsh.probe"
        return bundle + ".engine-launch.refresh"
    }

    private static let state = RefreshState()

    @discardableResult
    public static func register(_ runner: @escaping EngineLaunchProcessingTask.Runner) -> Bool {
        state.setRunner(runner)
        guard state.markRegistered() else { return false }
        return BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier, using: nil
        ) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            run(refresh)
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

    private static func run(_ task: BGAppRefreshTask) {
        guard let runner = state.runner() else {
            task.setTaskCompleted(success: false)
            return
        }
        let gate = RefreshCompletionGate()
        let grantedAt = Date()
        let window = EngineLaunchProcessingWindow(
            grantedAt: grantedAt,
            deadline: grantedAt.addingTimeInterval(EngineLaunchProcessingTask.assumedWindowSeconds),
            isExpired: { gate.isExpired })
        task.expirationHandler = { gate.finish(task, success: false) }
        Task {
            let success = await runner(window)
            gate.finish(task, success: success)
        }
    }
}

private final class RefreshState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRunner: EngineLaunchProcessingTask.Runner?
    private var registered = false

    func setRunner(_ runner: @escaping EngineLaunchProcessingTask.Runner) {
        lock.withLock { storedRunner = runner }
    }

    func runner() -> EngineLaunchProcessingTask.Runner? {
        lock.withLock { storedRunner }
    }

    func markRegistered() -> Bool {
        lock.withLock {
            if registered { return false }
            registered = true
            return true
        }
    }
}

private final class RefreshCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var expired = false

    var isExpired: Bool { lock.withLock { expired } }

    func finish(_ task: BGAppRefreshTask, success: Bool) {
        let shouldComplete: Bool = lock.withLock {
            expired = true
            if completed { return false }
            completed = true
            return true
        }
        if shouldComplete { task.setTaskCompleted(success: success) }
    }
}

#else

/// macOS / no BackgroundTasks: the request is never booked.
public struct EngineLaunchProcessingWindow: Sendable {
    public let grantedAt: Date
    public let deadline: Date
    public let isExpired: @Sendable () -> Bool
}

public enum EngineLaunchProcessingTask {
    public static var identifier: String { "engine-launch.processing" }
    public static let assumedWindowSeconds: TimeInterval = 25
    public typealias Runner = @Sendable (EngineLaunchProcessingWindow) async -> Bool

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
