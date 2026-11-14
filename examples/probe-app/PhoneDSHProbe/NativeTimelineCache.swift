// SPDX-License-Identifier: MIT
// Cached transcript projection.
//
// `ChatPage` used to rebuild `timelineRows` (filter + fold + group + turn
// state lookups) on every body pass. The cache key is the items revision plus
// the UI inputs that can change grouping: folded Turns and the durable turn
// facts. Rows keep exactly the old grouping/ordering semantics.
//
// A streaming delta changes only the last visible item. When every earlier
// item is unchanged the previous rows/turn facts are reused and only the tail
// row is replaced, so a delta does not regroup the transcript.
//
// The per-Turn facts live here too: the Turn's copy text, its token usage, its
// process-row presence and its closing assistant are accumulated in the same
// single pass as the grouping. `ChatPage` used to recompute all three by
// filtering the whole transcript inside `body`, once per process/tail row.
//
// This file also owns the two presentation policies that bound the page's
// main-thread cost (the hostless simulator suite compiles this file):
// `NativeTranscriptRenderWindow` (how many rows one body pass may materialize)
// and `ChatTranscriptGate` (which transcript mutations may run while the App
// is not on screen).

import Foundation
import ProbeKit

struct NativeTimelinePlanEntry: Equatable {
    let plan: NativePlanCardData
    let markdown: String
}

struct NativeTimelineTurnFacts: Equatable {
    var closingAssistantID: String?
    /// `closingAssistantID`'s message id, the feedback target.
    var closingMessageID: String?
    /// `closingAssistantID`'s row time, the tail clock fallback.
    var closingTimestamp: Date?
    var plans: [NativeTimelinePlanEntry] = []
    var changes: NativeChangedFiles?
    /// A closed Turn is foldable only with a final answer plus at least one
    /// process row that folding would hide (the old `turnHasProcess`).
    var hasProcess = false
    /// Every assistant text of the Turn, joined exactly like the copy button
    /// used to do on every body pass.
    var copyText = ""
    /// The Turn's token usage, deduplicated by message id like
    /// `NativeTranscriptProjector.usage(forTurn:in:)`.
    var usage: NativeTurnUsage?

    static let empty = NativeTimelineTurnFacts()
}

struct NativeTimelineSnapshot {
    let rows: [NativeTranscriptRow]
    let visibleItems: [ChatItem]
    let turnFacts: [Int: NativeTimelineTurnFacts]
    let scrollSignature: String
    let inputRowSignature: String
    /// Everything in `scrollSignature` before the last visible item's text.
    /// Reused verbatim by the tail fast path.
    let scrollSignaturePrefix: String
}

enum NativeTurnStateResolver {
    /// One implementation of the control row state used by both `ChatModel`
    /// and the timeline cache.
    static func resolve(turn: Int, endReasons: [Int: String],
                        startTimes: [Int: Date], endTimes: [Int: Date]) -> NativeTurnProcessState? {
        guard let reason = endReasons[turn] else { return nil }
        let elapsed = startTimes[turn].flatMap { start in
            endTimes[turn].map { max(0, $0.timeIntervalSince(start)) }
        }
        return NativeTurnProcessState.resolve(endReasonKind: reason, elapsed: elapsed)
    }
}

final class NativeTimelineCache {
    struct Key: Equatable {
        let itemsRevision: Int
        let structureRevision: Int?
        let foldedTurns: [Int]
        let endReasons: [Int: String]
        let startTimes: [Int: Date]
        let endTimes: [Int: Date]
    }

    private let changesCache: NativeChangesCache
    private var cachedKey: Key?
    private var cachedSnapshot: NativeTimelineSnapshot?
    private var cachedItems: [ChatItem] = []
    private(set) var rebuildCount = 0
    /// Number of snapshots produced by the last-row fast path.
    private(set) var tailUpdateCount = 0
    /// Number of snapshots that had to run the full grouping pass.
    private(set) var fullRebuildCount = 0

    init(changesCache: NativeChangesCache = .shared) {
        self.changesCache = changesCache
    }

