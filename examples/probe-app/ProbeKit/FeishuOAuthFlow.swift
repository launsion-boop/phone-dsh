// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Security

/// Everything the Feishu connector can fail with across the native session,
/// callback validation and broker exchange. Raw transport or Feishu strings are
/// never carried in these cases; the connector page maps them to fixed copy.
public enum FeishuOAuthError: Error, Equatable, Sendable {
    case cancelled
    case randomUnavailable
    case invalidConfiguration
    case notConfigured
    case invalidState
    case invalidCode
    case invalidVerifier
    case invalidCallback
    case stateMismatch
    case invalidToken
    case invalidRequest
    case authorizationFailed
    case invalidResponse
    case serviceUnavailable
}

/// The immutable, validated connection inputs. The App ID is public; the App
/// Secret stays on the platform broker. Values come from two Info.plist entries
/// that Xcode fills from the documented build settings, or are injected by
/// tests. Any missing or malformed value disables the whole configuration so
/// the page shows the unconfigured state.
public struct FeishuOAuthConfiguration: Equatable, Sendable {
    public enum Keys {
        public static let origin = "PDSH_FEISHU_OAUTH_ORIGIN"
        public static let appID = "PDSH_FEISHU_APP_ID"
    }

    public static let callbackScheme = "phonedsh-feishu"
    public static let callbackHost = "oauth"
    public static let callbackPath = "/callback"

    /// Feishu's authorization page. The token and revoke endpoints are only
    /// reached by the broker, never by this client.
    public static let authorizationEndpoint = URL(
        string: "https://accounts.feishu.cn/open-apis/authen/v1/authorize"
    )!

    /// `drive:drive:readonly` reads the user's own cloud space listing;
    /// `offline_access` makes Feishu issue a refresh token so the connector can
    /// renew an eight hour access token without a new browser round trip.
    public static let scopes = ["drive:drive:readonly", "offline_access"]

    public let origin: URL
    public let appID: String
    public let redirectURI: URL
    public let exchangeEndpoint: URL
    public let refreshEndpoint: URL
    public let revokeEndpoint: URL

    public init?(origin rawOrigin: String, appID rawAppID: String) {
        let originString = rawOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
        let appID = rawAppID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let origin = Self.normalizedHTTPSOrigin(originString),
              Self.isValidAppID(appID),
              let redirectURI = Self.endpoint(origin: origin, path: "/v1/feishu/oauth/callback"),
              let exchangeEndpoint = Self.endpoint(origin: origin, path: "/v1/feishu/oauth/exchange"),
              let refreshEndpoint = Self.endpoint(origin: origin, path: "/v1/feishu/oauth/refresh"),
              let revokeEndpoint = Self.endpoint(origin: origin, path: "/v1/feishu/oauth/revoke")
        else { return nil }

        self.origin = origin
        self.appID = appID
        self.redirectURI = redirectURI
        self.exchangeEndpoint = exchangeEndpoint
        self.refreshEndpoint = refreshEndpoint
        self.revokeEndpoint = revokeEndpoint
    }

    public init?(infoDictionary: [String: Any]?) {
        guard let infoDictionary,
              let origin = infoDictionary[Keys.origin] as? String,
              let appID = infoDictionary[Keys.appID] as? String
        else { return nil }
        self.init(origin: origin, appID: appID)
    }

