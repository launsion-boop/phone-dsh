// SPDX-License-Identifier: MIT

@testable import PhoneDSHProbe
@testable import ProbeKit
import XCTest

final class PA_IntegrationUpgradeTests: XCTestCase {
    func testRuntimeContextUsesLiveIdentityScopesCapabilitiesAndInteractionState() async throws {
        let root = temporaryRoot()
        let domain = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"))
        let conversations = ConversationStore(domain: domain)
        let memories = MemoryStore(domain: domain)
        let followUps = FollowUpStore(domain: domain)
        try await conversations.prepare()
        try await memories.prepare()
        try await followUps.prepare()
        let conversationID = UUID()
        let source = SourceEnvelope(requestID: UUID(), principal: "owner", source: .phone,
                                    replyTo: .phoneChat, grantVersion: 0, receivedAt: Date())
        let turn = try await conversations.enqueue(text: "分析这个 PR", source: source,
                                                   conversationID: conversationID)
        try await conversations.recordQuestion(PendingQuestion(text: "选择下一步"), turnID: turn.id)
        try await memories.save(MemoryRecord(
            principal: "owner", kind: .longTerm, field: .displayName, text: "测试用户",
            source: MemorySource(kind: .phone, reference: "onboarding", detail: "test"),
            origin: .userExplicit, status: .active))
        try await memories.save(MemoryRecord(
            principal: "owner", kind: .longTerm, field: .language, text: "en",
            source: MemorySource(kind: .phone, reference: "preference", detail: "test"),
            origin: .userExplicit, status: .active))
        let store = SuggestionStore(rootDirectory: root)
        try await store.recordHistory(SuggestionHistoryEntry(
            principal: "owner", canonicalKey: SuggestionStore.canonicalSuppressionKey(
                action: "review", target: "owner/repo#1"), outcome: .selected))
        let operations = try FileOperationLedger(root: root)
        let provider = PersonalAgentContextProvider(
            conversations: conversations, memories: memories, followUps: followUps,
            operations: operations, suggestionStore: store,
            assistantName: { "测试Agent" })
        let mandate = WorkMandate(mandateID: UUID(), version: 2, requestID: turn.requestID,
                                  principal: "owner", source: .phone, goal: "分析 PR",
                                  allowedActions: [.read], allowedEvidenceRefs: [],
                                  targets: MandateTargets(repository: "owner/repo",
                                                          issueOrPRNumbers: [1], origin: .userNamed),
                                  validUntil: Date().addingTimeInterval(600))
        let input = MainTurnInput(turnID: turn.id, requestID: turn.requestID, principal: "owner",
                                  conversationID: conversationID, text: turn.text, mandate: mandate)
        let snapshot = try await provider.snapshot(for: input)
        let descriptor = ConnectorToolDescriptor(
            internalName: "github.pull.get", connectorID: "github", effect: .read,
            mandateAction: .read, inputSchemaJSON: #"{"type":"object"}"#, summary: "Read PR")
        let resolved = try snapshot.resolvingRuntimeContext(descriptors: [descriptor])
        let runtime = try XCTUnwrap(resolved.runtimeContext)
        XCTAssertEqual(runtime.assistantName, "测试Agent")
        XCTAssertEqual(runtime.userName, "测试用户")
        XCTAssertEqual(runtime.preferredLanguage, "en")
        XCTAssertEqual(runtime.delegatedScopes.map(\.version), [2])
        XCTAssertEqual(runtime.delegatedScopes.first?.actions, ["read"])
        XCTAssertEqual(runtime.capabilities.map(\.name), ["github_pull_get"])
        XCTAssertEqual(runtime.interactionState.pendingClarifications.count, 1)
        XCTAssertTrue(runtime.interactionState.suggestionHistory.contains { $0.contains("selected") })
        let encoded = try runtime.encodedEnvelope()
        XCTAssertFalse(encoded.contains("{{"))
        XCTAssertTrue(encoded.contains("测试Agent"))
    }

    func testSuggestionHistoryAdapterKeepsSelectionAndAccountBoundaries() async throws {
        let store = SuggestionStore(rootDirectory: temporaryRoot())
        let adapter = SuggestionStoreHistoryAdapter(store: store)
        let key = SuggestionStore.canonicalSuppressionKey(action: "review", target: "owner/repo#1")
        let entry = SuggestionHistoryEntry(principal: "owner", accountScope: nil,
                                           canonicalKey: key, outcome: .selected)
        _ = try await adapter.recordSuggestion(entry)
        let selected = try await adapter.suggestionHistory(principal: "owner", accountScope: nil,
                                                            canonicalKey: key, limit: 10)
        XCTAssertEqual(selected.map(\.outcome), [.selected])
        let dismissed = try await adapter.suggestionHistory(principal: "owner", accountScope: nil,
                                                             canonicalKey: key, limit: 10)
        XCTAssertNotEqual(dismissed.map(\.outcome), [.dismissed])
        let otherAccount = try await adapter.suggestionHistory(principal: "owner", accountScope: "other",
                                                                canonicalKey: key, limit: 10)
        XCTAssertTrue(otherAccount.isEmpty)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PA-IntegrationUpgrade-\(UUID().uuidString)")
    }
}
