// SPDX-License-Identifier: MIT
//
// sim-fix-rt F1: `AwaitTask` must observe the task record, not the work task
// that also sends the parent wake. The wake can still be running (or blocked)
// after the child has settled; waiting for it made a 60 s AwaitTask time out at
// the Worker's 130 s client deadline and never honoured `timeout_ms`.

import Foundation
import XCTest
@testable import PhoneDSHBot

final class BotAwaitTaskTests: XCTestCase {
    private func makeParent(_ runtime: BotMCPRuntime,
                            sessionId: String = "gb-main",
                            callId: String = UUID().uuidString) async throws -> BotResolvedToolCall {
        let principal = try await runtime.issueSession(
            botId: "main", sessionId: sessionId, kind: .chat)
        let arguments = BotJSONValue.object(["prompt": .string("parent")])
        let attribution = try await runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: sessionId,
            callId: callId, name: "Task", arguments: arguments)
        guard let call = BotResolvedToolCall(
            sessionId: sessionId, callId: callId, agentId: "main",
            principal: principal, attribution: attribution) else {
            throw BotMCPError.unauthorized
        }
        return call
    }

    /// The child settles, but the asynchronous parent wake is still blocked.
    /// AwaitTask must return the settled record immediately, not wait for the
    /// wake turn (which is outside the caller's deadline).
    func testAwaitTaskReturnsWhenTheTaskSettlesEvenIfTheParentWakeIsBlocked() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let parent = try await makeParent(fixture.runtime)
        let transport = BotScriptedRemoteTransport(scripts: [
            "gb-main": [
                [.turn(), .assistant("parent"), .end()],
                [.turn(2), .assistant("wake consumed"), .end(turn: 2)],
            ],
            "gb-created-1": [[.turn(), .assistant("done"), .end()]],
        ])
        let remote = try await BotDSHRemoteRuntime(transport: transport, runtime: fixture.runtime)
        _ = try await remote.sendUserMessage("parent")
        // The wake turn (the next gb-main script) blocks before its first
        // event. It is not part of the task record's terminal state.
        transport.pause("gb-main")
        let started = try await remote.start(request: BotTaskRequest(
            parent: parent, title: "blocked wake", prompt: "inspect",
            asynchronous: true, timeoutMs: 2_000))
        transport.resume(started.sessionId)

        // Keep a pre-fix run from hanging the whole suite: the blocked wake is
        // released shortly after the assertion window.
        let release = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            transport.resume("gb-main")
        }
        defer {
            release.cancel()
            transport.resume("gb-main")
        }

        let clock = Date()
        let settled = try await remote.await(
            taskId: started.taskId, timeoutMs: 2_000, parent: parent)
        let elapsed = Date().timeIntervalSince(clock)
        XCTAssertEqual(settled.status, "completed")
        XCTAssertLessThan(elapsed, 1.0,
                          "AwaitTask waited for the parent wake instead of the record")
    }

    /// A still-running task must return at `timeout_ms` with its running
    /// record. The old task-group helper waited for the timed-out child to
    /// finish, so the caller saw the Worker's 130 s deadline.
    func testAwaitTaskTimeoutReturnsTheRunningRecord() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let parent = try await makeParent(fixture.runtime)
        let transport = BotScriptedRemoteTransport(scripts: [
            "gb-main": [[.turn(), .assistant("parent"), .end()]],
            "gb-created-1": [[.turn(), .assistant("done"), .end()]],
        ])
        let remote = try await BotDSHRemoteRuntime(transport: transport, runtime: fixture.runtime)
        _ = try await remote.sendUserMessage("parent")
        transport.pause("gb-created-1")
        let started = try await remote.start(request: BotTaskRequest(
            parent: parent, title: "slow child", prompt: "inspect",
            asynchronous: true, timeoutMs: 2_000))

        // Release the child after the timeout window so a pre-fix run returns
        // (with the wrong completed record) instead of hanging.
        let release = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            transport.resume("gb-created-1")
        }
        defer {
            release.cancel()
            transport.resume("gb-created-1")
        }

        let clock = Date()
        let record = try await remote.await(
            taskId: started.taskId, timeoutMs: 100, parent: parent)
        let elapsed = Date().timeIntervalSince(clock)
        XCTAssertEqual(record.status, "running",
                       "a timed-out AwaitTask must return the still-running record")
        XCTAssertLessThan(elapsed, 1.0,
                          "AwaitTask slept until the child finished instead of its timeout")
    }

    /// A task that already settled returns without a wait. This is the
    /// "completed before the waiter registered" race.
    func testAwaitTaskReturnsAlreadyCompletedTaskImmediately() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let parent = try await makeParent(fixture.runtime)
        let transport = BotScriptedRemoteTransport(scripts: [
            "gb-main": [
                [.turn(), .assistant("parent"), .end()],
                [.turn(2), .assistant("wake"), .end(turn: 2)],
            ],
            "gb-created-1": [[.turn(), .assistant("done"), .end()]],
        ])
        let remote = try await BotDSHRemoteRuntime(transport: transport, runtime: fixture.runtime)
        _ = try await remote.sendUserMessage("parent")
        let started = try await remote.start(request: BotTaskRequest(
            parent: parent, title: "fast child", prompt: "inspect",
            asynchronous: true, timeoutMs: 2_000))
        _ = try await remote.await(taskId: started.taskId, timeoutMs: 2_000, parent: parent)

        let clock = Date()
        let settled = try await remote.await(
            taskId: started.taskId, timeoutMs: 60_000, parent: parent)
        let elapsed = Date().timeIntervalSince(clock)
        XCTAssertEqual(settled.status, "completed")
        XCTAssertLessThan(elapsed, 0.5,
                          "an already completed task must return immediately")
    }
}
