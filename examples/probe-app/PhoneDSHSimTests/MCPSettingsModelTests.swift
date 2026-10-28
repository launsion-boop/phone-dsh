// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — native MCP settings model on the simulator.
//
// The production `MCPSettingsModel` drives the same native save path the app
// sheet uses. These tests inject a scripted Remote transport and a real
// `PhoneMCPAccessSettings` document, so the unknown-result branches are
// exercised without a WKWebView: an unreadable list, a registry error and a
// third URL must all leave an ownerless (abandoned) staging that the next real
// registry read can roll back, instead of a protected stage that no later list
// can resolve.

import Foundation
import XCTest
import PhoneDSH
import PhoneDSHAgentCore
import ProbeKit

private enum TransportReply {
    case value(JSONValue)
    case failure
}

private enum ModelMCPTestError: Error {
    case noMux
}

@MainActor
final class MCPSettingsModelTests: XCTestCase {
    private let endpoint = URL(string: "https://mcp.example.com/mcp")!
    private let movedEndpoint = URL(string: "https://other.example.com/mcp")!
    private let thirdEndpoint = URL(string: "https://third.example.com/mcp")!
    private let token = "Bearer native-model-token"

    private struct Harness {
        let defaults: UserDefaults
        let suite: String
        let settings: PhoneMCPAccessSettings
        let secrets: SimMCPSecretStore
    }

    private actor ScriptedTransport: DSHRemoteTransport {
        private var listReplies: [TransportReply] = []
        private var upsertReply: TransportReply = .failure
        private var listHook: (() async -> Void)?

        func setList(_ reply: TransportReply) { listReplies = [reply] }
        func setListReplies(_ replies: [TransportReply]) { listReplies = replies }
        func setListHook(_ hook: @escaping () async -> Void) { listHook = hook }
        func setUpsert(_ reply: TransportReply) { upsertReply = reply }

        func call(_ endpoint: String, args: JSONValue) async throws -> JSONValue {
            if endpoint == "phone/mcpList", let hook = listHook {
                listHook = nil
                await hook()
            }
            let reply: TransportReply
            switch endpoint {
            case "phone/mcpList":
                reply = listReplies.isEmpty ? .failure : listReplies.removeFirst()
            case "phone/mcpUpsert":
                reply = upsertReply
            default:
                return .object([:])
            }
            switch reply {
            case .value(let value): return value
            case .failure: throw ModelMCPTestError.noMux
            }
        }

        func openMux() async throws -> any DSHMuxConnection {
            throw ModelMCPTestError.noMux
        }
    }

    private func makeHarness() throws -> Harness {
        let suite = "MCPSettingsModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let secrets = SimMCPSecretStore()
        let settings = PhoneMCPAccessSettings(defaults: defaults, secretStore: secrets)
        return Harness(defaults: defaults,
                       suite: suite,
                       settings: settings,
                       secrets: secrets)
    }

    private func makeModel(_ harness: Harness,
                           transport: ScriptedTransport) -> MCPSettingsModel {
        MCPSettingsModel(
            settings: harness.settings,
            isHostRunning: { true },
            makeTransport: { transport },
            refreshPolicy: {})
    }

    private func draft(url: URL, value: String?) -> MCPServerDraft {
        MCPServerDraft(
            serverName: "mcp",
            url: url.absoluteString,
            enabled: true,
            toolCallTimeoutMs: "60000",
            headers: [MCPHeaderDraft(name: "Authorization", value: value ?? "")])
    }

    private func listReply(_ url: String?) -> JSONValue {
        guard let url else {
            return .object(["servers": .array([])])
        }
        return .object([
            "servers": .array([
                .object([
                    "serverName": .string("mcp"),
                    "url": .string(url),
                    "enabled": .bool(true),
                    "toolCallTimeoutMs": .number(60_000),
                ]),
            ]),
        ])
    }

