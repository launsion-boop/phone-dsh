// SPDX-License-Identifier: MIT
// Markdown AST cache.
//
// A finalized message is parsed once: the key carries its item id, content
// revision and parser version. A streaming tail reuses one slot per item, so
// every delta replaces that slot instead of growing the cache (and no SHA-256
// is run over the growing text). Only callers without an item id fall back to
// a content hash key.

import Foundation

final class NativeMarkdownParseCache {
    static let shared = NativeMarkdownParseCache()
    static let parserVersion = 1
    static let countLimit = 256
    static let totalCostLimit = 32 * 1024 * 1024

    private final class Entry {
        let revision: Int
        let blocks: [NativeMarkdownBlock]
        init(revision: Int, blocks: [NativeMarkdownBlock]) {
            self.revision = revision
            self.blocks = blocks
        }
    }

    private let cache: NativeBoundedCache<String, Entry>
    private let lock = NSLock()
    private(set) var parseCount = 0

    init(countLimit: Int = NativeMarkdownParseCache.countLimit,
         totalCostLimit: Int = NativeMarkdownParseCache.totalCostLimit) {
        cache = NativeBoundedCache(name: "NativeMarkdownParseCache",
                                   countLimit: countLimit,
                                   totalCostLimit: totalCostLimit)
    }

    var count: Int { cache.count }
    var approximateCost: Int { cache.approximateCost }
    var hitCount: Int { cache.hitCount }
    var missCount: Int { cache.missCount }

    func blocks(for source: String, itemID: String, revision: Int, streaming: Bool) -> [NativeMarkdownBlock] {
        let key = cacheKey(source: source, itemID: itemID, streaming: streaming)
        if let entry = cache.value(forKey: key), entry.revision == revision {
            return entry.blocks
        }
        let blocks = NativeMarkdownParser.parse(source, streaming: streaming)
        lock.lock(); parseCount += 1; lock.unlock()
        NativePerfCounters.shared.markdownParsed()
        cache.insert(Entry(revision: revision, blocks: blocks),
                     forKey: key,
                     cost: estimatedCost(source: source, blocks: blocks))
        return blocks
    }

    func removeAll() {
        cache.removeAll()
    }

    private func cacheKey(source: String, itemID: String, streaming: Bool) -> String {
        let kind = streaming ? "stream" : "final"
        if itemID.isEmpty {
            // Parse-only previews still get a repeat hit, but nothing on the
            // streaming transcript path hashes the whole message text.
            return "hash:\(NativeStableHash.fnv1a64(source)):\(kind):v\(Self.parserVersion)"
        }
        return "\(itemID):\(kind):v\(Self.parserVersion)"
    }

    private func estimatedCost(source: String, blocks: [NativeMarkdownBlock]) -> Int {
        // UTF-8 bytes are the dominant cost; a small per-block allowance keeps
        // the estimate honest for deeply structured documents.
        source.utf8.count * 2 + blocks.count * 64
    }
}
