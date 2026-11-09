// SPDX-License-Identifier: MIT

import PhoneDSHBot
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct BotChatPage: View {
    @ObservedObject var model: BotChatModel
    var cardActions: BotCardActions
    var onOpenInfo: () -> Void
    var onOpenInfoSection: (BotInfoSection) -> Void
    var hasOnlineDevices: Bool
    var onConnectDevice: () -> Void
    var externalDocumentAction: ((BotUIRow) -> Void)?
    let isMainBot: Bool
    let onSelectBot: (String) -> Void
    let peerAppearance: (String) -> BotFishAppearance?
    let handleExternalDeepLink: (URL) -> Bool

    @State private var draft = ""
    @State private var sourceRow: BotUIRow?
    @State private var documentRow: BotUIRow?
    @State private var preservingHistoryPosition = false
    /// Finished turns whose process row the user opened.
    @State private var openTurns: Set<Int> = []
    /// Files chosen but not sent yet. The optimistic user row is built from
    /// the same `BotUIAttachment` shape the durable projection returns.
    @State private var pendingAttachments: [BotDraftAttachment] = []
    @State private var attachmentNotice: String?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @FocusState private var composerFocused: Bool

    init(model: BotChatModel, isMainBot: Bool = false,
         cardActions: BotCardActions = BotCardActions(),
         onOpenInfo: @escaping () -> Void = {},
         onOpenInfoSection: @escaping (BotInfoSection) -> Void = { _ in },
         onSelectBot: @escaping (String) -> Void = { _ in },
         peerAppearance: @escaping (String) -> BotFishAppearance? = { _ in nil },
         hasOnlineDevices: Bool = false,
         onConnectDevice: @escaping () -> Void = {},
         handleExternalDeepLink: @escaping (URL) -> Bool = { _ in false },
         openDocument: ((BotUIRow) -> Void)? = nil,
         initialAttachments: [BotDraftAttachment] = [],
         initialAttachmentNotice: String? = nil) {
        self.model = model
        self.cardActions = cardActions
        self.onOpenInfo = onOpenInfo
        self.onOpenInfoSection = onOpenInfoSection
        self.hasOnlineDevices = hasOnlineDevices
        self.onConnectDevice = onConnectDevice
        self.externalDocumentAction = openDocument
        self.isMainBot = isMainBot
        self.onSelectBot = onSelectBot
        self.peerAppearance = peerAppearance
        self.handleExternalDeepLink = handleExternalDeepLink
        _pendingAttachments = State(initialValue: initialAttachments)
        _attachmentNotice = State(initialValue: initialAttachmentNotice)
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
        .onOpenURL { url in
            if !model.openDeepLink(url), handleExternalDeepLink(url) {
                model.deepLinkError = nil
            }
        }
        .onAppear { model.noteInteraction() }
        .onChange(of: draft) { _, _ in model.noteInteraction() }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems,
                      maxSelectionCount: BotAttachmentPolicy.maxCount, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPhotos(items) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.data],
                      allowsMultipleSelection: true) { result in
            importPickedFiles(result)
        }
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
                    BotFishView(state: model.fishState, size: 32, appearance: model.appearance,
                                crowned: isMainBot)
                    Text(model.botName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(HomeSpec.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let style = headerActivityStyle {
                        BotHeaderActivityIcon(style: style)
                    }
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

    /// Pending approval outranks the running status; a running turn with no
    /// body yet shows the three-dot mark, a tool step shows the pencil.
    private var headerActivityStyle: BotHeaderActivityIcon.Style? {
        if model.pendingApprovalCount > 0 { return .alert }
        guard let activity = model.activity else { return nil }
        switch activity.status {
        case .thinking, .streaming:
            return .dots
        case .toolRunning:
            return .pencil
        }
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
                            transcriptRow(row)
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
            BotFishView(state: model.fishState, size: 96, appearance: model.appearance,
                        crowned: isMainBot, allowsPoke: true)
            Text("嗨，我是 \(model.botName)")
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
                BotActivityLine(activity: activity, fishState: model.fishState, appearance: model.appearance)
                    .transition(.opacity.combined(with: .offset(y: 6)))
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
            attachmentTray
            // Grok-style capsule composer: one white r26 capsule with the
            // 36pt attach button leading, the growing text field in the
            // middle, and one 36pt send/stop button trailing. No microphone
            // and no voice mode.
            BotComposerLayout {
                Menu {
                    Button {
                        model.noteInteraction()
                        showPhotos = true
                    } label: {
                        Label("照片", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        model.noteInteraction()
                        showFiles = true
                    } label: {
                        Label("文件", systemImage: "folder")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(HomeSpec.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(HomeSpec.userBubble, in: Circle())
                        .contentShape(Circle())
                }
                .accessibilityLabel("添加附件")
                .accessibilityIdentifier("bot.composer.attach")

                TextField("向 \(model.botName) 提问", text: $draft, axis: .vertical)
                    .font(.system(size: HomeSpec.bodySize))
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("bot.composer.input")
                composerActionButton
            }
            .frame(minHeight: 52)
            .background(HomeSpec.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(HomeSpec.borderList, lineWidth: 0.5))
            .homeComposerShadow()
            .simultaneousGesture(TapGesture().onEnded { model.noteInteraction() })
            if model.runningTurnID != nil {
                Text("发送会并入当前回合，不会排队；停止只取消当前回合。")
                    .botCaptionFont()
                    .foregroundStyle(HomeSpec.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.showsActivityLine && model.activity != nil)
        .padding(.horizontal, HomeSpec.chromeInset)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(HomeSpec.page)
        .accessibilityElement(children: .contain)
    }

    /// Chips for the files waiting to be sent, plus the one-line refusal for a
    /// file that was too large, over the count limit, or unreadable.
    @ViewBuilder
    private var attachmentTray: some View {
        if !pendingAttachments.isEmpty || attachmentNotice != nil {
            VStack(alignment: .leading, spacing: 6) {
                if !pendingAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(pendingAttachments) { item in
                                attachmentChip(item, index: pendingAttachments.firstIndex(of: item) ?? 0)
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.vertical, 1)
                    }
                    .frame(height: 46)
                }
                if let attachmentNotice {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 12))
                        Text(attachmentNotice)
                            .font(.system(size: 12))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { self.attachmentNotice = nil } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("关闭附件提示")
                    }
                    .foregroundStyle(BotUIPalette.danger)
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier("bot.composer.attachment.notice")
                }
            }
        }
    }

    private func attachmentChip(_ item: BotDraftAttachment, index: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: item.attachment.iconName)
                .font(.system(size: 13))
                .foregroundStyle(HomeSpec.textSecondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.attachment.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(HomeSpec.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(item.attachment.sizeLabel) · \(item.attachment.kindLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(HomeSpec.textTertiary)
            }
            .frame(maxWidth: 150, alignment: .leading)
            Button {
                pendingAttachments.removeAll { $0.id == item.id }
                model.noteInteraction()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(HomeSpec.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除附件 \(item.attachment.name)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .frame(height: 44)
        .background(HomeSpec.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(HomeSpec.borderList, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bot.composer.attachment.\(index)")
    }

    private func importPickedFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            attachmentNotice = "无法读取所选文件：\(error.localizedDescription)"
        case .success(let urls):
            var refusals: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("phone-dsh-bot-attachments", isDirectory: true)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent(
                    "\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                } catch {
                    refusals.append("附件「\(url.lastPathComponent)」未附加：\(error.localizedDescription)")
                    continue
                }
                if let refusal = addDraftAttachment(url: destination, displayName: url.lastPathComponent) {
                    refusals.append(refusal)
                }
            }
            attachmentNotice = refusals.isEmpty ? nil : refusals.joined(separator: "\n")
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        var refusals: [String] = []
        let stamp = Int(Date().timeIntervalSince1970)
        for (offset, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                refusals.append("附件「照片 \(offset + 1)」未附加：无法读取所选照片。")
                continue
            }
            let type = item.supportedContentTypes.first
            let ext = type?.preferredFilenameExtension ?? "jpg"
            let name = "photo-\(stamp)-\(offset + 1).\(ext)"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            do {
                try data.write(to: url)
            } catch {
                refusals.append("附件「\(name)」未附加：\(error.localizedDescription)")
                continue
            }
            if let refusal = addDraftAttachment(url: url, displayName: name,
                                                fallbackMIMEType: type?.preferredMIMEType) {
                refusals.append(refusal)
            }
        }
        attachmentNotice = refusals.isEmpty ? nil : refusals.joined(separator: "\n")
        photoItems = []
    }

    /// Returns a refusal message instead of appending when the count or size
    /// limit is exceeded; the message is shown immediately and the item is not
    /// added, matching the DSH Bot composer.
    private func addDraftAttachment(url: URL, displayName: String,
                                    fallbackMIMEType: String? = nil) -> String? {
        guard pendingAttachments.count < BotAttachmentPolicy.maxCount else {
            return "附件「\(displayName)」未附加：每条消息最多 \(BotAttachmentPolicy.maxCount) 个附件。"
        }
        guard let attachment = BotUIAttachment.local(url: url, fallbackMIMEType: fallbackMIMEType) else {
            return "附件「\(displayName)」未附加：文件为空或无法读取。"
        }
        guard attachment.size <= BotAttachmentPolicy.maxBytes else {
            return "附件「\(displayName)」未附加：文件超过 25 MiB（\(attachment.sizeLabel)）。"
        }
        var named = attachment
        named.name = displayName
        pendingAttachments.append(BotDraftAttachment(url: url, attachment: named))
        model.noteInteraction()
        return nil
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

    /// Exactly one round button with three states: send (idle, disabled when
    /// empty), stop (running with an empty draft), send-and-steer (running
    /// with text). The send id is stable so the capture tests can drive it.
    @ViewBuilder
    private var composerActionButton: some View {
        if model.runningTurnID != nil && !canSend {
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
            .accessibilityLabel(model.runningTurnID != nil ? "发送并 steering" : "发送消息")
            .accessibilityIdentifier("bot.composer.send")
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = pendingAttachments.map(\.url)
        guard !text.isEmpty || !files.isEmpty else { return }
        draft = ""
        pendingAttachments = []
        attachmentNotice = nil
        model.send(text: text, files: files)
        composerFocused = true
    }

    private func transcriptRow(_ row: BotUIRow) -> some View {
        BotTranscriptRow(row: row, model: model, actions: resolvedCardActions,
                         sourceRow: $sourceRow, onSelectBot: onSelectBot,
                         peerAppearance: peerAppearance)
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

/// Single-line capsule: the text field and the 36pt button share a center, so
/// the first text baseline and the button center line up. Once the field grows
/// past the 52pt capsule the button sticks to the bottom 8pt instead.
private struct BotComposerLayout: Layout {
    typealias Cache = Void

    private let inset: CGFloat = 8
    private let attachButton: CGFloat = 36
    private let gap: CGFloat = 4

    func makeCache(subviews: Subviews) -> Void {}

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let width = proposal.width ?? 0
        let inputWidth = max(0, width - inset - attachButton - gap - gap
                             - HomeSpec.sendButton - inset)
        let input = subviews[1].sizeThatFits(ProposedViewSize(width: inputWidth, height: nil))
        return CGSize(width: width, height: max(52, input.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout Void) {
        guard subviews.count == 3 else { return }
        let inputWidth = max(0, bounds.width - inset - attachButton - gap - gap
                             - HomeSpec.sendButton - inset)
        let input = subviews[1].sizeThatFits(ProposedViewSize(width: inputWidth, height: nil))
        let singleLine = input.height <= 52
        let controlY = singleLine
            ? bounds.minY + (bounds.height - attachButton) / 2
            : bounds.maxY - attachButton - inset
        let inputY = bounds.minY + max(0, (bounds.height - input.height) / 2)
        subviews[0].place(
            at: CGPoint(x: bounds.minX + inset, y: controlY),
            proposal: ProposedViewSize(width: attachButton, height: attachButton))
        subviews[1].place(
            at: CGPoint(x: bounds.minX + inset + attachButton + gap, y: inputY),
            proposal: ProposedViewSize(width: inputWidth, height: input.height))
        subviews[2].place(
            at: CGPoint(x: bounds.maxX - inset - HomeSpec.sendButton, y: controlY),
            proposal: ProposedViewSize(width: HomeSpec.sendButton, height: HomeSpec.sendButton))
    }
}

/// One picked file waiting for the send button. `attachment` is the metadata
/// the transcript card and the import action use; `url` is the readable local
/// copy handed to `BotAttachmentImporting`.
struct BotDraftAttachment: Identifiable, Equatable {
    let id: UUID
    let url: URL
    var attachment: BotUIAttachment

    init(id: UUID = UUID(), url: URL, attachment: BotUIAttachment) {
        self.id = id
        self.url = url
        self.attachment = attachment
    }

    static func fixture(name: String, size: Int64, mimeType: String, kind: String) -> BotDraftAttachment {
        BotDraftAttachment(
            url: URL(fileURLWithPath: "/tmp/phone-dsh-fixture/\(name)"),
            attachment: BotUIAttachment(name: name, size: size, mimeType: mimeType, kind: kind))
    }
}

private struct BotTranscriptRow: View {
    let row: BotUIRow
    @ObservedObject var model: BotChatModel
    let actions: BotCardActions
    @Binding var sourceRow: BotUIRow?
    let onSelectBot: (String) -> Void
    let peerAppearance: (String) -> BotFishAppearance?

    var body: some View {
        Group {
            if let comm = BotAgentCommRendering.presentation(for: row) {
                BotAgentCommRow(presentation: comm,
                                appearance: comm.peerID.flatMap(peerAppearance),
                                onSelectBot: onSelectBot)
                    .padding(.horizontal, HomeSpec.contentInset)
                    .padding(.vertical, HomeSpec.blockGap / 2)
            } else if row.body.type == "text" {
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

/// The minimal agent-comm line. Outbound/reply/inbound rows from
/// `agent.comm` collapse into one readable sentence plus a small peer avatar;
/// tapping the peer switches to that Bot. Full visuals are the sidebar wave.
private struct BotAgentCommRow: View {
    let presentation: BotAgentCommPresentation
    let appearance: BotFishAppearance?
    let onSelectBot: (String) -> Void

    private var icon: String {
        switch presentation.tone {
        case .outbound: return "arrow.up.right"
        case .inbound: return "arrow.down.left"
        case .incoming: return "tray.and.arrow.down"
        case .reply: return "arrowshape.turn.up.left"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        presentation.tone == .failed ? BotUIPalette.danger : HomeSpec.textSecondary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let appearance {
                BotFishView(state: .idle, size: 28, appearance: appearance, still: true)
            } else {
                Image(systemName: "person.2")
                    .font(.system(size: 12))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(HomeSpec.userBubble, in: Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                    Text(presentation.text)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(HomeSpec.textPrimary)
                        .lineLimit(1)
                }
                if let detail = presentation.detail {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(tint)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            if let id = presentation.peerID { onSelectBot(id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel([presentation.text, presentation.detail ?? ""].joined(separator: "，"))
        .accessibilityIdentifier("bot.agent-comm.row")
    }
}

private struct BotTextRow: View {
    let row: BotUIRow
    private var isUser: Bool { row.role == "user" }
    private var text: String { row.body["text"]?.string ?? "" }
    private var attachments: [BotUIAttachment] {
        isUser ? BotUIAttachment.parseList(row.body["attachments"]) : []
    }

    /// DSH message rows: the user's words in the gray bubble (80% width,
    /// top-trailing corner square), the Bot's answer as the DSH markdown body;
    /// rows sit 20pt apart. Attached files are cards under the user's words,
    /// inside the same bubble and column.
    var body: some View {
        Group {
            if isUser {
                BotAdaptiveBubbleLayout(ratio: 0.8, trailing: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !text.isEmpty {
                            Text(text)
                                .font(NativeChatTheme.bodyFont())
                                .lineSpacing(NativeChatTheme.bodyLineSpacing)
                                .foregroundStyle(HomeSpec.textPrimary)
                                .textSelection(.enabled)
                        }
                        ForEach(attachments) { attachment in
                            BotUserAttachmentCard(attachment: attachment)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(HomeSpec.userBubble, in: HomeSpec.bubbleShape)
                }
            } else {
                BotAnswerBubbleContent(text: text, streaming: false)
            }
        }
        .padding(.horizontal, HomeSpec.contentInset)
        .padding(.vertical, HomeSpec.blockGap / 2)
    }
}

/// The user row's attached-file card: name, size and kind, matching the DSH
/// Bot transcript attachment row without adding a second card style.
private struct BotUserAttachmentCard: View {
    let attachment: BotUIAttachment

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: attachment.iconName)
                .font(.system(size: 15))
                .foregroundStyle(HomeSpec.textPrimary)
                .frame(width: 32, height: 32)
                .background(HomeSpec.surface, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(HomeSpec.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(attachment.sizeLabel) · \(attachment.kindLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(HomeSpec.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(HomeSpec.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(HomeSpec.borderList, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(attachment.name)，\(attachment.sizeLabel)，\(attachment.kindLabel)")
        .accessibilityIdentifier("bot.message.attachment")
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
