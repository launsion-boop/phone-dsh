// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Real-client integration against SC's short-lived local cloud service
/// (`PDSH_CLOUD_BASE_URL` + `PDSH_CLOUD_TOKEN` from
/// `evidence/cloud-local/session.env`). Without both variables every test is
/// SKIP (never PASS): the unit suite alone cannot prove the two ends agree.
///
/// The schedules below are registered with `interval=1`, so the cloud
/// materializes a due occurrence within ~60 s; an old routine whose local
/// next-run is already in the past does not imply a cloud wake (the frozen
/// anchor is the registration time).
final class CloudScheduleIntegrationTests: XCTestCase {
    private struct Env {
        var baseURL: URL
        var token: String
    }

    private func environment() throws -> Env {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["PDSH_CLOUD_BASE_URL"], !raw.isEmpty,
              let baseURL = URL(string: raw) else {
            throw XCTSkip("PDSH_CLOUD_BASE_URL not set; local cloud integration NOT_RUN")
        }
        guard let token = env["PDSH_CLOUD_TOKEN"], !token.isEmpty else {
            throw XCTSkip("PDSH_CLOUD_TOKEN not set; local cloud integration NOT_RUN")
        }
        return Env(baseURL: baseURL, token: token)
    }

    private struct Fixture {
        let root: URL
        let store: SQLiteDomainStore
        let machine: RoutineMachine
        let inbox: WakeInbox
        let scheduler: RoutineScheduler
        let runs: IntegrationRunLog
    }

    private func makeFixture(now: Int64) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"))
        let machine = RoutineMachine(store: SQLiteRoutineStore(domainStore: store))
        let inbox = WakeInbox(store: SQLiteWakeInboxStore(domainStore: store, botId: "bot-integration"))
        let sink = IntegrationRoutineSink()
        let runs = IntegrationRunLog()
        let scheduler = RoutineScheduler(
            botId: "bot-integration", machine: machine, inbox: inbox, sink: sink,
            runner: { request in runs.append(request); return .success("integration result") },
            available: { _ in true }, now: { Int64(Date().timeIntervalSince1970 * 1000) },
            runTimeoutMs: 5_000, cancelGraceMs: 0)
        return Fixture(root: root, store: store, machine: machine, inbox: inbox,
                       scheduler: scheduler, runs: runs)
    }

    private func register(_ fixture: Fixture, now: Int64, routineID: String) async throws {
        _ = try await fixture.machine.create(
            botId: "bot-integration", title: "Integration routine", prompt: "integration only",
            schedule: .interval(everyMinutes: 1, timezone: "UTC"),
            now: now, id: routineID)
        _ = try await fixture.machine.setCloudSchedule(
            botId: "bot-integration", routineId: routineID, enabled: true,
            authorizationRef: "record://event/1", now: now)
    }

    private func makeCloudClient(transport: any CloudScheduleTransport,
                                 fixture: Fixture) -> CloudScheduleClient {
        CloudScheduleClient(
            botID: "bot-integration",
            deviceID: "device-integration-\(UUID().uuidString.prefix(8))",
            transport: transport, machine: fixture.machine, scheduler: fixture.scheduler,
            readiness: { true },
            configuration: .init(pageLimit: 16, leaseSeconds: 20,
                                 activeIntervalMS: 1_000, leaseStartGuardMS: 0))
    }

    /// Polls the real service until one occurrence is processed, or the due
    /// window (75 s) expires. `interval=1` is the frozen anchor: registration
    /// time + 1 minute.
    private func waitForProcessed(_ client: CloudScheduleClient,
                                  timeout: TimeInterval = 75) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let result = await client.pollOnce()
            if case .processed(let count) = result, count > 0 { return true }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return false
    }

    private func cleanup(_ fixture: Fixture, routineID: String) async {
        _ = try? await fixture.machine.setCloudSchedule(
            botId: "bot-integration", routineId: routineID, enabled: false,
            now: Int64(Date().timeIntervalSince1970 * 1000))
    }

    func testLocalCloudDueLeaseReceiptRoundTrip() async throws {
        let env = try environment()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let fixture = try await makeFixture(now: now)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await register(fixture, now: now, routineID: "integration-due")
        let transport = RecordingCloudSchedulerTransport(
            base: CloudScheduleHTTPTransport(
                configuration: .init(baseURL: env.baseURL), tokenProvider: { env.token }))
        let client = makeCloudClient(transport: transport, fixture: fixture)

        let sync = await client.synchronizeNow()
        XCTAssertEqual(sync, .synced(1), "real cloud registration failed: \(sync)")
        let processed = await waitForProcessed(client)
        XCTAssertTrue(processed, "cloud did not materialize a due occurrence within 75s")
        XCTAssertEqual(fixture.runs.count, 1)
        let receipts = await transport.receipts
        XCTAssertEqual(receipts.last?.outcome, .delivered)
        XCTAssertNil(receipts.last?.reason)
        XCTAssertEqual(receipts.last?.localRunID,
                       "cloud-" + (receipts.last?.occurrenceKey ?? ""))
        await cleanup(fixture, routineID: "integration-due")
        let cleanupResult = await client.synchronizeNow()
        XCTAssertEqual(cleanupResult, .synced(1), "real cloud delete failed: \(cleanupResult)")
        print("cloud due integration: device=\(client.deviceID) sync=\(sync) receipts=\(receipts.count)")
    }

    func testLocalCloudLostAckRetriesTheSameReceiptWithoutRerun() async throws {
        let env = try environment()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let fixture = try await makeFixture(now: now)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await register(fixture, now: now, routineID: "integration-ack-loss")
        let transport = LosingAckCloudSchedulerTransport(
            base: CloudScheduleHTTPTransport(
                configuration: .init(baseURL: env.baseURL), tokenProvider: { env.token }))
        let client = makeCloudClient(transport: transport, fixture: fixture)
        _ = await client.synchronizeNow()

        let processed = await waitForProcessed(client)
        XCTAssertTrue(processed, "cloud did not materialize a due occurrence within 75s")
        // The runner runs once; the first ACK response is lost after the
        // server recorded it, the client retries the SAME receipt id and must
        // observe duplicate=true instead of running again.
        XCTAssertEqual(fixture.runs.count, 1)
        let responses = await transport.ackResponses
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses.first?.duplicate, true)
        let receipts = await transport.receipts
        XCTAssertEqual(receipts.count, 2, "one sent receipt plus one retry with the same id")
        XCTAssertEqual(receipts[0].receiptID, receipts[1].receiptID)

        await cleanup(fixture, routineID: "integration-ack-loss")
        _ = await client.synchronizeNow()
        print("cloud ack-loss integration: device=\(client.deviceID) duplicate=\(responses.first?.duplicate ?? false)")
    }
}

