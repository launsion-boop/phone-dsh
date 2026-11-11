// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// An erasure epoch switch archives the main chat that may have delegated a
/// Task. The Task keeps its own session and durable parent, but its one parent
/// wake and the `AwaitTask`/`StopSubagent` ownership check must follow the
/// Bot's current main chat. These tests drive the real runtime actor, durable
/// event store and scripted DSH frames; no model is involved.
final class BotTaskEpochWakeTests: XCTestCase {
    private func makeParent(
        _ runtime: BotMCPRuntime, sessionId: String = "gb-main",
        kind: BotSessionKind = .chat, callId: String = UUID().uuidString
    ) async throws -> BotResolvedToolCall {
        let principal = try await runtime.issueSession(
            botId: "main", sessionId: sessionId, kind: kind)
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
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition did not become true", file: file, line: line)
    }

    private func waitForStatus(_ remote: BotDSHRemoteRuntime, taskID: String,
                               parent: BotResolvedToolCall, status: String,
                               file: StaticString = #filePath, line: UInt = #line) async throws
        -> BotTaskRecord {
        var record = try await remote.await(taskId: taskID, timeoutMs: 50, parent: parent)
        for _ in 0..<400 {
            if record.status == status { return record }
            try await Task.sleep(nanoseconds: 5_000_000)
            record = try await remote.await(taskId: taskID, timeoutMs: 50, parent: parent)
        }
        XCTFail("task did not reach \(status): \(record.status)", file: file, line: line)
        return record
    }

    private func assertUnauthorized(
        _ operation: @escaping @Sendable () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("expected cross-parent operation to fail", file: file, line: line)
        } catch BotMCPError.unauthorized {
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
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

    /// Establishes `gb-main` and starts one paused async Task from `parent`.
    private func startPausedTask(
        _ fixture: BotMCPTestFixture, _ transport: BotScriptedRemoteTransport,
        parent: BotResolvedToolCall, title: String, prompt: String,
        taskEvents: [BotScriptedEvent]
    ) async throws -> (remote: BotDSHRemoteRuntime, task: BotTaskRecord) {
        let remote = try await BotDSHRemoteRuntime(transport: transport, runtime: fixture.runtime)
        _ = try await remote.sendUserMessage("parent")
        transport.pause("gb-created-1")
        transport.queue(sessionId: "gb-created-1", events: taskEvents)
        let task = try await remote.start(request: BotTaskRequest(
            parent: parent, title: title, prompt: prompt,
            asynchronous: true, timeoutMs: 5_000))
        try await waitUntil {
            transport.promptHistory.contains { $0.sessionId == task.sessionId }
        }
        return (remote, task)
    }

    private func feedParentTurn(
        _ transport: BotScriptedRemoteTransport, sessionId: String = "gb-main",
        turn: Int = 1, text: String = "parent"
    ) {
        transport.queue(sessionId: sessionId, events: [
            .turn(turn), .assistant(text), .end(turn: turn),
        ])
    }

    // MARK: - Completion

    func testEpochSwitchRoutesCompletionWakeToNewMainOnce() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let transport = BotScriptedRemoteTransport(scripts: [:])
        let parent = try await makeParent(fixture.runtime)
        feedParentTurn(transport)
        let setup = try await startPausedTask(
            fixture, transport, parent: parent, title: "Epoch completion", prompt: "work",
            taskEvents: [.turn(), .assistant("done"), .end()])
        XCTAssertEqual(setup.task.sessionId, "gb-created-1")

        let switched = try await setup.remote.switchMainSessionForErasure(
            erasureID: "erasure-completion", erasedRecords: [])
        XCTAssertEqual(switched.old, parent.sessionId)
        XCTAssertNotEqual(switched.new, switched.old)
        XCTAssertNotEqual(switched.new, setup.task.sessionId)

        feedParentTurn(transport, sessionId: switched.new, turn: 2, text: "wake consumed")
        transport.resume(setup.task.sessionId)

        let completed = try await waitForStatus(
            setup.remote, taskID: setup.task.taskId, parent: parent, status: "completed")
        XCTAssertEqual(completed.sessionId, setup.task.sessionId)
        XCTAssertEqual(completed.result, "done")

        let requestID = "task-settled:\(setup.task.taskId)"
        try await waitUntil {
            transport.promptRequestIds.contains {
                $0.sessionId == switched.new && $0.requestId == requestID
            }
        }
        let wakes = transport.promptRequestIds.filter { $0.requestId == requestID }
        XCTAssertEqual(wakes.map(\.sessionId), [switched.new],
                       "the current main session must receive the only wake")
        XCTAssertFalse(transport.promptRequestIds.contains {
            $0.sessionId == switched.old && $0.requestId == requestID
        })

        // A Worker restart after the terminal record must neither replay the
        // wake nor lose the Task's durable session.
        _ = await fixture.runtime.workerRestarted()
        let replayed = await setup.remote.deliverInterruptedTaskWakes()
        XCTAssertEqual(replayed, 0)
        XCTAssertEqual(transport.promptRequestIds.filter { $0.requestId == requestID }
            .map(\.sessionId), [switched.new])
    }

    // MARK: - Denied

    func testEpochSwitchRoutesDeniedWakeToNewMainOnceAfterWorkerRestart() async throws {
        let fixture = try makeBotMCPFixture(approvalExpiryMs: 60_000)
        defer { fixture.cleanup() }
        let transport = BotScriptedRemoteTransport(scripts: [:])
        let parent = try await makeParent(fixture.runtime)
        feedParentTurn(transport)
        let setup = try await startPausedTask(
            fixture, transport, parent: parent, title: "Epoch denial", prompt: "work",
            taskEvents: [.turn(), .end()])
        let (digest, approvalID) = try await issueTaskApproval(
            fixture, taskSession: setup.task.sessionId, callID: "epoch-denied")

        transport.resume(setup.task.sessionId)
        _ = try await waitForStatus(
            setup.remote, taskID: setup.task.taskId, parent: parent,
            status: "waiting_approval")

        let switched = try await setup.remote.switchMainSessionForErasure(
            erasureID: "erasure-denied", erasedRecords: [])
        XCTAssertEqual(switched.old, parent.sessionId)
        XCTAssertNotEqual(switched.new, switched.old)
        feedParentTurn(transport, sessionId: switched.new, turn: 2, text: "denied wake consumed")

        // The parked Task survives the replaced Worker; the decision is made
        // after the restart and must still wake the new main session.
        _ = await fixture.runtime.workerRestarted()
        let resolved = await fixture.runtime.approvals.resolve(
            approvalId: approvalID, decision: .deny, digest: digest)
        XCTAssertEqual(resolved, .resolved)

        let denied = try await waitForStatus(
            setup.remote, taskID: setup.task.taskId, parent: parent, status: "denied")
        XCTAssertEqual(denied.error, "approval_denied")
        XCTAssertEqual(denied.sessionId, setup.task.sessionId)

        let requestID = "task-settled:\(setup.task.taskId):approval:\(approvalID)"
        try await waitUntil {
            transport.promptRequestIds.contains {
                $0.sessionId == switched.new && $0.requestId == requestID
            }
        }
        XCTAssertEqual(transport.promptRequestIds.filter { $0.requestId == requestID }
            .map(\.sessionId), [switched.new])
        XCTAssertFalse(transport.promptRequestIds.contains {
            $0.sessionId == switched.old && $0.requestId == requestID
        })
    }

    // MARK: - Interrupted / restart

    func testEpochSwitchRoutesInterruptedWakeToNewMainAfterProcessRestart() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let transport = BotScriptedRemoteTransport(scripts: [:])
        let parent = try await makeParent(fixture.runtime)
        feedParentTurn(transport)
        let setup = try await startPausedTask(
            fixture, transport, parent: parent, title: "Epoch interrupted", prompt: "work",
            taskEvents: [.turn()])

        let switched = try await setup.remote.switchMainSessionForErasure(
            erasureID: "erasure-interrupted", erasedRecords: [])
        XCTAssertEqual(switched.old, parent.sessionId)
        feedParentTurn(transport, sessionId: switched.new, turn: 2, text: "restart wake consumed")

        // A fresh runtime is the new process. The Task snapshot is still
        // `running`, so restore applies `worker_restarted`, rebuilds the epoch
        // history from the durable runtime.started events and queues one wake.
        let restored = try await BotDSHRemoteRuntime(
            transport: transport, runtime: fixture.runtime)
        let delivered = await restored.deliverInterruptedTaskWakes()
        XCTAssertEqual(delivered, 1)
        let requestID = "task-interrupted:\(setup.task.taskId)"
        XCTAssertEqual(transport.promptRequestIds.filter { $0.requestId == requestID }
            .map(\.sessionId), [switched.new])
        XCTAssertFalse(transport.promptRequestIds.contains {
            $0.sessionId == switched.old && $0.requestId == requestID
        })
        let replayed = await restored.deliverInterruptedTaskWakes()
        XCTAssertEqual(replayed, 0)

        let interrupted = try await restored.await(
            taskId: setup.task.taskId, timeoutMs: 50, parent: parent)
        XCTAssertEqual(interrupted.status, "interrupted")
        XCTAssertEqual(interrupted.error, "worker_restarted")
        XCTAssertEqual(interrupted.sessionId, setup.task.sessionId)

        let newParent = try await makeParent(
            fixture.runtime, sessionId: switched.new, callId: "epoch-new-parent")
        let viaNewMain = try await restored.await(
            taskId: setup.task.taskId, timeoutMs: 50, parent: newParent)
        XCTAssertEqual(viaNewMain.status, "interrupted")
        let otherParent = try await makeParent(
            fixture.runtime, sessionId: "gb-other", callId: "epoch-other-parent")
        await assertUnauthorized {
            _ = try await restored.await(
                taskId: setup.task.taskId, timeoutMs: 50, parent: otherParent)
        }
        await assertUnauthorized {
            _ = try await restored.stop(
                taskId: setup.task.taskId, parent: otherParent)
        }
        // Release the replaced process's paused turn after all assertions.
        _ = await setup.remote.workerRestarted()
        transport.resume(setup.task.sessionId)
    }

