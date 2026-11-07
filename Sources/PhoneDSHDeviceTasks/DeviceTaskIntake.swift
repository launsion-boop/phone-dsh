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

    public init(executor: DeviceTaskExecutor) { self.executor = executor }

    /// Starts only after an explicit, connection-scoped grant. Disconnects or
    /// malformed input end intake; callers may request a new grant later.
    @discardableResult
    public func start(deviceID: String, authorized: Bool, inbox: any DeviceTaskInbox,
                      onStopped: @escaping @Sendable () async -> Void = {},
                      next: @escaping Next) throws -> Bool {
        guard authorized else { throw DeviceTaskError.unauthorized }
        guard jobs[deviceID] == nil else { return false }
        let token = UUID()
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
            self.finished(deviceID: deviceID, token: token)
            await onStopped()
        }
        jobs[deviceID] = Job(token: token, task: task)
        return true
    }

    public func stop(deviceID: String) async {
        guard let job = jobs.removeValue(forKey: deviceID) else { return }
        job.task.cancel()
        await job.task.value
    }

    public func stopAll() async {
        let active = jobs.values.map(\.task)
        jobs.removeAll()
        for job in active { job.cancel() }
        for job in active { await job.value }
    }

    public func isRunning(deviceID: String) -> Bool { jobs[deviceID] != nil }

    private func finished(deviceID: String, token: UUID) {
        if jobs[deviceID]?.token == token { jobs.removeValue(forKey: deviceID) }
    }
}
