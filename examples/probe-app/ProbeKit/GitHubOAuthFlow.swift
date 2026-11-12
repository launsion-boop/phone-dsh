// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Security

/// Everything the GitHub connector can fail with across the native session,
/// callback validation and broker exchange. Raw transport or broker strings are
/// never carried in these cases; the connector page maps them to fixed copy.
public enum GitHubOAuthError: Error, Equatable, Sendable {
    case cancelled
    case randomUnavailable
    case invalidConfiguration
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

/// The immutable, validated connection inputs. Values are read from the three
/// Info.plist entries that Xcode fills from the documented build settings, or
/// injected directly by tests. Any missing or malformed value makes the whole
/// configuration unavailable so the page can show the unconfigured state.
public struct GitHubOAuthConfiguration: Equatable, Sendable {
    public enum Keys {
        public static let origin = "PDSH_GITHUB_OAUTH_ORIGIN"
        public static let clientID = "PDSH_GITHUB_OAUTH_CLIENT_ID"
        public static let appSlug = "PDSH_GITHUB_APP_SLUG"
    }

    public static let callbackScheme = "phonedsh-github"
    public static let callbackHost = "oauth"
    public static let callbackPath = "/callback"

    /// GitHub's page for reviewing and revoking user authorization of GitHub
    /// Apps. It is the safe fallback when broker-side revocation fails.
    public static let authorizedAppSettingsURL = URL(
        string: "https://github.com/settings/apps/authorizations"
    )!

    public let origin: URL
    public let clientID: String
    public let appSlug: String
    public let redirectURI: URL
    public let exchangeEndpoint: URL
    public let revokeEndpoint: URL

    public init?(origin rawOrigin: String, clientID rawClientID: String, appSlug rawAppSlug: String) {
        let originString = rawOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientID = rawClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let appSlug = rawAppSlug.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let origin = Self.normalizedHTTPSOrigin(originString),
              Self.isValidClientID(clientID),
              Self.isValidAppSlug(appSlug),
              let redirectURI = Self.endpoint(origin: origin, path: "/v1/github/oauth/callback"),
              let exchangeEndpoint = Self.endpoint(origin: origin, path: "/v1/github/oauth/exchange"),
              let revokeEndpoint = Self.endpoint(origin: origin, path: "/v1/github/oauth/revoke")
        else { return nil }

        self.origin = origin
        self.clientID = clientID
        self.appSlug = appSlug
        self.redirectURI = redirectURI
        self.exchangeEndpoint = exchangeEndpoint
        self.revokeEndpoint = revokeEndpoint
    }

    public init?(infoDictionary: [String: Any]?) {
        guard let infoDictionary,
              let origin = infoDictionary[Keys.origin] as? String,
              let clientID = infoDictionary[Keys.clientID] as? String,
              let appSlug = infoDictionary[Keys.appSlug] as? String
        else { return nil }
        self.init(origin: origin, clientID: clientID, appSlug: appSlug)
    }

    /// The GitHub authorization page. The verifier never appears here: only the
    /// S256 challenge and the broker callback URI are sent to GitHub.
    public func authorizationURL(state: String, codeChallenge: String) -> URL? {
        guard GitHubOAuthPKCE.isValidState(state),
              GitHubOAuthPKCE.isValidChallenge(codeChallenge)
        else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/login/oauth/authorize"
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url
    }

    /// Fixed by the contract: the configured slug selects the GitHub App, and
    /// the user chooses repositories in GitHub's own installation page.
    public var installationURL: URL {
        URL(string: "https://github.com/apps/\(appSlug)/installations/new")!
    }

    private static func normalizedHTTPSOrigin(_ raw: String) -> URL? {
        guard !raw.isEmpty,
              raw.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let parsed = URLComponents(string: raw)
        else { return nil }

        guard parsed.scheme?.lowercased() == "https",
              let host = parsed.host, !host.isEmpty,
              parsed.user == nil,
              parsed.password == nil,
              parsed.percentEncodedPath.isEmpty || parsed.percentEncodedPath == "/",
              parsed.query == nil,
              parsed.fragment == nil
        else { return nil }

        if let port = parsed.port, !(1...65535).contains(port) { return nil }

        var components = parsed
        components.scheme = "https"
        components.host = host.lowercased()
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func endpoint(origin: URL, path: String) -> URL? {
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func isValidClientID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...128).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            isASCIIAlphaNumeric(byte) || byte == 45 || byte == 46 || byte == 95
        }
    }

