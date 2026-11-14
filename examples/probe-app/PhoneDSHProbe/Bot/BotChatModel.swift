// SPDX-License-Identifier: MIT

import Combine
import Foundation
import PhoneDSHAgentCore
import PhoneDSHBot

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
                guard !Task.isCancelled, let self else { return }
                // No pending text means the turn's final frame already
                // consumed it (or none arrived); the 100ms loop must not keep
                // waking the main thread between turns.
                guard self.flush(deliver: deliver) else { break }
            }
            self?.task = nil
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

    private func flush(deliver: @escaping (String) -> Void) -> Bool {
        guard let pending else { return false }
        self.pending = nil
        deliver(pending.text)
        return true
    }

    deinit {
        task?.cancel()
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

enum BotCardSettlementTone: Equatable {
    case neutral
    case success
}

/// The one-line summary that replaces an interactive card once it no longer
/// needs the user: the same shape as the approval's decided row.
struct BotCardSettlement: Equatable {
    var glyph: String
    var title: String
    var detail: String?
    var tone: BotCardSettlementTone = .neutral
    /// The approval detail is a command, so it keeps the monospaced style.
    var monospacedDetail = false
}

/// Local checklist progress and the result of sending it back to the Bot.
/// `sending` keeps the full card until the chat action is accepted; `sent`
/// switches to the one-line summary.
struct BotChecklistProgress: Equatable {
    var done: Int
    var total: Int
    var sending = false
    var sent = false
}

/// The checklist state a card carries into `send`.
private struct BotChecklistSend {
    var rowID: String
    var done: Int
    var total: Int
}

@MainActor
final class BotChatModel: ObservableObject {
    @Published private(set) var rows: [BotUIRow]
    @Published private(set) var streamingText: String?
    @Published private(set) var runningTurnID: String?
    /// A send was appended locally but the host has not started the turn yet.
    /// The status line covers that gap too; the flag is cleared when the turn
    /// starts, the action fails, the user stops, or the 120s fallback expires.
    @Published private(set) var awaitingTurn = false
    /// The user stopped this turn or its final reply arrived and the host's
    /// `turn/end` has not arrived yet. The status line stays hidden while the
    /// live text remains visible until the durable rows take over.
    @Published private(set) var lineSuppressed = false
    /// The durable runtime projection: fish lifecycle and current action.
    @Published private(set) var runtimePresentation = BotRuntimePresentation()
    /// The same projection rebuilt from the live turn frames, which are the
    /// authority while a turn is running.
    @Published private(set) var livePresentation: BotRuntimePresentation?
    /// Agent-driven one-shot FishAction for every avatar of this Bot.
    @Published private(set) var reaction: BotFishReaction?
    /// Sixty seconds without a turn or a touch: the fish sleeps until the
    /// next interaction. Approvals and running turns always win over this.
    @Published private(set) var idleSleeping = false
    @Published private(set) var actionStates: [String: BotUIActionState] = [:]
    @Published private(set) var dismissedCardIDs: Set<String> = []
    /// Approvals this local send declined automatically ("发消息时自动拒绝").
    /// They still went through the existing approval `deny` action; the set
    /// only changes the settled summary.
    @Published private(set) var autoDeclinedApprovalIDs: Set<String> = []
    @Published private(set) var checklistProgress: [String: BotChecklistProgress] = [:]
    @Published private(set) var actionLog: [String] = []
    /// The option picked on a choice card, kept locally so an accepted answer
    /// can still show its label before the durable row round-trips.
    private var answeredOptionIDs: [String: String] = [:]
    /// The latest failure (live update, history, an action, an attachment, or
    /// a newly arrived host error notice). It is shown only on the header
    /// status line, clears itself after `runtimeNoticeLifetime`, and is
    /// cleared at once by the next send. A failure that keeps repeating (the
    /// watch loop) keeps re-arming the timer, so it stays while it lasts.
    @Published var runtimeNotice: String? {
        didSet { armRuntimeNoticeExpiry() }
    }
    static let runtimeNoticeLifetime: UInt64 = 6_000_000_000
    private var runtimeNoticeExpiry: Task<Void, Never>?
    @Published var deepLinkError: String?
    /// The current Bot's profile appearance, mirrored from `BotProfileCenter`.
    @Published private(set) var appearance: BotFishAppearance = .classic
    /// The profile name is authoritative once the profile index exists; before
    /// that it is the runtime context name (the last `renamed` event).
    @Published private(set) var botName: String
    /// Mirrors the roster's main-Bot pointer for the crown on the header and
    /// the empty state.
    @Published private(set) var isMainBot = false
    /// Importing is an app-layer dependency: the fixture model leaves it nil and
    /// the production hub injects the real workspace importer.
    var attachmentImporter: (any BotAttachmentImporting)?
    /// Lets the production hub reset the per-Bot idle clock in the runtime
    /// unit when this page sees a touch, so the sidebar and the page agree.
    var onInteraction: (() -> Void)?
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
    private var awaitingTurnTimeout: Task<Void, Never>?
    /// Live frames of the open turn, replayed through the one director mapper.
    private var liveFish: BotLiveFishProjection
    private var fishExpiryTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    /// UI polling is allowed only while the Bot page is selected and the scene
    /// is active. The page owns the watch/live tasks; this flag makes a
    /// lingering task harmless and lets pause drop transient UI state.
    private var pageActive = true
    /// Invalidates an older watch task that has not observed cancellation yet
    /// when the page becomes visible again.
    private var watchGeneration = 0

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
    private var profileCancellables: Set<AnyCancellable> = []

    init(rows: [BotUIRow] = [], context: BotRuntimeContext,
         driver: BotChatDriver? = nil, fixtureHistory: [BotUIRow] = [],
         fixtureActions: Bool = false, profileCenter: BotProfileCenter? = nil) {
        self.rows = rows.sorted { $0.seq < $1.seq }
        self.context = context
        self.driver = driver
        self.fixtureActions = fixtureActions
        self.fixtureHistory = fixtureHistory
        self.fixtureHistoryCursor = fixtureHistory.first?.id
        self.hasMoreHistory = driver != nil || !fixtureHistory.isEmpty
        self.botName = context.botName
        self.liveFish = BotLiveFishProjection(botID: context.botID)
        attach(profileCenter: profileCenter)
    }

    func setMainBot(_ isMain: Bool) {
        guard isMainBot != isMain else { return }
        isMainBot = isMain
    }

    /// Mirrors the profile center's name and appearance into the published
    /// values the page and the fish renderer read.
    func attach(profileCenter: BotProfileCenter?) {
        profileCancellables.removeAll()
        guard let center = profileCenter else { return }
        appearance = center.appearance
        botName = center.displayName
        center.$appearance
            .sink { [weak self] value in
                Task { @MainActor [weak self] in self?.appearance = value }
            }
            .store(in: &profileCancellables)
        center.$displayName
            .sink { [weak self] value in
                Task { @MainActor [weak self] in self?.botName = value }
            }
            .store(in: &profileCancellables)
    }

    var visibleRows: [BotUIRow] {
        // A dismissed question is not hidden: it settles into its one-line
        // 「已关闭」 summary like every other handled interactive card.
        rows.filter { BotUIRendering.isRenderable($0) && !Self.isNotice($0) }
    }

    /// Error and denial notices never enter the Bot transcript: a failure is
    /// reported on the header status line (`runtimeNotice`), and a denial is
    /// already the approval card's settled 「已拒绝」 line.
    static func isNotice(_ row: BotUIRow) -> Bool {
        row.body.type == "notice"
    }

    private func armRuntimeNoticeExpiry() {
        runtimeNoticeExpiry?.cancel()
        runtimeNoticeExpiry = nil
        guard runtimeNotice != nil else { return }
        runtimeNoticeExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.runtimeNoticeLifetime)
            guard !Task.isCancelled else { return }
            self?.runtimeNotice = nil
        }
    }

    /// The transcript: while a turn is live its answer text is drawn from the
    /// live frames, so the durable copies of that turn wait until it ends.
    var displayRows: [BotUIRow] {
        guard let turn = live?.turn else { return visibleRows }
        return visibleRows.filter { !(Self.isAnswer($0) && Self.turn(of: $0) == turn) }
    }

    /// IDs of the interactive cards currently drawn as one-line settled
    /// summaries. The transcript watches this set: when a card collapses the
    /// content gets shorter while the scroll offset stays at the old bottom,
    /// so it scrolls to the bottom once more after the collapse animation.
    var settledRowIDs: Set<String> {
        Set(displayRows.compactMap { row in
            settlement(for: row) == nil ? nil : row.id
        })
    }

    static func turn(of row: BotUIRow) -> Int? { row.body["turn"]?.int }

    static func isAnswer(_ row: BotUIRow) -> Bool {
        row.role == "assistant" && row.body.type == "text"
    }

    /// An approval is still awaiting the user until a local decision is in
    /// flight (`.pending`) or accepted. Excluding `.pending` makes the header
    /// leave「等你确认」the moment the user sends the next message, before the
    /// asynchronous deny round-trip completes.
    private var approvalsAwaitingDecision: [BotUIRow] {
        visibleRows.filter { row in
            guard row.body.type == "approval" else { return false }
            let status = row.body["status"]?.string ?? row.body["ask"]?.object?["status"]?.string ?? "pending"
            guard status == "pending" else { return false }
            switch actionStates["approval:\(row.id)"] {
            case .pending, .accepted: return false
            default: return true
            }
        }
    }

    var pendingApprovalCount: Int {
        approvalsAwaitingDecision.count
    }

    var needsAttentionCount: Int {
        let cards = visibleRows.filter { row in
            guard let card = BotUICardContent.parse(row: row) else { return false }
            switch card.kind {
            case .question, .steps:
                return !isActionPending("card:\(row.id)") && settlement(for: row) == nil
            case .checklist:
                guard card.body["interactive"]?.bool != false else { return false }
                if checklistProgress[row.id]?.sending == true { return false }
                return settlement(for: row) == nil
            default:
                return false
            }
        }.count
        return pendingApprovalCount + cards
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

    /// What the fish shows now: the shared fish-lifecycle projection
    /// (`ui-state.md` §4.7). The page contributes its local live/durable
    /// presentation and running signal; the priority itself lives in
    /// `BotFishLifecycleProjection` so the header, empty state and roster
    /// drawer cannot diverge.
    var fishState: BotFishLifecycle {
        let now = BotLiveFishProjection.now
        return BotFishLifecycleProjection.resolve(
            pendingApprovalCount: pendingApprovalCount,
            running: runningTurnID != nil || live != nil,
            idleSleeping: idleSleeping,
            livePresentation: livePresentation.map {
                BotFishLifecyclePresentation(fishState: $0.fishState,
                                             oneShot: $0.oneShot)
            },
            durablePresentation: BotFishLifecyclePresentation(
                fishState: runtimePresentation.fishState,
                oneShot: runtimePresentation.oneShot),
            liveTurn: live != nil,
            now: now)
    }

    /// The durable drawer/header activity: the factory's own status/detail.
    /// The status line uses `lineActivity` instead; this property keeps the
    /// previous "running turn, no pending approval" behavior for other callers.
    var activity: BotActivity? {
        guard runningTurnID != nil, pendingApprovalCount == 0 else { return nil }
        if live != nil { return livePresentation?.activity }
        return runtimePresentation.activity
    }

    /// Whether reply text is arriving right now. Committed `.text` segments do
    /// not count: once a paragraph is committed the line returns to the tool
    /// phrase if the turn goes on to call one.
    var isStreamingNow: Bool {
        if !pendingDelta.isEmpty { return true }
        if streamingText?.isEmpty == false { return true }
        guard let live else { return false }
        return !live.buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The status line spans the whole turn: from the local send (before the
    /// host starts the turn) until final/turn end. Streaming and approvals do
    /// not hide it; stop/final suppress it while the live text stays.
    var showsActivityLine: Bool {
        if awaitingTurn { return true }
        if runningTurnID != nil { return true }
        if let live, !live.ended, !lineSuppressed { return true }
        return false
    }

    /// What the single status line shows, in priority order:
    /// pending approval → waiting; streaming text → replying; the factory's
    /// current phase; thinking fallback while waiting for the first event.
    var lineActivity: BotActivity? {
        guard showsActivityLine else { return nil }
        if pendingApprovalCount > 0 {
            return BotActivity(status: .thinking, detail: "", category: .waiting)
        }
        if isStreamingNow {
            return BotActivity(status: .streaming, detail: "", category: .replying)
        }
        let factoryActivity = live != nil ? livePresentation?.activity : runtimePresentation.activity
        return factoryActivity
            ?? BotActivity(status: .thinking, detail: "", category: .thinking)
    }

    /// The newest row that is still waiting for a person: a pending approval
    /// or an unanswered question/steps/checklist card. The transcript scrolls
    /// to this row's bottom when it exists, because the live text of the same
    /// turn is rendered *after* the durable rows and scrolling to the tail
    /// would push the card's buttons above the keyboard (the field failure).
    /// A card that already collapsed into its one-line settled summary is not
    /// actionable any more; `settlement(for:)` is the single rule for that,
    /// including cards skipped by the next user message.
    var newestActionableCard: BotUIRow? {
        guard let row = displayRows.last,
              let card = BotUICardContent.parse(row: row) else { return nil }
        switch card.kind {
        case .approval, .question, .steps, .checklist:
            if card.kind == .checklist, card.body["interactive"]?.bool == false {
                return nil
            }
            return settlement(for: row) == nil ? row : nil
        default:
            return nil
        }
    }

    /// Interactive cards that were already on screen before the latest user
    /// text and were never handled.
    ///
    /// Question and steps cards are deliberately absent: their staleness is the
    /// durable projection's `status` (`superseded`), computed from the same
    /// event stream the planner refuses with `card_expired`. A second local
    /// rule could only disagree with it, which is exactly the bug this view had
    /// (a card that looked active was expired, and a card that looked stale was
    /// still answerable). A checklist has no durable expiry — its send is an
    /// ordinary chat message — so the send-time guidance stays app-owned.
    /// Approvals are auto-denied on send instead.
    var mutedCardIDs: Set<String> {
        guard let lastUserIndex = visibleRows.lastIndex(where: { $0.role == "user" && $0.body.type == "text" }) else {
            return []
        }
        let ordered = visibleRows
        return Set(ordered[..<lastUserIndex].compactMap { row in
            guard let card = BotUICardContent.parse(row: row),
                  card.kind == .checklist,
                  actionStates["card:\(row.id)"] == nil else { return nil }
            if let state = checklistProgress[row.id], state.sending || state.sent { return nil }
            if card.body["interactive"]?.bool == false { return nil }
            return row.id
        })
    }

    /// The single settlement rule for every interactive card kind. `nil` keeps
    /// the full card: untouched, still sending (`.pending`), or failed and
    /// therefore retryable.
    func settlement(for row: BotUIRow) -> BotCardSettlement? {
        guard let card = BotUICardContent.parse(row: row) else { return nil }
        switch card.kind {
        case .question, .steps:
            return choiceSettlement(row: row, card: card)
        case .checklist:
            return checklistSettlement(row: row, card: card)
        case .approval:
            return approvalSettlement(row: row, card: card)
        default:
            return nil
        }
    }

    private func choiceSettlement(row: BotUIRow, card: BotUICardContent) -> BotCardSettlement? {
        let key = "card:\(row.id)"
        let status = card.body["status"]?.string
        let detail = choiceDetail(card)
        // The durable card status is the one truth for "can this still be
        // answered". It settles even while a local tap is pending or failed: the
        // planner refuses a card that a newer question/steps card replaced, so
        // keeping its buttons would only produce a second refusal.
        if status == "superseded" {
            return BotCardSettlement(glyph: "minus.circle", title: BotChoiceCardUI.supersededTitle,
                                     detail: detail)
        }
        if dismissedCardIDs.contains(row.id) || status == "dismissed" {
            return BotCardSettlement(glyph: "xmark.circle", title: "已关闭", detail: detail)
        }
        if status == "answered" {
            let label = chosenChoiceLabel(row: row, card: card)
            return BotCardSettlement(
                glyph: "checkmark.circle",
                title: label.map { "已选择：\($0)" } ?? "已送出",
                detail: detail)
        }
        // In flight (`.pending`) keeps the full card with its spinner, and a
        // failed attempt keeps it retryable.
        if actionBlocksSettlement(key) { return nil }
        if actionStates[key] == .accepted {
            let label = chosenChoiceLabel(row: row, card: card)
            return BotCardSettlement(
                glyph: "checkmark.circle",
                title: label.map { "已选择：\($0)" } ?? "已送出",
                detail: detail)
        }
        return nil
    }

    private func choiceDetail(_ card: BotUICardContent) -> String? {
        let prompt = card.body.string("question", "prompt")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let prompt, !prompt.isEmpty { return prompt }
        return card.kind == .steps ? "建议下一步" : nil
    }

    private func chosenChoiceLabel(row: BotUIRow, card: BotUICardContent) -> String? {
        guard let optionID = row.body["answeredOptionID"]?.string ?? answeredOptionIDs[row.id] else {
            return nil
        }
        let key = card.kind == .steps ? "steps" : "options"
        return BotUIChoice.parseList(card.body[key]).first(where: { $0.id == optionID })?.label
    }

    private func checklistSettlement(row: BotUIRow, card: BotUICardContent) -> BotCardSettlement? {
        guard card.body["interactive"]?.bool != false else { return nil }
        let state = checklistProgress[row.id]
        if state?.sending == true { return nil }

        let items = BotUIChecklistItem.parseList(card.body["items"])
        let done = state?.done ?? items.filter(\.done).count
        let total = state?.total ?? items.count
        let title = card.body["title"]?.string ?? ""
        let detail = "\(title) · 已完成 \(done)/\(total)"
        if state?.sent == true {
            return BotCardSettlement(glyph: "checkmark.circle", title: "已发送勾选结果", detail: detail)
        }
        if mutedCardIDs.contains(row.id) {
            return BotCardSettlement(glyph: "minus.circle", title: "已略过", detail: detail)
        }
        return nil
    }

    private func approvalSettlement(row: BotUIRow, card: BotUICardContent) -> BotCardSettlement? {
        let key = "approval:\(row.id)"
        if actionBlocksSettlement(key) { return nil }

        let ask = card.body["ask"]?.object ?? [:]
        let status = card.body["status"]?.string ?? ask["status"]?.string ?? "pending"
        let action = card.body.string("action", "title", "text") ?? ask["action"]?.string ?? "操作"
        let command = card.body.string("command", "target") ?? ask["target"]?.string ?? ""
        let detail = command.isEmpty ? action : command
        let autoDeclined = autoDeclinedApprovalIDs.contains(row.id)

        if status == "pending" {
            guard autoDeclined else { return nil }
            return BotCardSettlement(glyph: "xmark.circle", title: "已略过，视为拒绝",
                                     detail: detail, monospacedDetail: !command.isEmpty)
        }
        if autoDeclined {
            return BotCardSettlement(glyph: "xmark.circle", title: "已略过，视为拒绝",
                                     detail: detail, monospacedDetail: !command.isEmpty)
        }
        // The durable projection may carry `allowed-session` for a session
        // grant; the shared receipt mapping is the single source of truth for
        // matching the label to the button the user actually pressed (P26
        // §2.7), so a session grant never renders as a one-off or「已处理」.
        let allowed = status == "allowed" || status == "allowed-session" || status == "always"
        let scope = card.body["alwaysScope"]?.string ?? ask["alwaysScope"]?.string ?? "until"
        let label = BotApprovalReceipt.label(for: status, scope: scope)
        return BotCardSettlement(glyph: allowed ? "checkmark.circle.fill" : "xmark.circle",
                                 title: label, detail: detail,
                                 tone: allowed ? .success : .neutral,
                                 monospacedDetail: !command.isEmpty)
    }

    func isActionPending(_ key: String) -> Bool { actionStates[key] == .pending }

    /// A card stays full while its action is in flight (existing loading) and
    /// after a failure (the user can retry).
    private func actionBlocksSettlement(_ key: String) -> Bool {
        switch actionStates[key] {
        case .pending, .failed: return true
        default: return false
        }
    }

    func send(text: String, files: [URL] = []) {
        send(text: text, files: files, checklist: nil)
    }

    /// The checklist view reports its local toggles so a skipped card can
    /// still show how many items were checked at that moment.
    func noteChecklistProgress(rowID: String, done: Int, total: Int) {
        guard checklistProgress[rowID]?.sent != true,
              checklistProgress[rowID]?.sending != true else { return }
        checklistProgress[rowID] = BotChecklistProgress(done: done, total: total)
    }

    /// Sends the checklist result as a normal chat message. The card keeps its
    /// full form while the action is in flight, then settles only when the
    /// action is accepted; a failure re-enables the button for a retry.
    func sendChecklist(row: BotUIRow, done: Int, total: Int, message: String) {
        guard checklistProgress[row.id]?.sent != true,
              checklistProgress[row.id]?.sending != true,
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        checklistProgress[row.id] = BotChecklistProgress(done: done, total: total, sending: true)
        send(text: message, files: [],
             checklist: BotChecklistSend(rowID: row.id, done: done, total: total))
    }

    private func send(text: String, files: [URL], checklist: BotChecklistSend?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !files.isEmpty else { return }
        noteInteraction()
        runtimeNotice = nil
        let nonce = UUID().uuidString
        let localID = "local-\(nonce)"
        let messageID = "att-\(Int(Date().timeIntervalSince1970 * 1_000))-\(nonce.prefix(8).lowercased())"
        let drafted = files.compactMap { BotUIAttachment.local(url: $0) }
        var values: [String: BotJSONValue] = ["text": .string(trimmed)]
        if !drafted.isEmpty {
            values["attachments"] = .array(drafted.map(\.jsonValue))
        }
        var local = BotUIRow.fixture(id: localID, botID: context.botID,
                                     seq: (rows.map(\.seq).max() ?? 0) + 1,
                                     kind: "sendMessage", role: "user",
                                     body: BotUIBody(type: "text", values: values),
                                     eventID: "local:\(nonce)")
        local.provenance.trust = "owner_direct"
        rows.append(local)

        // A send is also the user's answer to every approval still awaiting a
        // decision: mark them pending synchronously so the header and
        // pendingApprovalCount leave「等你确认」at once, then deny them in order
        // before the chat action below. No new protocol action is involved;
        // this is the existing approval deny path.
        let autoDeclines = approvalsAwaitingDecision.filter { row in
            approvalAction(row: row, decision: .deny) != nil
        }
        for row in autoDeclines { actionStates["approval:\(row.id)"] = .pending }

        // The line starts on the local echo and only spans a new turn; steering
        // into an already running turn keeps the existing line. A stopped or
        // finalized turn keeps its live text, so `live != nil` alone does not
        // mean this send is steering.
        if runningTurnID == nil { markAwaitingTurn() }
        if files.isEmpty, driver == nil, fixtureActions, runningTurnID == nil {
            beginTurn(turnID: "fixture-turn")
        }
        Task {
            // One Task on the MainActor awaits each deny to completion before
            // the chat action starts, so the driver observes deny → chat.
            for row in autoDeclines { await autoDeclineApproval(row) }
            await importAndSend(text: trimmed, files: files, messageID: messageID,
                                nonce: nonce, localID: localID, checklist: checklist)
        }
    }

    /// Imports the picked files into this Bot's DSH workspace, then sends one
    /// `chat` action with the readable paths. A failed file is skipped with a
    /// notice; it never blocks the other files or the text.
    private func importAndSend(text: String, files: [URL], messageID: String,
                               nonce: String, localID: String,
                               checklist: BotChecklistSend?) async {
        var imported: [BotAttachment] = []
        var notices: [String] = []
        if !files.isEmpty {
            if let attachmentImporter {
                let result = await attachmentImporter.importFiles(
                    botID: context.botID, messageID: messageID, files: files)
                imported = result.items
                notices = result.errors.map { "附件「\($0.name)」未附加：\($0.reason)" }
            } else {
                notices = files.map {
                    "附件「\($0.lastPathComponent)」未附加：附件导入未连接"
                }
            }
        }
        if !notices.isEmpty { runtimeNotice = notices.joined(separator: "\n") }
        if !imported.isEmpty, let index = rows.firstIndex(where: { $0.id == localID }) {
            rows[index].body.values["attachments"] = .array(imported.map { BotUIAttachment($0).jsonValue })
        } else if let index = rows.firstIndex(where: { $0.id == localID }) {
            rows[index].body.values.removeValue(forKey: "attachments")
        }
        guard !text.isEmpty || !imported.isEmpty else {
            rows.removeAll { $0.id == localID }
            clearAwaitingTurn()
            if let checklist { invalidateChecklistSend(checklist) }
            return
        }
        if driver == nil && fixtureActions && runningTurnID == nil {
            beginTurn(turnID: "fixture-turn")
        }
        let action = BotUIUserAction.chat(nonce: nonce, botID: context.botID, text: text,
                                          attachments: imported.isEmpty ? nil : imported)
        let key = "chat:\(localID)"
        await perform(action, key: key, localRowID: localID)
        if let checklist {
            if actionStates[key] == .accepted {
                checklistProgress[checklist.rowID] = BotChecklistProgress(
                    done: checklist.done, total: checklist.total, sent: true)
            } else {
                invalidateChecklistSend(checklist)
            }
        }
    }

    private func invalidateChecklistSend(_ checklist: BotChecklistSend) {
        guard checklistProgress[checklist.rowID]?.sent != true else { return }
        checklistProgress[checklist.rowID] = BotChecklistProgress(
            done: checklist.done, total: checklist.total)
    }

    private static func retryState(_ state: BotUIActionState?) -> BotUIActionRetry.KeyState? {
        switch state {
        case .pending: return .pending
        case .accepted: return .accepted
        case .failed: return .failed
        case nil: return nil
        }
    }

    /// Taps one option. The tap is local, immediate and reversible: the choice
    /// appears in the transcript at once (a `local-<nonce>` echo, the same
    /// convention the composer uses), the card shows `正在送出…`, and a refused
    /// or failed action rolls the echo back with human copy on the card.
    func answer(row: BotUIRow, optionID: String) {
        let key = "card:\(row.id)"
        guard BotUIActionRetry.accepts(intent: .answer, cardKind: .question,
                                       state: Self.retryState(actionStates[key])),
              !optionID.isEmpty else { return }
        // The projection already knows the card was replaced by a newer one
        // (`status == superseded`). The planner would refuse the tap, so say so
        // on the card instead of starting an action that must fail.
        if cardStatus(row) == "superseded" {
            actionStates[key] = .failed("card_expired")
            return
        }
        let choice = BotUICardContent.parse(row: row).flatMap { card -> BotUIChoice? in
            let listKey = card.kind == .steps ? "steps" : "options"
            return BotUIChoice.parseList(card.body[listKey]).first { $0.id == optionID }
        }
        let nonce = UUID().uuidString
        let echo = BotChoiceCardUI.echo(nonce: nonce, value: choice?.value ?? "",
                                        label: choice?.label ?? "")
        if let echo { appendChoiceEcho(echo, botID: row.botID) }
        answeredOptionIDs[row.id] = optionID
        actionStates[key] = .pending
        let action = BotUIUserAction.cardAnswer(nonce: nonce, botID: row.botID,
                                                cardID: row.id, optionID: optionID)
        Task { await perform(action, key: key, localRowID: echo?.rowID) }
    }

    private func cardStatus(_ row: BotUIRow) -> String? {
        row.body["status"]?.string
    }

    /// The composer's `local-<nonce>` user row, for a tapped option. The durable
    /// user row of the same choice carries `chatActionNonce == <nonce>` (the
    /// projection reads it from the frozen `card-answer:<nonce>` request id), so
    /// `upsert` retires the echo with the same rule it uses for a typed message.
    private func appendChoiceEcho(_ echo: BotChoiceEcho, botID: String) {
        var local = BotUIRow.fixture(id: echo.rowID, botID: botID,
                                     seq: (rows.map(\.seq).max() ?? 0) + 1,
                                     kind: "sendMessage", role: "user",
                                     body: BotUIBody(type: "text", values: ["text": .string(echo.text)]),
                                     eventID: echo.eventID)
        local.provenance.trust = "owner_direct"
        rows.append(local)
    }

    func dismiss(row: BotUIRow) {
        guard BotUICardContent.parse(row: row)?.kind == .question else { return }
        let key = "dismiss:\(row.id)"
        guard BotUIActionRetry.accepts(intent: .dismiss, cardKind: .question,
                                       state: Self.retryState(actionStates[key])) else { return }
        actionStates[key] = .pending
        let action = BotUIUserAction.cardDismiss(nonce: UUID().uuidString, botID: row.botID, cardID: row.id)
        Task { await perform(action, key: key, localRowID: nil) }
    }

    func decide(row: BotUIRow, decision: BotUIApprovalDecision) {
        guard let action = beginApproval(row: row, decision: decision) else { return }
        Task { await perform(action, key: "approval:\(row.id)", localRowID: nil) }
    }

    private func beginApproval(row: BotUIRow, decision: BotUIApprovalDecision) -> BotUIUserAction? {
        let key = "approval:\(row.id)"
        guard BotUIActionRetry.accepts(intent: .approval, cardKind: .question,
                                       state: Self.retryState(actionStates[key])) else {
            return nil
        }
        guard let action = approvalAction(row: row, decision: decision) else { return nil }
        actionStates[key] = .pending
        return action
    }

    private func approvalAction(row: BotUIRow, decision: BotUIApprovalDecision) -> BotUIUserAction? {
        guard let approvalID = row.body.string("approvalID", "requestId", "id")
                ?? row.body["ask"]?.object?["requestId"]?.string,
              let digest = row.body["digest"]?.string else { return nil }
        return BotUIUserAction.approval(nonce: UUID().uuidString, botID: row.botID,
                                        approvalID: approvalID, decision: decision, digest: digest)
    }

    /// Runs the existing deny action for an approval the user implicitly
    /// rejected by sending the next message. The caller marked it `.pending`
    /// synchronously; the marker for the settled text is only recorded after
    /// the driver accepted the action.
    private func autoDeclineApproval(_ row: BotUIRow) async {
        let key = "approval:\(row.id)"
        guard actionStates[key] == .pending,
              let action = approvalAction(row: row, decision: .deny) else { return }
        await perform(action, key: key, localRowID: nil)
        if actionStates[key] == .accepted {
            autoDeclinedApprovalIDs.insert(row.id)
        }
    }

    func stop() {
        clearAwaitingTurn()
        lineSuppressed = true
        guard let turnID = runningTurnID else { return }
        cancelledTurnIDs.insert(turnID)
        runningTurnID = nil
        streamingText = nil
        stream.cancel()
        actionLog.append("stop:\(turnID)")
        scheduleIdleSleep(reset: true)
        Task { await driver?.stopCurrentTurn(turnID) }
    }

    func beginTurn(turnID: String) {
        clearAwaitingTurn()
        lineSuppressed = false
        cancelledTurnIDs.remove(turnID)
        runningTurnID = turnID
        streamingText = nil
        sleepTask?.cancel()
        sleepTask = nil
        idleSleeping = false
    }

    /// Start the "sent, waiting for the host to open the turn" window. If no
    /// turn starts within 120s the fallback clears it so the line cannot hang.
    private func markAwaitingTurn() {
        lineSuppressed = false
        awaitingTurn = true
        awaitingTurnTimeout?.cancel()
        awaitingTurnTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard !Task.isCancelled, let self, self.awaitingTurn else { return }
            self.awaitingTurnTimeout = nil
            self.awaitingTurn = false
        }
    }

    /// The turn started, the send failed, was dropped, or the user stopped it.
    private func clearAwaitingTurn() {
        awaitingTurnTimeout?.cancel()
        awaitingTurnTimeout = nil
        if awaitingTurn { awaitingTurn = false }
    }

    /// Any touch, keystroke or send wakes an idle fish and restarts the
    /// 60-second sleep clock.
    func noteInteraction() {
        if idleSleeping { idleSleeping = false }
        onInteraction?()
        guard runningTurnID == nil, live == nil else {
            sleepTask?.cancel()
            sleepTask = nil
            return
        }
        scheduleIdleSleep(reset: true)
    }

    /// Pull the durable presentation once (page open, and each watch poll).
    func refreshPresentation() async {
        guard let driver else { return }
        if let presentation = try? await driver.presentation() {
            applyDurablePresentation(presentation)
        }
    }

    private func applyDurablePresentation(_ presentation: BotRuntimePresentation) {
        // `@Published` publishes on every assignment, even an equal value. The
        // 800ms watch re-reads the same durable projection while the user
        // reads a card; assigning it unconditionally re-rendered the whole
        // dense transcript every poll.
        if presentation != runtimePresentation { runtimePresentation = presentation }
        if let liveTurn = live {
            // The durable projection is authoritative for whether a turn is
            // still open. A `turn/end` live frame can be lost when the scene
            // pauses or the Worker is replaced; without this check the live
            // turn (and its failed tool rows) stayed mounted forever, keeping
            // the lazy transcript in a placement loop after the incident.
            if presentation.runningTurnID == nil {
                let committed = liveTurn.turn.map { number in
                    rows.contains { Self.isAnswer($0) && Self.turn(of: $0) == number }
                } ?? false
                if liveTurn.ended || committed {
                    settleDurableLive(presentation)
                    return
                }
            }
            return
        }
        if reaction != presentation.reaction { reaction = presentation.reaction }
        if let turn = presentation.runningTurnID {
            if runningTurnID == nil, !cancelledTurnIDs.contains(turn) {
                runningTurnID = turn
            }
            clearAwaitingTurn()
        } else if let turn = runningTurnID, !cancelledTurnIDs.contains(turn) {
            runningTurnID = nil
            streamingText = nil
            // A final frame can be lost across a background pause. The durable
            // projection is authoritative once no turn is running, so stop a
            // coalescer that is still waiting for its next pending delta.
            stream.cancel()
        }
        scheduleIdleSleep()
    }

    /// Drop a live turn the durable projection has already closed. The next
    /// watch poll renders the durable answer row and its folded process row
    /// instead of the live tool group that was being re-measured forever.
    private func settleDurableLive(_ presentation: BotRuntimePresentation) {
        live = nil
        livePresentation = nil
        reaction = presentation.reaction
        liveFish = BotLiveFishProjection(botID: context.botID)
        fishExpiryTask?.cancel()
        fishExpiryTask = nil
        stream.cancel()
        deltaFlush?.cancel()
        deltaFlush = nil
        pendingDelta = ""
        streamingText = nil
        runningTurnID = nil
        scheduleIdleSleep(reset: true)
    }

    private func scheduleIdleSleep(reset: Bool = false) {
        if reset {
            sleepTask?.cancel()
            sleepTask = nil
        } else if sleepTask != nil {
            return
        }
        guard runningTurnID == nil, live == nil, pendingApprovalCount == 0 else {
            sleepTask?.cancel()
            sleepTask = nil
            return
        }
        sleepTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.sleepTask = nil
            guard self.runningTurnID == nil, self.live == nil, self.pendingApprovalCount == 0 else { return }
            self.idleSleeping = true
        }
    }

    func receiveStream(turnID: String, text: String, final: Bool = false) {
        guard runningTurnID == turnID, !cancelledTurnIDs.contains(turnID) else { return }
        if final {
            stream.cancel()
            streamingText = nil
            runningTurnID = nil
            lineSuppressed = true
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
        // A host error notice that arrives while the page is open is reported
        // once on the header line; history (a reset batch) never replays one.
        if !batch.reset {
            let known = Set(rows.map(\.id))
            if let fresh = incoming.last(where: {
                !known.contains($0.id) && Self.isNotice($0)
                    && BotUIRendering.isRenderable($0)
                    && ($0.body["tone"]?.string ?? "error") == "error"
            }) {
                runtimeNotice = fresh.body["text"]?.string
            }
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
            if rows[index] == row { return }
            var next = row
            if rows[index].id != row.id {
                // An in-place card update (same `cardKey`) may still carry a
                // fresh producer id — the durable projection used to mint a
                // new `card.presented` row id for every progress update. The
                // transcript's identity is the first row id: replacing it
                // makes `ForEach` tear down and rebuild the lazy item on every
                // update, which feeds the placement loop. Keep the original
                // identity and ordering; merge the provenance instead.
                next.id = rows[index].id
                next.seq = rows[index].seq
                next.createdAt = rows[index].createdAt
                var eventIDs = rows[index].provenance.eventIDs
                for eventID in row.provenance.eventIDs where !eventIDs.contains(eventID) {
                    eventIDs.append(eventID)
                }
                next.provenance.eventIDs = eventIDs
            }
            if next == rows[index] { return }
            rows[index] = next
        } else {
            rows.append(row)
        }
        rows.sort { $0.seq < $1.seq }
    }

    /// Polls the production row projection until the view's `.task` is
    /// cancelled. Fixture models have no driver and simply do not run it.
    ///
    /// The first iteration runs immediately, so becoming visible again reads
    /// the durable rows and presentation once before the normal 0.8s cadence.
    func watchLoop() async {
        guard let driver else { return }
        watchGeneration &+= 1
        let generation = watchGeneration
        while !Task.isCancelled, pageActive, generation == watchGeneration {
            do {
                let batch = try await driver.watch(watchCursor)
                apply(batch)
                let processes = await driver.turnProcesses()
                if processes != turnProcesses { turnProcesses = processes }
                settleLive()
                if let presentation = try? await driver.presentation() {
                    applyDurablePresentation(presentation)
                }
            } catch {
                runtimeNotice = "Bot 实时更新失败：\(error.localizedDescription)"
                liveFish.noteError("Bot 实时更新失败：\(error.localizedDescription)")
                refreshLiveFishPresentation()
            }
            guard !Task.isCancelled, pageActive, generation == watchGeneration else { return }
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
    }

    /// Follows the running turn's live frames until the view's `.task` ends.
    /// Hiding the page cancels the stream; becoming visible starts a fresh
    /// subscription after the durable catch-up.
    func liveLoop() async {
        guard let driver else { return }
        for await frame in await driver.liveFrames() {
            guard pageActive, !Task.isCancelled else { return }
            receive(frame)
        }
    }

    /// Called by `BotProductionPage` when the Bot tab/scene pause changes.
    /// Hiding cancels every UI-only timer and drops the transient live turn so
    /// the first visible read replaces it with the durable projection.
    func setPageActive(_ active: Bool) {
        guard pageActive != active else { return }
        pageActive = active
        guard !active else { return }
        stream.cancel()
        deltaFlush?.cancel()
        deltaFlush = nil
        fishExpiryTask?.cancel()
        fishExpiryTask = nil
        sleepTask?.cancel()
        sleepTask = nil
        pendingDelta = ""
        streamingText = nil
        live = nil
        livePresentation = nil
        reaction = nil
        liveFish = BotLiveFishProjection(botID: context.botID)
    }

    func receive(_ frame: BotLiveFrame) {
        liveFish.receive(frame)
        switch frame {
        case .streamStart:
            pendingDelta = ""
            if live == nil { lineSuppressed = false }
            var turn = live ?? BotLiveTurn()
            turn.buffer = ""
            if turn != live { live = turn }
        case .textDelta(let text):
            if live == nil {
                lineSuppressed = false
                live = BotLiveTurn()
            }
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
                lineSuppressed = false
                live = BotLiveTurn()
                sleepTask?.cancel()
                sleepTask = nil
                idleSleeping = false
            } else {
                flushDelta()
                if live == nil { lineSuppressed = false }
            }
            var turn = live ?? BotLiveTurn()
            turn.apply(event: event)
            if turn != live { live = turn }
            if type == "turn/start" {
                runningTurnID = liveFish.presentation().runningTurnID
                streamingText = nil
            } else if type == "turn/end" {
                runningTurnID = nil
                scheduleIdleSleep(reset: true)
            }
        }
        // Any live frame means the host has picked up the turn.
        if runningTurnID != nil || live != nil { clearAwaitingTurn() }
        refreshLiveFishPresentation()
    }

    private func refreshLiveFishPresentation() {
        let presentation = liveFish.presentation()
        if livePresentation != presentation { livePresentation = presentation }
        if reaction != presentation.reaction { reaction = presentation.reaction }
        scheduleFishExpiry(presentation)
    }

    /// The renderer owns the reaction TTL, but the lifecycle fallback is a
    /// model value: wake once the one-shot ends so an error turn returns to
    /// idle even when no further frame arrives.
    private func scheduleFishExpiry(_ presentation: BotRuntimePresentation) {
        fishExpiryTask?.cancel()
        fishExpiryTask = nil
        let now = BotLiveFishProjection.now
        var deadlines: [Int64] = []
        if let shot = presentation.oneShot, shot.endsAt > now { deadlines.append(shot.endsAt) }
        if let reaction = presentation.reaction, reaction.endsAt > now { deadlines.append(reaction.endsAt) }
        guard let next = deadlines.min() else { return }
        fishExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, next - now)) * 1_000_000)
            guard !Task.isCancelled, let self else { return }
            self.refreshLiveFishPresentation()
        }
    }

    private func flushDelta() {
        deltaFlush?.cancel()
        deltaFlush = nil
        guard !pendingDelta.isEmpty, var turn = live, !turn.ended, !turn.suppressesText else {
            pendingDelta = ""
            return
        }
        turn.buffer += pendingDelta
        pendingDelta = ""
        if turn != live { live = turn }
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
            scheduleIdleSleep(reset: true)
        } else if turn != live {
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
        guard let link = BotDeepLink(url: url), link.botID == context.botID else {
            deepLinkError = "这条消息不可用或已过期。"
            return false
        }
        // Routine links target the routine list in the information page, not
        // a chat row. Let the production hub own that destination.
        guard let rowID = link.rowID else { return false }
        guard visibleRows.contains(where: { $0.id == rowID }) else {
            deepLinkError = "这条消息不可用或已过期。"
            return false
        }
        deepLinkError = nil
        scrollRequestID = rowID
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
            if driver == nil, let localRowID, case .cardAnswer = action {
                // A fixture/preview model has no durable projection to retire the
                // optimistic choice echo; the accepted action is its own record,
                // so drop the echo instead of duplicating it.
                rows.removeAll { $0.id == localRowID }
            }
            if case .cardDismiss = action { dismissedCardIDs.insert(action.cardID) }
            if case .approval(_, _, _, let decision, _) = action, let rowID = approvalRowID(action: action) {
                updateApproval(rowID: rowID, decision: decision)
            }
        } else {
            let reason = result.reason ?? "动作未完成"
            actionStates[key] = .failed(reason)
            // The optimistic row only stands for a choice that reached the
            // model; a failure rolls it back.
            if let localRowID, BotChoiceCardUI.echoDisposition(for: .failed(reason)) == .remove {
                rows.removeAll { $0.id == localRowID }
            }
            clearAwaitingTurn()
            // A refused card action is a normal stale-card outcome: the card
            // itself names it, so it must not become an error near the avatar.
            if BotChoiceCardUI.refusalText(reason) == nil { runtimeNotice = reason }
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