    /// The Feishu authorization page. Only the App ID, the broker callback and
    /// the S256 challenge travel here; the verifier never enters a URL.
    public func authorizationURL(state: String, codeChallenge: String) -> URL? {
        guard FeishuOAuthPKCE.isValidState(state),
              FeishuOAuthPKCE.isValidChallenge(codeChallenge)
        else { return nil }

        var components = URLComponents(
            url: Self.authorizationEndpoint, resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: appID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return components?.url
    }

    public func appLink(for authorizationURL: URL) -> URL? {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        guard let encodedURL = authorizationURL.absoluteString
            .addingPercentEncoding(withAllowedCharacters: unreserved)
        else { return nil }

        var link = URLComponents()
        link.scheme = "https"
        link.host = "applink.feishu.cn"
        link.path = "/client/web_url/open"
        link.percentEncodedQueryItems = [
            URLQueryItem(name: "mode", value: "window"),
            URLQueryItem(name: "url", value: encodedURL),
        ]
        return link.url
    }

    /// Feishu App IDs look like `cli_a5ca35a685b0x26e`: an `cli_` prefix and
    /// then letters and digits. The shape is checked before any request.
    public static func isValidAppID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (6...64).contains(bytes.count), value.hasPrefix("cli_") else { return false }
        return bytes.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte)
                || (97...122).contains(byte) || byte == 95
        }
    }

    static func normalizedHTTPSOrigin(_ raw: String) -> URL? {
        guard !raw.isEmpty,
              raw.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let parsed = URLComponents(string: raw)
        else { return nil }

        guard parsed.scheme?.lowercased() == "https",
              let host = parsed.host, !host.isEmpty,
              parsed.user == nil,
              parsed.password == nil,
              parsed.port == nil || parsed.port == 443,
              parsed.query == nil,
              parsed.fragment == nil,
              parsed.path.isEmpty || parsed.path == "/"
        else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        return components.url
    }

    static func endpoint(origin: URL, path: String) -> URL? {
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

/// The fixed native callback accepted from `ASWebAuthenticationSession`.
public enum FeishuOAuthCallback: Equatable, Sendable {
    case code(String)
    case accessDenied
}

/// Strict validation of the broker's native callback. It receives exactly one
/// state plus either one code or the normalized `access_denied` marker; every
/// duplicate, conflicting, unknown or token-bearing parameter is rejected.
public enum FeishuOAuthCallbackValidator {
    public static func validate(
        _ url: URL, expectedState: String
    ) throws -> FeishuOAuthCallback {
        guard FeishuOAuthPKCE.isValidState(expectedState) else {
            throw FeishuOAuthError.invalidState
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == FeishuOAuthConfiguration.callbackScheme,
              components.host?.lowercased() == FeishuOAuthConfiguration.callbackHost,
              components.percentEncodedPath == FeishuOAuthConfiguration.callbackPath,
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              let items = components.queryItems,
              items.count == 2
        else { throw FeishuOAuthError.invalidCallback }

        var values: [String: String] = [:]
        for item in items {
            guard item.name == "state" || item.name == "code" || item.name == "error",
                  values[item.name] == nil,
                  let value = item.value, !value.isEmpty
            else { throw FeishuOAuthError.invalidCallback }
            values[item.name] = value
        }

        guard let state = values["state"] else { throw FeishuOAuthError.invalidCallback }
        guard state == expectedState else { throw FeishuOAuthError.stateMismatch }

        if let code = values["code"], values["error"] == nil {
            guard FeishuOAuthPKCE.isValidCode(code) else {
                throw FeishuOAuthError.invalidCallback
            }
            return .code(code)
        }
        if let error = values["error"], values["code"] == nil {
            guard error == "access_denied" else { throw FeishuOAuthError.invalidCallback }
            return .accessDenied
        }
        throw FeishuOAuthError.invalidCallback
    }
}

/// The state, RFC 7636 verifier and S256 challenge for one authorization
/// attempt. A fresh attempt is generated for every connect tap.
public struct FeishuOAuthAttempt: Equatable, Sendable {
    public let state: String
    public let verifier: String
    public let challenge: String

    public init(state: String, verifier: String) throws {
        guard FeishuOAuthPKCE.isValidState(state) else { throw FeishuOAuthError.invalidState }
        guard FeishuOAuthPKCE.isValidVerifier(verifier) else {
            throw FeishuOAuthError.invalidVerifier
        }
        self.state = state
        self.verifier = verifier
        self.challenge = try FeishuOAuthPKCE.codeChallenge(for: verifier)
    }
}

public enum FeishuOAuthPKCE {
    /// 32 random bytes encode to exactly 43 base64url characters, which is the
    /// shape both the state and the verifier use.
    public static func makeAttempt() throws -> FeishuOAuthAttempt {
        try makeAttempt(randomBytes: FeishuOAuthSecureRandom.bytes)
    }

    public static func makeAttempt(
        randomBytes: (Int) throws -> Data
    ) throws -> FeishuOAuthAttempt {
        let state = try randomURLSafeString(randomBytes: randomBytes)
        let verifier = try randomURLSafeString(randomBytes: randomBytes)
        return try FeishuOAuthAttempt(state: state, verifier: verifier)
    }

    public static func codeChallenge(for verifier: String) throws -> String {
        guard isValidVerifier(verifier) else { throw FeishuOAuthError.invalidVerifier }
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func isValidState(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 43 && bytes.allSatisfy(isBase64URLByte)
    }

    public static func isValidChallenge(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 43 && bytes.allSatisfy(isBase64URLByte)
    }

    /// Feishu codes are letters, digits, underscore or hyphen; the platform
    /// reserves 64 characters, so anything up to 512 is accepted.
    public static func isValidCode(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...512).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte)
                || (97...122).contains(byte) || byte == 95 || byte == 45
        }
    }

    /// 43 to 128 RFC 7636 unreserved characters.
    public static func isValidVerifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (43...128).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte)
                || (97...122).contains(byte) || byte == 45 || byte == 46
                || byte == 95 || byte == 126
        }
    }

    private static func randomURLSafeString(
        randomBytes: (Int) throws -> Data
    ) throws -> String {
        let data = try randomBytes(32)
        guard data.count == 32 else { throw FeishuOAuthError.randomUnavailable }
        return base64URL(data)
    }

    private static func isBase64URLByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte)
            || (97...122).contains(byte) || byte == 45 || byte == 95
    }
}

