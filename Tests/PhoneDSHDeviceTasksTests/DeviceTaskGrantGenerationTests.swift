// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import PhoneDSHDeviceTasks

private actor GenerationGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var arrivals: [(Int, CheckedContinuation<Void, Never>)] = []
    private var entered = 0
    private var released = false
    func wait() async {
        entered += 1
        let ready = arrivals.filter { $0.0 <= entered }; arrivals.removeAll { $0.0 <= entered }
        for (_, observer) in ready { observer.resume() }
        if released { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func waitUntilEntered(_ count: Int = 1) async {
        if entered >= count || released { return }
        await withCheckedContinuation { arrivals.append((count, $0)) }
    }
    func isWaiting() -> Bool { !waiting.isEmpty && !released }
    func observerCount() -> Int { arrivals.count }
    func release() {
        released = true
        let pending = waiting; waiting.removeAll()
        let observers = arrivals; arrivals.removeAll()
        for continuation in pending { continuation.resume() }
        for (_, continuation) in observers { continuation.resume() }
    }
}

private actor GenerationMetrics {
    var live: Set<UUID> = []
    var maxLive = 0
    var deliveries: [UUID: Int] = [:]
    var closed = false
    var entered: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    func begin(_ token: UUID) {
        live.insert(token); maxLive = max(maxLive, live.count)
        let observers = entered.removeValue(forKey: token) ?? []
        for observer in observers { observer.resume() }
    }
    func end(_ token: UUID) { live.remove(token) }
    func waitFor(_ token: UUID) async {
        if live.contains(token) || closed { return }
        await withCheckedContinuation { entered[token, default: []].append($0) }
    }
    func waiterCount() -> Int { entered.values.reduce(0) { $0 + $1.count } }
    func releaseWaiters() {
        closed = true
        let pending = entered.values.flatMap { $0 }; entered.removeAll()
        for continuation in pending { continuation.resume() }
    }
    func peak() -> Int { maxLive }
    func delivered(_ token: UUID, old: UUID) { if token != old { deliveries[token, default: 0] += 1 } }
    func deliveryCount() -> Int { deliveries.values.reduce(0, +) }
    func deliveriesByToken() -> [UUID: Int] { deliveries }
}

private actor GenerationRunner: DeviceTaskRunner {
    private var runCount = 0
    func count() -> Int { runCount }
    func session(for deviceID: String, existingSession: String?) async throws -> String { existingSession ?? "test" }
    func run(task: DeviceTask, record: DeviceTaskRecord) async -> DeviceTaskOutcome { runCount += 1; return .completed(output: "test", truncated: false) }
    func cancel(sessionID: String) async {}
}
private struct GenerationInbox: DeviceTaskInbox {
    func accept(id: String) async throws {}
    func report(id: String, outcome: DeviceTaskOutcome) async throws {}
}
private struct GenerationFixture: Decodable {
    let id: String
    let steps: [String]
    let expected: Expected
    struct Expected: Decodable {
        let old_running: Bool, new_running: Bool, busy: Bool, old_alive_during_busy: Bool
        let max_live_jobs: Int, new_start_attempts: Int, auto_retries: Int
        let callback_can_be_pending_after_stop: Bool?
    }
}

@MainActor private final class GenerationResources {
    var gates: [GenerationGate] = []
    var intake: DeviceTaskIntake?
    var metrics: GenerationMetrics?
    func release() async -> Task<Void, Never>? {
        for gate in gates { await gate.release() }
        await metrics?.releaseWaiters()
        guard let intake else { return nil }
        return Task { await intake.stopAll() }
    }
}

private actor BlockingGenerationInbox: DeviceTaskInbox {
    let gate: GenerationGate
    let started: XCTestExpectation
    var accepts = 0, reports = 0
    init(gate: GenerationGate, started: XCTestExpectation) { self.gate = gate; self.started = started }
    func accept(id: String) async throws { accepts += 1; started.fulfill(); await gate.wait() }
    func report(id: String, outcome: DeviceTaskOutcome) async throws { reports += 1 }
    func counts() -> (Int, Int) { (accepts, reports) }
}
private actor GenerationOneTaskFeed {
    let value: DeviceTask
    var delivered = false
    init(_ value: DeviceTask) { self.value = value }
    func next() async throws -> DeviceTask? {
        if !delivered { delivered = true; return value }
        try await Task.sleep(for: .seconds(3600)); return nil
    }
}

@MainActor final class DeviceTaskGrantGenerationTests: XCTestCase {
    func testSharedGrantGenerationScenarios() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try String(contentsOf: root.appendingPathComponent("spec/device/v1/golden/task-grant-generations.jsonl"), encoding: .utf8)
        let fixtures = try data.split(whereSeparator: \.isNewline).map { try JSONDecoder().decode(GenerationFixture.self, from: Data($0.utf8)) }
        XCTAssertEqual(Set(fixtures.map(\.id)).count, 13)
        for fixture in fixtures {
            let resources = GenerationResources()
            let done = expectation(description: "scenario \(fixture.id) completes")
            var completed = false
            let task = Task {
                do { try await self.run(fixture, resources: resources) }
                catch { XCTFail("scenario \(fixture.id) threw: \(error)") }
                completed = true; done.fulfill()
            }
            await fulfillment(of: [done], timeout: 8)
            if !completed {
                task.cancel()
                if let cleanup = await resources.release() {
                    let cleanupDone = expectation(description: "timed-out scenario cleanup")
                    Task { await cleanup.value; cleanupDone.fulfill() }
                    await fulfillment(of: [cleanupDone], timeout: 2)
                }
                break
            }
        }
    }

    private func run(_ fixture: GenerationFixture, resources: GenerationResources) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let intake = DeviceTaskIntake(executor: try DeviceTaskExecutor(directory: directory, runner: GenerationRunner()))
        let coordinator = DeviceTaskGrantCoordinator()
        let metrics = GenerationMetrics(), gate = GenerationGate(), jobGate = GenerationGate()
        let monitorGate = GenerationGate(), callbackGate = GenerationGate(), callbackReturned = GenerationGate()
        let notificationDone = GenerationGate()
        resources.intake = intake; resources.metrics = metrics
        resources.gates = [gate, jobGate, monitorGate, callbackGate, callbackReturned, notificationDone]
        let old = UUID(), new = UUID(), other = UUID()
        var currentNew = new
        let oldDevice = "lan:old", otherDevice = "lan:other"
        var oldStop: Task<Void, Never>?, secondStop: Task<Void, Never>?, monitor: Task<Void, Never>?
        var oldStart: Task<Bool, Error>?, secondStart: Task<Bool, Error>?
        var newAttempts = 0, autoRetries = 0, busy = false, oldAlive = false
        var newDevice = oldDevice
        var callbackPendingAfterStop = false
        let holdOldJob = ["busy-until-old-stops", "suspend-cancels-all-first"].contains(fixture.id)
        coordinator.beforeStart = { token in
            await metrics.delivered(token, old: old)
            if fixture.id == "cancel-before-start" && token == old { await gate.wait() }
            if fixture.id == "suspend-cancels-all-first" && token == other { await gate.wait() }
        }
        if ["old-stop-after-new-start", "same-device-other-entry"].contains(fixture.id) {
            await intake.setNotificationTestHook { token in if token == old { await notificationDone.wait() } }
            coordinator.afterStop = { token in if token == old { await notificationDone.waitUntilEntered(); await gate.wait() } }
        }
        if fixture.id == "held-callback-allows-new-generation" {
            coordinator.beforeFinished = { token in if token == old { await callbackGate.wait() } }
            await intake.setNotificationTestHook { token in if token == old { await notificationDone.wait() } }
        }
        func begin(_ key: String, _ token: UUID, _ device: String,
                   callback: @escaping @Sendable () async -> Void = {}) throws -> Task<Bool, Error> {
            let next: DeviceTaskIntake.Next = {
                await metrics.begin(token)
                if holdOldJob && token == old { await jobGate.wait() }
                else { try? await Task.sleep(for: .seconds(3600)) }
                await metrics.end(token)
                try Task.checkCancellation()
                throw DeviceTaskError.unauthorized
            }
            if ["callback-self-stop", "callback-stop-all", "callbacks-stop-each-other", "legacy-unscoped-callback-stops-current"].contains(fixture.id), token != new {
                return Task {
                    await metrics.delivered(token, old: old)
                    return try await intake.start(deviceID: device, token: token, authorized: true, inbox: GenerationInbox(), onStopped: callback, next: next)
                }
            }
            return try coordinator.start(key: key, token: token, deviceID: device, intake: intake, inbox: GenerationInbox(), onStopped: callback, next: next)
        }
        func startOld(callback: @escaping @Sendable () async -> Void = {}) async throws {
            oldStart = try begin("old", old, oldDevice, callback: callback)
            let ok = try await oldStart!.value
            XCTAssertTrue(ok, fixture.id)
            await metrics.waitFor(old)
        }
        func startNew(key: String = "old", device: String? = nil, token: UUID? = nil) async throws {
            newAttempts += 1
            if token == nil && newAttempts > 1 { currentNew = UUID() }
            let chosen = token ?? currentNew
            newDevice = device ?? oldDevice
            secondStart = try begin(key, chosen, newDevice)
            let ok = try await secondStart!.value
            if ok { await metrics.waitFor(chosen) } else { busy = true }
        }
        for step in fixture.steps {
            switch step {
            case "hold_old_start_before_intake":
                oldStart = try begin("old", old, oldDevice); await gate.waitUntilEntered()
            case "start_old":
                if fixture.id == "callback-self-stop" {
                    try await startOld { await intake.stop(deviceID: oldDevice); await callbackReturned.wait(); await callbackGate.wait() }
                } else if fixture.id == "callback-stop-all" {
                    try await startOld { await intake.stopAll(); await callbackReturned.wait(); await callbackGate.wait() }
                } else if fixture.id == "legacy-unscoped-callback-stops-current" {
                    try await startOld { await callbackGate.wait(); await intake.stop(deviceID: oldDevice); await callbackReturned.wait() }
                } else { try await startOld() }
            case "stop_old":
                if ["callback-self-stop", "callback-stop-all", "callbacks-stop-each-other"].contains(fixture.id) {
                    oldStop = Task { await intake.stop(deviceID: oldDevice) }
                } else { oldStop = coordinator.invalidate(key: "old") }
            case "release_old_start": await gate.release()
            case "await_old_stop":
                await oldStop?.value
                if fixture.id == "held-callback-allows-new-generation" || fixture.id == "legacy-unscoped-callback-stops-current" {
                    callbackPendingAfterStop = await callbackGate.isWaiting()
                }
            case "stop_old_hold_return_after_job_and_callback_finish":
                oldStop = coordinator.invalidate(key: "old"); await gate.waitUntilEntered()
            case "start_new_same_entry": try await startNew()
            case "start_new_other_entry_same_device": try await startNew(key: "new")
            case "release_old_stop_return": await gate.release(); await notificationDone.release(); await oldStop?.value
            case "hold_old_connection_monitor":
                monitor = Task { await coordinator.checkConnection(key: "old", token: old, check: {
                    await monitorGate.wait(); return false
                }, onDisconnected: { _ = coordinator.invalidate(key: "old") }) }
                await monitorGate.waitUntilEntered()
            case "deliver_old_monitor_disconnected": await monitorGate.release(); await monitor?.value
            case "stop_old_hold_job_exit": oldStop = coordinator.invalidate(key: "old"); await jobGate.waitUntilEntered()
            case "start_new_same_entry_expect_busy":
                try await startNew(); XCTAssertTrue(busy, fixture.id)
                oldAlive = await intake.isRunning(deviceID: oldDevice, token: old)
                secondStop = coordinator.invalidate(key: "old"); await secondStop?.value
            case "start_new_other_entry_same_device_expect_busy":
                try await startNew(key: "new"); XCTAssertTrue(busy, fixture.id)
                oldAlive = await intake.isRunning(deviceID: oldDevice, token: old)
            case "finish_failed_new_cleanup": secondStop = coordinator.invalidate(key: "new"); await secondStop?.value
            case "observe_old_still_running":
                let running = await intake.isRunning(deviceID: oldDevice, token: old); XCTAssertTrue(running, fixture.id)
            case "observe_no_automatic_retry":
                // A second explicit start is only made by the later fixture step.
                let deliveries = await metrics.deliveryCount()
                autoRetries = max(0, deliveries - newAttempts)
            case "release_old_job": await jobGate.release()
            case "fresh_user_start_new": try await startNew()
            case "hold_second_start_before_intake":
                newAttempts += 1; newDevice = otherDevice
                secondStart = try begin("new", other, otherDevice); await gate.waitUntilEntered()
            case "suspend_hold_old_job_exit":
                oldStop = coordinator.invalidate(key: "old"); secondStop = coordinator.invalidate(key: "new")
                await jobGate.waitUntilEntered()
            case "release_second_start": await gate.release()
            case "observe_second_never_starts":
                do { _ = try await secondStart!.value; XCTFail("cancelled start returned: \(fixture.id)") }
                catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
            case "await_suspension": await oldStop?.value; await secondStop?.value
            case "stop_old_hold_onStopped_notification": oldStop = coordinator.invalidate(key: "old"); await callbackGate.waitUntilEntered()
            case "release_old_token_scoped_notification":
                await callbackGate.release(); await notificationDone.waitUntilEntered(); await notificationDone.release()
            case "stop_old_hold_unscoped_notification":
                oldStop = Task { await intake.stop(deviceID: oldDevice) }; await callbackGate.waitUntilEntered()
            case "release_old_notification_calling_unscoped_stop":
                await callbackGate.release(); await callbackReturned.waitUntilEntered(); await callbackReturned.release()
            case "await_new_stop": break
            case "onStopped_stop_same_device", "onStopped_stop_all": break
            case "observe_callback_stop_returned", "observe_stop_all_returned":
                await callbackReturned.waitUntilEntered(); callbackPendingAfterStop = true
            case "finish_callback", "finish_callbacks": await callbackReturned.release(); await callbackGate.release()
            case "start_two_devices":
                if fixture.id == "callbacks-stop-each-other" {
                    try await startOld { await intake.stop(deviceID: otherDevice); await callbackReturned.wait(); await callbackGate.wait() }
                    newAttempts += 1; newDevice = otherDevice
                    secondStart = try begin("new", other, otherDevice, callback: { await intake.stop(deviceID: oldDevice); await callbackReturned.wait(); await callbackGate.wait() })
                    let started = try await secondStart!.value; XCTAssertTrue(started); await metrics.waitFor(other)
                } else {
                    try await startOld { await intake.stopAll(); await callbackReturned.wait(); await callbackGate.wait() }
                    try await startNew(key: "new", device: otherDevice, token: other)
                }
            case "stop_both":
                oldStop = Task { await intake.stop(deviceID: oldDevice) }; secondStop = Task { await intake.stop(deviceID: otherDevice) }
            case "callbacks_stop_other_device": break
            case "observe_both_callback_stops_returned":
                // Both notifications must finish their cross-stop before either gate is released.
                await callbackReturned.waitUntilEntered(2); callbackPendingAfterStop = true
            case "start_external_stop_all": secondStop = Task { await intake.stopAll() }
            case "await_both_stops": await oldStop?.value; await secondStop?.value
            case "await_external_stop_all": await secondStop?.value; await oldStop?.value
            default: XCTFail("unimplemented fixture step \(step) in \(fixture.id)")
            }
        }
        let finalOld = await intake.isRunning(deviceID: oldDevice, token: old)
        let finalNew = await intake.isRunning(deviceID: newDevice, token: newDevice == otherDevice ? other : currentNew)
        XCTAssertEqual(finalOld, fixture.expected.old_running, fixture.id)
        XCTAssertEqual(finalNew, fixture.expected.new_running, fixture.id)
        XCTAssertEqual(busy, fixture.expected.busy, fixture.id)
        XCTAssertEqual(oldAlive, fixture.expected.old_alive_during_busy, fixture.id)
        let peak = await metrics.peak()
        XCTAssertEqual(peak, fixture.expected.max_live_jobs, fixture.id)
        XCTAssertEqual(newAttempts, fixture.expected.new_start_attempts, fixture.id)
        let deliveries = await metrics.deliveryCount()
        let deliveriesByToken = await metrics.deliveriesByToken()
        XCTAssertTrue(deliveriesByToken.values.allSatisfy { $0 == 1 }, "token retried: \(fixture.id)")
        autoRetries = max(autoRetries, deliveries - newAttempts)
        XCTAssertEqual(autoRetries, fixture.expected.auto_retries, fixture.id)
        if let expected = fixture.expected.callback_can_be_pending_after_stop { XCTAssertEqual(callbackPendingAfterStop, expected, fixture.id) }
        let cleanOld = coordinator.invalidate(key: "old"), cleanNew = coordinator.invalidate(key: "new")
        await cleanOld?.value; await cleanNew?.value
        await intake.stopAll()
    }
}

