// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
@testable import ProbeKit
import XCTest

final class PA_GmailOAuthTests: XCTestCase {
    func testPKCEParametersAndStateValidation() throws {
        let request = try GmailOAuthFlow.authorizationRequest(configuration: PA_GmailConfiguration()) { count in
            Data(repeating: 7, count: count)
        }
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let challenge = GmailOAuthFlow.base64URL(Data(SHA256.hash(data: Data(request.codeVerifier.utf8))))
        XCTAssertEqual(items.first(where: { $0.name == "code_challenge" })?.value, challenge)
        XCTAssertEqual(items.first(where: { $0.name == "code_challenge_method" })?.value, "S256")
        XCTAssertNil(items.first(where: { $0.name == "client_secret" }))
        XCTAssertEqual(request.codeVerifier.count, 43)
        let callback = URL(string: "dev.phone-dsh.probe:/oauth/gmail?code=code1&state=\(request.state)")!
        XCTAssertEqual(try GmailOAuthFlow.authorizationCode(callback: callback, expectedState: request.state), "code1")
        let attack = URL(string: "dev.phone-dsh.probe:/oauth/gmail?code=attacker&state=wrong")!
        XCTAssertThrowsError(try GmailOAuthFlow.authorizationCode(callback: attack, expectedState: request.state)) {
            XCTAssertEqual($0 as? GmailError, .invalidState)
        }
        XCTAssertThrowsError(try GmailOAuthFlow.authorizationCode(
            callback: callback, request: request, now: request.issuedAt.addingTimeInterval(601))) {
            XCTAssertEqual($0 as? GmailError, .invalidState)
        }
    }

    func testRefreshFailureExpiresAndDeletesTokens() async throws {
        let store = PA_GmailTokenStore(PA_GmailTokens(expired: true))
        let transport = PA_GmailTransport()
        await transport.enqueueJSON("POST /token", status: 400, "{\"error\":\"invalid_grant\"}")
        let manager = PA_GmailManager(store: store, transport: transport)
        do {
            _ = try await manager.withValidAccessToken { _ in "must not execute" }
            XCTFail("refresh failure must expire authorization")
        } catch {
            XCTAssertEqual(error as? GmailError, .expired)
        }
        XCTAssertNil(store.snapshot)
    }

    func testRevokeUsesRequestBodyAndDeletesKeychainItem() async throws {
        let store = PA_GmailTokenStore(PA_GmailTokens())
        let transport = PA_GmailTransport()
        await transport.enqueueJSON("POST /revoke", "{}")
        let manager = PA_GmailManager(store: store, transport: transport)
        try await manager.revoke()
        XCTAssertNil(store.snapshot)
        let requests = await transport.requests(for: "/revoke")
        XCTAssertEqual(requests.count, 1)
        let url = try requests[0].url()
        XCTAssertFalse(url.absoluteString.contains("test-refresh-token"))
        XCTAssertTrue(String(decoding: requests[0].body ?? Data(), as: UTF8.self).contains("token="))
    }

    func testMissingBundleConfigurationStaysNotConfigured() {
        XCTAssertNil(GmailOAuthConfiguration.loadFromInfoBundle(Bundle()))
    }
}