    func snapshot(items: [ChatItem], itemsRevision: Int, foldedTurns: Set<Int>,
                  endReasons: [Int: String], startTimes: [Int: Date],
                  endTimes: [Int: Date], structureRevision: Int? = nil) -> NativeTimelineSnapshot {
        let key = Key(itemsRevision: itemsRevision,
                      structureRevision: structureRevision,
                      foldedTurns: foldedTurns.sorted(),
                      endReasons: endReasons,
                      startTimes: startTimes,
                      endTimes: endTimes)
        if key == cachedKey, let cachedSnapshot {
            return cachedSnapshot
        }
        MainThreadHangMonitor.mark("timelineSnapshot.start")
        let snapshot: NativeTimelineSnapshot
        let tailOnly = tailSnapshot(items: items, key: key,
                                    endReasons: endReasons,
                                    startTimes: startTimes, endTimes: endTimes)
        if let tailOnly {
            snapshot = tailOnly
            tailUpdateCount += 1
        } else {
            snapshot = build(items: items, foldedTurns: foldedTurns,
                             endReasons: endReasons,
                             startTimes: startTimes, endTimes: endTimes)
            fullRebuildCount += 1
        }
        MainThreadHangMonitor.mark("timelineSnapshot.end")
        cachedKey = key
        cachedSnapshot = snapshot
        cachedItems = items
        rebuildCount += 1
        NativePerfCounters.shared.timelineRebuilt()
        return snapshot
    }

    func resetForTesting() {
        cachedKey = nil
        cachedSnapshot = nil
        cachedItems = []
        rebuildCount = 0
        tailUpdateCount = 0
        fullRebuildCount = 0
    }

    /// Reuses every row and turn fact when the only change is the text of the
    /// last streaming assistant/reasoning item. Any other shape falls back to
    /// `build` (correctness first).
    private func tailSnapshot(items: [ChatItem], key: Key,
                              endReasons: [Int: String], startTimes: [Int: Date],
                              endTimes: [Int: Date]) -> NativeTimelineSnapshot? {
        guard let cachedSnapshot, let cachedKey,
              sameDisplayInputs(cachedKey, key),
              cachedItems.count == items.count,
              let previous = cachedItems.last, let last = items.last,
              previous != last,
              previous.streaming, last.streaming,
              previous.kind == last.kind, previous.turn == last.turn,
              last.kind == .assistant || last.kind == .reasoning,
              (key.structureRevision != nil
                ? key.structureRevision == cachedKey.structureRevision
                : items.indices.dropLast().allSatisfy({ items[$0] == cachedItems[$0] })),
              cachedSnapshot.visibleItems.last?.id == last.id,
              !cachedSnapshot.rows.isEmpty else { return nil }

        var rows = cachedSnapshot.rows
        // A running turn can already carry a turnTail control row. It is not
        // transcript content and must not force a full regroup per text tick.
        var rowIndex = rows.count - 1
        if case .turnTail = rows[rowIndex] { rowIndex -= 1 }
        guard rowIndex >= 0 else { return nil }
        switch rows[rowIndex] {
        case .item(let rowItem):
            guard rowItem.id == last.id, !Self.isProcessKind(last.kind) else { return nil }
            rows[rowIndex] = .item(last)
        case .tools(let group):
            guard Self.isProcessKind(last.kind), group.last?.id == last.id else { return nil }
            var next = group
            next[next.count - 1] = last
            rows[rowIndex] = .tools(next)
        default:
            return nil
        }
        var visible = cachedSnapshot.visibleItems
        visible[visible.count - 1] = last
        let signature = cachedSnapshot.scrollSignaturePrefix + last.text
        // Turn facts stay cached. The only row whose text changed is a
        // streaming assistant (or reasoning) row; a Turn with a streaming
        // assistant has no closing assistant and therefore no tail row, so it
        // consumes neither `copyText` nor `usage` until the next full rebuild
        // (which the turn's end reason triggers).
        return NativeTimelineSnapshot(rows: rows,
                                      visibleItems: visible,
                                      turnFacts: cachedSnapshot.turnFacts,
                                      scrollSignature: signature,
                                      inputRowSignature: cachedSnapshot.inputRowSignature,
                                      scrollSignaturePrefix: cachedSnapshot.scrollSignaturePrefix)
    }

