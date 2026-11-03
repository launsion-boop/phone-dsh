// SPDX-License-Identifier: MIT

import Foundation
import ProbeKit
import XCTest

final class PA_LocalCapabilityToolInvokerTests: XCTestCase {
    func testDescriptorsReflectBoundProvidersAndRejectDSHCaller() async throws {
        let fixture = try await makeFixture()
        let local = LocalCapabilityToolInvoker(profile: StaticProfile(), memories: fixture.memories,
                                               followUps: fixture.followUps)
        let names = await local.descriptors.map(\.internalName)
        XCTAssertTrue(names.contains("rename_assistant"))
        XCTAssertTrue(names.contains("memory_open_loop"))
        XCTAssertFalse(names.contains("schedule_create"))
        XCTAssertFalse(names.contains("memory_record_suggestion"))
        XCTAssertFalse(names.contains("approval"))

        let result = await local.invoke("memory_log", argumentsJSON: #"{"text":"event"}"#, caller: .dshDirect)
        XCTAssertTrue(result.isError)
        XCTAssertEqual(try object(result)["error"]["code"] as? String, "personal_agent_required")
    }

    func testRenameUsesSharedDefaultsKeySurvivesRestartAndReportsFailure() async throws {
        let suiteName = "PA-LocalCapability-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = try await makeFixture()
        let store = PersonalAgentProfileStore(defaults: defaults)
        let local = LocalCapabilityToolInvoker(profile: store, memories: fixture.memories,
                                               followUps: fixture.followUps)

        let result = await invoke(local, "rename_assistant", #"{"name":"  小鱼\nProd  "}"#)
        XCTAssertFalse(result.isError, result.contentJSON)
        XCTAssertEqual(defaults.string(forKey: PersonalAgentProfileStore.assistantNameKey), "小鱼\nProd")
        let restartedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let restarted = PersonalAgentProfileStore(defaults: restartedDefaults)
        XCTAssertEqual(try restarted.profile().assistantName, "小鱼\nProd")
        let payload = try object(result)
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["profile"]["assistantName"] as? String, "小鱼\nProd")

        let failing = LocalCapabilityToolInvoker(profile: FailingProfile(), memories: fixture.memories,
                                                 followUps: fixture.followUps)
        let failed = await invoke(failing, "rename_assistant", #"{"name":"Not saved"}"#)
        XCTAssertTrue(failed.isError)
        XCTAssertEqual(try object(failed)["ok"] as? Bool, false)
        XCTAssertEqual(try object(failed)["error"]["code"] as? String, "persistence_failed")
    }

    func testMemoryRevisionSourceAndPrincipalAccountBoundaries() async throws {
        let fixture = try await makeFixture()
        let owner = LocalCapabilityToolInvoker(profile: StaticProfile(), memories: fixture.memories,
                                               followUps: fixture.followUps, accountScope: "account-a")
        let created = await invoke(owner, "memory_set_preference",
                                   #"{"field":"responseLength","value":"short"}"#)
        XCTAssertFalse(created.isError, created.contentJSON)
        let createdRecord = try XCTUnwrap(object(created)["record"] as? [String: Any])
        let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(createdRecord["id"] as? String)))
        XCTAssertEqual(createdRecord["revision"] as? Int, 1)
        XCTAssertEqual(createdRecord["principal"] as? String, "owner")
        XCTAssertEqual(createdRecord["accountScope"] as? String, "account-a")

        let revised = await invoke(owner, "memory_set_preference",
                                   #"{"field":"responseLength","value":"concise"}"#)
        XCTAssertFalse(revised.isError, revised.contentJSON)
        let revisedRecord = try XCTUnwrap(object(revised)["record"] as? [String: Any])
        XCTAssertEqual(revisedRecord["revision"] as? Int, 2)
        XCTAssertEqual(revisedRecord["supersedes"] as? String, id.uuidString)
        XCTAssertEqual(revisedRecord["source"]["kind"] as? String, "phone")
        let active = try await fixture.memories.active(principal: "owner", accountScope: "account-a")
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.text, "concise")
        let archivedStatus = try await fixture.memories.record(id)?.status
        XCTAssertEqual(archivedStatus, .archived)

        let otherPrincipal = LocalCapabilityToolInvoker(profile: StaticProfile(), memories: fixture.memories,
                                                        followUps: fixture.followUps, accountScope: "account-a")
        let wrongPrincipal = await invoke(otherPrincipal, "memory_delete",
                                          "{\"id\":\"\(id.uuidString)\"}", principal: "someone-else")
        XCTAssertTrue(wrongPrincipal.isError)
        XCTAssertEqual(try object(wrongPrincipal)["error"]["code"] as? String, "not_found")

        let otherAccount = LocalCapabilityToolInvoker(profile: StaticProfile(), memories: fixture.memories,
                                                      followUps: fixture.followUps, accountScope: "account-b")
        let newID = try XCTUnwrap(revisedRecord["id"] as? String)
        let wrongAccount = await invoke(otherAccount, "memory_delete", "{\"id\":\"\(newID)\"}")
        XCTAssertTrue(wrongAccount.isError)
        let crossAccountStatus = try await fixture.memories.record(UUID(uuidString: newID)!)?.status
        XCTAssertEqual(crossAccountStatus, .active)
    }

    func testMemoryLogAndDeleteExecuteAgainstRealStoreAndRejectSecrets() async throws {
        let fixture = try await makeFixture()
        let local = LocalCapabilityToolInvoker(profile: StaticProfile(), memories: fixture.memories,
                                               followUps: fixture.followUps, accountScope: "mail-a")
        let logged = await invoke(local, "memory_log", #"{"text":"Met the project team","scope":"work"}"#)
        XCTAssertFalse(logged.isError, logged.contentJSON)
        let record = try XCTUnwrap(object(logged)["record"] as? [String: Any])
        let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(record["id"] as? String)))
        let storedRecord = try await fixture.memories.record(id)
        let persisted = try XCTUnwrap(storedRecord)
        XCTAssertEqual(persisted.kind, .event)
        XCTAssertEqual(persisted.accountScope, "mail-a")
        XCTAssertEqual(persisted.revision, 1)

        let deleted = await invoke(local, "memory_delete", "{\"id\":\"\(id.uuidString)\"}")
        XCTAssertFalse(deleted.isError, deleted.contentJSON)
        let forgottenStatus = try await fixture.memories.record(id)?.status
        XCTAssertEqual(forgottenStatus, .forgotten)
        let activeAfterDelete = try await fixture.memories.active(principal: "owner", accountScope: "mail-a")
        XCTAssertFalse(activeAfterDelete.contains(where: { $0.id == id }))

        let secret = await invoke(local, "memory_log", #"{"text":"password=do-not-save"}"#)
        XCTAssertTrue(secret.isError)
        XCTAssertEqual(try object(secret)["ok"] as? Bool, false)
    }

    func testOpenLoopPersistsWaitingDoneCancelledAndExpiredStates() async throws {
        let fixture = try await makeFixture()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let local = LocalCapabilityToolInvoker(profile: StaticProfile(), memories: fixture.memories,
                                               followUps: fixture.followUps, now: { start })
        let opened = await invoke(local, "memory_open_loop", """
        {"action":"open","goal":"Wait for the reply","waiting_for":"user",
         "target":{"kind":"gmailThread","thread_id":"thread-1"},
         "check_condition":"reply arrived","stop_condition":"reply received",
         "valid_until":"2027-02-10T00:00:00Z"}
        """)
        XCTAssertFalse(opened.isError, opened.contentJSON)
        let followUp = try XCTUnwrap(object(opened)["follow_up"] as? [String: Any])
        XCTAssertEqual(followUp["status"] as? String, "waiting-user")
        let id = try XCTUnwrap(followUp["id"] as? String)
        let waitingReason = try await fixture.followUps.record(UUID(uuidString: id)!)?.followUp.waitingReason
        XCTAssertEqual(waitingReason, "waiting-user")

        let done = await invoke(local, "memory_open_loop", "{\"action\":\"done\",\"id\":\"\(id)\"}")
        XCTAssertEqual(try object(done)["follow_up"]["status"] as? String, "done")
        let endedAt = try await fixture.followUps.record(UUID(uuidString: id)!)?.endedAt
        XCTAssertNotNil(endedAt)

        let expiring = await invoke(local, "memory_open_loop", """
        {"action":"open","goal":"External check","waiting_for":"external",
         "target":{"kind":"githubPR","repository":"owner/repo","number":42},
         "check_condition":"checks complete","stop_condition":"merged",
         "valid_until":"2027-01-16T00:00:00Z"}
        """)
        let expiringID = try XCTUnwrap(object(expiring)["follow_up"]["id"] as? String)
        let later = LocalCapabilityToolInvoker(profile: StaticProfile(), memories: fixture.memories,
                                               followUps: fixture.followUps,
                                               now: { start.addingTimeInterval(3 * 86_400) })
        let listed = await invoke(later, "memory_open_loop", #"{"action":"list","include_ended":true}"#)
        let rows = try XCTUnwrap(object(listed)["follow_ups"] as? [[String: Any]])
        XCTAssertEqual(rows.first(where: { $0["id"] as? String == expiringID })?["status"] as? String, "expired")

        let cancelled = await invoke(later, "memory_open_loop", "{\"action\":\"cancelled\",\"id\":\"\(expiringID)\"}")
        XCTAssertEqual(try object(cancelled)["follow_up"]["status"] as? String, "cancelled")
    }

    func testSuggestionHistoryUsesBoundStoreAndHostAssignedScope() async throws {
        let fixture = try await makeFixture()
        let history = HistoryProvider()
        let local = LocalCapabilityToolInvoker(profile: StaticProfile(), memories: fixture.memories,
                                               followUps: fixture.followUps, suggestionHistory: history,
                                               accountScope: "account-a")
        let selected = await invoke(local, "memory_record_suggestion",
                                    #"{"canonical_key":"gmail:thread-1:reply","outcome":"selected"}"#)
        XCTAssertFalse(selected.isError, selected.contentJSON)
        let event = try XCTUnwrap(object(selected)["event"] as? [String: Any])
        XCTAssertEqual(event["principal"] as? String, "owner")
        XCTAssertEqual(event["accountScope"] as? String, "account-a")
        XCTAssertEqual(event["outcome"] as? String, "selected")

        _ = await invoke(local, "memory_record_suggestion",
                         #"{"canonical_key":"gmail:thread-1:reply","outcome":"dismissed"}"#)
        let read = await invoke(local, "memory_get_suggestion_history",
                                #"{"canonical_key":"gmail:thread-1:reply","limit":10}"#)
        let entries = try XCTUnwrap(object(read)["history"] as? [[String: Any]])
        XCTAssertEqual(Set(entries.compactMap { $0["outcome"] as? String }), ["selected", "dismissed"])
        let historyCount = await history.recordCount()
        XCTAssertEqual(historyCount, 2)

        let other = await invoke(local, "memory_get_suggestion_history", "{}", principal: "other")
        XCTAssertEqual(try object(other)["count"] as? Int, 0)
    }

    func testScheduleDedupeTimezoneUpdateCancellationAndVerifiedNextRun() async throws {
        let fixture = try await makeFixture()
        let scheduler = ScheduleProvider()
        let local = LocalCapabilityToolInvoker(profile: StaticProfile(), memories: fixture.memories,
                                               followUps: fixture.followUps, schedules: scheduler,
                                               accountScope: "account-a")
        let arguments = """
        {"session_id":"session-1","title":"Standup","prompt":"Prepare standup",
         "rule":{"kind":"daily","daily":{"time":"09:00:00","time_zone":"Asia/Shanghai"}}}
        """
        let created = await invoke(local, "schedule_create", arguments)
        XCTAssertFalse(created.isError, created.contentJSON)
        let schedule = try XCTUnwrap(object(created)["schedule"] as? [String: Any])
        XCTAssertEqual(schedule["time_zone"] as? String, "Asia/Shanghai")
        XCTAssertEqual(schedule["next_run_status"] as? String, "scheduled")
        XCTAssertNotNil(schedule["next_run_at"])
        XCTAssertEqual(schedule["background_execution"]["exact_time_guaranteed"] as? Bool, false)
        let id = try XCTUnwrap(schedule["id"] as? String)

        let duplicate = await invoke(local, "schedule_create", arguments)
        XCTAssertEqual(try object(duplicate)["outcome"] as? String, "deduplicated")
        XCTAssertEqual(try object(duplicate)["schedule"]["id"] as? String, id)
        let createCount = await scheduler.createCount
        XCTAssertEqual(createCount, 1)

        let updated = await invoke(local, "schedule_update",
                                   "{\"id\":\"\(id)\",\"title\":\"Daily standup\"}")
        XCTAssertFalse(updated.isError, updated.contentJSON)
        XCTAssertEqual(try object(updated)["schedule"]["title"] as? String, "Daily standup")
        XCTAssertEqual(try object(updated)["schedule"]["next_run_status"] as? String, "scheduled")
        let updateCount = await scheduler.updateCount
        XCTAssertEqual(updateCount, 1)

        let deleted = await invoke(local, "schedule_delete", "{\"id\":\"\(id)\"}")
        XCTAssertFalse(deleted.isError, deleted.contentJSON)
        XCTAssertEqual(try object(deleted)["cancelled"] as? Bool, true)
        XCTAssertEqual(try object(deleted)["next_run_status"] as? String, "cancelled")
        let deleteCount = await scheduler.deleteCount
        XCTAssertEqual(deleteCount, 1)
        let cancelledStatus = await scheduler.schedule(id: id)?.status
        XCTAssertEqual(cancelledStatus, "cancelled")

        let invalid = await invoke(local, "schedule_create", """
        {"session_id":"session-1","title":"Bad zone","prompt":"Do not create",
         "rule":{"kind":"cron","cron":{"expression":"0 9 * * 1-5","time_zone":"Mars/Olympus"}}}
        """)
        XCTAssertTrue(invalid.isError)
        XCTAssertEqual(try object(invalid)["error"]["code"] as? String, "invalid_arguments")
        let finalCreateCount = await scheduler.createCount
        XCTAssertEqual(finalCreateCount, 1)
    }

    func testScheduleDoesNotClaimSuccessWhenCancellationIsUnconfirmed() async throws {
        let fixture = try await makeFixture()
        let scheduler = ScheduleProvider(confirmCancellation: false)
        let local = LocalCapabilityToolInvoker(profile: StaticProfile(), memories: fixture.memories,
                                               followUps: fixture.followUps, schedules: scheduler)
        let created = await invoke(local, "schedule_create",
                                   #"{"session_id":"s","title":"Once","prompt":"Run","rule":{"kind":"after","after_seconds":60}}"#)
        let id = try XCTUnwrap(object(created)["schedule"]["id"] as? String)
        let deleted = await invoke(local, "schedule_delete", "{\"id\":\"\(id)\"}")
        XCTAssertTrue(deleted.isError)
        XCTAssertEqual(try object(deleted)["ok"] as? Bool, false)
        XCTAssertEqual(try object(deleted)["error"]["code"] as? String, "verification_failed")
    }

    private func makeFixture() async throws -> (memories: MemoryStore, followUps: FollowUpStore) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PA-LocalCapability-\(UUID().uuidString)/domain.sqlite")
        let domain = try SQLiteDomainStore(fileURL: url)
        let memories = MemoryStore(domain: domain)
        let followUps = FollowUpStore(domain: domain)
        try await memories.prepare()
        try await followUps.prepare()
        return (memories, followUps)
    }

    private func invoke(_ invoker: LocalCapabilityToolInvoker, _ name: String, _ arguments: String,
                        principal: String = "owner") async -> ToolInvocationResult {
        await invoker.invoke(name, argumentsJSON: arguments,
                             caller: .personalAgent(mandate: mandate(principal: principal)))
    }

    private func mandate(principal: String) -> WorkMandate {
        WorkMandate(mandateID: UUID(), version: 3, requestID: UUID(), principal: principal,
                    source: .phone, goal: "Manage personal local state", allowedActions: [.read],
                    allowedEvidenceRefs: [], targets: MandateTargets(origin: .userNamed),
                    validUntil: Date(timeIntervalSince1970: 4_000_000_000))
    }

    private func object(_ result: ToolInvocationResult) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.contentJSON.utf8)) as? [String: Any])
    }
}

private struct StaticProfile: PersonalAgentProfileProviding {
    func profile() throws -> PersonalAgentProfile { PersonalAgentProfile(assistantName: "Test Agent") }
    func renameAssistant(to name: String) throws -> PersonalAgentProfile {
        PersonalAgentProfile(assistantName: name.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private struct FailingProfile: PersonalAgentProfileProviding {
    func profile() throws -> PersonalAgentProfile { PersonalAgentProfile(assistantName: "Old") }
    func renameAssistant(to name: String) throws -> PersonalAgentProfile {
        throw LocalCapabilityError.persistenceFailed("injected write failure")
    }
}

private actor HistoryProvider: SuggestionHistoryProviding {
    private var entries: [SuggestionHistoryEntry] = []

    func suggestionHistory(principal: String, accountScope: String?, canonicalKey: String?,
                           limit: Int) async throws -> [SuggestionHistoryEntry] {
        Array(entries.filter {
            $0.principal == principal && $0.accountScope == accountScope &&
                (canonicalKey == nil || $0.canonicalKey == canonicalKey)
        }.sorted { $0.occurredAt > $1.occurredAt }.prefix(limit))
    }

    func recordSuggestion(_ entry: SuggestionHistoryEntry) async throws -> SuggestionHistoryEntry {
        entries.append(entry)
        return entry
    }

    func recordCount() -> Int { entries.count }
}

private actor ScheduleProvider: PersonalScheduleProviding {
    private var records: [PersonalSchedule] = []
    private let confirmCancellation: Bool
    private(set) var createCount = 0
    private(set) var updateCount = 0
    private(set) var deleteCount = 0

    init(confirmCancellation: Bool = true) {
        self.confirmCancellation = confirmCancellation
    }

    func listSchedules(principal: String, accountScope: String?) async throws -> [PersonalSchedule] {
        records
    }

    func createSchedule(_ request: PersonalScheduleCreateRequest) async throws -> PersonalSchedule {
        createCount += 1
        let schedule = PersonalSchedule(id: "schedule-\(createCount)", sessionID: request.sessionID,
                                        title: request.title, prompt: request.prompt, rule: request.rule,
                                        status: "active", nextRunAt: Date(timeIntervalSince1970: 1_800_000_000),
                                        nextRunStatus: "scheduled")
        records.append(schedule)
        return schedule
    }

    func updateSchedule(_ request: PersonalScheduleUpdateRequest) async throws -> PersonalSchedule {
        updateCount += 1
        guard let index = records.firstIndex(where: { $0.id == request.current.id }) else {
            throw LocalCapabilityError.notFound("schedule")
        }
        let current = records[index]
        let updated = PersonalSchedule(id: current.id, sessionID: current.sessionID,
                                       title: request.title ?? current.title,
                                       prompt: request.prompt ?? current.prompt,
                                       rule: request.rule ?? current.rule, status: current.status,
                                       nextRunAt: current.nextRunAt, nextRunStatus: current.nextRunStatus)
        records[index] = updated
        return updated
    }

    func deleteSchedule(_ request: PersonalScheduleDeleteRequest) async throws -> PersonalScheduleDeleteResult {
        deleteCount += 1
        guard confirmCancellation else {
            return PersonalScheduleDeleteResult(id: request.current.id, cancelled: false, status: "active")
        }
        if let index = records.firstIndex(where: { $0.id == request.current.id }) {
            let current = records[index]
            records[index] = PersonalSchedule(id: current.id, sessionID: current.sessionID,
                                              title: current.title, prompt: current.prompt, rule: current.rule,
                                              status: "cancelled", nextRunAt: nil, nextRunStatus: "cancelled")
        }
        return PersonalScheduleDeleteResult(id: request.current.id, cancelled: true, status: "cancelled")
    }

    func schedule(id: String) -> PersonalSchedule? {
        records.first(where: { $0.id == id })
    }
}

private extension Optional where Wrapped == Any {
    subscript(key: String) -> Any? {
        guard case .some(let value) = self else { return nil }
        return (value as? [String: Any])?[key]
    }
}
