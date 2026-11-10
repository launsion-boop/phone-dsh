// SPDX-License-Identifier: MIT
// Bounded one-line summaries for thinking and tool rows.
//
// Both used to split the whole text/output on every body pass. The key is the
// item id plus `renderRevision`, so a streamed delta or a tool result recomputes
// once and every later body pass (including a re-created row view) hits.

import Foundation

final class NativeRowSummaryCache {
    static let shared = NativeRowSummaryCache()
    static let countLimit = 1024
    static let totalCostLimit = 4 * 1024 * 1024

    private let cache: NativeBoundedCache<String, String>
    private(set) var missCount = 0

    init(countLimit: Int = NativeRowSummaryCache.countLimit,
         totalCostLimit: Int = NativeRowSummaryCache.totalCostLimit) {
        cache = NativeBoundedCache(name: "NativeRowSummaryCache",
                                   countLimit: countLimit,
                                   totalCostLimit: totalCostLimit)
    }

    func toolSummary(for item: ChatItem, compute: () -> String) -> String {
        cached(key: "tool|\(item.id)|\(item.renderRevision)", compute: compute)
    }

    func thinkingSummary(for item: ChatItem) -> String {
        cached(key: "think|\(item.id)|\(item.renderRevision)|\(item.streaming ? 1 : 0)") {
            Self.makeThinkingSummary(item.text, streaming: item.streaming)
        }
    }

    func removeAll() {
        cache.removeAll()
    }

    func resetForTesting() {
        cache.removeAll()
        missCount = 0
    }

    private func cached(key: String, compute: () -> String) -> String {
        if let cached = cache.value(forKey: key) {
            return cached
        }
        missCount += 1
        let value = compute()
        cache.insert(value, forKey: key, cost: value.utf8.count * 2 + 64)
        return value
    }

    /// Original `NativeThinkingRow` summary rule, retained verbatim.
    static func makeThinkingSummary(_ text: String, streaming: Bool) -> String {
        let raw = streaming ? streamingSummary(text) : (text.components(separatedBy: "\n").first ?? "")
        return raw.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func streamingSummary(_ text: String) -> String {
        var summary = ""
        for paragraph in text.components(separatedBy: "\n\n") {
            if let newline = paragraph.firstIndex(of: "\n") {
                let first = paragraph[..<newline].trimmingCharacters(in: .whitespaces)
                if !first.isEmpty { summary = first }
            }
        }
        return summary
    }
}
