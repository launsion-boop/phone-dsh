// SPDX-License-Identifier: MIT

import Foundation
import ProbeKit

@MainActor
final class DSHScheduleAdapter: PersonalScheduleProviding {
    private struct Owner: Codable, Equatable {
        let principal: String
        let accountScope: String?
    }

    private let model: DSHManagementModel
    private let defaults: UserDefaults
    private let boundPrincipal: String?
    private let boundAccountScope: String?
    private let ownershipKey = "personalAgent.scheduleOwners.v1"

    init(model: DSHManagementModel, sessionID: @escaping () -> String = { "" },
         ownershipDefaults: UserDefaults = .standard, boundPrincipal: String? = nil,
         boundAccountScope: String? = nil) {
        self.model = model
        self.defaults = ownershipDefaults
        self.boundPrincipal = boundPrincipal
        self.boundAccountScope = boundAccountScope
    }

    func listSchedules(principal: String, accountScope: String?) async throws -> [PersonalSchedule] {
        try requireScope(principal: principal, accountScope: accountScope)
        await model.refreshAutomations()
        let owners = try readOwners()
        return try model.scheduleRecords.compactMap { managed in
            guard owners[managed.id] == Owner(principal: principal, accountScope: accountScope) else { return nil }
            return try schedule(managed)
        }
    }

    func createSchedule(_ request: PersonalScheduleCreateRequest) async throws -> PersonalSchedule {
        try requireScope(principal: request.principal, accountScope: request.accountScope)
        guard case .after(let seconds) = request.rule else {
            throw LocalCapabilityError.unavailable("The current DSH schedule adapter supports after(seconds) only")
        }
        let existing = try await listSchedules(principal: request.principal, accountScope: request.accountScope)
        if let duplicate = existing.first(where: {
            $0.sessionID == request.sessionID && $0.title == request.title &&
                $0.prompt == request.prompt && $0.rule == request.rule && $0.acceptsDuplicate
        }) {
            return duplicate
        }
        let beforeIDs = Set(model.scheduleRecords.map(\.id))
        let created = await model.createSchedule(sessionID: request.sessionID, title: request.title,
                                                 prompt: request.prompt, afterSeconds: seconds)
        await model.refreshAutomations()
        let candidates = try model.scheduleRecords.compactMap { managed -> ManagedSchedule? in
            guard managed.sessionID == request.sessionID, managed.title == request.title,
                  managed.prompt == request.prompt else { return nil }
            return try rule(managed) == request.rule ? managed : nil
        }
        if let managed = candidates.first(where: { !beforeIDs.contains($0.id) }) ??
            (created ? candidates.first : nil) {
            try saveOwner(Owner(principal: request.principal, accountScope: request.accountScope), for: managed.id)
            return try schedule(managed)
        }
        throw LocalCapabilityError.persistenceFailed(model.error ??
            "DSH did not confirm the schedule; it was not created again automatically")
    }

    func updateSchedule(_ request: PersonalScheduleUpdateRequest) async throws -> PersonalSchedule {
        if let rule = request.rule, rule != request.current.rule {
            throw LocalCapabilityError.unavailable("Changing schedule timing is not supported by this adapter")
        }
        let scoped = try await listSchedules(principal: request.principal, accountScope: request.accountScope)
        guard scoped.contains(where: { $0.id == request.current.id }),
              let managed = model.scheduleRecords.first(where: { $0.id == request.current.id }) else {
            throw LocalCapabilityError.notFound("Schedule not found in the current principal/account scope")
        }
        let updated = await model.updateSchedule(managed, title: request.title ?? request.current.title,
                                                 prompt: request.prompt ?? request.current.prompt)
        guard updated else {
            throw LocalCapabilityError.persistenceFailed(model.error ?? "DSH schedule update failed")
        }
        let current = try await listSchedules(principal: request.principal, accountScope: request.accountScope)
        guard let schedule = current.first(where: { $0.id == request.current.id }) else {
            throw LocalCapabilityError.verificationFailed("The updated schedule was not present in the scoped DSH catalog")
        }
        return schedule
    }

