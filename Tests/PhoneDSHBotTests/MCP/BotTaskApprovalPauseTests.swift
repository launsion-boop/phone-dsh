// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// End-to-end host path for a durable approval inside an asynchronous Task:
/// the task parks at `waiting_approval`, survives a Worker restart, and resumes
/// or ends denied after the user decision. The scripted transport only drives
/// the DSH session frames; no model is involved.
final class BotTaskApprovalPauseTests: XCTestCase {
    private func makeParent(_ runtime: BotMCPRuntime, sessionId: String = "gb-main",
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

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition did not become true", file: file, line: line)
    }

    private func waitForStatus(_ remote: BotDSHRemoteRuntime, taskID: String,
                               parent: BotResolvedToolCall, status: String) async throws
        -> BotTaskRecord {
        var record = try await remote.await(taskId: taskID, timeoutMs: 200, parent: parent)
        for _ in 0..<300 {
            record = try await remote.await(taskId: taskID, timeoutMs: 200, parent: parent)
            if record.status == status { return record }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return record
    }

    private func issueTaskApproval(
        _ fixture: BotMCPTestFixture, taskSession: String, callID: String
    ) async throws -> (digest: String, approvalID: String) {
        let args = BotJSONValue.object([
            "action": .string("forget"), "scope": .string("user"), "fact": .string("task"),
        ])
        _ = try await fixture.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: taskSession,
            callId: callID, name: "UpdateMemory", arguments: args)
        let digest = try BotArgumentsDigest.string(for: args)
        let outcome = await fixture.runtime.approve(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: taskSession,
            callId: callID, name: "UpdateMemory", action: "Forget a memory",
            detail: "task approval", command: "", argsDigest: digest,
            alwaysScope: "until", askAction: "tool-call")
        XCTAssertTrue(outcome.pending, outcome.message ?? "")
        return (digest, try XCTUnwrap(outcome.approvalId))
    }

    private func makeRunningTask(
        _ fixture: BotMCPTestFixture,
        _ transport: BotScriptedRemoteTransport,
        firstTurn: [BotScriptedEvent]
    ) async throws -> (remote: BotDSHRemoteRuntime, parent: BotResolvedToolCall,
                       task: BotTaskRecord) {
        let parent = try await makeParent(fixture.runtime)
        transport.queue(sessionId: "gb-main", events: [
            .turn(), .assistant("parent"), .end(),
        ])
        let remote = try await BotDSHRemoteRuntime(transport: transport, runtime: fixture.runtime)
        _ = try await remote.sendUserMessage("parent")
        transport.pause("gb-created-1")
        transport.queue(sessionId: "gb-created-1", events: firstTurn)
        let task = try await remote.start(request: BotTaskRequest(
            parent: parent, title: "Approval task", prompt: "do the work",
            asynchronous: true, timeoutMs: 5_000))
        try await waitUntil { transport.promptHistory.contains { $0.sessionId == task.sessionId } }
        return (remote, parent, task)
    }

