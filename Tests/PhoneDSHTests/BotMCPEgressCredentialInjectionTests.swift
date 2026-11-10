// SPDX-License-Identifier: MIT
//
// WPF1 verification for the "Bot identity impersonation" fix package:
// the host must require the per-run `X-PDSH-MCP-Egress` credential on every
// exact MCP route before resolving or injecting a credential, and must not
// forward that header upstream.
//
// These tests drive the real `PhoneMCPAccessSettings` -> `MCPEgressPolicy` ->
// `PhoneMCPCredentialProvider` -> `ModelGateway` chain, a real loopback HTTP
// upstream and the real `/v1/http` writer. The egress suites in
// `spec/bot/v1/golden/mcp-egress.phone.json` drive `ModelGateway.mcpEgressAdmitted`
// and the loopback failure envelope.

import Foundation
import Network
import XCTest
import PhoneDSHAgentCore
@testable import PhoneDSHGateway
import PhoneDSHLoopback
@testable import PhoneDSH

final class BotMCPEgressCredentialInjectionTests: XCTestCase {
    private static let connectorURL = "https://connector.example.test/mcp"
    private static let connectorAuthorization = "Bearer wpf0-fixture-user-connector-token"
    private static let connectorKey = "wpf0-fixture-connector-key"
    private static let egressToken = "wpf0-fixture-egress-token"

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

    /// Wraps a provider and records whether credential resolution was reached.
    private final class CountingCredentialProvider: CredentialProvider, @unchecked Sendable {
        private let base: any CredentialProvider
        private let lock = NSLock()
        private var calls = 0

        init(base: any CredentialProvider) {
            self.base = base
        }

        var credentialCalls: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }

        func credential(for scope: CredentialScope) async throws -> Credential {
            lock.lock()
            calls += 1
            lock.unlock()
            return try await base.credential(for: scope)
        }

