// SPDX-License-Identifier: MIT

import Foundation
import ProbeKit
import XCTest

final class PA_GitHubSecretTests: XCTestCase {
    func testSecretNeverAppearsInURLsToolJSONErrorsOrRequestSnapshots() async throws {
        let secret = "test-only-secret"
        let credentials = InMemoryConnectorCredentials()
        try credentials.saveCredential(secret, for: "github.pat")
        let transport = MockConnectorHTTPTransport()
        await transport.stub("/repos/owner/repo", status: 401)
        let registry = try await connectedGitHubRegistry(credentials: credentials)
        let bridge = GitHubToolBridge(client: GitHubClient(transport: transport, credentials: credentials),
                                      registry: registry)
        let result = await bridge.invoke("github.repository.get",
                                         argumentsJSON: #"{"repository":"owner/repo"}"#,
                                         caller: .dshDirect)
        XCTAssertTrue(result.isError)
        XCTAssertFalse(result.contentJSON.contains(secret))
        for request in await transport.snapshot() {
            XCTAssertFalse(request.url.contains(secret))
            XCTAssertFalse(request.body?.contains(secret) == true)
            XCTAssertTrue(request.hasAuthorization)
        }
        XCTAssertFalse(GitHubClientError.unauthorized.message.contains(secret))
        XCTAssertFalse(String(describing: GitHubClientError.unauthorized).contains(secret))
    }

    func testMissingCredentialFailsClosedWithoutURLFallback() async throws {
        let credentials = InMemoryConnectorCredentials()
        let transport = MockConnectorHTTPTransport()
        let client = GitHubClient(transport: transport, credentials: credentials)
        do {
            _ = try await client.repository("owner/repo")
            XCTFail("missing PAT must fail")
        } catch let error as GitHubClientError {
            XCTAssertEqual(error, .notConfigured)
        }
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 0)
    }
}
