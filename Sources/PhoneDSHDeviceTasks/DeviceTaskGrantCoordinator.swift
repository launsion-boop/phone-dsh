// SPDX-License-Identifier: MIT
import Foundation

/// Owns the pending start handle for each UI grant. All mutation happens on
/// the main actor, so registration and revocation occur before any suspension.
@MainActor public final class DeviceTaskGrantCoordinator {
    private struct Grant {
        let token: UUID
        let deviceID: String
        let intake: DeviceTaskIntake
        let start: Task<Bool, Error>
    }
    private var grants: [String: Grant] = [:]

    #if DEBUG
    var beforeStart: @Sendable (UUID) async -> Void = { _ in }
    var beforeFinished: @Sendable (UUID) async -> Void = { _ in }
    var afterStop: @Sendable (UUID) async -> Void = { _ in }
    #endif

    public init() {}

    /// Installs the cancellation handle synchronously before returning it.
    public func start(key: String, token: UUID, deviceID: String, intake: DeviceTaskIntake,
                      inbox: any DeviceTaskInbox,
                      onStopped: @escaping @Sendable () async -> Void = {},
                      next: @escaping DeviceTaskIntake.Next) throws -> Task<Bool, Error> {
        guard grants[key] == nil else { throw DeviceTaskError.deviceBusy }
        #if DEBUG
        let startHook = beforeStart, finishedHook = beforeFinished
        #endif
        let task = Task { [weak self] in
            #if DEBUG
            await startHook(token)
            #endif
            return try await intake.start(deviceID: deviceID, token: token, authorized: true, inbox: inbox,
                                   onStopped: { [weak self] in
                #if DEBUG
                await finishedHook(token)
                #endif
                await self?.finished(key: key, token: token, callback: onStopped)
            }, next: next)
        }
        grants[key] = Grant(token: token, deviceID: deviceID, intake: intake, start: task)
        return task
    }

    /// Invalidates and cancels synchronously; the returned task joins the
    /// pending start and stops only its own generation. Callers can invalidate
    /// every grant before awaiting any returned task.
    public func invalidate(key: String) -> Task<Void, Never>? {
        guard let grant = grants.removeValue(forKey: key) else { return nil }
        grant.start.cancel()
        #if DEBUG
        let stopHook = afterStop
        #endif
        return Task {
            _ = await grant.start.result
            await grant.intake.stop(deviceID: grant.deviceID, token: grant.token)
            #if DEBUG
            await stopHook(grant.token)
            #endif
        }
    }

    /// An asynchronous connection check may return after its grant has been
    /// replaced. Perform the invalidation synchronously only for its owner.
    public func checkConnection(key: String, token: UUID,
                                check: () async throws -> Bool,
                                onDisconnected: () -> Void) async {
        let connected: Bool
        do { connected = try await check() } catch { connected = false }
        guard grants[key]?.token == token else { return }
        if !connected { onDisconnected() }
    }

    private func finished(key: String, token: UUID,
                          callback: @escaping @Sendable () async -> Void) async {
        guard grants[key]?.token == token else { return }
        grants.removeValue(forKey: key)
        await callback()
    }
}
