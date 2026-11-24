// SPDX-License-Identifier: MIT
// Host-owned OAuth for hosted MCP connectors (docs/design-connectors-2026-11-24.md).

import Foundation
import XCTest
import PhoneDSHAgentCore
import PhoneDSHGateway
@testable import PhoneDSH

final class PhoneMCPOAuthTests: XCTestCase {
    private static let resource = URL(string: "https://docs.example.test/openapi/mcp")!
    private static let resourceMetadata = "https://docs.example.test/openapi/mcp/.well-known/oauth-protected-resource"

    /// Mirrors the shape Tencent Docs served on 2026-11-24: the resource
    /// metadata lives under the resource path (only reachable through the
    /// 401 header) and the authorization endpoint already has a query.
    private func tencentLikeServer() -> FakeOAuthHTTP {
        let http = FakeOAuthHTTP()
        http.route("POST", Self.resource.absoluteString) { _ in
            .init(status: 401, headers: ["WWW-Authenticate": #"Bearer resource_metadata="\#(Self.resourceMetadata)""#],
                  json: ["error": "invalid_token"])
        }
        http.route("GET", Self.resourceMetadata) { _ in
            .init(json: ["resource": Self.resource.absoluteString,
                         "authorization_servers": ["https://docs.example.test"]])
        }
        http.route("GET", "https://docs.example.test/.well-known/oauth-authorization-server") { _ in
            .init(json: [
                "issuer": "https://docs.example.test",
                "authorization_endpoint": "https://docs.example.test/scenario/open.html?authType=2",
                "token_endpoint": "https://docs.example.test/openapi/mcp/oauth/token",
                "registration_endpoint": "https://docs.example.test/openapi/mcp/oauth/register",
                "code_challenge_methods_supported": ["S256"],
                "token_endpoint_auth_methods_supported": ["none"],
            ])
        }
        http.route("POST", "https://docs.example.test/openapi/mcp/oauth/register") { request in
            let body = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            XCTAssertEqual(body?["token_endpoint_auth_method"] as? String, "none")
            XCTAssertEqual(body?["redirect_uris"] as? [String], ["phonedsh-oauth://callback/tencent-docs"])
            return .init(status: 201, json: ["client_id": "client-1"])
        }
        return http
    }

    func testDiscoveryFollowsTheResourceMetadataHeader() async throws {
        let client = PhoneMCPOAuthClient(http: tencentLikeServer())
        let metadata = try await client.discover(resource: Self.resource)
        XCTAssertEqual(metadata.issuer, "https://docs.example.test")
        XCTAssertEqual(metadata.tokenEndpoint.absoluteString, "https://docs.example.test/openapi/mcp/oauth/token")
        XCTAssertEqual(metadata.resource, Self.resource.absoluteString)
    }

    func testDiscoveryRefusesAServerWithoutS256() async {
        let http = tencentLikeServer()
        http.route("GET", "https://docs.example.test/.well-known/oauth-authorization-server") { _ in
            .init(json: ["issuer": "https://docs.example.test",
                         "authorization_endpoint": "https://docs.example.test/authorize",
                         "token_endpoint": "https://docs.example.test/token",
                         "code_challenge_methods_supported": ["plain"]])
        }
        do {
            _ = try await PhoneMCPOAuthClient(http: http).discover(resource: Self.resource)
            XCTFail("expected unsupportedServer")
        } catch {
            XCTAssertEqual(error as? PhoneMCPOAuthError, .unsupportedServer("PKCE S256"))
        }
    }

    func testAuthorizationURLKeepsExistingQueryAndCarriesPKCE() async throws {
        let client = PhoneMCPOAuthClient(http: tencentLikeServer())
        let metadata = try await client.discover(resource: Self.resource)
        let registration = try await client.register(
            metadata, redirectURI: PhoneMCPConnectorCatalog.redirectURI(for: PhoneMCPConnectorCatalog.tencentDocs), scope: "docs:read")
        let attempt = client.begin(registration, scope: "docs:read")
        let items = URLComponents(url: attempt.url, resolvingAgainstBaseURL: false)!.queryItems!
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(value("authType"), "2")
        XCTAssertEqual(value("client_id"), "client-1")
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("code_challenge"), PhoneMCPOAuthClient.challenge(for: attempt.verifier))
        XCTAssertEqual(value("state"), attempt.state)
        XCTAssertEqual(value("resource"), Self.resource.absoluteString)
        XCTAssertEqual(value("scope"), "docs:read")
    }

