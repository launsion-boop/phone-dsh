// SPDX-License-Identifier: MIT
// phone-dsh host SDK — host-owned OAuth for hosted MCP connectors
// (docs/design-connectors-2026-11-24.md §5).
//
// The whole OAuth flow runs in the app process: discovery, dynamic client
// registration, PKCE, code exchange and refresh. Tokens live only in a
// dedicated Keychain service and in this process's memory. The Worker's
// phone-mcp row carries the `phone-host-injects-mcp-key` placeholder; the
// gateway drops it and asks `MCPEgressPolicy` for this source's header.

import CryptoKit
import Foundation

// MARK: - Catalog

/// One hosted MCP connector the app ships. The catalog is static: the Worker
/// can never add, rename or redirect a connector.
public struct PhoneMCPConnector: Identifiable, Equatable, Sendable {
    /// Stable id, also the Keychain account and the callback path segment.
    public let id: String
    /// phone-mcp `serverName`; kept equal to the upstream DSH plugin so the
    /// model sees the same `mcp__<server>__*` tool names.
    public let serverName: String
    /// Streamable HTTP MCP endpoint (the OAuth protected resource).
    public let url: URL
    /// Requested scope; `nil` lets the server choose.
    public let scope: String?
    /// Placeholder environment name for the phone-mcp row. It is never read:
    /// a host-managed header receives the placeholder instead.
    public let envName: String

    public init(id: String, serverName: String, url: URL, scope: String?, envName: String) {
        self.id = id
        self.serverName = serverName
        self.url = url
        self.scope = scope
        self.envName = envName
    }
}

public enum PhoneMCPConnectorCatalog {
    public static let tencentDocs = PhoneMCPConnector(
        id: "tencent-docs",
        serverName: "tencent-docs",
        url: URL(string: "https://docs.qq.com/openapi/mcp")!,
        scope: "docs:read docs:write",
        envName: "PDSH_CONNECTOR_TENCENT_DOCS")

    public static let all: [PhoneMCPConnector] = [tencentDocs]

    /// Server names that only the connector flow may grant.
    public static var reservedServerNames: Set<String> { Set(all.map(\.serverName)) }

    public static func connector(serverName: String) -> PhoneMCPConnector? {
        all.first { $0.serverName == serverName }
    }

    /// Custom scheme the app's authorization sheet intercepts. It is not
    /// registered in Info.plist: `ASWebAuthenticationSession` captures it.
    public static let callbackScheme = "phonedsh-oauth"

    public static func redirectURI(for connector: PhoneMCPConnector) -> URL {
        URL(string: "\(callbackScheme)://callback/\(connector.id)")!
    }
}

// MARK: - Errors

public enum PhoneMCPOAuthError: Error, LocalizedError, Equatable, Sendable {
    case insecureEndpoint(String)
    case discoveryFailed(String)
    case registrationFailed(String)
    case unsupportedServer(String)
    case callbackInvalid
    case stateMismatch
    case authorizationDenied(String)
    case tokenRequestFailed(String)
    /// The refresh token was rejected or is missing; the user must connect again.
    case reauthorizationRequired
    case store

    public var errorDescription: String? {
        switch self {
        case .insecureEndpoint: return "授权服务器必须使用 HTTPS。"
        case .discoveryFailed(let detail): return "无法读取授权服务器信息：\(detail)"
        case .registrationFailed(let detail): return "无法向授权服务器注册本应用：\(detail)"
        case .unsupportedServer(let detail): return "授权服务器不支持所需的授权方式：\(detail)"
        case .callbackInvalid: return "授权回调无效。"
        case .stateMismatch: return "授权回调与本次请求不匹配，已拒绝。"
        case .authorizationDenied(let detail): return "授权未完成：\(detail)"
        case .tokenRequestFailed(let detail): return "无法取得访问令牌：\(detail)"
        case .reauthorizationRequired: return "授权已失效，请重新连接。"
        case .store: return "无法读取或保存授权信息。请解锁设备后重试。"
        }
    }
}

// MARK: - Persisted record

public struct PhoneMCPOAuthTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var scope: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date?, scope: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }
}

