// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Production lifecycle bridge: a 401 stops requests; only a real credential
/// update (account SDK state) plus foreground re-arms the same client and
/// reconciles/syncs; logout keeps it stopped; another Bot is unaffected.
final class BotCloudScheduleLifecycleTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let machine: RoutineMachine
        let scheduler: RoutineScheduler
        let runs: LifecycleRunLog
        let transport: LifecycleProbeTransport
        let client: CloudScheduleClient
        let lifecycle: BotCloudScheduleLifecycle
    }

    private func fixture(botID: String = "bot-a", device: String,
                         now: Int64) async throws -> Fixture {
        let root = try wp6TempDirectory(self)
        let store = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"))
        let machine = RoutineMachine(store: SQLiteRoutineStore(domainStore: store))
        let inbox = WakeInbox(store: SQLiteWakeInboxStore(domainStore: store, botId: botID))
        let runs = LifecycleRunLog()
        let scheduler = RoutineScheduler(
            botId: botID, machine: machine, inbox: inbox, sink: LifecycleSink(),
            runner: { request in runs.append(request); return .success("ok") },
            available: { _ in true },
            settings: { ProactiveSettings(quietStart: "00:00", quietEnd: "00:00", timeZone: "UTC") },
            now: { now }, runTimeoutMs: 1_000, cancelGraceMs: 0)
        _ = try await machine.create(
            botId: botID, title: "Digest", prompt: "summarize",
            schedule: .interval(everyMinutes: 30, timezone: "UTC"),
            now: now - 3_600_000, id: "digest")
        _ = try await machine.setCloudSchedule(
            botId: botID, routineId: "digest", enabled: true,
            authorizationRef: "record://event/1", now: now)
        let transport = LifecycleProbeTransport(clock: { now })
        let client = CloudScheduleClient(
            botID: botID, deviceID: device, transport: transport,
            machine: machine, scheduler: scheduler, readiness: { true },
            now: { now }, sleep: { _ in },
            configuration: .init(pageLimit: 16, leaseSeconds: 600,
                                 activeIntervalMS: 60_000, leaseStartGuardMS: 0))
        let lifecycle = BotCloudScheduleLifecycle(client: client)
        return Fixture(root: root, machine: machine, scheduler: scheduler, runs: runs,
                       transport: transport, client: client, lifecycle: lifecycle)
    }

    func testUnauthorizedStopsThenCredentialUpdateAndForegroundResume() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try await fixture(device: "device-lifecycle", now: now)
        await f.client.start()
        await f.lifecycle.scenePhaseChanged(false)   // stop the timer loop; drive cycles explicitly

        // 401 on the account's real request path.
        await f.lifecycle.scenePhaseChanged(true)
        let blocked = await f.transport.requestCount
        XCTAssertGreaterThan(blocked, 0)
        _ = await f.client.pollOnce()
        let stillBlocked = await f.transport.requestCount
        XCTAssertEqual(stillBlocked, blocked, "a 401 must not be retried on a timer")

        // Credential update arrives through the live bridge; the next cycle
        // reconciles and syncs without any test-only client reset.
        await f.transport.setCredentialValid(true)
        await f.transport.enqueuePoll(.init(
            serverTimeMS: now,
            events: [CloudScheduleEvent(
                eventID: "evt-lifecycle", deviceID: "device-lifecycle",
                botID: "bot-a", routineID: "digest",
                occurrenceKey: String(repeating: "ab", count: 32),
                occurrenceAtMS: now, scheduledForMS: now,
                scheduleRevision: 1,
                lease: .init(leaseID: "lease-lifecycle", attempt: 1,
                             expiresAtMS: now + 600_000))]))
        await f.lifecycle.credentialsDidChange(signedIn: true)
        let recovered = await f.transport.requestCount
        XCTAssertGreaterThan(recovered, stillBlocked)
        XCTAssertEqual(f.runs.count, 1)
        let receipts = await f.transport.receiptRequests
        XCTAssertEqual(receipts.last?.outcome, .delivered)

        // Logout keeps it stopped even when the App becomes foreground again.
        await f.lifecycle.credentialsDidChange(signedIn: false)
        let signedOut = await f.transport.requestCount
        await f.lifecycle.scenePhaseChanged(true)
        _ = await f.client.pollOnce()
        let afterLogout = await f.transport.requestCount
        XCTAssertEqual(afterLogout, signedOut)
    }

    func testOtherBotIsNotStoppedByOneBotsAuthFailure() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let first = try await fixture(botID: "bot-a", device: "device-a", now: now)
        let second = try await fixture(botID: "bot-b", device: "device-b", now: now)
        await first.client.start()
        await second.client.start()
        await first.lifecycle.scenePhaseChanged(false)
        await second.lifecycle.scenePhaseChanged(false)
        await first.lifecycle.scenePhaseChanged(true)
        let firstBlocked = await first.transport.requestCount
        XCTAssertGreaterThan(firstBlocked, 0)

        await second.transport.setCredentialValid(true)
        await second.transport.enqueuePoll(.init(
            serverTimeMS: now,
            events: [CloudScheduleEvent(
                eventID: "evt-b", deviceID: "device-b", botID: "bot-b", routineID: "digest",
                occurrenceKey: String(repeating: "cd", count: 32),
                occurrenceAtMS: now, scheduledForMS: now, scheduleRevision: 1,
                lease: .init(leaseID: "lease-b", attempt: 1, expiresAtMS: now + 600_000))]))
        await second.lifecycle.credentialsDidChange(signedIn: true)
        await second.lifecycle.scenePhaseChanged(true)
        XCTAssertEqual(second.runs.count, 1)
        let firstAfter = await first.transport.requestCount
        XCTAssertEqual(firstAfter, firstBlocked, "another Bot's auth must not resume this one")
    }
}