    func testFinishRejectsAForeignStateBeforeAnyTokenRequest() async throws {
        let http = tencentLikeServer()
        let client = PhoneMCPOAuthClient(http: http)
        let attempt = client.begin(Self.registration(), scope: nil)
        let callback = URL(string: "phonedsh-oauth://callback/tencent-docs?code=abc&state=forged")!
        do {
            _ = try await client.finish(attempt, callback: callback)
            XCTFail("expected stateMismatch")
        } catch {
            XCTAssertEqual(error as? PhoneMCPOAuthError, .stateMismatch)
        }
        XCTAssertFalse(http.requests.contains { $0.url?.path.hasSuffix("/oauth/token") == true })
    }

    func testFinishExchangesTheCodeWithTheVerifier() async throws {
        let http = tencentLikeServer()
        http.route("POST", "https://docs.example.test/openapi/mcp/oauth/token") { request in
            let form = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            XCTAssertTrue(form.contains("grant_type=authorization_code"))
            XCTAssertTrue(form.contains("code=the-code"))
            XCTAssertTrue(form.contains("code_verifier="))
            return .init(json: ["access_token": "at-1", "refresh_token": "rt-1",
                                "token_type": "Bearer", "expires_in": 3600])
        }
        let now = Date(timeIntervalSince1970: 1_000_000)
        let client = PhoneMCPOAuthClient(http: http, now: { now })
        let attempt = client.begin(Self.registration(), scope: nil)
        let callback = URL(string: "phonedsh-oauth://callback/tencent-docs?code=the-code&state=\(attempt.state)")!
        let record = try await client.finish(attempt, callback: callback)
        XCTAssertEqual(record.tokens.accessToken, "at-1")
        XCTAssertEqual(record.tokens.refreshToken, "rt-1")
        XCTAssertEqual(record.tokens.expiresAt, now.addingTimeInterval(3600))
    }

    func testRefreshKeepsThePreviousRefreshTokenWhenOmitted() async throws {
        let http = FakeOAuthHTTP()
        http.route("POST", "https://docs.example.test/openapi/mcp/oauth/token") { _ in
            .init(json: ["access_token": "at-2", "token_type": "bearer", "expires_in": 60])
        }
        let refreshed = try await PhoneMCPOAuthClient(http: http).refresh(Self.record(access: "at-1", refresh: "rt-1"))
        XCTAssertEqual(refreshed.tokens.accessToken, "at-2")
        XCTAssertEqual(refreshed.tokens.refreshToken, "rt-1")
    }

    func testRejectedRefreshRequiresReauthorization() async {
        let http = FakeOAuthHTTP()
        http.route("POST", "https://docs.example.test/openapi/mcp/oauth/token") { _ in
            .init(status: 400, json: ["error": "invalid_grant"])
        }
        do {
            _ = try await PhoneMCPOAuthClient(http: http).refresh(Self.record(access: "at-1", refresh: "rt-1"))
            XCTFail("expected reauthorizationRequired")
        } catch {
            XCTAssertEqual(error as? PhoneMCPOAuthError, .reauthorizationRequired)
        }
    }

    func testTokenSourceRefreshesNearExpiryOnceAndPersists() async throws {
        let http = FakeOAuthHTTP()
        http.route("POST", "https://docs.example.test/openapi/mcp/oauth/token") { _ in
            .init(json: ["access_token": "at-2", "refresh_token": "rt-2", "token_type": "Bearer", "expires_in": 3600])
        }
        let now = Date(timeIntervalSince1970: 2_000_000)
        let secrets = MemorySecretStore()
        let store = PhoneMCPOAuthStore(secretStore: secrets)
        var record = Self.record(access: "at-1", refresh: "rt-1")
        record.tokens.expiresAt = now.addingTimeInterval(10)
        let source = PhoneMCPOAuthTokenSource(connectorID: "tencent-docs", record: record, store: store,
                                              client: PhoneMCPOAuthClient(http: http, now: { now }),
                                              now: { now })
        async let first = source.headers()
        async let second = source.headers()
        let results = await [first, second]
        XCTAssertEqual(results, [["Authorization": "Bearer at-2"], ["Authorization": "Bearer at-2"]])
        XCTAssertEqual(http.requests.filter { $0.url?.path.hasSuffix("/oauth/token") == true }.count, 1)
        XCTAssertEqual(try store.record(for: "tencent-docs")?.tokens.refreshToken, "rt-2")
    }

