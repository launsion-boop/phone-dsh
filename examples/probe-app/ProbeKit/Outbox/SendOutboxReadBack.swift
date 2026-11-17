// SPDX-License-Identifier: MIT
// The authoritative read-back that settles an `outcomeUnknown` send
// (spec/host/v1/README.md section 10, "Outcome unknown").
import Foundation
import PhoneDSHAgentCore

public enum SendOutboxReadBack: Equatable, Sendable {
    /// A durable `user/message` carries the rpcId.
    case journaled
    /// The engine holds the prompt in its inbox; its `user/message` follows the next turn start.
    case held
    /// One consistent snapshot proves the engine never received the request.
    case absent
    /// The read-back could not prove either way. The entry stays where it is.
    case inconclusive

    /// How long an unknown submit must settle before absence may be concluded, so a request
    /// still in flight can land and a persistently failing transport is retried ever more slowly.
    public static func settleDelayMs(attempts: Int) -> Int64 {
        min(3_000 << Int64(max(0, min(attempts, 8) - 1)), 300_000)
    }

    /// Absence requires a readable inbox and a complete history from one follow snapshot.
    /// A nil first page means the session has no durable log.
    public static func resolve(rpcId: String, createdAtMs: Int64, inbox: JSONValue?,
                               firstPage: JSONValue?, maxPages: Int = 40,
                               loadEarlier: (Int) async throws -> JSONValue) async throws -> Self {
        var inboxKnown = false
        if let inboxObject = inbox?.objectValue {
            inboxKnown = true
            // Both lanes are required by the pinned InboxWireState.
            for target in ["next-turn", "next-step"] {
                guard let items = inboxObject[target]?.arrayValue else {
                    inboxKnown = false
                    continue
                }
                for item in items {
                    guard let message = item.objectValue else {
                        inboxKnown = false
                        continue
                    }
                    guard let source = message["source"]?.objectValue,
                          let kind = source["kind"]?.stringValue else {
                        inboxKnown = false
                        continue
                    }
                    if kind == "user", source["rpcId"]?.stringValue == rpcId {
                        return .held
                    }
                }
            }
        }
        // Phone clock changes can make history timestamps nonmonotonic.
        var page = firstPage
        var previousBefore: Int?
        var pages = 0
        var historyKnown = true
        while let current = page {
            try Task.checkCancellation()
            pages += 1
            guard let records = current["records"]?.arrayValue,
                  let hasMore = current["hasMore"]?.boolValue else {
                return .inconclusive
            }
            var events: [JSONValue] = []
            for record in records {
                guard let event = record["event"]?.objectValue else {
                    return .inconclusive
                }
                events.append(.object(event))
            }
            for record in events {
                guard let type = record["type"]?.stringValue else {
                    historyKnown = false
                    continue
                }
                guard type == "user/message" else { continue }
                guard let data = record["data"]?.objectValue,
                      let source = data["source"]?.objectValue else {
                    historyKnown = false
                    continue
                }
                guard let kind = source["kind"]?.stringValue else {
                    historyKnown = false
                    continue
                }
                if kind == "user", source["rpcId"]?.stringValue == rpcId {
                    return .journaled
                }
            }
            if !hasMore { break }
            guard pages < maxPages,
                  let before = pageCursor(events) else {
                return .inconclusive
            }
            if let previousBefore, before >= previousBefore { return .inconclusive }
            previousBefore = before
            page = try await loadEarlier(before)
        }
        return inboxKnown && historyKnown ? .absent : .inconclusive
    }

    /// Reject an unreadable sequence instead of skipping unseen history.
    private static func pageCursor(_ events: [JSONValue]) -> Int? {
        guard !events.isEmpty else { return nil }
        var minimum: Int?
        for event in events {
            guard let number = event["seq"]?.numberValue,
                  number.isFinite,
                  number == number.rounded(.towardZero),
                  let seq = Int(exactly: number),
                  seq >= 0, number <= 9_007_199_254_740_991 else {
                return nil
            }
            minimum = min(minimum ?? seq, seq)
        }
        return minimum
    }
}
