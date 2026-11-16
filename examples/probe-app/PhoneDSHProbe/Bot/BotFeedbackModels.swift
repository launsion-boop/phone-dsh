// SPDX-License-Identifier: MIT

// BotFeedbackModels: one feedback vocabulary bound to a real durable Bot
// artifact. The host validates the artifact and derives the suppression scope;
// the view only presents the choices, keeps pending/recorded state, and offers
// undo with the accepted feedback event id.

import Foundation
import PhoneDSHBot

enum BotFeedbackVerdict: String, CaseIterable, Equatable {
    case adopt
    case correct
    case suppress
    case undo

    var label: String {
        switch self {
        case .adopt: return "采纳"
        case .correct: return "说错了"
        case .suppress: return "这类别推了"
        case .undo: return "撤销"
        }
    }

    var icon: String {
        switch self {
        case .adopt: return "hand.thumbsup"
        case .correct: return "exclamationmark.bubble"
        case .suppress: return "bell.slash"
        case .undo: return "arrow.uturn.backward"
        }
    }

    var isUndo: Bool { self == .undo }
}

struct BotFeedbackArtifact: Equatable {
    var rowID: String
    var botID: String
    /// A human label for the artifact; never an internal id.
    var label: String
    var kindLabel: String
    var verdicts: [BotFeedbackVerdict]
    /// The scopes this row may offer for `suppress`. The dialog lists exactly
    /// these; it never silently widens a routine class to a cross-Bot `user`.
    var suppressScopes: [BotFeedbackScope] = []
    /// Internal target mapping for the host adapter. A delivered card/text is
    /// `delivery:<rowID>`; a routine definition is `routine:<routineID>` and
    /// has no single delivery yet, so it must not offer the artifact scope.
    var targetKind: String = "delivery"
    var targetID: String = ""
    var isRoutineDefinition: Bool = false

    func offers(_ verdict: BotFeedbackVerdict) -> Bool {
        verdicts.contains(verdict)
    }
}

enum BotFeedbackArtifactParse: Equatable {
    case eligible(BotFeedbackArtifact)
    case unavailable(String)
}

