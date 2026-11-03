// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHShell
import ProbeKit
import XCTest

final class PA_GitHubDualPathTests: XCTestCase {
    func testChatAndDSHUseSameBridgeClientAndGrant() async throws {
        let credentials = InMemoryConnectorCredentials()
        try credentials.saveCredential("test-only-secret", for: "github.pat")
        let transport = MockConnectorHTTPTransport()
        await transport.stub("/repos/owner/repo", json: githubRepositoryJSON)
        let client = GitHubClient(transport: transport, credentials: credentials)
        let registry = try await connectedGitHubRegistry(credentials: credentials)
        let bridge = GitHubToolBridge(client: client, registry: registry)
        let composite = CompositePhoneToolBridge(bridges: [bridge])

        let chat = await bridge.invoke("github.repository.get",
                                       argumentsJSON: #"{"repository":"owner/repo"}"#,
                                       caller: .personalAgent(mandate: readMandate()))
        let dsh = try await composite.callTool(name: "phone.github.repository.get",
                                               arguments: #"{"repository":"owner/repo"}"#)
        XCTAssertFalse(chat.isError)
        XCTAssertEqual(chat.contentJSON, dsh)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(chat.contentJSON.utf8)) as? [String: Any])
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        XCTAssertEqual(result["html_url"] as? String, "https://github.com/owner/repo")

        let denied = await bridge.invoke("github.repository.get",
                                         argumentsJSON: #"{"repository":"other/private"}"#,
                                         caller: .personalAgent(mandate: readMandate()))
        XCTAssertTrue(denied.isError)
        XCTAssertTrue(denied.contentJSON.contains("repository_outside_grant"))

        try await registry.revoke("github")
        let chatAfterRevoke = await bridge.invoke("github.repository.get",
                                                  argumentsJSON: #"{"repository":"owner/repo"}"#,
                                                  caller: .personalAgent(mandate: readMandate()))
        let dshAfterRevoke = try await bridge.callTool(name: "github.repository.get",
                                                       arguments: #"{"repository":"owner/repo"}"#)
        XCTAssertTrue(chatAfterRevoke.isError)
        XCTAssertTrue(chatAfterRevoke.contentJSON.contains("connector_revoked"))
        XCTAssertTrue(dshAfterRevoke.contains("connector_revoked"))
    }

    func testBridgeDescriptorsProjectReadAndWriteEffects() {
        let credentials = InMemoryConnectorCredentials()
        let transport = MockConnectorHTTPTransport()
        let client = GitHubClient(transport: transport, credentials: credentials)
        let registry = try! PersistentConnectorRegistry(store: InMemoryConnectorStore())
        let readOnly = GitHubToolBridge(client: client, registry: registry)
        XCTAssertEqual(readOnly.descriptors.filter { $0.effect == .write }.count, 0)
        let bridge = GitHubToolBridge(client: client, registry: registry,
                                      writeGate: AllowingWriteGate(), ledger: RecordingOperationLedger())
        XCTAssertEqual(Set(bridge.descriptors.map(\.internalName)), bridge.handles)
        XCTAssertEqual(bridge.hostCapabilities, Set(bridge.handles.map { "phone-tool:\($0)" }))
        XCTAssertEqual(bridge.descriptors.filter { $0.effect == .read }.count, 5)
        XCTAssertEqual(bridge.descriptors.filter { $0.effect == .write }.map(\.mandateAction),
                       [.githubComment, .githubCreateIssue])
        XCTAssertFalse(bridge.supportsContext)
    }
}
