// SPDX-License-Identifier: MIT
// Display-only draft of the assistant/reasoning text that is still streaming.
//
// DSH persists an assistant message only when its step settles
// (`assistant/message`). If the App or WebContent dies mid-stream, the durable
// session is repaired with `turn/end{kind:'interrupted'}` and the text that was
// already shown on screen is simply gone. The App keeps a small per-session
// file beside the transcript snapshot so every relaunch can paint that text,
// clearly marked as not part of the session, until the turn has a durable
// replacement. This file owns the on-disk shape, the byte bound and the reload
// policy; the App target owns the queue/writer.

import Foundation
import PhoneDSHAgentCore

/// One of the two streamed row kinds. The raw value is the stable on-disk name.
public enum NativeStreamDraftKind: String, Codable, Equatable, Sendable {
    case reasoning
    case assistant

    public var chatKind: ChatItem.Kind {
        switch self {
        case .reasoning: return .reasoning
        case .assistant: return .assistant
        }
    }

    public var title: String {
        switch self {
        case .reasoning: return "思考"
        case .assistant: return "Assistant"
        }
    }
}

/// The current streaming row's display text. Only what the row already showed
/// is stored: no raw event, no prompt, no tool data.
public struct NativeStreamDraftItem: Codable, Equatable, Sendable {
    public var itemID: String
    public var kind: NativeStreamDraftKind
    public var turn: Int?
    public var step: Int?
    public var text: String
    public var updatedAtMilliseconds: Double
    /// True when the file byte cap forced this row to keep only its tail.
    public var truncated: Bool

    public init(itemID: String,
                kind: NativeStreamDraftKind,
                turn: Int?,
                step: Int?,
                text: String,
                updatedAt: Date = Date(),
                truncated: Bool = false) {
        self.itemID = itemID
        self.kind = kind
        self.turn = turn
        self.step = step
        self.text = text
        self.updatedAtMilliseconds = updatedAt.timeIntervalSince1970 * 1_000
        self.truncated = truncated
    }

    public var updatedAt: Date {
        Date(timeIntervalSince1970: updatedAtMilliseconds / 1_000)
    }

    private enum CodingKeys: String, CodingKey {
        case itemID, kind, turn, step, text, truncated
        // The design names this member `updatedAt`; the value stays a
        // millisecond epoch so it sorts and compares without a date codec.
        case updatedAtMilliseconds = "updatedAt"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        itemID = try values.decode(String.self, forKey: .itemID)
        kind = try values.decode(NativeStreamDraftKind.self, forKey: .kind)
        turn = try values.decodeIfPresent(Int.self, forKey: .turn)
        step = try values.decodeIfPresent(Int.self, forKey: .step)
        text = try values.decode(String.self, forKey: .text)
        updatedAtMilliseconds = try values.decodeIfPresent(Double.self, forKey: .updatedAtMilliseconds) ?? 0
        truncated = try values.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

/// Versioned envelope. The backend/session identity is inside the file so a
/// copied or renamed file cannot paint another session's text (same rule as
/// `CachedTranscriptSnapshot`).
public struct NativeStreamDraftFile: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var v: Int
    public var backend: String
    public var sessionID: String
    public var items: [NativeStreamDraftItem]

    public init(backend: BackendID, sessionID: String, items: [NativeStreamDraftItem]) {
        self.v = Self.currentVersion
        self.backend = backend.storageScope
        self.sessionID = sessionID
        self.items = items
    }
}

public enum NativeStreamDraftCodec {
    /// One session's draft budget; the same bound the transcript snapshot uses.
    public static let maxFileBytes = 512 * 1024
    /// A session has at most one assistant and one reasoning stream at a time.
    /// The generous cap only protects against a malformed writer.
    public static let maxItems = 16

    /// Encodes the current rows, keeping the newest rows and the tail of the
    /// text when the JSON would exceed `maxFileBytes`. Returns nil for an empty
    /// draft (the store deletes the file in that case).
    public static func encode(items: [NativeStreamDraftItem],
                              backend: BackendID,
                              sessionID: String) -> Data? {
        var kept = items.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !kept.isEmpty else { return nil }
        if kept.count > maxItems { kept = Array(kept.suffix(maxItems)) }

        while true {
            guard let data = encodeUnchecked(kept, backend: backend, sessionID: sessionID)
            else { return nil }
            if data.count <= maxFileBytes { return data }
            guard kept.count > 1 else {
                let trimmed = fittingTail(of: kept[0], backend: backend, sessionID: sessionID)
                guard !trimmed.text.isEmpty else { return nil }
                return encodeUnchecked([trimmed], backend: backend, sessionID: sessionID)
            }
            // The newest row is the one being written; drop the older rows
            // first instead of truncating the live tail.
            kept.removeFirst()
        }
    }

