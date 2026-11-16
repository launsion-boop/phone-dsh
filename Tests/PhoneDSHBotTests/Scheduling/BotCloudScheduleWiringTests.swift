// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Production wiring: a user tap becomes one durable user-action event and a
/// `record://event/<commitSeq>` permission, then reaches the cloud client.
final class BotCloudScheduleWiringTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let store: SQLiteDomainStore
        let machine: RoutineMachine
        let scheduler: RoutineScheduler
        let transport: WiringProbeTransport
        let client: CloudScheduleClient
        let wiring: BotCloudScheduleWiring
    }

    private func fixture(at now: Int64,
                         authorizer: any CloudScheduleAuthorizing = CloudScheduleAuthorizer())
        async throws -> Fixture {
        let root = try wp6TempDirectory(self)
        let store = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"))
        let machine = RoutineMachine(store: SQLiteRoutineStore(domainStore: store))
        let inbox = WakeInbox(store: SQLiteWakeInboxStore(domainStore: store, botId: "bot-a"))
        let sink = WP6RoutineSink()
        let runs = WP6RunLog()
        let scheduler = RoutineScheduler(
            botId: "bot-a", machine: machine, inbox: inbox, sink: sink,
            runner: { request in runs.append(request); return .success("ok") },
            available: { _ in true }, settings: { wp6Settings() }, now: { now })
        let transport = WiringProbeTransport(clock: { now })
        let client = CloudScheduleClient(
            botID: "bot-a", deviceID: "device-a", transport: transport,
            machine: machine, scheduler: scheduler, authorizer: authorizer,
            readiness: { true }, now: { now }, sleep: { _ in }, configuration: .init())
        let wiring = BotCloudScheduleWiring(
            store: store, machine: machine, client: client, botID: "bot-a", now: { now })
        _ = try await machine.create(
            botId: "bot-a", title: "Digest", prompt: "summarize",
            schedule: .interval(everyMinutes: 30, timezone: "UTC"),
            now: now - 3_600_000, id: "digest")
        return Fixture(root: root, store: store, machine: machine, scheduler: scheduler,
                       transport: transport, client: client, wiring: wiring)
    }

    private func userActionEvents(_ f: Fixture) async throws -> [BotEvent] {
        try await f.store.events(after: 0, limit: 200).filter {
            $0.type == "ui.system_event"
        }
    }

    func testEnableWritesOneUserActionAndRecordsItsCommitSeq() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try await fixture(at: now)
        try await f.wiring.setRoutineCloudSchedule(routineID: "digest", enabled: true)

        let fetched = try await f.machine.get(botId: "bot-a", routineId: "digest")
        let routine = try XCTUnwrap(fetched)
        XCTAssertEqual(routine.cloudSchedule?.enabled, true)
        let reference = try XCTUnwrap(routine.cloudSchedule?.authorizationRef)
        XCTAssertTrue(reference.hasPrefix("record://event/"))
        XCTAssertNotNil(reference.range(of: #"^record://event/[1-9][0-9]*$"#,
                                        options: .regularExpression))

        let events = try await userActionEvents(f)
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.principal.kind, "chat")
        XCTAssertEqual(event.principal.botId, "bot-a")
        XCTAssertEqual(event.origin, .local(source: "user"))
        XCTAssertEqual(event.data["event"]?.stringValue, "cloud-schedule-enabled")
        XCTAssertEqual(event.data["routineId"]?.stringValue, "digest")
        // The reference names exactly the committed decision.
        XCTAssertEqual(reference, "record://event/\(try XCTUnwrap(event.commitSeq))")

        _ = await f.client.synchronizeNow()
        let sync = await f.transport.syncRequests
        XCTAssertEqual(sync.last?.registrations.first?.authorizationRef, reference)
    }

    func testDoubleTapDoesNotDuplicateTheAuditEvent() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try await fixture(at: now)
        try await f.wiring.setRoutineCloudSchedule(routineID: "digest", enabled: true)
        try await f.wiring.setRoutineCloudSchedule(routineID: "digest", enabled: true)
        let events = try await userActionEvents(f)
        XCTAssertEqual(events.count, 1)
    }

    func testDisableRecordsRevocationAndCloudDelete() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try await fixture(at: now)
        try await f.wiring.setRoutineCloudSchedule(routineID: "digest", enabled: true)
        _ = await f.client.synchronizeNow()
        let fetchedEnabled = try await f.machine.get(botId: "bot-a", routineId: "digest")
        let enabled = try XCTUnwrap(fetchedEnabled)
        let enabledRevision = try XCTUnwrap(enabled.cloudSchedule?.seq)

        try await f.wiring.setRoutineCloudSchedule(routineID: "digest", enabled: false)
        let fetchedDisabled = try await f.machine.get(botId: "bot-a", routineId: "digest")
        let disabled = try XCTUnwrap(fetchedDisabled)
        XCTAssertEqual(disabled.cloudSchedule?.enabled, false)
        XCTAssertGreaterThan(try XCTUnwrap(disabled.cloudSchedule?.seq), enabledRevision)
        let events = try await userActionEvents(f)
        XCTAssertEqual(events.map { $0.data["event"]?.stringValue },
                       ["cloud-schedule-enabled", "cloud-schedule-disabled"])

        _ = await f.client.synchronizeNow()
        let sync = await f.transport.syncRequests
        XCTAssertEqual(sync.last?.removed.map(\.routineID), ["digest"])
    }

    func testPurgeDeletesEveryOwnedCloudRow() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try await fixture(at: now)
        _ = try await f.machine.create(
            botId: "bot-a", title: "Second", prompt: "summarize",
            schedule: .interval(everyMinutes: 60, timezone: "UTC"),
            now: now - 3_600_000, id: "second")
        try await f.wiring.setRoutineCloudSchedule(routineID: "digest", enabled: true)
        try await f.wiring.setRoutineCloudSchedule(routineID: "second", enabled: true)
        _ = await f.client.synchronizeNow()
        let purged = await f.wiring.purgeCloudSchedules()
        XCTAssertEqual(purged, 2)
        let cancels = await f.transport.cancelRoutineRequests
        XCTAssertEqual(Set(cancels.map(\.routineID)), ["digest", "second"])
    }

    func testTokenRefreshRearmsTheClient() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try await fixture(at: now)
        try await f.wiring.setRoutineCloudSchedule(routineID: "digest", enabled: true)
        await f.transport.failRequests(with: .unauthenticated)
        _ = await f.client.pollOnce()
        let blocked = await f.transport.requestCount
        _ = await f.client.pollOnce()
        let stillBlocked = await f.transport.requestCount
        XCTAssertEqual(stillBlocked, blocked)
        await f.transport.clearForcedError()
        await f.wiring.noteAuthenticationRefreshed()
        _ = await f.client.pollOnce()
        let afterRefresh = await f.transport.requestCount
        XCTAssertGreaterThan(afterRefresh, blocked)
    }

    func testComposedAuthorizerDoesNotSilentlyAllowAll() async {
        let additional = ComposedCloudScheduleAuthorizer(
            sourceConsent: { _ in .revoked })
        let routine = Routine(id: "r", agentId: "b", title: "t", prompt: "p",
                              schedule: .interval(everyMinutes: 60, timezone: "UTC"),
                              enabled: true, createdAt: 0,
                              cloudSchedule: .init(enabled: true, seq: 1,
                                                   authorizationRef: "record://event/1"))
        let refusal = await additional.refusal(for: routine)
        XCTAssertEqual(refusal, .revoked)
        let defaultAuthorizer = ComposedCloudScheduleAuthorizer()
        let allowed = await defaultAuthorizer.refusal(for: routine)
        XCTAssertNil(allowed)
        let notEnabled = Routine(id: "r", agentId: "b", title: "t", prompt: "p",
                                 schedule: .interval(everyMinutes: 60, timezone: "UTC"),
                                 enabled: true, createdAt: 0)
        let notEnabledRefusal = await defaultAuthorizer.refusal(for: notEnabled)
        XCTAssertEqual(notEnabledRefusal, .revoked)
    }
}