    private static func isValidAppSlug(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...100).contains(bytes.count),
              bytes.first != 45,
              bytes.last != 45
        else { return false }
        return bytes.allSatisfy { isASCIIAlphaNumeric($0) || $0 == 45 }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
}

/// The fixed native callback accepted from `ASWebAuthenticationSession`.
public enum GitHubOAuthCallback: Equatable, Sendable {
    case code(String)
    case accessDenied
}

/// Strict validation of the broker's native callback. It receives exactly one
/// state plus either one code or the normalized `access_denied` marker; every
/// duplicate, conflicting, unknown or token-bearing parameter is rejected.
public enum GitHubOAuthCallbackValidator {
    public static func validate(
        _ url: URL, expectedState: String
    ) throws -> GitHubOAuthCallback {
        guard GitHubOAuthPKCE.isValidState(expectedState) else {
            throw GitHubOAuthError.invalidState
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == GitHubOAuthConfiguration.callbackScheme,
              components.host?.lowercased() == GitHubOAuthConfiguration.callbackHost,
              components.percentEncodedPath == GitHubOAuthConfiguration.callbackPath,
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              let items = components.queryItems,
              items.count == 2
        else { throw GitHubOAuthError.invalidCallback }

        var values: [String: String] = [:]
        for item in items {
            guard item.name == "state" || item.name == "code" || item.name == "error",
                  values[item.name] == nil,
                  let value = item.value, !value.isEmpty
            else { throw GitHubOAuthError.invalidCallback }
            values[item.name] = value
        }

        guard let state = values["state"] else { throw GitHubOAuthError.invalidCallback }
        guard state == expectedState else { throw GitHubOAuthError.stateMismatch }

        if let code = values["code"], values["error"] == nil {
            guard GitHubOAuthPKCE.isValidCode(code) else {
                throw GitHubOAuthError.invalidCallback
            }
            return .code(code)
        }
        if let error = values["error"], values["code"] == nil {
            guard error == "access_denied" else { throw GitHubOAuthError.invalidCallback }
            return .accessDenied
        }
        throw GitHubOAuthError.invalidCallback
    }
}

/// The state, RFC 7636 verifier and S256 challenge for one authorization
/// attempt. A fresh attempt is generated for every connect tap.
public struct GitHubOAuthAttempt: Equatable, Sendable {
    public let state: String
    public let verifier: String
    public let challenge: String

    public init(state: String, verifier: String) throws {
        guard GitHubOAuthPKCE.isValidState(state) else { throw GitHubOAuthError.invalidState }
        guard GitHubOAuthPKCE.isValidVerifier(verifier) else {
            throw GitHubOAuthError.invalidVerifier
        }
        self.state = state
        self.verifier = verifier
        self.challenge = try GitHubOAuthPKCE.codeChallenge(for: verifier)
    }
}

public enum GitHubOAuthPKCE {
    /// 32 random bytes encode to exactly 43 base64url characters, as required
    /// for both the state and the verifier.
    public static func makeAttempt() throws -> GitHubOAuthAttempt {
        try makeAttempt(randomBytes: GitHubOAuthSecureRandom.bytes)
    }

    public static func makeAttempt(
        randomBytes: (Int) throws -> Data
    ) throws -> GitHubOAuthAttempt {
        let state = try randomURLSafeString(randomBytes: randomBytes)
        let verifier = try randomURLSafeString(randomBytes: randomBytes)
        return try GitHubOAuthAttempt(state: state, verifier: verifier)
    }

    public static func codeChallenge(for verifier: String) throws -> String {
        guard isValidVerifier(verifier) else { throw GitHubOAuthError.invalidVerifier }
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

    /// 1 to 512 URL-safe ASCII characters: letters, digits, underscore, hyphen.
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
        guard data.count == 32 else { throw GitHubOAuthError.randomUnavailable }
        return base64URL(data)
    }

    private static func isBase64URLByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte)
            || (97...122).contains(byte) || byte == 45 || byte == 95
    }
}

