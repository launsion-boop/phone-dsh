// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Real-client integration against SC's local cloud service. It runs only when
/// both environment variables are present:
///
///   PDSH_CLOUD_BASE_URL=http://127.0.0.1:<port>
///   PDSH_CLOUD_TOKEN=<local test bearer>
///
/// Without them the test is SKIP (never PASS): the unit suite alone cannot
/// prove the two ends agree. E/SC run this with a fixed cloud commit and keep
/// the server log; the test prints the commands and ids it used.
final class CloudScheduleIntegrationTests: XCTestCase {
    private func environment() throws -> (URL, String) {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["PDSH_CLOUD_BASE_URL"], !raw.isEmpty,
              let baseURL = URL(string: raw) else {
            throw XCTSkip("PDSH_CLOUD_BASE_URL not set; local cloud integration NOT_RUN")
        }
        guard let token = env["PDSH_CLOUD_TOKEN"], !token.isEmpty else {
            throw XCTSkip("PDSH_CLOUD_TOKEN not set; local cloud integration NOT_RUN")
        }
        return (baseURL, token)
    }

    func testLocalCloudSyncPollReconcileRoundTrip() async throws {
        let (baseURL, token) = try environment()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"))
        let machine = RoutineMachine(store: SQLiteRoutineStore(domainStore: store))
        let inbox = WakeInbox(store: SQLiteWakeInboxStore(domainStore: store, botId: "bot-integration"))
        let sink = IntegrationRoutineSink()
        let runs = IntegrationRunLog()
        let scheduler = RoutineScheduler(
            botId: "bot-integration", machine: machine, inbox: inbox, sink: sink,
            runner: { request in runs.append(request); return .success("integration result") },
            available: { _ in true }, now: { Int64(Date().timeIntervalSince1970 * 1000) })
        let transport = CloudScheduleHTTPTransport(
            configuration: CloudScheduleHTTPConfiguration(baseURL: baseURL),
            tokenProvider: { token })
        let client = CloudScheduleClient(
            botID: "bot-integration", deviceID: "device-integration-\(UUID().uuidString.prefix(8))",
            transport: transport, machine: machine, scheduler: scheduler,
            readiness: { true },
            configuration: .init())

        _ = try await machine.create(
            botId: "bot-integration", title: "Integration routine", prompt: "integration only",
            schedule: .interval(everyMinutes: 30, timezone: "UTC"),
            now: now - 3_600_000, id: "integration-routine")
        _ = try await machine.setCloudSchedule(
            botId: "bot-integration", routineId: "integration-routine",
            enabled: true, authorizationRef: "record://event/1", now: now)

        let sync = await client.synchronizeNow()
        guard case .synced(let accepted) = sync else {
            return XCTFail("local cloud sync failed: \(sync)")
        }
        XCTAssertGreaterThanOrEqual(accepted, 1)
        let synced = try await machine.get(botId: "bot-integration", routineId: "integration-routine")
        XCTAssertEqual(synced?.cloudSchedule?.enabled, true)

        // An immediate poll may legitimately have no due event; the assertion
        // is that the real HTTP round-trip succeeds (no error result).
        let poll = await client.pollOnce()
        switch poll {
        case .failed(let diagnostic):
            XCTFail("local cloud poll failed: \(diagnostic)")
        default:
            break
        }
        print("cloud integration: device=\(client.deviceID) accepted=\(accepted) poll=\(poll)")

        // Clean up the schedule on the local service so repeated runs stay
        // deterministic (disabled + next sync DELETEs it).
        _ = try await machine.setCloudSchedule(
            botId: "bot-integration", routineId: "integration-routine", enabled: false,
            now: Int64(Date().timeIntervalSince1970 * 1000))
        let cleanup = await client.synchronizeNow()
        XCTAssertEqual(cleanup, .synced(1))
        XCTAssertEqual(runs.count, 0, "a future-scheduled routine must not run during this test")
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