private actor WiringProbeTransport: CloudScheduleTransport {
    private let clock: @Sendable () -> Int64
    private(set) var syncRequests: [CloudScheduleSyncRequest] = []
    private(set) var receiptRequests: [CloudScheduleReceiptRequest] = []
    private(set) var cancelRoutineRequests: [CloudScheduleCancelRequest] = []
    private(set) var requestCount = 0
    private var forcedError: CloudScheduleTransportError?

    init(clock: @escaping @Sendable () -> Int64) { self.clock = clock }
    func failRequests(with error: CloudScheduleTransportError) { forcedError = error }
    func clearForcedError() { forcedError = nil }
    private func maybeThrow() throws { if let forcedError { throw forcedError } }

    func sync(_ request: CloudScheduleSyncRequest) async throws -> CloudScheduleSyncResponse {
        syncRequests.append(request); requestCount += 1
        try maybeThrow()
        return CloudScheduleSyncResponse(
            serverTimeMS: clock(), accepted: request.registrations,
            removedAccepted: request.removed.map(\.routineID),
            removedRevisions: Dictionary(uniqueKeysWithValues: request.removed.map {
                ($0.routineID, $0.revision + 1)
            }))
    }

    func poll(_ request: CloudSchedulePollRequest) async throws -> CloudSchedulePollResponse {
        requestCount += 1
        try maybeThrow()
        return CloudSchedulePollResponse(serverTimeMS: clock())
    }

    func acknowledge(_ request: CloudScheduleReceiptRequest) async throws -> CloudScheduleReceiptResponse {
        receiptRequests.append(request); requestCount += 1
        try maybeThrow()
        return CloudScheduleReceiptResponse(accepted: true)
    }

    func reconcile(_ request: CloudScheduleReconcileRequest) async throws -> CloudScheduleReconcileResponse {
        requestCount += 1
        try maybeThrow()
        return CloudScheduleReconcileResponse(serverTimeMS: clock())
    }

    func cancelRoutine(_ request: CloudScheduleCancelRequest) async throws {
        cancelRoutineRequests.append(request); requestCount += 1
    }

    func cancelEvent(_ request: CloudScheduleEventCancelRequest) async throws {}
}
