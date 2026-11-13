// SPDX-License-Identifier: MIT
// Markdown AST cache.
//
// A finalized message is parsed once: the key carries its item id, content
// revision and parser version. A streaming tail reuses one slot per item, so
// every delta replaces that slot instead of growing the cache (and no SHA-256
// is run over the growing text). Only callers without an item id fall back to
// a content hash key.
//
// Streaming revisions also carry the incremental parser: it freezes the blocks
// of a stable blank-line prefix and re-parses only the tail, so a delta does
// not re-parse the whole growing message.

import Foundation
import ProbeKit

final class NativeMarkdownParseCache {
    static let shared = NativeMarkdownParseCache()
    static let parserVersion = 2
    static let countLimit = 256
    static let totalCostLimit = 32 * 1024 * 1024

    private final class Entry {
        var revision: Int
        var source: String
        var blocks: [NativeMarkdownBlock]
        /// Present for streaming entries; `nil` for finalized messages.
        var incremental: NativeMarkdownIncrementalParser?

        init(revision: Int, source: String, blocks: [NativeMarkdownBlock],
             incremental: NativeMarkdownIncrementalParser?) {
            self.revision = revision
            self.source = source
            self.blocks = blocks
            self.incremental = incremental
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
        // One lookup per call keeps the hit/miss counters exactly as before.
        let existing = cache.value(forKey: key)
        if let existing, existing.revision == revision {
            return existing.blocks
        }

        MainThreadHangMonitor.mark("markdownParse.start")
        let blocks: [NativeMarkdownBlock]
        var incremental: NativeMarkdownIncrementalParser?
        if streaming, !itemID.isEmpty {
            var parser: NativeMarkdownIncrementalParser
            if let existing, let prior = existing.incremental,
               source.utf8.count >= existing.source.utf8.count,
               source.hasPrefix(existing.source) {
                // Append-only: hand the new suffix to the existing prefix
                // state instead of starting over.
                parser = prior
                // Release the cache's copy of the previous materialized tail;
                // otherwise the plain-paragraph append below is copy-on-write.
                existing.blocks = []
                let offset = existing.source.utf8.count
                let delta = String(decoding: source.utf8.dropFirst(offset), as: UTF8.self)
                _ = parser.append(delta)
            } else {
                parser = NativeMarkdownIncrementalParser()
                _ = parser.append(source)
            }
            blocks = parser.blocks
            incremental = parser
        } else {
            blocks = NativeMarkdownParser.parse(source, streaming: streaming)
        }
        MainThreadHangMonitor.mark("markdownParse.end")

        lock.lock(); parseCount += 1; lock.unlock()
        NativePerfCounters.shared.markdownParsed()
        cache.insert(Entry(revision: revision, source: source, blocks: blocks,
                           incremental: incremental),
                     forKey: key,
                     cost: estimatedCost(source: source, blocks: blocks, streaming: streaming))
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

    private func estimatedCost(source: String, blocks: [NativeMarkdownBlock],
                               streaming: Bool) -> Int {
        // UTF-8 bytes are the dominant cost; a small per-block allowance keeps
        // the estimate honest for deeply structured documents. A streaming
        // entry also holds the full text, the mutable tail and the plain-text
        // buffer, so it is deliberately charged more than a final AST.
        let copies = streaming ? 4 : 2
        return source.utf8.count * copies + blocks.count * 64
    }
}
