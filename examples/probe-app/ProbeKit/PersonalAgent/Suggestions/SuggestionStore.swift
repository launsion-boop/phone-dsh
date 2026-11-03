// SPDX-License-Identifier: MIT

import Foundation

public actor SuggestionStore {
    private let fileURL: URL
    private var suggestions: [UUID: ConversationSuggestion]

    public init(rootDirectory: URL) {
        self.fileURL = rootDirectory.appendingPathComponent("conversation-suggestions.json")
        if let data = try? Data(contentsOf: fileURL),
           let restored = try? JSONDecoder().decode([ConversationSuggestion].self, from: data) {
            self.suggestions = Dictionary(restored.map { ($0.turnID, $0) }, uniquingKeysWith: { _, last in last })
        } else {
            self.suggestions = [:]
        }
    }

    public func options(for turnID: UUID) -> [String]? {
        guard let suggestion = suggestions[turnID], !suggestion.dismissed else { return nil }
        return suggestion.options
    }

    public func save(turnID: UUID, options: [String]) throws {
        let existing = suggestions[turnID]
        let suggestion = ConversationSuggestion(id: existing?.id ?? UUID(), turnID: turnID,
                                                options: options, dismissed: existing?.dismissed ?? false)
        var updated = suggestions
        updated[turnID] = suggestion
        try persist(updated)
        suggestions = updated
    }

    public func dismiss(turnID: UUID) throws {
        let existing = suggestions[turnID]
        let suggestion = ConversationSuggestion(id: existing?.id ?? UUID(), turnID: turnID,
                                                options: existing?.options ?? [], dismissed: true)
        var updated = suggestions
        updated[turnID] = suggestion
        try persist(updated)
        suggestions = updated
    }

    public func isDismissed(turnID: UUID) -> Bool {
        suggestions[turnID]?.dismissed ?? false
    }

    private func persist(_ values: [UUID: ConversationSuggestion]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(values.values.sorted { $0.turnID.uuidString < $1.turnID.uuidString })
        try data.write(to: fileURL, options: .atomic)
    }
}