    // MARK: - Deliberate host park

    /// The S6 epoch eraser parks the Worker while a `session/follow` is open.
    /// That EOF is an expected interruption: the Task must not be settled as
    /// `failed`, and the queued `task-interrupted:` wake must reach the new
    /// main session after the replacement Worker is attached.
    func testIntentionalParkTurnsFollowEOFIntoInterruptedWakeOnNewMain() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let transport = BotScriptedRemoteTransport(scripts: [:])
        let parent = try await makeParent(fixture.runtime)
        feedParentTurn(transport)
        let setup = try await startPausedTask(
            fixture, transport, parent: parent, title: "Parked task", prompt: "long work",
            taskEvents: [.turn()])

        let switched = try await setup.remote.switchMainSessionForErasure(
            erasureID: "erasure-park", erasedRecords: [])
        XCTAssertEqual(switched.old, parent.sessionId)
        feedParentTurn(transport, sessionId: switched.new, turn: 2, text: "interrupted wake consumed")

        // The eraser marks the deliberate park before host.park(); the open
        // follow stream then ends without a turn/end.
        await setup.remote.beginHostPark()
        transport.resume(setup.task.sessionId)

        let interrupted = try await waitForStatus(
            setup.remote, taskID: setup.task.taskId, parent: parent,
            status: "interrupted")
        XCTAssertEqual(interrupted.error, "worker_restarted")
        XCTAssertEqual(interrupted.sessionId, setup.task.sessionId)
        await setup.remote.endHostPark()

