// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Drives the cloud scheduler client through a scripted transport and the real
/// `RoutineScheduler`/`RoutineMachine` SQLite store. Every assertion is about
/// persisted routine state or the actual transport calls, never an in-memory
/// fake result.
final class CloudScheduleClientTests: XCTestCase {
    private let occurrenceA = String(repeating: "a1", count: 32)
    private let occurrenceB = String(repeating: "b2", count: 32)

    private struct Fixture {
        let root: URL
        let clock: WP6Clock
        let machine: RoutineMachine
        let inbox: WakeInbox
        let sink: WP6RoutineSink
        let runs: WP6RunLog
        let scheduler: RoutineScheduler
        let transport: CloudScheduleProbeTransport
        let client: CloudScheduleClient
    }

    private func fixture(runner: @escaping RoutineScheduler.Runner = { _ in .success("ok") },
                         ready: WP6Flag = WP6Flag(true),
                         authorizer: any CloudScheduleAuthorizing = CloudScheduleAuthorizer(),
                         at now: Int64) throws -> Fixture {
        let root = try wp6TempDirectory(self)
        let clock = WP6Clock(now)
        let machine = try wp6Machine(root: root)
        let inbox = try wp6Inbox(root: root)
        let sink = WP6RoutineSink()
        let runs = WP6RunLog()
        let scheduler = RoutineScheduler(
            botId: "bot-a", machine: machine, inbox: inbox, sink: sink,
            runner: { request in runs.append(request); return await runner(request) },
            available: { _ in true }, settings: { wp6Settings() }, now: { clock.now })
        let transport = CloudScheduleProbeTransport(clock: { clock.now })
        let client = CloudScheduleClient(
            botID: "bot-a", deviceID: "device-a", transport: transport,
            machine: machine, scheduler: scheduler, authorizer: authorizer,
            readiness: { ready.current }, now: { clock.now },
            sleep: { _ in }, configuration: .init())
        return Fixture(root: root, clock: clock, machine: machine, inbox: inbox, sink: sink,
                       runs: runs, scheduler: scheduler, transport: transport, client: client)
    }

    private func makeRoutine(_ f: Fixture, id: String = "digest",
                             prompt: String = "summarize the inbox",
                             schedule: RoutineSchedule = .interval(everyMinutes: 30, timezone: "UTC"),
                             at now: Int64) async throws {
        _ = try await f.machine.create(
            botId: "bot-a", title: "Daily digest", prompt: prompt,
            schedule: schedule, now: now - 3_600_000, id: id)
        _ = try await f.machine.setCloudSchedule(
            botId: "bot-a", routineId: id, enabled: true,
            authorizationRef: "record://event/1", now: now)
    }

    private func cloudEvent(_ f: Fixture, routineID: String = "digest",
                            occurrenceKey: String, occurrenceAt: Int64,
                            scheduleRevision: Int64,
                            attempt: Int = 1, leaseSeconds: Int64 = 900,
                            eventID: String = "evt-1") -> CloudScheduleEvent {
        CloudScheduleEvent(
            eventID: eventID, deviceID: "device-a", botID: "bot-a", routineID: routineID,
            occurrenceKey: occurrenceKey, occurrenceAtMS: occurrenceAt,
            scheduledForMS: occurrenceAt, scheduleRevision: scheduleRevision,
            lease: CloudScheduleLease(leaseID: "lease-\(eventID)", attempt: attempt,
                                      expiresAtMS: f.clock.now + leaseSeconds * 1000))
    }

    // MARK: - Sync / permission

