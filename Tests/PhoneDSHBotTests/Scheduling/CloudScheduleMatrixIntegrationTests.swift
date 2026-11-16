// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// A09 real-service matrix against SC's local isolated instance
/// (`evidence/cloud-local-matrix/session.env`). Every test is SKIP without the
/// environment; the scripts in `proposals/` are not evidence by themselves.
final class CloudScheduleMatrixIntegrationTests: XCTestCase {
    private struct Env { var baseURL: URL; var token: String }
    private struct Harness {
        let root: URL
        let machine: RoutineMachine
        let scheduler: RoutineScheduler
        let runs: MatrixRunLog
    }

    private func environment() throws -> Env {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["PDSH_CLOUD_BASE_URL"], let url = URL(string: raw) else {
            throw XCTSkip("PDSH_CLOUD_BASE_URL not set; A09 matrix NOT_RUN")
        }
        guard let token = env["PDSH_CLOUD_TOKEN"], !token.isEmpty else {
            throw XCTSkip("PDSH_CLOUD_TOKEN not set; A09 matrix NOT_RUN")
        }
        return Env(baseURL: url, token: token)
    }

    private func harness() async throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-matrix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"))
        let machine = RoutineMachine(store: SQLiteRoutineStore(domainStore: store))
        let inbox = WakeInbox(store: SQLiteWakeInboxStore(domainStore: store, botId: "bot-matrix"))
        let runs = MatrixRunLog()
        let scheduler = RoutineScheduler(
            botId: "bot-matrix", machine: machine, inbox: inbox,
            sink: MatrixSink(),
            runner: { request in runs.append(request); return .success("matrix result") },
            available: { _ in true },
            settings: { ProactiveSettings(quietStart: "00:00", quietEnd: "00:00", timeZone: "UTC") },
            now: { Int64(Date().timeIntervalSince1970 * 1000) },
            runTimeoutMs: 1_000, cancelGraceMs: 0)
        return Harness(root: root, machine: machine, scheduler: scheduler, runs: runs)
    }

    private func transport(_ env: Env) -> CloudScheduleHTTPTransport {
        CloudScheduleHTTPTransport(
            configuration: .init(baseURL: env.baseURL),
            tokenProvider: { env.token })
    }

    private func makeRoutine(_ h: Harness, id: String) async throws {
        _ = try await h.machine.create(
            botId: "bot-matrix", title: "Matrix routine \(id)", prompt: "matrix only",
            schedule: .interval(everyMinutes: 1, timezone: "UTC"),
            now: Int64(Date().timeIntervalSince1970 * 1000), id: id)
        _ = try await h.machine.setCloudSchedule(
            botId: "bot-matrix", routineId: id, enabled: true,
            authorizationRef: "record://event/1",
            now: Int64(Date().timeIntervalSince1970 * 1000))
    }

    private func register(_ transport: CloudScheduleHTTPTransport, device: String,
                          routineID: String) async throws {
        let registration = CloudScheduleRegistration(
            routineID: routineID, botID: "bot-matrix", revision: 1, enabled: true,
            schedule: .init(kind: .interval, intervalMinutes: 1, timezone: "UTC"),
            catchUp: "latest", authorizationRef: "record://event/1")
        let response = try await transport.sync(.init(
            deviceID: device, botID: "bot-matrix", registrations: [registration]))
        XCTAssertEqual(response.accepted.map(\.routineID), [routineID])
    }

    private func waitDue(_ transport: CloudScheduleHTTPTransport, device: String,
                         timeout: TimeInterval = 75,
                         leaseSeconds: Int = 15) async throws -> CloudScheduleEvent? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let response = try await transport.poll(.init(
                deviceID: device, botID: "bot-matrix",
                limit: 16, leaseSeconds: leaseSeconds))
            if let event = response.events.first { return event }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return nil
    }

    private func acknowledge(_ transport: CloudScheduleHTTPTransport, device: String,
                             event: CloudScheduleEvent, outcome: CloudScheduleOutcome,
                             reason: CloudScheduleReason?, receiptID: String) async throws {
        _ = try await transport.acknowledge(.init(
            deviceID: device, eventID: event.eventID, receiptID: receiptID,
            occurrenceKey: event.occurrenceKey, outcome: outcome, reason: reason,
            completedAtMS: Int64(Date().timeIntervalSince1970 * 1000),
            localRunID: event.localRunID))
    }

    private func delete(_ transport: CloudScheduleHTTPTransport, device: String,
                        routineID: String, revision: Int64 = 1) async {
        try? await transport.cancelRoutine(.init(
            deviceID: device, routineID: routineID, expectedRevision: revision))
    }

    private func makeClient(_ env: Env, _ h: Harness, device: String,
                            leaseSeconds: Int = 5) -> CloudScheduleClient {
        let t = transport(env)
        return CloudScheduleClient(
            botID: "bot-matrix", deviceID: device, transport: t,
            machine: h.machine, scheduler: h.scheduler,
            readiness: { true }, configuration: .init(
                pageLimit: 16, leaseSeconds: leaseSeconds,
                activeIntervalMS: 1_000, leaseStartGuardMS: 0))
    }

    private func pollUntilRun(_ client: CloudScheduleClient, _ h: Harness,
                              timeout: TimeInterval = 30) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let result = await client.pollOnce()
            if case .processed(let count) = result, count > 0, h.runs.count > 0 { return true }
            if h.runs.count > 0 { return true }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return h.runs.count > 0
    }

    func testMatrix3LeaseExpiryReusesOccurrenceWithoutDuplicateRun() async throws {
        let env = try environment()
        let h = try await harness(); defer { try? FileManager.default.removeItem(at: h.root) }
        let device = "dev-matrix3-\(UUID().uuidString.prefix(6))"
        let t = transport(env)
        try await makeRoutine(h, id: "matrix3")
        try await register(t, device: device, routineID: "matrix3")
        let firstDue = try await waitDue(t, device: device, leaseSeconds: 5)
        let first = try XCTUnwrap(firstDue, "no due event for lease-expiry test")
        try await Task.sleep(nanoseconds: 6_000_000_000)
        let client = makeClient(env, h, device: device, leaseSeconds: 5)
        let recovered = await pollUntilRun(client, h)
        XCTAssertTrue(recovered, "client did not recover the expired lease")
        XCTAssertEqual(h.runs.count, 1)
        _ = await client.pollOnce()
        XCTAssertEqual(h.runs.count, 1)
        await delete(t, device: device, routineID: "matrix3",
                     revision: Int64(first.scheduleRevision))
    }

    func testMatrix4ConcurrentPollHasOneLeaseAndLateAckIsTerminal() async throws {
        let env = try environment()
        let h = try await harness(); defer { try? FileManager.default.removeItem(at: h.root) }
        let device = "dev-matrix4-\(UUID().uuidString.prefix(6))"
        let t = transport(env)
        try await makeRoutine(h, id: "matrix4")
        try await register(t, device: device, routineID: "matrix4")
        let firstDue = try await waitDue(t, device: device, leaseSeconds: 15)
        let first = try XCTUnwrap(firstDue, "no due event for concurrent poll test")
        async let a = t.poll(.init(deviceID: device, botID: "bot-matrix",
                                   limit: 16, leaseSeconds: 15))
        async let b = t.poll(.init(deviceID: device, botID: "bot-matrix",
                                   limit: 16, leaseSeconds: 15))
        let (ra, rb) = try await (a, b)
        let concurrent = (ra.events + rb.events).filter { $0.eventID == first.eventID }
        XCTAssertLessThanOrEqual(Set(concurrent.map(\.lease.leaseID)).count, 1,
                                 "an unexpired occurrence must not get a second lease")
        try await acknowledge(t, device: device, event: first, outcome: .delivered,
                              reason: nil, receiptID: "matrix4-r1")
        do {
            try await acknowledge(t, device: device, event: first, outcome: .failed,
                                  reason: .timeout, receiptID: "matrix4-r2")
            XCTFail("a late ACK must not overwrite the terminal receipt")
        } catch let error as CloudScheduleTransportError {
            switch error {
            case .conflict, .invalidRequest: break
            default: XCTFail("unexpected late ACK error: \(error)")
            }
        }
        let after = try await t.poll(.init(deviceID: device, botID: "bot-matrix",
                                           limit: 16, leaseSeconds: 5))
        XCTAssertTrue(after.events.filter { $0.eventID == first.eventID }.isEmpty)
        await delete(t, device: device, routineID: "matrix4",
                     revision: Int64(first.scheduleRevision))
    }

    func testMatrix5OfflineReconnectDeliversOnce() async throws {
        let env = try environment()
        let h = try await harness(); defer { try? FileManager.default.removeItem(at: h.root) }
        let device = "dev-matrix5-\(UUID().uuidString.prefix(6))"
        let t = transport(env)
        try await makeRoutine(h, id: "matrix5")
        try await register(t, device: device, routineID: "matrix5")
        // Stay offline past the due time, then come back with a fresh client.
        try await Task.sleep(nanoseconds: 66_000_000_000)
        let client = makeClient(env, h, device: device)
        let delivered = await pollUntilRun(client, h)
        XCTAssertTrue(delivered, "offline occurrence was not delivered")
        XCTAssertEqual(h.runs.count, 1)
        _ = await client.pollOnce()
        XCTAssertEqual(h.runs.count, 1)
        await delete(t, device: device, routineID: "matrix5")
    }

    func testMatrix6RestartReconcilesLeasedEventWithoutDuplicateRun() async throws {
        let env = try environment()
        let h = try await harness(); defer { try? FileManager.default.removeItem(at: h.root) }
        let device = "dev-matrix6-\(UUID().uuidString.prefix(6))"
        let t = transport(env)
        try await makeRoutine(h, id: "matrix6")
        try await register(t, device: device, routineID: "matrix6")
        let firstDue = try await waitDue(t, device: device, leaseSeconds: 30)
        let first = try XCTUnwrap(firstDue, "no due event for restart test")
        let client = makeClient(env, h, device: device, leaseSeconds: 30)
        let recovered = await pollUntilRun(client, h)
        XCTAssertTrue(recovered, "restart reconcile did not run the leased event")
        XCTAssertEqual(h.runs.count, 1)
        _ = await client.pollOnce()
        XCTAssertEqual(h.runs.count, 1)
        await delete(t, device: device, routineID: "matrix6",
                     revision: Int64(first.scheduleRevision))
    }

    func testMatrix7RevokedScheduleHasNoEventsAndLateAckConflicts() async throws {
        let env = try environment()
        let h = try await harness(); defer { try? FileManager.default.removeItem(at: h.root) }
        let device = "dev-matrix7-\(UUID().uuidString.prefix(6))"
        let t = transport(env)
        try await makeRoutine(h, id: "matrix7")
        try await register(t, device: device, routineID: "matrix7")
        let firstDue = try await waitDue(t, device: device, leaseSeconds: 30)
        let first = try XCTUnwrap(firstDue, "no due event for revoke test")
        await delete(t, device: device, routineID: "matrix7",
                     revision: Int64(first.scheduleRevision))
        do {
            try await acknowledge(t, device: device, event: first, outcome: .delivered,
                                  reason: nil, receiptID: "matrix7-late")
            XCTFail("late ACK after delete must fail")
        } catch let error as CloudScheduleTransportError {
            switch error {
            case .conflict, .invalidRequest: break
            default: XCTFail("unexpected late ACK error: \(error)")
            }
        }
        let after = try await t.poll(.init(deviceID: device, botID: "bot-matrix",
                                           limit: 16, leaseSeconds: 5))
        XCTAssertTrue(after.events.filter { $0.eventID == first.eventID }.isEmpty)
        let client = makeClient(env, h, device: device)
        _ = await client.pollOnce()
        XCTAssertEqual(h.runs.count, 0)
    }

    func testMatrix8UnknownTerminalIsNotRetried() async throws {
        let env = try environment()
        let h = try await harness(); defer { try? FileManager.default.removeItem(at: h.root) }
        let device = "dev-matrix8-\(UUID().uuidString.prefix(6))"
        let t = transport(env)
        try await makeRoutine(h, id: "matrix8")
        try await register(t, device: device, routineID: "matrix8")
        let firstDue = try await waitDue(t, device: device, leaseSeconds: 30)
        let first = try XCTUnwrap(firstDue, "no due event for unknown test")
        try await acknowledge(t, device: device, event: first, outcome: .unknown,
                              reason: .needsReconciliation, receiptID: "matrix8-unknown")
        let after = try await t.poll(.init(deviceID: device, botID: "bot-matrix",
                                           limit: 16, leaseSeconds: 5))
        XCTAssertTrue(after.events.filter { $0.eventID == first.eventID }.isEmpty,
                      "an unknown terminal occurrence must not be re-leased")
        let terminal = try await t.reconcile(.init(
            deviceID: device, sinceMS: 0, limit: 16, includeTerminal: true))
        let row = terminal.events.first { $0.eventID == first.eventID }
        XCTAssertEqual(row?.state, "terminal",
                       "reconcile include_terminal must expose the terminal row")
        let client = makeClient(env, h, device: device)
        _ = await client.pollOnce()
        XCTAssertEqual(h.runs.count, 0)
        await delete(t, device: device, routineID: "matrix8",
                     revision: Int64(first.scheduleRevision))
    }

    /// Requires explicit SC coordination: the test writes a ready marker after
    /// leasing an occurrence, SC kills and restarts the same instance/DB, then
    /// writes a done marker. Gated by `PDSH_CLOUD_RESTART_TEST=1`.
    func testMatrix9ServiceRestartKeepsOccurrenceAndDeliversOnce() async throws {
        let env = try environment()
        guard ProcessInfo.processInfo.environment["PDSH_CLOUD_RESTART_TEST"] == "1" else {
            throw XCTSkip("PDSH_CLOUD_RESTART_TEST not set; kill -9 matrix NOT_RUN")
        }
        let h = try await harness(); defer { try? FileManager.default.removeItem(at: h.root) }
        let device = "dev-matrix9-\(UUID().uuidString.prefix(6))"
        let t = transport(env)
        try await makeRoutine(h, id: "matrix9")
        try await register(t, device: device, routineID: "matrix9")
        let firstDue = try await waitDue(t, device: device, leaseSeconds: 5)
        let first = try XCTUnwrap(firstDue, "no due event for restart matrix")
        let markerDir = ProcessInfo.processInfo.environment["PDSH_CLOUD_RESTART_DIR"]
            ?? "evidence/cloud-local-matrix"
        let ready = URL(fileURLWithPath: markerDir).appendingPathComponent("s-restart-ready")
        let done = URL(fileURLWithPath: markerDir).appendingPathComponent("s-restart-done")
        try? FileManager.default.removeItem(at: done)
        try "\(first.eventID) \(first.occurrenceKey)".write(to: ready, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: ready); try? FileManager.default.removeItem(at: done) }

        // Wait for SC to kill and restart the instance (same DB).
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline, !FileManager.default.fileExists(atPath: done.path) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard FileManager.default.fileExists(atPath: done.path) else {
            XCTFail("SC did not signal the restart within 120s")
            return
        }
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        let client = makeClient(env, h, device: device, leaseSeconds: 5)
        let delivered = await pollUntilRun(client, h, timeout: 45)
        XCTAssertTrue(delivered, "occurrence was not delivered after the service restart")
        XCTAssertEqual(h.runs.count, 1)
        _ = await client.pollOnce()
        XCTAssertEqual(h.runs.count, 1)
        await delete(t, device: device, routineID: "matrix9")
    }
}

private actor MatrixSink: RoutineResultSink {
    func deliver(_ automation: RoutineAutomation) async throws -> Bool { false }
}

private final class MatrixRunLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [RoutineRunRequest] = []
    var count: Int { lock.withLock { values.count } }
    func append(_ request: RoutineRunRequest) { lock.withLock { values.append(request) } }
}
