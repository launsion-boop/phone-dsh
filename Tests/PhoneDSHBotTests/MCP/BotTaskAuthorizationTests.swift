// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class BotTaskAuthorizationTests: XCTestCase {
    func testTaskResultCarriesResolvedSubsetAndAwaitMatches() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let transport = BotScriptedRemoteTransport(scripts: [
            "gb-main": [[.turn(), .assistant("parent"), .end()]],
            "gb-created-1": [[.turn(), .assistant("done"), .end()]],
        ])
        let remote = try await BotDSHRemoteRuntime(
            transport: transport, runtime: fixture.runtime)
        _ = try await remote.sendUserMessage("parent")
        await beginUserTurn(fixture.runtime, rpcId: "bot-task-dispatch")
        let started = try await registerAndExecute(
            fixture.runtime, name: "Task", arguments: .object([
                "task_title": .string("Scoped task"), "prompt": .string("inspect"),
                "allowed_write_directories": .array([.string("notes")]),
                "async": .bool(false),
            ]))
        await fixture.runtime.endTurn(sessionId: "gb-main")
        let authorization = try XCTUnwrap(started.structuredContent?["authorization"])
        let directories = authorization["allowedWriteDirectories"]?.arrayValue?
            .compactMap(\.stringValue) ?? []
        let expected = BotWorkspaceLayout.botRoot(botId: "main") + "/notes"
        XCTAssertEqual(directories, [expected])
        XCTAssertEqual(authorization["workspaceRoot"], .string(BotWorkspaceLayout.botRoot(botId: "main")))
        XCTAssertEqual(authorization["canWriteOutsideWorkspace"], .bool(false))
        XCTAssertEqual(authorization["canNetworkWrite"], .bool(false))
        XCTAssertEqual(authorization["canDelegateTasks"], .bool(false))

        let awaited = try await registerAndExecute(
            fixture.runtime, name: "AwaitTask", arguments: .object([
                "task_id": .string(try XCTUnwrap(started.structuredContent?["task_id"]?.stringValue)),
            ]))
        XCTAssertEqual(awaited.structuredContent?["authorization"], authorization,
                       "AwaitTask must report the same persisted subset")
        let prompt = try XCTUnwrap(transport.prompts["gb-created-1"]?.text)
        XCTAssertTrue(prompt.contains("<task_authorization>"),
                      "the child must be told its capability subset: \(prompt)")
        XCTAssertTrue(prompt.contains("network_write: false"))
        XCTAssertTrue(prompt.contains("delegate_tasks: false"))
    }

    func testChildTaskCannotDispatchAnotherTaskByDefault() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(
            botId: "main", sessionId: "gb-task-child", kind: .task)
        let result = try await registerAndExecute(
            fixture.runtime, name: "Task",
            arguments: .object(["task_title": .string("nested"), "prompt": .string("nested")]),
            sessionId: "gb-task-child")
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.structuredContent?["error"]?["code"], .string("permission_denied"))
        XCTAssertTrue(
            (result.structuredContent?["error"]?["message"]?.stringValue ?? "")
                .contains("delegation is not allowed"))
    }

    func testWriteInsideSubsetNeedsApprovalAndOutsideIsDeniedFirst() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let authorization = try BotTaskAuthorization.resolve(
            requestedDirectories: ["/tmp/task-allowed"],
            workspaceRoot: BotWorkspaceLayout.botRoot(botId: "main"))
        _ = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-task-scope", kind: .task,
            capabilities: authorization.capabilities)

        let outside = BotJSONValue.object(["file_path": .string("/tmp/outside.txt")])
        let outsideDigest = try BotArgumentsDigest.string(for: outside)
        _ = try await fixture.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-task-scope",
            callId: "write-outside", name: "write", arguments: outside)
        let denied = await fixture.runtime.approve(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-task-scope",
            callId: "write-outside", name: "write", action: "Write",
            detail: "outside", command: "", argsDigest: outsideDigest,
            alwaysScope: "until", askAction: "tool-call")
        XCTAssertFalse(denied.allowed)
        XCTAssertEqual(denied.message, "task_scope:path_denied")

        let inside = BotJSONValue.object(["file_path": .string("/tmp/task-allowed/a.md")])
        let insideDigest = try BotArgumentsDigest.string(for: inside)
        _ = try await fixture.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-task-scope",
            callId: "write-inside", name: "write", arguments: inside)
        let approval = Task {
            await fixture.runtime.approve(
                runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-task-scope",
                callId: "write-inside", name: "write", action: "Write",
                detail: "inside", command: "", argsDigest: insideDigest,
                alwaysScope: "until", askAction: "tool-call")
        }
        let approvalID = try await waitForApproval(fixture.runtime)
        let pendingDigest = await fixture.runtime.approvals.pendingDigest(approvalId: approvalID)
        _ = await fixture.runtime.approvals.resolve(
            approvalId: approvalID, decision: .allowOnce,
            digest: try XCTUnwrap(pendingDigest))
        let allowed = await approval.value
        XCTAssertTrue(allowed.allowed, String(describing: allowed))
    }

    func testBashRedirectOutsideSubsetIsDenied() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let authorization = try BotTaskAuthorization.resolve(
            requestedDirectories: ["notes"],
            workspaceRoot: BotWorkspaceLayout.botRoot(botId: "main"))
        _ = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-task-bash", kind: .task,
            capabilities: authorization.capabilities)

        let redirect = BotJSONValue.object([
            "command": .string("echo hello > /tmp/escaped.txt"),
        ])
        let redirectDigest = try BotArgumentsDigest.string(for: redirect)
        _ = try await fixture.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-task-bash",
            callId: "bash-redirect", name: "bash", arguments: redirect)
        let redirected = await fixture.runtime.approve(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-task-bash",
            callId: "bash-redirect", name: "bash", action: "Run",
            detail: "redirect", command: "echo hello > /tmp/escaped.txt",
            argsDigest: redirectDigest, alwaysScope: "until", askAction: "run-command")
        XCTAssertFalse(redirected.allowed)
        XCTAssertEqual(redirected.message, "task_scope:path_denied")
    }

    func testResolveRejectsEmptyAndOversizedDirectoryLists() throws {
        let root = BotWorkspaceLayout.botRoot(botId: "main")
        XCTAssertThrowsError(try BotTaskAuthorization.resolve(
            requestedDirectories: [""], workspaceRoot: root))
        XCTAssertThrowsError(try BotTaskAuthorization.resolve(
            requestedDirectories: (0...32).map { "/tmp/d\($0)" }, workspaceRoot: root))
    }

    func testAuthorizationCapabilitiesRoundTrip() throws {
        let authorization = try BotTaskAuthorization.resolve(
            requestedDirectories: ["notes", "/tmp/reports"],
            workspaceRoot: BotWorkspaceLayout.botRoot(botId: "main"))
        XCTAssertTrue(authorization.canWriteOutsideWorkspace)
        let restored = try XCTUnwrap(BotTaskAuthorization.from(
            capabilities: authorization.capabilities))
        XCTAssertEqual(restored, authorization)
        XCTAssertTrue(restored.allowsWrite(to: "notes/a.md"))
        XCTAssertFalse(restored.allowsWrite(to: "/tmp/other.txt"))
        XCTAssertTrue(restored.allowsWrite(to: "/tmp/reports/r.txt"))
    }
}