    func testSyncSendsTimingAndRevisionButNeverRoutineText() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try fixture(at: now)
        try await makeRoutine(f, prompt: "SECRET-PROMPT-TEXT", at: now)
        let outcome = await f.client.synchronizeNow()
        let syncRequests = await f.transport.syncRequests
        let synced = try XCTUnwrap(syncRequests.last)
        guard case .synced(let count) = outcome else {
            return XCTFail("expected sync, got \(outcome)")
        }
        XCTAssertGreaterThanOrEqual(count, 1)
        XCTAssertEqual(synced.deviceID, "device-a")
        XCTAssertEqual(synced.botID, "bot-a")
        let registration = try XCTUnwrap(synced.registrations.first)
        XCTAssertEqual(registration.routineID, "digest")
        XCTAssertGreaterThan(registration.revision, 0)
        XCTAssertEqual(registration.schedule.kind, .interval)
        XCTAssertEqual(registration.schedule.intervalMinutes, 30)
        XCTAssertEqual(registration.schedule.timezone, "UTC")
        XCTAssertEqual(registration.catchUp, "latest")
        XCTAssertEqual(registration.authorizationRef, "record://event/1")
        XCTAssertEqual(registration.operation, "register")
        // The request type has no text field at all; keep the negative
        // assertion on the encoded request so a future refactor cannot leak.
        let encoded = try JSONEncoder().encode(synced)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(json.contains("SECRET-PROMPT-TEXT"))
        XCTAssertFalse(json.contains("Daily digest"))
        XCTAssertFalse(json.lowercased().contains("prompt"))
    }

    func testSyncMarksTheCloudRevisionAndDisableQueuesADelete() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try fixture(at: now)
        try await makeRoutine(f, at: now)
        let fetched_before = try await f.machine.get(botId: "bot-a", routineId: "digest")
        let before = try XCTUnwrap(fetched_before)
        XCTAssertEqual(before.cloudSchedule?.enabled, true)
        let firstRevision = try XCTUnwrap(before.cloudSchedule?.seq)

        _ = await f.client.synchronizeNow()
        let syncRequests = await f.transport.syncRequests
        let first = try XCTUnwrap(syncRequests.last)
        XCTAssertEqual(first.registrations.first?.revision, firstRevision)
        XCTAssertEqual(first.registrations.first?.operation, "register")

        _ = try await f.machine.setCloudSchedule(botId: "bot-a", routineId: "digest",
                                                 enabled: false, now: now + 1)
        let fetched_revoked = try await f.machine.get(botId: "bot-a", routineId: "digest")
        let revoked = try XCTUnwrap(fetched_revoked)
        XCTAssertGreaterThan(try XCTUnwrap(revoked.cloudSchedule?.seq), firstRevision)
        _ = await f.client.synchronizeNow()
        let afterRevoke = await f.transport.syncRequests
        let deleted = try XCTUnwrap(afterRevoke.last)
        XCTAssertEqual(deleted.removed.map(\.routineID), ["digest"])
    }

    // MARK: - Run / receipt

    func testPollRunsOneOccurrenceAndAcknowledgesIt() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try fixture(at: now)
        try await makeRoutine(f, at: now)
        _ = await f.client.synchronizeNow()
        let fetched_routine = try await f.machine.get(botId: "bot-a", routineId: "digest")
        let routine = try XCTUnwrap(fetched_routine)
        let revision = try XCTUnwrap(routine.cloudSchedule?.seq)
        let slot = try XCTUnwrap(routine.nextRunAt)
        await f.transport.enqueuePoll(.init(
            serverTimeMS: f.clock.now,
            events: [cloudEvent(f, occurrenceKey: occurrenceA, occurrenceAt: slot,
                                scheduleRevision: revision)]))

        let result = await f.client.pollOnce()
        XCTAssertEqual(result, .processed(1))
        XCTAssertEqual(f.runs.count, 1)
        XCTAssertEqual(f.runs.all.first?.runId,
                       RoutineScheduler.cloudRunId(occurrenceKey: occurrenceA))
        let receiptRequests = await f.transport.receiptRequests
        let receipt = try XCTUnwrap(receiptRequests.last)
        XCTAssertEqual(receipt.outcome, .delivered)
        XCTAssertNil(receipt.reason)
        XCTAssertEqual(receipt.occurrenceKey, occurrenceA)
        XCTAssertEqual(receipt.localRunID, "cloud-\(occurrenceA)")
        XCTAssertEqual(receipt.receiptID,
                       CloudScheduleClient.receiptID(eventID: "evt-1", occurrenceKey: occurrenceA))
        await WP6AssertEqual(await f.sink.rows.count, 1)
    }

    func testDuplicateDeliveryDoesNotExecuteTwice() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try fixture(at: now)
        try await makeRoutine(f, at: now)
        _ = await f.client.synchronizeNow()
        let fetched_routine = try await f.machine.get(botId: "bot-a", routineId: "digest")
        let routine = try XCTUnwrap(fetched_routine)
        let slot = try XCTUnwrap(routine.nextRunAt)
        let revision = try XCTUnwrap(routine.cloudSchedule?.seq)
        let event = cloudEvent(f, occurrenceKey: occurrenceA, occurrenceAt: slot,
                               scheduleRevision: revision)
        await f.transport.enqueuePoll(.init(serverTimeMS: f.clock.now, events: [event]))
        await f.transport.enqueuePoll(.init(serverTimeMS: f.clock.now, events: [event]))

        _ = await f.client.pollOnce()
        _ = await f.client.pollOnce()
        XCTAssertEqual(f.runs.count, 1)
        let receiptRequests = await f.transport.receiptRequests
        XCTAssertEqual(receiptRequests.count, 2)
        XCTAssertEqual(receiptRequests.map(\.receiptID).first,
                       receiptRequests.map(\.receiptID).last)
        XCTAssertNil(receiptRequests.last?.reason)
    }

    func testOlderPendingOccurrencesAreCoalesced() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try fixture(at: now)
        try await makeRoutine(f, at: now)
        _ = await f.client.synchronizeNow()
        let fetched_routine = try await f.machine.get(botId: "bot-a", routineId: "digest")
        let routine = try XCTUnwrap(fetched_routine)
        let revision = try XCTUnwrap(routine.cloudSchedule?.seq)
        let older = cloudEvent(f, occurrenceKey: occurrenceA, occurrenceAt: now - 3_600_000,
                               scheduleRevision: revision, eventID: "evt-old")
        let newer = cloudEvent(f, occurrenceKey: occurrenceB, occurrenceAt: now,
                               scheduleRevision: revision, eventID: "evt-new")
        await f.transport.enqueuePoll(.init(serverTimeMS: f.clock.now, events: [newer, older]))

        let result = await f.client.pollOnce()
        XCTAssertEqual(result, .processed(2))
        XCTAssertEqual(f.runs.count, 1)
        XCTAssertEqual(f.runs.all.first?.runId,
                       RoutineScheduler.cloudRunId(occurrenceKey: occurrenceB))
        let receipts = await f.transport.receiptRequests
        XCTAssertEqual(receipts.count, 2)
        XCTAssertEqual(receipts.first { $0.eventID == "evt-old" }?.outcome, .skipped)
        XCTAssertEqual(receipts.first { $0.eventID == "evt-old" }?.reason, .superseded)
        XCTAssertEqual(receipts.first { $0.eventID == "evt-new" }?.outcome, .delivered)
    }

    func testLostAckIsRetriedWithTheSameReceiptAndNeverReruns() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try fixture(at: now)
        try await makeRoutine(f, at: now)
        _ = await f.client.synchronizeNow()
        let fetched_routine = try await f.machine.get(botId: "bot-a", routineId: "digest")
        let routine = try XCTUnwrap(fetched_routine)
        let slot = try XCTUnwrap(routine.nextRunAt)
        let revision = try XCTUnwrap(routine.cloudSchedule?.seq)
        let event = cloudEvent(f, occurrenceKey: occurrenceA, occurrenceAt: slot,
                               scheduleRevision: revision)
        await f.transport.enqueuePoll(.init(serverTimeMS: f.clock.now, events: [event]))
        await f.transport.failNextAcks(1)
        let first = await f.client.pollOnce()
        XCTAssertEqual(first, .failed("transport"))
        XCTAssertEqual(f.runs.count, 1)
        var receiptRequests = await f.transport.receiptRequests
        XCTAssertEqual(receiptRequests.count, 1)

        await f.transport.enqueuePoll(.init(serverTimeMS: f.clock.now, events: [event]))
        let second = await f.client.pollOnce()
        XCTAssertEqual(second, .processed(1))
        XCTAssertEqual(f.runs.count, 1)
        receiptRequests = await f.transport.receiptRequests
        XCTAssertEqual(receiptRequests.count, 2)
        XCTAssertEqual(receiptRequests[0].receiptID, receiptRequests[1].receiptID)
    }

    // MARK: - Unknown outcome / recovery

    func testReconcileReportsUnknownAfterACrashInsteadOfReplaying() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try fixture(at: now)
        try await makeRoutine(f, at: now)
        let fetched_routine = try await f.machine.get(botId: "bot-a", routineId: "digest")
        let routine = try XCTUnwrap(fetched_routine)
        let slot = try XCTUnwrap(routine.nextRunAt)
        let revision = try XCTUnwrap(routine.cloudSchedule?.seq)
        // The previous process died after `begin`; recovery must not replay a
        // non-idempotent run.
        _ = try await f.machine.begin(
            botId: "bot-a", routineId: "digest", startedAt: now, scheduledFor: slot,
            leaseOwner: "local", leaseTTLMs: 1_000,
            runId: RoutineScheduler.cloudRunId(occurrenceKey: occurrenceA))
        // Let the previous process's run lease expire, then recover: a
        // non-idempotent attempt becomes needs-reconciliation, never a replay.
        f.clock.set(now + 2_000)
        _ = try await f.scheduler.recover()
        await f.transport.enqueueReconcile(.init(
            serverTimeMS: f.clock.now,
            events: [cloudEvent(f, occurrenceKey: occurrenceA, occurrenceAt: slot,
                                scheduleRevision: revision, attempt: 2)],
            nextCursorMS: now))

        let result = await f.client.pollOnce()
        XCTAssertEqual(result, .processed(1))
        XCTAssertEqual(f.runs.count, 0)
        let receiptRequests = await f.transport.receiptRequests
        let receipt = try XCTUnwrap(receiptRequests.last)
        XCTAssertEqual(receipt.outcome, .unknown)
        XCTAssertEqual(receipt.reason, .needsReconciliation)
        XCTAssertEqual(receipt.occurrenceKey, occurrenceA)
    }

    func testNotReadyNeverConsumesAPollLease() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let ready = WP6Flag(false)
        let f = try fixture(ready: ready, at: now)
        try await makeRoutine(f, at: now)
        await f.transport.enqueuePoll(.init(serverTimeMS: f.clock.now, events: []))

        let notReady = await f.client.pollOnce()
        XCTAssertEqual(notReady, .notReady)
        let notReadyPolls = await f.transport.pollRequests
        XCTAssertTrue(notReadyPolls.isEmpty)

        ready.set(true)
        _ = await f.client.pollOnce()
        let readyPolls = await f.transport.pollRequests
        XCTAssertEqual(readyPolls.count, 1)
    }

    func testRevokedAuthorizationCancelsTheScheduleWithoutARun() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try fixture(authorizer: StaticCloudAuthorizer(reason: .revoked), at: now)
        try await makeRoutine(f, at: now)
        let fetched_routine = try await f.machine.get(botId: "bot-a", routineId: "digest")
        let routine = try XCTUnwrap(fetched_routine)
        let slot = try XCTUnwrap(routine.nextRunAt)
        await f.transport.enqueuePoll(.init(
            serverTimeMS: f.clock.now,
            events: [cloudEvent(f, occurrenceKey: occurrenceA, occurrenceAt: slot,
                                scheduleRevision: try XCTUnwrap(routine.cloudSchedule?.seq))]))

        let result = await f.client.pollOnce()
        XCTAssertEqual(result, .processed(1))
        XCTAssertEqual(f.runs.count, 0)
        let receipts = await f.transport.receiptRequests
        XCTAssertEqual(receipts.last?.outcome, .skipped)
        XCTAssertEqual(receipts.last?.reason, .revoked)
        let cancelled = await f.transport.cancelRoutineRequests
        XCTAssertEqual(cancelled.map(\.routineID), ["digest"])
    }

    func testOrdinaryRunFailureUsesTheFrozenRunFailedReason() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try fixture(runner: { _ in .failure("tool unavailable") }, at: now)
        try await makeRoutine(f, at: now)
        _ = await f.client.synchronizeNow()
        let fetched_routine = try await f.machine.get(botId: "bot-a", routineId: "digest")
        let routine = try XCTUnwrap(fetched_routine)
        let slot = try XCTUnwrap(routine.nextRunAt)
        await f.transport.enqueuePoll(.init(
            serverTimeMS: f.clock.now,
            events: [cloudEvent(f, occurrenceKey: occurrenceA, occurrenceAt: slot,
                                scheduleRevision: try XCTUnwrap(routine.cloudSchedule?.seq))]))
        let result = await f.client.pollOnce()
        XCTAssertEqual(result, .processed(1))
        let receipts = await f.transport.receiptRequests
        XCTAssertEqual(receipts.last?.outcome, .failed)
        XCTAssertEqual(receipts.last?.reason, .runFailed)
    }

    func testStaleScheduleRevisionIsSkipped() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try fixture(at: now)
        try await makeRoutine(f, at: now)
        let fetched_routine = try await f.machine.get(botId: "bot-a", routineId: "digest")
        let routine = try XCTUnwrap(fetched_routine)
        let slot = try XCTUnwrap(routine.nextRunAt)
        let stale = try XCTUnwrap(routine.cloudSchedule?.seq) - 1
        await f.transport.enqueuePoll(.init(
            serverTimeMS: f.clock.now,
            events: [cloudEvent(f, occurrenceKey: occurrenceA, occurrenceAt: slot,
                                scheduleRevision: stale)]))
        let result = await f.client.pollOnce()
        XCTAssertEqual(result, .processed(1))
        XCTAssertEqual(f.runs.count, 0)
        let receipts = await f.transport.receiptRequests
        XCTAssertEqual(receipts.last?.outcome, .skipped)
        XCTAssertEqual(receipts.last?.reason, .revoked)
    }

    func testTooShortLeaseDoesNotStartOrAcknowledgeARun() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try fixture(at: now)
        try await makeRoutine(f, at: now)
        let fetched_routine = try await f.machine.get(botId: "bot-a", routineId: "digest")
        let routine = try XCTUnwrap(fetched_routine)
        let slot = try XCTUnwrap(routine.nextRunAt)
        await f.transport.enqueuePoll(.init(
            serverTimeMS: f.clock.now,
            events: [cloudEvent(f, occurrenceKey: occurrenceA, occurrenceAt: slot,
                                scheduleRevision: try XCTUnwrap(routine.cloudSchedule?.seq),
                                leaseSeconds: 30)]))
        let result = await f.client.pollOnce()
        XCTAssertEqual(result, .leaseTooShort)
        XCTAssertEqual(f.runs.count, 0)
        let receipts = await f.transport.receiptRequests
        XCTAssertTrue(receipts.isEmpty)
    }

    func testUnknownRoutineEventIsRefusedAndCancelled() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try fixture(at: now)
        await f.transport.enqueuePoll(.init(
            serverTimeMS: f.clock.now,
            events: [cloudEvent(f, routineID: "deleted-routine", occurrenceKey: occurrenceA,
                                occurrenceAt: now, scheduleRevision: 1)]))
        let result = await f.client.pollOnce()
        XCTAssertEqual(result, .processed(1))
        let receipts = await f.transport.receiptRequests
        XCTAssertEqual(receipts.last?.outcome, .skipped)
        XCTAssertEqual(receipts.last?.reason, .disabled)
        let cancelled = await f.transport.cancelRoutineRequests
        XCTAssertEqual(cancelled.map(\.routineID), ["deleted-routine"])
    }

    // MARK: - Revision contract on the routine record

    func testCloudScheduleRevisionBumpsOnScheduleChangeAndEnableToggle() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try fixture(at: now)
        _ = try await f.machine.create(
            botId: "bot-a", title: "Digest", prompt: "summarize",
            schedule: .interval(everyMinutes: 30, timezone: "UTC"),
            now: now - 3_600_000, id: "digest")
        let granted = try await f.machine.setCloudSchedule(
            botId: "bot-a", routineId: "digest", enabled: true,
            authorizationRef: "record://event/2", now: now)
        let firstSeq = try XCTUnwrap(granted.cloudSchedule?.seq)
        XCTAssertEqual(granted.cloudSchedule?.authorizationRef, "record://event/2")

        let updated = try await f.machine.update(
            botId: "bot-a", routineId: "digest",
            patch: RoutinePatch(schedule: .interval(everyMinutes: 60, timezone: "UTC")),
            now: now + 1)
        XCTAssertGreaterThan(try XCTUnwrap(updated.cloudSchedule?.seq), firstSeq)

        let disabled = try await f.machine.setCloudSchedule(
            botId: "bot-a", routineId: "digest", enabled: false, now: now + 2)
        XCTAssertEqual(disabled.cloudSchedule?.enabled, false)
        XCTAssertGreaterThan(try XCTUnwrap(disabled.cloudSchedule?.seq),
                             try XCTUnwrap(updated.cloudSchedule?.seq))
    }

    func testPhasedRoutineIsNotRegisteredAndStaysLocal() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try fixture(at: now)
        _ = try await f.machine.create(
            botId: "bot-a", title: "Phased", prompt: "summarize",
            schedule: .interval(everyMinutes: 60, phaseMinutes: 15, timezone: "UTC"),
            now: now - 3_600_000, id: "phased")
        _ = try await f.machine.setCloudSchedule(
            botId: "bot-a", routineId: "phased", enabled: true,
            authorizationRef: "record://event/3", now: now)
        _ = await f.client.synchronizeNow()
        let requests = await f.transport.syncRequests
        XCTAssertTrue(requests.flatMap(\.registrations).isEmpty)
        let fetched_phased = try await f.machine.get(botId: "bot-a", routineId: "phased")
        let routine = try XCTUnwrap(fetched_phased)
        XCTAssertEqual(routine.cloudSchedule?.enabled, true)
    }

    func testAuthorizationReferenceMustBeARecordReference() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try fixture(at: now)
        _ = try await f.machine.create(
            botId: "bot-a", title: "Digest", prompt: "summarize",
            schedule: .interval(everyMinutes: 30, timezone: "UTC"),
            now: now - 3_600_000, id: "digest")
        do {
            _ = try await f.machine.setCloudSchedule(
                botId: "bot-a", routineId: "digest", enabled: true,
                authorizationRef: "not-a-record", now: now)
            XCTFail("expected invalid authorization reference")
        } catch let error as RoutineError {
            guard case .invalidRoutine = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let fetched_routine = try await f.machine.get(botId: "bot-a", routineId: "digest")
        let routine = try XCTUnwrap(fetched_routine)
        XCTAssertNil(routine.cloudSchedule)
    }

    func testReceiptIDIsStableAndOccurrenceScoped() {
        XCTAssertEqual(CloudScheduleClient.receiptID(eventID: "evt-1", occurrenceKey: occurrenceA),
                       CloudScheduleClient.receiptID(eventID: "evt-1", occurrenceKey: occurrenceA))
        XCTAssertNotEqual(CloudScheduleClient.receiptID(eventID: "evt-1", occurrenceKey: occurrenceA),
                          CloudScheduleClient.receiptID(eventID: "evt-1", occurrenceKey: occurrenceB))
        XCTAssertTrue(CloudScheduleClient.receiptID(eventID: "evt-1", occurrenceKey: occurrenceA)
            .hasPrefix("r-"))
    }
}

