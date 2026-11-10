// SPDX-License-Identifier: MIT
//
// S1-C.1: coalesce streamed transcript text before mutating `ChatModel.items`.
//
// The hosted session emits assistant/reasoning deltas at the model's token
// rate, which on a loaded phone used to publish one `items` mutation per token
// (and one full timeline invalidation per mutation). This buffer merges
// adjacent deltas that target the same row, and `ChatModel` drains it at
// `ResourceLevel.streamUpdatesPerSecond` while a turn runs. Draining in order
// cannot change the final text: each chunk is appended to the same row the
// per-event path would have appended it to.

import Foundation
import PhoneDSHAgentCore

/// Ordered, run-length-merged streamed text chunks.
struct NativeStreamAccumulator: Equatable {
    struct Chunk: Equatable {
        let itemID: String
        var text: String
    }

    private(set) var chunks: [Chunk] = []

    var isEmpty: Bool { chunks.isEmpty }

    /// Appends one delta to ``itemID``. Adjacent chunks for the same row merge,
    /// so N deltas of one row become one append; a delta for another row starts
    /// a new chunk to preserve the global order.
    mutating func append(_ text: String, to itemID: String) {
        guard !text.isEmpty else { return }
        if let last = chunks.indices.last, chunks[last].itemID == itemID {
            chunks[last].text += text
        } else {
            chunks.append(Chunk(itemID: itemID, text: text))
        }
    }

    /// Removes and returns every pending chunk, oldest first.
    mutating func take() -> [Chunk] {
        guard !chunks.isEmpty else { return [] }
        let taken = chunks
        chunks.removeAll(keepingCapacity: true)
        return taken
    }

    mutating func removeAll() {
        chunks.removeAll(keepingCapacity: true)
    }
}

extension Array where Element == ChatItem {
    /// Applies pending chunks in order.
    ///
    /// A chunk whose row is gone (a history reload replaced the transcript) is
    /// dropped: the authoritative replacement already carries the durable text
    /// and the delayed fragment must not be appended to a different row.
    mutating func applyStreamChunks(_ chunks: [NativeStreamAccumulator.Chunk]) {
        guard !chunks.isEmpty else { return }
        for chunk in chunks {
            guard let index = firstIndex(where: { $0.id == chunk.itemID }) else { continue }
            self[index].text += chunk.text
            self[index].bumpRenderRevision()
        }
    }
}
