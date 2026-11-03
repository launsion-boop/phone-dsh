// SPDX-License-Identifier: MIT

import Foundation
import ProbeKit
import XCTest

final class PA_GitHubWriteTests: XCTestCase {
    private let commentJSON = #"{"id":99,"body":"hello","html_url":"https://github.com/owner/repo/issues/7#issuecomment-99","created_at":"2026-11-03T00:00:00Z","user":{"login":"octo"}}"#

    func testPersonalAgentWriteUsesGateAndLedgerButDSHDirectNeverInheritsIt() async throws {
        let credentials = InMemoryConnectorCredentials()
        try credentials.saveCredential("test-only-secret", for: "github.pat")
        let transport = MockConnectorHTTPTransport()
        await transport.stub("/repos/owner/repo/issues/7/comments", method: "POST", status: 201, json: commentJSON)
        let registry = try await connectedGitHubRegistry(credentials: credentials)
        let gate = AllowingWriteGate()
        let ledger = RecordingOperationLedger()
        let bridge = GitHubToolBridge(client: GitHubClient(transport: transport, credentials: credentials),
                                      registry: registry, writeGate: gate, ledger: ledger)
        let arguments = #"{"repository":"owner/repo","number":7,"body":"hello"}"#

        let direct = try await bridge.callTool(name: "github.issue.comment", arguments: arguments)
        XCTAssertTrue(direct.contains("dsh_approval_required"))
        let gateCalls = await gate.calls
        let directPrepareCount = await ledger.prepareCount
        XCTAssertEqual(gateCalls, 1)
        XCTAssertEqual(directPrepareCount, 0)

        let result = await bridge.invoke("github.issue.comment", argumentsJSON: arguments,
                                         caller: .personalAgent(mandate: readMandate(actions: [.read, .githubComment])))
        XCTAssertFalse(result.isError, result.contentJSON)
        XCTAssertTrue(result.contentJSON.contains("comment-99"))
        let prepareCount = await ledger.prepareCount
        XCTAssertEqual(prepareCount, 1)
        let records = await ledger.records
        XCTAssertEqual(records.values.first?.phase, .committed)
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.filter { $0.method == "POST" }.count, 1)
    }

    func testNetworkFailureMarksUnknownAndDoesNotRetry() async throws {
        let credentials = InMemoryConnectorCredentials()
        try credentials.saveCredential("test-only-secret", for: "github.pat")
        let transport = MockConnectorHTTPTransport()
        await transport.stub("/repos/owner/repo/issues/7/comments", method: "POST",
                             failure: .networkUnavailable)
        let registry = try await connectedGitHubRegistry(credentials: credentials)
        let ledger = RecordingOperationLedger()
        let bridge = GitHubToolBridge(client: GitHubClient(transport: transport, credentials: credentials),
                                      registry: registry, writeGate: AllowingWriteGate(), ledger: ledger)
        let result = await bridge.invoke("github.issue.comment",
                                         argumentsJSON: #"{"repository":"owner/repo","number":7,"body":"hello"}"#,
                                         caller: .personalAgent(mandate: readMandate(actions: [.read, .githubComment])))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.contentJSON.contains("network_unavailable"))
        let records = await ledger.records
        XCTAssertEqual(records.values.first?.phase, .unknown)
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.filter { $0.method == "POST" }.count, 1)
    }

    func testCreateIssueUsesGateAndLedger() async throws {
        let credentials = InMemoryConnectorCredentials()
        try credentials.saveCredential("test-only-secret", for: "github.pat")
        let transport = MockConnectorHTTPTransport()
        await transport.stub("/repos/owner/repo/issues", method: "POST", status: 201, json: githubIssueJSON)
        let registry = try await connectedGitHubRegistry(credentials: credentials)
        let gate = AllowingWriteGate()
        let ledger = RecordingOperationLedger()
        let bridge = GitHubToolBridge(client: GitHubClient(transport: transport, credentials: credentials),
                                      registry: registry, writeGate: gate, ledger: ledger)
        let result = await bridge.invoke("github.issue.create",
                                         argumentsJSON: #"{"repository":"owner/repo","title":"Issue","body":"body"}"#,
                                         caller: .personalAgent(mandate: readMandate(actions: [.read, .githubCreateIssue])))
        XCTAssertFalse(result.isError, result.contentJSON)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.contentJSON.utf8)) as? [String: Any])
        XCTAssertEqual(envelope["url"] as? String, "https://github.com/owner/repo/issues/7")
        let gateCalls = await gate.calls
        let records = await ledger.records
        XCTAssertEqual(gateCalls, 1)
        XCTAssertEqual(records.values.first?.phase, .committed)
    }

    func testReconcileFindsMatchingDigestWithoutAnotherWrite() async throws {
        let credentials = InMemoryConnectorCredentials()
        try credentials.saveCredential("test-only-secret", for: "github.pat")
        let transport = MockConnectorHTTPTransport()
        await transport.stub("/repos/owner/repo/issues/7", json: githubIssueJSON)
        await transport.stub("/repos/owner/repo/issues/7/comments", json: "[\(commentJSON)]")
        let client = GitHubClient(transport: transport, credentials: credentials)
        let intent = OperationIntent(toolName: "github.issue.comment",
                                     argumentsJSON: #"{"repository":"owner/repo","number":7,"body":"hello"}"#,
                                     digest: GitHubWriteReconciler.digest("hello"), mandateID: UUID())
        let commentTime = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-03T00:00:00Z"))
        let operation = OperationRecord(id: intent.id, intent: intent, phase: .unknown,
                                        createdAt: commentTime, updatedAt: commentTime)
        let receipt = try await GitHubWriteReconciler(client: client).reconcile(operation)
        XCTAssertEqual(receipt?.providerObjectID, "99")
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.filter { $0.method == "POST" }.count, 0)
    }
}
