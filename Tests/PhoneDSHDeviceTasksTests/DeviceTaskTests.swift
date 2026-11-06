// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import PhoneDSHDeviceTasks

private actor TestInbox: DeviceTaskInbox {
    var accepted: [String] = []
    var reports: [(String, DeviceTaskOutcome)] = []
    var failReport = false
    func accept(id: String) async throws { accepted.append(id) }
    func report(id: String, outcome: DeviceTaskOutcome) async throws {
        if failReport { throw CocoaError(.fileWriteUnknown) }
        reports.append((id, outcome))
    }
    func setFailReport(_ value: Bool) { failReport = value }
    func reportValues() -> [DeviceTaskOutcome] { reports.map(\.1) }
    func acceptCount() -> Int { accepted.count }
}

private actor TestRunner: DeviceTaskRunner {
    var runs = 0
    var delayMS = 0
    func session(for deviceID: String) async throws -> String { "session-" + deviceID }
    func run(task: DeviceTask, record: DeviceTaskRecord) async -> DeviceTaskOutcome {
        runs += 1
        if delayMS > 0 { try? await Task.sleep(for: .milliseconds(delayMS)) }
        return .completed(output: "Answer", truncated: false)
    }
    func cancel(sessionID: String) async {}
    func count() -> Int { runs }
    func setDelay(_ value: Int) { delayMS = value }
}

final class DeviceTaskTests: XCTestCase {
    private func task(_ id: String = "task-1", key: String = "key-1", text: String = "Hello") throws -> DeviceTask {
        let body: [String: Any] = ["id": id, "idempotency_key": key, "requester": "device", "created_at": "2026-11-06T00:00:00Z", "body": ["type": "goal", "text": text]]
        return try DeviceTask.decode(JSONSerialization.data(withJSONObject: body))
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    func testSharedTaskFixtures() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("spec/device/v1/golden/task-cases.jsonl")
        for line in try String(contentsOf: fixture, encoding: .utf8).split(separator: "\n") {
            let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let bytes = try JSONSerialization.data(withJSONObject: XCTUnwrap(row["task"]))
            let value = try? DeviceTask.decode(bytes)
            XCTAssertEqual(value != nil, row["valid"] as? Bool, row["name"] as? String ?? "")
        }
    }

    func testUTF8LimitsAndSafeOutput() throws {
        XCTAssertThrowsError(try task(text: String(repeating: "中", count: 257)))
        let outcome = DeviceTaskOutcome.boundedOutput(String(repeating: "中", count: 400))
        guard case .completed(let text, let truncated) = outcome else { return XCTFail("missing output") }
        XCTAssertEqual(text.utf8.count, 1023)
        XCTAssertTrue(truncated)
    }

    func testJournalLockAndCorruptionFailClosed() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try DeviceTaskJournal(directory: dir)
        XCTAssertThrowsError(try DeviceTaskJournal(directory: dir))
        let record = try journal.create(deviceID: "device-1", task: task(), sessionID: "s1", now: Date())
        XCTAssertEqual(record.requestID, "dev:" + record.msgID)
        XCTAssertEqual(record.seq, 1)
        XCTAssertThrowsError(try journal.create(deviceID: "device-1", task: task("different", key: "key-1"), sessionID: "s1", now: Date()))
        let file = dir.appendingPathComponent(record.msgID + ".json")
        try Data("not-json".utf8).write(to: file)
        XCTAssertThrowsError(try journal.records())
    }

    func testDuplicateDeliveryReplaysResultOnly() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = TestRunner(), inbox = TestInbox()
        let executor = try DeviceTaskExecutor(directory: dir, runner: runner)
        let value = try task()
        await inbox.setFailReport(true)
        do { try await executor.process(deviceID: "device-1", task: value, authorized: true, inbox: inbox); XCTFail("lost report") } catch {}
        await inbox.setFailReport(false)
        try await executor.process(deviceID: "device-1", task: value, authorized: true, inbox: inbox)
        let count = await runner.count(), accepts = await inbox.acceptCount(), reports = await inbox.reportValues()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(accepts, 1)
        XCTAssertEqual(reports, [.completed(output: "Answer", truncated: false)])
        do { try await executor.process(deviceID: "device-1", task: task("task-2", key: "key-1"), authorized: true, inbox: inbox); XCTFail("conflict") }
        catch { XCTAssertEqual(error as? DeviceTaskError, .idempotencyConflict) }
    }

    func testInterruptedRunNeverReplays() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let value = try task()
        do {
            let journal = try DeviceTaskJournal(directory: dir)
            var record = try journal.create(deviceID: "device-1", task: value, sessionID: "s1", now: Date())
            record.phase = .running
            try journal.save(record)
        }
        let runner = TestRunner(), inbox = TestInbox()
        let executor = try DeviceTaskExecutor(directory: dir, runner: runner)
        try await executor.process(deviceID: "device-1", task: value, authorized: true, inbox: inbox)
        let count = await runner.count(), reports = await inbox.reportValues()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(reports, [.failed(kind: .unknownOutcome, message: "Previous execution was interrupted; its outcome is unknown.")])
    }

    func testUnauthorizedAndConcurrentTasksDoNotDispatch() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = TestRunner(), inbox = TestInbox()
        await runner.setDelay(200)
        let executor = try DeviceTaskExecutor(directory: dir, runner: runner)
        do { try await executor.process(deviceID: "device-1", task: task(), authorized: false, inbox: inbox); XCTFail("unauthorized") }
        catch { XCTAssertEqual(error as? DeviceTaskError, .unauthorized) }
        let first = Task { try await executor.process(deviceID: "device-1", task: task(), authorized: true, inbox: inbox) }
        try await Task.sleep(for: .milliseconds(50))
        do { try await executor.process(deviceID: "device-1", task: task("task-2", key: "key-2"), authorized: true, inbox: inbox); XCTFail("concurrent") }
        catch { XCTAssertEqual(error as? DeviceTaskError, .deviceBusy) }
        try await first.value
        let count = await runner.count()
        XCTAssertEqual(count, 1)
    }
}
