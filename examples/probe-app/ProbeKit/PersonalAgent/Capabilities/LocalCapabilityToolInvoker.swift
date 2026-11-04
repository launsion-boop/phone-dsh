// SPDX-License-Identifier: MIT

import Foundation

public actor LocalCapabilityToolInvoker: ConnectorToolInvoker {
    public static let connectorID = "personal"
    public static let backgroundExecutionLimitation =
        "Schedules run only while the bound DSH host is running. iOS does not guarantee exact-time background execution; suspension or host termination can delay or prevent a run."

    public let descriptors: [ConnectorToolDescriptor]

    private let profile: any PersonalAgentProfileProviding
    private let memories: MemoryStore
    private let followUps: FollowUpStore
    private let suggestionHistory: (any SuggestionHistoryProviding)?
    private let schedules: (any PersonalScheduleProviding)?
    private let accountScope: String?
    private let now: @Sendable () -> Date

    public init(profile: any PersonalAgentProfileProviding,
                memories: MemoryStore,
                followUps: FollowUpStore,
                suggestionHistory: (any SuggestionHistoryProviding)? = nil,
                schedules: (any PersonalScheduleProviding)? = nil,
                accountScope: String? = nil,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.profile = profile
        self.memories = memories
        self.followUps = followUps
        self.suggestionHistory = suggestionHistory
        self.schedules = schedules
        self.accountScope = accountScope
        self.now = now

        var descriptors = [
            Self.descriptor("rename_assistant", effect: .write, action: .personalProfileWrite,
                            summary: "Rename the shared Personal Agent profile", schema: Self.renameSchema),
            Self.descriptor("memory_set_profile", effect: .write, action: .personalMemoryWrite,
                            summary: "Save a field in the shared personal profile memory", schema: Self.profileSchema),
            Self.descriptor("memory_set_preference", effect: .write, action: .personalMemoryWrite,
                            summary: "Save or revise an explicit personal preference", schema: Self.profileSchema),
            Self.descriptor("memory_log", effect: .write, action: .personalMemoryWrite,
                            summary: "Append an explicit event to personal memory", schema: Self.memoryLogSchema),
            Self.descriptor("memory_delete", effect: .write, action: .personalMemoryWrite,
                            summary: "Forget a memory owned by the current principal and account", schema: Self.memoryDeleteSchema),
            Self.descriptor("memory_open_loop", effect: .write, action: .personalFollowUpWrite,
                            summary: "Open, inspect, finish, or cancel a persisted FollowUp", schema: Self.openLoopSchema),
        ]
        if suggestionHistory != nil {
            descriptors.append(Self.descriptor("memory_get_suggestion_history", effect: .read,
                                               action: .read, summary: "Read scoped suggestion interaction history",
                                               schema: Self.suggestionHistorySchema))
            descriptors.append(Self.descriptor("memory_record_suggestion", effect: .write,
                                               action: .personalSuggestionHistoryWrite,
                                               summary: "Record a distinct suggestion interaction outcome",
                                               schema: Self.recordSuggestionSchema))
        }
        if schedules != nil {
            descriptors.append(Self.descriptor("schedule_list", effect: .read, action: .read,
                                               summary: "List schedules from the bound DSH scheduler",
                                               schema: Self.emptySchema))
            descriptors.append(Self.descriptor("schedule_create", effect: .write, action: .personalScheduleWrite,
                                               summary: "Create a deduplicated schedule in the bound DSH scheduler",
                                               schema: Self.scheduleCreateSchema))
            descriptors.append(Self.descriptor("schedule_update", effect: .write, action: .personalScheduleWrite,
                                               summary: "Update an existing schedule in the bound DSH scheduler",
                                               schema: Self.scheduleUpdateSchema))
            descriptors.append(Self.descriptor("schedule_delete", effect: .write, action: .personalScheduleWrite,
                                               summary: "Cancel an existing schedule in the bound DSH scheduler",
                                               schema: Self.scheduleDeleteSchema))
        }
        self.descriptors = descriptors
    }

    public func invoke(_ name: String, argumentsJSON: String,
                       caller: ToolCaller) async -> ToolInvocationResult {
        guard descriptors.contains(where: { $0.internalName == name }) else {
            return Self.failure(name: name, code: "unknown_tool", message: "The local capability is not registered")
        }
        guard case .personalAgent(let mandate) = caller else {
            return Self.failure(name: name, code: "personal_agent_required",
                                message: "Local capabilities require a current Personal Agent WorkMandate")
        }
        guard !mandate.principal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              mandate.validUntil > now() else {
            return Self.failure(name: name, code: "mandate_expired",
                                message: "The Personal Agent WorkMandate is missing or expired")
        }
        let descriptor = descriptors.first { $0.internalName == name }!
        let isFollowUpRead: Bool = {
            guard name == "memory_open_loop",
                  let object = try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]
            else { return false }
            return object["action"] as? String == "list"
        }()
        let requiredAction = isFollowUpRead ? MandateAction.read : descriptor.mandateAction
        guard let requiredAction, mandate.allowedActions.contains(requiredAction) else {
            return Self.failure(name: name, code: "action_not_delegated",
                                message: "The current WorkMandate does not allow \(requiredAction?.rawValue ?? "this local operation")")
        }
        do {
            switch name {
            case "rename_assistant": return try await renameAssistant(argumentsJSON)
            case "memory_set_profile", "memory_set_preference":
                return try await setMemoryField(name, argumentsJSON: argumentsJSON, mandate: mandate)
            case "memory_log": return try await logMemory(argumentsJSON, mandate: mandate)
            case "memory_delete": return try await deleteMemory(argumentsJSON, mandate: mandate)
            case "memory_open_loop": return try await openLoop(argumentsJSON, mandate: mandate)
            case "memory_get_suggestion_history":
                return try await getSuggestionHistory(argumentsJSON, mandate: mandate)
            case "memory_record_suggestion":
                return try await recordSuggestion(argumentsJSON, mandate: mandate)
            case "schedule_list": return try await listSchedules(mandate: mandate)
            case "schedule_create": return try await createSchedule(argumentsJSON, mandate: mandate)
            case "schedule_update": return try await updateSchedule(argumentsJSON, mandate: mandate)
            case "schedule_delete": return try await deleteSchedule(argumentsJSON, mandate: mandate)
            default: return Self.failure(name: name, code: "unknown_tool", message: "Unknown local capability")
            }
        } catch let error as LocalCapabilityError {
            return Self.failure(name: name, error: error)
        } catch let error as MemoryError {
            return Self.failure(name: name, code: "memory_\(String(describing: error))",
                                message: "MemoryStore rejected the operation: \(String(describing: error))")
        } catch FollowUpError.notFound {
            return Self.failure(name: name, code: "follow_up_not_found", message: "The FollowUp does not exist")
        } catch {
            return Self.failure(name: name, code: "storage_or_provider_failed",
                                message: "The backing store or bound provider did not confirm the operation: \(error.localizedDescription)")
        }
    }

    private func renameAssistant(_ argumentsJSON: String) async throws -> ToolInvocationResult {
        let object = try Self.object(argumentsJSON, allowed: ["name"], required: ["name"])
        let name = try Self.string(object, key: "name")
        let saved = try profile.renameAssistant(to: name)
        let verified = try profile.profile()
        guard verified == saved, verified.assistantName == name.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw LocalCapabilityError.verificationFailed("assistant name read-after-write did not match")
        }
        return try Self.success(tool: "rename_assistant", outcome: "renamed", values: ["profile": Self.jsonObject(saved)])
    }

    private func setMemoryField(_ name: String, argumentsJSON: String,
                                mandate: WorkMandate) async throws -> ToolInvocationResult {
        let object = try Self.object(argumentsJSON, allowed: ["field", "value"], required: ["field", "value"])
        let fieldName = try Self.string(object, key: "field")
        guard let field = PersonalContextField(rawValue: fieldName) else {
            throw LocalCapabilityError.invalidArguments("unsupported PersonalContextField: \(fieldName)")
        }
        let value = try Self.string(object, key: "value")
        let existing = try await memories.records(principal: mandate.principal, statuses: [.active])
            .filter { $0.accountScope == accountScope && $0.field == field && $0.isActive(at: now()) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
        let source = memorySource(name, mandate: mandate)
        let saved: MemoryRecord
        let outcome: String
        if let existing {
            if existing.text == value {
                saved = existing
                outcome = "unchanged"
            } else {
                saved = try await memories.supersede(existing.id, with: value, source: source, now: now())
                outcome = "revised"
            }
        } else {
            let record = MemoryRecord(principal: mandate.principal, accountScope: accountScope,
                                      kind: .longTerm, field: field, text: value, source: source,
                                      origin: .modelInference, revision: 1, validFrom: now(), status: .active,
                                      createdAt: now(), updatedAt: now())
            try await memories.save(record)
            saved = record
            outcome = "created"
        }
        let verified = try await verifiedMemory(saved.id, principal: mandate.principal)
        guard verified.revision == saved.revision, verified.text == value,
              verified.source.kind == source.kind, verified.source.reference == source.reference,
              verified.source.detail == source.detail, verified.isActive(at: now()) else {
            throw LocalCapabilityError.verificationFailed("memory read-after-write did not match")
        }
        return try Self.success(tool: name, outcome: outcome,
                                values: ["record": Self.jsonObject(verified), "revision": verified.revision])
    }

    private func logMemory(_ argumentsJSON: String,
                           mandate: WorkMandate) async throws -> ToolInvocationResult {
        let object = try Self.object(argumentsJSON, allowed: ["text", "scope"], required: ["text"])
        let text = try Self.string(object, key: "text")
        let scope = try Self.optionalString(object, key: "scope") ?? "personal"
        let source = memorySource("memory_log", mandate: mandate)
        let record = MemoryRecord(principal: mandate.principal, accountScope: accountScope,
                                  kind: .event, text: text, scope: scope, source: source,
                                  origin: .modelInference, revision: 1, validFrom: now(), status: .active,
                                  createdAt: now(), updatedAt: now())
        try await memories.save(record)
        let verified = try await verifiedMemory(record.id, principal: mandate.principal)
        guard verified.revision == 1, verified.text == text,
              verified.source.kind == source.kind, verified.source.reference == source.reference,
              verified.source.detail == source.detail else {
            throw LocalCapabilityError.verificationFailed("memory event read-after-write did not match")
        }
        return try Self.success(tool: "memory_log", outcome: "logged", values: ["record": Self.jsonObject(verified)])
    }

    private func deleteMemory(_ argumentsJSON: String,
                              mandate: WorkMandate) async throws -> ToolInvocationResult {
        let object = try Self.object(argumentsJSON, allowed: ["id"], required: ["id"])
        let id = try Self.uuid(object, key: "id")
        let existing = try await memories.record(id)
        guard let existing, existing.principal == mandate.principal,
              existing.accountScope == accountScope else {
            throw LocalCapabilityError.notFound("memory was not found in the current principal/account scope")
        }
        try await memories.forget(id, now: now())
        let verified = try await verifiedMemory(id, principal: mandate.principal)
        guard verified.status == .forgotten else {
            throw LocalCapabilityError.verificationFailed("memory was not marked forgotten")
        }
        let active = try await memories.active(principal: mandate.principal,
                                               accountScope: accountScope, limit: 100, now: now())
        guard !active.contains(where: { $0.id == id }) else {
            throw LocalCapabilityError.verificationFailed("forgotten memory remains active")
        }
        return try Self.success(tool: "memory_delete", outcome: "forgotten",
                                values: ["id": id.uuidString, "status": verified.status.rawValue,
                                         "revision": verified.revision])
    }

    private func openLoop(_ argumentsJSON: String, mandate: WorkMandate) async throws -> ToolInvocationResult {
        let object = try Self.object(argumentsJSON,
                                     allowed: ["action", "id", "goal", "target", "waiting_for",
                                               "check_condition", "stop_condition", "valid_until",
                                               "notification_policy", "include_ended"],
                                     required: ["action"])
        let action = try Self.string(object, key: "action")
        switch action {
        case "open":
            let goal = try Self.string(object, key: "goal")
            let waitingFor = try Self.optionalString(object, key: "waiting_for") ?? "external"
            guard waitingFor == "user" || waitingFor == "external" else {
                throw LocalCapabilityError.invalidArguments("waiting_for must be user or external")
            }
            let targetObject = try Self.nestedObject(object, key: "target",
                                                     allowed: ["kind", "repository", "number", "thread_id"],
                                                     required: ["kind"])
            let kindName = try Self.string(targetObject, key: "kind")
            guard let kind = FollowUpTarget.Kind(rawValue: kindName) else {
                throw LocalCapabilityError.invalidArguments("target kind must be githubPR or gmailThread")
            }
            let repository = try Self.optionalString(targetObject, key: "repository")
            let number = try Self.optionalInt(targetObject, key: "number")
            let threadID = try Self.optionalString(targetObject, key: "thread_id")
            switch kind {
            case .githubPR:
                guard repository != nil, number != nil, number! > 0, threadID == nil else {
                    throw LocalCapabilityError.invalidArguments("githubPR requires repository and a positive number")
                }
            case .gmailThread:
                guard threadID != nil, repository == nil, number == nil else {
                    throw LocalCapabilityError.invalidArguments("gmailThread requires only thread_id")
                }
            }
            let check = CheckCondition(expression: try Self.string(object, key: "check_condition"))
            let stop = StopCondition(expression: try Self.string(object, key: "stop_condition"))
            let validUntil = try Self.optionalDate(object, key: "valid_until")
            if let validUntil, validUntil <= now() {
                throw LocalCapabilityError.invalidArguments("valid_until must be in the future")
            }
            let policyName = try Self.optionalString(object, key: "notification_policy") ?? "changesOnly"
            guard let policy = NotificationPolicy(rawValue: policyName) else {
                throw LocalCapabilityError.invalidArguments("invalid notification_policy")
            }
            let followUp = FollowUp(goal: goal,
                                    target: FollowUpTarget(kind: kind, repository: repository,
                                                           number: number, threadID: threadID),
                                    allowedActions: [.read], waitingReason: "waiting-\(waitingFor)",
                                    nextCheckCondition: check, stopCondition: stop,
                                    validUntil: validUntil, notificationPolicy: policy)
            let created = try await followUps.create(followUp, principal: mandate.principal,
                                                     accountScope: accountScope)
            guard let verified = try await followUps.record(created.id, principal: mandate.principal,
                                                            accountScope: accountScope), verified == created else {
                throw LocalCapabilityError.verificationFailed("FollowUp read-after-write did not match")
            }
            return try Self.success(tool: "memory_open_loop", outcome: "opened",
                                    values: ["follow_up": followUpJSON(verified)])
        case "list":
            let includeEnded = try Self.optionalBool(object, key: "include_ended") ?? false
            let records = try await followUps.records(includeEnded: includeEnded, principal: mandate.principal,
                                                      accountScope: accountScope)
            return try Self.success(tool: "memory_open_loop", outcome: "listed",
                                    values: ["follow_ups": records.map(followUpJSON), "count": records.count])
        case "done", "cancelled":
            let id = try Self.uuid(object, key: "id")
            guard var record = try await followUps.record(id, principal: mandate.principal,
                                                          accountScope: accountScope), record.endedAt == nil else {
                throw LocalCapabilityError.notFound("an open FollowUp with this id was not found")
            }
            record.followUp.waitingReason = action
            record.endedAt = now()
            record.needsAttention = false
            record.revision += 1
            try await followUps.save(record)
            guard let verified = try await followUps.record(id, principal: mandate.principal,
                                                            accountScope: accountScope), verified.endedAt != nil,
                  verified.followUp.waitingReason == action, verified.revision == record.revision else {
                throw LocalCapabilityError.verificationFailed("FollowUp completion was not persisted")
            }
            return try Self.success(tool: "memory_open_loop", outcome: action,
                                    values: ["follow_up": followUpJSON(verified)])
        default:
            throw LocalCapabilityError.invalidArguments("action must be open, list, done, or cancelled")
        }
    }

    private func getSuggestionHistory(_ argumentsJSON: String,
                                      mandate: WorkMandate) async throws -> ToolInvocationResult {
        guard let suggestionHistory else { throw LocalCapabilityError.unavailable("suggestion history is not bound") }
        let object = try Self.object(argumentsJSON, allowed: ["canonical_key", "limit"], required: [])
        let canonicalKey = try Self.optionalCanonicalKey(object, key: "canonical_key")
        let limit = try Self.optionalInt(object, key: "limit") ?? 50
        guard (1...100).contains(limit) else {
            throw LocalCapabilityError.invalidArguments("limit must be in 1...100")
        }
        let entries = try await suggestionHistory.suggestionHistory(
            principal: mandate.principal, accountScope: accountScope, canonicalKey: canonicalKey, limit: limit)
        return try Self.success(tool: "memory_get_suggestion_history", outcome: "read",
                                values: ["history": entries.map(Self.jsonObject), "count": entries.count])
    }

    private func recordSuggestion(_ argumentsJSON: String,
                                  mandate: WorkMandate) async throws -> ToolInvocationResult {
        guard let suggestionHistory else { throw LocalCapabilityError.unavailable("suggestion history is not bound") }
        let object = try Self.object(argumentsJSON, allowed: ["canonical_key", "outcome"],
                                     required: ["canonical_key", "outcome"])
        guard let canonicalKey = try Self.optionalCanonicalKey(object, key: "canonical_key") else {
            throw LocalCapabilityError.invalidArguments("canonical_key is required")
        }
        let outcomeName = try Self.string(object, key: "outcome")
        guard let outcome = SuggestionHistoryOutcome(rawValue: outcomeName) else {
            throw LocalCapabilityError.invalidArguments("unsupported suggestion outcome")
        }
        let entry = SuggestionHistoryEntry(principal: mandate.principal, accountScope: accountScope,
                                           canonicalKey: canonicalKey, outcome: outcome, occurredAt: now())
        let saved = try await suggestionHistory.recordSuggestion(entry)
        let history = try await suggestionHistory.suggestionHistory(
            principal: mandate.principal, accountScope: accountScope, canonicalKey: canonicalKey, limit: 100)
        guard let verified = history.first(where: { $0.id == saved.id }), verified == entry else {
            throw LocalCapabilityError.verificationFailed("suggestion history read-after-write did not match")
        }
        return try Self.success(tool: "memory_record_suggestion", outcome: outcome.rawValue,
                                values: ["event": Self.jsonObject(verified)])
    }

    private func listSchedules(mandate: WorkMandate) async throws -> ToolInvocationResult {
        guard let schedules else { throw LocalCapabilityError.unavailable("scheduler is not bound") }
        let values = try await schedules.listSchedules(principal: mandate.principal, accountScope: accountScope)
        return try Self.success(tool: "schedule_list", outcome: "listed",
                                values: ["schedules": values.map(scheduleJSON), "count": values.count])
    }

    private func createSchedule(_ argumentsJSON: String,
                                mandate: WorkMandate) async throws -> ToolInvocationResult {
        guard let schedules else { throw LocalCapabilityError.unavailable("scheduler is not bound") }
        let object = try Self.object(argumentsJSON,
                                     allowed: ["session_id", "title", "prompt", "rule"],
                                     required: ["session_id", "title", "prompt", "rule"])
        let sessionID = try Self.string(object, key: "session_id")
        let title = try Self.string(object, key: "title")
        let prompt = try Self.string(object, key: "prompt")
        let rule = try Self.scheduleRule(try Self.rawObject(object, key: "rule"))
        let existing = try await schedules.listSchedules(principal: mandate.principal, accountScope: accountScope)
        if let duplicate = existing.first(where: {
            $0.acceptsDuplicate && $0.sessionID == sessionID && $0.title == title &&
                $0.prompt == prompt && $0.rule == rule
        }) {
            return try Self.success(tool: "schedule_create", outcome: "deduplicated",
                                    values: ["schedule": scheduleJSON(duplicate), "deduplicated": true])
        }
        let request = PersonalScheduleCreateRequest(principal: mandate.principal, accountScope: accountScope,
                                                    sessionID: sessionID, title: title, prompt: prompt, rule: rule)
        let created = try await schedules.createSchedule(request)
        let verified = try await verifySchedule(created.id, provider: schedules, mandate: mandate)
        return try Self.success(tool: "schedule_create", outcome: "created",
                                values: ["schedule": scheduleJSON(verified), "deduplicated": false])
    }

    private func updateSchedule(_ argumentsJSON: String,
                                mandate: WorkMandate) async throws -> ToolInvocationResult {
        guard let schedules else { throw LocalCapabilityError.unavailable("scheduler is not bound") }
        let object = try Self.object(argumentsJSON, allowed: ["id", "title", "prompt", "rule"], required: ["id"])
        let id = try Self.string(object, key: "id")
        let current = try await verifySchedule(id, provider: schedules, mandate: mandate)
        let title = try Self.optionalString(object, key: "title")
        let prompt = try Self.optionalString(object, key: "prompt")
        let rule = try object["rule"].map { try Self.scheduleRule(try Self.dictionary($0)) }
        guard title != nil || prompt != nil || rule != nil else {
            throw LocalCapabilityError.invalidArguments("at least one of title, prompt, or rule is required")
        }
        let updatedTitle = title ?? current.title
        let updatedPrompt = prompt ?? current.prompt
        let updatedRule = rule ?? current.rule
        let existing = try await schedules.listSchedules(principal: mandate.principal, accountScope: accountScope)
        if existing.contains(where: {
            $0.id != id && $0.acceptsDuplicate && $0.sessionID == current.sessionID &&
                $0.title == updatedTitle && $0.prompt == updatedPrompt && $0.rule == updatedRule
        }) {
            throw LocalCapabilityError.invalidArguments("the update would duplicate an active schedule")
        }
        let request = PersonalScheduleUpdateRequest(principal: mandate.principal, accountScope: accountScope,
                                                    current: current, title: title, prompt: prompt, rule: rule)
        let updated = try await schedules.updateSchedule(request)
        let verified = try await verifySchedule(updated.id, provider: schedules, mandate: mandate)
        return try Self.success(tool: "schedule_update", outcome: "updated", values: ["schedule": scheduleJSON(verified)])
    }

    private func deleteSchedule(_ argumentsJSON: String,
                                mandate: WorkMandate) async throws -> ToolInvocationResult {
        guard let schedules else { throw LocalCapabilityError.unavailable("scheduler is not bound") }
        let object = try Self.object(argumentsJSON, allowed: ["id"], required: ["id"])
        let id = try Self.string(object, key: "id")
        let current = try await verifySchedule(id, provider: schedules, mandate: mandate)
        let result = try await schedules.deleteSchedule(PersonalScheduleDeleteRequest(
            principal: mandate.principal, accountScope: accountScope, current: current))
        guard result.id == id, result.cancelled else {
            throw LocalCapabilityError.verificationFailed("the scheduler did not confirm cancellation")
        }
        return try Self.success(tool: "schedule_delete", outcome: "cancelled",
                                values: ["id": id, "cancelled": true, "status": result.status,
                                         "next_run_at": NSNull(), "next_run_status": "cancelled",
                                         "background_execution": backgroundJSON()])
    }

    private func verifiedMemory(_ id: UUID, principal: String) async throws -> MemoryRecord {
        guard let record = try await memories.record(id), record.principal == principal,
              record.accountScope == accountScope else {
            throw LocalCapabilityError.verificationFailed("saved memory is outside the current principal/account scope")
        }
        return record
    }

    private func verifySchedule(_ id: String, provider: any PersonalScheduleProviding,
                                mandate: WorkMandate) async throws -> PersonalSchedule {
        let records = try await provider.listSchedules(principal: mandate.principal, accountScope: accountScope)
        guard let record = records.first(where: { $0.id == id }) else {
            throw LocalCapabilityError.verificationFailed("the scheduler catalog did not contain the returned schedule")
        }
        return record
    }

    private func memorySource(_ tool: String, mandate: WorkMandate) -> MemorySource {
        MemorySource(kind: mandate.source, reference: mandate.requestID.uuidString,
                     detail: "Personal Agent \(tool); mandate=\(mandate.mandateID.uuidString)@\(mandate.version)",
                     observedAt: now())
    }

    private func followUpJSON(_ record: FollowUpRecord) -> [String: Any] {
        let followUp = record.followUp
        let status: String
        if record.endedAt != nil {
            status = followUp.waitingReason == "cancelled" ? "cancelled" : "done"
        } else if let validUntil = followUp.validUntil, validUntil <= now() {
            status = "expired"
        } else {
            status = followUp.waitingReason ?? "waiting-external"
        }
        return [
            "id": record.id.uuidString,
            "goal": followUp.goal,
            "target_kind": followUp.target.kind.rawValue,
            "status": status,
            "waiting_reason": followUp.waitingReason ?? NSNull(),
            "check_condition": followUp.nextCheckCondition.expression,
            "stop_condition": followUp.stopCondition.expression,
            "valid_until": followUp.validUntil.map(Self.dateString) ?? NSNull(),
            "ended_at": record.endedAt.map(Self.dateString) ?? NSNull(),
            "revision": record.revision,
        ]
    }

    private func scheduleJSON(_ schedule: PersonalSchedule) -> [String: Any] {
        [
            "id": schedule.id,
            "session_id": schedule.sessionID,
            "title": schedule.title,
            "prompt": schedule.prompt,
            "rule": Self.ruleJSON(schedule.rule),
            "status": schedule.status,
            "next_run_at": schedule.nextRunAt.map(Self.dateString) ?? NSNull(),
            "next_run_status": schedule.nextRunStatus,
            "latest_delivery_at": schedule.latestDeliveryAt.map(Self.dateString) ?? NSNull(),
            "time_zone": schedule.rule.timeZone ?? NSNull(),
            "background_execution": backgroundJSON(),
        ]
    }

    private func backgroundJSON() -> [String: Any] {
        ["exact_time_guaranteed": false, "limitation": Self.backgroundExecutionLimitation]
    }

    private static func scheduleRule(_ value: Any) throws -> PersonalScheduleRule {
        let object = try dictionary(value)
        let kind = try string(object, key: "kind")
        switch kind {
        case "after":
            try requireKeys(object, allowed: ["kind", "after_seconds"], required: ["kind", "after_seconds"])
            let seconds = try int(object, key: "after_seconds")
            guard seconds > 0 else { throw LocalCapabilityError.invalidArguments("after_seconds must be positive") }
            return .after(seconds: seconds)
        case "at":
            try requireKeys(object, allowed: ["kind", "at"], required: ["kind", "at"])
            return .at(try date(object, key: "at", requireOffset: true))
        case "every":
            try requireKeys(object, allowed: ["kind", "every_seconds"], required: ["kind", "every_seconds"])
            let seconds = try int(object, key: "every_seconds")
            guard seconds >= 60 else { throw LocalCapabilityError.invalidArguments("every_seconds must be at least 60") }
            return .every(seconds: seconds)
        case "daily":
            try requireKeys(object, allowed: ["kind", "daily"], required: ["kind", "daily"])
            let daily = try nestedObject(object, key: "daily", allowed: ["time", "time_zone"], required: ["time", "time_zone"])
            return .daily(time: try validLocalTime(daily), timeZone: try validTimeZone(daily))
        case "weekly":
            try requireKeys(object, allowed: ["kind", "weekly"], required: ["kind", "weekly"])
            let weekly = try nestedObject(object, key: "weekly", allowed: ["time", "time_zone", "weekdays"],
                                          required: ["time", "time_zone", "weekdays"])
            guard let weekdays = weekly["weekdays"] as? [Int], !weekdays.isEmpty,
                  Set(weekdays).count == weekdays.count, weekdays.allSatisfy({ (1...7).contains($0) }) else {
                throw LocalCapabilityError.invalidArguments("weekdays must contain unique ISO values in 1...7")
            }
            return .weekly(time: try validLocalTime(weekly), timeZone: try validTimeZone(weekly), weekdays: weekdays)
        case "cron":
            try requireKeys(object, allowed: ["kind", "cron"], required: ["kind", "cron"])
            let cron = try nestedObject(object, key: "cron", allowed: ["expression", "time_zone"],
                                        required: ["expression", "time_zone"])
            let expression = try string(cron, key: "expression")
            guard expression.split(whereSeparator: \.isWhitespace).count == 5 else {
                throw LocalCapabilityError.invalidArguments("cron expression must have five fields")
            }
            return .cron(expression: expression, timeZone: try validTimeZone(cron))
        default:
            throw LocalCapabilityError.invalidArguments("unsupported schedule rule kind")
        }
    }

    private static func ruleJSON(_ rule: PersonalScheduleRule) -> [String: Any] {
        switch rule {
        case .after(let seconds): return ["kind": "after", "after_seconds": seconds]
        case .at(let date): return ["kind": "at", "at": dateString(date)]
        case .every(let seconds): return ["kind": "every", "every_seconds": seconds]
        case .daily(let time, let timeZone):
            return ["kind": "daily", "daily": ["time": time, "time_zone": timeZone]]
        case .weekly(let time, let timeZone, let weekdays):
            return ["kind": "weekly", "weekly": ["time": time, "time_zone": timeZone, "weekdays": weekdays]]
        case .cron(let expression, let timeZone):
            return ["kind": "cron", "cron": ["expression": expression, "time_zone": timeZone]]
        }
    }

    private static func validLocalTime(_ object: [String: Any]) throws -> String {
        let time = try string(object, key: "time")
        guard time.range(of: #"^(?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d(?:\.\d{1,3})?)?$"#,
                         options: .regularExpression) != nil else {
            throw LocalCapabilityError.invalidArguments("time must be HH:mm or HH:mm:ss")
        }
        return time
    }

    private static func validTimeZone(_ object: [String: Any]) throws -> String {
        let identifier = try string(object, key: "time_zone")
        guard let zone = TimeZone(identifier: identifier) else {
            throw LocalCapabilityError.invalidArguments("time_zone must be a valid IANA identifier")
        }
        return zone.identifier
    }

    private static func object(_ json: String, allowed: Set<String>, required: Set<String>) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let object = try dictionary(value)
        try requireKeys(object, allowed: allowed, required: required)
        return object
    }

    private static func dictionary(_ value: Any) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw LocalCapabilityError.invalidArguments("arguments must be a JSON object")
        }
        return object
    }

    private static func requireKeys(_ object: [String: Any], allowed: Set<String>, required: Set<String>) throws {
        guard required.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: allowed) else {
            throw LocalCapabilityError.invalidArguments("missing or unknown arguments")
        }
    }

    private static func nestedObject(_ object: [String: Any], key: String,
                                     allowed: Set<String>, required: Set<String>) throws -> [String: Any] {
        guard let value = object[key] else { throw LocalCapabilityError.invalidArguments("\(key) is required") }
        let nested = try dictionary(value)
        try requireKeys(nested, allowed: allowed, required: required)
        return nested
    }

    private static func rawObject(_ object: [String: Any], key: String) throws -> Any {
        guard let value = object[key] else { throw LocalCapabilityError.invalidArguments("\(key) is required") }
        return value
    }

    private static func string(_ object: [String: Any], key: String) throws -> String {
        guard let value = object[key] as? String else {
            throw LocalCapabilityError.invalidArguments("\(key) must be a string")
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 8_192 else {
            throw LocalCapabilityError.invalidArguments("\(key) must contain 1...8192 characters")
        }
        return normalized
    }

    private static func optionalString(_ object: [String: Any], key: String) throws -> String? {
        guard object[key] != nil else { return nil }
        return try string(object, key: key)
    }

    private static func optionalCanonicalKey(_ object: [String: Any], key: String) throws -> String? {
        guard let value = try optionalString(object, key: key) else { return nil }
        guard value.count <= 256 else { throw LocalCapabilityError.invalidArguments("canonical_key is too long") }
        return value
    }

    private static func int(_ object: [String: Any], key: String) throws -> Int {
        guard let value = object[key] as? Int else {
            throw LocalCapabilityError.invalidArguments("\(key) must be an integer")
        }
        return value
    }

    private static func optionalInt(_ object: [String: Any], key: String) throws -> Int? {
        guard object[key] != nil else { return nil }
        return try int(object, key: key)
    }

    private static func optionalBool(_ object: [String: Any], key: String) throws -> Bool? {
        guard object[key] != nil else { return nil }
        guard let value = object[key] as? Bool else {
            throw LocalCapabilityError.invalidArguments("\(key) must be a boolean")
        }
        return value
    }

    private static func uuid(_ object: [String: Any], key: String) throws -> UUID {
        let value = try string(object, key: key)
        guard let id = UUID(uuidString: value) else { throw LocalCapabilityError.invalidArguments("\(key) must be a UUID") }
        return id
    }

    private static func date(_ object: [String: Any], key: String, requireOffset: Bool = false) throws -> Date {
        let value = try string(object, key: key)
        if requireOffset, value.range(of: #"(?:Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) == nil {
            throw LocalCapabilityError.invalidArguments("\(key) must include a timezone offset")
        }
        guard let parsed = parseDate(value) else { throw LocalCapabilityError.invalidArguments("\(key) must be ISO-8601") }
        return parsed
    }

    private static func optionalDate(_ object: [String: Any], key: String) throws -> Date? {
        guard object[key] != nil else { return nil }
        return try date(object, key: key, requireOffset: true)
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func dateString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func jsonObject<T: Encodable>(_ value: T) -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(value)
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            return ["encoding_error": String(describing: error)]
        }
    }

    private static func success(tool: String, outcome: String,
                                values: [String: Any]) throws -> ToolInvocationResult {
        var payload: [String: Any] = ["ok": true, "tool": tool, "outcome": outcome]
        payload.merge(values) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return ToolInvocationResult(toolCallID: "", contentJSON: String(decoding: data, as: UTF8.self))
    }

    private static func failure(name: String, error: LocalCapabilityError) -> ToolInvocationResult {
        switch error {
        case .invalidArguments(let message): return failure(name: name, code: "invalid_arguments", message: message)
        case .unavailable(let message): return failure(name: name, code: "capability_unavailable", message: message)
        case .notFound(let message): return failure(name: name, code: "not_found", message: message)
        case .persistenceFailed(let message): return failure(name: name, code: "persistence_failed", message: message)
        case .verificationFailed(let message): return failure(name: name, code: "verification_failed", message: message)
        }
    }

    private static func failure(name: String, code: String, message: String) -> ToolInvocationResult {
        let payload: [String: Any] = ["ok": false, "tool": name,
                                      "error": ["code": code, "message": message]]
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return ToolInvocationResult(toolCallID: "",
                                    contentJSON: data.map { String(decoding: $0, as: UTF8.self) } ?? #"{"ok":false}"#,
                                    isError: true)
    }

    private static func descriptor(_ name: String, effect: ToolEffect,
                                   action: MandateAction? = nil, summary: String,
                                   schema: String) -> ConnectorToolDescriptor {
        ConnectorToolDescriptor(internalName: name, connectorID: connectorID, effect: effect,
                                mandateAction: action, inputSchemaJSON: schema, summary: summary)
    }

    private static let emptySchema = #"{"type":"object","properties":{},"additionalProperties":false}"#
    private static let renameSchema = #"{"type":"object","required":["name"],"properties":{"name":{"type":"string","minLength":1,"maxLength":80}},"additionalProperties":false}"#
    private static let profileSchema = #"{"type":"object","required":["field","value"],"properties":{"field":{"type":"string","enum":["displayName","timeZone","language","responseLength","occupation","keyContacts","keyRepositoriesOrLabels","workSchedule"]},"value":{"type":"string","minLength":1,"maxLength":8192}},"additionalProperties":false}"#
    private static let memoryLogSchema = #"{"type":"object","required":["text"],"properties":{"text":{"type":"string","minLength":1,"maxLength":8192},"scope":{"type":"string","minLength":1,"maxLength":256}},"additionalProperties":false}"#
    private static let memoryDeleteSchema = #"{"type":"object","required":["id"],"properties":{"id":{"type":"string","format":"uuid"}},"additionalProperties":false}"#
    private static let openLoopSchema = #"{"type":"object","required":["action"],"properties":{"action":{"type":"string","enum":["open","list","done","cancelled"]},"id":{"type":"string","format":"uuid"},"goal":{"type":"string"},"target":{"type":"object","required":["kind"],"properties":{"kind":{"type":"string","enum":["githubPR","gmailThread"]},"repository":{"type":"string"},"number":{"type":"integer","minimum":1},"thread_id":{"type":"string"}},"additionalProperties":false},"waiting_for":{"type":"string","enum":["user","external"]},"check_condition":{"type":"string"},"stop_condition":{"type":"string"},"valid_until":{"type":"string","format":"date-time"},"notification_policy":{"type":"string","enum":["quiet","changesOnly","allResults"]},"include_ended":{"type":"boolean"}},"additionalProperties":false}"#
    private static let suggestionHistorySchema = #"{"type":"object","properties":{"canonical_key":{"type":"string","minLength":1,"maxLength":256},"limit":{"type":"integer","minimum":1,"maximum":100}},"additionalProperties":false}"#
    private static let recordSuggestionSchema = #"{"type":"object","required":["canonical_key","outcome"],"properties":{"canonical_key":{"type":"string","minLength":1,"maxLength":256},"outcome":{"type":"string","enum":["shown","selected","dismissed","declined","superseded","expired"]}},"additionalProperties":false}"#
    private static let scheduleCreateSchema = ##"{"type":"object","required":["session_id","title","prompt","rule"],"properties":{"session_id":{"type":"string","minLength":1},"title":{"type":"string","minLength":1},"prompt":{"type":"string","minLength":1},"rule":{"$ref":"#/$defs/rule"}},"additionalProperties":false,"$defs":{"rule":{"type":"object","required":["kind"],"properties":{"kind":{"type":"string","enum":["after","at","every","daily","weekly","cron"]},"after_seconds":{"type":"integer","minimum":1},"at":{"type":"string","format":"date-time"},"every_seconds":{"type":"integer","minimum":60},"daily":{"type":"object"},"weekly":{"type":"object"},"cron":{"type":"object"}},"additionalProperties":false}}}"##
    private static let scheduleUpdateSchema = #"{"type":"object","required":["id"],"properties":{"id":{"type":"string","minLength":1},"title":{"type":"string","minLength":1},"prompt":{"type":"string","minLength":1},"rule":{"type":"object"}},"additionalProperties":false}"#
    private static let scheduleDeleteSchema = #"{"type":"object","required":["id"],"properties":{"id":{"type":"string","minLength":1}},"additionalProperties":false}"#
}
