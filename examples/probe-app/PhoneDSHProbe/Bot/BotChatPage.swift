// SPDX-License-Identifier: MIT

import SwiftUI
import UIKit

struct BotChatPage: View {
    @ObservedObject var model: BotChatModel
    var cardActions: BotCardActions
    var onOpenInfo: () -> Void
    var onOpenInfoSection: (BotInfoSection) -> Void
    var hasOnlineDevices: Bool
    var onConnectDevice: () -> Void
    var externalDocumentAction: ((BotUIRow) -> Void)?

    @State private var draft = ""
    @State private var sourceRow: BotUIRow?
    @State private var documentRow: BotUIRow?
    @State private var preservingHistoryPosition = false
    /// Finished turns whose process row the user opened.
    @State private var openTurns: Set<Int> = []
    @FocusState private var composerFocused: Bool

    init(model: BotChatModel, cardActions: BotCardActions = BotCardActions(),
         onOpenInfo: @escaping () -> Void = {},
         onOpenInfoSection: @escaping (BotInfoSection) -> Void = { _ in },
         hasOnlineDevices: Bool = false,
         onConnectDevice: @escaping () -> Void = {},
         openDocument: ((BotUIRow) -> Void)? = nil) {
        self.model = model
        self.cardActions = cardActions
        self.onOpenInfo = onOpenInfo
        self.onOpenInfoSection = onOpenInfoSection
        self.hasOnlineDevices = hasOnlineDevices
        self.onConnectDevice = onConnectDevice
        self.externalDocumentAction = openDocument
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            transcript
            composerDock
        }
        .background(HomeSpec.page.ignoresSafeArea())
        .sheet(item: $sourceRow) { row in
            BotSourceSheet(row: row)
        }
        .sheet(item: $documentRow) { row in
            BotDocumentPreview(row: row)
        }
        .alert("无法定位消息", isPresented: Binding(
            get: { model.deepLinkError != nil },
            set: { if !$0 { model.deepLinkError = nil } }
        )) {
            Button("好", role: .cancel) { model.deepLinkError = nil }
        } message: {
            Text(model.deepLinkError ?? "")
        }
        .onOpenURL { _ = model.openDeepLink($0) }
        .onAppear { model.noteInteraction() }
        .onChange(of: draft) { _, _ in model.noteInteraction() }
    }

    /// Grok-style Bot header: one centered avatar+name capsule, and the DSH
    /// page's own 92×44 device/menu capsule on the trailing side. The leading
    /// spacer mirrors the trailing capsule so the Bot capsule is centered on
    /// the screen and can never grow under the menu.
    private var header: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: HomeSpec.navPillWidth, height: 1)
                .accessibilityHidden(true)
            Button {
                model.noteInteraction()
                onOpenInfo()
            } label: {
                HStack(spacing: 8) {
                    BotFishView(state: model.fishState, size: 32)
                    Text(model.context.botName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(HomeSpec.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.leading, 6)
                .padding(.trailing, 14)
                .frame(height: HomeSpec.navButton)
                .background(HomeSpec.surface, in: Capsule())
                .overlay(alignment: .topTrailing) {
                    if model.needsAttentionCount > 0 {
                        Circle()
                            .fill(NativeParityTokens.error)
                            .frame(width: 6, height: 6)
                            .padding(.top, 4)
                            .padding(.trailing, 6)
                    }
                }
                .homeFloatingShadow()
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Bot 信息")
            .accessibilityIdentifier("bot.info.open")
            .frame(maxWidth: .infinity)

            HeaderActionPill(hasOnlineDevices: hasOnlineDevices,
                             connectIdentifier: "bot.connect-device",
                             menuIdentifier: "bot.header.menu",
                             showsMenuActivityDot: model.runningTurnID != nil,
                             onConnect: {
                                 model.noteInteraction()
                                 onConnectDevice()
                             }) {
                headerMenuItems
            }
        }
        .padding(.horizontal, HomeSpec.chromeInset)
        .padding(.top, HomeSpec.navTop)
        .frame(height: HomeSpec.navTop + HomeSpec.navButton)
        .background(HomeSpec.page)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var headerMenuItems: some View {
        Text("跟进中 \(model.followingCount) · 需要你处理 \(model.needsAttentionCount)")
        Divider()
        Button("Bot 信息与设置", systemImage: "person.crop.circle") {
            openInfo(nil)
        }
        Button("记忆", systemImage: "brain") {
            openInfo(.memory)
        }
        Button("例行任务", systemImage: "repeat") {
            openInfo(.routines)
        }
        Button("审批记录", systemImage: "checkmark.shield") {
            openInfo(.approvals)
        }
    }

    private func openInfo(_ section: BotInfoSection?) {
        model.noteInteraction()
        if let section {
            onOpenInfoSection(section)
        } else {
            onOpenInfo()
        }
    }

    private var transcript: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if model.hasMoreHistory {
                            HStack {
                                if model.loadingHistory { ProgressView() }
                                Text(model.loadingHistory ? "正在加载历史" : "向上加载历史")
                                    .botCaptionFont()
                                    .foregroundStyle(HomeSpec.textTertiary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .onAppear { loadHistory(proxy: proxy) }
                            .accessibilityIdentifier("bot.history.loader")
                        }
                        if isEmpty {
                            emptyState
                                .frame(minHeight: max(0, geometry.size.height - HomeSpec.blockGap - 16),
                                       alignment: .center)
                                .accessibilityIdentifier("bot.chat.empty")
                        }
                        let anchors = processAnchors
                        ForEach(model.displayRows) { row in
                            if let turn = anchors[row.id], let process = model.turnProcesses[turn] {
                                BotTurnProcessBlock(process: process, isOpen: openTurns.contains(turn)) {
                                    withAnimation(.easeOut(duration: 0.16)) {
                                        if openTurns.contains(turn) { openTurns.remove(turn) } else { openTurns.insert(turn) }
                                    }
                                }
                                .id("process-\(turn)")
                            }
                            BotTranscriptRow(row: row, model: model, actions: resolvedCardActions,
                                             sourceRow: $sourceRow)
                                .id(row.id)
                        }
                        if let live = model.live {
                            BotLiveTurnView(live: live)
                            Color.clear.frame(height: 1).id("bot-live-tail")
                        }
                        if let streaming = model.streamingText {
                            BotStreamingRow(text: streaming)
                                .id("bot-live-stream")
                        }
                    }
                    .padding(.top, HomeSpec.blockGap)
                    .padding(.bottom, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.visibleRows.map(\.id)) { _, _ in
                    guard !preservingHistoryPosition, model.scrollRequestID == nil else { return }
                    if let last = model.visibleRows.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: liveScrollKey) { _, key in
                    if key != nil { proxy.scrollTo("bot-live-tail", anchor: .bottom) }
                }
                .onChange(of: model.streamingText) { _, value in
                    if value != nil { proxy.scrollTo("bot-live-stream", anchor: .bottom) }
                }
                .onChange(of: model.scrollRequestID) { _, rowID in
                    guard let rowID else { return }
                    withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(rowID, anchor: .center) }
                    model.scrollRequestID = nil
                }
            }
        }
        // Same as DSH: a tap anywhere in the transcript, blank space
        // included, hands the keyboard back and wakes an idle fish.
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            model.noteInteraction()
            composerFocused = false
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                            to: nil, from: nil, for: nil)
        })
        .accessibilityIdentifier("bot.chat.transcript")
    }

    private var isEmpty: Bool {
        model.displayRows.isEmpty && model.streamingText == nil && model.live == nil
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            BotFishView(state: model.fishState, size: 96, allowsPoke: true)
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
            Text("嗨，我是 \(model.context.botName)")
                .botFont(size: 15, lineHeight: 22, weight: .semibold, style: .body)
                .foregroundStyle(HomeSpec.textPrimary)
            Text("我可以处理任务、整理文件和查找资料。\n想让我帮你做什么？")
                .botFont(size: 13, lineHeight: 18, style: .body)
                .foregroundStyle(HomeSpec.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, HomeSpec.contentInset)
        .padding(.vertical, 24)
    }

    private var resolvedCardActions: BotCardActions {
        var actions = cardActions
        actions.openDocument = externalDocumentAction ?? { row in documentRow = row }
        return actions
    }

    private var composerDock: some View {
        VStack(spacing: 8) {
            if model.showsActivityLine, let activity = model.activity {
                BotActivityLine(activity: activity, fishState: model.fishState)
            }
            if model.pendingApprovalCount > 0 {
                Button {
                    model.scrollRequestID = model.visibleRows.first(where: {
                        $0.body.type == "approval" && ($0.body["status"]?.string ?? "pending") == "pending"
                    })?.id
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.shield")
                            .foregroundStyle(NativeParityTokens.warning)
                        Text("有 \(model.pendingApprovalCount) 项操作待审批")
                            .botSecondaryFont(weight: .medium)
                            .foregroundStyle(HomeSpec.textPrimary)
                        Spacer()
                        Text("查看")
                            .botSecondaryFont(weight: .medium)
                            .foregroundStyle(HomeSpec.textSecondary)
                    }
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .homeListCard()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("bot.approval.banner")
            }
            if let notice = model.runtimeNotice {
                // DSH composer notice: one 13pt line above the card, dismissible.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 13))
                    Text(notice)
                        .font(.system(size: 13))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.runtimeNotice = nil } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭提示")
                }
                .foregroundStyle(BotUIPalette.danger)
                .padding(.horizontal, 4)
            }
            // Grok-style capsule composer: one white r26 capsule, the growing
            // text field on the leading side, and exactly one 36pt round
            // send/stop button on the trailing side. No microphone, no voice
            // mode, no attachment button.
            HStack(alignment: .bottom, spacing: 8) {
                TextField("向 \(model.context.botName) 提问", text: $draft, axis: .vertical)
                    .font(.system(size: HomeSpec.bodySize))
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("bot.composer.input")
                    .onSubmit { send() }
                if model.runningTurnID != nil {
                    Button { model.stop() } label: {
                        BotComposerGlyph(systemImage: "stop.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("停止当前回合")
                    .accessibilityIdentifier("bot.composer.stop")
                } else {
                    Button(action: send) {
                        BotComposerGlyph(systemImage: "arrow.up", enabled: canSend)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .accessibilityLabel("发送消息")
                    .accessibilityIdentifier("bot.composer.send")
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(HomeSpec.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(HomeSpec.borderList, lineWidth: 0.5))
            .homeComposerShadow()
            .contentShape(Capsule())
            .onTapGesture {
                model.noteInteraction()
                composerFocused = true
            }
            if model.runningTurnID != nil {
                Text("发送会并入当前回合，不会排队；停止只取消当前回合。")
                    .botCaptionFont()
                    .foregroundStyle(HomeSpec.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, HomeSpec.chromeInset)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(HomeSpec.page)
        .accessibilityElement(children: .contain)
    }

    /// The first answer row of each turn that has tool steps carries that
    /// turn's process row above it, as on the DSH page.
    private var processAnchors: [String: Int] {
        var anchors: [String: Int] = [:]
        var seen: Set<Int> = []
        for row in model.displayRows where BotChatModel.isAnswer(row) {
            guard let turn = BotChatModel.turn(of: row), model.turnProcesses[turn] != nil,
                  seen.insert(turn).inserted else { continue }
            anchors[row.id] = turn
        }
        return anchors
    }

    private var liveScrollKey: String? {
        model.live.map { live in
            "\(live.segments.count):\(live.buffer.count):\(live.tools.count):\(live.ended)"
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        model.send(text: text)
        composerFocused = true
    }

    private func loadHistory(proxy: ScrollViewProxy) {
        guard !model.loadingHistory else { return }
        let anchor = model.visibleRows.first?.id
        preservingHistoryPosition = true
        Task {
            await model.loadHistory()
            if let anchor { proxy.scrollTo(anchor, anchor: .top) }
            preservingHistoryPosition = false
        }
    }
}

private struct BotTranscriptRow: View {
    let row: BotUIRow
    @ObservedObject var model: BotChatModel
    let actions: BotCardActions
    @Binding var sourceRow: BotUIRow?

    var body: some View {
        Group {
            if row.body.type == "text" {
                BotTextRow(row: row)
            } else if let card = BotUICardContent.parse(row: row) {
                BotCardView(row: row, card: card, model: model, actions: actions)
                    .padding(.horizontal, HomeSpec.contentInset)
                    .padding(.vertical, HomeSpec.blockGap / 2)
            }
        }
        .contextMenu {
            Button("复制") { UIPasteboard.general.string = BotUIRendering.copyText(row) }
            Button("查看来源") { sourceRow = row }
        }
    }
}

private struct BotTextRow: View {
    let row: BotUIRow
    private var isUser: Bool { row.role == "user" }

    /// DSH message rows: the user's words in the gray bubble (80% width,
    /// top-trailing corner square), the Bot's answer as the DSH markdown body;
    /// rows sit 20pt apart.
    var body: some View {
        Group {
            if isUser {
                BotAdaptiveBubbleLayout(ratio: 0.8, trailing: true) {
                    Text(row.body["text"]?.string ?? "")
                        .font(NativeChatTheme.bodyFont())
                        .lineSpacing(NativeChatTheme.bodyLineSpacing)
                        .foregroundStyle(HomeSpec.textPrimary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(HomeSpec.userBubble, in: HomeSpec.bubbleShape)
                }
            } else {
                BotAnswerBubbleContent(text: row.body["text"]?.string ?? "", streaming: false)
            }
        }
        .padding(.horizontal, HomeSpec.contentInset)
        .padding(.vertical, HomeSpec.blockGap / 2)
    }
}

/// The Bot's own words: the DSH markdown body inside a white bubble on the
/// leading side (top-leading corner square, hairline edge), up to 86% wide.
private struct BotAnswerBubbleContent: View {
    let text: String
    let streaming: Bool

    var body: some View {
        BotAdaptiveBubbleLayout(ratio: 0.86, trailing: false) {
            NativeMarkdownBody(markdown: text, streaming: streaming, workspaceFiles: [], onOpenFile: { _ in })
                .font(NativeChatTheme.bodyFont())
                .lineSpacing(NativeChatTheme.bodyLineSpacing)
                .foregroundStyle(HomeSpec.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(HomeSpec.surface, in: HomeSpec.botBubbleShape)
                .overlay(HomeSpec.botBubbleShape.strokeBorder(HomeSpec.borderList, lineWidth: 0.5))
        }
    }
}

/// A finished turn's process row ("已完成，用时 …"); open, it lists the
/// turn's tool calls as DSH tool rows.
private struct BotTurnProcessBlock: View {
    let process: BotTurnProcess
    let isOpen: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NativeTurnProcessRow(state: process.state, isOpen: isOpen, isFoldable: true, onToggle: onToggle)
            if isOpen {
                ToolRunRow(items: process.items)
            }
        }
        .padding(.horizontal, HomeSpec.contentInset)
        .padding(.vertical, HomeSpec.blockGap / 2)
    }
}

/// The running turn in arrival order: committed text bubbles, tool groups,
/// the text still streaming, then DSH's running clock.
private struct BotLiveTurnView: View {
    let live: BotLiveTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(live.segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let text):
                    BotAnswerBubbleContent(text: text, streaming: false)
                        .padding(.horizontal, HomeSpec.contentInset)
                        .padding(.vertical, HomeSpec.blockGap / 2)
                case .tools(let ids):
                    ToolRunRow(items: live.tools(for: ids))
                        .padding(.horizontal, HomeSpec.contentInset)
                        .padding(.vertical, HomeSpec.blockGap / 2)
                }
            }
            if !live.buffer.isEmpty {
                BotAnswerBubbleContent(text: live.buffer, streaming: true)
                    .padding(.horizontal, HomeSpec.contentInset)
                    .padding(.vertical, HomeSpec.blockGap / 2)
                    .accessibilityIdentifier("bot.streaming.text")
            }
        }
    }
}

private struct BotAdaptiveBubbleLayout: Layout {
    typealias Cache = CGSize

    let ratio: CGFloat
    let trailing: Bool

    func makeCache(subviews: Subviews) -> CGSize { .zero }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout CGSize) -> CGSize {
        guard let child = subviews.first, let width = proposal.width else { return .zero }
        cache = child.sizeThatFits(ProposedViewSize(width: width * ratio, height: proposal.height))
        return CGSize(width: width, height: cache.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout CGSize) {
        guard let child = subviews.first else { return }
        let x = trailing ? bounds.maxX - cache.width : bounds.minX
        child.place(at: CGPoint(x: x, y: bounds.minY),
                    proposal: ProposedViewSize(width: cache.width, height: cache.height))
    }
}

private struct BotStreamingRow: View {
    let text: String

    var body: some View {
        BotAnswerBubbleContent(text: text, streaming: true)
            .padding(.horizontal, HomeSpec.contentInset)
            .padding(.vertical, HomeSpec.blockGap / 2)
            .accessibilityIdentifier("bot.streaming.text")
    }
}

/// The 36pt send / stop circle, as in DSH: black when it can act, the
/// bubble gray with a muted glyph when it cannot.
private struct BotComposerGlyph: View {
    let systemImage: String
    var enabled = true

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(enabled ? HomeSpec.primaryButtonInk : HomeSpec.iconMuted)
            .frame(width: HomeSpec.sendButton, height: HomeSpec.sendButton)
            .background(enabled ? HomeSpec.primaryButton : HomeSpec.userBubble, in: Circle())
            .contentShape(Circle())
    }
}