extension DeviceTaskGrantGenerationTests {
    func testRealExecutorKeepsDeviceBusyDuringUncooperativeAccept() async throws {
        let resources = GenerationResources()
        let done = expectation(description: "real executor revocation completes")
        var completed = false
        let operation = Task {
            do { try await self.runRealExecutor(resources: resources) }
            catch { XCTFail("real executor scenario threw: \(error)") }
            completed = true; done.fulfill()
        }
        await fulfillment(of: [done], timeout: 8)
        if !completed {
            operation.cancel()
            if let cleanup = await resources.release() {
                let cleanupDone = expectation(description: "timed-out executor cleanup")
                Task { await cleanup.value; cleanupDone.fulfill() }
                await fulfillment(of: [cleanupDone], timeout: 2)
            }
        }
    }

    private func runRealExecutor(resources: GenerationResources) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = GenerationRunner(), acceptGate = GenerationGate()
        let entered = expectation(description: "real executor entered inbox acceptance")
        let inbox = BlockingGenerationInbox(gate: acceptGate, started: entered)
        let intake = DeviceTaskIntake(executor: try DeviceTaskExecutor(directory: directory, runner: runner))
        let coordinator = DeviceTaskGrantCoordinator()
        resources.gates = [acceptGate]; resources.intake = intake
        let task = try DeviceTask.decode(Data(#"{"id":"grant-task","idempotency_key":"grant-key","requester":"test","created_at":"2026-11-06T00:00:00Z","body":{"type":"goal","text":"hello"}}"#.utf8))
        let feed = GenerationOneTaskFeed(task)
        let old = UUID(), attempted = UUID(), fresh = UUID(), device = "lan:real-executor"
        defer { Task { await acceptGate.release(); await intake.stopAll() } }
        let start = try coordinator.start(key: "entry", token: old, deviceID: device, intake: intake, inbox: inbox) { try await feed.next() }
        let started = try await start.value; XCTAssertTrue(started)
        await fulfillment(of: [entered], timeout: 5)
        let initialCounts = await inbox.counts()
        guard initialCounts.0 == 1 else { return XCTFail("real accept did not start") }
        let oldStop = coordinator.invalidate(key: "entry")
        let next = try coordinator.start(key: "entry", token: attempted, deviceID: device, intake: intake, inbox: inbox) { nil }
        let busyResult = try await next.value
        XCTAssertFalse(busyResult, "cancelling an in-flight accept must keep its device busy")
        let failedCleanup = coordinator.invalidate(key: "entry"); await failedCleanup?.value
        let oldStillOwns = await intake.isRunning(deviceID: device, token: old)
        XCTAssertTrue(oldStillOwns)
        let whileBlocked = await inbox.counts(), blockedRuns = await runner.count()
        XCTAssertEqual(whileBlocked.0, 1); XCTAssertEqual(whileBlocked.1, 0); XCTAssertEqual(blockedRuns, 0)
        await acceptGate.release()
        await oldStop?.value
        let afterStop = await inbox.counts(), finalRuns = await runner.count()
        XCTAssertEqual(afterStop.0, 1); XCTAssertEqual(afterStop.1, 0); XCTAssertEqual(finalRuns, 0)
        let retry = try coordinator.start(key: "entry", token: fresh, deviceID: device, intake: intake, inbox: inbox) {
            try await Task.sleep(for: .seconds(3600)); return nil
        }
        let retryStarted = try await retry.value
        XCTAssertTrue(retryStarted, "a fresh explicit grant can start after the old worker exits")
        let finalStop = coordinator.invalidate(key: "entry"); await finalStop?.value
    }
}

extension DeviceTaskGrantGenerationTests {
    func testWatchdogReleasesObserversAndLateWaiters() async throws {
        let resources = GenerationResources(), gate = GenerationGate(), metrics = GenerationMetrics()
        resources.gates = [gate]; resources.metrics = metrics
        let token = UUID()
        let gateDone = expectation(description: "gate observer released")
        let metricDone = expectation(description: "metric observer released")
        Task { await gate.waitUntilEntered(); gateDone.fulfill() }
        Task { await metrics.waitFor(token); metricDone.fulfill() }
        for _ in 0..<200 {
            let gates = await gate.observerCount(), waiters = await metrics.waiterCount()
            if gates == 1 && waiters == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let gateCount = await gate.observerCount(), metricCount = await metrics.waiterCount()
        XCTAssertEqual(gateCount, 1); XCTAssertEqual(metricCount, 1)
        _ = await resources.release()
        await fulfillment(of: [gateDone, metricDone], timeout: 2)
        let lateGate = expectation(description: "late gate observer released")
        let lateMetric = expectation(description: "late metric observer released")
        Task { await gate.waitUntilEntered(); lateGate.fulfill() }
        Task { await metrics.waitFor(token); lateMetric.fulfill() }
        await fulfillment(of: [lateGate, lateMetric], timeout: 2)
    }
}
