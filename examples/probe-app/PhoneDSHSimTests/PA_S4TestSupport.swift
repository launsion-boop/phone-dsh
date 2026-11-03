// SPDX-License-Identifier: MIT

import Foundation
import ProbeKit
import XCTest

let paFixedDate = Date(timeIntervalSince1970: 1_760_000_000)

func paTemporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("pa-s4-tests-\(UUID().uuidString)", isDirectory: true)
}

func paEnvelope(requestID: UUID = UUID(), source: SourceKind = .phone, principal: String = "user") -> SourceEnvelope {
    SourceEnvelope(requestID: requestID, principal: principal, source: source,
                   replyTo: source == .dsh ? .dshSession("session") : .phoneChat,
                   grantVersion: 1, receivedAt: paFixedDate)
}

func paMandate(actions: Set<MandateAction> = [.read, .gmailReplyInThread],
               origin: TargetOrigin = .userNamed, source: SourceKind = .phone,
               requestID: UUID = UUID(), mandateID: UUID = UUID(),
               threads: [String] = ["thread-safe"], recipients: [String] = ["alice@example.com"],
               repository: String? = "octo/repo", numbers: [Int] = [1],
               evidence: Set<EvidenceRef> = [], validUntil: Date? = nil) -> WorkMandate {
    WorkMandate(mandateID: mandateID, version: 1, requestID: requestID, principal: "user", source: source,
                goal: "fixture", allowedActions: actions, allowedEvidenceRefs: evidence,
                targets: MandateTargets(gmailThreadIDs: threads, recipientIdentities: recipients,
                                        repository: repository, issueOrPRNumbers: numbers, origin: origin),
                validUntil: validUntil ?? paFixedDate.addingTimeInterval(600))
}

func paGrant(actions: Set<MandateAction> = [.read, .gmailReplyInThread, .gmailSendNew, .gmailForward,
                                            .gmailCreateDraft, .githubComment, .githubCreateIssue,
                                            .githubPush, .githubOpenPR],
             connectorID: String = "gmail", version: Int = 1, paused: Bool = false,
             repositories: [String] = ["octo/repo"], maxOperations: Int = 20,
             maxRecipients: Int = 3, maxAttachmentBytes: Int = 1_000) -> ConnectorGrant {
    ConnectorGrant(connectorID: connectorID, version: version, allowedActions: actions,
                   scope: GrantScope(repositories: repositories, gmailAccount: "user@example.com"),
                   rateLimit: RateLimit(maxOperationsPerHour: maxOperations, maxRecipients: maxRecipients,
                                        maxAttachmentBytes: maxAttachmentBytes), paused: paused)
}

func paTool(name: String = "gmail.message.reply", connectorID: String = "gmail",
            effect: ToolEffect = .irreversible,
            action: MandateAction? = .gmailReplyInThread) -> ConnectorToolDescriptor {
    ConnectorToolDescriptor(internalName: name, connectorID: connectorID, effect: effect,
                            mandateAction: action, inputSchemaJSON: "{}", summary: "fixture")
}

func paReplyArguments(thread: String = "thread-safe", recipients: [String] = ["alice@example.com"],
                      evidence: [String]? = nil, attachmentBytes: Int? = nil) -> String {
    var object: [String: Any] = ["threadID": thread, "recipients": recipients, "body": "connector-controlled body"]
    object["evidenceRefs"] = evidence
    object["attachmentBytes"] = attachmentBytes
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}

func paGitHubArguments(repository: String = "octo/repo", number: Int = 1) -> String {
    let object: [String: Any] = ["repository": repository, "number": number, "body": "comment"]
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}

func paDenial(_ decision: GateDecision) -> GateDenial? {
    if case let .deny(denial) = decision { return denial }
    return nil
}

func paIntent(id: UUID = UUID(), digest: String = "digest", tool: String = "gmail.message.reply") -> OperationIntent {
    OperationIntent(id: id, toolName: tool, argumentsJSON: paReplyArguments(), digest: digest,
                    mandateID: UUID())
}

actor PACounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

enum PATestError: Error { case timeout, provider }

func paAssertEqual<Value: Equatable>(_ value: Value, _ expected: Value,
                                     file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(value, expected, file: file, line: line)
}

func paAssertNil<Value>(_ value: Value?, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertNil(value, file: file, line: line)
}
