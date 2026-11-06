// SPDX-License-Identifier: MIT
import Foundation
import PhoneDSHAgentCore
import XCTest
@testable import PhoneDSHDeviceTasks

final class BLETaskIntentTests: XCTestCase {
    func testSharedIntentVectorsAndQueryOnlyRecovery() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("spec/device/v1/golden/ble-task-link-ops.jsonl")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try DeviceTaskJournal(directory: dir)
        let taskJSON = """
        {"id":"task-1","idempotency_key":"goal-1","requester":"device","created_at":"2026-11-06T00:00:00Z","body":{"type":"goal","text":"Hello"}}
        """
        let task = try DeviceTask.decode(Data(taskJSON.utf8))
        let record = try journal.create(deviceID: "ble:ce6ec956-1111-4222-8333-123456789abc", task: task, sessionID: "session-1", now: Date())
        for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
            let row = try JSONValue.parse(Data(line.utf8))
            let args = try XCTUnwrap(row["args"])
            let expectedJSON = try XCTUnwrap(row["record"])
            let expected = try JSONDecoder().decode(BLETaskIntent.self, from: expectedJSON.encoded())
            let made = try BLETaskIntent.make(record: record, action: expected.action, arguments: args)
            XCTAssertEqual(made == expected, row["valid"]?.boolValue, row["name"]?.stringValue ?? "")
            if row["valid"]?.boolValue == true {
                let first = try journal.prepareBLETransition(record: record, action: expected.action, arguments: args)
                XCTAssertTrue(first.fresh)
                XCTAssertEqual(first.intent, expected)
                let second = try journal.prepareBLETransition(record: record, action: expected.action, arguments: args)
                XCTAssertFalse(second.fresh, "a persisted intent is query-only")
                XCTAssertEqual(second.intent, expected)
            }
        }
        let badArgs: JSONValue = .object(["id": .string("task-1"), "output": .string("changed"), "truncated": .bool(false)])
        XCTAssertThrowsError(try journal.prepareBLETransition(record: record, action: .complete, arguments: badArgs))
    }
}

private actor FakeBLETaskLink: BLETaskLinkInbox {
    private var attempts: [(String, UUID, Bool)] = []
    private var dropFirstAccept = true
    func invokeOrQuery(requestID: UUID, name: String, arguments: JSONValue,
                       idempotencyKey: String, fresh: Bool) async throws -> JSONValue {
        attempts.append((name, requestID, fresh))
        if name == "pdsh.task.accept" && dropFirstAccept {
            dropFirstAccept = false
            throw CocoaError(.fileReadUnknown)
        }
        return .object(["request_id": .string(requestID.uuidString.lowercased()), "status": .string("completed"), "result": .object([:])])
    }
    func observed() -> [(String, UUID, Bool)] { attempts }
}

private actor FakeTaskRunner: DeviceTaskRunner {
    private var count = 0
    func session(for deviceID: String, existingSession: String?) async throws -> String { existingSession ?? "session-1" }
    func run(task: DeviceTask, record: DeviceTaskRecord) async -> DeviceTaskOutcome { count += 1; return .completed(output: "done", truncated: false) }
    func cancel(sessionID: String) async {}
    func runs() -> Int { count }
}

extension BLETaskIntentTests {
    func testLostAcceptQueriesSameLinkOperationAndNeverRerunsTask() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data(#"{"id":"task-1","idempotency_key":"goal-1","requester":"device","created_at":"2026-11-06T00:00:00Z","body":{"type":"goal","text":"Hello"}}"#.utf8)
        let task = try DeviceTask.decode(bytes)
        let device = "ble:ce6ec956-1111-4222-8333-123456789abc"
        let runner = FakeTaskRunner(), link = FakeBLETaskLink()
        let executor = try DeviceTaskExecutor(directory: dir, runner: runner)
        do { try await executor.process(deviceID: device, task: task, authorized: true, inbox: link); XCTFail("lost accept") } catch {}
        try await executor.process(deviceID: device, task: task, authorized: true, inbox: link)
        try await executor.process(deviceID: device, task: task, authorized: true, inbox: link)
        let attempts = await link.observed(), runs = await runner.runs()
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(attempts.map(\.0), ["pdsh.task.accept", "pdsh.task.accept", "pdsh.task.complete", "pdsh.task.complete"])
        XCTAssertEqual(attempts.map(\.2), [true, false, true, false])
        XCTAssertEqual(attempts[0].1, attempts[1].1)
        XCTAssertEqual(attempts[2].1, attempts[3].1)
    }
}
