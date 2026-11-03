// SPDX-License-Identifier: MIT

import Foundation

public struct SuggestionStoreHistoryAdapter: SuggestionHistoryProviding {
    public let store: SuggestionStore

    public init(store: SuggestionStore) {
        self.store = store
    }

    public func suggestionHistory(principal: String, accountScope: String?, canonicalKey: String?,
                                  limit: Int) async throws -> [SuggestionHistoryEntry] {
        await store.historyEntries(principal: principal, accountScope: accountScope,
                                   canonicalKey: canonicalKey, limit: limit)
    }

    public func recordSuggestion(_ entry: SuggestionHistoryEntry) async throws -> SuggestionHistoryEntry {
        try await store.recordHistory(entry)
        return entry
    }
}