enum BotFeedbackArtifactRule {
    /// A feedback target must be a durable, visible assistant artifact. Owner
    /// messages, local echoes, notices and unrenderable rows are refused before
    /// any action is sent.
    static func availability(for row: BotUIRow) -> BotFeedbackArtifactParse {
        if row.id.hasPrefix("local-")
            || (!row.provenance.eventIDs.isEmpty
                && row.provenance.eventIDs.allSatisfy({ $0.hasPrefix("local:") })) {
            return .unavailable("这条内容还没有写入记录")
        }
        // `BotSessionLogProjection` keeps `sendMessage` as the default row
        // kind for `card.presented` (attachment/document) and for assistant
        // text. Rejecting the kind also rejected every real assistant
        // artifact, so E's restored attachment card rendered without a
        // feedback bar. Owner/local rows are already excluded by `role ==
        // "user"` and the local-id provenance checks.
        if row.role == "user" {
            return .unavailable("这是你自己发送的消息")
        }
        guard BotUIRendering.isRenderable(row) else {
            return .unavailable("这条内容没有可反馈的产物")
        }
        let kindLabel: String
        let verdicts: [BotFeedbackVerdict]
        let suppressScopes: [BotFeedbackScope]
        var targetKind = "delivery"
        var targetID = row.id
        var isRoutineDefinition = false
        if row.body.type == "text" {
            let text = (row.body["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard row.role == "assistant", !text.isEmpty else {
                return .unavailable("这条内容没有可反馈的产物")
            }
            kindLabel = "回复"
            verdicts = [.adopt, .undo]
            suppressScopes = []
        } else if let card = BotUICardContent.parse(row: row) {
            switch card.kind {
            // This inline bar records feedback on a delivered message or
            // attachment. Choice/approval cards have their own explicit
            // actions; routine/task/progress cards are bound through the host
            // routine/task target, not a chat-row delivery target. Showing a
            // feedback bar that the adapter would map to the wrong target is
            // worse than not showing it.
            case .attachment:
                kindLabel = "附件"
                verdicts = [.adopt, .undo]
                suppressScopes = []
            case .document:
                kindLabel = "文档"
                verdicts = [.adopt, .undo]
                suppressScopes = []
            case .automation:
                // A routine definition has no single delivery yet: its target
                // is the routine itself, so only class/user scopes apply. A
                // routine result row has a real delivery and keeps artifact.
                if let routineID = row.body["routineID"]?.string,
                   !routineID.isEmpty {
                    kindLabel = "例行任务"
                    verdicts = [.suppress, .undo]
                    suppressScopes = [.routineClass, .user]
                    targetKind = "routine"
                    targetID = routineID
                    isRoutineDefinition = true
                } else {
                    kindLabel = "例行结果"
                    verdicts = [.suppress, .undo]
                    suppressScopes = [.artifact, .routineClass, .user]
                }
            case .notice, .question, .steps, .approval,
                 .task, .progress, .checklist, .link:
                return .unavailable("这类内容不通过消息反馈")
            }
        } else {
            return .unavailable("这条内容没有可反馈的产物")
        }
        return .eligible(BotFeedbackArtifact(
            rowID: row.id, botID: row.botID,
            label: displayLabel(for: row),
            kindLabel: kindLabel,
            verdicts: verdicts,
            suppressScopes: suppressScopes,
            targetKind: targetKind,
            targetID: targetID,
            isRoutineDefinition: isRoutineDefinition))
    }

    static func displayLabel(for row: BotUIRow) -> String {
        let raw = BotUIRendering.copyText(row).trimmingCharacters(in: .whitespacesAndNewlines)
        // `copyText` falls back to the row id for a body without any readable
        // field; that fallback must not leak into the feedback flow.
        guard !raw.isEmpty, raw != row.id, !BotProvenanceLabel.looksInternal(raw) else {
            return "这条内容"
        }
        return raw.count <= 36 ? raw : String(raw.prefix(35)) + "…"
    }
}

struct BotFeedbackReceipt: Equatable, Identifiable {
    var rowID: String
    var verdict: BotFeedbackVerdict
    var feedbackID: String
    var atMS: Int64
    /// An undo event points at this receipt; it stays in the audit list but is
    /// no longer the artifact's current feedback.
    var undone: Bool = false

    var id: String { feedbackID }
}

enum BotFeedbackAvailability: Equatable {
    case available
    case pending
    case recorded(String)
    case unavailable(String)
}

enum BotFeedbackScope: String, Equatable {
    /// Only this artifact.
    case artifact
    /// This routine's future results. Wire `.class`; G-2 r5 accepts only a
    /// narrow routine/reminder class here, never `user`.
    case routineClass
    /// This kind of proactive output, across Bots. Only a UI action may create
    /// it (G-2 r5); the host derives the concrete kind-level class.
    case user
}

struct BotFeedbackIntent: Equatable {
    var nonce: String
    var rowID: String
    var botID: String
    /// Internal host-adapter target. `delivery` uses rowID; `routine` uses the
    /// routineID and has no single delivery before its first run.
    var targetKind: String = "delivery"
    var targetID: String = ""
    /// This is a routine definition, not a routine result; artifact scope is
    /// not meaningful for it.
    var isRoutineDefinition: Bool = false
    var verdict: BotFeedbackVerdict
    /// `suppress` is the only verdict that asks for a scope; the UI explicitly
    /// chooses "this one" vs "this kind in every Bot".
    var scope: BotFeedbackScope
    /// Only for `undo`; the accepted feedback event id.
    var feedbackID: String?
}

enum BotFeedbackDisplay: Equatable {
    case none
    case pending
    case recorded(BotFeedbackVerdict)
    case undone

    var label: String {
        switch self {
        case .none: return ""
        case .pending: return "正在记录…"
        case .recorded(let verdict): return "已记录：\(verdict.label)"
        case .undone: return "已撤销反馈"
        }
    }
}

struct BotFeedbackState: Equatable {
    /// Newest first, append-only. The model never rewrites an old receipt; undo
    /// marks it and appends its own durable event.
    private(set) var receipts: [String: [BotFeedbackReceipt]] = [:]
    private(set) var pending: Set<String> = []
    private(set) var lastFailure: [String: String] = [:]

