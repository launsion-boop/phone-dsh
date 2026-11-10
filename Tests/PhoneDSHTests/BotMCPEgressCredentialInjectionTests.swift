// SPDX-License-Identifier: MIT
//
// WPF0 verification for the "Bot identity impersonation" fix package:
// does the host inject a user-configured MCP connector credential when the
// request comes from the model-written `curl` path?
//
// These tests drive the real `PhoneMCPAccessSettings` -> `MCPEgressPolicy` ->
// `PhoneMCPCredentialProvider` -> `ModelGateway` chain, with a real loopback
// HTTP upstream. The only fixture is the credential value and the local
// upstream; nothing is asserted from reading the implementation.
//
// The known-failure test states the post-fix behaviour ("should be rejected")
// and is expected to fail on the current baseline. WPF1 removes the
// `XCTExpectFailure` marker and makes it a normal passing regression.

import Foundation
import Network
import XCTest
import PhoneDSHAgentCore
import PhoneDSHGateway
@testable import PhoneDSH

final class BotMCPEgressCredentialInjectionTests: XCTestCase {
    private static let connectorURL = "https://connector.example.test/mcp"
    private static let connectorAuthorization = "Bearer wpf0-fixture-user-connector-token"
    private static let connectorKey = "wpf0-fixture-connector-key"

    // MARK: - Fixtures

    private final class InMemoryDocumentStore: PhoneMCPAccessDocumentStore, @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?

