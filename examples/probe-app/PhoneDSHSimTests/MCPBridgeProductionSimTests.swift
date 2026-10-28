// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — production Web→native MCP bridge on the iOS Simulator.
//
// Unlike `MCPProductionSimTests`, this suite installs the production
// `MCPControlBridge` from ProbeKit on the real WKWebView created by
// `WebHostConfiguration`, then posts `pdshMcpControl` messages from the page's
// own JavaScript world. The grants therefore travel the same
// WKScriptMessageHandlerWithReply → `MCPControlController` →
// `PhoneMCPAccessSettings` → live `MCPEgressPolicy` path the App uses.
//
// It also drives the real `phone/mcpUpsert` Remote, proves the bridge grant is
// visible to the running gateway before the mount, and proves a failed upsert
// can roll back both the old exact URL and its independent Keychain value.
//
// Boundary: simulator only. The SwiftUI sheet, ATS/local-network prompts on a
// physical iPhone and a real remote MCP server stay NOT_RUN until a Mac/device
// run records them.

import Foundation
import WebKit
import XCTest
import ProbeKit
import PhoneDSH
import PhoneDSHAgentCore

@MainActor
final class MCPBridgeProductionSimTests: XCTestCase {
    func testPageBridgeGrantSyncRollbackAndRevokeUseTheProductionPath() async throws {
        let nonce = UUID().uuidString.prefix(8).lowercased()
        let serverName = "bridge-\(nonce)"
        let fixture = NoCorsMCPFixture()
        let mcpURL = try fixture.start()
        let mcpToken = fixture.token
        let suiteName = "MCPBridgeProductionSimTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secrets = SimMCPSecretStore()
        let settings = PhoneMCPAccessSettings(defaults: defaults, secretStore: secrets)
        var presentedDraft: MCPControlDraft?
        let controller = MCPControlController(
            settings: settings,
            policy: MCPEgressPolicy(),
            presentSettings: { draft in presentedDraft = draft })
        var host: PhoneDSHHost?
        var window: SimVisibleWindow?
        var loadedServer = false

        do {
            let workspace = SimEnvironment.workspaceRoot(name: "mcp-bridge-\(nonce)")
            try FileManager.default.createDirectory(at: workspace,
                                                    withIntermediateDirectories: true)
            let bundle = try SimEnvironment.workerBundle()
            var plan = ModelProviderLaunchPlan(
                allowedModelHosts: [],
                credentialProvider: RecordingModelCredentialProvider(value: "model-key-must-not-reach-mcp"),
                environment: [:])
            let policy = MCPHostConfiguration.apply(to: &plan,
                                                    settings: settings,
                                                    policy: controller.policy)
            let visibleWindow = SimVisibleWindow(size: CGSize(width: 430, height: 932))
            window = visibleWindow
            let anchor = VisibleEngineAnchor()
            visibleWindow.anchor.addSubview(anchor.view)
            visibleWindow.window.layoutIfNeeded()
            XCTAssertTrue(anchor.isInWindow)

            let port = WebHostConfiguration.freeLoopbackPort()
            let assembly = WebHostConfiguration.make(
                workspaceRoot: workspace,
                bundle: bundle,
                modelURL: URL(string: "http://127.0.0.1:1")!,
                modelName: "deepseek-flash",
                credentialProvider: plan.credentialProvider,
                egressHosts: [],
                loopbackPort: port,
                allowedModelHosts: [],
                egressAuthorizer: policy,
                environment: [
                    "DEEPSEEK_API_KEY": "phone-host-injects-key",
                    "DEEPSEEK_BASE_URL": "http://127.0.0.1:1",
                    "DSH_TELEMETRY_DISABLED": "1",
                    "PDSH_MODEL_NAME": "deepseek-flash",
                ],
                drainDeadline: 5,
                helloTimeout: 240)
            let newHost = PhoneDSHHost(
                configuration: assembly.configuration,
                engineFactory: WebHostConfiguration.engineFactory(anchor: anchor))
            host = newHost
            try await newHost.start()
            try await simWait(timeout: 240, label: "bridge production Web host Running") {
                await newHost.state == .running
            }
            let transport = try await newHost.makeTransport()
            let webView = try XCTUnwrap(anchor.engine?.view,
                                        "the production WebHostConfiguration engine is missing")
            let bridge = MCPControlBridge(controller: controller)
            webView.configuration.userContentController.addScriptMessageHandler(
                bridge, contentWorld: .page, name: MCPControlBridge.messageHandlerName)

            // MARK: grant is live before the Worker upsert
            let firstGrant = try await postBridge([
                "v": 1,
                "action": "grant",
                "serverName": serverName,
                "url": mcpURL.absoluteString,
                "headers": ["Authorization": "PHONE_MCP_BRIDGE_TOKEN"],
            ], to: webView)
            XCTAssertEqual(firstGrant["needsValues"] as? Bool, true,
                           "a new authenticated row has no native value yet")
            let firstTransaction = try XCTUnwrap(firstGrant["transaction"] as? String)
            XCTAssertTrue(controller.policy.allowsEgressHost(mcpURL),
                          "the page grant must update the same live policy before upsert")
            XCTAssertFalse(controller.policy.allowsEgressHost(
                URL(string: "https://unrelated.invalid/mcp")!))
            _ = try await postBridge(["v": 1, "action": "commit",
                                      "transaction": firstTransaction], to: webView)

            // The native editor is the only writer of the actual value.
            let granted = try controller.grant(
                serverName: serverName,
                url: mcpURL.absoluteString,
                headers: ["Authorization"],
                values: ["Authorization": "Bearer \(mcpToken)"])
            XCTAssertFalse(granted.headers.isEmpty)

            let job = try await postBridge([
                "v": 1,
                "action": "grant",
                "serverName": serverName,
                "url": mcpURL.absoluteString,
                "headers": ["Authorization": "PHONE_MCP_BRIDGE_TOKEN"],
            ], to: webView)
            XCTAssertEqual(job["needsValues"] as? Bool, false,
                           "the existing native value is preserved for the same endpoint")
            let transaction = try XCTUnwrap(job["transaction"] as? String)
            // A list snapshot taken now does not contain this row yet. The
            // native controller must keep the in-flight grant alive.
            _ = try await postBridge([
                "v": 1,
                "action": "sync",
                "servers": [[String: Any]](),
            ], to: webView)
            XCTAssertEqual(try settings.load().grants.map(\.serverName), [serverName],
                           "sync must not revoke an open grant transaction")
            XCTAssertTrue(controller.policy.allowsEgressHost(mcpURL))
            let upsert = try await transport.call(
                "phone/mcpUpsert",
                args: .object(["request": .object([
                    "serverName": .string(serverName),
                    "url": .string(mcpURL.absoluteString),
                    "headersFromEnv": .object(["Authorization": .string("PHONE_MCP_BRIDGE_TOKEN")]),
                    "hostManagedHeaders": .array([.string("Authorization")]),
                    "enabled": .bool(true),
                    "toolCallTimeoutMs": .number(5_000),
                ])]))
            XCTAssertEqual(upsert["status"]?.stringValue, "connected")
            loadedServer = true
            let authorized = fixture.requestsSnapshot.contains { request in
                request.headers["authorization"] == "Bearer \(mcpToken)"
                    && request.headers["x-api-key"] == nil
            }
            XCTAssertTrue(authorized, "the bridge-granted route injected only the MCP token")
            _ = try await postBridge(["v": 1, "action": "commit",
                                      "transaction": transaction], to: webView)

            // MARK: sync is the successful list authority and keeps a live row
            _ = try await postBridge([
                "v": 1,
                "action": "sync",
                "servers": [[
                    "serverName": serverName,
                    "url": mcpURL.absoluteString,
                ]],
            ], to: webView)
            XCTAssertEqual(try settings.load().grants.map(\.serverName), [serverName])
            XCTAssertTrue(controller.policy.allowsEgressHost(mcpURL))

            // MARK: a failed upsert rolls the grant back to the old URL/key
            XCTAssertEqual(settings.secretValues(for: serverName)?["Authorization"],
                           "Bearer \(mcpToken)",
                           "the committed old row still has its independent value")
            let closedPort = WebHostConfiguration.freeLoopbackPort()
            XCTAssertNotEqual(closedPort, 0)
            let movedURL = URL(string: "http://127.0.0.1:\(closedPort)/other")!
            let moved = try await postBridge([
                "v": 1,
                "action": "grant",
                "serverName": serverName,
                "url": movedURL.absoluteString,
                "headers": ["Authorization": "PHONE_MCP_BRIDGE_TOKEN"],
            ], to: webView)
            let movedTransaction = try XCTUnwrap(moved["transaction"] as? String)
            XCTAssertEqual(moved["needsValues"] as? Bool, true,
                           "a changed trust boundary needs its own value")
            XCTAssertTrue(controller.policy.allowsEgressHost(movedURL),
                          "the moved endpoint is temporarily admitted for the attempted upsert")
            // `secretValues` returns nil only when the server has no grant at
            // all. A moved grant that declares header names but has no stored
            // value map returns an empty map, so assert the absence of the old
            // value and header name rather than the absence of the dictionary.
            let movedSecrets = settings.secretValues(for: serverName) ?? [:]
            XCTAssertTrue(movedSecrets.isEmpty,
                          "the moved endpoint starts without the old endpoint's value map")
            XCTAssertNil(movedSecrets["Authorization"],
                         "the moved endpoint starts without the old endpoint's Authorization value")
            XCTAssertTrue(settings.storedHeaderNames(serverName: serverName).isEmpty,
                          "the old endpoint's header name is not carried into the moved grant")
            do {
                _ = try await transport.call(
                    "phone/mcpUpsert",
                    args: .object(["request": .object([
                        "serverName": .string(serverName),
                        "url": .string(movedURL.absoluteString),
                        "headersFromEnv": .object(["Authorization": .string("PHONE_MCP_BRIDGE_TOKEN")]),
                        "hostManagedHeaders": .array([.string("Authorization")]),
                        "enabled": .bool(true),
                        "toolCallTimeoutMs": .number(1_000),
                    ])]))
                XCTFail("the closed-port MCP endpoint must fail to connect")
            } catch {
                // expected: mount failure
            }
            _ = try await postBridge(["v": 1, "action": "rollback",
                                      "transaction": movedTransaction], to: webView)
            XCTAssertFalse(controller.policy.allowsEgressHost(movedURL))
            XCTAssertTrue(controller.policy.allowsEgressHost(mcpURL))
            XCTAssertEqual(try settings.load().grants.first?.url, mcpURL.absoluteString)
            XCTAssertEqual(settings.secretValues(for: serverName)?["Authorization"],
                           "Bearer \(mcpToken)",
                           "the old URL's independent value is restored, not the failed endpoint's")
            let listedAfterRollback = try await transport.call("phone/mcpList", args: .object([:]))
            let rowsAfterRollback = listedAfterRollback["servers"]?.arrayValue ?? []
            XCTAssertEqual(rowsAfterRollback.compactMap { $0["serverName"]?.stringValue },
                           [serverName])
            XCTAssertEqual(rowsAfterRollback.first?["url"]?.stringValue,
                           mcpURL.absoluteString)
            // The failed update unmounted the old row before the Worker
            // restored its file entry; the restored exact grant must let the
            // existing reconnect path bring the old server back.
            let recovered = try await transport.call(
                "phone/mcpReconnect",
                args: .object(["request": .object(["serverName": .string(serverName)])]))
            XCTAssertEqual(recovered["status"]?.stringValue, "connected",
                           "rollback restored the old route; reconnect must recover the row")

            // MARK: the bridge's open action carries only non-secret row fields
            _ = try await postBridge([
                "v": 1,
                "action": "open",
                "draft": [
                    "serverName": serverName,
                    "url": mcpURL.absoluteString,
                    "headersFromEnv": ["Authorization": "PHONE_MCP_BRIDGE_TOKEN"],
                    "enabled": true,
                    "toolCallTimeoutMs": 5_000,
                ],
            ], to: webView)
            XCTAssertEqual(presentedDraft?.serverName, serverName)
            XCTAssertEqual(presentedDraft?.headers.first?.name, "Authorization")
            XCTAssertFalse(String(describing: presentedDraft).contains(mcpToken),
                           "the native draft never carries a value")

            // MARK: revoke removes the live route and the dedicated value
            _ = try await postBridge(["v": 1, "action": "revoke",
                                      "serverName": serverName], to: webView)
            XCTAssertFalse(controller.policy.allowsEgressHost(mcpURL))
            XCTAssertTrue(try settings.load().grants.isEmpty)
            XCTAssertNil(settings.secretValues(for: serverName))
            XCTAssertFalse(secrets.allValues().contains { $0.contains(mcpToken) })

            if loadedServer {
                _ = try await transport.call(
                    "phone/mcpRemove",
                    args: .object(["request": .object(["serverName": .string(serverName)])]))
            }
            if let host { try await host.stop() }
            host = nil
            window?.shutdown()
            window = nil
            fixture.stop()
            defaults.removePersistentDomain(forName: suiteName)
        } catch {
            if let host { try await host.stop() }
            window?.shutdown()
            fixture.stop()
            defaults.removePersistentDomain(forName: suiteName)
            throw error
        }
    }

    /// Post one message from the real page world and await the
    /// `WKScriptMessageHandlerWithReply` promise.
    private func postBridge(_ message: [String: Any],
                            to webView: WKWebView) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: message,
                                              options: [.sortedKeys])
        let literal = String(decoding: data, as: UTF8.self)
        let script = """
        (() => {
          window.__pdshMCPBridgeReply = null;
          window.webkit.messageHandlers.pdshMcpControl.postMessage(\(literal)).then(
            value => { window.__pdshMCPBridgeReply = { ok: true, value: value ?? null }; },
            error => { window.__pdshMCPBridgeReply = { ok: false, error: String(error) }; });
        })();
        """
        _ = try await webView.evaluateJavaScript(script)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let raw = try await webView.evaluateJavaScript("window.__pdshMCPBridgeReply")
            if let reply = raw as? [String: Any] {
                guard (reply["ok"] as? Bool) == true else {
                    throw SimError.assertion("pdshMcpControl failed: \(reply["error"] ?? "unknown")")
                }
                return (reply["value"] as? [String: Any]) ?? [:]
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw SimError.timeout("pdshMcpControl did not reply within 15 s")
    }
}
