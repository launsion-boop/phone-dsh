// SPDX-License-Identifier: MIT
import Foundation
import XCTest
import PhoneDSHAgentCore
@testable import PhoneDSHDeviceTasks

private final class SettlementRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DeviceTaskSettlement] = []

    var all: [DeviceTaskSettlement] {
        lock.lock(); defer { lock.unlock() }
        return values
    }

    var count: Int { all.count }

    func record(_ value: DeviceTaskSettlement) {
        lock.lock(); values.append(value); lock.unlock()
    }

    func reset() {
        lock.lock(); values.removeAll(); lock.unlock()
    }
}

private actor SettlementRunner: DeviceTaskRunner {
    private var outcome: DeviceTaskOutcome
    private var delayMS: Int
    private var runs = 0

    init(outcome: DeviceTaskOutcome = .completed(output: "Answer", truncated: false),
         delayMS: Int = 0) {
        self.outcome = outcome
        self.delayMS = delayMS
    }

    func session(for deviceID: String, existingSession: String?) async throws -> String {
        "session-" + deviceID
    }

    func run(task: DeviceTask, record: DeviceTaskRecord) async -> DeviceTaskOutcome {
        runs += 1
        if delayMS > 0 { try? await Task.sleep(for: .milliseconds(delayMS)) }
        return outcome
    }

    func cancel(sessionID: String) async {}
    func runCount() -> Int { runs }
}

private actor SettlementInbox: DeviceTaskInbox {
    private var failReport: Bool
    private var accepts = 0
    private var reports: [DeviceTaskOutcome] = []

    init(failReport: Bool = false) { self.failReport = failReport }

    func accept(id: String) async throws { accepts += 1 }

    func report(id: String, outcome: DeviceTaskOutcome) async throws {
        if failReport { throw CocoaError(.fileWriteUnknown) }
        reports.append(outcome)
    }

    func setFailReport(_ value: Bool) { failReport = value }
    func acceptCount() -> Int { accepts }
    func reportValues() -> [DeviceTaskOutcome] { reports }
}

/// Returns the current instant and then advances, so the expiry check that
/// follows durable acceptance observes a later clock reading.
private final class SteppingSettlementClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    private let step: TimeInterval

    init(_ value: Date, step: TimeInterval) {
        self.value = value
        self.step = step
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value.addTimeInterval(step)
        return current
    }
}

final class DeviceTaskSettlementTests: XCTestCase {
    private func task(id: String = "task-1", key: String = "key-1",
                      text: String = "Check the kitchen temperature",
                      deadline: String? = nil) throws -> DeviceTask {
        var body: [String: Any] = [
            "id": id, "idempotency_key": key, "requester": "sensor-1",
            "created_at": "2026-11-06T00:00:00Z",
            "body": ["type": "goal", "text": text],
        ]
        if let deadline { body["deadline"] = deadline }
        return try DeviceTask.decode(JSONSerialization.data(withJSONObject: body))
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func journalRecord(in directory: URL) throws -> DeviceTaskRecord {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let file = try XCTUnwrap(files.first)
        return try JSONDecoder().decode(DeviceTaskRecord.self, from: Data(contentsOf: file))
    }

    func testFreshCompletionNotifiesOnceAfterJournalWrite() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = SettlementRecorder(), runner = SettlementRunner(), inbox = SettlementInbox()
        let executor = try DeviceTaskExecutor(directory: dir, runner: runner, onSettled: recorder.record)
        let value = try task()

        try await executor.process(deviceID: "sensor-1", task: value, authorized: true, inbox: inbox)

        let settlements = recorder.all
        XCTAssertEqual(settlements.count, 1)
        let settlement = try XCTUnwrap(settlements.first)
        XCTAssertEqual(settlement.deviceID, "sensor-1")
        XCTAssertEqual(settlement.taskID, "task-1")
        XCTAssertEqual(settlement.idempotencyKey, "key-1")
        XCTAssertEqual(settlement.goal, "Check the kitchen temperature")
        XCTAssertEqual(settlement.outcome, .completed(output: "Answer", truncated: false))
        XCTAssertEqual(try journalRecord(in: dir).outcome, settlement.outcome)
        let reports = await inbox.reportValues()
        XCTAssertEqual(reports, [settlement.outcome])
        let runs = await runner.runCount()
        XCTAssertEqual(runs, 1)
    }

    func testFailureOutcomeNotifies() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = SettlementRecorder()
        let failure = DeviceTaskOutcome.failed(kind: .denied, message: "No permission")
        let runner = SettlementRunner(outcome: failure), inbox = SettlementInbox()
        let executor = try DeviceTaskExecutor(directory: dir, runner: runner, onSettled: recorder.record)