public enum FeishuOAuthSecureRandom {
    public static func bytes(_ count: Int) throws -> Data {
        guard count > 0, count <= 1024 else { throw FeishuOAuthError.randomUnavailable }
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        guard status == errSecSuccess else { throw FeishuOAuthError.randomUnavailable }
        return data
    }
}

public struct FeishuOAuthToken: Equatable, Sendable {
    public let accessToken: String
    public let expiresIn: Int
    public let refreshToken: String?
    public let refreshExpiresIn: Int?
    public let scope: String?

    public init(
        accessToken: String,
        expiresIn: Int,
        refreshToken: String? = nil,
        refreshExpiresIn: Int? = nil,
        scope: String? = nil
    ) {
        self.accessToken = accessToken
        self.expiresIn = expiresIn
        self.refreshToken = refreshToken
        self.refreshExpiresIn = refreshExpiresIn
        self.scope = scope
    }
}

/// The broker exchange/refresh/revoke client. The default session carries no
/// cookies, cache or credentials, refuses redirects and times out after ten
/// seconds, matching the platform broker's own upstream budget.
public struct FeishuOAuthFlow: Sendable {
    public let configuration: FeishuOAuthConfiguration
    private let session: URLSession

    public init(configuration: FeishuOAuthConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        if let session {
            self.session = session
            return
        }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.httpCookieAcceptPolicy = .never
        sessionConfiguration.urlCredentialStorage = nil
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.timeoutIntervalForRequest = 10
        sessionConfiguration.timeoutIntervalForResource = 10
        self.session = URLSession(
            configuration: sessionConfiguration,
            delegate: FeishuOAuthNoRedirects(),
            delegateQueue: nil
        )
    }

