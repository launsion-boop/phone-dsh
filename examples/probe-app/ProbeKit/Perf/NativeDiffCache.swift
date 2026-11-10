// SPDX-License-Identifier: MIT
// Diff caches.
//
// `NativeTranscriptProjector` short-circuits the LCS DP table above 300 lines
// on either side (a 5000×5000 edit used to allocate ~25M Ints). This file keeps
// the resulting per-turn facts and the small-diff counts bounded.

import Foundation

public struct NativeDiffLineCounts: Equatable {
    public let added: Int
    public let deleted: Int
}

struct NativeDiffLineCountsKey: Hashable {
    let oldHash: UInt64
    let newHash: UInt64
    let oldLineCount: Int
    let newLineCount: Int
}

public final class NativeDiffLineCountsCache {
    static let shared = NativeDiffLineCountsCache()
    public static let lcsLineLimit = 300
    public static let countLimit = 512
    public static let totalCostLimit = 1 * 1024 * 1024

    let cache: NativeBoundedCache<NativeDiffLineCountsKey, NativeDiffLineCounts>
    public private(set) var lcsRuns = 0
    public private(set) var shortCircuits = 0

    public init(countLimit: Int = NativeDiffLineCountsCache.countLimit,
         totalCostLimit: Int = NativeDiffLineCountsCache.totalCostLimit) {
        cache = NativeBoundedCache(name: "NativeDiffLineCountsCache",
                                   countLimit: countLimit,
                                   totalCostLimit: totalCostLimit)
    }

    public func counts(old: String?, new: String) -> NativeDiffLineCounts {
        let oldText = old ?? ""
        let oldLines = oldText.components(separatedBy: .newlines)
        let newLines = new.components(separatedBy: .newlines)
        let key = NativeDiffLineCountsKey(
            oldHash: NativeStableHash.fnv1a64(oldText),
            newHash: NativeStableHash.fnv1a64(new),
            oldLineCount: oldLines.count,
            newLineCount: newLines.count)
        if let cached = cache.value(forKey: key) {
            return cached
        }

        let result: NativeDiffLineCounts
        if oldLines.count > Self.lcsLineLimit || newLines.count > Self.lcsLineLimit {
            // OOM guard: never build the O(m×n) table. The caller only needs
            // added/deleted counts, which the fallback reports as whole-side
            // counts (the same convention as "old side absent" in the LCS
            // path: an empty old string still counts as its one empty line).
            shortCircuits += 1
            result = NativeDiffLineCounts(added: newLines.count, deleted: oldLines.count)
        } else {
            lcsRuns += 1
            NativePerfCounters.shared.lcsComputed()
            result = Self.lcsCounts(oldLines: oldLines, newLines: newLines)
        }
        cache.insert(result, forKey: key, cost: 64 + oldText.utf8.count / 8 + new.utf8.count / 8)
        return result
    }

    public func resetForTesting() {
        cache.removeAll()
        lcsRuns = 0
        shortCircuits = 0
    }

    /// The original LCS table, retained for small diffs and as the test oracle.
    static func lcsCounts(oldLines: [String], newLines: [String]) -> NativeDiffLineCounts {
        var table = Array(repeating: Array(repeating: 0, count: newLines.count + 1),
                          count: oldLines.count + 1)
        if oldLines.count > 0, newLines.count > 0 {
            for i in stride(from: oldLines.count - 1, through: 0, by: -1) {
                for j in stride(from: newLines.count - 1, through: 0, by: -1) {
                    table[i][j] = oldLines[i] == newLines[j]
                        ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        let common = table[0][0]
        return NativeDiffLineCounts(added: newLines.count - common,
                                    deleted: oldLines.count - common)
    }
}

/// Per-turn `changes` facts keyed by the turn's contributing row versions.
public final class NativeChangesCache {
    public static let shared = NativeChangesCache()
    public static let countLimit = 256
    public static let totalCostLimit = 16 * 1024 * 1024

    private final class Entry {
        let changes: NativeChangedFiles?
        let cost: Int
        init(changes: NativeChangedFiles?, cost: Int) {
            self.changes = changes
            self.cost = cost
        }
    }

    struct Key: Hashable {
        let turn: Int
        let signature: String
    }

    private let cache: NativeBoundedCache<Key, Entry>
    public private(set) var missCount = 0

    public init(countLimit: Int = NativeChangesCache.countLimit,
         totalCostLimit: Int = NativeChangesCache.totalCostLimit) {
        cache = NativeBoundedCache(name: "NativeChangesCache",
                                   countLimit: countLimit,
                                   totalCostLimit: totalCostLimit)
    }

    public func changes(forTurn turn: Int, signature: String,
                 compute: () -> NativeChangedFiles?) -> NativeChangedFiles? {
        let key = Key(turn: turn, signature: signature)
        if let entry = cache.value(forKey: key) {
            return entry.changes
        }
        missCount += 1
        let changes = compute()
        cache.insert(Entry(changes: changes, cost: Self.estimatedCost(changes)),
                     forKey: key, cost: Self.estimatedCost(changes))
        return changes
    }

    public func removeAll() {
        cache.removeAll()
    }

    public func resetForTesting() {
        cache.removeAll()
        missCount = 0
    }

    private static func estimatedCost(_ changes: NativeChangedFiles?) -> Int {
        guard let changes else { return 1 }
        return changes.files.reduce(0) { total, file in
            total + (file.oldText?.utf8.count ?? 0) + file.newText.utf8.count + 256
        }
    }
}