/// Everything needed to refresh without rediscovery.
public struct PhoneMCPOAuthRegistration: Codable, Equatable, Sendable {
    public var issuer: String
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var clientID: String
    public var redirectURI: URL
    public var resource: String

    public init(issuer: String, authorizationEndpoint: URL, tokenEndpoint: URL,
                clientID: String, redirectURI: URL, resource: String) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.resource = resource
    }
}

public struct PhoneMCPOAuthRecord: Codable, Equatable, Sendable {
    public var version: Int
    public var registration: PhoneMCPOAuthRegistration
    public var tokens: PhoneMCPOAuthTokens

    public init(registration: PhoneMCPOAuthRegistration, tokens: PhoneMCPOAuthTokens) {
        self.version = 1
        self.registration = registration
        self.tokens = tokens
    }
}

/// Keychain-backed record store, one account per connector id. Uses a
/// dedicated service: never the model, search or static-MCP service.
public struct PhoneMCPOAuthStore: Sendable {
    public static let defaultKeychainService = "dev.phone-dsh.probe.connectors"
    private let secrets: any ModelProviderSecretStore

    public init(secretStore: any ModelProviderSecretStore =
                    KeychainModelProviderSecretStore(service: PhoneMCPOAuthStore.defaultKeychainService)) {
        self.secrets = secretStore
    }

    public func record(for connectorID: String) throws -> PhoneMCPOAuthRecord? {
        let raw: String?
        do { raw = try secrets.secret(for: Self.account(connectorID)) }
        catch { throw PhoneMCPOAuthError.store }
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        guard let record = try? JSONDecoder.oauth.decode(PhoneMCPOAuthRecord.self, from: data) else {
            throw PhoneMCPOAuthError.store
        }
        return record
    }

    public func save(_ record: PhoneMCPOAuthRecord, for connectorID: String) throws {
        guard let data = try? JSONEncoder.oauth.encode(record),
              let text = String(data: data, encoding: .utf8) else { throw PhoneMCPOAuthError.store }
        do { try secrets.setSecret(text, for: Self.account(connectorID)) }
        catch { throw PhoneMCPOAuthError.store }
    }

    public func delete(_ connectorID: String) throws {
        do { try secrets.deleteSecret(for: Self.account(connectorID)) }
        catch { throw PhoneMCPOAuthError.store }
    }

    static func account(_ connectorID: String) -> String { "connector.\(connectorID).v1" }
}

extension JSONEncoder {
    fileprivate static var oauth: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    fileprivate static var oauth: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

// MARK: - HTTP seam

/// One OAuth HTTP exchange. Production uses an ephemeral `URLSession` that
/// refuses redirects and carries no cookies; tests inject canned responses.
public protocol PhoneMCPOAuthHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public final class URLSessionPhoneMCPOAuthHTTP: NSObject, PhoneMCPOAuthHTTP, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    public override init() { super.init() }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PhoneMCPOAuthError.tokenRequestFailed("non-HTTP response")
        }
        return (data, http)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

// MARK: - Client

/// Authorization-server facts found by discovery.
public struct PhoneMCPOAuthServerMetadata: Equatable, Sendable {
    public var issuer: String
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var registrationEndpoint: URL?
    public var resource: String
}

/// One prepared browser authorization: open `url`, then pass the callback to
/// `PhoneMCPOAuthClient.finish`.
public struct PhoneMCPOAuthAttempt: Sendable {
    public let url: URL
    public let state: String
    public let verifier: String
    public let registration: PhoneMCPOAuthRegistration
}

public struct PhoneMCPOAuthClient: Sendable {
    private let http: any PhoneMCPOAuthHTTP
    private let clientName: String
    private let now: @Sendable () -> Date

    public init(http: any PhoneMCPOAuthHTTP = URLSessionPhoneMCPOAuthHTTP(),
                clientName: String = "Phone DSH",
                now: @escaping @Sendable () -> Date = Date.init) {
        self.http = http
        self.clientName = clientName
        self.now = now
    }

