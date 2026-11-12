// SPDX-License-Identifier: MIT

import Foundation
import ProbeKit
import XCTest

final class GitHubOAuthTests: XCTestCase {
    func testAuthorizationUsesPKCEWithoutSendingVerifierInURL() throws {
        let fixture = try OAuthFixture.load()
        let configuration = try XCTUnwrap(oauthConfiguration)
        let attempt = try GitHubOAuthAttempt(state: fixture.state, verifier: fixture.codeVerifier)
        let url = try XCTUnwrap(configuration.authorizationURL(state: attempt.state, codeChallenge: attempt.challenge))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        XCTAssertEqual(components.host, "github.com")
        XCTAssertEqual(components.path, "/login/oauth/authorize")
        XCTAssertEqual(items["redirect_uri"], "https://auth.example.com/v1/github/oauth/callback")
        XCTAssertEqual(items["state"], fixture.state)
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["code_challenge"], "lCAUrwMZXJf8imEhoD4WYLiQJ6U4MloQHrpCbazX5Yc")
        XCTAssertNil(items["code_verifier"])
        XCTAssertNil(items["client_secret"])
    }

    func testCallbackChecksAttemptAndRejectsUnexpectedParameters() throws {
        let f = try OAuthFixture.load()
        let root = "phonedsh-github://oauth/callback?"
        let valid = try XCTUnwrap(URL(string: root + "state=\(f.state)&code=\(f.code)"))
        XCTAssertEqual(try GitHubOAuthCallbackValidator.validate(valid, expectedState: f.state), .code(f.code))
        XCTAssertThrowsError(try GitHubOAuthCallbackValidator.validate(valid, expectedState: f.wrongState)) {
            XCTAssertEqual($0 as? GitHubOAuthError, .stateMismatch)
        }
        let denied = try XCTUnwrap(URL(string: root + "state=\(f.state)&error=access_denied"))
        XCTAssertEqual(try GitHubOAuthCallbackValidator.validate(denied, expectedState: f.state), .accessDenied)
        for invalid in [
            root + "state=\(f.state)&code=\(f.code)&state=\(f.wrongState)",
            root + "state=\(f.state)&access_token=\(f.accessToken)",
            "phonedsh-github://unexpected/callback?state=\(f.state)&code=\(f.code)",
        ] {
            XCTAssertThrowsError(try GitHubOAuthCallbackValidator.validate(
                XCTUnwrap(URL(string: invalid)), expectedState: f.state
            ))
        }
    }

    func testExchangeAndRevokeUseTheBrokerAndRejectPersonalTokens() async throws {
        let f = try OAuthFixture.load()
        let configuration = try XCTUnwrap(oauthConfiguration)
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [OAuthFixtureProtocol.self]
        let flow = GitHubOAuthFlow(configuration: configuration, session: URLSession(configuration: session))

        let token = try await flow.exchange(code: f.code, codeVerifier: f.codeVerifier)
        XCTAssertEqual(token.accessToken, f.accessToken)
        XCTAssertEqual(token.expiresIn, f.expiresIn)
        try await flow.revoke(token: token.accessToken)

        do {
            _ = try await flow.exchange(code: f.code, codeVerifier: f.invalidVerifier)
            XCTFail("Expected invalid verifier.")
        } catch {
            XCTAssertEqual(error as? GitHubOAuthError, .invalidVerifier)
        }
        do {
            _ = try await flow.exchange(code: "bad-token", codeVerifier: f.codeVerifier)
            XCTFail("Expected a GitHub App token.")
        } catch {
            XCTAssertEqual(error as? GitHubOAuthError, .invalidToken)
        }
    }
}

private let oauthConfiguration = GitHubOAuthConfiguration(
    origin: "https://auth.example.com", clientID: "Iv1.fixture", appSlug: "phone-dsh-fixture"
)

private struct OAuthFixture: Decodable {
    let state: String
    let wrongState: String
    let code: String
    let codeVerifier: String
    let accessToken: String
    let expiresIn: Int
    let invalidVerifier: String
    let invalidToken: String

    static func load() throws -> Self {
        let url = try XCTUnwrap(Bundle(for: GitHubOAuthTests.self)
            .url(forResource: "github-oauth-cases.json", withExtension: nil))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Self.self, from: Data(contentsOf: url))
    }
}

private final class OAuthFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let fixture = try OAuthFixture.load()
            let url = try XCTUnwrap(request.url)
            guard url.scheme == "https", url.host == "auth.example.com", url.query == nil,
                  request.httpMethod == "POST",
                  request.value(forHTTPHeaderField: "Content-Type") == "application/json"
            else { throw URLError(.badServerResponse) }
            let body = try JSONSerialization.jsonObject(with: bodyData()) as? [String: String]
            let status: Int
            let payload: Data
            switch url.path {
            case "/v1/github/oauth/exchange":
                guard let code = body?["code"], code == fixture.code || code == "bad-token",
                      body == ["code": code, "code_verifier": fixture.codeVerifier]
                else { throw URLError(.badServerResponse) }
                status = 200
                payload = try JSONSerialization.data(withJSONObject: [
                    "access_token": code == fixture.code ? fixture.accessToken : fixture.invalidToken,
                    "expires_in": fixture.expiresIn,
                ])
            case "/v1/github/oauth/revoke":
                guard body == ["access_token": fixture.accessToken] else { throw URLError(.badServerResponse) }
                status = 204
                payload = Data()
            default:
                throw URLError(.badServerResponse)
            }
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !payload.isEmpty { client?.urlProtocol(self, didLoad: payload) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private func bodyData() throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { throw URLError(.badServerResponse) }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw URLError(.badServerResponse) }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
