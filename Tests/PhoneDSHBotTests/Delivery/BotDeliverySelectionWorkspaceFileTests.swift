// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// A02 delivery fixture: a workspace file gets its real `workspaceFile`
/// derivation from the production `BotDSHRemoteRuntime` write tool result,
/// then the completed selection host carries those record-backed sources into
/// the approval row and the real `show_attachment` card. No derivation or card
/// event is appended by this test.
final class BotDeliverySelectionWorkspaceFileTests: XCTestCase {
    private let now: Int64 = 1_794_801_600_000

    func testWrittenWorkspaceFileCarriesRecordEvidenceIntoDeliveryCard() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("a02-delivery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try write("docs/周报.md", "周报 张三 本周进展\n第二行", root: root)

        // The Worker produces the real write tool call/result. The production
        // remote runtime attaches workspaceFile derivation to the result.
        let transport = BotScriptedRemoteTransport(scripts: ["gb-main": [[
            .turn(),
            BotScriptedEvent("user/message", .object([
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string("请写 docs/周报.md，收件人张三"),
                ])]),
                "source": .object([
                    "kind": .string("user"),
                    "rpcId": .string("user-action:a02-delivery"),
                ]),
            ])),
            .toolCall("write", id: "write-a02",
                      arguments: #"{"file_path":"docs/周报.md","content":"周报 张三 本周进展"}"#),
            .toolResult(id: "write-a02"),
            .end(),
        ]]])
        let remote = try await BotDSHRemoteRuntime(
            transport: transport, runtime: fixture.runtime, now: { self.now })
        _ = try await remote.sendUserMessage("请写周报")
        let events = try await botEvents(fixture.store)
        let result = try XCTUnwrap(events.first {
            $0.type == "conversation.tool_result"
                && $0.data["derivation"]?["artifact"]?["kind"] == .string("workspaceFile")
        })
        let source = try XCTUnwrap(
            result.data["derivation"]?["sources"]?.arrayValue?.first?["record"]?.stringValue)
        XCTAssertTrue(source.hasPrefix("record://event/"))

        let catalog = BotWorkspaceDirectoryCatalog(workspaceRoot: root)
        let workspace = WorkspaceDecisionContextService(catalog: catalog, now: { self.now })
        let provenance = BotProvenanceService(eventLog: fixture.store)
        let host = BotDeliverySelectionHost(
            eventLog: fixture.store,
            workspaceState: BotDeliverySelectionHost.workspaceStateResolver(
                workspace: workspace),
            evidenceSources: BotDeliverySelectionHost.workspaceEvidenceResolver(
                provenance: provenance),
            now: { self.now })
        await fixture.runtime.installDeliverySelection(host)
        let decision = BotDecisionContextService(
            memoryForBot: { _ in await fixture.runtime.memory(for: "main") },
            permissionRevision: { _, _, _ in "rev-a02" },
            materialState: { _ in (.unknown, .noBaseline) },
            workspaceMaterials: workspace, now: { self.now })
        await fixture.runtime.installDecisionContext(
            decision, permissionRevision: { _, _, _ in "rev-a02" })
        try await fixture.runtime.grants.recover()
        _ = try await fixture.runtime.issueSession(
            botId: "main", sessionId: "gb-main", kind: .chat)
        await beginUserTurn(fixture.runtime)

        let decisionArgs: BotJSONValue = .object([
            "session_id": .string("gb-main"),
            "turn_id": .string("gb-main#0"),
            "step": .number(1),
            "stage": .string("pre_delivery"),
            "query": .string("周报 张三"),
            "scopes": .array([.string("agent")]),
            "limits": .object([
                "max_materials": .number(4),
                "max_characters": .number(1_600),
                "max_snippet_characters": .number(240),
                "deadline_ms": .number(1_500),
            ]),
        ])
        let decisionResult = try await registerAndExecute(
            fixture.runtime, name: BotDecisionTool.name, arguments: decisionArgs,
            sessionId: "gb-main", callId: "a02-decision")
        XCTAssertNotEqual(decisionResult.isError, true, "decision: \(decisionResult)")

        let args: BotJSONValue = .object([
            "action": .string("发送周报给张三"),
            "detail": .string("docs/周报.md 已由用户确认"),
        ])
        _ = try await fixture.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: "a02-request", name: "RequestApproval", arguments: args)
        let execution = Task {
            await fixture.runtime.execute(
                name: "RequestApproval", arguments: args,
                context: BotMCPRequestContext(callId: "a02-request"))
        }
        let approvalID = try await waitForApproval(fixture.runtime)
        let rowID = "e-main-approval-\(approvalID)"
        let firstDraft = try await host.draft(botID: "main", rowID: rowID)
        var draft = try XCTUnwrap(firstDraft)
        XCTAssertEqual(draft.revision, 1)
        let resource = try XCTUnwrap(draft.resources.first {
            $0.workspacePath == "docs/周报.md"
        })
        XCTAssertFalse(resource.source.evidenceSources.isEmpty,
                       "real write derivation must yield record-backed sources")
        XCTAssertTrue(resource.source.evidenceSources.allSatisfy {
            $0.record.hasPrefix("record://event/")
        })
        XCTAssertEqual(resource.source.role, "evidence")

        let applied = try await host.apply(BotDeliverySelectionSubmission(
            nonce: "a02-select", botID: "main", rowID: rowID,
            draftID: draft.draftID, expectedRevision: 1,
            selectedResourceIDs: [resource.id]))
        guard case .accepted = applied else { return XCTFail("selection: \(applied)") }
        let updatedDraft = try await host.draft(botID: "main", rowID: rowID)
        draft = try XCTUnwrap(updatedDraft)
        let rawEvidence = try await host.evidence(
            approvalID: approvalID, botID: "main")
        let evidence = try XCTUnwrap(rawEvidence)
        XCTAssertEqual(evidence.revision, 2)
        XCTAssertEqual(evidence.sources.first?.evidenceSources.count, 1)

        let resolved = await fixture.runtime.approvals.resolve(
            approvalId: approvalID, decision: .allowOnce, digest: draft.digest)
        XCTAssertEqual(resolved, .resolved)
        let resultValue = await execution.value
        XCTAssertNotEqual(resultValue.isError, true)

        let attachArgs: BotJSONValue = .object(["path": .string("docs/周报.md")])
        _ = try await fixture.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: "a02-attach", name: "show_attachment", arguments: attachArgs)
        let attached = await fixture.runtime.execute(
            name: "show_attachment", arguments: attachArgs,
            context: BotMCPRequestContext(callId: "a02-attach"))
        XCTAssertNotEqual(attached.isError, true)
        let after = try await botEvents(fixture.store)
        let card = try XCTUnwrap(after.last { $0.type == "card.presented" })
        XCTAssertEqual(card.data["path"]?.stringValue, "docs/周报.md")
        XCTAssertEqual(card.data["evidence"]?.arrayValue?.first?.stringValue, source)
        XCTAssertEqual(card.data["delivery_sources"]?.arrayValue?.first?["role"]?.stringValue,
                       "evidence")
    }

    private func waitForApproval(_ runtime: BotMCPRuntime) async throws -> String {
        for _ in 0..<400 {
            if let id = await runtime.approvals.pendingIDs.first { return id }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw NSError(domain: "a02-delivery", code: 1)
    }

    private func write(_ path: String, _ content: String, root: URL) throws {
        let url = root
            .appendingPathComponent("materialized/workspace", isDirectory: true)
            .appendingPathComponent(".dshbot/agents/main", isDirectory: true)
            .appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