    static func key(rowID: String, verdict: BotFeedbackVerdict) -> String {
        "\(rowID)\u{0}\(verdict.rawValue)"
    }

    func latest(for rowID: String) -> BotFeedbackReceipt? {
        receipts[rowID]?.first
    }

    func latestActive(for rowID: String) -> BotFeedbackReceipt? {
        receipts[rowID]?.first { !$0.undone && !$0.verdict.isUndo }
    }

    func display(for rowID: String) -> BotFeedbackDisplay {
        if pending.contains(where: { $0.hasPrefix(rowID + "\u{0}") }) {
            return .pending
        }
        guard let latest = latest(for: rowID) else { return .none }
        if latest.verdict.isUndo { return .undone }
        return .recorded(latest.verdict)
    }

    func failure(for rowID: String) -> String? {
        lastFailure[rowID]
    }

    func canUndo(for rowID: String) -> Bool {
        guard let latest = latestActive(for: rowID), !latest.feedbackID.isEmpty else { return false }
        return !pending.contains(Self.key(rowID: rowID, verdict: .undo))
    }

    func availability(for artifact: BotFeedbackArtifact,
                      verdict: BotFeedbackVerdict) -> BotFeedbackAvailability {
        guard artifact.offers(verdict) else {
            return .unavailable("这个操作不适用于这类内容")
        }
        if pending.contains(Self.key(rowID: artifact.rowID, verdict: verdict)) {
            return .pending
        }
        if verdict.isUndo {
            return canUndo(for: artifact.rowID)
                ? .available
                : .unavailable("还没有可撤销的反馈")
        }
        if latestActive(for: artifact.rowID)?.verdict == verdict {
            return .recorded(verdict.label)
        }
        return .available
    }

    /// Returns the feedbackID used in the undo payload (the latest active
    /// receipt's accepted event id).
    func undoFeedbackID(for rowID: String) -> String? {
        latestActive(for: rowID)?.feedbackID
    }

    @discardableResult
    mutating func begin(rowID: String, verdict: BotFeedbackVerdict) -> Bool {
        let key = Self.key(rowID: rowID, verdict: verdict)
        guard !pending.contains(key) else { return false }
        if verdict.isUndo, !canUndo(for: rowID) { return false }
        if !verdict.isUndo, latestActive(for: rowID)?.verdict == verdict { return false }
        pending.insert(key)
        lastFailure.removeValue(forKey: rowID)
        return true
    }

    /// Applies the host's accepted result. `feedbackID` is the accepted
    /// eventID. For undo, `undoTarget` is the receipt the host validated.
    mutating func accept(rowID: String, verdict: BotFeedbackVerdict,
                         feedbackID: String, atMS: Int64,
                         undoTarget: String? = nil) {
        pending.remove(Self.key(rowID: rowID, verdict: verdict))
        lastFailure.removeValue(forKey: rowID)
        if verdict.isUndo, let target = undoTarget,
           var list = receipts[rowID],
           let index = list.firstIndex(where: { $0.feedbackID == target }) {
            list[index].undone = true
            receipts[rowID] = list
        }
        receipts[rowID, default: []].insert(
            BotFeedbackReceipt(rowID: rowID, verdict: verdict,
                               feedbackID: feedbackID, atMS: atMS),
            at: 0)
    }

    mutating func fail(rowID: String, verdict: BotFeedbackVerdict, reason: String) {
        pending.remove(Self.key(rowID: rowID, verdict: verdict))
        lastFailure[rowID] = reason
    }

    /// A durable projection may carry a compact feedback summary; the view can
    /// seed its receipt without a second read. Unknown fields stay absent.
    mutating func seed(rowID: String, feedback: BotJSONValue?) {
        guard let object = feedback?.object,
              let verdict = BotFeedbackVerdict(rawValue: object["verdict"]?.string ?? ""),
              let feedbackID = object.string("feedback_id", "feedbackID"), !feedbackID.isEmpty else {
            return
        }
        let atMS = object["at_ms"]?.int.map(Int64.init) ?? 0
        receipts[rowID] = [BotFeedbackReceipt(rowID: rowID, verdict: verdict,
                                              feedbackID: feedbackID, atMS: atMS)]
    }
}
