// SPDX-License-Identifier: MIT

import Foundation
import ProbeKit
import XCTest

private let feishuState = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"
private let feishuVerifier = "TxYmzM4PHLBlqm5NtnCmwxMH8mFlRWl_ipie3O0aVzo"
private let feishuChallenge = "O0nS63zirsJkDT3cMvBt9oV_H48bhFpeAh4EyyILRWE"
private let feishuCode = "2Wd5g337vo5BZXUz-3W5KECsWUmIzJ_FJ1eFD59fD1AJIibIZljTu3OLK"
private let feishuTokenValue = "u-7f1bcd13fc57d46bac21793a18e560"
private let feishuRefreshValue = "ur-6d0b5a02cf9d4f0d9c1f5f8f0b0d6a11"

final class FeishuOAuthTests: XCTestCase {
    private var configuration: FeishuOAuthConfiguration {
        get throws {
            try XCTUnwrap(FeishuOAuthConfiguration(
                origin: "https://auth.example.com", appID: "cli_a5ca35a685b0x26e"
            ))
        }
    }

    func testConfigurationRequiresAnHTTPSOriginAndAFeishuAppID() {
        XCTAssertNotNil(FeishuOAuthConfiguration(origin: "https://auth.example.com", appID: "cli_a5ca35a685b0x26e"))
        XCTAssertNil(FeishuOAuthConfiguration(origin: "http://auth.example.com", appID: "cli_a5ca35a685b0x26e"))
        XCTAssertNil(FeishuOAuthConfiguration(origin: "https://auth.example.com/path", appID: "cli_a5ca35a685b0x26e"))
        XCTAssertNil(FeishuOAuthConfiguration(origin: "https://auth.example.com", appID: "not-an-app-id"))
        XCTAssertNil(FeishuOAuthConfiguration(origin: "", appID: ""))
        XCTAssertNil(FeishuOAuthConfiguration(infoDictionary: nil))
        XCTAssertNil(FeishuOAuthConfiguration(infoDictionary: [
            FeishuOAuthConfiguration.Keys.origin: "https://auth.example.com",
        ]))
    }

    func testAuthorizationUsesPKCEWithoutSendingTheVerifier() throws {
        let configuration = try configuration
        let attempt = try FeishuOAuthAttempt(state: feishuState, verifier: feishuVerifier)
        XCTAssertEqual(attempt.challenge, feishuChallenge)

        let url = try XCTUnwrap(configuration.authorizationURL(
            state: attempt.state, codeChallenge: attempt.challenge
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        XCTAssertEqual(components.host, "accounts.feishu.cn")
        XCTAssertEqual(components.path, "/open-apis/authen/v1/authorize")
        XCTAssertEqual(items["client_id"], "cli_a5ca35a685b0x26e")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["redirect_uri"], "https://auth.example.com/v1/feishu/oauth/callback")
        XCTAssertEqual(items["state"], feishuState)
        XCTAssertEqual(items["code_challenge"], feishuChallenge)
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["scope"], "drive:drive:readonly offline_access")
        XCTAssertEqual(items["prompt"], "consent")
        XCTAssertNil(items["code_verifier"])
        XCTAssertNil(items["client_secret"])
    }

    func testCallbackChecksStateAndRejectsUnexpectedParameters() throws {
        let root = "phonedsh-feishu://oauth/callback?"
        let valid = try XCTUnwrap(URL(string: root + "state=\(feishuState)&code=\(feishuCode)"))
        XCTAssertEqual(
            try FeishuOAuthCallbackValidator.validate(valid, expectedState: feishuState),
            .code(feishuCode)
        )
        XCTAssertEqual(
            try FeishuOAuthCallbackValidator.validate(
                XCTUnwrap(URL(string: root + "state=\(feishuState)&error=access_denied")),
                expectedState: feishuState
            ),
            .accessDenied
        )

        let wrongState = String(repeating: "a", count: 43)
        XCTAssertThrowsError(try FeishuOAuthCallbackValidator.validate(
            valid, expectedState: wrongState
        )) {
            XCTAssertEqual($0 as? FeishuOAuthError, .stateMismatch)
        }
        for invalid in [
            root + "state=\(feishuState)&code=\(feishuCode)&state=\(wrongState)",
            root + "state=\(feishuState)&code=\(feishuCode)&access_token=\(feishuTokenValue)",
            root + "state=\(feishuState)&code=bad code",
            root + "state=\(feishuState)&error=server_error",
            "phonedsh-feishu://unexpected/callback?state=\(feishuState)&code=\(feishuCode)",
        ] {
            XCTAssertThrowsError(try FeishuOAuthCallbackValidator.validate(
                XCTUnwrap(URL(string: invalid)), expectedState: feishuState
            ))
        }
    }