    private func seedOldGrant(_ harness: Harness) throws {
        let old = try harness.settings.grant(serverName: "mcp",
                                             url: endpoint.absoluteString,
                                             headers: ["Authorization"],
                                             values: ["Authorization": token])
        XCTAssertTrue(try harness.settings.commitGrant(
            serverName: old.serverName,
            expectedURL: old.url,
            expectedHeaders: old.headers))
    }

    func testAbandonedStageBlocksNewSaveUntilTheRegistryResolvesIt() async throws {
        let harness = try makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suite) }
        try seedOldGrant(harness)

        let moved = try harness.settings.grant(
            serverName: "mcp",
            url: movedEndpoint.absoluteString,
            headers: ["Authorization"],
            values: ["Authorization": "Bearer replacement"])
        XCTAssertNotNil(moved.secretID)
        try harness.settings.markStagedGrantsAbandoned(serverNames: ["mcp"])

        let transport = ScriptedTransport()
        await transport.setList(.failure)
        let model = makeModel(harness, transport: transport)
        await model.save(draft(url: thirdEndpoint, value: "Bearer latest"))
        XCTAssertTrue(model.errorText?.contains("上一次保存的结果尚未确认") ?? false,
                      "the native page must ask for a registry refresh")
        XCTAssertEqual(try harness.settings.load().grants.first?.url,
                       movedEndpoint.absoluteString,
                       "the abandoned row is preserved, not overwritten")
        XCTAssertFalse(harness.secrets.allValues().contains { $0.contains("latest") })

        // A successful list names B, so the old stage commits before the user
        // saves C. C then rolls back to B, not to the older A.
        await transport.setList(.value(listReply(movedEndpoint.absoluteString)))
        await model.refresh()
        XCTAssertFalse(try harness.settings.hasStagedGrant(serverName: "mcp"))
        XCTAssertEqual(harness.settings.secretValues(for: "mcp")?["Authorization"],
                       "Bearer replacement")

        await transport.setUpsert(.value(.object([:])))
        await transport.setList(.value(listReply(thirdEndpoint.absoluteString)))
        await model.save(draft(url: thirdEndpoint, value: "Bearer latest"))
        XCTAssertEqual(try harness.settings.load().grants.first?.url,
                       thirdEndpoint.absoluteString)
        XCTAssertFalse(try harness.settings.hasStagedGrant(serverName: "mcp"))
        XCTAssertNil(model.errorText)
    }

    func testRollbackFalseIsNotReportedAsRestoredByTheNativePage() async throws {
        let harness = try makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suite) }
        try seedOldGrant(harness)

        let transport = ScriptedTransport()
        await transport.setListReplies([
            .value(listReply(endpoint.absoluteString)),
            .failure,
        ])
        await transport.setUpsert(.failure)
        // A newer edit takes the slot while the page queries the registry, so
        // rollbackGrant returns false for the failed save's expected URL.
        let newerURL = thirdEndpoint.absoluteString
        await transport.setListHook {
            await MainActor.run {
                _ = try? harness.settings.grant(
                    serverName: "mcp",
                    url: newerURL,
                    headers: ["Authorization"],
                    values: ["Authorization": "Bearer newest"])
            }
        }
        let model = makeModel(harness, transport: transport)

        await model.save(draft(url: movedEndpoint, value: "Bearer replacement"))
        XCTAssertTrue(model.errorText?.contains("未能确认已恢复旧配置") ?? false)
        XCTAssertFalse(model.errorText?.contains("已恢复该服务器的配置") ?? false,
                       "a false rollback must not be reported as restored")
        XCTAssertEqual(try harness.settings.load().grants.first?.url,
                       thirdEndpoint.absoluteString,
                       "the newer edit stays current")
        XCTAssertTrue(try harness.settings.hasStagedGrant(serverName: "mcp"))

        // The next real list still names A, so the ownerless stage resolves to
        // A instead of being left protected forever.
        await transport.setList(.value(listReply(endpoint.absoluteString)))
        await model.refresh()
        XCTAssertEqual(try harness.settings.load().grants.first?.url,
                       endpoint.absoluteString)
        XCTAssertEqual(harness.settings.secretValues(for: "mcp")?["Authorization"], token)
        XCTAssertFalse(try harness.settings.hasStagedGrant(serverName: "mcp"))
    }

    func testUnreadableListLeavesAnOwnerlessStageTheNextListRollsBack() async throws {
        let harness = try makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suite) }
        try seedOldGrant(harness)

        let transport = ScriptedTransport()
        await transport.setList(.failure)
        await transport.setUpsert(.failure)
        let model = makeModel(harness, transport: transport)

        await model.save(draft(url: movedEndpoint, value: "Bearer replacement"))
        XCTAssertTrue(model.errorText?.contains("保存结果未确认") ?? false,
                      "the native page must report the unreadable list")
        XCTAssertTrue(try harness.settings.hasStagedGrant(serverName: "mcp"))
        XCTAssertEqual(try harness.settings.stagedPreviousGrant(serverName: "mcp")?.url,
                       endpoint.absoluteString)

        // The stage is ownerless, so the next real list can use the old row as
        // positive proof for rollback instead of protecting it forever.
        await transport.setList(.value(listReply(endpoint.absoluteString)))
        await model.refresh()
        XCTAssertEqual(try harness.settings.load().grants.first?.url,
                       endpoint.absoluteString)
        XCTAssertEqual(harness.settings.secretValues(for: "mcp")?["Authorization"], token)
        XCTAssertFalse(try harness.settings.hasStagedGrant(serverName: "mcp"))
    }

    func testRegistryErrorLeavesAnOwnerlessStageTheNextListRollsBack() async throws {
        let harness = try makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suite) }
        try seedOldGrant(harness)

        let transport = ScriptedTransport()
        await transport.setList(.value(.object(["error": .string("corrupt registry")])))
        await transport.setUpsert(.failure)
        let model = makeModel(harness, transport: transport)

        await model.save(draft(url: movedEndpoint, value: "Bearer replacement"))
        XCTAssertTrue(model.errorText?.contains("暂时无法读取 MCP 列表") ?? false)
        XCTAssertTrue(try harness.settings.hasStagedGrant(serverName: "mcp"))

        await transport.setList(.value(listReply(endpoint.absoluteString)))
        await model.refresh()
        XCTAssertEqual(try harness.settings.load().grants.first?.url,
                       endpoint.absoluteString)
        XCTAssertEqual(harness.settings.secretValues(for: "mcp")?["Authorization"], token)
        XCTAssertFalse(try harness.settings.hasStagedGrant(serverName: "mcp"))
    }

    func testThirdURLIsNotARollbackProofAndTheNextListResolvesIt() async throws {
        let harness = try makeHarness()
        defer { harness.defaults.removePersistentDomain(forName: harness.suite) }
        try seedOldGrant(harness)

        let transport = ScriptedTransport()
        await transport.setListReplies([
            .value(listReply(thirdEndpoint.absoluteString)),
            .failure,
        ])
        await transport.setUpsert(.failure)
        let model = makeModel(harness, transport: transport)

        await model.save(draft(url: movedEndpoint, value: "Bearer replacement"))
        XCTAssertTrue(model.errorText?.contains("还未确认上次保存是否生效") ?? false,
                      "a third URL must stay unknown, not roll back")
        XCTAssertTrue(model.errorText?.contains("现有配置未改动") ?? false)
        XCTAssertTrue(try harness.settings.hasStagedGrant(serverName: "mcp"))
        XCTAssertEqual(try harness.settings.load().grants.first?.url,
                       movedEndpoint.absoluteString)

        await transport.setList(.value(listReply(endpoint.absoluteString)))
        await model.refresh()
        XCTAssertEqual(try harness.settings.load().grants.first?.url,
                       endpoint.absoluteString)
        XCTAssertEqual(harness.settings.secretValues(for: "mcp")?["Authorization"], token)
        XCTAssertFalse(try harness.settings.hasStagedGrant(serverName: "mcp"))
    }
}