        let delivered = await setup.remote.deliverInterruptedTaskWakes()
        XCTAssertEqual(delivered, 1)
        let requestID = "task-interrupted:\(setup.task.taskId)"
        try await waitUntil {
            transport.promptRequestIds.contains {
                $0.sessionId == switched.new && $0.requestId == requestID
            }
        }
        XCTAssertEqual(transport.promptRequestIds.filter { $0.requestId == requestID }
            .map(\.sessionId), [switched.new])
        XCTAssertFalse(transport.promptRequestIds.contains {
            $0.sessionId == switched.old && $0.requestId == requestID
        })
        let replayed = await setup.remote.deliverInterruptedTaskWakes()
        XCTAssertEqual(replayed, 0, "the interrupted wake is delivered exactly once")
        XCTAssertFalse(transport.promptRequestIds.contains {
            $0.requestId == "task-settled:\(setup.task.taskId)"
        })
    }

    /// The same EOF outside a deliberate park is a real failure. The park
    /// signal must not swallow genuine transport errors.
    func testFollowEOFWithoutIntentionalParkRemainsFailed() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let transport = BotScriptedRemoteTransport(scripts: [:])
        let parent = try await makeParent(fixture.runtime)
        feedParentTurn(transport)
        let setup = try await startPausedTask(
            fixture, transport, parent: parent, title: "Broken task", prompt: "work",
            taskEvents: [.turn()])
        transport.resume(setup.task.sessionId)

        let failed = try await waitForStatus(
            setup.remote, taskID: setup.task.taskId, parent: parent, status: "failed")
        XCTAssertEqual(failed.error, "session/follow ended before turn/end")
    }

    // MARK: - AwaitTask / StopSubagent

    func testEpochSwitchNewMainCanAwaitAndStopTaskAndOtherSessionsAreRejected() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let transport = BotScriptedRemoteTransport(scripts: [:])
        let parent = try await makeParent(fixture.runtime)
        feedParentTurn(transport)
        let setup = try await startPausedTask(
            fixture, transport, parent: parent, title: "Epoch stop", prompt: "long work",
            taskEvents: [.turn(), .assistant("late completion"), .end()])

        let switched = try await setup.remote.switchMainSessionForErasure(
            erasureID: "erasure-stop", erasedRecords: [])
        XCTAssertEqual(switched.old, parent.sessionId)

        let newParent = try await makeParent(
            fixture.runtime, sessionId: switched.new, callId: "epoch-await-parent")
        let otherParent = try await makeParent(
            fixture.runtime, sessionId: "gb-other", callId: "epoch-other-stop")
        await assertUnauthorized {
            _ = try await setup.remote.await(
                taskId: setup.task.taskId, timeoutMs: 50, parent: otherParent)
        }
        await assertUnauthorized {
            _ = try await setup.remote.stop(
                taskId: setup.task.taskId, parent: otherParent)
        }

        let stopping = Task {
            try await setup.remote.stop(
                taskId: setup.task.taskId, parent: newParent)
        }
        try await waitUntil {
            transport.cancellations.contains(setup.task.sessionId)
        }
        transport.resume(setup.task.sessionId)
        let stopped = try await stopping.value
        XCTAssertEqual(stopped.status, "stopped")
        XCTAssertEqual(stopped.sessionId, setup.task.sessionId)
        await assertUnauthorized {
            _ = try await setup.remote.stop(
                taskId: setup.task.taskId, parent: otherParent)
        }
        // The current main and the original durable parent can both read the
        // terminal record; the successor did not replace the Task's session.
        let viaNewParent = try await setup.remote.await(
            taskId: setup.task.taskId, timeoutMs: 50, parent: newParent)
        XCTAssertEqual(viaNewParent.status, "stopped")
        let viaOldParent = try await setup.remote.await(
            taskId: setup.task.taskId, timeoutMs: 50, parent: parent)
        XCTAssertEqual(viaOldParent.status, "stopped")
    }

    // MARK: - Non-chat parents

    func testEpochSwitchLeavesRoutineAndTeamTaskOwnershipAndWakeUnchanged() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let transport = BotScriptedRemoteTransport(scripts: [:])
        feedParentTurn(transport)
        let remote = try await BotDSHRemoteRuntime(
            transport: transport, runtime: fixture.runtime)
        _ = try await remote.sendUserMessage("parent")

        var tasks: [(parent: BotResolvedToolCall, record: BotTaskRecord)] = []
        for kind in [BotSessionKind.routine, .team] {
            let parent = try await makeParent(
                fixture.runtime, sessionId: "gb-\(kind.rawValue)-parent",
                kind: kind, callId: UUID().uuidString)
            let index = tasks.count + 1
            let session = "gb-created-\(index)"
            transport.pause(session)
            transport.queue(sessionId: session, events: [
                .turn(), .assistant("done \(kind.rawValue)"), .end(),
            ])
            let record = try await remote.start(request: BotTaskRequest(
                parent: parent, title: "Non-chat \(kind.rawValue)", prompt: "work",
                asynchronous: true, timeoutMs: 5_000))
            XCTAssertEqual(record.sessionId, session)
            tasks.append((parent, record))
        }

        let switched = try await remote.switchMainSessionForErasure(
            erasureID: "erasure-non-chat", erasedRecords: [])
        XCTAssertEqual(switched.old, "gb-main")
        XCTAssertEqual(switched.new, "gb-created-3")
        for task in tasks { transport.resume(task.record.sessionId) }

        for task in tasks {
            let completed = try await waitForStatus(
                remote, taskID: task.record.taskId, parent: task.parent,
                status: "completed")
            XCTAssertEqual(completed.sessionId, task.record.sessionId)
            XCTAssertNil(transport.promptRequestIds.first {
                $0.requestId == "task-settled:\(task.record.taskId)"
            }, "a non-chat parent Task never wakes a chat session")
        }
        XCTAssertTrue(transport.promptRequestIds.allSatisfy {
            !$0.requestId.hasPrefix("task-settled:")
        })
        XCTAssertEqual(switched.new, "gb-created-3",
                       "the switch must not create or reuse a Task session")
    }
}
