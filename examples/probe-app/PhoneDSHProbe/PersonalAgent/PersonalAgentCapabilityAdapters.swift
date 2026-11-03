// SPDX-License-Identifier: MIT

import Foundation
import ProbeKit

@MainActor
final class DSHScheduleAdapter: PersonalScheduleProviding {
    private let model: DSHManagementModel
    private let sessionID: () -> String

    init(model: DSHManagementModel, sessionID: @escaping () -> String) {
        self.model = model
        self.sessionID = sessionID
    }

    func listSchedules(principal: String, accountScope: String?) async throws -> [PersonalSchedule] {
        await model.refreshAutomations()
        return model.scheduleRecords.map(schedule)
    }

    func createSchedule(_ request: PersonalScheduleCreateRequest) async throws -> PersonalSchedule {
        guard case .after(let seconds) = request.rule else {
            throw LocalCapabilityError.unavailable("The current DSH schedule adapter supports after(seconds) only")
        }
        let existing = try await listSchedules(principal: request.principal, accountScope: request.accountScope)
        if let duplicate = existing.first(where: {
            $0.title == request.title && $0.prompt == request.prompt && $0.rule == request.rule && $0.acceptsDuplicate
        }) {
            return duplicate
        }
        let created = await model.createSchedule(sessionID: sessionID(), title: request.title,
                                                 prompt: request.prompt, afterSeconds: seconds)
        guard created else {
            throw LocalCapabilityError.persistenceFailed(model.error ?? "DSH schedule creation failed")
        }
        let current = try await listSchedules(principal: request.principal, accountScope: request.accountScope)
        guard let schedule = current.first(where: {
            $0.title == request.title && $0.prompt == request.prompt && $0.rule == request.rule
        }) else {
            throw LocalCapabilityError.verificationFailed("The created schedule was not present in the DSH catalog")
        }
        return schedule
    }

    func updateSchedule(_ request: PersonalScheduleUpdateRequest) async throws -> PersonalSchedule {
        if let rule = request.rule, rule != request.current.rule {
            throw LocalCapabilityError.unavailable("Changing schedule timing is not supported by this adapter")
        }
        guard let managed = model.scheduleRecords.first(where: { $0.id == request.current.id }) else {
            throw LocalCapabilityError.notFound("Schedule not found in the DSH catalog")
        }
        let updated = await model.updateSchedule(managed, title: request.title ?? request.current.title,
                                                 prompt: request.prompt ?? request.current.prompt)
        guard updated else {
            throw LocalCapabilityError.persistenceFailed(model.error ?? "DSH schedule update failed")
        }
        let current = try await listSchedules(principal: request.principal, accountScope: request.accountScope)
        guard let schedule = current.first(where: { $0.id == request.current.id }) else {
            throw LocalCapabilityError.verificationFailed("The updated schedule was not present in the DSH catalog")
        }
        return schedule
    }

    func deleteSchedule(_ request: PersonalScheduleDeleteRequest) async throws -> PersonalScheduleDeleteResult {
        guard let managed = model.scheduleRecords.first(where: { $0.id == request.current.id }) else {
            throw LocalCapabilityError.notFound("Schedule not found in the DSH catalog")
        }
        await model.deleteSchedule(managed)
        if let error = model.error {
            throw LocalCapabilityError.persistenceFailed(error)
        }
        return PersonalScheduleDeleteResult(id: request.current.id, cancelled: true, status: "cancelled")
    }

    private func schedule(_ managed: ManagedSchedule) -> PersonalSchedule {
        PersonalSchedule(id: managed.id, sessionID: managed.sessionID, title: managed.title,
                         prompt: managed.prompt, rule: rule(managed), status: managed.status,
                         nextRunAt: Self.date(managed.scheduledAt), nextRunStatus: managed.status,
                         latestDeliveryAt: managed.latestDeliveryAt.flatMap(Self.date))
    }

    private func rule(_ managed: ManagedSchedule) -> PersonalScheduleRule {
        let normalized = managed.kind.lowercased().replacingOccurrences(of: " ", with: "")
        if normalized.hasPrefix("after"),
           let seconds = normalized.split(whereSeparator: { $0 == ":" || $0 == "=" || $0 == "_" })
            .compactMap({ Int($0) }).first {
            return .after(seconds: seconds)
        }
        if let date = Self.date(managed.scheduledAt) { return .at(date) }
        return .cron(expression: managed.kind, timeZone: TimeZone.current.identifier)
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
