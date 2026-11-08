// SPDX-License-Identifier: MIT
import Foundation

/// Foreground connection-scoped loops. The caller must revoke the grant and
/// stop the loop when its connection, credential, or app lifecycle changes.
public actor DeviceTaskIntake {
    public typealias Next = @Sendable () async throws -> DeviceTask?
    private struct Job {
        let token: UUID
        let task: Task<Void, Never>
    }
    private let executor: DeviceTaskExecutor
    private var jobs: [String: Job] = [:]
    #if DEBUG
    var testAfterNotification: @Sendable (UUID) async -> Void = { _ in }
    func setNotificationTestHook(_ hook: @escaping @Sendable (UUID) async -> Void) { testAfterNotification = hook }
    #endif

    public init(executor: DeviceTaskExecutor) { self.executor = executor }

    /// Starts only after an explicit, connection-scoped grant. Disconnects or
    /// malformed input end intake; callers may request a new grant later.
    @discardableResult
    public func start(deviceID: String, authorized: Bool, inbox: any DeviceTaskInbox,
                      onStopped: @escaping @Sendable () async -> Void = {},
                      next: @escaping Next) throws -> Bool {
        try start(deviceID: deviceID, token: UUID(), authorized: authorized, inbox: inbox,
                  onStopped: onStopped, next: next)
    }

    /// Starts a specifically identified grant generation. A cancelled start
    /// cannot install a job even if its actor delivery was delayed.
    @discardableResult
    public func start(deviceID: String, token: UUID, authorized: Bool, inbox: any DeviceTaskInbox,
                      onStopped: @escaping @Sendable () async -> Void = {},
                      next: @escaping Next) throws -> Bool {
        guard authorized else { throw DeviceTaskError.unauthorized }
        try Task.checkCancellation()
        guard jobs[deviceID] == nil else { return false }
        let task = Task { [executor] in
            do {
                while !Task.isCancelled {
                    let received = try await next()
                    try Task.checkCancellation()
                    if let received {
                        // Keep the same durable task across a lost accept or
                        // terminal reply. The executor reuses the recorded
                        // Link request or re-sends only an idempotent LAN
                        // receipt; it never replays the DSH turn.
                        while true {
                            do {
                                try await executor.process(deviceID: deviceID, task: received, authorized: true, inbox: inbox)
                                break
                            } catch is CancellationError { throw CancellationError() }
                            catch let error as DeviceTaskError { throw error }
                            catch let error as LANDeviceTaskInboxError where error != .unavailable { throw error }
                            catch { try await Task.sleep(for: .seconds(1)) }
                        }
                    } else {
                        try await Task.sleep(for: .seconds(1))
                    }
                }
            } catch { /* A disconnected, revoked or invalid peer must be reauthorized. */ }
        }
        jobs[deviceID] = Job(token: token, task: task)
        #if DEBUG
        let notificationHook = testAfterNotification
        #endif
        // Notification is not part of the worker join: callbacks may request
        // stop on this or another job without creating a cycle.
        Task {
            await task.value
            self.finished(deviceID: deviceID, token: token)
            await onStopped()
            #if DEBUG
            await notificationHook(token)
            #endif
        }
        return true
    }

    public func stop(deviceID: String) async {
        guard let job = jobs[deviceID] else { return }
        job.task.cancel()
        await job.task.value
        finished(deviceID: deviceID, token: job.token)
    }

    /// Revokes only the job installed by this exact generation.
    public func stop(deviceID: String, token: UUID) async {
        guard let job = jobs[deviceID], job.token == token else { return }
        job.task.cancel()
        await job.task.value
        finished(deviceID: deviceID, token: token)
    }

    public func stopAll() async {
        let active = jobs.map { (deviceID: $0.key, job: $0.value) }
        for entry in active { entry.job.task.cancel() }
        for entry in active {
            await entry.job.task.value
            finished(deviceID: entry.deviceID, token: entry.job.token)
        }
    }

    public func isRunning(deviceID: String) -> Bool { jobs[deviceID] != nil }

    func isRunning(deviceID: String, token: UUID) -> Bool { jobs[deviceID]?.token == token }

    private func finished(deviceID: String, token: UUID) {
        if jobs[deviceID]?.token == token { jobs.removeValue(forKey: deviceID) }
    }
}
