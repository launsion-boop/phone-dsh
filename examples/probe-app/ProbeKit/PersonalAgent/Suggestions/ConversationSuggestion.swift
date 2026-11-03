// SPDX-License-Identifier: MIT

import Foundation

public struct ConversationSuggestion: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let turnID: UUID
    public var options: [String]
    public var dismissed: Bool

    public init(id: UUID = UUID(), turnID: UUID, options: [String], dismissed: Bool = false) {
        self.id = id
        self.turnID = turnID
        self.options = options
        self.dismissed = dismissed
    }
}

public protocol SuggestionGenerating: Sendable {
    func generate(turn: MainTurnInput, answer: AssistantMessage) async throws -> [String]
}
