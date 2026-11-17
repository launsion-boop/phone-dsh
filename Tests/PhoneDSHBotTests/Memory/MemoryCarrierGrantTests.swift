// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// G-1 r20: a real observation carrier may carry grant_id at its data root
/// (`conversation.tool_result`) or flat `context.observed`; P reads it into
/// BotSourceState and never invents one when the carrier omits it.
final class MemoryCarrierGrantTests: XCTestCase {
    func testCarrierGrantFlowsIntoSourceState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("carrier-grant-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteDomainStore(
            fileURL: root.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        defer { Task { try? await store.close() } }
        let gateway = BotGateway(now: { 1_000 })
        try await gateway.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        let service = BotRecordService(store: store, gateway: gateway, workspaceRoot: root)

        let toolSeq = try await store.append(BotEvent(
            type: "conversation.tool_result", eventId: "grant-tool:test", time: 1_000,
            origin: .local(source: "runtime"), traceId: "trace-grant-tool",
            principal: BotPrincipal(botId: "main", sessionId: "gb-main", kind: "chat"),
            causationId: nil, correlationId: "gb-main",
            data: .object(["grant_id": .string("grant-web-7")])))
        let contextSeq = try await store.append(BotEvent(
            type: "context.observed", eventId: "grant-context:test", time: 1_100,
            origin: .local(source: "runtime"), traceId: "trace-grant-context",
            principal: BotPrincipal(botId: "main", sessionId: "gb-main", kind: "chat"),
            causationId: nil, correlationId: "gb-main", ignorable: true,
            data: .object([
                "schema": .string("bot-context-observation/v1"),
                "source": .string("web"),
                "observed_at_ms": .number(1_100),
                "owner_bot_id": .string("main"),
                "grant_id": .string("grant-context-9"),
            ])))
        let states = try await service.sourceStates(
            for: ["record://event/\(toolSeq)", "record://event/\(contextSeq)"],
            callerBotID: "main", callerSessionID: "gb-main")
        XCTAssertEqual(states.first { $0.ref == "record://event/\(toolSeq)" }?.grantId,
                       "grant-web-7")
        XCTAssertEqual(states.first { $0.ref == "record://event/\(contextSeq)" }?.grantId,
                       "grant-context-9")
    }

    func testOmittedCarrierGrantStaysNil() {
        XCTAssertNil(BotRecordService.carrierGrantId(
            type: "conversation.tool_result", data: .object([:])))
        XCTAssertNil(BotRecordService.carrierGrantId(
            type: "conversation.assistant_message",
            data: .object(["grant_id": .string("not-a-carrier")])))
    }
}
