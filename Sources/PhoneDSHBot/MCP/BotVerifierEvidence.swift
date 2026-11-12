// SPDX-License-Identifier: MIT

import Foundation

/// Evidence window for the read-only verifier (P26 §2.9). The durable event
/// log is append-only and only exposes ascending pages, so "newest" means
/// paging from the beginning and keeping a bounded tail of the subject
/// session's refs. A single oldest-1000 page is exactly the defect this type
/// replaces: a new session's events live past that page.
public enum BotVerifierEvidence {
    public static let pageSize = 1_000

    /// Append one page to the bounded tail and drop the oldest overflow.
    public static func append(_ page: [BotEvent], subjectSessionId: String,
                              limit: Int, to refs: inout [String]) {
        guard limit > 0 else { refs = []; return }
        for event in page where event.principal.sessionId == subjectSessionId {
            guard let seq = event.commitSeq else { continue }
            refs.append("record://event/\(seq)")
        }
        if refs.count > limit { refs.removeFirst(refs.count - limit) }
    }

    /// Read the whole durable log through its real pager and return at most
    /// `limit` newest `record://event/<commitSeq>` refs for one session.
    public static func latestRefs(in log: any BotEventLog, subjectSessionId: String,
                                  limit: Int = 4) async throws -> [String] {
        guard limit > 0, !subjectSessionId.isEmpty else { return [] }
        var refs: [String] = []
        var cursor = 0
        while true {
            let page = try await log.events(after: cursor, limit: pageSize)
            if page.isEmpty { break }
            append(page, subjectSessionId: subjectSessionId, limit: limit, to: &refs)
            guard let last = page.last?.commitSeq, last > cursor else { break }
            cursor = last
            if page.count < pageSize { break }
        }
        return refs
    }
}
