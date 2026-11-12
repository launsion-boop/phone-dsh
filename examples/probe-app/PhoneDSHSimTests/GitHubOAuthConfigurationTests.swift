// SPDX-License-Identifier: MIT

import Foundation
import ProbeKit
import XCTest

final class GitHubOAuthConfigurationTests: XCTestCase {
    private let state = String(repeating: "A", count: 43)

    func testOriginIsNormalizedToAPathlessLowercaseHTTPSOrigin() throws {
        let configuration = try XCTUnwrap(GitHubOAuthConfiguration(
            origin: " https://Auth.Example.com:8443/ ",
            clientID: "Iv1.fixture",
            appSlug: "phone-dsh-fixture"
        ))
        XCTAssertEqual(configuration.origin.absoluteString, "https://auth.example.com:8443")
        XCTAssertEqual(
            configuration.redirectURI.absoluteString,
            "https://auth.example.com:8443/v1/github/oauth/callback"
        )
        XCTAssertEqual(
            configuration.exchangeEndpoint.absoluteString,
            "https://auth.example.com:8443/v1/github/oauth/exchange"
        )
        XCTAssertEqual(
            configuration.revokeEndpoint.absoluteString,
            "https://auth.example.com:8443/v1/github/oauth/revoke"
        )
        XCTAssertEqual(
            configuration.installationURL.absoluteString,
            "https://github.com/apps/phone-dsh-fixture/installations/new"
        )
    }

    func testMalformedOriginsDisableTheWholeConfiguration() {
        for origin in [
            "",
            "http://auth.example.com",
            "https://auth.example.com/path",
            "https://auth.example.com?query=1",
            "https://auth.example.com#fragment",
            "https://user:pass@auth.example.com",
            "https://auth.example.com:99999",
            "https://auth example.com",
        ] {
            XCTAssertNil(
                GitHubOAuthConfiguration(
                    origin: origin, clientID: "Iv1.fixture", appSlug: "phone-dsh-fixture"
                ),
                origin
            )
        }
    }

    func testMalformedClientIdentifiersDisableTheWholeConfiguration() {
        for clientID in ["", "Iv1 fixture", "Iv1/fixture", "Iv1+fixture", String(repeating: "a", count: 129)] {
            XCTAssertNil(
                GitHubOAuthConfiguration(
                    origin: "https://auth.example.com", clientID: clientID, appSlug: "phone-dsh-fixture"
                ),
                clientID
            )
        }
    }

    func testMalformedAppSlugsDisableTheWholeConfiguration() {
        for slug in ["", "-phone", "phone-", "phone_dsh", "phone dsh", String(repeating: "a", count: 101)] {
            XCTAssertNil(
                GitHubOAuthConfiguration(
                    origin: "https://auth.example.com", clientID: "Iv1.fixture", appSlug: slug
                ),
                slug
            )
        }
    }

    func testInfoDictionaryRequiresAllThreeKeys() throws {
        let complete: [String: Any] = [
            GitHubOAuthConfiguration.Keys.origin: "https://auth.example.com",
            GitHubOAuthConfiguration.Keys.clientID: "Iv1.fixture",
            GitHubOAuthConfiguration.Keys.appSlug: "phone-dsh-fixture",
        ]
        XCTAssertNotNil(GitHubOAuthConfiguration(infoDictionary: complete))
        for missing in GitHubOAuthConfiguration.Keys.all {
            var partial = complete
            partial.removeValue(forKey: missing)
            XCTAssertNil(GitHubOAuthConfiguration(infoDictionary: partial), missing)
        }
        XCTAssertNil(GitHubOAuthConfiguration(infoDictionary: nil))
    }

    func testPKCEAttemptsAreFreshAndURLSafe() throws {
        let first = try GitHubOAuthPKCE.makeAttempt()
        let second = try GitHubOAuthPKCE.makeAttempt()
        XCTAssertNotEqual(first.state, second.state)
        XCTAssertNotEqual(first.verifier, second.verifier)
        XCTAssertEqual(first.state.count, 43)
        XCTAssertEqual(first.verifier.count, 43)
        XCTAssertEqual(first.challenge.count, 43)
        XCTAssertNotEqual(first.challenge, GitHubOAuthPKCE.base64URL(Data(first.verifier.utf8)))
    }

    func testCallbackRejectsAnotherPathPortOrExtraParameter() throws {
        let root = "phonedsh-github://oauth/callback"
        XCTAssertEqual(
            try GitHubOAuthCallbackValidator.validate(
                XCTUnwrap(URL(string: root + "?state=\(state)&code=github-code")),
                expectedState: state
            ),
            .code("github-code")
        )
        for invalid in [
            "phonedsh-github://oauth/callback2?state=\(state)&code=github-code",
            "phonedsh-github://oauth:8080/callback?state=\(state)&code=github-code",
            "http://oauth/callback?state=\(state)&code=github-code",
            root + "?state=\(state)&code=github-code&extra=1",
            root + "?state=\(state)&code=github-code&code=github-code",
            root + "?state=\(state)&code=",
        ] {
            XCTAssertThrowsError(
                try GitHubOAuthCallbackValidator.validate(
                    XCTUnwrap(URL(string: invalid)), expectedState: state
                ),
                invalid
            )
        }
    }
}

private extension GitHubOAuthConfiguration.Keys {
    static var all: [String] { [origin, clientID, appSlug] }
}
