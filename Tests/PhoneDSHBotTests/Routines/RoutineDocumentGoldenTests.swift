// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// CCR-7: the persisted routine snapshot is `{botId, document}` and the
/// document is encoded by `DurableEventSnapshots.data(for:botId:)`. These
/// fixtures are the inputs; the expected bytes come from the Swift encoder
/// that produced `spec/bot/v2/golden/routine-document.json`.
final class RoutineDocumentGoldenTests: XCTestCase {
    private enum Fixture {
        static let botId = "main"

        static func runState(_ status: RoutineRunStatus, attempt: Int, runId: String,
                             startedAt: Int64, finishedAt: Int64? = nil,
                             error: String? = nil, reconciliation: Bool = false) -> RoutineRunState {
            RoutineRunState(runId: runId, attempt: attempt, status: status,
                            scheduledFor: startedAt, startedAt: startedAt, finishedAt: finishedAt,
                            leaseOwner: status == .started ? "local" : nil,
                            leaseExpiresAt: status == .started ? startedAt + 660_000 : nil,
                            error: error, reconciliationRequired: reconciliation)
        }

        static let newRoutine = Routine(
            id: "daily-digest", agentId: "main", title: "Daily digest",
            prompt: "Summarize the day.", schedule: .daily(time: "09:00", timezone: "Asia/Shanghai"),
            createdAt: 1_760_000_000_000, nextRunAt: 1_760_032_800_000)

        static let deferredRoutine: Routine = {
            var routine = newRoutine
            routine.quietDefer = RoutineQuietDefer(
                until: 1_760_030_000_000, scheduledFor: 1_760_028_000_000, at: 1_760_027_000_000)
            routine.nextRunAt = 1_760_030_000_000
            return routine
        }()

        static let startedRoutine: Routine = {
            var routine = newRoutine
            routine.attempt = 1
            routine.lastRunAt = 1_760_028_000_000
            routine.runState = runState(.started, attempt: 1, runId: "run-daily-1",
                                        startedAt: 1_760_028_000_000)
            return routine
        }()

        static let needsReconciliationRoutine: Routine = {
            var routine = startedRoutine
            routine.runState = runState(.needsReconciliation, attempt: 1, runId: "run-daily-1",
                                        startedAt: 1_760_028_000_000,
                                        finishedAt: 1_760_034_000_000,
                                        error: "effect outcome unknown", reconciliation: true)
            routine.lastResult = RoutineResult(
                status: .needsReconciliation, text: "", error: "effect outcome unknown",
                startedAt: 1_760_028_000_000, finishedAt: 1_760_034_000_000,
                durationMs: 6_000_000, scheduledFor: 1_760_028_000_000, lateByMs: 0,
                quiet: false, attempt: 1, runId: "run-daily-1")
            routine.nextRunAt = nil
            return routine
        }()

        static let delivery = RoutineDelivery(
            deliveryKey: "daily-digest:1", routineId: "daily-digest", agentId: "main",
            attempt: 1, runId: "run-daily-1", status: .pending,
            resultStatus: .needsReconciliation, text: "", error: "effect outcome unknown",
            routineTitle: "Daily digest", context: "routine", delivery: .held,
            urgent: false, urgentReason: "", lateByMs: 0,
            startedAt: 1_760_028_000_000, finishedAt: 1_760_034_000_000,
            durationMs: 6_000_000, createdAt: 1_760_034_000_000, updatedAt: 1_760_034_000_000,
            attempts: 0)

        static func document(named name: String) -> (eventType: String, document: RoutineDocument)? {
            switch name {
            case "new":
                return ("routine.defined", RoutineDocument(version: 1, routines: [newRoutine]))
            case "deferred":
                return ("routine.updated", RoutineDocument(version: 1, routines: [deferredRoutine]))
            case "started":
                return ("routine.updated", RoutineDocument(version: 1, routines: [startedRoutine]))
            case "needs-reconciliation":
                return ("routine.updated", RoutineDocument(
                    version: 1, routines: [needsReconciliationRoutine],
                    deliveries: ["daily-digest:1": delivery]))
            case "deleted":
                return ("routine.deleted", RoutineDocument(
                    version: 1, routines: [], deliveries: ["daily-digest:1": delivery]))
            default:
                return nil
            }
        }
    }

    private func fixture() throws -> [String: Any] {
        try BotGoldenFixture.mergedObject("routine-document")
    }

    private func canonical(_ object: Any) throws -> Data {
        try BotJSONValue.parse(JSONSerialization.data(withJSONObject: object)).encoded()
    }

    func testEveryGoldenDocumentComesFromTheRealEncoder() throws {
        let golden = try fixture()
        let valid = try XCTUnwrap(golden["valid"] as? [[String: Any]])
        XCTAssertEqual(valid.compactMap { $0["name"] as? String },
                       ["new", "deferred", "started", "needs-reconciliation", "deleted"])
        var seenEventTypes: [String] = []
        for caseVector in valid {
            let name = try XCTUnwrap(caseVector["name"] as? String)
            let expectedType = try XCTUnwrap(caseVector["eventType"] as? String)
            let expected = try XCTUnwrap(caseVector["data"])
            let fixture = try XCTUnwrap(Fixture.document(named: name), "missing fixture \(name)")
            XCTAssertEqual(fixture.eventType, expectedType)
            seenEventTypes.append(expectedType)

            let data = try DurableEventSnapshots.data(for: fixture.document, botId: Fixture.botId)
            XCTAssertEqual(try data.encoded(), try canonical(expected), "\(name) bytes")

            let event = BotEvent(
                type: expectedType, eventId: "routine-snapshot:\(name)", commitSeq: 1,
                time: 1_760_000_000_000, origin: .local(source: "scheduler"),
                traceId: "trace-routine-snapshot:\(name)",
                principal: BotPrincipal(botId: Fixture.botId, sessionId: nil, kind: "routine"),
                causationId: nil, correlationId: Fixture.botId, data: data)
            let decoded = try DurableEventSnapshots.decode(
                RoutineDocument.self, from: event, botId: Fixture.botId)
            XCTAssertEqual(decoded, fixture.document)
        }
        XCTAssertEqual(seenEventTypes,
                       ["routine.defined", "routine.updated", "routine.updated",
                        "routine.updated", "routine.deleted"])
    }

}
