// SPDX-License-Identifier: MIT

import Combine
import Foundation
import PhoneDSHAgentCore

@MainActor
private final class BotStreamCoalescer {
    private var pending: (turnID: String, text: String)?
    private var task: Task<Void, Never>?

    func submit(turnID: String, text: String, deliver: @escaping (String) -> Void) {
        pending = (turnID, text)
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }
                self?.flush(deliver: deliver)
            }
        }
    }

    func finish(text: String, deliver: @escaping (String) -> Void) {
        task?.cancel()
        task = nil
        pending = nil
        deliver(text)
    }

    func cancel() {
        task?.cancel()
        task = nil
        pending = nil
    }

    private func flush(deliver: @escaping (String) -> Void) {
        guard let pending else { return }
        self.pending = nil
        deliver(pending.text)
    }
}

enum BotChatModelError: LocalizedError {
    case runtimeUnavailable

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable: return "Bot 运行时未连接：动作未执行。"
        }
    }
}

enum BotUIActionState: Equatable {
    case pending
    case accepted
    case failed(String)
}

@MainActor
final class BotChatModel: ObservableObject {
    @Published private(set) var rows: [BotUIRow]
    @Published private(set) var streamingText: String?
    @Published private(set) var runningTurnID: String?
    @Published private(set) var actionStates: [String: BotUIActionState] = [:]
    @Published private(set) var dismissedCardIDs: Set<String> = []
    @Published private(set) var actionLog: [String] = []
    @Published var runtimeNotice: String?
    @Published var deepLinkError: String?
    @Published var scrollRequestID: String?
    @Published private(set) var loadingHistory = false
    @Published private(set) var hasMoreHistory = false
    /// The running main-chat turn as DSH draws it (streamed text, live tool
    /// rows); nil when no turn is running and the durable rows are current.
    @Published private(set) var live: BotLiveTurn?
    /// Tool steps of finished turns, keyed by DSH turn number.
    @Published private(set) var turnProcesses: [Int: BotTurnProcess] = [:]
    private var pendingDelta = ""
    private var deltaFlush: Task<Void, Never>?

    let context: BotRuntimeContext
    private let driver: BotChatDriver?
    /// Only fixture/preview models may fabricate an accepted action without a
    /// production driver. The default must fail loudly, never pretend success.
    private let fixtureActions: Bool
    private let stream = BotStreamCoalescer()
    private var cancelledTurnIDs: Set<String> = []
    private var consumedNonces: [String: String] = [:]
    private var fixtureHistory: [BotUIRow]
    private var fixtureHistoryCursor: String?
    private var historyCursor: String?
    private let historyPageSize = 50
    private var watchCursor = 0
    private var watching = false

    init(rows: [BotUIRow] = [], context: BotRuntimeContext = BotRuntimeContext(),
         driver: BotChatDriver? = nil, fixtureHistory: [BotUIRow] = [],
         fixtureActions: Bool = false) {
        self.rows = rows.sorted { $0.seq < $1.seq }
        self.context = context
        self.driver = driver
        self.fixtureActions = fixtureActions
        self.fixtureHistory = fixtureHistory
        self.fixtureHistoryCursor = fixtureHistory.first?.id
        self.hasMoreHistory = driver != nil || !fixtureHistory.isEmpty
    }

    var visibleRows: [BotUIRow] {
        rows.filter { BotUIRendering.isRenderable($0) && !dismissedCardIDs.contains($0.id) }
    }

    /// The transcript: while a turn is live its answer text is drawn from the
    /// live frames, so the durable copies of that turn wait until it ends.
    var displayRows: [BotUIRow] {
        guard let turn = live?.turn else { return visibleRows }
        return visibleRows.filter { !(Self.isAnswer($0) && Self.turn(of: $0) == turn) }
    }

    static func turn(of row: BotUIRow) -> Int? { row.body["turn"]?.int }

    static func isAnswer(_ row: BotUIRow) -> Bool {
        row.role == "assistant" && row.body.type == "text"
    }

    var pendingApprovalCount: Int {
        visibleRows.filter { row in
            guard row.body.type == "approval" else { return false }
            let status = row.body["status"]?.string ?? row.body["ask"]?.object?["status"]?.string ?? "pending"
            return status == "pending" && actionStates["approval:\(row.id)"] != .accepted
        }.count
    }