private struct BotSourceSheet: View {
    let row: BotUIRow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("行") {
                    LabeledContent("rowID", value: row.id)
                    LabeledContent("botID", value: row.botID)
                    LabeledContent("表面", value: BotUIRendering.surface(row))
                    LabeledContent("序号", value: "\(row.seq) / \(row.updatedSeq)")
                }
                Section("来源") {
                    LabeledContent("信任", value: row.provenance.trust)
                    LabeledContent("外部内容", value: row.provenance.tainted ? "是" : "否")
                    ForEach(row.provenance.eventIDs, id: \.self) { eventID in
                        Text(eventID).textSelection(.enabled)
                    }
                }
            }
            .homeGroupedList()
            .navigationTitle("消息来源")
            .toolbar { Button("完成") { dismiss() } }
        }
    }
}

private struct BotDocumentPreview: View {
    let row: BotUIRow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(row.body.string("title", "name", "fileName") ?? "文档")
                        .botTitleFont()
                        .foregroundStyle(HomeSpec.textPrimary)
                    if let content = row.body.string("content", "markdown") {
                        Text(content)
                            .botBodyFont()
                            .foregroundStyle(HomeSpec.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        if let summary = row.body.string("summary", "description") {
                            Text(summary)
                                .botBodyFont()
                                .foregroundStyle(HomeSpec.textSecondary)
                        }
                        BotFailureRow(message: "此卡片没有内嵌正文；由宿主打开原始文档。")
                    }
                    if let path = row.body.string("path", "url") {
                        Text(path)
                            .botCaptionFont()
                            .foregroundStyle(HomeSpec.textTertiary)
                            .textSelection(.enabled)
                    }
                }
                .padding(HomeSpec.contentInset)
            }
            .background(HomeSpec.page)
            .navigationTitle("文档")
            .toolbar { Button("完成") { dismiss() } }
        }
    }
}