        func invalidate(_ credential: Credential, for scope: CredentialScope) async {
            await base.invalidate(credential, for: scope)
        }
    }

    private final class CollectFailure: Error {}

    private func makeSettings() -> PhoneMCPAccessSettings {
        PhoneMCPAccessSettings(documentStore: InMemoryDocumentStore(),
                               secretStore: InMemorySecretStore())
    }

    private func makeGateway(policy: MCPEgressPolicy,
                             provider: any CredentialProvider,
                             mcpEgressToken: String? = BotMCPEgressCredentialInjectionTests.egressToken,
                             responseLog: (any ResponseLogging)? = nil,
                             allowedUpstreamHosts: Set<String> = []) -> ModelGateway {
        if let mcpEgressToken {
            policy.setMCPEgressToken(mcpEgressToken)
        }
        let configuration = ModelGatewayConfiguration(
            allowedUpstreamHosts: allowedUpstreamHosts,
            responseLogQuotaBytes: 1_000_000,
            backoff: ModelGatewayBackoffPolicy(initialDelay: 0,
                                               multiplier: 2,
                                               maximumDelay: 1,
                                               jitterFraction: 0,
                                               maximumAttempts: 1),
            upstreamRequestTimeout: 10)
        return ModelGateway(configuration: configuration,
                            credentialProvider: provider,
                            responseLog: responseLog,
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

    /// Collects the pre-head failure of one gateway exchange.
    private func collectFailure(_ gateway: ModelGateway,
                                _ request: GatewayRequest) async throws -> Error {
        do {
            _ = try await collect(gateway, request)
            throw CollectFailure()
        } catch let error as ModelGatewayError {
            return error
        }
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
    /// body) targets exactly the user's connector URL without the egress
    /// credential. The host must answer 403 `mcp_egress_forbidden` before it
    /// resolves the stored connector header or contacts the upstream.
    func testModelWrittenRequestWithoutEgressCredentialIsRejectedBeforeCredentialResolution() async throws {
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
        let counting = CountingCredentialProvider(base: plan.credentialProvider)
        let gateway = makeGateway(policy: policy, provider: counting)
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
        let error = try await collectFailure(gateway, request)
        XCTAssertEqual(error as? ModelGatewayError, .mcpEgressForbidden)
        XCTAssertEqual(counting.credentialCalls, 0,
                       "a rejected request must not resolve any credential")
        XCTAssertEqual(upstream.requests.count, 0,
                       "a rejected request must not reach the connector")
        let failure = HTTPEgressFailure(error: error)
        XCTAssertEqual(failure.status, 403)
        XCTAssertEqual(failure.code, "mcp_egress_forbidden")
        XCTAssertEqual(String(decoding: failure.encodedBody(), as: UTF8.self),
                       #"{"error":{"code":"mcp_egress_forbidden","message":"the MCP egress credential is missing or invalid"}}"#)
    }

    /// A trusted Bot client's request reaches the upstream with the host
    /// credential and without the hop header.
    func testBotRouteWithCorrectEgressCredentialInjectsBotBearerAndStripsTheHeader() async throws {
        let upstream = try LoopbackUpstream()
        let port = try await upstream.start()
        defer { upstream.stop() }
        let localURL = "http://127.0.0.1:\(port)/mcp"
        let botBearer = "Bearer wpf1-fixture-bot-bearer"

        let policy = MCPEgressPolicy()
        try policy.grantBotRuntimeEndpoint(try XCTUnwrap(URL(string: localURL)),
                                           token: "wpf1-fixture-bot-bearer")
        let gateway = makeGateway(
            policy: policy,
            provider: PhoneMCPCredentialProvider(policy: policy,
                                                 base: NoneCredentialProvider()))
        addTeardownBlock { await gateway.shutdown() }

        let target = try XCTUnwrap(URL(string: localURL))
        let body = Data(#"{"jsonrpc":"2.0","id":"wpf1","method":"tools/list"}"#.utf8)
        // The same Bot route without the hop credential is refused before any
        // upstream contact; the correct request below is the only one seen.
        let rejected = try await collectFailure(
            gateway,
            GatewayRequest(method: "POST",
                           url: target,
                           headers: [
                               "authorization": "Bearer phone-host-injects-bot-mcp-token",
                               "content-type": "application/json",
                           ],
                           body: body))
        XCTAssertEqual(rejected as? ModelGatewayError, .mcpEgressForbidden)
        XCTAssertEqual(upstream.requests.count, 0)

        let request = GatewayRequest(
            method: "POST",
            url: target,
            headers: [
                "authorization": "Bearer phone-host-injects-bot-mcp-token",
                "content-type": "application/json",
                GatewayRequest.mcpEgressHeader: Self.egressToken,
            ],
            body: body)
        let (status, _, _) = try await collect(gateway, request)
        XCTAssertEqual(status, 200)
        let seen = try XCTUnwrap(upstream.requests.first)
        XCTAssertEqual(seen.headers["authorization"], botBearer,
                       "the host injects the Bot bearer for the exact route")
        XCTAssertNil(seen.headers["x-pdsh-mcp-egress"],
                     "the egress credential must never reach the upstream")
    }

    /// A trusted user-connector client's request gets the stored header map,
    /// and the hop header is stripped before the upstream request.
    func testUserConnectorWithCorrectEgressCredentialInjectsStoredHeadersAndStripsTheHeader() async throws {
        let upstream = try LoopbackUpstream()
        let port = try await upstream.start()
        defer { upstream.stop() }
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

        let request = GatewayRequest(
            method: "POST",
            url: try XCTUnwrap(URL(string: localURL)),
            headers: [
                "content-type": "application/json",
                "X-PDSH-MCP-EGRESS": Self.egressToken,
            ],
            body: Data(#"{"jsonrpc":"2.0","id":"wpf1","method":"tools/list"}"#.utf8))
        let (status, _, _) = try await collect(gateway, request)
        XCTAssertEqual(status, 200)
        let seen = try XCTUnwrap(upstream.requests.first)
        XCTAssertEqual(seen.headers["authorization"], Self.connectorAuthorization)
        XCTAssertEqual(seen.headers["x-connector-key"], Self.connectorKey)
        XCTAssertNil(seen.headers["x-pdsh-mcp-egress"],
                     "the egress credential must never reach the connector")
    }

    /// The real `/v1/http` writer emits the frozen 403 envelope and writes no
    /// response-log entry. The target is an authorized exact route that is not
    /// listening, so a missing gate would surface a 502 instead.
    func testLoopbackHTTPEgressWritesTheFrozenForbiddenEnvelopeWithoutAResponseLogEntry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpf1-response-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let responseLog = try ResponseLog(root: root, quotaBytes: 1_000_000)

        let policy = MCPEgressPolicy()
        try policy.grant(serverName: "dead-connector",
                         url: try XCTUnwrap(URL(string: "http://127.0.0.1:9/mcp")),
                         headers: ["authorization": "Bearer fixture"])
        let gateway = makeGateway(
            policy: policy,
            provider: PhoneMCPCredentialProvider(policy: policy,
                                                 base: NoneCredentialProvider()),
            responseLog: responseLog)
        addTeardownBlock { await gateway.shutdown() }

        let loopback = LoopbackServer(
            configuration: LoopbackConfiguration(token: "wpf1-loopback-token"),
            routes: LoopbackRoutes(httpEgress: PhoneDSHGatewayEgress(gateway: gateway)))
        let endpoint = try await loopback.start()
        defer { Task { await loopback.stop() } }

        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("v1/http"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.setValue("http://127.0.0.1:9/mcp", forHTTPHeaderField: "X-PDSH-Target-URL")
        request.setValue("POST", forHTTPHeaderField: "X-PDSH-Target-Method")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":"wpf1","method":"tools/call"}"#.utf8)
        let (body, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 403)
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-PDSH-Proxy-Error"),
                       "mcp_egress_forbidden")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"),
                       "application/json; charset=utf-8")
        XCTAssertEqual(String(decoding: body, as: UTF8.self),
                       #"{"error":{"code":"mcp_egress_forbidden","message":"the MCP egress credential is missing or invalid"}}"#)
        let logged = await responseLog.totalBytes()
        XCTAssertEqual(logged, 0,
                       "a pre-credential egress rejection must not write the response log")
    }

    /// The frozen vector has correct-value cases for three of the four Bot
    /// paths; this drives the fourth (`/identity/cancel`) through the same real
    /// policy/gate so "Bot four routes" is covered without editing the spec.
    func testAllFourBotRoutesRequireAndAcceptTheEgressCredential() async throws {
        let policy = MCPEgressPolicy()
        try policy.grantBotRuntimeEndpoint(
            try XCTUnwrap(URL(string: "http://127.0.0.1:8787/mcp")))
        let counting = CountingCredentialProvider(base: NoneCredentialProvider())
        let gateway = makeGateway(policy: policy, provider: counting)
        addTeardownBlock { await gateway.shutdown() }

        for path in ["mcp", "identity/register", "identity/cancel", "approval"] {
            let url = try XCTUnwrap(URL(string: "http://127.0.0.1:8787/\(path)"))
            XCTAssertTrue(gateway.mcpEgressAdmitted(
                GatewayRequest(method: "POST", url: url,
                               headers: [GatewayRequest.mcpEgressHeader: Self.egressToken])),
                path)
            XCTAssertFalse(gateway.mcpEgressAdmitted(
                GatewayRequest(method: "POST", url: url)), path)
            let error = try await collectFailure(
                gateway, GatewayRequest(method: "POST", url: url))
            XCTAssertEqual(error as? ModelGatewayError, .mcpEgressForbidden, path)
        }
        XCTAssertEqual(counting.credentialCalls, 0)
    }

    /// A target outside every exact MCP route keeps the pre-WPF1 behaviour: no
    /// egress header is required and the allowed host is reached normally.
    func testNonMCPWhitelistedTargetIsUnaffectedByTheGate() async throws {
        let upstream = try LoopbackUpstream()
        let port = try await upstream.start()
        defer { upstream.stop() }
        let localURL = "http://127.0.0.1:\(port)/v1/messages"
        let policy = MCPEgressPolicy()
        let gateway = makeGateway(
            policy: policy,
            provider: NoneCredentialProvider(),
            allowedUpstreamHosts: ["127.0.0.1:\(port)"])
        addTeardownBlock { await gateway.shutdown() }

        let (status, _, _) = try await collect(
            gateway,
            GatewayRequest(method: "POST",
                           url: try XCTUnwrap(URL(string: localURL)),
                           headers: ["content-type": "application/json"],
                           body: Data("{}".utf8)))
        XCTAssertEqual(status, 200)
        XCTAssertEqual(upstream.requests.count, 1,
                       "a non-MCP allowed host must still be reachable without the header")
        XCTAssertNil(upstream.requests.first?.headers["x-pdsh-mcp-egress"])
    }

    // MARK: - Contract vectors

    private struct EgressVectorRoute: Decodable {
        let kind: String
        let url: String
    }

    private struct EgressVectorExpect: Decodable {
        let admitted: Bool?
        let status: Int?
        let error: String?
    }

    private struct EgressVectorCase: Decodable {
        let suite: String
        let name: String
        let target: String?
        let headers: [String: String]?
        let expect: EgressVectorExpect
    }

    private struct EgressVector: Decodable {
        let egressToken: String
        let egressRoutes: [EgressVectorRoute]
        let valid: [EgressVectorCase]
        let invalid: [EgressVectorCase]
    }

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PhoneDSHTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository
    }

    /// Every `egress` case in the frozen vector drives the real
    /// `MCPEgressPolicy` exact-route predicate and the real gateway gate; the
    /// invalid cases also drive the loopback failure mapping.
    func testEgressVectorsDriveTheRealHostGateAndFailureEnvelope() async throws {
        let file = Self.repositoryRoot()
            .appendingPathComponent("spec/bot/v1/golden/mcp-egress.phone.json")
        let vector = try JSONDecoder().decode(EgressVector.self,
                                              from: try Data(contentsOf: file))
        XCTAssertEqual(vector.egressToken, Self.egressToken)

        let policy = MCPEgressPolicy()
        for route in vector.egressRoutes {
            let url = try XCTUnwrap(URL(string: route.url), route.url)
            switch route.kind {
            case "bot":
                // `grantBotRuntimeEndpoint` takes the `/mcp` endpoint and
                // derives the four exact paths from its parent.
                var components = try XCTUnwrap(
                    URLComponents(url: url, resolvingAgainstBaseURL: false))
                components.path = "/mcp"
                components.query = nil
                try policy.grantBotRuntimeEndpoint(try XCTUnwrap(components.url))
            case "user":
                try policy.grant(serverName: "vector-\(url.host ?? "user")",
                                 url: url,
                                 headers: ["authorization": "Bearer fixture"])
            default:
                XCTFail("unknown egress route kind \(route.kind)")
            }
        }
        XCTAssertTrue(policy.allowsEgressHost(
            try XCTUnwrap(URL(string: "http://127.0.0.1:8787/mcp"))))
        XCTAssertTrue(policy.allowsEgressHost(
            try XCTUnwrap(URL(string: "https://connector.example.test/mcp?session=wpf0"))))

        let counting = CountingCredentialProvider(base: NoneCredentialProvider())
        let gateway = makeGateway(policy: policy,
                                  provider: counting,
                                  mcpEgressToken: vector.egressToken)
        addTeardownBlock { await gateway.shutdown() }

        var validCount = 0
        for testCase in vector.valid where testCase.suite == "egress" {
            validCount += 1
            let url = try XCTUnwrap(URL(string: testCase.target ?? ""), testCase.name)
            let request = GatewayRequest(method: "POST",
                                         url: url,
                                         headers: testCase.headers ?? [:])
            XCTAssertEqual(testCase.expect.admitted, true, testCase.name)
            XCTAssertTrue(gateway.mcpEgressAdmitted(request), testCase.name)
            // The gate's scope is the policy's exact route set, not the path
            // suffix: an identical-shaped sibling/port is outside it.
            if !policy.allowsEgressHost(url) {
                XCTAssertTrue(gateway.mcpEgressAdmitted(
                    GatewayRequest(method: "POST", url: url)), testCase.name)
            }
        }
        XCTAssertEqual(validCount, 9)

        var invalidCount = 0
        for testCase in vector.invalid where testCase.suite == "egress" {
            invalidCount += 1
            let url = try XCTUnwrap(URL(string: testCase.target ?? ""), testCase.name)
            let request = GatewayRequest(method: "POST",
                                         url: url,
                                         headers: testCase.headers ?? [:])
            XCTAssertEqual(testCase.expect.admitted, false, testCase.name)
            XCTAssertFalse(gateway.mcpEgressAdmitted(request), testCase.name)
            let error = try await collectFailure(gateway, request)
            XCTAssertEqual(error as? ModelGatewayError, .mcpEgressForbidden, testCase.name)
            let failure = HTTPEgressFailure(error: error)
            XCTAssertEqual(failure.status, testCase.expect.status, testCase.name)
            XCTAssertEqual(failure.code, testCase.expect.error, testCase.name)
            XCTAssertEqual(String(decoding: failure.encodedBody(), as: UTF8.self),
                           #"{"error":{"code":"mcp_egress_forbidden","message":"the MCP egress credential is missing or invalid"}}"#,
                           testCase.name)
        }
        XCTAssertEqual(invalidCount, 10)
        XCTAssertEqual(counting.credentialCalls, 0,
                       "no invalid vector may resolve a credential")
    }
}