    func testTokenSourceReportsReauthorizationAndStopsSendingTheToken() async {
        let http = FakeOAuthHTTP()
        http.route("POST", "https://docs.example.test/openapi/mcp/oauth/token") { _ in
            .init(status: 400, json: ["error": "invalid_grant"])
        }
        let flagged = Flag()
        let source = PhoneMCPOAuthTokenSource(connectorID: "tencent-docs",
                                              record: Self.record(access: "at-1", refresh: "rt-1"),
                                              store: PhoneMCPOAuthStore(secretStore: MemorySecretStore()),
                                              client: PhoneMCPOAuthClient(http: http),
                                              onReauthorizationRequired: { flagged.set() })
        await source.invalidate()
        let headers = await source.headers()
        XCTAssertNil(headers)
        XCTAssertTrue(flagged.value)
        let again = await source.headers()
        XCTAssertNil(again)
    }

    func testCredentialProviderUsesTheDynamicSourceOnlyForItsExactRoute() async throws {
        let policy = MCPEgressPolicy()
        try policy.grant(serverName: "tencent-docs", url: Self.resource, headers: [:])
        let source = StaticSource(headers: ["Authorization": "Bearer live"])
        policy.setDynamicCredentialSource(source, serverName: "tencent-docs")
        let base = StaticCredentialProvider([:])
        let provider = PhoneMCPCredentialProvider(policy: policy, base: base)

        let credential = try await provider.credential(
            for: ModelGatewayCredentialRouting.scope(for: Self.resource))
        XCTAssertEqual(credential.kind, .headers(["Authorization": "Bearer live"]))

        await provider.invalidate(credential, for: ModelGatewayCredentialRouting.scope(for: Self.resource))
        let invalidated = await source.invalidations
        XCTAssertEqual(invalidated, 1)

        policy.setDynamicCredentialSource(nil, serverName: "tencent-docs")
        let none = try await provider.credential(for: ModelGatewayCredentialRouting.scope(for: Self.resource))
        XCTAssertEqual(none.kind, .none)
    }

    func testStoreRoundTripsWithoutLeakingIntoOtherAccounts() throws {
        let secrets = MemorySecretStore()
        let store = PhoneMCPOAuthStore(secretStore: secrets)
        let record = Self.record(access: "at-1", refresh: "rt-1")
        try store.save(record, for: "tencent-docs")
        XCTAssertEqual(try store.record(for: "tencent-docs"), record)
        XCTAssertNil(try store.record(for: "linear"))
        try store.delete("tencent-docs")
        XCTAssertNil(try store.record(for: "tencent-docs"))
    }

    // MARK: Fixtures

    private static func registration() -> PhoneMCPOAuthRegistration {
        PhoneMCPOAuthRegistration(
            issuer: "https://docs.example.test",
            authorizationEndpoint: URL(string: "https://docs.example.test/scenario/open.html?authType=2")!,
            tokenEndpoint: URL(string: "https://docs.example.test/openapi/mcp/oauth/token")!,
            clientID: "client-1",
            redirectURI: PhoneMCPConnectorCatalog.redirectURI(for: PhoneMCPConnectorCatalog.tencentDocs),
            resource: resource.absoluteString)
    }

    private static func record(access: String, refresh: String?) -> PhoneMCPOAuthRecord {
        PhoneMCPOAuthRecord(registration: registration(),
                            tokens: PhoneMCPOAuthTokens(accessToken: access, refreshToken: refresh,
                                                        expiresAt: nil, scope: nil))
    }
}

// MARK: - Test doubles

private final class FakeOAuthHTTP: PhoneMCPOAuthHTTP, @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var json: [String: Any] = [:]
    }

    private let lock = NSLock()
    private var routes: [String: (URLRequest) -> Reply] = [:]
    private var recorded: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func route(_ method: String, _ url: String, _ reply: @escaping (URLRequest) -> Reply) {
        lock.lock(); defer { lock.unlock() }
        routes["\(method) \(url)"] = reply
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // Let concurrent callers interleave so single-flight is exercised.
        await Task.yield()
        let key = "\(request.httpMethod ?? "GET") \(request.url!.absoluteString)"
        lock.lock()
        recorded.append(request)
        let handler = routes[key]
        lock.unlock()
        let reply = handler?(request) ?? Reply(status: 404)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (try JSONSerialization.data(withJSONObject: reply.json), response)
    }
}

private final class MemorySecretStore: ModelProviderSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func secret(for reference: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[reference]
    }

    func setSecret(_ secret: String, for reference: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[reference] = secret
    }

    func deleteSecret(for reference: String) throws {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: reference)
    }
}

private actor StaticSource: MCPDynamicCredentialSource {
    let value: [String: String]
    var invalidations = 0
    init(headers: [String: String]) { value = headers }
    func headers() async -> [String: String]? { value }
    func invalidate() async { invalidations += 1 }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return raised }
    func set() { lock.lock(); raised = true; lock.unlock() }
}
