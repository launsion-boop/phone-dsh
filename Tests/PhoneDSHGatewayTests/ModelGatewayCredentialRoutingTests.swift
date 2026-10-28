// SPDX-License-Identifier: MIT
// ModelGateway credential routing: the gateway puts the lowercased host and
// normalized request path into `CredentialScope`, so an independent Search/
// Fetch API and the model Messages API on the same host can use different keys.
// The gateway test uses the real MockUpstreamServer and asserts what actually
// reached the upstream.

import Foundation
import XCTest
import PhoneDSHGateway
import PhoneDSHAgentCore

final class ModelGatewayCredentialRoutingTests: XCTestCase {
    func testScopeUsesLowercasedHostNormalizedPathSchemeAndPort() {
        let messages = ModelGatewayCredentialRouting.scope(
            for: URL(string: "https://API.Example.COM:8443/v1/messages/")!)
        XCTAssertEqual(messages.service, "api.example.com")
        XCTAssertEqual(messages.audience, "/v1/messages")
        XCTAssertEqual(messages.scheme, "https")
        XCTAssertEqual(messages.port, 8443)

        let root = ModelGatewayCredentialRouting.scope(for: URL(string: "https://example.test")!)
        XCTAssertEqual(root.service, "example.test")
        XCTAssertEqual(root.audience, "/")
        XCTAssertEqual(root.scheme, "https")
        XCTAssertNil(root.port, "a default port must stay absent so the provider can apply the scheme default")

        let query = ModelGatewayCredentialRouting.scope(
            for: URL(string: "https://example.test/v1/messages?trace=1#fragment")!)
        XCTAssertEqual(query.audience, "/v1/messages")

        let noHost = ModelGatewayCredentialRouting.scope(for: URL(string: "file:///tmp/request")!)
        XCTAssertEqual(noHost.service, "")
        XCTAssertEqual(noHost.audience, "/tmp/request")
        XCTAssertEqual(noHost.scheme, "file")
        XCTAssertNil(noHost.port)
    }

    func testNormalizedPathCollapsesSeparatorsAndResolvesDotSegments() {
        XCTAssertEqual(ModelGatewayCredentialRouting.normalizedPath(""), "/")
        XCTAssertEqual(ModelGatewayCredentialRouting.normalizedPath("v1/messages"), "/v1/messages")
        XCTAssertEqual(ModelGatewayCredentialRouting.normalizedPath("/v1//messages/"), "/v1/messages")
        XCTAssertEqual(ModelGatewayCredentialRouting.normalizedPath("/v1/tools/./search/../search/"),
                       "/v1/tools/search")
        XCTAssertEqual(ModelGatewayCredentialRouting.normalizedPath("/../.."), "/")
    }

    func testRealGatewayRequestsCarryThePathAudienceAndTheMatchingKey() async throws {
        let server = try MockUpstreamServer { _ in
            .full(status: 200, headers: ["content-type": "application/json"], body: Data("{}".utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }

        let root = try makeTemporaryDirectory()
        let log = try ResponseLog(root: root, quotaBytes: 1_000_000)
        let provider = RecordingGatewayCredentialProvider(
            searchPaths: ["/v1/tools/search", "/v1/tools/fetch"])
        let configuration = ModelGatewayConfiguration(
            allowedUpstreamHosts: ["127.0.0.1:\(server.port)"],
            backoff: ModelGatewayBackoffPolicy(initialDelay: 0,
                                               multiplier: 1,
                                               maximumDelay: 0,
                                               jitterFraction: 0,
                                               maximumAttempts: 1),
            upstreamRequestTimeout: 5)
        let gateway = ModelGateway(configuration: configuration,
                                   credentialProvider: provider,
                                   responseLog: log,
                                   clock: ManualGatewayClock())
        addTeardownBlock {
            await gateway.shutdown()
            try? FileManager.default.removeItem(at: root)
        }

        let paths = ["/v1/messages", "/v1/tools/search", "/v1/tools/fetch", "/v1/tools/unknown"]
        for path in paths {
            let request = GatewayRequest(
                method: "POST",
                url: URL(string: "http://127.0.0.1:\(server.port)\(path)")!,
                headers: ["content-type": "application/json"],
                body: Data(#"{"model":"m"}"#.utf8))
            let response = try await collectGatewayResponse(gateway.handle(request))
            XCTAssertEqual(response.status, 200, path)
        }

        let received = server.requests
        XCTAssertEqual(received.map(\.path), paths)
        XCTAssertEqual(provider.scopes.map { $0.audience ?? "" }, paths)
        XCTAssertEqual(Set(provider.scopes.map(\.service)), Set(["127.0.0.1"]))

        XCTAssertEqual(received[0].headers["x-api-key"], "model-key")
        XCTAssertNil(received[0].headers["authorization"])

        for index in [1, 2] {
            XCTAssertEqual(received[index].headers["authorization"], "Bearer search-key",
                           "\(paths[index]) must use the independent search key")
            XCTAssertNil(received[index].headers["x-api-key"],
                         "\(paths[index]) must not receive the model key")
        }

        XCTAssertEqual(received[3].headers["x-api-key"], "model-key",
                       "an unknown path must not receive the search key")
        XCTAssertNil(received[3].headers["authorization"])
    }
}

private final class RecordingGatewayCredentialProvider: CredentialProvider, @unchecked Sendable {
    private let searchPaths: Set<String>
    private let lock = NSLock()
    private var storedScopes: [CredentialScope] = []

    init(searchPaths: Set<String>) {
        self.searchPaths = searchPaths
    }

    var scopes: [CredentialScope] {
        lock.lock()
        defer { lock.unlock() }
        return storedScopes
    }

    func credential(for scope: CredentialScope) async throws -> Credential {
        lock.lock()
        storedScopes.append(scope)
        lock.unlock()
        guard scope.service == "127.0.0.1" else {
            throw ProviderError.unauthorized("unknown host \(scope.service)")
        }
        if let audience = scope.audience, searchPaths.contains(audience) {
            return Credential(kind: .bearer, value: "search-key")
        }
        return Credential(kind: .apiKey(header: "x-api-key"), value: "model-key")
    }

    func invalidate(_ credential: Credential, for scope: CredentialScope) async {}
}