        try await executor.process(deviceID: "sensor-1", task: try task(),
                                   authorized: true, inbox: inbox)

        XCTAssertEqual(recorder.all.map(\.outcome), [failure])
    }

    func testExpiredBeforeSubmissionNotifies() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-06T00:00:00Z"))
        let clock = SteppingSettlementClock(start, step: 301)
        let recorder = SettlementRecorder(), runner = SettlementRunner(), inbox = SettlementInbox()
        let executor = try DeviceTaskExecutor(directory: dir, runner: runner,
                                              clock: { clock.now() }, onSettled: recorder.record)

        try await executor.process(deviceID: "sensor-1", task: try task(),
                                   authorized: true, inbox: inbox)

        XCTAssertEqual(recorder.all.count, 1)
        guard case .failed(let kind, _) = try XCTUnwrap(recorder.all.first?.outcome) else {
            return XCTFail("expired task did not settle as a failure")
        }
        XCTAssertEqual(kind, .expired)
        let runs = await runner.runCount()
        XCTAssertEqual(runs, 0)
    }

    func testTimeoutAfterSubmissionNotifiesUnknownOutcome() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-06T00:00:00Z"))
        let recorder = SettlementRecorder()
        let runner = SettlementRunner(delayMS: 5_000), inbox = SettlementInbox()
        let executor = try DeviceTaskExecutor(directory: dir, runner: runner,
                                              clock: { start }, onSettled: recorder.record)
        let value = try task(deadline: "2026-11-06T00:00:01Z")

        try await executor.process(deviceID: "sensor-1", task: value,
                                   authorized: true, inbox: inbox)

        XCTAssertEqual(recorder.all.count, 1)
        guard case .failed(let kind, _) = try XCTUnwrap(recorder.all.first?.outcome) else {
            return XCTFail("timed-out task did not settle as a failure")
        }
        XCTAssertEqual(kind, .unknownOutcome)
    }

    func testExistingTerminalRecordReplayDoesNotNotifyAgain() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = SettlementRecorder(), runner = SettlementRunner(), inbox = SettlementInbox()
        let executor = try DeviceTaskExecutor(directory: dir, runner: runner, onSettled: recorder.record)
        let value = try task()

        try await executor.process(deviceID: "sensor-1", task: value, authorized: true, inbox: inbox)
        XCTAssertEqual(recorder.all.count, 1)
        recorder.reset()

        try await executor.process(deviceID: "sensor-1", task: value, authorized: true, inbox: inbox)

        XCTAssertEqual(recorder.all.count, 0, "a replay must only resend the persisted report")
        let runs = await runner.runCount()
        XCTAssertEqual(runs, 1)
        let accepts = await inbox.acceptCount()
        let reports = await inbox.reportValues()
        XCTAssertEqual(accepts, 1)
        XCTAssertEqual(reports.count, 2, "the terminal report is retried")
    }

    func testFailedReportStillNotifiesAndLeavesTerminalJournal() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = SettlementRecorder(), runner = SettlementRunner()
        let failing = SettlementInbox(failReport: true), retrying = SettlementInbox()
        let executor = try DeviceTaskExecutor(directory: dir, runner: runner, onSettled: recorder.record)
        let value = try task()

        do {
            try await executor.process(deviceID: "sensor-1", task: value,
                                       authorized: true, inbox: failing)
            XCTFail("a failed report must surface its error")
        } catch {}

        XCTAssertEqual(recorder.all.count, 1)
        XCTAssertEqual(recorder.all.first?.outcome, .completed(output: "Answer", truncated: false))
        let record = try journalRecord(in: dir)
        XCTAssertEqual(record.phase, .terminal)
        XCTAssertEqual(record.outcome, .completed(output: "Answer", truncated: false))

        try await executor.process(deviceID: "sensor-1", task: value,
                                   authorized: true, inbox: retrying)
        XCTAssertEqual(recorder.all.count, 1, "retrying the report must not notify again")
        let reports = await retrying.reportValues()
        XCTAssertEqual(reports, [.completed(output: "Answer", truncated: false)])
    }

    func testNoObserverKeepsCompletionBehavior() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = SettlementRunner(), inbox = SettlementInbox()
        let executor = try DeviceTaskExecutor(directory: dir, runner: runner)

        try await executor.process(deviceID: "sensor-1", task: try task(),
                                   authorized: true, inbox: inbox)

        let reports = await inbox.reportValues()
        XCTAssertEqual(reports, [.completed(output: "Answer", truncated: false)])
        XCTAssertEqual(try journalRecord(in: dir).phase, .terminal)
    }
}
