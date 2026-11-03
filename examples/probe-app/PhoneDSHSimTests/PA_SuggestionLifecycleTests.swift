// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import ProbeKit

final class PA_SuggestionLifecycleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testStructuredNoneOneAndFourOptionsUseHostMetadata() async throws {
        let one = proposalJSON(options: [optionJSON(id: "draft_reply", label: "起草回复")])
        let four = proposalJSON(options: (1...4).map {
            optionJSON(id: "step_\($0)", label: "步骤 \($0)")
        })
        let transport = PA_RuntimeScriptedTransport(replies: [
            structuredReply(#"{"kind":"none"}"#), structuredReply(one), structuredReply(four),
        ])
        let generator = NativeSuggestionGenerator(
            clientResolver: PA_RuntimeFixedResolver(transport: transport), capabilities: ["gmail.create_draft:write"])
        let turn = pa_runtimeTurn(mandate: nil, text: "整理这封邮件")
        let answer = AssistantMessage(text: "已整理")
        let key = SuggestionSuppressionKey(action: "Gmail.CreateDraft", target: " thread-42 ")
        let metadata = SuggestionHostMetadata(
            accountID: "account-a", cardID: UUID(), createdAt: now, expiresAt: now.addingTimeInterval(600),
            suppressionKeysByOptionID: ["draft_reply": [key]], suppressionHistory: ["v1:dismissed"],
            userLanguage: "zh-Hans")

        let none = await generator.generateCard(turn: turn, answer: answer, metadata: metadata)
        let oneResult = await generator.generateCard(turn: turn, answer: answer, metadata: metadata)
        let fourResult = await generator.generateCard(turn: turn, answer: answer, metadata: metadata)

        XCTAssertEqual(none, .none)
        let oneCard = try card(from: oneResult)
        XCTAssertEqual(oneCard.options.count, 1)
        XCTAssertEqual(oneCard.options[0].userRequest, "请起草回复，不要发送")
        XCTAssertEqual(oneCard.cardID, metadata.cardID)
        XCTAssertEqual(oneCard.conversationID, turn.conversationID)
        XCTAssertEqual(oneCard.turnID, turn.turnID)
        XCTAssertEqual(oneCard.principal, turn.principal)
        XCTAssertEqual(oneCard.accountID, "account-a")
        XCTAssertEqual(oneCard.createdAt, now)
        XCTAssertEqual(oneCard.expiresAt, now.addingTimeInterval(600))
        XCTAssertEqual(oneCard.suppressionKeys, [key])
        XCTAssertFalse(oneCard.multiSelect)
        let fourCard = try card(from: fourResult)
        XCTAssertEqual(fourCard.options.count, 4)
        XCTAssertEqual(fourCard.suppressionKeys.count, 4)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.tools.map(\.name), ["suggest_card"])
        XCTAssertEqual(request.toolChoice, .tool("suggest_card"))
        XCTAssertTrue(request.tools[0].inputSchemaJSON.contains("additionalProperties"))
        XCTAssertTrue(request.system.contains("must never be suggested or approved"))
        guard case .text(let prompt) = request.messages[0].content.first else {
            return XCTFail("expected text context")
        }
        XCTAssertTrue(prompt.contains("整理这封邮件"))
        XCTAssertTrue(prompt.contains("gmail.create_draft:write"))
        XCTAssertTrue(prompt.contains("v1:dismissed"))
        XCTAssertTrue(prompt.contains("zh-Hans"))
    }

    func testMalformedDuplicateUnknownAndApprovalOutputsAreRejected() async throws {
        let duplicate = proposalJSON(options: [
            optionJSON(id: "same", label: "一"), optionJSON(id: "same", label: "二"),
        ])
        let unknown = #"{"kind":"next_steps","question":"继续？","options":[],"allow_custom":false,"dismiss_on_move_on":true,"multi_select":false,"cardID":"model-controlled"}"#
        let approval = #"{"kind":"approval","question":"发送？","options":[],"allow_custom":false,"dismiss_on_move_on":false,"multi_select":false}"#
        let transport = PA_RuntimeScriptedTransport(replies: [
            pa_runtimeTextResponse("不是结构化输出"), structuredReply(duplicate), structuredReply(unknown),
            structuredReply(approval), structuredReply(proposalJSON(options: [])),
        ])
        let generator = NativeSuggestionGenerator(clientResolver: PA_RuntimeFixedResolver(transport: transport))
        let turn = pa_runtimeTurn(mandate: nil)

        for _ in 0..<5 {
            let result = await generator.generateCard(turn: turn, answer: AssistantMessage(text: "完成"),
                                                      metadata: metadata())
            XCTAssertEqual(result, .suppressed(.invalidResponse))
        }
    }

    func testPendingClarificationAndStaleContextSuppressGeneration() async throws {
        let transport = PA_RuntimeScriptedTransport(replies: [])
        let pending = MainConversationSnapshot(currentText: "", pendingQuestions: [PendingQuestion(text: "请选择")])
        let generator = NativeSuggestionGenerator(
            clientResolver: PA_RuntimeFixedResolver(transport: transport),
            contextProvider: MainStaticContextProvider(base: pending))
        let turn = pa_runtimeTurn(mandate: nil)

        let blocked = await generator.generateCard(turn: turn, answer: AssistantMessage(text: "等待"),
                                                   metadata: metadata())
        let stale = await generator.generateCard(
            turn: turn, answer: AssistantMessage(text: "完成"),
            metadata: SuggestionHostMetadata(accountID: "account-a", createdAt: now, expiresAt: now))

        XCTAssertEqual(blocked, .suppressed(.pendingClarification))
        XCTAssertEqual(stale, .suppressed(.staleContext))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testClarificationSupersedesOptionalCardAndWinsOutstandingOwner() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SuggestionStore(rootDirectory: root)
        let scope = scope()
        let optionalResult = try await store.shown(makeCard(scope: scope), now: now)
        let optional = try XCTUnwrap(optionalResult)
        let clarification = makeCard(scope: scope, turnID: UUID(), kind: .clarification, options: [],
                                     allowCustom: true, dismissOnMoveOn: false)

        let shownClarification = try await store.shown(clarification, now: now)
        let suppressedOptional = try await store.shown(makeCard(scope: scope, turnID: UUID()), now: now)
        let loaded = try await store.outstanding(scope: scope, now: now)
        let optionalOutcome = await store.outcome(cardID: optional.cardID)

        XCTAssertEqual(shownClarification?.cardID, clarification.cardID)
        XCTAssertNil(suppressedOptional)
        XCTAssertEqual(loaded.map(\.cardID), [clarification.cardID])
        XCTAssertEqual(optionalOutcome, .superseded)
    }

    func testSelectionReturnsUserRequestNeverDismissesAndDeduplicatesRetries() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SuggestionStore(rootDirectory: root)
        let card = makeCard(scope: scope())
        _ = try await store.shown(card, now: now)
        let eventID = UUID()

        let firstResult = try await store.select(cardID: card.cardID, optionID: "next",
                                                 selectionEventID: eventID, now: now)
        let retryResult = try await store.select(cardID: card.cardID, optionID: "next",
                                                 selectionEventID: eventID, now: now)
        let first = try XCTUnwrap(firstResult)
        let retry = try XCTUnwrap(retryResult)
        let secondTap = try await store.select(cardID: card.cardID, optionID: "next",
                                               selectionEventID: UUID(), now: now)
        let outcome = await store.outcome(cardID: card.cardID)
        let outcomes = await store.events(cardID: card.cardID).map(\.outcome)
        let dismissed = await store.isDismissed(turnID: card.turnID)

        XCTAssertTrue(first.shouldSend)
        XCTAssertEqual(first.userRequest, "请起草回复，不要发送")
        XCTAssertFalse(retry.shouldSend)
        XCTAssertEqual(retry.selection, first.selection)
        XCTAssertNil(secondTap)
        XCTAssertEqual(outcome, .selected)
        XCTAssertEqual(outcomes, [.shown, .selected])
        XCTAssertFalse(dismissed)

        let reopened = SuggestionStore(rootDirectory: root)
        let restoredResult = try await reopened.select(cardID: card.cardID, optionID: "next",
                                                       selectionEventID: eventID, now: now)
        let restoredRetry = try XCTUnwrap(restoredResult)
        XCTAssertFalse(restoredRetry.shouldSend)
        let nextTurn = makeCard(scope: card.scope, turnID: UUID())
        let nextResult = try await reopened.shown(nextTurn, now: now)
        XCTAssertNotNil(nextResult)
    }

    func testDismissalSurvivesRestartAndCooldownIsCanonicalAcrossTurns() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SuggestionStore(rootDirectory: root)
        let scope = scope()
        let key = SuggestionSuppressionKey(action: "Draft Reply", target: "thread-42")
        let first = makeCard(scope: scope, keys: [key])
        _ = try await store.shown(first, now: now)
        try await store.dismiss(cardID: first.cardID, now: now)

        let reopened = SuggestionStore(rootDirectory: root)
        let sameActionNewWording = makeCard(scope: scope, turnID: UUID(), question: "完全不同的措辞",
                                            keys: [SuggestionSuppressionKey(action: "draft reply",
                                                                            target: "thread-42")])
        let duringCooldown = try await reopened.shown(sameActionNewWording, now: now.addingTimeInterval(60))
        let direct = makeCard(scope: scope, turnID: UUID(), keys: [key])
        let directResult = try await reopened.shown(direct, now: now.addingTimeInterval(120),
                                                    directlyRequested: true)
        let afterCooldownDate = now.addingTimeInterval(8 * 24 * 60 * 60)
        let afterCooldown = makeCard(scope: scope, turnID: UUID(), keys: [key], createdAt: afterCooldownDate)
        let firstOutcome = await reopened.outcome(cardID: first.cardID)
        let cooldownResult = try await reopened.shown(afterCooldown, now: afterCooldownDate)

        XCTAssertNil(duringCooldown)
        XCTAssertNotNil(directResult)
        XCTAssertEqual(firstOutcome, .dismissed)
        XCTAssertNotNil(cooldownResult)
        XCTAssertNotEqual(key.canonical, SuggestionSuppressionKey(action: "draft_reply", target: "thread-42").canonical)
        XCTAssertEqual(key.canonical, SuggestionStore.canonicalSuppressionKey(action: "draft reply",
                                                                              target: "thread-42"))
    }

    func testExplicitDeclinesCountSeparatelyAndTwoStopUnsolicitedRepeats() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SuggestionStore(rootDirectory: root)
        let scope = scope()
        let key = SuggestionSuppressionKey(action: "send", target: "thread-42")
        let first = makeCard(scope: scope, keys: [key])
        _ = try await store.shown(first, now: now)
        try await store.decline(cardID: first.cardID, now: now)
        let second = makeCard(scope: scope, turnID: UUID(), keys: [key])
        _ = try await store.shown(second, now: now.addingTimeInterval(60), directlyRequested: true)
        try await store.decline(cardID: second.cardID, now: now.addingTimeInterval(60))

        let later = now.addingTimeInterval(31 * 24 * 60 * 60)
        let third = makeCard(scope: scope, turnID: UUID(), keys: [key], createdAt: later)
        let result = try await store.shown(third, now: later)
        let direct = makeCard(scope: scope, turnID: UUID(), keys: [key], createdAt: later.addingTimeInterval(60))
        let unrelated = makeCard(scope: scope, turnID: UUID(), keys: [
            SuggestionSuppressionKey(action: "dismissed_action", target: "other"),
        ], createdAt: later.addingTimeInterval(120))
        let directResult = try await store.shown(direct, now: later.addingTimeInterval(60),
                                                 directlyRequested: true)
        let unrelatedResult = try await store.shown(unrelated, now: later.addingTimeInterval(120))
        let outcomes = await store.events(cardID: first.cardID).map(\.outcome)

        XCTAssertNil(result)
        XCTAssertNotNil(directResult)
        XCTAssertNotNil(unrelatedResult)
        XCTAssertEqual(outcomes, [.shown, .declined])
    }

    func testLateResultsCannotReviveDismissedOrSupersededTurns() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SuggestionStore(rootDirectory: root)
        let scope = scope()
        let dismissedTurn = UUID()
        let original = makeCard(scope: scope, turnID: dismissedTurn)
        _ = try await store.shown(original, now: now)
        try await store.dismiss(cardID: original.cardID, now: now)
        let lateAfterDismiss = makeCard(scope: scope, turnID: dismissedTurn)

        let cancelledTurn = UUID()
        try await store.supersede(turnID: cancelledTurn, scope: scope, now: now)
        let lateAfterCancel = makeCard(scope: scope, turnID: cancelledTurn)
        let newTurn = makeCard(scope: scope, turnID: UUID(), keys: [
            SuggestionSuppressionKey(action: "other", target: "other"),
        ])
        _ = try await store.shown(newTurn, now: now.addingTimeInterval(60))

        let dismissedLateResult = try await store.shown(lateAfterDismiss, now: now.addingTimeInterval(120))
        let cancelledLateResult = try await store.shown(lateAfterCancel, now: now.addingTimeInterval(120))
        let newOutcome = await store.outcome(cardID: newTurn.cardID)
        XCTAssertNil(dismissedLateResult)
        XCTAssertNil(cancelledLateResult)
        XCTAssertEqual(newOutcome, .shown)
    }

    func testAccountAndConversationScopesIsolateCardsAndSuppression() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SuggestionStore(rootDirectory: root)
        let accountA = scope()
        let accountB = SuggestionScope(conversationID: accountA.conversationID,
                                       principal: accountA.principal, accountID: "account-b")
        let otherConversation = SuggestionScope(conversationID: UUID(), principal: accountA.principal,
                                                accountID: accountA.accountID)
        let key = SuggestionSuppressionKey(action: "draft", target: "thread-42")
        let dismissed = makeCard(scope: accountA, keys: [key])
        _ = try await store.shown(dismissed, now: now)
        try await store.dismiss(cardID: dismissed.cardID, now: now)
        let otherAccountCard = makeCard(scope: accountB, keys: [key])
        let otherConversationCard = makeCard(scope: otherConversation, keys: [key])

        _ = try await store.shown(otherAccountCard, now: now)
        _ = try await store.shown(otherConversationCard, now: now)
        let accountALoaded = try await store.outstanding(scope: accountA, now: now)
        let accountBLoaded = try await store.outstanding(scope: accountB, now: now)
        let otherConversationLoaded = try await store.outstanding(scope: otherConversation, now: now)

        XCTAssertTrue(accountALoaded.isEmpty)
        XCTAssertEqual(accountBLoaded.map(\.cardID), [otherAccountCard.cardID])
        XCTAssertEqual(otherConversationLoaded.map(\.cardID), [otherConversationCard.cardID])
    }

    func testStaleAndExpiredCardsAreNotOutstanding() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SuggestionStore(rootDirectory: root)
        let scope = scope()
        let stale = makeCard(scope: scope, createdAt: now.addingTimeInterval(-600),
                             expiresAt: now.addingTimeInterval(-1))
        let staleResult = try await store.shown(stale, now: now)
        XCTAssertNil(staleResult)

        let expiring = makeCard(scope: scope, turnID: UUID(), createdAt: now,
                                expiresAt: now.addingTimeInterval(60))
        _ = try await store.shown(expiring, now: now)
        let loaded = try await store.outstanding(scope: scope, now: now.addingTimeInterval(61))
        let outcome = await store.outcome(cardID: expiring.cardID)
        let outcomes = await store.events(cardID: expiring.cardID).map(\.outcome)
        XCTAssertTrue(loaded.isEmpty)
        XCTAssertEqual(outcome, .expired)
        XCTAssertEqual(outcomes, [.shown, .expired])
    }

    func testLegacyMigrationKeepsSameTurnSuppressionAndUnknownOutcome() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dismissedTurn = UUID()
        let openTurn = UUID()
        let legacy = [
            ConversationSuggestion(turnID: dismissedTurn, options: ["旧建议"], dismissed: true),
            ConversationSuggestion(turnID: openTurn, options: ["仍可见"], dismissed: false),
        ]
        let data = try JSONEncoder().encode(legacy)
        try data.write(to: root.appendingPathComponent("conversation-suggestions.json"))

        let migrated = SuggestionStore(rootDirectory: root)
        let dismissedOutcome = await migrated.legacyOutcome(turnID: dismissedTurn)
        let openOutcome = await migrated.legacyOutcome(turnID: openTurn)
        let dismissed = await migrated.isDismissed(turnID: dismissedTurn)
        let dismissedOptions = await migrated.options(for: dismissedTurn)
        let openOptions = await migrated.options(for: openTurn)
        XCTAssertEqual(dismissedOutcome, .unknown)
        XCTAssertEqual(openOutcome, .unknown)
        XCTAssertTrue(dismissed)
        XCTAssertNil(dismissedOptions)
        XCTAssertEqual(openOptions, ["仍可见"])
        try await migrated.save(turnID: dismissedTurn, options: ["迟到结果"])
        let lateOptions = await migrated.options(for: dismissedTurn)
        XCTAssertNil(lateOptions)

        let reopened = SuggestionStore(rootDirectory: root)
        let reopenedOutcome = await reopened.legacyOutcome(turnID: dismissedTurn)
        let reopenedDismissed = await reopened.isDismissed(turnID: dismissedTurn)
        XCTAssertEqual(reopenedOutcome, .unknown)
        XCTAssertTrue(reopenedDismissed)
        let disk = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("conversation-suggestions.json"))) as? [String: Any]
        XCTAssertEqual(disk?["schemaVersion"] as? Int, 2)
    }

    private func metadata() -> SuggestionHostMetadata {
        SuggestionHostMetadata(accountID: "account-a", createdAt: now, expiresAt: now.addingTimeInterval(600))
    }

    private func scope() -> SuggestionScope {
        SuggestionScope(conversationID: UUID(), principal: "owner", accountID: "account-a")
    }

    private func makeCard(scope: SuggestionScope, turnID: UUID = UUID(),
                          kind: SuggestionKind = .nextSteps, question: String = "要继续吗？",
                          options: [SuggestionOption]? = nil,
                          allowCustom: Bool = false, dismissOnMoveOn: Bool = true,
                          keys: [SuggestionSuppressionKey]? = nil,
                          createdAt: Date? = nil, expiresAt: Date? = nil) -> SuggestionCard {
        SuggestionCard(conversationID: scope.conversationID, turnID: turnID, principal: scope.principal,
                       accountID: scope.accountID, createdAt: createdAt ?? now, expiresAt: expiresAt,
                       suppressionKeys: keys ?? [SuggestionSuppressionKey(action: "draft", target: "thread-42")],
                       kind: kind, question: question,
                       options: options ?? [SuggestionOption(id: "next", label: "起草回复",
                                                             userRequest: "请起草回复，不要发送")],
                       allowCustom: allowCustom, dismissOnMoveOn: dismissOnMoveOn)
    }

    private func card(from result: SuggestionGenerationResult) throws -> SuggestionCard {
        guard case .card(let card) = result else {
            XCTFail("expected card, got \(result)")
            throw SuggestionValidationError.invalid("missing test card")
        }
        return card
    }

    private func optionJSON(id: String, label: String) -> [String: Any] {
        ["id": id, "label": label, "user_request": "请起草回复，不要发送"]
    }

    private func proposalJSON(options: [[String: Any]]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [
            "kind": "next_steps", "question": "要继续吗？", "options": options,
            "allow_custom": false, "dismiss_on_move_on": true, "multi_select": false,
        ])
        return String(decoding: data, as: UTF8.self)
    }

    private func structuredReply(_ json: String) -> PA_RuntimeTransportReply {
        pa_runtimeToolResponse(name: "suggest_card", inputJSON: json)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PA-SuggestionLifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