    var needsAttentionCount: Int {
        let choices = visibleRows.filter { row in
            guard let card = BotUICardContent.parse(row: row), card.kind == .question || card.kind == .steps else {
                return false
            }
            return !mutedCardIDs.contains(row.id) && actionStates["card:\(row.id)"] != .accepted
        }.count
        return pendingApprovalCount + choices
    }

    var followingCount: Int {
        if let injected = context.followingCount { return injected }
        return visibleRows.filter { row in
            guard let card = BotUICardContent.parse(row: row) else { return false }
            switch card.kind {
            case .automation:
                let status = row.body["status"]?.string ?? row.body["automation"]?.object?["status"]?.string ?? "sent"
                return status == "running" || status == "confirming"
            case .progress:
                return (row.body["state"]?.string ?? "running") == "running"
            case .task:
                let status = row.body["status"]?.string ?? row.body["task"]?.object?["status"]?.string ?? ""
                return ["running", "active", "in_progress", "working"].contains(status)
            default:
                return false
            }
        }.count
    }

    var mutedCardIDs: Set<String> {
        guard let lastUserIndex = visibleRows.lastIndex(where: { $0.role == "user" && $0.body.type == "text" }) else {
            return []
        }
        let ordered = visibleRows
        return Set(ordered[..<lastUserIndex].compactMap { row in
            guard let card = BotUICardContent.parse(row: row), card.kind == .question || card.kind == .steps,
                  actionStates["card:\(row.id)"] == nil else { return nil }
            return row.id
        })
    }

    func isActionPending(_ key: String) -> Bool { actionStates[key] == .pending }

    func send(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let nonce = UUID().uuidString
        let action = BotUIUserAction.chat(nonce: nonce, botID: context.botID, text: trimmed)
        let localID = "local-\(nonce)"
        let local = BotUIRow.text(id: localID, botID: context.botID,
                                  seq: (rows.map(\.seq).max() ?? 0) + 1,
                                  role: "user", text: trimmed, eventID: "local:\(nonce)")
        rows.append(local)
        if driver == nil && fixtureActions && runningTurnID == nil {
            beginTurn(turnID: "fixture-turn")
        }
        Task { await perform(action, key: "chat:\(localID)", localRowID: localID) }
    }

    func answer(row: BotUIRow, optionID: String) {
        let key = "card:\(row.id)"
        guard actionStates[key] == nil || actionStates[key].map({ if case .failed = $0 { return true }; return false }) == true,
              !mutedCardIDs.contains(row.id), !optionID.isEmpty else { return }
        actionStates[key] = .pending
        let action = BotUIUserAction.cardAnswer(nonce: UUID().uuidString, botID: row.botID,
                                                cardID: row.id, optionID: optionID)
        Task { await perform(action, key: key, localRowID: nil) }
    }

    func dismiss(row: BotUIRow) {
        guard BotUICardContent.parse(row: row)?.kind == .question else { return }
        let key = "dismiss:\(row.id)"
        guard actionStates[key] == nil else { return }
        actionStates[key] = .pending
        let action = BotUIUserAction.cardDismiss(nonce: UUID().uuidString, botID: row.botID, cardID: row.id)
        Task { await perform(action, key: key, localRowID: nil) }
    }

    func decide(row: BotUIRow, decision: BotUIApprovalDecision) {
        let key = "approval:\(row.id)"
        guard actionStates[key] == nil || actionStates[key].map({ if case .failed = $0 { return true }; return false }) == true,
              let approvalID = row.body.string("approvalID", "requestId", "id")
                ?? row.body["ask"]?.object?["requestId"]?.string,
              let digest = row.body["digest"]?.string else { return }
        actionStates[key] = .pending
        let action = BotUIUserAction.approval(nonce: UUID().uuidString, botID: row.botID,
                                              approvalID: approvalID, decision: decision, digest: digest)
        Task { await perform(action, key: key, localRowID: nil) }
    }

    func stop() {
        guard let turnID = runningTurnID else { return }
        cancelledTurnIDs.insert(turnID)
        runningTurnID = nil
        streamingText = nil
        stream.cancel()
        actionLog.append("stop:\(turnID)")
        Task { await driver?.stopCurrentTurn(turnID) }
    }

    func beginTurn(turnID: String) {
        cancelledTurnIDs.remove(turnID)
        runningTurnID = turnID
        streamingText = nil
    }