    public func exchange(code: String, codeVerifier: String) async throws -> FeishuOAuthToken {
        guard FeishuOAuthPKCE.isValidCode(code) else { throw FeishuOAuthError.invalidCode }
        guard FeishuOAuthPKCE.isValidVerifier(codeVerifier) else {
            throw FeishuOAuthError.invalidVerifier
        }
        let body = try encode(ExchangeRequest(code: code, codeVerifier: codeVerifier))
        let data = try await post(configuration.exchangeEndpoint, body: body)
        return try token(from: data)
    }

    public func refresh(refreshToken: String) async throws -> FeishuOAuthToken {
        guard FeishuConnectorAPI.isValidToken(refreshToken) else {
            throw FeishuOAuthError.invalidToken
        }
        let body = try encode(RefreshRequest(refreshToken: refreshToken))
        let data = try await post(configuration.refreshEndpoint, body: body)
        return try token(from: data)
    }

    public func revoke(token: String) async throws {
        guard FeishuConnectorAPI.isValidToken(token) else { throw FeishuOAuthError.invalidToken }
        let body = try encode(RevokeRequest(token: token))
        let (_, response) = try await send(configuration.revokeEndpoint, body: body)
        switch response.statusCode {
        case 204:
            return
        case 400:
            throw FeishuOAuthError.invalidRequest
        case 401:
            throw FeishuOAuthError.authorizationFailed
        case 503:
            throw FeishuOAuthError.notConfigured
        default:
            throw FeishuOAuthError.serviceUnavailable
        }
    }

    private func token(from data: Data) throws -> FeishuOAuthToken {
        let decoded: TokenResponse
        do {
            decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw FeishuOAuthError.invalidResponse
        }
        guard FeishuConnectorAPI.isValidToken(decoded.accessToken),
              decoded.expiresIn > 0
        else { throw FeishuOAuthError.invalidToken }
        return FeishuOAuthToken(
            accessToken: decoded.accessToken,
            expiresIn: decoded.expiresIn,
            refreshToken: decoded.refreshToken.flatMap {
                FeishuConnectorAPI.isValidToken($0) ? $0 : nil
            },
            refreshExpiresIn: decoded.refreshExpiresIn,
            scope: decoded.scope
        )
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw FeishuOAuthError.invalidResponse
        }
    }

    private func post(_ url: URL, body: Data) async throws -> Data {
        let (data, response) = try await send(url, body: body)
        switch response.statusCode {
        case 200:
            return data
        case 400:
            throw FeishuOAuthError.invalidRequest
        case 401:
            throw FeishuOAuthError.authorizationFailed
        case 502:
            throw FeishuOAuthError.serviceUnavailable
        case 503:
            throw FeishuOAuthError.notConfigured
        default:
            throw FeishuOAuthError.serviceUnavailable
        }
    }

    private func send(_ url: URL, body: Data) async throws -> (Data, HTTPURLResponse) {
        // The broker caps app POST bodies at 4 KiB. The validated fields cannot
        // reach this limit, so this is a defensive assertion, not a fallback.
        guard body.count <= 4096 else { throw FeishuOAuthError.invalidRequest }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("phone-dsh", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw FeishuOAuthError.invalidResponse
            }
            return (data, http)
        } catch let error as FeishuOAuthError {
            throw error
        } catch is CancellationError {
            throw FeishuOAuthError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw FeishuOAuthError.cancelled
        } catch {
            throw FeishuOAuthError.serviceUnavailable
        }
    }

    private struct ExchangeRequest: Encodable {
        let code: String
        let codeVerifier: String

        enum CodingKeys: String, CodingKey {
            case code
            case codeVerifier = "code_verifier"
        }
    }

    private struct RefreshRequest: Encodable {
        let refreshToken: String

        enum CodingKeys: String, CodingKey {
            case refreshToken = "refresh_token"
        }
    }

    private struct RevokeRequest: Encodable {
        let token: String
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int
        let refreshToken: String?
        let refreshExpiresIn: Int?
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case refreshExpiresIn = "refresh_token_expires_in"
            case scope
        }
    }
}

private final class FeishuOAuthNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? { nil }
}
