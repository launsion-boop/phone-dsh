// SPDX-License-Identifier: MIT
// secure-session-v2 §9.2: DeviceTaskExecutor hands secure transitions to a
// BLESecureTaskInbox only after the `ble-secure-ops` intent is durable; a
// pre-existing intent is passed with fresh == false (status first, §9.3);
// arguments come solely from the persisted parent.
import Foundation
import XCTest
@testable import PhoneDSHDeviceTasks

private actor RecordingSecureInbox: BLESecureTaskInbox {
    nonisolated let phoneID = "phone:" + String(repeating: "1", count: 64)
    let directory: URL
    var calls: [(BLESecureTransitionArguments, Bool, Bool)] = []
    var failNext: Error?
    init(directory: URL) { self.directory = directory }
    func setFailNext(_ error: Error?) { failNext = error }
    func transition(_ arguments: BLESecureTransitionArguments, intent: BLESecureTaskIntent, fresh: Bool) async throws {
        let file = directory.appendingPathComponent("ble-secure-ops").appendingPathComponent(intent.fileName)
        calls.append((arguments, fresh, FileManager.default.fileExists(atPath: file.path)))
        if let failNext { self.failNext = nil; throw failNext }
    }
    func snapshot() -> [(BLESecureTransitionArguments, Bool, Bool)] { calls }
}

private actor CountingRunner: DeviceTaskRunner {
    var runs = 0
    func session(for deviceID: String, existingSession: String?) async throws -> String { existingSession ?? "s-1" }
    func run(task: DeviceTask, record: DeviceTaskRecord) async -> DeviceTaskOutcome { runs += 1; return .completed(output: "ok", truncated: false) }
    func cancel(sessionID: String) async {}
}

final class BLESecureExecutorBindingTests: XCTestCase {
    func testSecureInboxGetsDurableIntentsAndReconcilesAfterALostReply() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pdsh-secure-binding-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = CountingRunner()
        let executor = try DeviceTaskExecutor(directory: directory, runner: runner)
        let inbox = RecordingSecureInbox(directory: directory)
        let device = "ble:" + String(repeating: "a", count: 64)
        let body: [String: Any] = ["id": "t-1", "idempotency_key": "k-1", "requester": "device",
                                   "created_at": "2026-11-08T00:00:00Z", "body": ["type": "goal", "text": "hi"]]
        let task = try DeviceTask.decode(JSONSerialization.data(withJSONObject: body))
        // Lost accept reply: the intent stays; the retry is not fresh.
        await inbox.setFailNext(BLESecureTaskInboxError.retryLater)
        do { try await executor.process(deviceID: device, task: task, authorized: true, inbox: inbox); XCTFail("lost reply") }
        catch { XCTAssertEqual(error as? BLESecureTaskInboxError, .retryLater) }
        let runsBefore = await runner.runs
        XCTAssertEqual(runsBefore, 0, "nothing runs before an applied accept")
        try await executor.process(deviceID: device, task: task, authorized: true, inbox: inbox)
        let calls = await inbox.snapshot()
        XCTAssertEqual(calls.map(\.0.action), [.accept, .accept, .complete])
        XCTAssertEqual(calls.map(\.1), [true, false, true], "fresh only in the call that installed the intent")
        XCTAssertTrue(calls.allSatisfy(\.2), "every intent is durable before the binding is called")
        XCTAssertEqual(calls[2].0, .complete(id: "t-1", idem: "k-1", output: "ok", truncated: false))
        let runs = await runner.runs
        XCTAssertEqual(runs, 1)
        let tasks = try await executor.tasks(deviceID: device)
        XCTAssertEqual(tasks, [task])
        // A link-style call never reaches a secure inbox.
        do { try await inbox.accept(id: "t-1"); XCTFail() } catch { XCTAssertEqual(error as? DeviceTaskError, .unauthorized) }
    }
}