    func deleteSchedule(_ request: PersonalScheduleDeleteRequest) async throws -> PersonalScheduleDeleteResult {
        let scoped = try await listSchedules(principal: request.principal, accountScope: request.accountScope)
        guard scoped.contains(where: { $0.id == request.current.id }),
              let managed = model.scheduleRecords.first(where: { $0.id == request.current.id }) else {
            throw LocalCapabilityError.notFound("Schedule not found in the current principal/account scope")
        }
        await model.deleteSchedule(managed)
        if let error = model.error {
            throw LocalCapabilityError.persistenceFailed(error)
        }
        return PersonalScheduleDeleteResult(id: request.current.id, cancelled: true, status: "cancelled")
    }

    private func requireScope(principal: String, accountScope: String?) throws {
        if let boundPrincipal, boundPrincipal != principal {
            throw LocalCapabilityError.unavailable("The scheduler is bound to a different principal")
        }
        if let boundAccountScope, boundAccountScope != accountScope {
            throw LocalCapabilityError.unavailable("The scheduler is bound to a different account")
        }
    }

    private func readOwners() throws -> [String: Owner] {
        guard let data = defaults.data(forKey: ownershipKey) else { return [:] }
        do {
            return try JSONDecoder().decode([String: Owner].self, from: data)
        } catch {
            throw LocalCapabilityError.persistenceFailed("Schedule ownership metadata is unreadable; catalog access is blocked")
        }
    }

    private func saveOwner(_ owner: Owner, for id: String) throws {
        var owners = try readOwners()
        if let existing = owners[id], existing != owner {
            throw LocalCapabilityError.persistenceFailed("Schedule ID is already owned by another scope")
        }
        owners[id] = owner
        let data = try JSONEncoder().encode(owners)
        defaults.set(data, forKey: ownershipKey)
        guard defaults.synchronize() else {
            throw LocalCapabilityError.persistenceFailed("Schedule ownership metadata was not persisted")
        }
    }

    private func schedule(_ managed: ManagedSchedule) throws -> PersonalSchedule {
        PersonalSchedule(id: managed.id, sessionID: managed.sessionID, title: managed.title,
                         prompt: managed.prompt, rule: try rule(managed), status: managed.status,
                         nextRunAt: Self.date(managed.scheduledAt), nextRunStatus: managed.status,
                         latestDeliveryAt: managed.latestDeliveryAt.flatMap(Self.date))
    }

    private func rule(_ managed: ManagedSchedule) throws -> PersonalScheduleRule {
        let record = managed.expectedRecord
        func requiredString(_ key: String) throws -> String {
            guard let value = record[key]?.stringValue, !value.isEmpty else {
                throw LocalCapabilityError.verificationFailed("DSH schedule is missing \(key)")
            }
            return value
        }
        func requiredInt(_ key: String) throws -> Int {
            guard let value = record[key]?.intValue, value > 0 else {
                throw LocalCapabilityError.verificationFailed("DSH schedule is missing \(key)")
            }
            return value
        }
        switch managed.kind {
        case "after": return .after(seconds: try requiredInt("afterSeconds"))
        case "at":
            guard let date = Self.date(try requiredString("scheduledAt")) else {
                throw LocalCapabilityError.verificationFailed("DSH schedule has an invalid scheduledAt value")
            }
            return .at(date)
        case "every": return .every(seconds: try requiredInt("everySeconds"))
        case "daily": return .daily(time: try requiredString("time"), timeZone: try requiredString("timeZone"))
        case "weekly":
            guard let weekdays = record["weekdays"]?.arrayValue?.compactMap(\.intValue), !weekdays.isEmpty else {
                throw LocalCapabilityError.verificationFailed("DSH weekly schedule has no weekdays")
            }
            return .weekly(time: try requiredString("time"), timeZone: try requiredString("timeZone"),
                           weekdays: weekdays)
        case "cron": return .cron(expression: try requiredString("expression"),
                                  timeZone: try requiredString("timeZone"))
        default:
            throw LocalCapabilityError.verificationFailed("Unsupported DSH schedule kind: \(managed.kind)")
        }
    }

    private static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}