private actor LifecycleProbeTransport: CloudScheduleTransport {
    private let clock: @Sendable () -> Int64
    private(set) var requestCount = 0
    private(set) var receiptRequests: [CloudScheduleReceiptRequest] = []
    private var credentialValid = false
    private var pollResponses: [CloudSchedulePollResponse] = []

    init(clock: @escaping @Sendable () -> Int64) { self.clock = clock }
    func setCredentialValid(_ valid: Bool) { credentialValid = valid }
    func enqueuePoll(_ response: CloudSchedulePollResponse) { pollResponses.append(response) }
    private func maybeThrow() throws {
        if !credentialValid { throw CloudScheduleTransportError.unauthenticated }
    }

    func sync(_ request: CloudScheduleSyncRequest) async throws -> CloudScheduleSyncResponse {
        requestCount += 1
        try maybeThrow()
        return CloudScheduleSyncResponse(serverTimeMS: clock(), accepted: request.registrations,
                                         removedAccepted: request.removed.map(\.routineID))
    }
    func poll(_ request: CloudSchedulePollRequest) async throws -> CloudSchedulePollResponse {
        requestCount += 1
        try maybeThrow()
        if pollResponses.isEmpty {
            return CloudSchedulePollResponse(serverTimeMS: clock())
        }
        return pollResponses.removeFirst()
    }
    func acknowledge(_ request: CloudScheduleReceiptRequest) async throws -> CloudScheduleReceiptResponse {
        requestCount += 1
        try maybeThrow()
        receiptRequests.append(request)
        return CloudScheduleReceiptResponse(accepted: true)
    }
    func reconcile(_ request: CloudScheduleReconcileRequest) async throws -> CloudScheduleReconcileResponse {
        requestCount += 1
        try maybeThrow()
        return CloudScheduleReconcileResponse(serverTimeMS: clock())
    }
    func cancelRoutine(_ request: CloudScheduleCancelRequest) async throws { requestCount += 1 }
    func cancelEvent(_ request: CloudScheduleEventCancelRequest) async throws { requestCount += 1 }
}

private actor LifecycleSink: RoutineResultSink {
    func deliver(_ automation: RoutineAutomation) async throws -> Bool { false }
}

private final class LifecycleRunLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [RoutineRunRequest] = []
    var count: Int { lock.withLock { values.count } }
    func append(_ request: RoutineRunRequest) { lock.withLock { values.append(request) } }
}
