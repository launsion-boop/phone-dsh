// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — production MCP wiring on the iOS Simulator.
//
// This suite boots the same `WebHostConfiguration` assembly the App's Web
// surface uses, wraps the real model credential provider with
// `MCPHostConfiguration` (the exact-URL policy and independent MCP Keychain
// router), and drives the real `phone/mcpUpsert` / `phone/mcpReconnect` /
// `phone/mcpRemove` Remote methods. The local MCP fixture deliberately sends
// no CORS headers and uses a token different from the model key.
//
// Boundary: this is simulator evidence for the host assembly + Worker + native
// gateway. The page bridge path is covered separately by
// `MCPBridgeProductionSimTests`; this suite does not prove the SwiftUI sheet,
// ATS/local-network prompts on a physical iPhone or a real remote MCP server.
// Those remain NOT_RUN until a Mac/device run.

import Foundation
import Network
import XCTest
import ProbeKit
import PhoneDSH
import PhoneDSHAgentCore
import PhoneDSHEngine

@MainActor
final class MCPProductionSimTests: XCTestCase {
    private static let modelKey = "model-key-must-not-reach-mcp"
    private static let workerPlaceholder = "phone-host-injects-key"

    func testProductionWebHostExactMCPGrantAndIndependentKey() async throws {
        let nonce = UUID().uuidString.prefix(8).lowercased()
        let serverName = "prod-\(nonce)"
        let directory = try SimEnvironment.reportsDirectory()
        let report = SimSuiteReport(suite: "worker-mcp-production", gate: "G1",
                                    directory: directory,
                                    fileName: "worker-mcp-production-report.json")
        let fixture = NoCorsMCPFixture()
        let mcpURL = try fixture.start()
        let modelKey = Self.modelKey
        let mcpToken = fixture.token
        var host: PhoneDSHHost?
        var window: SimVisibleWindow?
        let suiteName = "MCPProductionSimTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secrets = SimMCPSecretStore()
        let settings = PhoneMCPAccessSettings(defaults: defaults, secretStore: secrets)

        do {
            report.set("nonce", String(nonce))
            report.set("mcp_url", mcpURL.absoluteString)
            report.set("fixture_cors", "none")
            let workspace = SimEnvironment.workspaceRoot(name: "mcp-production-\(nonce)")
            try FileManager.default.createDirectory(at: workspace,
                                                    withIntermediateDirectories: true)
            let bundle = try SimEnvironment.workerBundle()

            var plan = ModelProviderLaunchPlan(
                allowedModelHosts: [],
                credentialProvider: RecordingModelCredentialProvider(value: modelKey),
                environment: [:])
            let policy = MCPHostConfiguration.apply(to: &plan, settings: settings)
            try settings.grant(serverName: serverName,
                               url: mcpURL.absoluteString,
                               headers: ["Authorization"],
                               values: ["Authorization": "Bearer \(mcpToken)"])
            settings.apply(to: policy)

            let visibleWindow = SimVisibleWindow(size: CGSize(width: 430, height: 932))
            window = visibleWindow
            XCTAssertTrue(visibleWindow.isAttached)
            let anchor = VisibleEngineAnchor()
            visibleWindow.anchor.addSubview(anchor.view)
            visibleWindow.window.layoutIfNeeded()
            guard anchor.isInWindow else {
                throw SimError.assertion("the Web host anchor is not in a visible window")
            }
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
                    "DEEPSEEK_API_KEY": Self.workerPlaceholder,
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
            try await simWait(timeout: 240, label: "production Web host Running") {
                await newHost.state == .running
            }
            let transport = try await newHost.makeTransport()

            // MARK: exact URL + host-managed key reaches the no-CORS server
            let upsert = try await transport.call(
                "phone/mcpUpsert",
                args: .object(["request": .object([
                    "serverName": .string(serverName),
                    "url": .string(mcpURL.absoluteString),
                    "headersFromEnv": .object(["Authorization": .string("PDSH_SIM_MCP_TOKEN")]),
                    "hostManagedHeaders": .array([.string("Authorization")]),
                    "enabled": .bool(true),
                    "toolCallTimeoutMs": .number(5_000),
                ])]))
            let tools = (upsert["tools"]?.arrayValue ?? []).compactMap(\.stringValue)
            let expected = ["mcp__\(serverName)__echo", "mcp__\(serverName)__ping"]
            let authorized = fixture.requestsSnapshot.contains { request in
                request.headers["authorization"] == "Bearer \(mcpToken)"
                    && request.headers["x-api-key"] == nil
                    && request.headers["access-control-request-method"] == nil
            }
            try require(report, "mcp.production.exact_origin",
                        upsert["status"]?.stringValue == "connected"
                            && tools == expected
                            && authorized,
                        metrics: ["status": upsert["status"]?.stringValue ?? "",
                                  "tools": tools.joined(separator: ","),
                                  "authorized_requests": fixture.requestsSnapshot.filter {
                                      $0.headers["authorization"] == "Bearer \(mcpToken)"
                                  }.count,
                                  "cors_headers": fixture.sentCORSHeaders],
                        detail: "the real WebHostConfiguration/gateway admitted only the exact MCP URL, injected the "
                            + "independent MCP token, and the no-CORS fixture returned initialize/tools/list")

            // MARK: an unregistered sibling path is not admitted
            var siblingDenied = false
            do {
                _ = try await transport.call(
                    "phone/mcpUpsert",
                    args: .object(["request": .object([
                        "serverName": .string("other-\(nonce)"),
                        "url": .string("http://127.0.0.1:\(mcpURL.port ?? 0)/other"),
                        "headersFromEnv": .object([:]),
                        "enabled": .bool(true),
                        "toolCallTimeoutMs": .number(1_000),
                    ])]))
            } catch {
                siblingDenied = true
            }
            let listAfterDenied = try await transport.call("phone/mcpList", args: .object([:]))
            let serversAfterDenied = (listAfterDenied["servers"]?.arrayValue ?? [])
                .compactMap { $0["serverName"]?.stringValue }
            try require(report, "mcp.production.extra_host_denied",
                        siblingDenied && serversAfterDenied == [serverName],
                        metrics: ["sibling_denied": siblingDenied,
                                  "servers": serversAfterDenied.joined(separator: ",")],
                        detail: "a same-host sibling path outside the exact grant is rejected by host_not_allowed "
                            + "before the MCP client writes a row")

            // MARK: revoke removes both the route and the Keychain value
            try settings.revoke(serverName: serverName)
            settings.apply(to: policy)
            var reconnectDenied = false
            do {
                _ = try await transport.call(
                    "phone/mcpReconnect",
                    args: .object(["request": .object(["serverName": .string(serverName)])]))
            } catch {
                reconnectDenied = true
            }
            let noRoute = !policy.allowsEgressHost(URL(string: mcpURL.absoluteString)!)
            let noKey = !secrets.allValues().contains { $0.contains(mcpToken) }
            try require(report, "mcp.production.revoke",
                        reconnectDenied && noRoute && noKey,
                        metrics: ["reconnect_denied": reconnectDenied,
                                  "route_present": !noRoute,
                                  "key_present": !noKey],
                        detail: "revoking the native grant removed the live exact-URL admission and the dedicated "
                            + "Keychain value; reconnect then failed closed")

            _ = try await transport.call(
                "phone/mcpRemove",
                args: .object(["request": .object(["serverName": .string(serverName)])]))
            let finalList = try await transport.call("phone/mcpList", args: .object([:]))
            let finalServers = finalList["servers"]?.arrayValue ?? []
            try require(report, "mcp.production.remove",
                        finalServers.isEmpty
                            && !secrets.allValues().contains { $0.contains(mcpToken) },
                        metrics: ["servers_after_remove": finalServers.count,
                                  "mcp_keychain_values": secrets.allValues().count],
                        detail: "the shared Worker registry has no row and the independent MCP Keychain has no value; "
                            + "the model key was never used for MCP")

            if let host { try await host.stop() }
            host = nil
            window?.shutdown()
            window = nil
            fixture.stop()
            defaults.removePersistentDomain(forName: suiteName)
            report.finish(ok: true)
            _ = try report.write()
        } catch {
            report.record("mcp.production.failure", status: .fail, gating: true,
                          metrics: ["error": String(describing: error)],
                          threshold: simG1Threshold("mcp_production_wiring", measured: 0),
                          detail: "production MCP wiring failed: \(String(describing: error))")
            if let host { try await host.stop() }
            window?.shutdown()
            fixture.stop()
            defaults.removePersistentDomain(forName: suiteName)
            report.finish(ok: false, failure: String(describing: error))
            _ = try? report.write()
            throw error
        }
    }

