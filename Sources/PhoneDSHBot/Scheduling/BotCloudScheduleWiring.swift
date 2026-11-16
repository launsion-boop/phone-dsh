// SPDX-License-Identifier: MIT

import Foundation

/// Production adapter between an explicit user action (Bot information page
/// toggle) and the frozen cloud-scheduling permission.
///
/// The UI never forges an authorization reference. Enabling writes one durable
/// `ui.system_event` owned by the user's tap and uses its committed sequence as
/// `record://event/<seq>`; disabling clears the permission and lets the client
/// delete the cloud row. The coordinator is the only place the App has to call;
/// the composition keeps owning construction/lifecycle.
public actor BotCloudScheduleWiring {
    private let store: SQLiteDomainStore
    private let machine: RoutineMachine
    private let client: CloudScheduleClient
    private let botID: String
    private let now: @Sendable () -> Int64

    public init(store: SQLiteDomainStore, machine: RoutineMachine,
                client: CloudScheduleClient, botID: String,
                now: @escaping @Sendable () -> Int64 = {
                    Int64(Date().timeIntervalSince1970 * 1000)
                }) {
        self.store = store
        self.machine = machine
        self.client = client
        self.botID = botID
        self.now = now
    }

    /// One explicit user decision. Enabling requires a durable user-action
    /// event; disabling records the revocation and removes the cloud row on the
    /// next sync. Already-matching state is a no-op, so a double tap cannot
    /// create duplicate audit events.
    public func setRoutineCloudSchedule(routineID: String, enabled: Bool) async throws {
        guard let routine = try await machine.get(botId: botID, routineId: routineID) else {
            throw RoutineError.routineNotFound(routineID)
        }
        let currentlyEnabled = routine.cloudSchedule?.enabled == true
        if currentlyEnabled == enabled {
            await client.noteSchedulesChanged()
            return
        }
        let timestamp = now()
        let action = enabled ? "cloud-schedule-enabled" : "cloud-schedule-disabled"
        let eventID = "ui:\(action):\(safe(routineID)):\(timestamp)"
        let event = BotEvent(
            type: "ui.system_event", eventId: eventID, time: timestamp,
            origin: .local(source: "user"), traceId: "trace:\(eventID)",
            principal: BotPrincipal(botId: botID, sessionId: nil, kind: "chat"),
            causationId: nil, correlationId: routineID,
            data: .object([
                "event": .string(action),
                "routineId": .string(routineID),
                "enabled": .bool(enabled),
            ]))
        let commitSeq = try await store.append(event)
        if enabled {
            _ = try await machine.setCloudSchedule(
                botId: botID, routineId: routineID, enabled: true,
                authorizationRef: "record://event/\(commitSeq)", now: timestamp)
        } else {
            _ = try await machine.setCloudSchedule(
                botId: botID, routineId: routineID, enabled: false, now: timestamp)
        }
        await client.noteSchedulesChanged()
    }

    /// Call before deleting the Bot: its routines are erased locally, so this
    /// is the last chance to delete the cloud schedule rows.
    @discardableResult
    public func purgeCloudSchedules() async -> Int {
        await client.purgeCloudSchedules()
    }

    /// Call after a successful account token refresh; the client stops polling
    /// on 401/403 until then.
    public func noteAuthenticationRefreshed() async {
        await client.noteAuthenticationRefreshed()
    }

    private func safe(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.prefix(80))
    }
}

/// Composes the routine-local consent check with the platform services the App
/// already has (N source consent/generation, F suppression). A nil closure is
/// explicit: those services are not wired yet, not a silent allow-all.
public struct ComposedCloudScheduleAuthorizer: CloudScheduleAuthorizing {
    public typealias AdditionalCheck = @Sendable (Routine) async -> CloudScheduleReason?

    private let base: any CloudScheduleAuthorizing
    private let additional: AdditionalCheck?

    public init(base: any CloudScheduleAuthorizing = CloudScheduleAuthorizer(),
                additional: AdditionalCheck? = nil) {
        self.base = base
        self.additional = additional
    }

    public func refusal(for routine: Routine) async -> CloudScheduleReason? {
        if let refusal = await base.refusal(for: routine) { return refusal }
        guard let additional else { return nil }
        return await additional(routine)
    }
}
