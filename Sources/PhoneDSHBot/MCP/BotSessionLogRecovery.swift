// SPDX-License-Identifier: MIT

import Foundation

/// What one recovered DSH session log says about an unfinished turn.
public struct BotOpenTurnReport: Sendable, Equatable {
    /// The last `turn/start` that has no matching `turn/end`.
    public var turn: Int
    /// `tool/call` ids inside that open turn without a matching `tool/result`.
    public var pendingCallIDs: [String]

    public init(turn: Int, pendingCallIDs: [String]) {
        self.turn = turn
        self.pendingCallIDs = pendingCallIDs
    }
}

/// Read-only recovery scan over a materialized DSH session log.
///
/// The App restart path must not leave a durable `turn/start` without its
/// `turn/end`: the new Worker queues every later prompt behind that turn and
/// the row projection keeps the interrupted tool card running. This helper
/// only inspects the tail; it never writes or rewrites the session log.
public enum BotSessionLogRecovery {
    /// Last N bytes of a large session log are enough to find the open turn:
    /// a turn that is still open sits at the end of the file.
    public static let defaultTailBytes = 4 * 1024 * 1024

    /// Returns the open turn, or nil when the log ends with a `turn/end`.
    public static func openTurn(at url: URL,
                                maximumBytes: Int = defaultTailBytes) -> BotOpenTurnReport? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0
        do {
            try handle.seek(toOffset: start)
        } catch {
            return nil
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") {
            // The first line of a tail read is usually partial; drop it.
            text = String(text[text.index(after: newline)...])
        }
        return inspect(lines: text.split(separator: "\n", omittingEmptySubsequences: true))
    }

    static func inspect<S: StringProtocol>(lines: [S]) -> BotOpenTurnReport? {
        var openTurn: Int?
        var pending: [String] = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let event = object as? [String: Any],
                  let type = event["type"] as? String else { continue }
            switch type {
            case "turn/start":
                let data = event["data"] as? [String: Any]
                openTurn = (data?["turn"] as? Int) ?? openTurn ?? 0
                pending = []
            case "turn/end":
                openTurn = nil
                pending = []
            case "tool/call":
                guard openTurn != nil else { continue }
                let data = event["data"] as? [String: Any]
                if let callID = data?["callId"] as? String, !callID.isEmpty,
                   !pending.contains(callID) {
                    pending.append(callID)
                }
            case "tool/result":
                guard openTurn != nil else { continue }
                let data = event["data"] as? [String: Any]
                let message = data?["message"] as? [String: Any]
                let source = message?["source"] as? [String: Any]
                if let callID = (data?["toolCallId"] as? String)
                    ?? (message?["toolCallId"] as? String)
                    ?? (source?["callId"] as? String) {
                    pending.removeAll { $0 == callID }
                }
            default:
                continue
            }
        }
        guard let turn = openTurn else { return nil }
        return BotOpenTurnReport(turn: turn, pendingCallIDs: pending)
    }
}