    private func sameDisplayInputs(_ lhs: Key, _ rhs: Key) -> Bool {
        lhs.foldedTurns == rhs.foldedTurns
            && lhs.endReasons == rhs.endReasons
            && lhs.startTimes == rhs.startTimes
            && lhs.endTimes == rhs.endTimes
    }

    private func build(items: [ChatItem], foldedTurns: Set<Int>,
                       endReasons: [Int: String],
                       startTimes: [Int: Date], endTimes: [Int: Date]) -> NativeTimelineSnapshot {
        let visibleItems = items.filter { $0.kind != .status }
        let stateFor: (Int) -> NativeTurnProcessState? = { turn in
            NativeTurnStateResolver.resolve(turn: turn, endReasons: endReasons,
                                            startTimes: startTimes, endTimes: endTimes)
        }

        // One pass over the visible transcript feeds the grouping, the Markdown
        // cards and every per-Turn fact that used to filter all items again
        // inside each row's `body` (copy text, usage, process presence).
        var lastAssistantByTurn: [Int: ChatItem] = [:]
        var assistantTextsByTurn: [Int: [String]] = [:]
        var plansByTurn: [Int: [NativeTimelinePlanEntry]] = [:]
        var changeKeysByTurn: [Int: [String]] = [:]
        var contentRowCountsByTurn: [Int: Int] = [:]
        var usageByTurn: [Int: NativeTurnUsage] = [:]
        var usageMessageIDsByTurn: [Int: Set<String>] = [:]
        for item in visibleItems {
            guard let turn = item.turn else { continue }
            switch item.kind {
            case .assistant:
                lastAssistantByTurn[turn] = item
                assistantTextsByTurn[turn, default: []].append(item.text)
            case .toolCall:
                if item.toolName == "exit_plan_mode",
                   let markdown = item.arguments?["plan"]?.stringValue,
                   let plan = NativePlanCardData(id: item.callID ?? item.id, markdown: markdown) {
                    plansByTurn[turn, default: []].append(
                        NativeTimelinePlanEntry(plan: plan, markdown: markdown))
                }
                if ["write", "edit", "str_replace_editor"].contains(item.toolName ?? "") {
                    changeKeysByTurn[turn, default: []].append(
                        "\(item.id)#\(item.toolName ?? "")#\(item.renderRevision)#\(item.toolState?.rawValue ?? "nil")")
                }
            default:
                break
            }
            if item.kind != .user && item.kind != .context {
                contentRowCountsByTurn[turn, default: 0] += 1
            }
            if let usage = item.turnUsage {
                // Same accumulation as `NativeTranscriptProjector.usage`, kept
                // in one pass so the tail row never scans the transcript.
                var counted = true
                if let messageID = item.messageID {
                    counted = usageMessageIDsByTurn[turn, default: []].insert(messageID).inserted
                }
                guard counted else { continue }
                if var total = usageByTurn[turn] {
                    total.add(usage)
                    usageByTurn[turn] = total
                } else {
                    usageByTurn[turn] = usage
                }
            }
        }

        let answerIDs: [Int: String] = lastAssistantByTurn.mapValues(\.id)
        let rowItems = visibleItems.filter { item in
            guard let turn = item.turn, foldedTurns.contains(turn),
                  let answerID = answerIDs[turn] else { return true }
            if item.kind == .user || item.kind == .context { return true }
            return item.id == answerID
        }

        var rows: [NativeTranscriptRow] = []
        var lastTurn: Int?
        var pendingTurnControl: Int?
        for item in rowItems {
            // A new prompt closes the previous Turn's tail above itself. User
            // rows often carry no turn number, so waiting for the next Turn's
            // first answer row would drop that tail under the new bubble.
            if item.kind == .user, let previous = lastTurn, item.turn != previous,
               let state = stateFor(previous), state != .running {
                rows.append(.turnTail(previous))
                lastTurn = nil
            }
            if let turn = item.turn, turn != lastTurn {
                if let previous = lastTurn, previous != turn,
                   stateFor(previous) != nil {
                    rows.append(.turnTail(previous))
                }
                lastTurn = turn
                pendingTurnControl = stateFor(turn) != nil ? turn : nil
            }
            // The official control row sits after the Turn's input and before
            // its process (controlAnchorSeq - 0.1), so defer it past user /
            // trigger rows instead of placing it above the prompt.
            if let pending = pendingTurnControl,
               item.kind != .user, item.kind != .context {
                rows.append(.turnProcess(pending))
                pendingTurnControl = nil
            }
            if item.kind == .context {
                if case .contexts(let previous)? = rows.last {
                    rows[rows.count - 1] = .contexts(previous + [item])
                } else {
                    rows.append(.contexts([item]))
                }
            } else if Self.isProcessKind(item.kind) {
                // A turn's reasoning/tool activity is process, not content: one
                // row for the whole run, opened on demand.
                if case .tools(let previous)? = rows.last {
                    rows[rows.count - 1] = .tools(previous + [item])
                } else {
                    rows.append(.tools([item]))
                }
            } else {
                rows.append(.item(item))
            }
        }
        if let lastTurn, stateFor(lastTurn) != nil {
            rows.append(.turnTail(lastTurn))
        }

        var turnFacts: [Int: NativeTimelineTurnFacts] = [:]
        for (turn, assistant) in lastAssistantByTurn {
            var facts = NativeTimelineTurnFacts()
            facts.plans = plansByTurn[turn] ?? []
            facts.copyText = (assistantTextsByTurn[turn] ?? []).joined(separator: "\n\n")
            facts.usage = usageByTurn[turn]
            // The closing assistant itself is one of the Turn's non-input rows,
            // so more than one means folding would hide a process row.
            facts.hasProcess = (contentRowCountsByTurn[turn] ?? 0) > 1
            if !assistant.streaming {
                facts.closingAssistantID = assistant.id
                facts.closingMessageID = assistant.messageID
                facts.closingTimestamp = assistant.timestamp
                let signature = (changeKeysByTurn[turn] ?? []).joined(separator: ",")
                facts.changes = changesCache.changes(forTurn: turn, signature: signature) {
                    NativeTranscriptProjector.changes(forTurn: turn, in: visibleItems)
                }
            }
            turnFacts[turn] = facts
        }

        let signaturePrefix = visibleItems.map(\.id).joined(separator: ",") + "|"
        let scrollSignature = signaturePrefix + (visibleItems.last?.text ?? "")
        let inputs = visibleItems.filter { $0.kind == .user || $0.kind == .context }
        let inputRowSignature = "\(inputs.count)|\(inputs.last?.id ?? "-")"

        return NativeTimelineSnapshot(rows: rows,
                                      visibleItems: visibleItems,
                                      turnFacts: turnFacts,
                                      scrollSignature: scrollSignature,
                                      inputRowSignature: inputRowSignature,
                                      scrollSignaturePrefix: signaturePrefix)
    }

