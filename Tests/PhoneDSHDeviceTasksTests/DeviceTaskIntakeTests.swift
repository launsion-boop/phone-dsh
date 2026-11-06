// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import PhoneDSHDeviceTasks

private actor IntakeRunner: DeviceTaskRunner {
    private var runCount = 0
    func session(for deviceID: String, existingSession: String?) async throws -> String { existingSession ?? "session-1" }
    func run(task: DeviceTask, record: DeviceTaskRecord) async -> DeviceTaskOutcome { runCount += 1; return .completed(output: "done", truncated: false) }
    func cancel(sessionID: String) async {}
    func runs() -> Int { runCount }
}
private actor IntakeInbox: DeviceTaskInbox {
    private var count = 0
    func accept(id: String) async throws {}
    func report(id: String, outcome: DeviceTaskOutcome) async throws { count += 1 }
    func reports() -> Int { count }
}
private actor IntakeFeed {
    let task: DeviceTask
    private var served = false
    init(_ task: DeviceTask) { self.task = task }
    func next() async throws -> DeviceTask? {
        if !served { served = true; return task }
        try await Task.sleep(for: .seconds(30))
        return nil
    }
}

final class DeviceTaskIntakeTests: XCTestCase {
    func testExplicitGrantAndRevocationStopTheLoop() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let task = try DeviceTask.decode(Data(#"{"id":"task-1","idempotency_key":"key-1","requester":"device","created_at":"2026-11-06T00:00:00Z","body":{"type":"goal","text":"Hello"}}"#.utf8))
        let runner = IntakeRunner(), inbox = IntakeInbox(), feed = IntakeFeed(task)
        let intake = DeviceTaskIntake(executor: try DeviceTaskExecutor(directory: dir, runner: runner))
        do { _ = try await intake.start(deviceID: "device-1", authorized: false, inbox: inbox) { try await feed.next() }; XCTFail("missing grant") }
        catch { XCTAssertEqual(error as? DeviceTaskError, .unauthorized) }
        let started = try await intake.start(deviceID: "device-1", authorized: true, inbox: inbox) { try await feed.next() }
        XCTAssertTrue(started)
        let duplicate = try await intake.start(deviceID: "device-1", authorized: true, inbox: inbox) { try await feed.next() }
        XCTAssertFalse(duplicate)
        for _ in 0..<100 {
            if await inbox.reports() == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await intake.stop(deviceID: "device-1")
        let running = await intake.isRunning(deviceID: "device-1"), runs = await runner.runs(), reports = await inbox.reports()
        XCTAssertFalse(running)
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(reports, 1)
    }
}

private actor SlowIntakeInbox: DeviceTaskInbox {
    private var entered = false
    func accept(id: String) async throws { entered = true; try await Task.sleep(for: .seconds(30)) }
    func report(id: String, outcome: DeviceTaskOutcome) async throws {}
    func acceptedStarted() -> Bool { entered }
}

extension DeviceTaskIntakeTests {
    func testRevocationDuringAcceptanceNeverStartsDSH() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let task = try DeviceTask.decode(Data(#"{"id":"task-1","idempotency_key":"key-1","requester":"device","created_at":"2026-11-06T00:00:00Z","body":{"type":"goal","text":"Hello"}}"#.utf8))
        let runner = IntakeRunner(), inbox = SlowIntakeInbox(), feed = IntakeFeed(task)
        let intake = DeviceTaskIntake(executor: try DeviceTaskExecutor(directory: dir, runner: runner))
        _ = try await intake.start(deviceID: "device-1", authorized: true, inbox: inbox) { try await feed.next() }
        for _ in 0..<100 {
            if await inbox.acceptedStarted() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let started = await inbox.acceptedStarted()
        XCTAssertTrue(started)
        await intake.stop(deviceID: "device-1")
        let runs = await runner.runs()
        XCTAssertEqual(runs, 0)
    }
}

private actor RetryIntakeInbox: DeviceTaskInbox {
    private var reportCount = 0
    func accept(id: String) async throws {}
    func report(id: String, outcome: DeviceTaskOutcome) async throws {
        reportCount += 1
        if reportCount == 1 { throw LANDeviceTaskInboxError.unavailable }
    }
    func reports() -> Int { reportCount }
}

extension DeviceTaskIntakeTests {
    func testLostTerminalReplyRetriesWithoutRerunningDSH() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let task = try DeviceTask.decode(Data(#"{"id":"task-1","idempotency_key":"key-1","requester":"device","created_at":"2026-11-06T00:00:00Z","body":{"type":"goal","text":"Hello"}}"#.utf8))
        let runner = IntakeRunner(), inbox = RetryIntakeInbox(), feed = IntakeFeed(task)
        let intake = DeviceTaskIntake(executor: try DeviceTaskExecutor(directory: dir, runner: runner))
        _ = try await intake.start(deviceID: "device-1", authorized: true, inbox: inbox) { try await feed.next() }
        for _ in 0..<200 {
            if await inbox.reports() >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await intake.stop(deviceID: "device-1")
        let runs = await runner.runs(), reports = await inbox.reports()
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(reports, 2)
    }
}