        func read() throws -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return data
        }

        func write(_ data: Data) throws {
            lock.lock()
            self.data = data
            lock.unlock()
        }
    }

    private final class InMemorySecretStore: ModelProviderSecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]

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
            values.removeValue(forKey: reference)
            lock.unlock()
        }
    }

    private struct SeenRequest: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private final class LoopbackUpstream: @unchecked Sendable {
        private let queue = DispatchQueue(label: "phone-dsh.wpf0-connector-upstream")
        private let listener: NWListener
        private let stateLock = NSLock()
        private var stored: [SeenRequest] = []
        private(set) var port: UInt16 = 0

        init() throws {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1",
                                                                  port: .any)
            listener = try NWListener(using: parameters)
        }

        var requests: [SeenRequest] {
            stateLock.lock()
            defer { stateLock.unlock() }
            return stored
        }

        func start() async throws -> UInt16 {
            try await withCheckedThrowingContinuation { continuation in
                let once = OnceFlag()
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        let port = self.listener.port?.rawValue ?? 0
                        self.port = port
                        if once.claim() { continuation.resume(returning: port) }
                    case .failed(let error):
                        if once.claim() { continuation.resume(throwing: error) }
                    case .cancelled:
                        if once.claim() { continuation.resume(throwing: UpstreamError.cancelled) }
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: queue)
            }
        }

        func stop() {
            listener.cancel()
        }

        private func accept(_ connection: NWConnection) {
            connection.start(queue: queue)
            receiveHead(on: connection, buffer: Data())
        }

        private func receiveHead(on connection: NWConnection, buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                [weak self] data, _, complete, error in
                guard let self else { connection.cancel(); return }
                var accumulated = buffer
                if let data { accumulated.append(data) }
                let separator = Data("\r\n\r\n".utf8)
                if let range = accumulated.range(of: separator) {
                    self.parse(connection: connection, buffer: accumulated, headEnd: range)
                } else if complete || error != nil {
                    connection.cancel()
                } else {
                    self.receiveHead(on: connection, buffer: accumulated)
                }
            }
        }

        private func parse(connection: NWConnection, buffer: Data,
                           headEnd: Range<Data.Index>) {
            guard let head = String(data: buffer[..<headEnd.lowerBound], encoding: .utf8) else {
                connection.cancel()
                return
            }
            var lines = head.components(separatedBy: "\r\n")
            guard !lines.isEmpty else { connection.cancel(); return }
            let requestLine = lines.removeFirst().split(separator: " ")
            guard requestLine.count >= 2 else { connection.cancel(); return }
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                headers[name] = value
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            let received = Data(buffer[headEnd.upperBound...])
            if received.count >= length {
                deliver(connection: connection, method: String(requestLine[0]),
                        path: String(requestLine[1]), headers: headers,
                        body: Data(received.prefix(length)))
            } else {
                receiveBody(connection: connection, method: String(requestLine[0]),
                            path: String(requestLine[1]), headers: headers,
                            body: received, contentLength: length)
            }
        }

        private func receiveBody(connection: NWConnection, method: String, path: String,
                                 headers: [String: String], body: Data,
                                 contentLength: Int) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                [weak self] data, _, complete, error in
                guard let self else { connection.cancel(); return }
                var accumulated = body
                if let data { accumulated.append(data) }
                if accumulated.count >= contentLength || complete || error != nil {
                    self.deliver(connection: connection, method: method, path: path,
                                 headers: headers,
                                 body: Data(accumulated.prefix(contentLength)))
                } else {
                    self.receiveBody(connection: connection, method: method, path: path,
                                     headers: headers, body: accumulated,
                                     contentLength: contentLength)
                }
            }
        }

        private func deliver(connection: NWConnection, method: String, path: String,
                             headers: [String: String], body: Data) {
            stateLock.lock()
            stored.append(SeenRequest(method: method, path: path,
                                      headers: headers, body: body))
            stateLock.unlock()
            let payload = Data(#"{"ok":true}"#.utf8)
            var head = "HTTP/1.1 200 OK\r\n"
            head += "Content-Type: application/json\r\n"
            head += "Content-Length: \(payload.count)\r\n"
            head += "Connection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + payload,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private enum UpstreamError: Error {
        case cancelled
    }

    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }

    private final class NoneCredentialProvider: CredentialProvider {
        func credential(for scope: CredentialScope) async throws -> Credential {
            .none
        }

        func invalidate(_ credential: Credential, for scope: CredentialScope) async {}
    }

    private final class CollectFailure: Error {}

    private func makeSettings() -> PhoneMCPAccessSettings {
        PhoneMCPAccessSettings(documentStore: InMemoryDocumentStore(),
                               secretStore: InMemorySecretStore())
    }

    private func makeGateway(policy: MCPEgressPolicy,
                             provider: any CredentialProvider) -> ModelGateway {
        let configuration = ModelGatewayConfiguration(
            allowedUpstreamHosts: [],
            responseLogQuotaBytes: 1_000_000,
            backoff: ModelGatewayBackoffPolicy(initialDelay: 0,
                                               multiplier: 2,
                                               maximumDelay: 1,
                                               jitterFraction: 0,
                                               maximumAttempts: 1),
            upstreamRequestTimeout: 10)
        return ModelGateway(configuration: configuration,
                            credentialProvider: provider,
                            egressAuthorizer: policy)
    }

    private func collect(_ gateway: ModelGateway,
                         _ request: GatewayRequest) async throws -> (Int, [String: String], Data) {
        var status: Int?
        var headers: [String: String] = [:]
        var body = Data()
        for try await chunk in gateway.handle(request) {
            if let chunkStatus = chunk.status {
                status = chunkStatus
                headers = chunk.headers
            }
            body.append(chunk.body)
        }
        guard let status else { throw CollectFailure() }
        return (status, headers, body)
    }

    // MARK: - Tests

    /// Counter-check that the connector route really is in the live policy:
    /// the production wrapper resolves the user's stored headers for the exact
    /// scope before any request is made.
    func testUserConnectorRouteResolvesTheStoredHostHeader() async throws {
        let settings = makeSettings()
        let grant = try settings.grant(
            serverName: "connector",
            url: Self.connectorURL,
            headers: ["Authorization", "X-Connector-Key"],
            values: [
                "Authorization": Self.connectorAuthorization,
                "X-Connector-Key": Self.connectorKey,
            ])
        try settings.commitGrant(serverName: grant.serverName,
                                 expectedURL: grant.url,
                                 expectedHeaders: grant.headers)

        var plan = ModelProviderLaunchPlan()
        let policy = MCPHostConfiguration.apply(to: &plan, settings: settings)
        let url = try XCTUnwrap(URL(string: Self.connectorURL))
        XCTAssertTrue(policy.allowsEgressHost(url),
                      "the exact connector URL is an MCP egress route")

        let credential = try await plan.credentialProvider.credential(
            for: ModelGatewayCredentialRouting.scope(for: url))
        XCTAssertEqual(credential.kind, .headers([
            "Authorization": Self.connectorAuthorization,
            "X-Connector-Key": Self.connectorKey,
        ]))
        XCTAssertEqual(credential.value, "",
                       "the exact-route credential is a header map, not the model key")
    }

    /// The verification the fix package asked for: a Worker request shaped like
    /// the model-written `curl` shim (loopback `Authorization` plus an arbitrary
    /// body) targets exactly the user's connector URL. Today the host injects
    /// the stored connector credential and forwards the request. After WPF1 the
    /// missing `X-PDSH-MCP-Egress` value must produce a pre-upstream 403.
    func testKnownFailureModelWrittenRequestGetsTheUserConnectorCredential() async throws {
        let upstream = try LoopbackUpstream()
        let port = try await upstream.start()
        defer { upstream.stop() }

        // The local port is the only way to observe what the real gateway
        // sends; this mirrors a user connector whose exact URL points at a
        // local server.
        let localURL = "http://127.0.0.1:\(port)/mcp"
        let settings = makeSettings()
        let grant = try settings.grant(
            serverName: "local-connector",
            url: localURL,
            headers: ["Authorization", "X-Connector-Key"],
            values: [
                "Authorization": Self.connectorAuthorization,
                "X-Connector-Key": Self.connectorKey,
            ])
        try settings.commitGrant(serverName: grant.serverName,
                                 expectedURL: grant.url,
                                 expectedHeaders: grant.headers)

        var plan = ModelProviderLaunchPlan()
        let policy = MCPHostConfiguration.apply(to: &plan, settings: settings)
        let gateway = makeGateway(policy: policy, provider: plan.credentialProvider)
        addTeardownBlock { await gateway.shutdown() }

        let target = try XCTUnwrap(URL(string: localURL))
        let request = GatewayRequest(
            method: "POST",
            url: target,
            headers: [
                // The shape the production curl shim sends over /v1/http.
                "authorization": "Bearer wpf0-fixture-loopback-token",
                "content-type": "application/json",
            ],
            body: Data(#"{"jsonrpc":"2.0","id":"wpf0","method":"tools/call"}"#.utf8))
        let (status, headers, _) = try await collect(gateway, request)

        XCTExpectFailure("WPF0 connector inference: the host injects the user's connector "
            + "credential for a model-written /v1/http request") {
            XCTAssertEqual(status, 403,
                           "a request without the egress credential must be rejected at egress")
            XCTAssertEqual(headers["x-pdsh-proxy-error"], "mcp_egress_forbidden",
                           "the rejection must carry the stable egress error code")
            XCTAssertEqual(upstream.requests.count, 0,
                           "a rejected request must not reach the connector")
            let seen = upstream.requests.first
            XCTAssertNil(seen?.headers["authorization"],
                         "the host injected the user's connector Authorization: \(seen?.headers ?? [:])")
            XCTAssertNil(seen?.headers["x-connector-key"],
                         "the host injected the user's connector header: \(seen?.headers ?? [:])")
        }
    }
}
