// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Root ruling: recheck the independent cloud opt-in + authorization_ref before
/// execution; consult a source only when the routine's own persisted derivation
/// names a real context observation; never pull F suppression into scheduling.
final class BotCloudScheduleAuthorizationTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let store: SQLiteDomainStore
        let machine: RoutineMachine
        let solver: BotCloudAuthorizationResolver
    }

    private func fixture(at now: Int64) async throws -> Fixture {
        let root = try wp6TempDirectory(self)
        let store = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"))
        let machine = RoutineMachine(store: SQLiteRoutineStore(domainStore: store))
        let resolver = BotCloudAuthorizationResolver(store: store)
        _ = try await machine.create(
            botId: "bot-a", title: "Digest", prompt: "summarize",
            schedule: .interval(everyMinutes: 30, timezone: "UTC"),
            now: now - 3_600_000, id: "digest")
        return Fixture(root: root, store: store, machine: machine, solver: resolver)
    }

    private func appendContextObservation(_ f: Fixture, source: String) async throws -> String {
        let seq = try await f.store.append(BotEvent(
            type: "context.observed",
            eventId: "context-observed:\(source):\(UUID().uuidString)",
            time: 1_000, origin: .local(source: "runtime"),
            traceId: "trace-context-\(source)",
            principal: BotPrincipal(botId: "bot-a", sessionId: nil, kind: "proactive"),
            causationId: nil, correlationId: source, ignorable: true,
            data: .object(["schemaVersion": .number(1), "source": .string(source)])))
        return "record://event/\(seq)"
    }

    func testMissingOrErasedAuthorizationRefIsRefused() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try await fixture(at: now)
        let granted = try await f.machine.setCloudSchedule(
            botId: "bot-a", routineId: "digest", enabled: true,
            authorizationRef: "record://event/999999", now: now)
        let unresolvedRef = try XCTUnwrap(granted.cloudSchedule?.authorizationRef)
        let initial = await f.solver.state(of: unresolvedRef)
        XCTAssertEqual(initial, .unresolved)

        let dummySeq = try await f.store.append(BotEvent(
            type: "ui.system_event", eventId: "dummy-grant", time: 1_000,
            origin: .local(source: "user"), traceId: "trace-dummy",
            principal: BotPrincipal(botId: "bot-a", sessionId: nil, kind: "chat"),
            causationId: nil, correlationId: nil,
            data: .object(["event": .string("dummy")])))
        let ref = "record://event/\(dummySeq)"
        _ = try await f.machine.setCloudSchedule(
            botId: "bot-a", routineId: "digest", enabled: true,
            authorizationRef: ref, now: now + 1)
        let valid = await f.solver.state(of: ref)
        XCTAssertEqual(valid, .valid)

        let seq = try await f.store.append(BotEvent(
            type: "erasure", eventId: "erasure-test", time: 2_000,
            origin: .local(source: "runtime"), traceId: "trace-erasure-test",
            principal: BotPrincipal(botId: "bot-a", sessionId: nil, kind: "proactive"),
            causationId: nil, correlationId: nil,
            data: .object([
                "erasedEvents": .array([.object(["record": .string(ref)])]),
            ])))
        XCTAssertGreaterThan(seq, 0)
        let erased = await f.solver.state(of: ref)
        XCTAssertEqual(erased, .erased)

        let authorizer = BotCloudScheduleConsentAuthorizer(
            refCheck: { await f.solver.state(of: $0) == .valid })
        let fetchedRoutine = try await f.machine.get(botId: "bot-a", routineId: "digest")
        let routine = try XCTUnwrap(fetchedRoutine)
        let refused = await authorizer.refusal(for: routine)
        XCTAssertEqual(refused, .revoked)
        let missing = try await f.machine.setCloudSchedule(
            botId: "bot-a", routineId: "digest", enabled: true,
            authorizationRef: "record://event/999998", now: now + 2)
        let missingRefused = await authorizer.refusal(for: missing)
        XCTAssertEqual(missingRefused, .revoked)
    }

    func testRealDerivationDependencyStopsOnlyThatRoutine() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try await fixture(at: now)
        let calendarRef = try await appendContextObservation(f, source: "calendar")
        _ = try await f.machine.setCloudSchedule(
            botId: "bot-a", routineId: "digest", enabled: true,
            authorizationRef: calendarRef, derivationRef: calendarRef, now: now)
        _ = try await f.machine.create(
            botId: "bot-a", title: "Second", prompt: "summarize",
            schedule: .interval(everyMinutes: 60, timezone: "UTC"),
            now: now - 3_600_000, id: "second")
        _ = try await f.machine.setCloudSchedule(
            botId: "bot-a", routineId: "second", enabled: true,
            authorizationRef: "record://event/1", now: now)

        let dependency = BotRoutineSourceDependencyResolver(
            store: f.store, botID: "bot-a",
            authorization: { source in
                source != "calendar"
            })
        let authorizer = BotCloudScheduleConsentAuthorizer(
            refCheck: { _ in true },
            sourceDependency: { await dependency.refusal(for: $0) })
        let fetchedCalendar = try await f.machine.get(botId: "bot-a", routineId: "digest")
        let calendarRoutine = try XCTUnwrap(fetchedCalendar)
        let calendarRefusal = await authorizer.refusal(for: calendarRoutine)
        XCTAssertEqual(calendarRefusal, .revoked,
                       "the routine with a real calendar basis must stop")
        let fetchedUnrelated = try await f.machine.get(botId: "bot-a", routineId: "second")
        let unrelated = try XCTUnwrap(fetchedUnrelated)
        let unrelatedRefusal = await authorizer.refusal(for: unrelated)
        XCTAssertNil(unrelatedRefusal,
                     "cross-goal must not be stopped by another routine's source")
    }

    func testAuthorizedDependencyAndNoDependencyBothAllow() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try await fixture(at: now)
        let contactsRef = try await appendContextObservation(f, source: "contacts")
        _ = try await f.machine.setCloudSchedule(
            botId: "bot-a", routineId: "digest", enabled: true,
            authorizationRef: contactsRef, derivationRef: contactsRef, now: now)
        let dependency = BotRoutineSourceDependencyResolver(
            store: f.store, botID: "bot-a",
            authorization: { _ in true })
        let authorizer = BotCloudScheduleConsentAuthorizer(
            refCheck: { _ in true }, sourceDependency: { await dependency.refusal(for: $0) })
        let fetched = try await f.machine.get(botId: "bot-a", routineId: "digest")
        let routine = try XCTUnwrap(fetched)
        let refusal = await authorizer.refusal(for: routine)
        XCTAssertNil(refusal)
    }

    func testCloudClientDoesNotRegisterWithAnEphemeralAuthorizationRef() async throws {
        let now = wp6Date(2026, 5, 12, 12)
        let f = try await fixture(at: now)
        _ = try await f.machine.setCloudSchedule(
            botId: "bot-a", routineId: "digest", enabled: true,
            authorizationRef: "record://event/999999", now: now)
        let transport = AuthProbeTransport(clock: { now })
        let machine = f.machine
        let scheduler = RoutineScheduler(
            botId: "bot-a", machine: machine, inbox: try wp6Inbox(root: f.root),
            sink: WP6RoutineSink(), runner: { _ in .success("x") },
            available: { _ in true }, now: { now })
        let authorizer = BotCloudScheduleConsentAuthorizer(
            refCheck: { await f.solver.state(of: $0) == .valid })
        let client = CloudScheduleClient(
            botID: "bot-a", deviceID: "device-a", transport: transport,
            machine: machine, scheduler: scheduler, authorizer: authorizer,
            readiness: { true }, now: { now }, sleep: { _ in })
        let result = await client.synchronizeNow()
        XCTAssertEqual(result, .synced(0))
        let sync = await transport.syncRequests
        XCTAssertTrue(sync.flatMap(\.registrations).isEmpty)
    }
}