    private static func isProcessKind(_ kind: ChatItem.Kind) -> Bool {
        switch kind {
        case .reasoning, .toolCall, .toolResult: return true
        default: return false
        }
    }
}

// MARK: - Render window

/// How many transcript rows one body pass may materialize.
///
/// Field evidence (iPhone 17 Pro, iPhoneOS 27.0): re-adopting a 600-row
/// session put every row into one `LazyVStack` pass; the main thread spent
/// the whole 10 s scene-update allowance in
/// `DisplayList.ViewUpdater.ViewCache.update` and FRONTBOARD killed the app
/// with `0x8BADF00D`. The page therefore renders the newest rows only and
/// grows that window through the existing "load earlier" sentinel — first
/// from rows already in memory, then from the host's older page.
enum NativeTranscriptRenderWindow {
    /// Rows a fresh page materializes behind the tail. A screen holds a
    /// handful of blocks, so this is already far more than one viewport.
    static let initialRows = 96
    /// Rows one explicit "load earlier" adds.
    static let pageRows = 64

    /// The newest rows, clamped to what exists.
    static func tailRange(rowCount: Int, limit: Int) -> Range<Int> {
        let count = max(0, rowCount)
        let keep = min(count, max(0, limit))
        return (count - keep)..<count
    }

    /// One "load earlier" step. Clamped to `rowCount` so the sentinel can tell
    /// when every loaded row is on screen; a host page is added on top through
    /// `growing(by:)`.
    static func grownLimit(_ limit: Int, rowCount: Int) -> Int {
        min(max(0, rowCount), max(0, limit) + pageRows)
    }

