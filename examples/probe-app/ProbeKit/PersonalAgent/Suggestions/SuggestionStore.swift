// SPDX-License-Identifier: MIT

import Foundation

public enum SuggestionStoreError: Error, Sendable, Equatable {
    case selectionEventConflict
    case unreadableState
}

public actor SuggestionStore {
    private static let diskSchemaVersion = 2

    private struct LegacyRecord: Codable {
        var suggestion: ConversationSuggestion
        let outcome: SuggestionOutcome
    }

    private struct TurnKey: Codable, Hashable {
        let scope: SuggestionScope
        let turnID: UUID
    }

    private struct DiskState: Codable {
        let schemaVersion: Int
        let cards: [SuggestionCard]
        let events: [SuggestionLifecycleEvent]
        let selections: [SuggestionSelection]
        let legacy: [LegacyRecord]
        let turnTombstones: [TurnKey]
    }

    private struct State {
        var cards: [UUID: SuggestionCard] = [:]
        var events: [SuggestionLifecycleEvent] = []
        var selections: [UUID: SuggestionSelection] = [:]
        var legacy: [UUID: LegacyRecord] = [:]
        var turnTombstones: Set<TurnKey> = []
    }

    private let fileURL: URL
    private let policy: SuggestionPolicy
    private let loadError: Error?
    private var state: State

    public var isHealthy: Bool { loadError == nil }

    public init(rootDirectory: URL, policy: SuggestionPolicy = SuggestionPolicy()) {
        self.fileURL = rootDirectory.appendingPathComponent("conversation-suggestions.json")
        self.policy = policy
        self.state = State()
        var recoveredError: Error?
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                if let disk = try? JSONDecoder().decode(DiskState.self, from: data),
                   disk.schemaVersion == Self.diskSchemaVersion {
                    var restored = State()
                    restored.cards = Dictionary(disk.cards.map { ($0.cardID, $0) }, uniquingKeysWith: { _, last in last })
                    restored.events = disk.events
                    restored.selections = Dictionary(disk.selections.map { ($0.selectionEventID, $0) },
                                                     uniquingKeysWith: { _, last in last })
                    restored.legacy = Dictionary(disk.legacy.map { ($0.suggestion.turnID, $0) },
                                                 uniquingKeysWith: { _, last in last })
                    restored.turnTombstones = Set(disk.turnTombstones)
                    self.state = restored
                } else if let legacy = try? JSONDecoder().decode([ConversationSuggestion].self, from: data) {
                    var migrated = State()
                    migrated.legacy = Dictionary(legacy.map {
                        ($0.turnID, LegacyRecord(suggestion: $0, outcome: .unknown))
                    }, uniquingKeysWith: { _, last in last })
                    self.state = migrated
                } else {
                    recoveredError = SuggestionStoreError.unreadableState
                }
            } catch {
                recoveredError = error
            }
        }
        self.loadError = recoveredError
    }

    @discardableResult
    public func shown(_ card: SuggestionCard, now: Date = Date(),
                      directlyRequested: Bool = false) throws -> SuggestionCard? {
        try requireHealthy()
        try card.validate()
        guard card.outcome == .shown, now < card.expiresAt else { return nil }
        if let existing = state.cards[card.cardID] {
            return existing.outcome == .shown ? existing : nil
        }
        let turnKey = TurnKey(scope: card.scope, turnID: card.turnID)
        guard !state.turnTombstones.contains(turnKey),
              state.legacy[card.turnID]?.suggestion.dismissed != true,
              !hasTerminalCard(for: turnKey) else { return nil }

        let outstanding = state.cards.values.filter {
            $0.scope == card.scope && $0.outcome == .shown && $0.cardID != card.cardID
        }
        if card.kind == .nextSteps {
            guard !outstanding.contains(where: { $0.kind == .clarification }),
                  directlyRequested || !isSuppressed(card, now: now) else { return nil }
        }

        var updated = state
        for other in outstanding {
            updated.cards[other.cardID]?.outcome = .superseded
            updated.events.append(SuggestionLifecycleEvent(cardID: other.cardID,
                                                           outcome: .superseded, createdAt: now))
        }
        updated.cards[card.cardID] = card
        updated.events.append(SuggestionLifecycleEvent(cardID: card.cardID,
                                                       outcome: .shown, createdAt: now))
        try persist(updated)
        state = updated
        return card
    }

    public func outstanding(scope: SuggestionScope, now: Date = Date()) throws -> [SuggestionCard] {
        try requireHealthy()
        var updated = state
        var changed = false
        for card in state.cards.values where card.scope == scope && card.outcome == .shown && now >= card.expiresAt {
            updated.cards[card.cardID]?.outcome = .expired
            updated.events.append(SuggestionLifecycleEvent(cardID: card.cardID,
                                                           outcome: .expired, createdAt: now))
            changed = true
        }
        if changed {
            try persist(updated)
            state = updated
        }
        return state.cards.values.filter { $0.scope == scope && $0.outcome == .shown }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func select(cardID: UUID, optionID: String, selectionEventID: UUID = UUID(),
                       now: Date = Date()) throws -> SuggestionSelectionResult? {
        try requireHealthy()
        if let existing = state.selections[selectionEventID] {
            guard existing.cardID == cardID, existing.optionID == optionID else {
                throw SuggestionStoreError.selectionEventConflict
            }
            return SuggestionSelectionResult(selection: existing, shouldSend: false)
        }
        guard let card = state.cards[cardID], card.outcome == .shown,
              let option = card.options.first(where: { $0.id == optionID }) else { return nil }
        if now >= card.expiresAt {
            try transition(cardID: cardID, outcome: .expired, now: now)
            return nil
        }
        let selection = SuggestionSelection(selectionEventID: selectionEventID, cardID: cardID,
                                            cardVersion: card.schemaVersion, optionID: option.id,
                                            visibleLabel: option.label, userRequest: option.userRequest,
                                            conversationID: card.conversationID,
                                            principal: card.principal, accountID: card.accountID, createdAt: now,
                                            originalMandate: card.originalMandate)
        var updated = state
        updated.cards[cardID]?.outcome = .selected
        updated.events.append(SuggestionLifecycleEvent(cardID: cardID, outcome: .selected, createdAt: now))
        updated.selections[selectionEventID] = selection
        try persist(updated)
        state = updated
        return SuggestionSelectionResult(selection: selection, shouldSend: true)
    }

    public func dismiss(cardID: UUID, now: Date = Date()) throws {
        try transition(cardID: cardID, outcome: .dismissed, now: now)
    }

    public func decline(cardID: UUID, now: Date = Date()) throws {
        try transition(cardID: cardID, outcome: .declined, now: now)
    }

    public func supersede(cardID: UUID, now: Date = Date()) throws {
        try transition(cardID: cardID, outcome: .superseded, now: now)
    }

    public func supersede(turnID: UUID, scope: SuggestionScope, now: Date = Date()) throws {
        let key = TurnKey(scope: scope, turnID: turnID)
        var updated = state
        updated.turnTombstones.insert(key)
        for card in state.cards.values where card.scope == scope && card.turnID == turnID && card.outcome == .shown {
            updated.cards[card.cardID]?.outcome = .superseded
            updated.events.append(SuggestionLifecycleEvent(cardID: card.cardID,
                                                           outcome: .superseded, createdAt: now))
        }
        try persist(updated)
        state = updated
    }

    public func outcome(cardID: UUID) -> SuggestionOutcome? {
        state.cards[cardID]?.outcome
    }

    public func events(cardID: UUID) -> [SuggestionLifecycleEvent] {
        state.events.filter { $0.cardID == cardID }.sorted { $0.createdAt < $1.createdAt }
    }

    public func suppressionHistory(limit: Int = 32) -> [String] {
        state.events.suffix(max(0, limit)).map { event in
            let keys = state.cards[event.cardID]?.suppressionKeys.map(\.canonical).joined(separator: ",") ?? "legacy"
            return "\(event.outcome.rawValue):\(keys)"
        }
    }

    public func historyEntries(principal: String, accountScope: String?, canonicalKey: String?,
                               limit: Int) -> [SuggestionHistoryEntry] {
        let accountID = accountScope ?? "local"
        let cards = state.cards.filter {
            $0.value.principal == principal && $0.value.accountID == accountID
        }
        let entries = state.events.compactMap { event -> SuggestionHistoryEntry? in
            guard let card = cards[event.cardID],
                  let outcome = SuggestionHistoryOutcome(rawValue: event.outcome.rawValue) else { return nil }
            let key = card.suppressionKeys.first?.canonical ?? ""
            if let canonicalKey, key != canonicalKey { return nil }
            return SuggestionHistoryEntry(id: event.id, principal: principal, accountScope: accountScope,
                                          canonicalKey: key, outcome: outcome, occurredAt: event.createdAt)
        }
        return Array(entries.sorted { $0.occurredAt > $1.occurredAt }.prefix(max(0, limit)))
    }

    public func recordHistory(_ entry: SuggestionHistoryEntry) throws {
        let accountID = entry.accountScope ?? "local"
        if state.cards[entry.id] != nil {
            switch entry.outcome {
            case .shown: return
            case .selected: try transition(cardID: entry.id, outcome: .selected, now: entry.occurredAt)
            case .dismissed: try dismiss(cardID: entry.id, now: entry.occurredAt)
            case .declined: try decline(cardID: entry.id, now: entry.occurredAt)
            case .superseded: try supersede(cardID: entry.id, now: entry.occurredAt)
            case .expired: return
            }
            return
        }
        let key = try Self.suppressionKey(from: entry.canonicalKey)
        let card = SuggestionCard(cardID: entry.id, conversationID: entry.id, turnID: entry.id,
                                  principal: entry.principal, accountID: accountID,
                                  createdAt: entry.occurredAt, suppressionKeys: [key], kind: .clarification,
                                  question: "Interaction history", options: [], allowCustom: true,
                                  dismissOnMoveOn: false, outcome: SuggestionOutcome(rawValue: entry.outcome.rawValue)!)
        var updated = state
        updated.cards[entry.id] = card
        updated.events.append(SuggestionLifecycleEvent(id: entry.id, cardID: entry.id,
                                                       outcome: card.outcome, createdAt: entry.occurredAt))
        try persist(updated)
        state = updated
    }

    public func legacyOutcome(turnID: UUID) -> SuggestionOutcome? {
        state.legacy[turnID]?.outcome
    }

    public nonisolated static func canonicalSuppressionKey(action: String, target: String) -> String {
        SuggestionSuppressionKey.canonical(action: action, target: target)
    }

    public func options(for turnID: UUID) -> [String]? {
        guard let record = state.legacy[turnID], !record.suggestion.dismissed else { return nil }
        return record.suggestion.options
    }

    public func save(turnID: UUID, options: [String]) throws {
        let existing = state.legacy[turnID]?.suggestion
        let suggestion = ConversationSuggestion(id: existing?.id ?? UUID(), turnID: turnID,
                                                options: options, dismissed: existing?.dismissed ?? false)
        var updated = state
        updated.legacy[turnID] = LegacyRecord(suggestion: suggestion, outcome: .unknown)
        try persist(updated)
        state = updated
    }

    public func dismiss(turnID: UUID) throws {
        let existing = state.legacy[turnID]?.suggestion
        let suggestion = ConversationSuggestion(id: existing?.id ?? UUID(), turnID: turnID,
                                                options: existing?.options ?? [], dismissed: true)
        var updated = state
        updated.legacy[turnID] = LegacyRecord(suggestion: suggestion, outcome: .unknown)
        try persist(updated)
        state = updated
    }

    public func isDismissed(turnID: UUID) -> Bool {
        state.legacy[turnID]?.suggestion.dismissed ?? false
    }

    private func hasTerminalCard(for key: TurnKey) -> Bool {
        state.cards.values.contains {
            $0.scope == key.scope && $0.turnID == key.turnID && $0.outcome != .shown
        }
    }

    private func isSuppressed(_ proposal: SuggestionCard, now: Date) -> Bool {
        let keys = Set(proposal.suppressionKeys)
        guard !keys.isEmpty else { return false }
        let matchingCards = state.cards.values.filter {
            $0.scope == proposal.scope && !Set($0.suppressionKeys).isDisjoint(with: keys)
        }
        let cardIDs = Set(matchingCards.map(\.cardID))
        let events = state.events.filter { cardIDs.contains($0.cardID) }
        for event in events {
            let age = now.timeIntervalSince(event.createdAt)
            guard age >= 0 else { continue }
            if event.outcome == .dismissed && age <= policy.dismissCooldown { return true }
            if event.outcome == .declined && age <= policy.declineCooldown { return true }
        }
        let declineCount = events.filter { $0.outcome == .declined }.count
        return declineCount >= policy.stopAfterExplicitDeclines
    }

    private static func suppressionKey(from canonical: String) throws -> SuggestionSuppressionKey {
        let parts = canonical.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "v1",
              let actionData = Data(base64Encoded: String(parts[1])),
              let targetData = Data(base64Encoded: String(parts[2])),
              let action = String(data: actionData, encoding: .utf8),
              let target = String(data: targetData, encoding: .utf8) else {
            throw SuggestionValidationError.invalid("invalid canonical suppression key")
        }
        return SuggestionSuppressionKey(action: action, target: target)
    }

    private func transition(cardID: UUID, outcome: SuggestionOutcome, now: Date) throws {
        try requireHealthy()
        guard let card = state.cards[cardID], card.outcome == .shown else { return }
        var updated = state
        updated.cards[cardID]?.outcome = outcome
        updated.events.append(SuggestionLifecycleEvent(cardID: cardID, outcome: outcome, createdAt: now))
        try persist(updated)
        state = updated
    }

    private func requireHealthy() throws {
        if loadError != nil { throw SuggestionStoreError.unreadableState }
    }

    private func persist(_ state: State) throws {
        try requireHealthy()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let disk = DiskState(
            schemaVersion: Self.diskSchemaVersion,
            cards: state.cards.values.sorted { $0.cardID.uuidString < $1.cardID.uuidString },
            events: state.events.sorted {
                ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
            },
            selections: state.selections.values.sorted {
                $0.selectionEventID.uuidString < $1.selectionEventID.uuidString
            },
            legacy: state.legacy.values.sorted {
                $0.suggestion.turnID.uuidString < $1.suggestion.turnID.uuidString
            },
            turnTombstones: state.turnTombstones.sorted {
                ($0.scope.accountID, $0.scope.principal, $0.scope.conversationID.uuidString, $0.turnID.uuidString)
                    < ($1.scope.accountID, $1.scope.principal, $1.scope.conversationID.uuidString, $1.turnID.uuidString)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(disk)
        try data.write(to: fileURL, options: .atomic)
    }
}
