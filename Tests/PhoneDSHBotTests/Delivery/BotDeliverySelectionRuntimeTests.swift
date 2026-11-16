// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// A04 vertical host test: the real MCP runtime produces the approval row from
/// the real pre-delivery workspace material, the user's selection is persisted
/// by the same row/draft, the approval digest is rebound, and the final
/// attachment tool consumes only the selected path.
final class BotDeliverySelectionRuntimeTests: XCTestCase {
    private let now: Int64 = 1_794_801_600_000

    private struct Launch {
        let fixture: BotMCPTestFixture
        let directory: URL
        let workspaceRoot: URL
        let host: BotDeliverySelectionHost
        let workspace: WorkspaceDecisionContextService
        func cleanup() {
            fixture.cleanup()
            try? FileManager.default.removeItem(at: workspaceRoot)
        }
    }

    private func makeLaunch() async throws -> Launch {
        let fixture = try makeBotMCPFixture()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("a04-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let catalog = BotWorkspaceDirectoryCatalog(workspaceRoot: directory)
        let workspace = WorkspaceDecisionContextService(catalog: catalog, now: { self.now })
        try write("docs/guide.md", "weekly guide", directory: directory)
        try write("docs/report.md", "weekly report", directory: directory)
        let host = BotDeliverySelectionHost(
            eventLog: fixture.store,
            workspaceState: BotDeliverySelectionHost.workspaceStateResolver(workspace: workspace),
            now: { self.now })
        await fixture.runtime.installDeliverySelection(host)
        let service = BotDecisionContextService(
            memoryForBot: { _ in await fixture.runtime.memory(for: "main") },
            permissionRevision: { _, _, _ in "rev-1" },
            materialState: { _ in (.unknown, .noBaseline) },
            workspaceMaterials: workspace,
            now: { self.now })
        await fixture.runtime.installDecisionContext(
            service, permissionRevision: { _, _, _ in "rev-1" })
        // The production runtime unit recovers grants in BotDSHRemoteRuntime
        // before the first turn; the bare MCP fixture has no remote, so do the
        // same initialization here or the first tool would see memory seed
        // events without a grant snapshot.
        try await fixture.runtime.grants.recover()
        _ = try await fixture.runtime.issueSession(
            botId: "main", sessionId: "gb-main", kind: .chat)
        await beginUserTurn(fixture.runtime)
        return Launch(fixture: fixture, directory: directory, workspaceRoot: directory,
                      host: host, workspace: workspace)
    }

    func testRequestApprovalProducesDraftAndAttachmentUsesSelection() async throws {
        let launch = try await makeLaunch()
        defer { launch.cleanup() }
        let runtime = launch.fixture.runtime
        let store = launch.fixture.store

        let decisionArgs: BotJSONValue = .object([
            "session_id": .string("gb-main"),
            "turn_id": .string("gb-main#0"),
            "step": .number(1),
            "stage": .string("pre_delivery"),
            "query": .string("guide report"),
            "scopes": .array([.string("agent")]),
            "limits": .object([
                "max_materials": .number(4),
                "max_characters": .number(1_600),
                "max_snippet_characters": .number(240),
                "deadline_ms": .number(1_500),
            ]),
        ])
        let decision = try await registerAndExecute(
            runtime, name: BotDecisionTool.name, arguments: decisionArgs,
            sessionId: "gb-main", callId: "a04-decision")
        XCTAssertNotEqual(decision.isError, true, "decision material lookup: \(decision)")

        let approvalArguments: BotJSONValue = .object([
            "action": .string("发送周报给张三"),
            "detail": .string("给张三的周报"),
        ])
        let callId = "a04-request-approval"
        _ = try await runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: callId, name: "RequestApproval", arguments: approvalArguments)
        let execution = Task {
            await runtime.execute(
                name: "RequestApproval", arguments: approvalArguments,
                context: BotMCPRequestContext(callId: callId))
        }
        let approvalID = try await waitForApproval(runtime)
        let rowID = "e-main-approval-\(approvalID)"
        var draft = try await launch.host.draft(botID: "main", rowID: rowID)
        let initial = try XCTUnwrap(draft)
        XCTAssertEqual(initial.revision, 1)
        XCTAssertEqual(initial.resources.count, 2, "real workspace materials became candidates")
        let guide = try XCTUnwrap(initial.resources.first {
            $0.workspacePath == "docs/guide.md"
        })
        let report = try XCTUnwrap(initial.resources.first {
            $0.workspacePath == "docs/report.md"
        })

        let applied = try await launch.host.apply(BotDeliverySelectionSubmission(
            nonce: "a04-select-1", botID: "main", rowID: rowID,
            draftID: initial.draftID, expectedRevision: 1,
            selectedResourceIDs: [guide.id]))
        guard case .accepted = applied else { return XCTFail("selection: \(applied)") }
        draft = try await launch.host.draft(botID: "main", rowID: rowID)
        XCTAssertEqual(draft?.revision, 2)
        XCTAssertEqual(draft?.selectedIDs, [guide.id])

        let digest = try XCTUnwrap(draft?.digest)
        let resolved = await runtime.approvals.resolve(
            approvalId: approvalID, decision: .allowOnce, digest: digest)
        XCTAssertEqual(resolved, .resolved,
                       "the coordinator must accept the rebound delivery digest")
        let approvalResult = await execution.value
        let debugEvents = try await store.events(after: 0, limit: 100)
        for event in debugEvents where event.type == "approval.decided" || event.type == "approval.requested" {
            print("A04_EVENT", event.type, String(data: (try? event.data.encoded()) ?? Data(), encoding: .utf8) ?? "?")
        }
        XCTAssertNotEqual(approvalResult.isError, true, "RequestApproval: \(approvalResult)")
        let approvedDelivery = approvalResult.structuredContent?["delivery"]
        XCTAssertEqual(approvedDelivery?["revision"]?.intValue, 2)
        let approvedPaths = approvedDelivery?["selected"]?.arrayValue?.compactMap {
            $0["path"]?.stringValue
        }
        XCTAssertEqual(approvedPaths, ["docs/guide.md"])

        // The actual delivery tool names the selected path: allowed.
        let selectedCall = "a04-attach-selected"
        let selectedArgs: BotJSONValue = .object([
            "path": .string("docs/guide.md"),
            "caption": .string("周报"),
        ])
        _ = try await runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: selectedCall, name: "show_attachment", arguments: selectedArgs)
        let selectedResult = await runtime.execute(
            name: "show_attachment", arguments: selectedArgs,
            context: BotMCPRequestContext(callId: selectedCall))
        XCTAssertNotEqual(selectedResult.isError, true, "selected attachment: \(selectedResult)")

