// SPDX-License-Identifier: MIT

import Foundation

/// The local, optimistic transcript echo of a tapped question/steps option.
///
/// The id follows the composer's `local-<nonce>` convention, so the transcript
/// reconciles it with the durable user row through the same in-memory
/// `chatActionNonce` rule it already uses for a typed message: the host sends
/// the option value with the frozen `card-answer:<nonce>` request id, the
/// projection carries that nonce on the user row, and the echo is retired when
/// the durable row arrives.
public struct BotChoiceEcho: Sendable, Equatable {
    public var nonce: String
    /// The text the host sends to the model (the option's value), so the
    /// optimistic bubble and the durable one read identically.
    public var text: String

    public init(nonce: String, text: String) {
        self.nonce = nonce
        self.text = text
    }

    public var rowID: String { "local-\(nonce)" }
    public var eventID: String { "local:\(nonce)" }
}

/// The local state of one card tap (P09 §3.1), mirroring the page's action
/// state: absent, `pending`, `accepted`, or `failed(reason)`.
public enum BotChoiceTapPhase: Sendable, Equatable {
    case idle
    case pending
    case accepted
    case failed(String)
}

/// What happens to the optimistic echo when the tap finishes.
public enum BotChoiceEchoDisposition: Sendable, Equatable {
    /// While the tap is in flight and after it is accepted: the durable user row
    /// retires the echo through its `card-answer:<nonce>` origin.
    case keep
    /// The action failed, so the choice never reached the model and the
    /// optimistic bubble must be rolled back.
    case remove
}

/// Pure P09 values for a question/steps tap: the status line the card shows
/// while waiting, the human copy for a refused tap, and the identity of the
/// optimistic row.
///
/// The page owns the rows and the action state; these values are the part the
/// card view, the chat model and the regression tests share, so the copy and
/// the rollback rule cannot fork between them.
public enum BotChoiceCardUI {
    /// Shown under the options while the tap waits for the durable answer.
    public static let pendingStatus = "正在送出…"

    /// The card's one-line settlement once a newer question/steps card replaced
    /// it. The newest card is the only one that can be tapped.
    public static let supersededTitle = "已过期，用最新那张"

    /// The planner's refusal codes mapped to human copy. A refusal is a normal
    /// outcome of a stale card, not a failure of the app: the raw code never
    /// reaches the header problem line or the card.
    public static let refusalCopy: [String: String] = [
        "card_expired": "这张卡片已经过期，用最新那张",
        "already_answered": "已经选过了",
        "answer_in_flight": "正在送出，稍等",
        "card_dismissed": "这张卡片已经关闭",
        "unknown_card": "这张卡片已失效",
        "unknown_option": "这张卡片已失效",
    ]

    /// The human copy for a refusal code, or nil when the reason is a real
    /// failure rather than a refusal.
    public static func refusalText(_ reason: String) -> String? {
        refusalCopy[reason.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    /// The card's failure line: a refused tap shows only the human copy, any
    /// other failure keeps the `未能送出：<reason>` form.
    public static func failureText(_ reason: String) -> String {
        refusalText(reason) ?? "未能送出：\(reason)"
    }

    /// The line under the options for the current tap phase. `nil` means the
    /// card shows no extra line: accepted and idle are described by the durable
    /// row's own settlement.
    public static func statusLine(for phase: BotChoiceTapPhase) -> String? {
        switch phase {
        case .pending: return pendingStatus
        case .failed(let reason): return failureText(reason)
        case .accepted, .idle: return nil
        }
    }

    /// The optimistic echo for a tap: the option's value (falling back to its
    /// label) as an ordinary user bubble, or nil when neither is present.
    public static func echo(nonce: String, value: String, label: String) -> BotChoiceEcho? {
        let nonce = nonce.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nonce.isEmpty else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = text.isEmpty ? fallback : text
        guard !resolved.isEmpty else { return nil }
        return BotChoiceEcho(nonce: nonce, text: resolved)
    }

    public static func echoDisposition(for phase: BotChoiceTapPhase) -> BotChoiceEchoDisposition {
        if case .failed = phase { return .remove }
        return .keep
    }
}