    private func require(_ report: SimSuiteReport,
                         _ name: String,
                         _ condition: Bool,
                         metrics: [String: Any],
                         detail: String) throws {
        report.record(name, status: condition ? .pass : .fail, gating: true,
                      metrics: metrics,
                      threshold: simG1Threshold("mcp_production_\(name)",
                                                measured: condition ? 1 : 0),
                      detail: detail)
        if !condition {
            throw SimError.assertion(detail)
        }
    }
}

// MARK: - MCP fixture without CORS

struct ObservedMCPRequest {
    let method: String
    let path: String
    let headers: [String: String]
}

/// Minimal Streamable HTTP MCP server. It deliberately sends no CORS header:
/// the production path is the host gateway's URLSession, not a browser fetch.
final class NoCorsMCPFixture: @unchecked Sendable {
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private let queue = DispatchQueue(label: "pdsh.sim.mcp.production")
    private let lock = NSLock()
    private var listener: NWListener?
    private var requests: [ObservedMCPRequest] = []
    private(set) var sentCORSHeaders = false

    var requestsSnapshot: [ObservedMCPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func start() throws -> URL {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error): failure = error; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success else {
            listener.cancel()
            throw SimError.environment("the MCP fixture listener timed out")
        }
        if let failure {
            listener.cancel()
            throw SimError.environment("the MCP fixture listener failed: \(failure)")
        }
        guard let port = listener.port?.rawValue, port != 0 else {
            listener.cancel()
            throw SimError.environment("the MCP fixture bound no port")
        }
        self.listener = listener
        return URL(string: "http://127.0.0.1:\(port)/mcp")!
    }