        // A different suggested file that the user did not select is refused;
        // the runtime does not rewrite the model's argument to the selected one.
        let unselectedCall = "a04-attach-unselected"
        let unselectedArgs: BotJSONValue = .object([
            "path": .string("docs/report.md"),
        ])
        _ = try await runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: unselectedCall, name: "show_attachment", arguments: unselectedArgs)
        let unselectedResult = await runtime.execute(
            name: "show_attachment", arguments: unselectedArgs,
            context: BotMCPRequestContext(callId: unselectedCall))
        XCTAssertEqual(unselectedResult.isError, true)
        XCTAssertEqual(
            unselectedResult.structuredContent?["error"]?["code"]?.stringValue,
            "delivery_resource_not_selected")

        let events = try await store.events(after: 0, limit: 1_000)
        let cards = events.filter { $0.type == "card.presented" }
        XCTAssertEqual(cards.count, 1, "only the selected attachment produced a card")
        let cardData = try XCTUnwrap(cards.first?.data)
        XCTAssertTrue(cardData["card"]?["path"]?.stringValue == "docs/guide.md")
        XCTAssertFalse(cardData["card"]?["path"]?.stringValue == "docs/report.md")

        // The row projection still shows the durable revision/resources after
        // the decision; the decision event repeats the delivery block.
        let history = BotRowHistory()
        _ = try await history.rebuild(
            botID: "main", epochs: [], uiEvents: events, heldRequestNonces: [:])
        let rows = await history.history()
        let approvalRow = try XCTUnwrap(rows.first { $0.id == rowID })
        XCTAssertEqual(approvalRow.body["status"]?.stringValue, "allowed")
        XCTAssertEqual(approvalRow.body["delivery"]?["revision"]?.intValue, 2)
        XCTAssertEqual(approvalRow.body["digest"]?.stringValue, digest)
        _ = report
    }

    func testChangedSourceAfterApprovalRefusesActualDelivery() async throws {
        let launch = try await makeLaunch()
        defer { launch.cleanup() }
        let runtime = launch.fixture.runtime
        let store = launch.fixture.store
        let decisionArgs: BotJSONValue = .object([
            "session_id": .string("gb-main"), "turn_id": .string("gb-main#0"),
            "step": .number(1), "stage": .string("pre_delivery"),
            "query": .string("guide report"), "scopes": .array([.string("agent")]),
            "limits": .object([
                "max_materials": .number(4), "max_characters": .number(1_600),
                "max_snippet_characters": .number(240), "deadline_ms": .number(1_500),
            ]),
        ])
        _ = try await registerAndExecute(runtime, name: BotDecisionTool.name,
                                         arguments: decisionArgs, callId: "a04-decision-2")
        let arguments: BotJSONValue = .object([
            "action": .string("发送周报给张三"), "detail": .string("给张三的周报"),
        ])
        let callID = "a04-request-approval-2"
        _ = try await runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: callID, name: "RequestApproval", arguments: arguments)
        let execution = Task {
            await runtime.execute(name: "RequestApproval", arguments: arguments,
                                  context: BotMCPRequestContext(callId: callID))
        }
        let approvalID = try await waitForApproval(runtime)
        let rowID = "e-main-approval-\(approvalID)"
        let initialDraft = try await launch.host.draft(botID: "main", rowID: rowID)
        let initial = try XCTUnwrap(initialDraft)
        let guide = try XCTUnwrap(initial.resources.first {
            $0.workspacePath == "docs/guide.md"
        })
        _ = try await launch.host.apply(BotDeliverySelectionSubmission(
            nonce: "a04-select-2", botID: "main", rowID: rowID,
            draftID: initial.draftID, expectedRevision: 1,
            selectedResourceIDs: [guide.id]))
        let selectedDraftValue = try await launch.host.draft(
            botID: "main", rowID: rowID)
        let selectedDraft = try XCTUnwrap(selectedDraftValue)
        let digest = selectedDraft.digest
        let resolved = await runtime.approvals.resolve(
            approvalId: approvalID, decision: .allowOnce, digest: digest)
        XCTAssertEqual(resolved, .resolved)
        _ = await execution.value

        // The approved version changes before the side effect. The host must
        // refuse; it must not silently send the new bytes under the old digest.
        try write("docs/guide.md", "a newer guide", directory: launch.directory)
        let attachCall = "a04-attach-changed"
        let attachArgs: BotJSONValue = .object(["path": .string("docs/guide.md")])
        _ = try await runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: attachCall, name: "show_attachment", arguments: attachArgs)
        let result = await runtime.execute(
            name: "show_attachment", arguments: attachArgs,
            context: BotMCPRequestContext(callId: attachCall))
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.structuredContent?["error"]?["code"]?.stringValue,
                       "delivery_source_changed")
        let events = try await store.events(after: 0, limit: 1_000)
        XCTAssertFalse(events.contains { $0.type == "card.presented" })
    }

    func testCorruptDeliveryRecordFailsClosedInRuntime() async throws {
        let launch = try await makeLaunch()
        defer { launch.cleanup() }
        let runtime = launch.fixture.runtime
        let store = launch.fixture.store
        let corrupt = BotEvent(
            type: "approval.requested", eventId: "runtime-corrupt",
            time: now, origin: .local(source: "card-bridge"),
            traceId: "runtime-corrupt",
            principal: BotPrincipal(botId: "main", sessionId: "gb-main", kind: "chat"),
            causationId: nil, correlationId: nil,
            data: .object([
                "approvalID": .string("approval-runtime-corrupt"),
                "status": .string("pending"),
                "deliverySelection": .bool(true),
                "delivery": .object(["revision": .number(1)]),
            ]))
        try await store.append(corrupt)
        let callID = "a04-corrupt-attach"
        let args: BotJSONValue = .object(["path": .string("docs/guide.md")])
        _ = try await runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: callID, name: "show_attachment", arguments: args)
        let result = await runtime.execute(
            name: "show_attachment", arguments: args,
            context: BotMCPRequestContext(callId: callID))
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.structuredContent?["error"]?["code"]?.stringValue,
                       "delivery_selection_corrupt")
        let events = try await store.events(after: 0, limit: 100)
        XCTAssertFalse(events.contains { $0.type == "card.presented" })
    }

    private func waitForApproval(_ runtime: BotMCPRuntime) async throws -> String {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let id = await runtime.approvals.pendingIDs.first { return id }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("RequestApproval did not create a pending approval")
        throw ApprovalWaitTimeout()
    }

    private func write(_ path: String, _ content: String, directory: URL) throws {
        let url = directory
            .appendingPathComponent("materialized/workspace", isDirectory: true)
            .appendingPathComponent(".dshbot/agents/main", isDirectory: true)
            .appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

private func requireValue<T>(_ value: T?, file: StaticString = #filePath,
                             line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

private struct ApprovalWaitTimeout: Error {}