    func testTaskParksOnDurableApprovalThenResumesAfterApprovalAndRestart() async throws {
        let fixture = try makeBotMCPFixture(approvalExpiryMs: 60_000)
        defer { fixture.cleanup() }
        let transport = BotScriptedRemoteTransport(scripts: [:])
        let setup = try await makeRunningTask(
            fixture, transport, firstTurn: [.turn(), .end()])
        let (digest, approvalID) = try await issueTaskApproval(
            fixture, taskSession: setup.task.sessionId, callID: "task-call")

        transport.resume("gb-created-1")
        let parked = try await waitForStatus(
            setup.remote, taskID: setup.task.taskId, parent: setup.parent,
            status: "waiting_approval")
        XCTAssertEqual(parked.error, "approval_pending")
        let pending = await fixture.runtime.approvals.pendingIDs
        XCTAssertEqual(pending, [approvalID])
        let eventsBeforeRestart = try await botEvents(fixture.store)
        XCTAssertFalse(eventsBeforeRestart.contains {
            $0.type == "task.settled" && $0.data["task_id"] == .string(setup.task.taskId)
        })

        // A Worker restart must not cancel the todo or turn the parked task
        // into an interrupted one.
        _ = await fixture.runtime.workerRestarted()
        let afterRestart = try await setup.remote.await(
            taskId: setup.task.taskId, timeoutMs: 200, parent: setup.parent)
        XCTAssertEqual(afterRestart.status, "waiting_approval")
        let pendingAfterRestart = await fixture.runtime.approvals.pendingIDs
        XCTAssertEqual(pendingAfterRestart, [approvalID])

        transport.queue(sessionId: setup.task.sessionId, events: [
            .turn(2), .assistant("resumed"), .end(turn: 2),
        ])
        let resolved = await fixture.runtime.approvals.resolve(
            approvalId: approvalID, decision: .allowOnce, digest: digest)
        XCTAssertEqual(resolved, .resolved)
        let completed = try await waitForStatus(
            setup.remote, taskID: setup.task.taskId, parent: setup.parent,
            status: "completed")
        XCTAssertEqual(completed.status, "completed")
        XCTAssertEqual(completed.result, "resumed")
        let resumedPrompt = transport.promptHistory.last(where: {
            $0.sessionId == setup.task.sessionId && $0.text.contains("[approval_resume]")
        })
        XCTAssertNotNil(resumedPrompt)
        XCTAssertTrue(transport.promptRequestIds.contains {
            $0.sessionId == setup.task.sessionId
                && $0.requestId == "task-turn:\(setup.task.taskId):approval:\(approvalID)"
        })
        let events = try await botEvents(fixture.store)
        XCTAssertTrue(events.contains {
            $0.type == "task.resumed" && $0.data["approvalID"] == .string(approvalID)
        })
        XCTAssertTrue(events.contains {
            $0.type == "task.settled" && $0.data["task_id"] == .string(setup.task.taskId)
                && $0.data["status"] == .string("completed")
        })
    }

    func testDeniedDurableApprovalEndsTaskAndWakesParentOnce() async throws {
        let fixture = try makeBotMCPFixture(approvalExpiryMs: 60_000)
        defer { fixture.cleanup() }
        let transport = BotScriptedRemoteTransport(scripts: [:])
        let setup = try await makeRunningTask(
            fixture, transport, firstTurn: [.turn(), .end()])
        let (digest, approvalID) = try await issueTaskApproval(
            fixture, taskSession: setup.task.sessionId, callID: "task-denied")
        transport.resume("gb-created-1")
        _ = try await waitForStatus(
            setup.remote, taskID: setup.task.taskId, parent: setup.parent,
            status: "waiting_approval")

        transport.queue(sessionId: "gb-main", events: [
            .turn(2), .assistant("denied"), .end(turn: 2),
        ])
        let resolved = await fixture.runtime.approvals.resolve(
            approvalId: approvalID, decision: .deny, digest: digest)
        XCTAssertEqual(resolved, .resolved)
        let denied = try await waitForStatus(
            setup.remote, taskID: setup.task.taskId, parent: setup.parent,
            status: "denied")
        XCTAssertEqual(denied.error, "approval_denied")
        try await waitUntil {
            transport.promptRequestIds.contains {
                $0.sessionId == "gb-main"
                    && $0.requestId == "task-settled:\(setup.task.taskId):approval:\(approvalID)"
            }
        }
        let events = try await botEvents(fixture.store)
        XCTAssertTrue(events.contains {
            $0.type == "task.settled" && $0.data["task_id"] == .string(setup.task.taskId)
                && $0.data["status"] == .string("denied")
        })
        let grants = await fixture.runtime.grants.list(botId: "main")
        XCTAssertFalse(grants.contains { $0.operation == "memory.forget" })
    }
}
