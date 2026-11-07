// SPDX-License-Identifier: MIT

import Foundation

/// Plans one durable user action. Chat, approvals and task stops still go through the
/// real DSH remote runtime first; card answers and dismissals are validated against the
/// durable `card.presented` history and commit a `card.answered` / `card.dismissed` event.
public actor BotRemoteActionPlanner: BotUserActionPlanning {
    private struct CardChoice: Sendable, Equatable {
        var id: String
        var label: String
        var value: String
    }

    private struct CardState: Sendable, Equatable {
        var id: String
        var kind: String
        var title: String?
        var choices: [CardChoice]
        var sessionID: String?
        var eventID: String
        var answeredOptionID: String?
        var dismissed: Bool
        var expired: Bool
    }

    private let remote: BotDSHRemoteRuntime
    private let runtime: BotMCPRuntime
    private let handler: BotMCPHandler
    private let store: SQLiteDomainStore
    private let botID: String
    private let wakeInbox: WakeInbox
    private let now: @Sendable () -> Int64
    /// Card ids with an answer turn in flight. The actor is re-entrant at every
    /// `await`, so the durable `answeredOptionID` check alone lets two
    /// concurrent taps both start a turn. The first caller owns the card until
    /// it commits or throws; the second one is stale without a side effect.
    private var answeringCards: Set<String> = []

    public init(remote: BotDSHRemoteRuntime, runtime: BotMCPRuntime,
                handler: BotMCPHandler, store: SQLiteDomainStore, botID: String,
                wakeInbox: WakeInbox? = nil,
                now: @escaping @Sendable () -> Int64 = {
                    Int64(Date().timeIntervalSince1970 * 1_000)
                }) {
        self.remote = remote
        self.runtime = runtime
        self.handler = handler
        self.store = store
        self.botID = botID
        self.wakeInbox = wakeInbox ?? WakeInbox(
            store: SQLiteWakeInboxStore(domainStore: store, botId: botID))
        self.now = now
    }

    public func plan(_ action: BotUserAction, trust: BotUserActionTrust) async throws -> BotUserActionPlanOutcome {
        guard trust == .ownerDirect, action.botID == botID else {
            return .rejected(reason: "untrusted_action")
        }
        switch action.kind {
        case .chat:
            guard let text = action.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return .rejected(reason: "missing_text")
            }
            return try await complete(action, result: remote.sendUserMessage(
                text, requestId: "user-action:\(action.nonce)"))
        case .cardAnswer:
            guard action.text == nil else {
                return .rejected(reason: "unexpected_card_answer_field")
            }
            guard let cardID = action.cardID, !cardID.isEmpty,
                  let optionID = action.optionID, !optionID.isEmpty else {
                return .rejected(reason: "invalid_card_answer")
            }
            // Reserve before the first await: a second concurrent plan sees the
            // card in flight and returns stale instead of starting a turn.
            guard answeringCards.insert(cardID).inserted else {
                return .stale(reason: "answer_in_flight")
            }
            defer { answeringCards.remove(cardID) }
            guard let card = try await cardState(cardID) else {
                return .stale(reason: "unknown_card")
            }
            guard card.kind == "question" || card.kind == "steps" else {
                return .stale(reason: "unknown_card")
            }
            if card.answeredOptionID != nil { return .stale(reason: "already_answered") }
            if card.dismissed { return .stale(reason: "card_dismissed") }
            if card.expired { return .stale(reason: "card_expired") }
            guard let option = card.choices.first(where: { $0.id == optionID }) else {
                return .stale(reason: "unknown_option")
            }
            let result = try await remote.sendUserMessage(
                option.value, requestId: "card-answer:\(action.nonce)")
            guard result.status == "completed" else {
                return .rejected(reason: result.error ?? "turn_not_completed")
            }
            // The remote turn is a side effect outside the SQLite plan. Re-read the
            // durable card state so a concurrent answer cannot commit twice.
            if let latest = try await cardState(cardID) {
                if latest.answeredOptionID != nil { return .stale(reason: "already_answered") }
                if latest.dismissed { return .stale(reason: "card_dismissed") }
            }
            return try await acceptCard(
                action, card: card, turnID: result.turnId,
                extra: [
                    "optionID": .string(option.id),
                    "label": .string(option.label),
                    "value": .string(option.value),
                ])
        case .cardDismiss:
            guard let cardID = action.cardID, !cardID.isEmpty else {
                return .rejected(reason: "missing_card_id")
            }
            guard let card = try await cardState(cardID) else {
                return .stale(reason: "unknown_card")
            }
            guard card.kind == "question" else {
                return .rejected(reason: "only_question_cards_can_be_dismissed")
            }
            if card.answeredOptionID != nil { return .stale(reason: "already_answered") }
            if card.dismissed { return .stale(reason: "card_dismissed") }
            if card.expired { return .stale(reason: "card_expired") }
            try await enqueueDismissedCard(card)
            return try await acceptCard(action, card: card, turnID: nil, extra: [:])
        case .approval:
            guard let approvalID = action.approvalID, let decision = action.decision,
                  let digest = action.digest else { return .rejected(reason: "invalid_approval") }
            switch await handler.resolveApproval(approvalId: approvalID, decision: decision, digest: digest) {
            case .resolved:
                return try await accept(action, turnID: nil)
            case .stale(let reason):
                return .stale(reason: reason)
            }
        case .stopTask:
            guard let threadID = action.threadID else { return .rejected(reason: "missing_thread_id") }
            let stopped = try await remote.stopTaskFromUser(taskID: threadID)
            guard stopped.status == "stopped" else { return .rejected(reason: stopped.error ?? "task_not_stopped") }
            return try await accept(action, turnID: nil)
        }
    }

    private func complete(_ action: BotUserAction,
                          result: BotRemoteTurnResult) async throws -> BotUserActionPlanOutcome {
        guard result.status == "completed" else {
            return .rejected(reason: result.error ?? "turn_not_completed")
        }
        return try await accept(action, turnID: result.turnId)
    }

    private func accept(_ action: BotUserAction, turnID: String?) async throws -> BotUserActionPlanOutcome {
        guard let sessionID = await remote.mainSessionIdentifier() else {
            throw BotMCPError.unavailable("main session unavailable")
        }
        let event = BotEvent(
            type: "conversation.turn_started", eventId: "action:\(action.nonce)", time: now(),
            origin: .local(source: "user"), traceId: "action:\(action.nonce)",
            principal: BotPrincipal(botId: botID, sessionId: sessionID, kind: "chat"),
            causationId: nil, correlationId: action.nonce, turnId: turnID,
            data: .object([
                "action": .string(action.kind.rawValue), "nonce": .string(action.nonce),
                "ownerDirect": .bool(true),
            ]))
        return .commit(BotUserActionPlan(event: event))
    }

    private func acceptCard(_ action: BotUserAction, card: CardState, turnID: String?,
                            extra: [String: BotJSONValue]) async throws -> BotUserActionPlanOutcome {
        let sessionID: String?
        if let existing = card.sessionID {
            sessionID = existing
        } else {
            sessionID = await remote.mainSessionIdentifier()
        }
        var data: [String: BotJSONValue] = [
            "action": .string(action.kind.rawValue),
            "nonce": .string(action.nonce),
            "ownerDirect": .bool(true),
            "cardID": .string(card.id),
            "cardType": .string(card.kind),
        ]
        if let title = card.title { data["title"] = .string(title) }
        data.merge(extra) { _, new in new }
        let type = action.kind == .cardDismiss ? "card.dismissed" : "card.answered"
        let event = BotEvent(
            type: type, eventId: "action:\(action.nonce)", time: now(),
            origin: .local(source: "card-bridge"), traceId: "action:\(action.nonce)",
            principal: BotPrincipal(botId: botID, sessionId: sessionID, kind: "chat"),
            causationId: card.eventID, correlationId: action.nonce, turnId: turnID,
            data: .object(data))
        return .commit(BotUserActionPlan(event: event))
    }

    private func enqueueDismissedCard(_ card: CardState) async throws {
        let title = String((card.title ?? card.id).prefix(200))
        let text = "用户关闭了提问卡「\(title)」，视为不回答；不要在同一话题重问。"
        let item = try WakeInboxItem(
            id: "card-dismissed:\(card.id)", kind: "card-dismissed",
            fromAgentName: "card-bridge", title: title, text: text,
            requestId: "card-dismissed:\(card.id)", createdAt: now())
        // Dismissal must still succeed when the held inbox is full or unavailable;
        // the durable card.dismissed event remains the authority.
        _ = try? await wakeInbox.enqueue(item)
    }

    private func cardState(_ id: String) async throws -> CardState? {
        var cards: [String: CardState] = [:]
        var open: [String] = []
        var cursor = 0
        while true {
            let events = try await store.events(after: cursor, limit: 500)
            for event in events where event.principal.botId == nil || event.principal.botId == botID {
                guard case .object(let data) = event.data else { continue }
                switch event.type {
                case "card.presented":
                    let cardID = string(data["id"]) ?? string(data["rowID"]) ?? "e-ui-\(event.eventId)"
                    let card = object(data["card"]) ?? data
                    let kind = string(data["cardType"]) ?? string(card["cardType"])
                        ?? string(data["kind"]) ?? string(card["kind"])
                    guard let kind, kind == "question" || kind == "steps" else { continue }
                    for openID in open { cards[openID]?.expired = true }
                    open.removeAll()
                    let rawChoices = array(data[kind == "question" ? "options" : "steps"])
                        ?? array(card[kind == "question" ? "options" : "steps"]) ?? []
                    let choices = rawChoices.compactMap(choice)
                    cards[cardID] = CardState(
                        id: cardID, kind: kind,
                        title: string(data["question"]) ?? string(card["question"])
                            ?? string(data["title"]) ?? string(card["title"]),
                        choices: choices, sessionID: event.principal.sessionId,
                        eventID: event.eventId, answeredOptionID: nil,
                        dismissed: false, expired: false)
                    open.append(cardID)
                case "card.answered":
                    guard let cardID = string(data["cardID"]), var card = cards[cardID] else { continue }
                    card.answeredOptionID = string(data["optionID"])
                    cards[cardID] = card
                    open.removeAll { $0 == cardID }
                case "card.dismissed":
                    guard let cardID = string(data["cardID"]), var card = cards[cardID] else { continue }
                    card.dismissed = true
                    cards[cardID] = card
                    open.removeAll { $0 == cardID }
                default:
                    continue
                }
            }
            guard events.count == 500, let last = events.last?.commitSeq else { break }
            cursor = last
        }
        return cards[id]
    }

    private func choice(_ value: BotJSONValue) -> CardChoice? {
        guard let object = object(value),
              let id = string(object["id"]) ?? string(object["optionId"]), !id.isEmpty else { return nil }
        let label = string(object["label"]) ?? id
        return CardChoice(id: id, label: label, value: string(object["value"]) ?? label)
    }

    private func object(_ value: BotJSONValue?) -> [String: BotJSONValue]? {
        guard case .object(let object)? = value else { return nil }
        return object
    }

    private func array(_ value: BotJSONValue?) -> [BotJSONValue]? {
        guard case .array(let values)? = value else { return nil }
        return values
    }

    private func string(_ value: BotJSONValue?) -> String? {
        guard case .string(let text)? = value, !text.isEmpty else { return nil }
        return text
    }
}