    // Discovery: MCP authorization spec — the 401 `WWW-Authenticate`
    // `resource_metadata` (RFC 9728) first, then the well-known fallback, then
    // RFC 8414 authorization-server metadata.
    public func discover(resource: URL) async throws -> PhoneMCPOAuthServerMetadata {
        try Self.requireHTTPS(resource)
        let resourceMetadataURL = try await resourceMetadataLocation(resource)
        let resourceDocument = try await getJSON(resourceMetadataURL, stage: "protected resource")
        guard let servers = resourceDocument["authorization_servers"] as? [String],
              let issuerText = servers.first, let issuer = URL(string: issuerText) else {
            throw PhoneMCPOAuthError.discoveryFailed("protected resource lists no authorization server")
        }
        try Self.requireHTTPS(issuer)
        let resourceID = (resourceDocument["resource"] as? String) ?? resource.absoluteString

        var serverDocument: [String: Any]?
        for candidate in Self.authorizationServerMetadataURLs(issuer: issuer) {
            if let document = try? await getJSON(candidate, stage: "authorization server") {
                serverDocument = document
                break
            }
        }
        guard let serverDocument,
              let authorizationText = serverDocument["authorization_endpoint"] as? String,
              let authorization = URL(string: authorizationText),
              let tokenText = serverDocument["token_endpoint"] as? String,
              let token = URL(string: tokenText) else {
            throw PhoneMCPOAuthError.discoveryFailed("authorization server metadata is incomplete")
        }
        try Self.requireHTTPS(authorization)
        try Self.requireHTTPS(token)
        let methods = serverDocument["code_challenge_methods_supported"] as? [String] ?? []
        guard methods.contains("S256") else {
            throw PhoneMCPOAuthError.unsupportedServer("PKCE S256")
        }
        let registration = (serverDocument["registration_endpoint"] as? String).flatMap(URL.init(string:))
        if let registration { try Self.requireHTTPS(registration) }
        return PhoneMCPOAuthServerMetadata(
            issuer: (serverDocument["issuer"] as? String) ?? issuer.absoluteString,
            authorizationEndpoint: authorization,
            tokenEndpoint: token,
            registrationEndpoint: registration,
            resource: resourceID)
    }

    /// Dynamic client registration (RFC 7591) as a public client.
    public func register(_ metadata: PhoneMCPOAuthServerMetadata,
                         redirectURI: URL,
                         scope: String?) async throws -> PhoneMCPOAuthRegistration {
        guard let endpoint = metadata.registrationEndpoint else {
            throw PhoneMCPOAuthError.unsupportedServer("dynamic client registration")
        }
        var body: [String: Any] = [
            "client_name": clientName,
            "redirect_uris": [redirectURI.absoluteString],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ]
        if let scope { body["scope"] = scope }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientID = document["client_id"] as? String, !clientID.isEmpty else {
            throw PhoneMCPOAuthError.registrationFailed(Self.errorSummary(data, status: response.statusCode))
        }
        return PhoneMCPOAuthRegistration(issuer: metadata.issuer,
                                         authorizationEndpoint: metadata.authorizationEndpoint,
                                         tokenEndpoint: metadata.tokenEndpoint,
                                         clientID: clientID,
                                         redirectURI: redirectURI,
                                         resource: metadata.resource)
    }