public enum GitHubOAuthSecureRandom {
    public static func bytes(_ count: Int) throws -> Data {
        guard count > 0, count <= 1024 else { throw GitHubOAuthError.randomUnavailable }
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        guard status == errSecSuccess else { throw GitHubOAuthError.randomUnavailable }
        return data
    }
}

public struct GitHubOAuthToken: Equatable, Sendable {
    public let accessToken: String
    public let expiresIn: Int

    public init(accessToken: String, expiresIn: Int) {
        self.accessToken = accessToken
        self.expiresIn = expiresIn
    }
}

/// The broker exchange/revoke client. The default session carries no cookies,
/// cache or credentials, refuses redirects and times out after ten seconds.
public struct GitHubOAuthFlow: Sendable {
    public let configuration: GitHubOAuthConfiguration
    private let session: URLSession

    public init(configuration: GitHubOAuthConfiguration, session: URLSession? = nil) {
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
            delegate: GitHubOAuthNoRedirects(),
            delegateQueue: nil
        )
    }

    public func exchange(code: String, codeVerifier: String) async throws -> GitHubOAuthToken {
        guard GitHubOAuthPKCE.isValidCode(code) else { throw GitHubOAuthError.invalidCode }
        guard GitHubOAuthPKCE.isValidVerifier(codeVerifier) else {
            throw GitHubOAuthError.invalidVerifier
        }

        let body: Data
        do {
            body = try JSONEncoder().encode(
                ExchangeRequest(code: code, codeVerifier: codeVerifier)
            )
        } catch {
            throw GitHubOAuthError.invalidResponse
        }

        let (data, response) = try await post(configuration.exchangeEndpoint, body: body)
        switch response.statusCode {
        case 200:
            break
        case 400:
            throw GitHubOAuthError.invalidRequest
        case 401:
            throw GitHubOAuthError.authorizationFailed
        case 502:
            throw GitHubOAuthError.serviceUnavailable
        default:
            throw GitHubOAuthError.serviceUnavailable
        }

        let decoded: ExchangeResponse
        do {
            decoded = try JSONDecoder().decode(ExchangeResponse.self, from: data)
        } catch {
            throw GitHubOAuthError.invalidResponse
        }
        guard GitHubConnectorAPI.isValidToken(decoded.accessToken),
              decoded.expiresIn > 0
        else { throw GitHubOAuthError.invalidToken }
        return GitHubOAuthToken(
            accessToken: decoded.accessToken,
            expiresIn: decoded.expiresIn
        )
    }

    public func revoke(token: String) async throws {
        guard GitHubConnectorAPI.isValidToken(token) else { throw GitHubOAuthError.invalidToken }

        let body: Data
        do {
            body = try JSONEncoder().encode(RevokeRequest(accessToken: token))
        } catch {
            throw GitHubOAuthError.invalidResponse
        }

        let (_, response) = try await post(configuration.revokeEndpoint, body: body)
        switch response.statusCode {
        case 204:
            return
        case 400:
            throw GitHubOAuthError.invalidRequest
        case 401:
            throw GitHubOAuthError.authorizationFailed
        case 502:
            throw GitHubOAuthError.serviceUnavailable
        default:
            throw GitHubOAuthError.serviceUnavailable
        }
    }

    private func post(
        _ url: URL, body: Data
    ) async throws -> (Data, HTTPURLResponse) {
        // The broker caps app POST bodies at 4 KiB. The validated fields cannot
        // reach this limit, so this is a defensive assertion, not a fallback.
        guard body.count <= 4096 else { throw GitHubOAuthError.invalidRequest }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("phone-dsh", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw GitHubOAuthError.invalidResponse
            }
            return (data, http)
        } catch let error as GitHubOAuthError {
            throw error
        } catch is CancellationError {
            throw GitHubOAuthError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw GitHubOAuthError.cancelled
        } catch {
            throw GitHubOAuthError.serviceUnavailable
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

    private struct ExchangeResponse: Decodable {
        let accessToken: String
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
        }
    }

    private struct RevokeRequest: Encodable {
        let accessToken: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }
    }
}

private final class GitHubOAuthNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? { nil }
}