private actor AuthProbeTransport: CloudScheduleTransport {
    private let clock: @Sendable () -> Int64
    private(set) var syncRequests: [CloudScheduleSyncRequest] = []
    init(clock: @escaping @Sendable () -> Int64) { self.clock = clock }
    func sync(_ request: CloudScheduleSyncRequest) async throws -> CloudScheduleSyncResponse {
        syncRequests.append(request)
        return CloudScheduleSyncResponse(serverTimeMS: clock(), accepted: request.registrations,
                                         removedAccepted: request.removed.map(\.routineID))
    }
    func poll(_ request: CloudSchedulePollRequest) async throws -> CloudSchedulePollResponse {
        CloudSchedulePollResponse(serverTimeMS: clock())
    }
    func acknowledge(_ request: CloudScheduleReceiptRequest) async throws -> CloudScheduleReceiptResponse {
        CloudScheduleReceiptResponse(accepted: true)
    }
    func reconcile(_ request: CloudScheduleReconcileRequest) async throws -> CloudScheduleReconcileResponse {
        CloudScheduleReconcileResponse(serverTimeMS: clock())
    }
    func cancelRoutine(_ request: CloudScheduleCancelRequest) async throws {}
    func cancelEvent(_ request: CloudScheduleEventCancelRequest) async throws {}
}