    /// Build the browser URL with PKCE S256, `state` and the RFC 8707 resource.
    /// Existing query items on the authorization endpoint are kept.
    public func begin(_ registration: PhoneMCPOAuthRegistration, scope: String?) -> PhoneMCPOAuthAttempt {
        let verifier = Self.randomURLSafe(byteCount: 32)
        let state = Self.randomURLSafe(byteCount: 32)
        var components = URLComponents(url: registration.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        items.append(contentsOf: [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: registration.clientID),
            URLQueryItem(name: "redirect_uri", value: registration.redirectURI.absoluteString),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: registration.resource),
        ])
        if let scope { items.append(URLQueryItem(name: "scope", value: scope)) }
        components.queryItems = items
        return PhoneMCPOAuthAttempt(url: components.url!, state: state,
                                    verifier: verifier, registration: registration)
    }

    /// Validate the callback and exchange its code.
    public func finish(_ attempt: PhoneMCPOAuthAttempt, callback: URL) async throws -> PhoneMCPOAuthRecord {
        guard callback.scheme == attempt.registration.redirectURI.scheme,
              callback.host == attempt.registration.redirectURI.host,
              callback.path == attempt.registration.redirectURI.path,
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
            throw PhoneMCPOAuthError.callbackInvalid
        }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let state = value("state"), Self.constantTimeEquals(state, attempt.state) else {
            throw PhoneMCPOAuthError.stateMismatch
        }
        if let error = value("error") {
            throw PhoneMCPOAuthError.authorizationDenied(value("error_description") ?? error)
        }
        if let iss = value("iss"), iss != attempt.registration.issuer {
            throw PhoneMCPOAuthError.callbackInvalid
        }
        guard let code = value("code"), !code.isEmpty else { throw PhoneMCPOAuthError.callbackInvalid }
        let tokens = try await tokenRequest(attempt.registration, form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": attempt.registration.redirectURI.absoluteString,
            "code_verifier": attempt.verifier,
            "client_id": attempt.registration.clientID,
            "resource": attempt.registration.resource,
        ], previousRefreshToken: nil)
        return PhoneMCPOAuthRecord(registration: attempt.registration, tokens: tokens)
    }

    /// Refresh; a rejected or missing refresh token means reauthorization.
    public func refresh(_ record: PhoneMCPOAuthRecord) async throws -> PhoneMCPOAuthRecord {
        guard let refreshToken = record.tokens.refreshToken, !refreshToken.isEmpty else {
            throw PhoneMCPOAuthError.reauthorizationRequired
        }
        let tokens = try await tokenRequest(record.registration, form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": record.registration.clientID,
            "resource": record.registration.resource,
        ], previousRefreshToken: refreshToken)
        var next = record
        next.tokens = tokens
        return next
    }

    // MARK: Internals

    private func tokenRequest(_ registration: PhoneMCPOAuthRegistration,
                              form: [String: String],
                              previousRefreshToken: String?) async throws -> PhoneMCPOAuthTokens {
        var request = URLRequest(url: registration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formEncode(form).data(using: .utf8)
        let (data, response) = try await http.send(request)
        let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(response.statusCode) else {
            if (document?["error"] as? String) == "invalid_grant", form["grant_type"] == "refresh_token" {
                throw PhoneMCPOAuthError.reauthorizationRequired
            }
            throw PhoneMCPOAuthError.tokenRequestFailed(Self.errorSummary(data, status: response.statusCode))
        }
        guard let document, let access = document["access_token"] as? String, !access.isEmpty else {
            throw PhoneMCPOAuthError.tokenRequestFailed("response has no access_token")
        }
        if let type = document["token_type"] as? String, type.lowercased() != "bearer" {
            throw PhoneMCPOAuthError.unsupportedServer("token_type \(type)")
        }
        let expiresIn = (document["expires_in"] as? NSNumber)?.doubleValue
            ?? (document["expires_in"] as? String).flatMap(Double.init)
        return PhoneMCPOAuthTokens(
            accessToken: access,
            // RFC 6749 §6: a refresh response may omit the refresh token, in
            // which case the previous one stays valid.
            refreshToken: (document["refresh_token"] as? String) ?? previousRefreshToken,
            expiresAt: expiresIn.map { now().addingTimeInterval($0) },
            scope: document["scope"] as? String)
    }

    private func resourceMetadataLocation(_ resource: URL) async throws -> URL {
        var probe = URLRequest(url: resource)
        probe.httpMethod = "POST"
        probe.setValue("application/json", forHTTPHeaderField: "Content-Type")
        probe.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        probe.httpBody = Data(#"{"jsonrpc":"2.0","id":0,"method":"ping"}"#.utf8)
        if let (_, response) = try? await http.send(probe),
           response.statusCode == 401,
           let header = response.value(forHTTPHeaderField: "WWW-Authenticate"),
           let location = Self.parameter("resource_metadata", in: header),
           let url = URL(string: location) {
            try Self.requireHTTPS(url)
            return url
        }
        // RFC 9728 §3.1: insert the well-known segment before the path.
        var components = URLComponents(url: resource, resolvingAgainstBaseURL: false)!
        let path = components.path == "/" ? "" : components.path
        components.path = "/.well-known/oauth-protected-resource" + path
        components.query = nil
        return components.url!
    }

    private func getJSON(_ url: URL, stage: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PhoneMCPOAuthError.discoveryFailed("\(stage) metadata HTTP \(response.statusCode)")
        }
        return document
    }

    static func authorizationServerMetadataURLs(issuer: URL) -> [URL] {
        var components = URLComponents(url: issuer, resolvingAgainstBaseURL: false)!
        let path = components.path == "/" ? "" : components.path
        components.query = nil
        var urls: [URL] = []
        for suffix in ["/.well-known/oauth-authorization-server", "/.well-known/openid-configuration"] {
            components.path = suffix + path
            urls.append(components.url!)
        }
        return urls
    }

    /// Extract one auth-param from a `WWW-Authenticate` value.
    static func parameter(_ name: String, in header: String) -> String? {
        let pattern = name + "=\""
        guard let start = header.range(of: pattern, options: .caseInsensitive) else { return nil }
        let rest = header[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    static func requireHTTPS(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
            throw PhoneMCPOAuthError.insecureEndpoint(url.absoluteString)
        }
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomURLSafe(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        var difference = UInt8(truncatingIfNeeded: left.count ^ right.count)
        for index in 0..<max(left.count, right.count) {
            difference |= (index < left.count ? left[index] : 0) ^ (index < right.count ? right[index] : 0)
        }
        return difference == 0
    }

    /// A short, value-free description of a failed response for the UI.
    static func errorSummary(_ data: Data, status: Int) -> String {
        if let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = document["error"] as? String {
            if let description = document["error_description"] as? String, !description.isEmpty {
                return "\(error)（\(description.prefix(120))）"
            }
            return error
        }
        return "HTTP \(status)"
    }
}

// MARK: - Live token source

/// Supplies one connector's `Authorization` header to the gateway, refreshing
/// before expiry. One refresh is in flight at a time; concurrent callers wait
/// for it. A rejected refresh drops the token and reports `needsReauth`.
public actor PhoneMCPOAuthTokenSource: MCPDynamicCredentialSource {
    public nonisolated let connectorID: String
    private let store: PhoneMCPOAuthStore
    private let client: PhoneMCPOAuthClient
    private let now: @Sendable () -> Date
    private let onReauthorizationRequired: @Sendable () -> Void
    private var record: PhoneMCPOAuthRecord?
    private var forceRefresh = false
    private var refreshing: Task<PhoneMCPOAuthRecord, Error>?

    /// Refresh this long before `expiresAt`.
    static let refreshSkew: TimeInterval = 60

    public init(connectorID: String,
                record: PhoneMCPOAuthRecord,
                store: PhoneMCPOAuthStore = PhoneMCPOAuthStore(),
                client: PhoneMCPOAuthClient = PhoneMCPOAuthClient(),
                now: @escaping @Sendable () -> Date = Date.init,
                onReauthorizationRequired: @escaping @Sendable () -> Void = {}) {
        self.connectorID = connectorID
        self.record = record
        self.store = store
        self.client = client
        self.now = now
        self.onReauthorizationRequired = onReauthorizationRequired
    }

    public func headers() async -> [String: String]? {
        guard let current = record else { return nil }
        let expiring = current.tokens.expiresAt.map { $0.timeIntervalSince(now()) < Self.refreshSkew } ?? false
        guard expiring || forceRefresh else {
            return ["Authorization": "Bearer \(current.tokens.accessToken)"]
        }
        do {
            let fresh = try await refreshOnce(current)
            return ["Authorization": "Bearer \(fresh.tokens.accessToken)"]
        } catch PhoneMCPOAuthError.reauthorizationRequired {
            record = nil
            onReauthorizationRequired()
            return nil
        } catch {
            // A transient failure keeps the old token: the server decides.
            return ["Authorization": "Bearer \(current.tokens.accessToken)"]
        }
    }

    public func invalidate() async {
        forceRefresh = true
    }

    private func refreshOnce(_ current: PhoneMCPOAuthRecord) async throws -> PhoneMCPOAuthRecord {
        if let refreshing { return try await refreshing.value }
        let client = self.client
        let task = Task { try await client.refresh(current) }
        refreshing = task
        defer { refreshing = nil }
        let fresh = try await task.value
        // Persist before use, so a crash cannot strand a rotated refresh token.
        try store.save(fresh, for: connectorID)
        record = fresh
        forceRefresh = false
        return fresh
    }
}