    func receiveStream(turnID: String, text: String, final: Bool = false) {
        guard runningTurnID == turnID, !cancelledTurnIDs.contains(turnID) else { return }
        if final {
            stream.cancel()
            streamingText = nil
            runningTurnID = nil
            guard !text.isEmpty else { return }
            upsert(BotUIRow.text(id: "stream-\(turnID)", botID: context.botID,
                                 seq: (rows.map(\.seq).max() ?? 0) + 1,
                                 role: "assistant", text: text, eventID: "evt-stream-\(turnID)"))
        } else {
            stream.submit(turnID: turnID, text: text) { [weak self] latest in
                guard self?.runningTurnID == turnID, self?.cancelledTurnIDs.contains(turnID) == false else { return }
                self?.actionLog.append("stream")
                self?.streamingText = latest
            }
        }
    }

    func apply(_ batch: BotUIRowBatch) {
        var incoming = batch.rows[...]
        if batch.reset {
            rows.removeAll { !$0.id.hasPrefix("local-") }
            if driver != nil {
                incoming = incoming.suffix(historyPageSize)
                historyCursor = incoming.first?.id
                hasMoreHistory = batch.rows.count > incoming.count
            }
        }
        if !batch.deletes.isEmpty {
            let deleted = Set(batch.deletes)
            rows.removeAll { deleted.contains($0.id) }
        }
        incoming.forEach(upsert)
        watchCursor = batch.cursor
    }

    func upsert(_ row: BotUIRow) {
        guard row.body.type != "deleted" else {
            rows.removeAll { $0.id == row.id }
            return
        }
        if let nonce = row.chatActionNonce {
            rows.removeAll { $0.id == "local-\(nonce)" }
        }
        var index = rows.firstIndex(where: { $0.id == row.id })
        if index == nil, row.body.cardType == "progress", let cardKey = row.body.cardKey {
            index = rows.firstIndex(where: { $0.body.cardType == "progress" && $0.body.cardKey == cardKey })
        }
        if index == nil {
            let eventIDs = Set(row.provenance.eventIDs)
            index = rows.firstIndex(where: { $0.id.hasPrefix("local-") && !Set($0.provenance.eventIDs).isDisjoint(with: eventIDs) })
        }
        if let index {
            if rows[index].id == row.id && rows[index].updatedSeq > row.updatedSeq { return }
            rows[index] = row
        } else {
            rows.append(row)
        }
        rows.sort { $0.seq < $1.seq }
    }