    func testExchangeRefreshAndRevokeUseTheBroker() async throws {
        let configuration = try configuration
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [FeishuOAuthFixtureProtocol.self]
        let flow = FeishuOAuthFlow(configuration: configuration, session: URLSession(configuration: session))

        let token = try await flow.exchange(code: feishuCode, codeVerifier: feishuVerifier)
        XCTAssertEqual(token.accessToken, feishuTokenValue)
        XCTAssertEqual(token.expiresIn, 7200)
        XCTAssertEqual(token.refreshToken, feishuRefreshValue)
        XCTAssertEqual(token.scope, "drive:drive:readonly offline_access")

        let refreshed = try await flow.refresh(refreshToken: feishuRefreshValue)
        XCTAssertEqual(refreshed.accessToken, feishuTokenValue)
        try await flow.revoke(token: feishuTokenValue)

        do {
            _ = try await flow.exchange(code: feishuCode, codeVerifier: String(repeating: "a", count: 12))
            XCTFail("Expected a short verifier to be rejected.")
        } catch {
            XCTAssertEqual(error as? FeishuOAuthError, .invalidVerifier)
        }
        do {
            _ = try await flow.exchange(code: "bad code", codeVerifier: feishuVerifier)
            XCTFail("Expected a malformed code to be rejected.")
        } catch {
            XCTAssertEqual(error as? FeishuOAuthError, .invalidCode)
        }
    }

    func testBrokerFailuresMapToFixedCases() async throws {
        for (path, expected) in [
            ("expired", FeishuOAuthError.authorizationFailed),
            ("missing", FeishuOAuthError.notConfigured),
            ("unavailable", FeishuOAuthError.serviceUnavailable),
        ] {
            let configuration = try XCTUnwrap(FeishuOAuthConfiguration(
                origin: "https://auth.example.com", appID: "cli_a5ca35a685b0x26e"
            ))
            let session = URLSessionConfiguration.ephemeral
            session.protocolClasses = [FeishuOAuthFixtureProtocol.self]
            let flow = FeishuOAuthFlow(configuration: configuration, session: URLSession(configuration: session))
            do {
                _ = try await flow.exchange(code: path, codeVerifier: feishuVerifier)
                XCTFail("Expected \(path) to fail.")
            } catch {
                XCTAssertEqual(error as? FeishuOAuthError, expected)
            }
        }
    }
}

private final class FeishuOAuthFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              url.scheme == "https", url.host == "auth.example.com",
              request.httpMethod == "POST",
              request.value(forHTTPHeaderField: "Content-Type") == "application/json"
        else { return send(400, Data(), url: request.url) }

        let body = bodyData()
        switch url.path {
        case "/v1/feishu/oauth/exchange":
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: String],
                  Set(object.keys) == ["code", "code_verifier"],
                  object["code_verifier"]?.count == 43
            else { return send(400, Data(), url: url) }
            switch object["code"] {
            case "expired":
                return send(401, Data(#"{"error":"authorization_failed"}"#.utf8), url: url)
            case "missing":
                return send(503, Data(#"{"error":"feishu_not_configured"}"#.utf8), url: url)
            case "unavailable":
                return send(502, Data(#"{"error":"feishu_unavailable"}"#.utf8), url: url)
            default:
                return send(200, tokenPayload, url: url)
            }
        case "/v1/feishu/oauth/refresh":
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: String],
                  Set(object.keys) == ["refresh_token"]
            else { return send(400, Data(), url: url) }
            return send(200, tokenPayload, url: url)
        case "/v1/feishu/oauth/revoke":
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: String],
                  Set(object.keys) == ["token"]
            else { return send(400, Data(), url: url) }
            return send(204, Data(), url: url)
        default:
            return send(404, Data(), url: url)
        }
    }

    override func stopLoading() {}

    private func bodyData() -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private var tokenPayload: Data {
        Data("""
        {"access_token":"\(feishuTokenValue)","expires_in":7200,\
        "refresh_token":"\(feishuRefreshValue)","refresh_token_expires_in":604800,\
        "scope":"drive:drive:readonly offline_access","token_type":"Bearer"}
        """.utf8)
    }

    private func send(_ status: Int, _ data: Data, url: URL?) {
        guard let url,
              let response = HTTPURLResponse(
                  url: url, statusCode: status, httpVersion: nil, headerFields: nil
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
}