    func stop() {
        lock.lock()
        let current = listener
        listener = nil
        lock.unlock()
        current?.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if let response = self.handle(accumulated) {
                self.send(response, on: connection)
                return
            }
            if complete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: accumulated)
        }
    }

    private func handle(_ data: Data) -> Data? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headRange = data.range(of: separator),
              let head = String(data: data[..<headRange.lowerBound], encoding: .utf8) else {
            return nil
        }
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = Data(data[headRange.upperBound...])
        guard body.count >= length else { return nil }
        if method == "GET" { return response(405, body: Data()) }
        if method == "DELETE" { return response(200, body: Data()) }
        lock.lock()
        requests.append(ObservedMCPRequest(method: method,
                                           path: String(parts[1]),
                                           headers: headers))
        lock.unlock()
        guard headers["authorization"] == "Bearer \(token)" else {
            return response(401, body: Data())
        }
        guard let object = try? JSONSerialization.jsonObject(
            with: Data(body.prefix(length))) as? [String: Any],
              let rpcMethod = object["method"] as? String,
              let id = object["id"] else {
            return response(202, body: Data(), session: true)
        }
        let result: [String: Any]
        switch rpcMethod {
        case "initialize":
            let requested = (object["params"] as? [String: Any])?["protocolVersion"] as? String
            result = ["protocolVersion": requested ?? "2025-06-18",
                      "capabilities": ["tools": [:]],
                      "serverInfo": ["name": "sim-no-cors", "version": "0.1.0"]]
        case "tools/list":
            result = ["tools": [
                ["name": "ping", "description": "pong",
                 "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]],
                ["name": "echo", "description": "echo",
                 "inputSchema": ["type": "object",
                                 "properties": ["message": ["type": "string"]],
                                 "required": ["message"],
                                 "additionalProperties": false]],
            ]]
        case "tools/call":
            let params = object["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            if name == "ping" {
                result = ["content": [["type": "text", "text": "pong"]]]
            } else if name == "echo" {
                result = ["content": [["type": "text",
                                       "text": "echo:\(arguments["message"] as? String ?? "")"]]]
            } else {
                return response(200, object: ["jsonrpc": "2.0", "id": id,
                                              "error": ["code": -32602,
                                                        "message": "unknown tool"]])
            }
        default:
            return response(200, object: ["jsonrpc": "2.0", "id": id,
                                          "error": ["code": -32601,
                                                    "message": "method not found"]])
        }
        return response(200, object: ["jsonrpc": "2.0", "id": id, "result": result],
                        session: true)
    }

    private func response(_ status: Int,
                          body: Data,
                          session: Bool = false) -> Data {
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Status")\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        if session { head += "Mcp-Session-Id: \(token)\r\n" }
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    private func response(_ status: Int, object: Any, session: Bool = false) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.sortedKeys])) ?? Data()
        return response(status, body: body, session: session)
    }

    private func send(_ response: Data, on connection: NWConnection) {
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

// MARK: - Test-only credential store

final class SimMCPSecretStore: ModelProviderSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var failNextDelete = false

    func failOneDelete() {
        lock.lock()
        failNextDelete = true
        lock.unlock()
    }

    func secret(for reference: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[reference]
    }

    func setSecret(_ secret: String, for reference: String) throws {
        lock.lock()
        values[reference] = secret
        lock.unlock()
    }

    func deleteSecret(for reference: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if failNextDelete {
            failNextDelete = false
            throw ModelProviderSettingsError.keychain(-1)
        }
        values.removeValue(forKey: reference)
    }

    func value(for reference: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[reference]
    }

    func allValues() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(values.values)
    }
}

struct RecordingModelCredentialProvider: CredentialProvider {
    let value: String

    func credential(for scope: CredentialScope) async throws -> Credential {
        Credential(kind: .apiKey(header: "x-api-key"), value: value)
    }

    func invalidate(_ credential: Credential, for scope: CredentialScope) async {}
}
