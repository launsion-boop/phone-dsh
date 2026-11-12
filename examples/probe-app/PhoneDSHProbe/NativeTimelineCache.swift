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

import Foundation
import ProbeKit

struct NativeTimelinePlanEntry: Equatable {
    let plan: NativePlanCardData
    let markdown: String
}

struct NativeTimelineTurnFacts: Equatable {
    var closingAssistantID: String?
    var plans: [NativeTimelinePlanEntry] = []
    var changes: NativeChangedFiles?

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
                  endTimes: [Int: Date]) -> NativeTimelineSnapshot {
        let key = Key(itemsRevision: itemsRevision,
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
              items.indices.dropLast().allSatisfy({ items[$0] == cachedItems[$0] }),
              cachedSnapshot.visibleItems.last?.id == last.id,
              let lastRow = cachedSnapshot.rows.last else { return nil }

        var rows = cachedSnapshot.rows
        switch lastRow {
        case .item(let rowItem):
            guard rowItem.id == last.id, !Self.isProcessKind(last.kind) else { return nil }
            rows[rows.count - 1] = .item(last)
        case .tools(let group):
            guard Self.isProcessKind(last.kind), group.last?.id == last.id else { return nil }
            var next = group
            next[next.count - 1] = last
            rows[rows.count - 1] = .tools(next)
        default:
            return nil
        }
        var visible = cachedSnapshot.visibleItems
        visible[visible.count - 1] = last
        let signature = cachedSnapshot.scrollSignaturePrefix + last.text
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

        // One pass over the visible transcript feeds both the grouping and the
        // per-row facts that used to filter all items again inside each row.
        var lastAssistantByTurn: [Int: ChatItem] = [:]
        var plansByTurn: [Int: [NativeTimelinePlanEntry]] = [:]
        var changeKeysByTurn: [Int: [String]] = [:]
        for item in visibleItems {
            guard let turn = item.turn else { continue }
            switch item.kind {
            case .assistant:
                lastAssistantByTurn[turn] = item
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
            if !assistant.streaming {
                facts.closingAssistantID = assistant.id
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
