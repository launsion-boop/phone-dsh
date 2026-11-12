// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Discovery (`bluetooth.scan` / `network.browse`) and PR59 BLE native-MCP
/// classification stay covered after the device-ingress removal. The BLE names
/// come from PR59's `spec/v1/native-mcp.md` "BLE tools"; PR59's per-connection
/// grant is the real authorization gate and the Bot ask is an additional layer.
final class BotDeviceToolProviderTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
    }

    func testDiscoveryUsesAttributionStandingDenyAndOnceGrant() async throws {
        let store = try SQLiteDomainStore(fileURL: try root().appendingPathComponent("domain.sqlite"),
                                          now: { 1_000 })
        let grants = BotGrantStore(domainStore: store, now: { 1_000 })
        let provider = BotDeviceToolProvider(authorizer: BotExecutionAuthorizer(grants: grants)) { _, _, _ in
            .object([
                "ok": .bool(true),
                "data": .object(["items": .array([]), "count": .number(0)]),
            ])
        }
        let gateway = BotGateway(now: { 1_000 })
        _ = try await gateway.issueSession(botId: "main", sessionId: "bot-main", kind: .chat)
        func call(_ tool: String, arguments: BotJSONValue, id: String) async throws -> BotResolvedToolCall {
            _ = try await gateway.registerToolCall(
                sessionId: "bot-main", callId: id, name: tool, arguments: arguments, runtimeId: "test")
            let resolved = await gateway.resolveToolCall(runtimeId: "test", name: tool, arguments: arguments)
            return try XCTUnwrap(resolved)
        }
        do {
            _ = try await provider.browseNetwork(call: call("network.browse", arguments: .object([:]), id: "denied"))
            XCTFail("missing grant must not execute discovery")
        } catch BotMCPError.unavailable(let reason) {
            XCTAssertEqual(reason, "device-discovery-missing-grant")
        }

        _ = try await grants.add(BotGrant(
            id: "deny", botId: "main", tool: "network.browse", operation: "device.discovery.read",
            resource: "network.browse", scope: .until, decision: .deny))
        _ = try await grants.add(BotGrant(
            id: "allow", botId: "main", tool: "network.browse", operation: "device.discovery.read",
            resource: "network.browse", scope: .until, decision: .allow))
        do {
            _ = try await provider.browseNetwork(call: call("network.browse", arguments: .object([:]), id: "denied-again"))
            XCTFail("standing deny must win")
        } catch BotMCPError.unavailable(let reason) {
            XCTAssertEqual(reason, "device-discovery-standing-deny")
        }

        _ = try await grants.add(BotGrant(
            id: "once", botId: "main", tool: "bluetooth.scan", operation: "device.discovery.read",
            resource: "bluetooth.scan", scope: .once, decision: .allow))
        let scanEffect = BotToolEffect(
            tool: "bluetooth.scan", operation: "device.discovery.read", resource: "bluetooth.scan",
            mutability: .read, policy: .ask)
        let scanGrant = await grants.find(botId: "main", sessionId: "bot-main", effect: scanEffect)
        XCTAssertEqual(scanGrant?.id, "once")
        let scanCall = try await call(
            "bluetooth.scan", arguments: .object(["duration": .number(5)]), id: "decision-check")
        let direct = await BotExecutionAuthorizer(grants: grants).authorizeExecution(
            principal: BotExecutionPrincipal(gateway: scanCall.principal), effects: [scanEffect], consumeOnce: false)
        XCTAssertTrue(direct.allowed, direct.reason)
        let response = try await provider.bluetoothScan(call: call(
            "bluetooth.scan", arguments: .object(["duration": .number(5)]), id: "once-call"))
        XCTAssertEqual(response["ok"]?.boolValue, true)
        do {
            _ = try await provider.bluetoothScan(call: call(
                "bluetooth.scan", arguments: .object(["duration": .number(5)]), id: "once-consumed"))
            XCTFail("once grant must not execute twice")
        } catch BotMCPError.unavailable(let reason) {
            XCTAssertEqual(reason, "device-discovery-missing-grant")
        }
        try await store.close()
    }

    func testPhoneQualifiedDiscoveryUsesSharedIdentityAndReadAskEffect() async throws {
        let store = try SQLiteDomainStore(fileURL: try root().appendingPathComponent("domain.sqlite"),
                                          now: { 1_000 })
        let runtime = BotMCPRuntime(store: store, now: { 1_000 })
        _ = try await runtime.issueSession(botId: "main", sessionId: "bot-main", kind: .chat)
        for tool in ["bluetooth.scan", "network.browse"] {
            let attribution = try await runtime.registerIdentity(
                runtimeId: "phone-worker", sessionId: "bot-main", callId: "identity-\(tool)",
                name: "mcp__phone__\(tool)", arguments: .object([:]))
            XCTAssertEqual(attribution.name, tool)
            let effect = BotToolEffectClassifier.effect(for: attribution.name)
            XCTAssertEqual(effect.mutability, .read)
            XCTAssertEqual(effect.policy, .ask)
            XCTAssertEqual(effect.operation, "device.discovery.read")
            _ = try await runtime.cancelIdentity(id: attribution.id)
        }
        try await store.close()
    }

    func testBleNativeMcpEffectsStayAskGatedAndKnown() {
        let readTools = ["ble_devices", "ble_read", "ble_link_tools", "ble_link_result"]
        for tool in readTools {
            let effect = BotToolEffectClassifier.effect(
                for: "mcp__phone__\(tool)", arguments: .object(["device_id": .string(" device-a ")]))
            XCTAssertEqual(effect.tool, tool)
            XCTAssertEqual(effect.mutability, .read, tool)
            XCTAssertEqual(effect.policy, .ask, tool)
            XCTAssertEqual(effect.resource, "device_id=device-a", tool)
            XCTAssertTrue(effect.known, tool)
            XCTAssertTrue(effect.isMcp, tool)
            XCTAssertNotEqual(effect.operation, "tool.unclassified", tool)
        }
        for tool in ["ble_alert", "ble_link_call"] {
            let effect = BotToolEffectClassifier.effect(
                for: "mcp__phone__\(tool)", arguments: .object(["device_id": .string("device-a")]))
            XCTAssertEqual(effect.mutability, .externalSend, tool)
            XCTAssertEqual(effect.policy, .ask, tool)
            XCTAssertEqual(effect.resource, "device_id=device-a", tool)
            XCTAssertTrue(effect.detail.contains("结果未知时不自动重试"), tool)
        }
        let noDevice = BotToolEffectClassifier.effect(
            for: "mcp__phone__ble_alert", arguments: .object([:]))
        XCTAssertEqual(noDevice.resource, "ble:*")
        let linkCall = BotToolEffectClassifier.effect(
            for: "mcp__phone__ble_link_call",
            arguments: .object(["device_id": .string("device-a"), "name": .string("light_on")]))
        XCTAssertEqual(linkCall.resource, "device_id=device-a&name=light_on")
        XCTAssertEqual(BotToolEffectClassifier.policy(for: "mcp__phone__ble_read"), .ask)
    }

    func testBleReadEffectNeedsAnAskGrant() async throws {
        let effect = BotToolEffectClassifier.effect(
            for: "mcp__phone__ble_read", arguments: .object(["device_id": .string("device-a")]))
        let store = BotGrantStore(now: { 1_000 })
        let authorizer = BotExecutionAuthorizer(grants: store)
        let principal = BotExecutionPrincipal(botId: "main", sessionId: "bot-main")
        let denied = await authorizer.authorizeExecution(principal: principal, effects: [effect])
        XCTAssertFalse(denied.allowed)
        _ = try await store.add(BotGrant(
            botId: "main", tool: effect.tool, operation: effect.operation,
            resource: effect.resource, scope: .once, decision: .allow))
        let allowed = await authorizer.authorizeExecution(principal: principal, effects: [effect])
        XCTAssertTrue(allowed.allowed, allowed.reason)
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }
}