    /// Polls the production row projection until the view's `.task` is
    /// cancelled. Fixture models have no driver and simply do not run it.
    func watchLoop() async {
        guard let driver, !watching else { return }
        watching = true
        defer { watching = false }
        while !Task.isCancelled {
            do {
                let batch = try await driver.watch(watchCursor)
                apply(batch)
                let processes = await driver.turnProcesses()
                if processes != turnProcesses { turnProcesses = processes }
                settleLive()
            } catch {
                runtimeNotice = "Bot 实时更新失败：\(error.localizedDescription)"
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
    }

    /// Follows the running turn's live frames until the view's `.task` ends.
    func liveLoop() async {
        guard let driver else { return }
        for await frame in await driver.liveFrames() {
            receive(frame)
        }
    }

    func receive(_ frame: BotLiveFrame) {
        switch frame {
        case .streamStart:
            pendingDelta = ""
            var turn = live ?? BotLiveTurn()
            turn.buffer = ""
            live = turn
        case .textDelta(let text):
            if live == nil { live = BotLiveTurn() }
            pendingDelta += text
            guard deltaFlush == nil else { return }
            deltaFlush = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard !Task.isCancelled else { return }
                self?.flushDelta()
            }
        case .event(let event):
            let type = event["type"]?.stringValue ?? ""
            if type == "turn/start" {
                pendingDelta = ""
                deltaFlush?.cancel()
                deltaFlush = nil
                live = BotLiveTurn()
            } else {
                flushDelta()
            }
            var turn = live ?? BotLiveTurn()
            turn.apply(event: event)
            live = turn
            if type == "turn/start" {
                runningTurnID = (event["data"]?["turn"]?.intValue).map(String.init)
                streamingText = nil
            } else if type == "turn/end" {
                runningTurnID = nil
            }
        }
    }

    private func flushDelta() {
        deltaFlush?.cancel()
        deltaFlush = nil
        guard !pendingDelta.isEmpty, var turn = live, !turn.ended else {
            pendingDelta = ""
            return
        }
        turn.buffer += pendingDelta
        pendingDelta = ""
        live = turn
    }

    /// After `turn/end` the live view stays until the row projection shows
    /// the turn's answer, so the reply never blinks out between the two.
    private func settleLive() {
        guard var turn = live, turn.ended else { return }
        turn.pollsSinceEnd += 1
        let committed = turn.turn.map { number in
            rows.contains { Self.isAnswer($0) && Self.turn(of: $0) == number }
        } ?? true
        if (committed && turn.pollsSinceEnd >= 2) || turn.pollsSinceEnd >= 4 {
            live = nil
        } else {
            live = turn
        }
    }

    func loadHistory() async {
        guard hasMoreHistory, !loadingHistory else { return }
        loadingHistory = true
        defer { loadingHistory = false }
        do {
            let page: BotUIHistoryPage
            if let driver {
                let anchor = historyCursor ?? rows.first(where: { !$0.id.hasPrefix("local-") })?.id
                page = try await driver.history(anchor, historyPageSize)
            } else if fixtureActions {
                page = BotUIHistoryPage(rows: fixtureHistory, nextCursor: nil, hasMore: false)
                fixtureHistory = []
            } else {
                throw BotChatModelError.runtimeUnavailable
            }
            page.rows.forEach(upsert)
            historyCursor = page.nextCursor
            hasMoreHistory = page.hasMore
        } catch {
            runtimeNotice = "历史加载失败：\(error.localizedDescription)"
        }
    }

    @discardableResult
    func openDeepLink(_ url: URL) -> Bool {
        guard let link = BotDeepLink(url: url), link.botID == context.botID,
              visibleRows.contains(where: { $0.id == link.rowID }) else {
            deepLinkError = "这条消息不可用或已过期。"
            return false
        }
        deepLinkError = nil
        scrollRequestID = link.rowID
        return true
    }

    private func perform(_ action: BotUIUserAction, key: String, localRowID: String?) async {
        let result: BotUIActionResult
        if let driver {
            actionLog.append(action.logLabel)
            result = await driver.perform(action)
        } else if fixtureActions {
            result = fixturePerform(action)
        } else {
            // The production page always injects a driver. If it is absent the
            // Bot runtime is disconnected; report that instead of fabricating
            // an accepted event.
            result = .rejected(reason: BotChatModelError.runtimeUnavailable.localizedDescription)
        }
        if let eventID = result.eventID {
            actionStates[key] = .accepted
            if let localRowID, let index = rows.firstIndex(where: { $0.id == localRowID }) {
                rows[index].provenance.eventIDs = [eventID]
            }
            if case .cardDismiss = action { dismissedCardIDs.insert(action.cardID) }
            if case .approval(_, _, _, let decision, _) = action, let rowID = approvalRowID(action: action) {
                updateApproval(rowID: rowID, decision: decision)
            }
        } else {
            let reason = result.reason ?? "动作未完成"
            actionStates[key] = .failed(reason)
            if let localRowID { rows.removeAll { $0.id == localRowID } }
            runtimeNotice = reason
        }
    }

    private func fixturePerform(_ action: BotUIUserAction) -> BotUIActionResult {
        actionLog.append(action.logLabel)
        if let eventID = consumedNonces[action.nonce] { return .duplicate(eventID: eventID) }
        let eventID = "evt-action-\(consumedNonces.count + 1)"
        consumedNonces[action.nonce] = eventID
        return .accepted(eventID: eventID)
    }

    private func approvalRowID(action: BotUIUserAction) -> String? {
        guard case .approval(_, _, let approvalID, _, _) = action else { return nil }
        return rows.first(where: { ($0.body.string("approvalID", "requestId", "id")
                                    ?? $0.body["ask"]?.object?["requestId"]?.string) == approvalID })?.id
    }

    private func updateApproval(rowID: String, decision: BotUIApprovalDecision) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        let status: String
        switch decision {
        case .allowOnce: status = "allowed"
        case .always: status = "always"
        case .deny: status = "denied"
        }
        rows[index].body.values["status"] = .string(status)
        rows[index].updatedSeq += 1
    }
}

private extension BotUIUserAction {
    var logLabel: String {
        switch self {
        case .chat: return "chat"
        case .cardAnswer: return "cardAnswer"
        case .cardDismiss: return "cardDismiss"
        case .approval(_, _, _, let decision, _): return "approval:\(decision.rawValue)"
        case .stopTask: return "stopTask"
        }
    }

    var cardID: String {
        switch self {
        case .cardAnswer(_, _, let cardID, _), .cardDismiss(_, _, let cardID): cardID
        default: ""
        }
    }
}