private actor IntegrationRoutineSink: RoutineResultSink {
    private(set) var rows: [RoutineAutomation] = []
    func deliver(_ automation: RoutineAutomation) async throws -> Bool {
        rows.append(automation)
        return false
    }
}

private final class IntegrationRunLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [RoutineRunRequest] = []
    var count: Int { lock.withLock { values.count } }
    func append(_ request: RoutineRunRequest) { lock.withLock { values.append(request) } }
}

/// Forwards to the real transport and records the receipts the client sent.
private actor RecordingCloudSchedulerTransport: CloudScheduleTransport {
    private let base: any CloudScheduleTransport
    private(set) var receipts: [CloudScheduleReceiptRequest] = []

    init(base: any CloudScheduleTransport) { self.base = base }

    func sync(_ request: CloudScheduleSyncRequest) async throws -> CloudScheduleSyncResponse {
        try await base.sync(request)
    }

    func poll(_ request: CloudSchedulePollRequest) async throws -> CloudSchedulePollResponse {
        try await base.poll(request)
    }

    func acknowledge(_ request: CloudScheduleReceiptRequest) async throws -> CloudScheduleReceiptResponse {
        receipts.append(request)
        return try await base.acknowledge(request)
    }

    func reconcile(_ request: CloudScheduleReconcileRequest) async throws -> CloudScheduleReconcileResponse {
        try await base.reconcile(request)
    }

    func cancelRoutine(_ request: CloudScheduleCancelRequest) async throws {
        try await base.cancelRoutine(request)
    }

    func cancelEvent(_ request: CloudScheduleEventCancelRequest) async throws {
        try await base.cancelEvent(request)
    }
}

/// Sends the first receipt to the real service, then throws as if its response
/// was lost. The client retries the same receipt id; the server answers
/// `duplicate=true`.
private actor LosingAckCloudSchedulerTransport: CloudScheduleTransport {
    private let base: any CloudScheduleTransport
    private var loseNextAckResponse = true
    private(set) var receipts: [CloudScheduleReceiptRequest] = []
    private(set) var ackResponses: [CloudScheduleReceiptResponse] = []

    init(base: any CloudScheduleTransport) { self.base = base }

    func sync(_ request: CloudScheduleSyncRequest) async throws -> CloudScheduleSyncResponse {
        try await base.sync(request)
    }

    func poll(_ request: CloudSchedulePollRequest) async throws -> CloudSchedulePollResponse {
        try await base.poll(request)
    }

    func acknowledge(_ request: CloudScheduleReceiptRequest) async throws -> CloudScheduleReceiptResponse {
        receipts.append(request)
        if loseNextAckResponse {
            loseNextAckResponse = false
            _ = try await base.acknowledge(request)
            throw CloudScheduleTransportError.transport("simulated lost ack response")
        }
        let response = try await base.acknowledge(request)
        ackResponses.append(response)
        return response
    }

    func reconcile(_ request: CloudScheduleReconcileRequest) async throws -> CloudScheduleReconcileResponse {
        try await base.reconcile(request)
    }

    func cancelRoutine(_ request: CloudScheduleCancelRequest) async throws {
        try await base.cancelRoutine(request)
    }

    func cancelEvent(_ request: CloudScheduleEventCancelRequest) async throws {
        try await base.cancelEvent(request)
    }
}