    public static func decode(_ data: Data,
                              backend: BackendID,
                              sessionID: String) -> NativeStreamDraftFile? {
        guard let file = try? JSONDecoder().decode(NativeStreamDraftFile.self, from: data),
              file.v == NativeStreamDraftFile.currentVersion,
              file.backend == backend.storageScope,
              file.sessionID == sessionID else { return nil }
        return file
    }

    private static func encodeUnchecked(_ items: [NativeStreamDraftItem],
                                        backend: BackendID,
                                        sessionID: String) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(NativeStreamDraftFile(backend: backend,
                                                         sessionID: sessionID,
                                                         items: items))
    }

    /// Largest tail of `item.text` whose envelope still fits the byte budget.
    /// The searched value is a character count, so multi-byte text cannot make
    /// the encoded file exceed the cap between probes.
    private static func fittingTail(of item: NativeStreamDraftItem,
                                    backend: BackendID,
                                    sessionID: String) -> NativeStreamDraftItem {
        var low = 0
        var high = item.text.count
        var best = item
        best.text = ""
        best.truncated = true
        while low <= high {
            let middle = low + (high - low) / 2
            var candidate = item
            candidate.text = String(item.text.suffix(middle))
            candidate.truncated = middle < item.text.count
            if let data = encodeUnchecked([candidate], backend: backend, sessionID: sessionID),
               data.count <= maxFileBytes {
                best = candidate
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return best
    }
}

/// Reload policy and row construction. Kept in ProbeKit so the rules are
/// unit-tested without the App's history loader or SwiftUI.
public enum NativeStreamDraftPolicy {
    /// The visible note on every display-only row.
    public static let interruptedNotice = "已中断：以下是中断前已收到的部分输出，未写入会话，模型看不到"

    /// `turn/end.reason.kind` values that mean the text was not settled. DSH
    /// repairs an abandoned stream with `interrupted`; the App also receives
    /// `aborted` for a local cancel and `error` for a failed turn.
    public static let nonNormalTurnEndKinds: Set<String> = [
        "interrupted", "failed", "error", "cancelled", "canceled", "aborted",
    ]

    public static func isNonNormalTurnEnd(_ kind: String?) -> Bool {
        guard let kind else { return false }
        return nonNormalTurnEndKinds.contains(kind.lowercased())
    }

    /// `.inactive` and `.background` are the last guaranteed main-actor
    /// windows before iOS may suspend the process; both force a draft write.
    public static func shouldFlushOnScenePhase(active: Bool) -> Bool {
        !active
    }

    /// A missing or non-listed kind is a normal settlement: a draft that was
    /// still on disk is obsolete and is deleted on reload.
    public static func isNormalTurnEnd(_ kind: String?) -> Bool {
        guard let kind, !kind.isEmpty else { return true }
        return !isNonNormalTurnEnd(kind)
    }

    /// DSH seq carried by a projected or live item id (`<session>:<seq>...`).
    /// A live stream row uses `:part-N`, a durable assistant block uses
    /// `:block-N`; both share the same leading seq, which is the position the
    /// reload comparison needs.
    public static func journalSeq(of itemID: String, sessionID: String) -> Int? {
        var rest = Substring(itemID)
        let prefix = "\(sessionID):"
        if rest.hasPrefix(prefix) { rest = rest.dropFirst(prefix.count) }
        let digits = rest.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// The aggregate outcome of one reload, used by the evidence line.
    public enum Verdict: String, Equatable, Sendable {
        /// At least one draft is still visible and still needed.
        case kept
        /// The turn's durable assistant/reasoning text now covers the draft.
        case superseded
        /// The turn ended normally, so the draft is obsolete.
        case settled
        /// The load had no draft rows.
        case none
    }

    public struct Resolution {
        /// The history with any display-only rows updated in place or inserted
        /// at the end of their turn. Display-only rows are never appended twice.
        public var items: [ChatItem]
        /// Draft rows physically removed from the file: normal settlement,
        /// durable text that covers the row, and malformed rows. Erase,
        /// archive and a superseding new turn delete the file through the
        /// store instead.
        public var consumedItemIDs: [String]
        /// Draft rows that are still visible and still needed. They stay on
        /// disk so the next reload can repaint the same stable row.
        public var keptItemIDs: [String]
        /// Policy outcome for this load (`kept` wins when drafts are mixed).
        public var verdict: Verdict
    }

    /// Decides which draft rows to paint after a durable history load.
    ///
    /// - A draft stays visible and on disk until its turn either has durable
    ///   assistant/reasoning text at or after the draft's journal position, or
    ///   ends normally, or a durable row shows that a later turn superseded it.
    ///   A turn that is still running (or whose end fact is not in the loaded
    ///   page) keeps the draft visible.
    /// - Re-running the projector must not append a second row: every shown
    ///   draft uses the stable id `<sessionID>:draft-<turn>-<kind>`, and an
    ///   existing row with that id is updated in place.
    /// - `consumedItemIDs` is only for the real removals above; a row that was
    ///   shown remains in `keptItemIDs`.
    ///
    /// `engineReportsRunningTurn` is retained as an input because the loader
    /// already has it, but it no longer hides a draft: a running turn with no
    /// durable replacement is exactly the case that must stay visible.
    public static func resolve(drafts: [NativeStreamDraftItem],
                               history: [ChatItem],
                               turnEndReasons: [Int: String],
                               engineReportsRunningTurn: Bool,
                               sessionID: String) -> Resolution {
        var consumed: [String] = []
        var kept: [String] = []
        var shown: [(turn: Int, seq: Int?, index: Int, item: ChatItem)] = []
        var items = history
        var removedAsSettled = false
        var removedAsSuperseded = false

        for (index, draft) in drafts.enumerated() {
            guard let turn = draft.turn else {
                // A row without a turn cannot be placed; it is not a visible
                // draft and must not survive forever.
                consumed.append(draft.itemID)
                removedAsSettled = true
                continue
            }
            if let endKind = turnEndReasons[turn] {
                guard isNonNormalTurnEnd(endKind) else {
                    consumed.append(draft.itemID)
                    removedAsSettled = true
                    continue
                }
            }
            // A durable row in a later turn means the user moved on. The send
            // path deletes the file, but this also repairs a kill that landed
            // between the accepted prompt and that delete.
            if history.contains(where: {
                !$0.isInterruptedDraft && ($0.turn ?? Int.min) > turn
            }) {
                consumed.append(draft.itemID)
                removedAsSuperseded = true
                continue
            }

            let seq = journalSeq(of: draft.itemID, sessionID: sessionID)
            if isCovered(draft: draft, seq: seq, turn: turn,
                         history: items, sessionID: sessionID) {
                consumed.append(draft.itemID)
                removedAsSuperseded = true
                continue
            }

            var item = ChatItem(id: draftItemID(sessionID: sessionID, turn: turn,
                                                kind: draft.kind),
                                kind: draft.kind.chatKind,
                                title: draft.kind.title,
                                text: draft.text,
                                streaming: false)
            item.turn = turn
            item.step = draft.step
            item.timestamp = draft.updatedAt
            item.isInterruptedDraft = true
            item.isInterruptedDraftTruncated = draft.truncated
            shown.append((turn: turn, seq: seq, index: index, item: item))
            kept.append(draft.itemID)
        }

        // A prior load may already have painted this draft. Replace that row
        // instead of appending a second one, and drop rows whose turn has now
        // been superseded or settled.
        let shownIDs = Set(shown.map(\.item.id))
        items.removeAll { $0.isInterruptedDraft && !shownIDs.contains($0.id) }

        // Insert by turn (and journal position inside one turn) so a single
        // draft stays at the tail of the turn whose text it continues.
        for entry in shown.sorted(by: { lhs, rhs in
            if lhs.turn != rhs.turn { return lhs.turn < rhs.turn }
            let left = lhs.seq ?? -1
            let right = rhs.seq ?? -1
            if left != right { return left < right }
            return lhs.index < rhs.index
        }) {
            if let existing = items.firstIndex(where: {
                $0.id == entry.item.id && $0.isInterruptedDraft
            }) {
                items[existing] = entry.item
                continue
            }
            let position: Int
            if let last = items.lastIndex(where: { $0.turn == entry.turn }) {
                position = last + 1
            } else if let next = items.firstIndex(where: {
                guard let turn = $0.turn else { return false }
                return turn > entry.turn
            }) {
                position = next
            } else {
                position = items.count
            }
            items.insert(entry.item, at: position)
        }

        let verdict: Verdict
        if !kept.isEmpty {
            verdict = .kept
        } else if removedAsSuperseded {
            verdict = .superseded
        } else if removedAsSettled {
            verdict = .settled
        } else {
            verdict = .none
        }
        return Resolution(items: items, consumedItemIDs: consumed,
                          keptItemIDs: kept, verdict: verdict)
    }

    /// Display-only rows never become model context. `ChatModel.send` builds its
    /// prompt from the composer value alone; this gate exists for any future
    /// caller that projects the transcript into a prompt.
    public static func modelContextItems(_ items: [ChatItem]) -> [ChatItem] {
        items.filter { !$0.isInterruptedDraft }
    }

    /// Stable display id for one draft kind in one turn. A reload updates this
    /// row instead of appending another one.
    public static func draftItemID(sessionID: String,
                                   turn: Int,
                                   kind: NativeStreamDraftKind) -> String {
        "\(sessionID):draft-\(turn)-\(kind.rawValue)"
    }

    private static func isCovered(draft: NativeStreamDraftItem,
                                  seq: Int?,
                                  turn: Int,
                                  history: [ChatItem],
                                  sessionID: String) -> Bool {
        history.contains { item in
            guard !item.isInterruptedDraft,
                  item.turn == turn,
                  item.kind == .assistant || item.kind == .reasoning
            else { return false }
            guard let seq else { return true }
            guard let settledSeq = journalSeq(of: item.id, sessionID: sessionID)
            else { return false }
            return settledSeq >= seq
        }
    }
}

/// One-line, pure evidence formatter for `chat-status.log`. The loader already
/// has the DSH cursor, the cached snapshot seq and the draft resolution, so
/// this function only formats those values; it never reads the WAL or event
/// log. The writer owns the timestamp and the file I/O.
public enum NativeStreamDraftEvidence {
    public static func evidenceLine(sessionID: String,
                                    dshLastSeq: Int?,
                                    snapshotLastSeq: UInt64?,
                                    drafts: [NativeStreamDraftItem],
                                    resolution: NativeStreamDraftPolicy.Resolution,
                                    activeTurn: Int?) -> String {
        let representative = representativeDraft(drafts, sessionID: sessionID)
        let draftTurn = representative?.turn
        let draftSeq = representative.flatMap {
            NativeStreamDraftPolicy.journalSeq(of: $0.itemID, sessionID: sessionID)
        }
        return "draft-evidence"
            + " session=\(sessionID)"
            + " dsh_last_seq=\(number(dshLastSeq))"
            + " snapshot_last_seq=\(number(snapshotLastSeq))"
            + " drafts=\(drafts.count)"
            + " kept=\(ids(resolution.keptItemIDs))"
            + " consumed=\(ids(resolution.consumedItemIDs))"
            + " active_turn=\(number(activeTurn))"
            + " draft_turn=\(number(draftTurn))"
            + " draft_seq=\(number(draftSeq))"
            + " verdict=\(resolution.verdict.rawValue)"
    }

    /// Newest draft by turn, then journal position. The format has one
    /// `draft_turn`/`draft_seq` pair; with the normal two rows of the same
    /// stream this picks the furthest position.
    private static func representativeDraft(_ drafts: [NativeStreamDraftItem],
                                             sessionID: String) -> NativeStreamDraftItem? {
        drafts.max { lhs, rhs in
            let leftTurn = lhs.turn ?? Int.min
            let rightTurn = rhs.turn ?? Int.min
            if leftTurn != rightTurn { return leftTurn < rightTurn }
            let leftSeq = NativeStreamDraftPolicy.journalSeq(of: lhs.itemID,
                                                             sessionID: sessionID) ?? Int.min
            let rightSeq = NativeStreamDraftPolicy.journalSeq(of: rhs.itemID,
                                                              sessionID: sessionID) ?? Int.min
            return leftSeq < rightSeq
        }
    }

    private static func number<T: BinaryInteger>(_ value: T?) -> String {
        value.map(String.init) ?? "none"
    }

    private static func ids(_ values: [String]) -> String {
        values.isEmpty ? "-" : values.joined(separator: ",")
    }
}

/// O(1)-per-append bookkeeping for the current streaming rows. `ChatModel`
/// copies `items` (at most two rows) when it submits a draft; it never filters
/// the whole transcript on the main actor.
public struct NativeStreamDraftTracker {
    public private(set) var items: [NativeStreamDraftItem] = []
    private var indexByID: [String: Int] = [:]

    public init() {}

    public mutating func begin(itemID: String,
                               kind: NativeStreamDraftKind,
                               turn: Int?,
                               step: Int?) {
        let row = NativeStreamDraftItem(itemID: itemID, kind: kind, turn: turn,
                                        step: step, text: "")
        if let index = indexByID[itemID] {
            items[index] = row
        } else {
            indexByID[itemID] = items.count
            items.append(row)
        }
    }

    public mutating func append(_ text: String, to itemID: String) {
        guard let index = indexByID[itemID], !text.isEmpty else { return }
        items[index].text += text
        items[index].updatedAtMilliseconds = Date().timeIntervalSince1970 * 1_000
    }

    public mutating func remove(itemIDs: [String]) {
        guard !itemIDs.isEmpty else { return }
        let removed = Set(itemIDs)
        items.removeAll { removed.contains($0.itemID) }
        reindex()
    }

    public mutating func clear(kind: NativeStreamDraftKind, turn: Int?) {
        items.removeAll { $0.kind == kind && $0.turn == turn }
        reindex()
    }

    public mutating func clear(turn: Int?) {
        items.removeAll { $0.turn == turn }
        reindex()
    }

    public mutating func clearAll() {
        items.removeAll()
        indexByID.removeAll()
    }

    private mutating func reindex() {
        indexByID.removeAll(keepingCapacity: true)
        for (index, item) in items.enumerated() {
            indexByID[item.itemID] = index
        }
    }
}
