// SPDX-License-Identifier: MIT
import Foundation

/// Native-only identity for one recording. The existing SendOutbox owns persistence.
public struct NativeVoiceRequest: Equatable, Sendable {
    public let sessionID: String
    public let rpcID: String

    public init(sessionID: String) {
        self.sessionID = sessionID
        self.rpcID = UUID().uuidString.lowercased()
    }
}

public enum NativeVoiceProgress: Equatable {
    case queued, running, unavailable, failed
    case completed(String)

    /// Never attribute a response by prompt text or the global engine running flag.
    public static func resolve(request: NativeVoiceRequest, items: [ChatItem],
                               endedTurns: Set<Int>, failedTurns: Set<Int>) -> Self {
        guard let inputIndex = items.firstIndex(where: {
            $0.kind == .user && $0.promptRequestID == request.rpcID && $0.promptJournalSeq != nil
        }), let turn = items[inputIndex].turn else { return .queued }
        if failedTurns.contains(turn) { return .failed }
        guard endedTurns.contains(turn) else { return .running }
        let replies = items.dropFirst(inputIndex + 1).filter {
            $0.kind == .assistant && $0.turn == turn && !$0.streaming && !$0.isInterruptedDraft
        }
        return .completed(replies.last(where: { !$0.text.isEmpty })?.text ?? "")
    }
}
