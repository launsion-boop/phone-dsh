// SPDX-License-Identifier: MIT

import AuthenticationServices
import CryptoKit
import Foundation

public struct GmailAuthorizationRequest: Sendable, Equatable {
    public let url: URL
    public let state: String
    public let codeVerifier: String
    public let issuedAt: Date

    public init(url: URL, state: String, codeVerifier: String, issuedAt: Date) {
        self.url = url
        self.state = state
        self.codeVerifier = codeVerifier
        self.issuedAt = issuedAt
    }
}

public enum GmailOAuthFlow {
    public static func authorizationRequest(
        configuration: GmailOAuthConfiguration,
        randomData: @Sendable (Int) -> Data = { defaultRandomData(count: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws -> GmailAuthorizationRequest {
        guard !configuration.clientID.isEmpty,
              let scheme = configuration.callbackScheme, !scheme.isEmpty else { throw GmailError.notConfigured }
        let state = base64URL(randomData(32))
        let verifier = base64URL(randomData(32))
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        guard let url = components?.url else { throw GmailError.notConfigured }
        return GmailAuthorizationRequest(url: url, state: state, codeVerifier: verifier, issuedAt: now())
    }

    public static func authorizationCode(callback: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              items.first(where: { $0.name == "state" })?.value == expectedState else {
            throw GmailError.invalidState
        }
        if items.first(where: { $0.name == "error" }) != nil { throw GmailError.revoked }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw GmailError.invalidResponse
        }
        return code
    }

    public static func authorizationCode(callback: URL, request: GmailAuthorizationRequest,
                                         now: Date = Date(), maximumStateAge: TimeInterval = 600) throws -> String {
        let age = now.timeIntervalSince(request.issuedAt)
        guard age >= 0, age <= maximumStateAge else { throw GmailError.invalidState }
        return try authorizationCode(callback: callback, expectedState: request.state)
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func defaultRandomData(count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }
}

@MainActor
public protocol GmailOAuthSessionProviding: AnyObject {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

@MainActor
public final class GmailASWebAuthenticationSessionProvider: NSObject, GmailOAuthSessionProviding,
                                                            ASWebAuthenticationPresentationContextProviding {
    private var activeSession: ASWebAuthenticationSession?

    public override init() {}

    public func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] url, error in
                self?.activeSession = nil
                if let url {
                    continuation.resume(returning: url)
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: GmailError.transport)
                }
            }
            activeSession = session
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                activeSession = nil
                continuation.resume(throwing: GmailError.transport)
            }
        }
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? UIWindow()
    }
}

public actor GmailTokenManager {
    private let configuration: GmailOAuthConfiguration
    private let store: any GmailTokenStore
    private let transport: any GmailHTTPTransport
    private let now: @Sendable () -> Date
    private var refreshTask: Task<String, Error>?

    public init(configuration: GmailOAuthConfiguration, store: any GmailTokenStore,
                transport: any GmailHTTPTransport, now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.store = store
        self.transport = transport
        self.now = now
    }

    public func completeAuthorization(code: String, verifier: String) async throws {
        var fields = [
            "client_id": configuration.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": configuration.redirectURI.absoluteString,
        ]
        let response = try await tokenRequest(fields: &fields)
        let tokens = try Self.tokens(from: response, previousRefreshToken: nil, scopes: configuration.scopes, now: now())
        try store.write(tokens)
    }

    public func withValidAccessToken<T>(_ body: @Sendable (String) async throws -> T) async throws -> T {
        let snapshot = try store.read { $0 }
        if let snapshot, snapshot.expiresAt.timeIntervalSince(now()) > 60 {
            return try await body(snapshot.accessToken)
        }
        if let refreshTask { return try await body(refreshTask.value) }
        guard let snapshot, let refreshToken = snapshot.refreshToken else { throw GmailError.expired }
        let task = Task<String, Error> {
            var fields = [
                "client_id": self.configuration.clientID,
                "refresh_token": refreshToken,
                "grant_type": "refresh_token",
            ]
            do {
                let response = try await self.tokenRequest(fields: &fields)
                let tokens = try Self.tokens(from: response, previousRefreshToken: refreshToken,
                                             scopes: snapshot.scopes, now: self.now())
                try self.store.write(tokens)
                return tokens.accessToken
            } catch let error as GmailError {
                if error == .httpStatus(400) || error == .httpStatus(401) {
                    try? self.store.write(nil)
                    throw GmailError.expired
                }
                throw error
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await body(task.value)
    }

    public func revoke() async throws {
        let snapshot = try store.read { $0 }
        defer { try? store.write(nil) }
        guard let token = snapshot?.refreshToken ?? snapshot?.accessToken else { return }
        let body = "token=\(Self.formEncode(token))".data(using: .utf8)
        let request = GmailHTTPRequest(method: "POST", host: "oauth2.googleapis.com", path: "/revoke",
                                       headers: ["Content-Type": "application/x-www-form-urlencoded"], body: body)
        let response = try await transport.send(request)
        guard (200...299).contains(response.statusCode) else { throw GmailError.httpStatus(response.statusCode) }
    }

    private func tokenRequest(fields: inout [String: String]) async throws -> GmailHTTPResponse {
        let body = fields.keys.sorted().map { "\(Self.formEncode($0))=\(Self.formEncode(fields[$0] ?? ""))" }
            .joined(separator: "&").data(using: .utf8)
        let request = GmailHTTPRequest(method: "POST", host: "oauth2.googleapis.com", path: "/token",
                                       headers: ["Content-Type": "application/x-www-form-urlencoded"], body: body)
        let response = try await transport.send(request)
        guard (200...299).contains(response.statusCode) else { throw GmailError.httpStatus(response.statusCode) }
        return response
    }

    private static func tokens(from response: GmailHTTPResponse, previousRefreshToken: String?,
                               scopes: [String], now: Date) throws -> GmailTokenSet {
        struct Payload: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresIn: TimeInterval
            let scope: String?
        }
        let payload = try GmailJSON.decoder.decode(Payload.self, from: response.data)
        guard !payload.accessToken.isEmpty else { throw GmailError.invalidResponse }
        let tokenScopes = payload.scope?.split(separator: " ").map(String.init) ?? scopes
        return GmailTokenSet(accessToken: payload.accessToken,
                             refreshToken: payload.refreshToken ?? previousRefreshToken,
                             expiresAt: now.addingTimeInterval(payload.expiresIn), scopes: tokenScopes)
    }

    private static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
    }
}

@MainActor
public final class GmailOAuthCoordinator {
    private let configuration: GmailOAuthConfiguration?
    private let sessions: any GmailOAuthSessionProviding
    private let tokens: GmailTokenManager

    public init(configuration: GmailOAuthConfiguration?, sessions: any GmailOAuthSessionProviding,
                tokens: GmailTokenManager) {
        self.configuration = configuration
        self.sessions = sessions
        self.tokens = tokens
    }

    public func signIn() async throws {
        guard let configuration else { throw GmailError.notConfigured }
        let request = try GmailOAuthFlow.authorizationRequest(configuration: configuration)
        guard let scheme = configuration.callbackScheme else { throw GmailError.notConfigured }
        let callback = try await sessions.authenticate(url: request.url, callbackScheme: scheme)
        let code = try GmailOAuthFlow.authorizationCode(callback: callback, request: request)
        try await tokens.completeAuthorization(code: code, verifier: request.codeVerifier)
    }
}