private struct StaticCloudAuthorizer: CloudScheduleAuthorizing {
    let reason: CloudScheduleReason?
    func refusal(for routine: Routine) async -> CloudScheduleReason? { reason }
}

/// Scripted transport: returns queued responses and records every request so a
/// test can assert exactly what crossed the client/cloud boundary.
actor CloudScheduleProbeTransport: CloudScheduleTransport {
    private let clock: @Sendable () -> Int64
    private(set) var syncRequests: [CloudScheduleSyncRequest] = []
    private(set) var pollRequests: [CloudSchedulePollRequest] = []
    private(set) var receiptRequests: [CloudScheduleReceiptRequest] = []
    private(set) var reconcileRequests: [CloudScheduleReconcileRequest] = []
    private(set) var cancelRoutineRequests: [CloudScheduleCancelRequest] = []
    private(set) var cancelEventRequests: [CloudScheduleEventCancelRequest] = []
    private var pollResponses: [CloudSchedulePollResponse] = []
    private var reconcileResponses: [CloudScheduleReconcileResponse] = []
    private var ackFailuresRemaining = 0

    init(clock: @escaping @Sendable () -> Int64) {
        self.clock = clock
    }

    func enqueuePoll(_ response: CloudSchedulePollResponse) { pollResponses.append(response) }
    func enqueueReconcile(_ response: CloudScheduleReconcileResponse) {
        reconcileResponses.append(response)
    }
    func failNextAcks(_ count: Int) { ackFailuresRemaining += max(0, count) }

    func sync(_ request: CloudScheduleSyncRequest) async throws -> CloudScheduleSyncResponse {
        syncRequests.append(request)
        return CloudScheduleSyncResponse(
            serverTimeMS: clock(),
            accepted: request.registrations,
            removedAccepted: request.removed.map(\.routineID))
    }

    func poll(_ request: CloudSchedulePollRequest) async throws -> CloudSchedulePollResponse {
        pollRequests.append(request)
        if pollResponses.isEmpty {
            return CloudSchedulePollResponse(serverTimeMS: clock())
        }
        return pollResponses.removeFirst()
    }

    func acknowledge(_ request: CloudScheduleReceiptRequest) async throws -> CloudScheduleReceiptResponse {
        receiptRequests.append(request)
        if ackFailuresRemaining > 0 {
            ackFailuresRemaining -= 1
            throw CloudScheduleTransportError.transport("ack lost")
        }
        return CloudScheduleReceiptResponse(accepted: true)
    }

    func reconcile(_ request: CloudScheduleReconcileRequest) async throws -> CloudScheduleReconcileResponse {
        reconcileRequests.append(request)
        if reconcileResponses.isEmpty {
            return CloudScheduleReconcileResponse(serverTimeMS: clock())
        }
        return reconcileResponses.removeFirst()
    }

    func cancelRoutine(_ request: CloudScheduleCancelRequest) async throws {
        cancelRoutineRequests.append(request)
    }

    func cancelEvent(_ request: CloudScheduleEventCancelRequest) async throws {
        cancelEventRequests.append(request)
    }
}
