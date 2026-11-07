// SPDX-License-Identifier: MIT

import SwiftUI
import UIKit

struct BotChatPage: View {
    @ObservedObject var model: BotChatModel
    var cardActions: BotCardActions
    var onOpenInfo: () -> Void
    var externalDocumentAction: ((BotUIRow) -> Void)?

    @State private var draft = ""
    @State private var sourceRow: BotUIRow?
    @State private var documentRow: BotUIRow?
    @State private var preservingHistoryPosition = false
    @FocusState private var composerFocused: Bool

    init(model: BotChatModel, cardActions: BotCardActions = BotCardActions(),
         onOpenInfo: @escaping () -> Void = {}, openDocument: ((BotUIRow) -> Void)? = nil) {
        self.model = model
        self.cardActions = cardActions
        self.onOpenInfo = onOpenInfo
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
    }

    private var header: some View {
        HStack(spacing: 12) {
            BotStaticAvatar()
            VStack(alignment: .leading, spacing: 4) {
                Text(model.context.botName)
                    .botFont(size: HomeSpec.navTitleSize, lineHeight: HomeSpec.navTitleLine,
                             weight: .semibold, style: .headline)
                    .foregroundStyle(HomeSpec.textPrimary)
                    .lineLimit(1)
                Text("跟进中 \(model.followingCount) · 需要你处理 \(model.needsAttentionCount)")
                    .botCaptionFont(weight: .medium)
                    .foregroundStyle(HomeSpec.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(NativeParityTokens.selector, in: Capsule())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { onOpenInfo() } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 20))
                    .frame(width: 44, height: 44)
                    .background(HomeSpec.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(HomeSpec.textPrimary)
            .accessibilityLabel("Bot 信息")
            .accessibilityIdentifier("bot.info.open")
        }
        .padding(.horizontal, HomeSpec.chromeInset)
        .padding(.top, HomeSpec.navTop)
        .padding(.bottom, 8)
        .background(HomeSpec.page)
        .accessibilityElement(children: .contain)
    }

    private var transcript: some View {
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
                    if model.visibleRows.isEmpty && model.streamingText == nil {
                        VStack(spacing: 16) {
                            BotStaticAvatar(size: 72)
                            BotEmptyState(title: "嗨，我是 \(model.context.botName)",
                                          message: "我可以处理任务、整理文件和查找资料。想让我帮你做什么？")
                        }
                        .accessibilityIdentifier("bot.chat.empty")
                    }
                    ForEach(model.visibleRows) { row in
                        BotTranscriptRow(row: row, model: model, actions: resolvedCardActions,
                                         sourceRow: $sourceRow)
                            .id(row.id)
                    }
                    if let streaming = model.streamingText {
                        BotStreamingRow(text: streaming)
                            .id("bot-live-stream")
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: model.visibleRows.map(\.id)) { _, _ in
                guard !preservingHistoryPosition, model.scrollRequestID == nil else { return }
                if let last = model.visibleRows.last { proxy.scrollTo(last.id, anchor: .bottom) }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("bot.chat.transcript")
    }

    private var resolvedCardActions: BotCardActions {
        var actions = cardActions
        actions.openDocument = externalDocumentAction ?? { row in documentRow = row }
        return actions
    }

    private var composerDock: some View {
        VStack(spacing: 8) {
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
                    .background(NativeParityTokens.selector, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("bot.approval.banner")
            }
            if let notice = model.runtimeNotice {
                HStack(spacing: 8) {
                    Text(notice)
                        .botSecondaryFont()
                        .foregroundStyle(NativeParityTokens.error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.runtimeNotice = nil } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("发消息给 \(model.context.botName)", text: $draft, axis: .vertical)
                    .botBodyFont()
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("bot.composer.input")
                    .onSubmit { send() }
                if model.runningTurnID != nil {
                    Button { model.stop() } label: {
                        BotComposerGlyph(systemImage: "stop.fill")
                    }
                    .accessibilityLabel("停止当前回合")
                    .accessibilityIdentifier("bot.composer.stop")
                }
                Button(action: send) {
                    BotComposerGlyph(systemImage: "arrow.up")
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.35 : 1)
                .accessibilityLabel(model.runningTurnID == nil ? "发送消息" : "发送并 steering")
                .accessibilityIdentifier("bot.composer.send")
            }
            .padding(4)
            .background(HomeSpec.surface, in: RoundedRectangle(cornerRadius: HomeSpec.composerOpenRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: HomeSpec.composerOpenRadius, style: .continuous)
                .strokeBorder(NativeParityTokens.borderL1, lineWidth: 0.5))
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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
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

    var body: some View {
        BotAdaptiveBubbleLayout(ratio: isUser ? 0.8 : 1, trailing: isUser) {
            Text(row.body["text"]?.string ?? "")
                .botBodyFont()
                .foregroundStyle(HomeSpec.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, isUser ? 16 : 0)
                .padding(.vertical, isUser ? 12 : 4)
                .background(isUser ? HomeSpec.userBubble : Color.clear,
                            in: isUser ? HomeSpec.bubbleShape : UnevenRoundedRectangle())
        }
        .padding(.horizontal, HomeSpec.contentInset)
        .padding(.vertical, 4)
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
        Text(text)
            .botBodyFont()
            .foregroundStyle(HomeSpec.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, HomeSpec.contentInset)
            .padding(.vertical, 8)
            .accessibilityIdentifier("bot.streaming.text")
    }
}

private struct BotComposerGlyph: View {
    let systemImage: String

    var body: some View {
        ZStack {
            Circle()
                .fill(HomeSpec.primaryButton)
                .frame(width: HomeSpec.sendButton, height: HomeSpec.sendButton)
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(HomeSpec.primaryButtonInk)
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
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