    /// After a host page prepended `addedRows`, the same rows must stay on
    /// screen and the new page must become reachable, so the window grows by
    /// the delta.
    static func growing(_ limit: Int, by addedRows: Int, rowCount: Int) -> Int {
        min(max(0, rowCount), max(0, limit) + max(0, addedRows))
    }
}

// MARK: - Background gate

/// Which transcript mutations may run while the App is not on screen.
///
/// The scene-update watchdog measures wall-clock main-thread time, and iOS
/// charges work done in the background to the same budget as visible work.
/// Status rows are diagnostics nobody can read while hidden, and a history
/// adoption replaces the whole transcript (the expensive page pass), so both
/// wait for `.active` instead of invalidating the page in the background.
struct ChatTranscriptGate: Equatable {
    /// False while the scene is not active.
    var isForeground: Bool
    /// Adoptions parked while hidden. Diagnostics only; the model owns the
    /// pending value because it also owns the rows.
    private(set) var deferredAdoptions = 0
    /// Rows were delivered after the newest adoption parked. The App can still
    /// execute while hidden (background keep-alive, a recovering event stream),
    /// and those rows land on the old transcript, so the parked snapshot is
    /// now **older** than the screen: committing it would drop them.
    private(set) var parkedAdoptionIsStale = false

    init(isForeground: Bool = true) {
        self.isForeground = isForeground
    }

    /// True when a status row may be appended. Status rows are diagnostics the
    /// page never draws, so while hidden the caller appends nothing and only
    /// keeps the status log line.
    var admitsStatusRow: Bool { isForeground }

    /// The row a foreground caller may append. Built here so the one status-row
    /// shape has a single definition; the caller owns the append because
    /// `items` has a `didSet` that must only fire on a real mutation (passing
    /// it `inout` would write it back and bump the revision either way).
    func statusRow(_ text: String) -> ChatItem? {
        guard isForeground else { return nil }
        return ChatItem(kind: .status, title: "Host", text: text)
    }

    /// True when the caller may replace the rows now. While hidden the caller
    /// parks the adoption and this records one deferral. A fresh park starts
    /// current: `noteRowsMayHaveChanged` marks it stale when the event pump
    /// delivers rows behind the App's back.
    mutating func takeAdoptionSlot() -> Bool {
        guard isForeground else {
            deferredAdoptions &+= 1
            parkedAdoptionIsStale = false
            return false
        }
        return true
    }

    /// The event pump delivered (or coalesced) rows that mutate the painted
    /// transcript. Called for every handled event; it only matters while an
    /// adoption is parked, where it supersedes the parked snapshot.
    mutating func noteRowsMayHaveChanged() {
        if deferredAdoptions > 0 { parkedAdoptionIsStale = true }
    }

    /// The parked adoption's commit decision, taken exactly once when the
    /// scene is active again: `false` means rows changed after the snapshot
    /// parked, so the caller must re-read the transcript in the foreground
    /// instead of overwriting live rows with the older snapshot.
    mutating func beginParkedAdoptionCommit() -> Bool {
        let commit = !parkedAdoptionIsStale
        if deferredAdoptions > 0 { deferredAdoptions -= 1 }
        parkedAdoptionIsStale = false
        return commit
    }
}
