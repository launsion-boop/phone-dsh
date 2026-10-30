// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — native conversation detail.

import PhoneDSHAgentCore
import PhoneDSH
import PhoneDSHEngine
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ChatPage: View {
    var openDrawer: (() -> Void)? = nil
    var drawerExpanded = false
    #if DEBUG
    /// 预览专用:直接吃一份本地造好的消息,不订阅宿主、不等记录就绪。
    var previewItems: [ChatItem]? = nil
    /// 预览专用:进页面时输入框里已经有这段字(验超长文本用)。
    var previewDraft: String? = nil
    #endif

    @State private var model = ChatModel.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var management = DSHManagementModel.shared
    @State private var draft = ""
    #if DEBUG
    @State private var didInjectDebugState = false
    @State private var hitProbe = ""
    #endif
    @State private var previousSessionKey = ""
    @AppStorage("chat.drafts.v1") private var savedDrafts = "{}"
    @AppStorage("phone-dsh.composer.busyEnter") private var busyEnterMode = "queue"
    @FocusState private var inputFocused: Bool
    @State private var pendingAttachments: [HarnessAttachment] = []
    @State private var showAttachmentPicker = false
    /// "添加文件" imports into the workspace; images stay native attachments.
    @State private var showFileImport = false
    /// Status line for a workspace import (the agent reads the file by path).
    @State private var fileImportNotice: String?
    @State private var commandExecution: NativeCommandExecution?
    @State private var showCommandResult = false
    @State private var isExecutingCommand = false
    @State private var showSessions = false
    @State private var showWorkbench = false
    @State private var initialWorkbenchPath: String?
    @State private var showSettings = false
    @State private var showProviderSettings = false
    /// A path whose bytes had not arrived yet; the next file refresh retries it.
    @State private var pendingPreviewPath: String?
    @State private var showSessionList = false
    @State private var debugSheet: String?
    @State private var showConfiguration = false
    @State private var showActivity = false
    @State private var showRuntimeDetails = false
    @State private var showSessionSettings = false
    @State private var cardsExpanded = false
    @State private var keyboardVisible = false
    @State private var renameTarget: ManagedSession?
    @State private var renameText = ""

    private func beginRename() {
        guard let id = model.currentSessionID,
              let session = management.sessions.first(where: { $0.id == id }) else { return }
        renameText = session.title
        renameTarget = session
    }
    @State private var confirmAccessMode: NativeAccessMode?
    @State private var isSelectingAccessMode = false
    @State private var attachmentError: String?
    @State private var nearBottom = true
    /// Measured transcript height; the scroll helpers use it to refuse a
    /// scroll into empty space.
    @State private var transcriptContentHeight: CGFloat = 0
    /// Set when a session opens; the next transcript layout jumps to the tail
    /// without animation so history loading never leaves the view at the top.
    @State private var pendingInitialScroll = false
    @State private var userScrolledAway = false
    /// Last measured tail offset; logged with every follow scroll so a
    /// "keeps scrolling" report can be diagnosed from chat-status.log.
    @State private var tailOffsetY: CGFloat = 0
    @State private var lastScrollTrace = Date.distantPast
    @State private var pasteLimitNoticed = false
    @State private var stopping = false
    @State private var scrollToLatestTrigger = 0
    /// Coalesces follow-the-tail scrolls so one lands after the lazy stack
    /// has laid the new rows out (see `scheduleTailScroll`).
    @State private var tailScrollTask: Task<Void, Never>?
    @State private var loadingEarlierTrajectory = false
    @State private var loadingEarlierTranscript = false

    private var providerNeedsKey: Bool {
        model.modelProviderIssue != nil
    }

    private var sessionKey: String { model.currentSessionID ?? "new" }
    private var sessionTitle: String {
        guard let id = model.currentSessionID else { return "新会话" }
        let title = management.sessions.first(where: { $0.id == id })?.title ?? ""
        if title.isEmpty || ["new conversation", "conversation"].contains(title.lowercased()) {
            return model.items.contains(where: { $0.kind == .user }) ? "当前会话" : "新会话"
        }
        return title
    }
    private var visibleItems: [ChatItem] {
        #if DEBUG
        if let previewItems { return previewItems }
        #endif
        return model.items.filter { $0.kind != .status }
    }
    private var transcriptScrollSignature: String {
        "\(visibleItems.map(\.id).joined(separator: ","))|\(visibleItems.last?.text ?? "")"
    }
    /// 自绘页头:左抽屉、中标题(可点改名)、右更多。行高 44,左右 16。
    private var chatHeader: some View {
        ZStack {
            Button { beginRename() } label: {
                Text(sessionTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(red: 0x11 / 255, green: 0x11 / 255, blue: 0x14 / 255))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .buttonStyle(.plain)
            .disabled(model.currentSessionID == nil)
            .accessibilityHint("点按重命名会话")
            .padding(.horizontal, providerNeedsKey ? 144 : 104)

            HStack(spacing: 0) {
                Button {
                    inputFocused = false
                    openDrawer?()
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 20, weight: .regular))
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(drawerExpanded ? "隐藏会话列表" : "打开会话列表")

                Spacer(minLength: 0)

                HStack(spacing: 4) {
                    Button { showRuntimeDetails = true } label: {
                        RunStatusDot(started: model.isStarted, parked: model.parked,
                                     needsModelConfiguration: providerNeedsKey)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("运行状态")
                    .accessibilityValue(providerNeedsKey ? "待配置模型服务" : model.displayStatus)
                    Menu {
                        ShareLink(item: historyExport,
                                  subject: Text("对话记录"),
                                  preview: SharePreview("对话记录")) {
                            Label("导出对话记录", systemImage: "square.and.arrow.up")
                        }
                        Button("子 Agent 与后台活动", systemImage: "person.2") { showActivity = true }
                            .disabled(model.currentSessionID == nil)
                        Button("本会话设置", systemImage: "slider.horizontal.3") { showSessionSettings = true }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 20))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .accessibilityLabel("更多操作")
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private var latestToolFailure: ChatItem? {
        guard let lastResult = model.items.last(where: { item in
            if case .toolResult = item.kind { return true }
            return false
        }), case .toolResult(isError: true) = lastResult.kind else { return nil }
        return lastResult
    }

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
            // A failure that belongs to one message is rendered under it; every
            // other failure (send refused, session open, stream error) needed a
            // surface too — it used to be invisible on this page.
            if model.failedItemID == nil, let error = model.userFacingError {
                errorBanner(error)
            }
            if let error = model.accessModeError { accessModeErrorBanner(error) }
            if let error = model.commandsError { commandErrorBanner(error) }
            cardsRegion
            transcript
        }
        // The composer is a bottom safe-area inset, not a stack item: the
        // keyboard then lifts only the composer and the content area shrinks
        // from the bottom. Putting it in the VStack lets the keyboard push the
        // whole stack (including the title row) up under the status bar on
        // newer iOS versions.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
            if model.pendingQuestion == nil { cardsExpanded = false }
        }
        .background(Color(.systemBackground))
        .navigationTitle({
            #if DEBUG
            return hitProbe
            #else
            return ""
            #endif
        }())
        .navigationBarTitleDisplayMode(.inline)
        // 系统导航栏整个隐掉:页头自己画、自己接点击。留着那层,看得见的是
        // 我们的页头,接点击的却是它,左上角那个按钮就是这么点不开的。
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .alert("重命名会话", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })) {
            TextField("会话名称", text: $renameText)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button("保存") {
                guard let session = renameTarget else { return }
                let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                renameTarget = nil
                guard !title.isEmpty else { return }
                Task { await management.rename(session, to: title) }
            }
        }
        .sheet(isPresented: $showSessions) {
            SessionsPage { showSessions = false }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showWorkbench) {
            NativeWorkbenchPage(sessionID: model.currentSessionID, initialPath: initialWorkbenchPath)
                .presentationDragIndicator(.visible)
        }
        .sheet(item: Binding(get: { debugSheet.map(DebugSheetToken.init) }, set: { debugSheet = $0?.value })) { token in
            if token.value == "provider" {
                NavigationStack { ModelProviderSettingsPage() }
            }
        }
        .sheet(isPresented: $showProviderSettings) {
            NavigationStack { ModelProviderSettingsPage() }
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsPage() }
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSessionSettings) {
            NavigationStack { NativeConfigurationPage() }
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showConfiguration) {
            NativeConfigurationPage()
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showCommandResult) {
            if let commandExecution {
                CommandExecutionResultPage(execution: commandExecution,
                                           onOpenFile: openWorkspaceResult)
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showRuntimeDetails) { RuntimeDetailsPage(model: model) }
        // 「完全权限」是唯一会改掉未来的开关:点它不直接生效,先弹系统的确认窗。
        // 标题里的名字和菜单项一字不差;开着的时候点同一项不用再问。
        .alert(accessModeConfirmationTitle, isPresented: Binding(
            get: { confirmAccessMode != nil },
            set: { if !$0 { confirmAccessMode = nil } }
        )) {
            Button("取消", role: .cancel) { confirmAccessMode = nil }
            Button("开启") {
                guard let mode = confirmAccessMode else { return }
                Task { await selectAccessMode(mode) }
                confirmAccessMode = nil
            }
        } message: {
            Text(AccessModeWording.confirmationMessage(for: confirmAccessMode?.id ?? "")
                 ?? "之后改文件、跑命令都不再问你。")
        }
        // 系统窗里的按钮吃这层的 tint,不写就是黑的,不是我们的蓝。
        .tint(ChatPage.accent)
        .sheet(isPresented: $showActivity) {
            if let sessionID = model.currentSessionID {
                NavigationStack { SessionActivityPage(sessionID: sessionID) }
                    .presentationDragIndicator(.visible)
            }
        }
        .fileImporter(
            isPresented: $showAttachmentPicker,
            allowedContentTypes: Self.imageContentTypes,
            allowsMultipleSelection: true,
            onCompletion: loadAttachments
        )
        // DSH's prompt path accepts image attachments only; any other file is
        // imported into the session workspace (the DSH-native way for the
        // agent to read it) and inserted as a path reference.
        .fileImporter(
            isPresented: $showFileImport,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true,
            onCompletion: loadWorkspaceFiles
        )
        .onChange(of: model.isTranscriptReady) { _, _ in
            #if DEBUG
            debugInjectIfReady()
            #endif
        }
        .onAppear {
            #if DEBUG
            if debugChatState != nil { debugInjectIfReady() }
            #endif
            previousSessionKey = sessionKey
            draft = savedDraft(for: sessionKey)
            #if DEBUG
            // 预览:输入框里先放好那段超长文本,验行高和滚动。
            if let previewDraft, draft.isEmpty { draft = previewDraft }
            #endif
            if model.isStarted { Task { await management.refresh() } }
            // The native surface owns the one host now, so a cold launch
            // starts it directly instead of waiting for a tap.
            if !model.isStarted, !model.busy {
                Task { await model.start() }
            }
            // Device-test automation (PDSH_CHAT_AUTOSTART / PDSH_CHAT_AUTOPROMPT).
            model.autostartIfRequested()
#if DEBUG
            if ProcessInfo.processInfo.environment["PDSH_DEBUG_TOOLRUN"] == "1", model.items.isEmpty {
                model.debugInjectToolRun()
            }
            if ProcessInfo.processInfo.environment["PDSH_DEBUG_START"] == "1" {
                Task { @MainActor in
                    await model.start()
                    try? await Task.sleep(for: .milliseconds(600))
                    if ProcessInfo.processInfo.environment["PDSH_DEBUG_FOCUS"] == "1" {
                        inputFocused = true
                    }
                }
            } else if ProcessInfo.processInfo.environment["PDSH_DEBUG_FOCUS"] == "1" {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(700))
                    inputFocused = true
                }
            }
            if let sheet = ProcessInfo.processInfo.environment["PDSH_DEBUG_SHEET"], !sheet.isEmpty {
                let delay = Int(ProcessInfo.processInfo.environment["PDSH_DEBUG_SHEET_DELAY_MS"] ?? "") ?? 400
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(delay))
                    switch sheet {
                    case "settings": showSettings = true
                    case "sessions": showSessions = true
                    case "provider": debugSheet = "provider"
                    case "config": showConfiguration = true
                    case "workbench": showWorkbench = true
                    default: break
                    }
                }
            }
#endif
        }
        .onChange(of: model.currentSessionID) { _, _ in
            // A successful selection can update ChatModel from the sidebar's
            // async task before its completion callback reaches this sheet.
            // Close from the observed source of truth as well, so restoring a
            // real session never leaves the user stranded in the sidebar.
            showSessions = false
            persistDraft(draft, for: previousSessionKey)
            previousSessionKey = sessionKey
            draft = savedDraft(for: sessionKey)
            #if DEBUG
            // 预览:输入框里先放好那段超长文本,验行高和滚动。
            if let previewDraft, draft.isEmpty { draft = previewDraft }
            #endif
            pendingAttachments.removeAll()
            attachmentError = nil
            // Opening another session must show its newest message, not the
            // top of the transcript.
            nearBottom = true
            userScrolledAway = false
            pendingInitialScroll = true
            Task { await management.refresh() }
        }
        .onChange(of: draft) { _, value in persistDraft(value, for: sessionKey) }
        .onChange(of: showWorkbench) { _, isPresented in
            if !isPresented { initialWorkbenchPath = nil }
        }
        // A tool-written file lands in the materialized workspace a moment
        // after the result row; keep the list warm while a turn runs and open
        // a path the person already tapped as soon as it appears.
        .onChange(of: model.files) { _, files in
            guard let pending = pendingPreviewPath else { return }
            guard let match = files.first(where: { $0.relativePath == pending })
                ?? Self.uniqueBasenameMatch(pending, in: files) else { return }
            pendingPreviewPath = nil
            attachmentError = nil
            initialWorkbenchPath = match.relativePath
            showWorkbench = true
        }
        .task(id: model.turnRunning) {
            guard model.turnRunning else { return }
            while !Task.isCancelled, model.turnRunning {
                model.refreshFiles()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// 同人 12、换人 20、状态行贴消息 6、工具行 8。
    static func spacing(before index: Int, in rows: [NativeTranscriptRow]) -> CGFloat {
        guard index > 0, index < rows.count else { return 0 }
        func kind(_ row: NativeTranscriptRow) -> ChatItem.Kind? {
            switch row {
            case .item(let item): return item.kind
            case .tools: return .toolCall
            case .contexts: return nil
            }
        }
        let current = kind(rows[index]), previous = kind(rows[index - 1])
        if current == .status { return 6 }
        if let current {
            switch current {
            case .toolCall, .toolResult: return 8
            case .status: return 6
            default: break
            }
        }
        if current == .context || current == nil { return 8 }
        if let current, let previous, current == previous { return 12 }
        return 20
    }

    /// Tool calls and tool results share the grouped process row.
    private static func isToolKind(_ kind: ChatItem.Kind) -> Bool {
        switch kind {
        case .toolCall, .toolResult: return true
        default: return false
        }
    }

    private var timelineRows: [NativeTranscriptRow] {
        var rows: [NativeTranscriptRow] = []
        for item in visibleItems {
            if item.kind == .context {
                if case .contexts(let previous)? = rows.last {
                    rows[rows.count - 1] = .contexts(previous + [item])
                } else {
                    rows.append(.contexts([item]))
                }
            } else if Self.isToolKind(item.kind) {
                // A turn's tool activity is process, not content: one row for
                // the whole run, opened on demand.
                if case .tools(let previous)? = rows.last {
                    rows[rows.count - 1] = .tools(previous + [item])
                } else {
                    rows.append(.tools([item]))
                }
            } else {
                rows.append(.item(item))
            }
        }
        return rows
    }

    /// Cards share a bounded area. Each card owns its scrolling so question
    /// actions remain visible while the options scroll or the keyboard opens.
    private var pendingCardCount: Int {
        (model.pendingPermission == nil ? 0 : 1) + (model.pendingQuestion == nil ? 0 : 1)
    }

    @ViewBuilder
    private var cardsRegion: some View {
        if pendingCardCount > 0 {
            if keyboardVisible && !cardsExpanded && model.pendingQuestion == nil {
                Button {
                    cardsExpanded = true
                } label: {
                    HStack(spacing: 9) {
                        // 「需要处理」是唯一该抢眼的点,全站用同一个警告橙 #B45309。
                        Circle()
                            .fill(ChatPage.warning)
                            .frame(width: 8, height: 8)
                        Text("\(pendingCardCount) 项需要处理")
                            .font(.system(size: 13))
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 0) {
                    // One card at a time: permission wins, and the other one
                    // folds into a line above it.
                    if model.pendingPermission != nil, model.pendingQuestion != nil {
                        Button { cardsExpanded.toggle() } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "exclamationmark.circle")
                                    .font(.system(size: 12))
                                Text("还有 1 个待确认")
                                    .font(.system(size: 12))
                                Spacer()
                                Image(systemName: cardsExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(Self.inkSecondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if let permission = model.pendingPermission {
                        ScrollView {
                            permissionCard(permission)
                        }
                    } else if let question = model.pendingQuestion {
                        QuestionCard(question: question) { answer in
                            Task { await model.respondToQuestion(answer: answer) }
                        }
                        .id(question.requestID)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    if cardsExpanded, model.pendingPermission != nil, let question = model.pendingQuestion {
                        QuestionCard(question: question) { answer in
                            Task { await model.respondToQuestion(answer: answer) }
                        }
                        .id(question.requestID)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                }
                .frame(maxHeight: UIScreen.main.bounds.height * 0.4)
            }
        }
    }

    @ViewBuilder
    private func queueLine(for item: ChatItem) -> some View {
        if let label = model.queueLabel[item.id] {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(ChatPage.inkSecondary)
                .padding(.top, 6)
        }
    }

    @ViewBuilder
    private func failureLineIfNeeded(for item: ChatItem) -> some View {
        if model.failedItemID == item.id, let failure = model.userFacingError {
            failureLine(failure)
        }
    }

    /// 贴在失败那条下面 6 点处的一行:13 号 #C0392B,「没发出去」+ 间距 +「重试」。
    private func failureLine(_ reason: String) -> some View {
        // 一行三段,同一基线:没发出去(红) · 原因(灰,宿主真读到时才有) · 重试(蓝)。
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("没发出去")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ChatPage.danger)
            if !reason.isEmpty {
                Text("·")
                    .font(.system(size: 13))
                    .foregroundStyle(ChatPage.inkSecondary)
                Text(reason)
                    .font(.system(size: 13))
                    .foregroundStyle(ChatPage.inkSecondary)
            }
            if model.failedPrompt != nil {
                Text("·")
                    .font(.system(size: 13))
                    .foregroundStyle(ChatPage.inkSecondary)
                Button("重试") { Task { _ = await model.retryFailedPrompt() } }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ChatPage.accent)
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    #if DEBUG
    /// 注入要等记录就绪,否则宿主拉回记录时会把它覆盖掉。
    private func debugInjectIfReady() {
        // A preview page carries its own items, so the state that belongs to
        // one of them (a failure line, a queued label) is applied here instead
        // of waiting for a live turn that never happens.
        if previewItems != nil, let state = debugChatState, !didInjectDebugState {
            didInjectDebugState = true
            switch state {
            case "chat.failed":
                model.debugInstallPreviewState(failedItemID: "p-u2",
                                               error: "示例：这次回合失败了。",
                                               queue: [:])
            case "chat.queued":
                model.debugInstallPreviewState(failedItemID: nil, error: nil,
                                               queue: ["p-u3": "已排队"])
            case "chat.question":
                model.debugInstallPreviewState(failedItemID: nil, error: nil, queue: [:],
                    question: HarnessQuestion(requestID: "preview-question", prompt: "请选择处理方式", questions: [
                        HarnessQuestionItem(id: "scope", prompt: "这次需要处理哪些内容？",
                            options: ["修复当前页面布局", "检查其他页面的按钮", "兼容小屏幕手机", "检查键盘弹出时的布局", "支持较大的系统字体", "保留已有聊天记录", "验证多选问题", "完成后重新安装"], multiple: true),
                        HarnessQuestionItem(id: "validation", prompt: "修复完成后如何验证？",
                            options: ["在手机上验证", "先检查构建结果"])
                    ]))
            default:
                break
            }
            return
        }
        guard let state = debugChatState, !didInjectDebugState, model.isTranscriptReady else { return }
        didInjectDebugState = true
        switch state {
        case "chat.failed": model.debugInjectFailure()
        case "chat.queued": model.debugInjectQueued()
        default: break
        }
    }

    private var debugChatState: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-uiPreview"), args.count > index + 1 else { return nil }
        let value = args[index + 1]
        return value.hasPrefix("chat.") ? value : nil
    }
    #endif

    /// 「没发出去」+ 间距 +「重试」;中间不加标点,也不补半句原因。
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(ChatPage.warning)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.failedPrompt != nil {
                Button("重试") { Task { _ = await model.retryFailedPrompt() } }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ChatPage.accent)
            }
            Button { model.clearError() } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                .accessibilityLabel("关闭提示")
                .foregroundStyle(ChatPage.inkSecondary)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }

    private func toolFailureBanner(_ item: ChatItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text("工具执行失败").font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                    Text(item.text.components(separatedBy: .newlines).first ?? item.text)
                        .font(.footnote).foregroundStyle(Self.inkSecondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.red.opacity(0.06))
    }

    private func accessModeErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(.orange)
            Text(message).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            Button("重试") { Task { await model.refreshAccessModes() } }
                .font(.footnote.weight(.medium))
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private func commandErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "command").foregroundStyle(.orange)
            Text(message).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            Button("重试") { Task { await model.loadCommands() } }
                .font(.footnote.weight(.medium))
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    /// Card colours and buttons per the design spec: #F2F3F5 surface, 16pt
    /// inset, 12pt radius, one filled primary action and a plain text deny —
    /// denying is not destructive, so it is not red.
    private func permissionCard(_ permission: ChatPermission) -> some View {
        PermissionCardView(permission: permission,
                           isBusy: model.busy,
                           onAllow: { respond(.allowOnce) },
                           onDeny: { respond(.deny) })
    }


    private func respond(_ decision: PermissionDecision) {
        guard let pending = model.pendingPermission else { return }
        Task { await model.respond(to: pending, decision: decision) }
    }

    /// The design's fixed values, so the card does not drift page by page.
    static let accent = Color(red: 0x2F / 255, green: 0x5B / 255, blue: 0xFF / 255)
    static let surface = Color(red: 0xF2 / 255, green: 0xF3 / 255, blue: 0xF5 / 255)
    /// #66666B — 5.13:1 on the card surface.
    static let inkSecondary = Color(red: 0x66 / 255, green: 0x66 / 255, blue: 0x6B / 255)
    /// 停止类动作的红色,白底 4.89。
    static let danger = Color(red: 0xC0 / 255, green: 0x39 / 255, blue: 0x2B / 255)
    /// 分隔线。
    static let hairline = Color(red: 0xDD / 255, green: 0xDC / 255, blue: 0xE2 / 255)
    /// 警告色 #B45309:只用于状态词和图标,不做整块底色。
    static let warning = Color(red: 0xB4 / 255, green: 0x53 / 255, blue: 0x09 / 255)

    private var transcript: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if model.transcriptHasMore {
                            Button {
                                guard !loadingEarlierTranscript else { return }
                                loadingEarlierTranscript = true
                                Task {
                                    await model.loadEarlierTranscript()
                                    loadingEarlierTranscript = false
                                }
                            } label: {
                                HStack {
                                    if loadingEarlierTranscript { ProgressView().controlSize(.small) }
                                    Text(loadingEarlierTranscript ? "正在加载…" : "加载更早消息")
                                }
                                .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                            .disabled(loadingEarlierTranscript)
                        }
                        if let error = model.transcriptError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                        if model.isShowingCachedTranscript {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("显示上次对话 · 引擎后台启动中…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(ChatPage.inkSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 4)
                        }
                        if visibleItems.isEmpty { emptyTimeline(viewportHeight: viewport.size.height) }
                        let rows = timelineRows
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            Group {
                            switch row {
                            case .item(let item):
                                VStack(alignment: .leading, spacing: 0) {
                                    ChatMessageRow(item: item, workspaceFiles: model.files,
                                                   onOpenFile: openWorkspaceResult)
                                    queueLine(for: item)
                                    failureLineIfNeeded(for: item)
                                }
                                .id(item.id)
                            case .contexts(let items):
                                NativeContextSourceGroup(items: items)
                                    .id("context-\(items.first?.id ?? "empty")")
                            case .tools(let items):
                                ToolRunRow(items: items, workspaceFiles: model.files,
                                           onOpenFile: openWorkspaceResult)
                                    .id("tool-run-\(items.first?.id ?? "empty")")
                            }
                            }
                            .padding(.top, Self.spacing(before: index, in: rows))
                        }
                        GeometryReader { tail in
                            Color.clear.preference(key: TranscriptTailPreference.self,
                                                   value: tail.frame(in: .named("chat-transcript")).minY)
                        }
                        .frame(height: 1)
                        .id("transcript-tail")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 22)
                    // Room for the "回到最新" pill (28pt tall) so it never sits
                    // on top of the last rows.
                    .padding(.bottom, 48)
                    .background(
                        GeometryReader { content in
                            Color.clear.preference(
                                key: TranscriptContentHeightPreference.self,
                                value: content.size.height)
                        })
                }
                .coordinateSpace(name: "chat-transcript")
                .scrollDismissesKeyboard(.interactively)
                .scrollBounceBehavior(.basedOnSize)
                .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { value in
                    if value.translation.height > 8 {
                        userScrolledAway = true
                    } else if value.translation.height < -8, nearBottom {
                        userScrolledAway = false
                    }
                })
                .onPreferenceChange(TranscriptContentHeightPreference.self) { height in
                    guard height.isFinite, height >= 0 else { return }
                    transcriptContentHeight = height
                }
                .onPreferenceChange(TranscriptTailPreference.self) { tailY in
                    guard tailY.isFinite else { return }
                    tailOffsetY = tailY
                    // Only a deliberate upward drag pauses following. Content
                    // growth must not be mistaken for the user leaving the tail.
                    nearBottom = tailY >= -1 && tailY <= viewport.size.height + 44
                }
                .onChange(of: transcriptScrollSignature) { _, _ in
                    if pendingInitialScroll, !visibleItems.isEmpty {
                        // Wait for the measured content height: scrolling
                        // before the layout is known cannot prove the content
                        // overflows, and the height change consumes this below.
                        guard transcriptContentHeight > 0 else { return }
                        pendingInitialScroll = false
                        nearBottom = true
                        scrollToTail(proxy, viewportHeight: viewport.size.height)
                        return
                    }
                    guard !userScrolledAway, !loadingEarlierTranscript else { return }
                    scheduleTailScroll(proxy, viewportHeight: viewport.size.height)
                }
                .onChange(of: model.isTranscriptReady) { _, ready in
                    guard ready, pendingInitialScroll, !visibleItems.isEmpty,
                          transcriptContentHeight > 0 else { return }
                    pendingInitialScroll = false
                    nearBottom = true
                    scrollToTail(proxy, viewportHeight: viewport.size.height)
                }
                .onChange(of: transcriptContentHeight) { _, height in
                    // A freshly opened session measures its history after the
                    // first layout; the pending jump lands here.
                    guard height > 0, pendingInitialScroll, !visibleItems.isEmpty else { return }
                    pendingInitialScroll = false
                    nearBottom = true
                    scrollToTail(proxy, viewportHeight: viewport.size.height)
                }
                .onChange(of: scrollToLatestTrigger) { _, _ in
                    nearBottom = true
                    userScrolledAway = false
                    withAnimation(.easeOut(duration: 0.2)) {
                        scrollToTail(proxy, viewportHeight: viewport.size.height)
                    }
                }
                .onChange(of: viewport.size.height) { old, new in
                    // The keyboard and the growing composer change the
                    // viewport. A transcript that was following re-anchors to
                    // the tail, so no blank strip is left below the content.
                    guard new.isFinite, new > old, !userScrolledAway else { return }
                    scheduleTailScroll(proxy, viewportHeight: new)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if userScrolledAway && !visibleItems.isEmpty {
                Button { scrollToLatestTrigger += 1 } label: {
                    Label("回到最新", systemImage: "arrow.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Self.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        // Opaque: a translucent capsule let the row underneath
                        // read through and looked like overlapping text.
                        .background(Self.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color(uiColor: .separator)))
                }
                .padding(.bottom, 12)
            }
        }
    }

    /// Scrolls to the transcript's last row, and only when the content
    /// actually overflows: scrolling a shorter transcript to a bottom anchor
    /// overshoots into empty space (the blank page). The last row is a real,
    /// laid-out frame; the lazy tail anchor can be scrolled past its estimate.
    private func scrollToTail(_ proxy: ScrollViewProxy, viewportHeight: CGFloat) {
        guard transcriptContentHeight.isFinite, viewportHeight.isFinite,
              tailOffsetY.isFinite, viewportHeight > 0,
              transcriptContentHeight > viewportHeight + 1 else { return }
        // The last row may be a folded tool-run group, not the last message;
        // scroll to the row that is actually last.
        if let last = timelineRows.last?.id {
            proxy.scrollTo(last, anchor: .bottom)
        } else {
            proxy.scrollTo("transcript-tail", anchor: .bottom)
        }
    }

    /// Follow after the next layout pass, unless the user deliberately moved
    /// into history. Delaying one short turn lets new row frames settle.
    private func scheduleTailScroll(_ proxy: ScrollViewProxy, viewportHeight: CGFloat) {
        guard !userScrolledAway, viewportHeight.isFinite, viewportHeight > 0 else { return }
        tailScrollTask?.cancel()
        tailScrollTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, !userScrolledAway else { return }
            if Date().timeIntervalSince(lastScrollTrace) > 1 {
                lastScrollTrace = Date()
                ChatModel.appendDiagnostic(
                    "scroll tail content=\(String(describing: transcriptContentHeight)) "
                    + "viewport=\(String(describing: viewportHeight)) "
                    + "tail=\(String(describing: tailOffsetY)) near=\(nearBottom) away=\(userScrolledAway)")
            }
            scrollToTail(proxy, viewportHeight: viewportHeight)
        }
    }

    /// 新会话空屏。三种状态互斥,同一时刻只渲染一种;三者都在滚动区里,
    /// 不做覆盖层/浮层。
    /// - A 引擎未启动(优先):`model.isStarted == false`
    /// - B 引擎已启动、模型服务没配好:`providerNeedsKey`
    /// - C 两者都好:居中两行文字
    @ViewBuilder
    private func emptyTimeline(viewportHeight: CGFloat) -> some View {
        if !model.isStarted {
            engineNotStartedState
                .padding(.top, 88)
        } else if providerNeedsKey {
            providerSetupState
                .padding(.top, 88)
        } else {
            readyState(viewportHeight: viewportHeight)
        }
    }

    /// A:引擎还没启动。整块横向居中,文字左对齐在 338 宽的列里。
    private var engineNotStartedState: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("引擎还没启动")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(red: 0x11 / 255, green: 0x11 / 255, blue: 0x14 / 255))
            Text("启动之后就能开始。")
                .font(.system(size: 13))
                .foregroundStyle(Self.inkSecondary)
                .padding(.top, 8)
            Button {
                guard !model.busy else { return }
                Task { await model.start() }
            } label: {
                Text(model.busy ? "正在启动…" : "启动本地引擎")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 338, height: 50)
                    .background(Self.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(model.busy)
            .padding(.top, 24)
        }
        .frame(width: 338, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// B:引擎已启动,只差模型服务。保留原来的卡,版式不动。
    private var providerSetupState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("还差一步:配好模型服务")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
            if let issue = model.modelProviderIssue {
                Text(issue)
                    .font(.system(size: 13))
                    .foregroundStyle(ChatPage.inkSecondary)
            }
            Button {
                showProviderSettings = true
            } label: {
                Text("去配置模型服务")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(ChatPage.accent, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// C:引擎与模型都就绪。文字块中心落在「对话区中心 + 24」。
    private func readyState(viewportHeight: CGFloat) -> some View {
        // 滚动内容的 LazyVStack 上、下各留 22 / 48(见 transcript 里的
        // padding)。容器高度取扣除这两段后的可用高度并在其中居中,
        // 再整体下移 24,文字块中心就是视口中心 + 24。
        let topInset: CGFloat = 22
        let bottomInset: CGFloat = 48
        let availableHeight = max(0, viewportHeight - topInset - bottomInset)
        let downwardShift = 24 + (bottomInset - topInset) / 2
        return VStack(spacing: 24) {
            Image("LogoBackground")
                .resizable()
                .scaledToFit()
                .frame(width: 220, height: 220)
                .opacity(colorScheme == .dark ? 0.12 : 0.18)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            VStack(spacing: 4) {
                Text("Phone DSH")
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(colorScheme == .dark
                        ? Color(red: 0xC9 / 255, green: 0xC9 / 255, blue: 0xCE / 255)
                        : Color(red: 0x4B / 255, green: 0x4B / 255, blue: 0x52 / 255))
                Text("运行在手机端的 DeepSeek Harness")
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(colorScheme == .dark
                        ? Color(red: 0x8A / 255, green: 0x8A / 255, blue: 0x90 / 255)
                        : Color(red: 0x71 / 255, green: 0x71 / 255, blue: 0x7A / 255))
            }
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: availableHeight)
        .offset(y: downwardShift)
    }

    private var composer: some View {
        VStack(spacing: 9) {
            if !pendingAttachments.isEmpty { attachmentStrip }
            if let attachmentError {
                HStack {
                    Text(attachmentError).font(.footnote).foregroundStyle(.red)
                    Spacer()
                    Button("关闭") { self.attachmentError = nil }.font(.footnote)
                }
            }
            if model.turnRunning && busyEnterMode == "steer" && !pendingAttachments.isEmpty {
                Text("补充说明不支持附带图片；请切换为“排入下一轮”或移除图片。")
                    .font(.footnote).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let fileImportNotice {
                HStack {
                    Text(fileImportNotice).font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("关闭") { self.fileImportNotice = nil }.font(.footnote)
                }
            }
            // The DSH input trigger: a bare leading `/token` opens the command
            // menu in place; picking one writes the token back into the draft.
            if slashToken != nil {
                slashCommandMenu
            }
            // 输入条是一整块浅灰圆角板。板内网格:上 12、下 12、左 14、右 8;
            // 文字行 22、间距 10、工具行 32,单行合计 88。工具行靠左排,
            // 发送/停止固定板内右下(右 8、底 8),文字因此不被按钮挤窄。
            VStack(spacing: 0) {
                // Composer per the design spec: 17pt text, 22pt line,
                // 1–5 lines then it scrolls inside.
                // TextEditor, not a vertical TextField: past five lines a
                // TextField clips the last visible line instead of scrolling,
                // which made a long draft impossible to read or edit. The
                // editor scrolls inside its five-line frame.
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text(composerPlaceholder)
                            .font(.system(size: 17))
                            .foregroundStyle(ChatPage.inkSecondary)
                            .padding(.leading, 5)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $draft)
                        .scrollContentBackground(.hidden)
                        .font(.system(size: 17))
                        .lineSpacing(2)
                        .focused($inputFocused)
                        .disabled(!composerEnabled)
                        .frame(minHeight: 22, maxHeight: 118)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(composerPlaceholder)
                }
                .padding(.leading, 14)
                .padding(.trailing, 8)
                .frame(minHeight: 22)
                .padding(.top, 6)
                    .onChange(of: draft) { _, value in
                        if value.count > 8_000 {
                            draft = String(value.prefix(8_000))
                            if !pasteLimitNoticed {
                                pasteLimitNoticed = true
                                attachmentError = "已截断到 8000 字。"
                            }
                        }
                    }

                composerControls
                    .padding(.leading, 14)
                    // 右侧给发送键留出 40(32 圆 + 8 间隙),工具行不钻到按钮下面。
                    .padding(.trailing, 40)
                    .frame(height: 32)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 发送键/停止键独占板内右下:32 圆到板右、板底各 8。
            // 44 是触控区,圆形 32 居中,所以外框再各收 2。
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 8) {
                    if model.turnRunning, canSubmit {
                        stopButton(diameter: 24, icon: 9)
                    }
                    if canSubmit || model.turnRunning {
                        actionButton
                    }
                }
                .padding(.trailing, 2)
                .padding(.bottom, 2)
            }
            .background(Color(red: 0xF2 / 255, green: 0xF3 / 255, blue: 0xF5 / 255),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        // 输入区外整片纯白,不画分隔线;靠上方的间距和对话分开。
        .background(Color.white)
        // The command catalog is pulled the first time the trigger opens, the
        // same lazy load the DSH command directory does per session.
        .onChange(of: slashToken) { _, token in
            guard token != nil, model.availableCommands.isEmpty,
                  !model.commandsLoading else { return }
            Task { await model.loadCommands() }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if !canSubmit && model.turnRunning {
            stopButton(diameter: 32, icon: 13)
        } else if canSubmit {
            Button(action: submitDraft) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(ChatPage.accent, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
            .animation(.easeOut(duration: 0.12), value: canSubmit)
            .accessibilityLabel("发送消息")
        }
    }

    private func stopButton(diameter: CGFloat, icon: CGFloat) -> some View {
        Button {
            guard !stopping else { return }
            stopping = true
            Task {
                await model.cancelTurn()
                stopping = false
            }
        } label: {
            Group {
                if stopping {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .frame(width: diameter, height: diameter)
                        .background(ChatPage.inkSecondary.opacity(0.7), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                } else {
                    Image(systemName: "stop.fill")
                        .font(.system(size: icon, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: diameter, height: diameter)
                        .background(ChatPage.inkSecondary, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(stopping ? "正在停止" : "停止执行")
    }

    private var composerControls: some View {
        // 外框按板内网格:左 14 起,按钮热区 32×32、相邻间隔 8(中心距 40);
        // 图标 17、文字 13,控件左右内边距 4,保持既有“墨迹约 20”的验收。
        HStack(spacing: 8) {
            Menu {
                Button("添加图片", systemImage: "photo") { showAttachmentPicker = true }
                Button("添加文件（写入工作区）", systemImage: "doc.badge.plus") {
                    showFileImport = true
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(ChatPage.inkSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!composerEnabled)
            .accessibilityLabel("添加图片或文件")
            accessModeMenu
            if providerNeedsKey {
                Button {
                    showProviderSettings = true
                } label: {
                    Label("配置模型服务", systemImage: "key")
                        .font(.system(size: 13))
                        .frame(minHeight: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ChatPage.accent)
            } else {
                modelMenu
            }
            if model.turnRunning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在执行")
            }
        }
    }

    /// 菜单照宿主的目录来:有几项列几项、顺序也照宿主的,我们只翻名字。
    /// 不合并、不删减;翻不出中文的档不列,只在当前生效时报一句状态。
    private var listedAccessModes: [NativeAccessMode] {
        var seen = Set<String>()
        var modes = model.availableAccessModes.filter { mode in
            guard let title = AccessModeWording.title(for: mode.id) else { return false }
            return seen.insert(title).inserted   // 两个 id 叫同一个名字时只出现一行
        }
        // 「完全权限」钉在最后一行可选行:最松的一档离手指最远。
        if let index = modes.firstIndex(where: { AccessModeWording.title(for: $0.id) == "完全权限" }) {
            modes.append(modes.remove(at: index))
        }
        // 这块菜单从输入框往上弹:系统把数组第一项画在最下面,
        // 所以数组要倒过来写,屏幕上才是从上到下 仅可查看 → 工作区内修改 → 完全权限。
        return modes.reversed()
    }

    /// 当前组合没匹配上任何预设时,在可选行之后报一句状态:给人看,不能点。
    private var currentStatusText: String? {
        AccessModeWording.statusText(forCurrent: model.currentAccessMode)
    }

    private var accessModeMenu: some View {
        Menu {
            // 系统菜单项只能一行字,加不了小字说明;用分组标题顶上那一行,
            // 把「为什么还会弹卡」说在前面:只写问不问那一半,不带档位名。
            if let error = model.accessModeError {
                Section("暂不可用") { Text(error) }
            }
            if model.availableAccessModes.isEmpty {
                Text("没有可切换的权限。")
            } else {
                let modes = listedAccessModes
                if modes.isEmpty {
                    Text("没有可切换的权限。")
                } else {
                    if let status = currentStatusText {
                        Text(status)
                            .foregroundStyle(Self.inkSecondary)
                            .disabled(true)
                    }
                    Section {
                    ForEach(modes) { mode in
                        Button {
                            if mode.id == "bypassPermissions" || mode.id == "danger-full-access" || mode.id == "phone" {
                                confirmAccessMode = mode
                            } else {
                                Task { await selectAccessMode(mode) }
                            }
                        } label: {
                            let title = AccessModeWording.title(for: mode.id) ?? ""
                            if mode.id == model.currentAccessMode {
                                Label(title, systemImage: "checkmark")
                            } else {
                                Text(title)
                            }
                        }
                        .disabled(isSelectingAccessMode)
                    }
                    } header: {
                        // 系统菜单项只能一行,小字说明放不进项里;用分组标题说清「为什么还会弹卡」,
                        // 标题只写问不问那一半,档位名交给下面带勾的那行。
                        Text(AccessModeWording.title(for: model.currentAccessMode ?? "") == "完全权限"
                             ? "写之前不再问你" : "每次写之前会先问你")
                    }
                }
            }
        } label: {
            // 只留图标和字:图标 17、文字 13,热区高 32。
            // 宽度跟着字走,不预留:预留的空白会把这一格撑宽,
            // 和下一格之间就出现一段看不见的空隙(墨迹间距对不上)。
            HStack(spacing: 4) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 17))
                Text(accessModeTitle)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(ChatPage.inkSecondary)
            .padding(.horizontal, 5)
            .frame(height: 32)
        }
        .disabled(!model.canSend || model.turnRunning || model.pendingQuestion != nil || model.pendingPermission != nil || isSelectingAccessMode)
        .accessibilityLabel("权限：\(accessModeTitle)")
    }
    private var accessModeTitle: String {
        if let current = model.currentAccessMode,
           let title = AccessModeWording.title(for: current) {
            return title
        }
        return "权限"
    }

    private var accessModeConfirmationTitle: String {
        guard let mode = confirmAccessMode,
              let title = AccessModeWording.title(for: mode.id) else { return "切换权限？" }
        return "开启「\(title)」？"
    }

    @MainActor
    private func selectAccessMode(_ mode: NativeAccessMode) async {
        isSelectingAccessMode = true
        defer { isSelectingAccessMode = false }
        _ = await model.selectAccessMode(mode.id)
    }

    private var modelMenu: some View {
        Menu {
            if management.modelRoutes.isEmpty {
                Label("模型目录暂不可用", systemImage: "exclamationmark.circle")
            } else {
                // 这块菜单从输入框往上弹,系统把数组里的先后整个倒过来画:
                // 所以「强度」段写在前面、段内条目也倒着给,屏幕上才是
                // 上面「模型」、下面「强度」,每段里顺序正常。
                if let route = currentRoute, !route.reasoningEfforts.isEmpty {
                    Section("强度") {
                        ForEach(route.reasoningEfforts.reversed()) { effort in
                            Button {
                                Task { await management.selectModel(route, reasoningEffort: effort.id) }
                            } label: {
                                if management.currentModelSelection?.reasoningEffort == effort.id {
                                    Label(effortTitle(effort), systemImage: "checkmark")
                                } else {
                                    Text(effortTitle(effort))
                                }
                            }
                        }
                        Button {
                            Task { await management.selectModel(route, reasoningEffort: nil) }
                        } label: {
                            // 「默认强度」不是一档,是「按这个模型自己那档来」:
                            // 后面跟上它现在实际等于哪个档,点了才不会没底。
                            let defaultTitle = defaultEffortTitle(for: route)
                            if management.currentModelSelection?.reasoningEffort == nil {
                                Label(defaultTitle, systemImage: "checkmark")
                            } else {
                                Text(defaultTitle)
                            }
                        }
                    }
                }
                Section("模型") {
                    ForEach(listedModelRoutes.reversed()) { route in
                        Button {
                            Task { await management.selectModel(route, reasoningEffort: keptEffort(for: route)) }
                        } label: {
                            if management.currentModelSelection?.model == route.model {
                                Label(route.model, systemImage: "checkmark")
                            } else {
                                Text(route.model)
                            }
                        }
                    }
                }
            }
        } label: {
            // 这一行只放模型名,强度收进菜单里选:名字要一眼认得出,
            // 宁可少一个「Max」,也不能把模型名截成 deepseek-…。
            modelNameBlock
        }
        .disabled(!model.canSend || model.turnRunning || model.pendingQuestion != nil || model.pendingPermission != nil)
        .accessibilityLabel("选择模型")
    }

    private var modelControlTint: Color {
        model.canSend ? Color(red: 0x11/255, green: 0x11/255, blue: 0x14/255) : ChatPage.inkSecondary
    }

    private var modelNameBlock: some View {
        HStack(spacing: 4) {
            Image(systemName: "cpu")
                .font(.system(size: 17))
            Text(modelDisplayName)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(modelControlTint)
        .padding(.horizontal, 5)
        .frame(height: 32)
        .layoutPriority(1)
    }

    private func reasoningEffortBlock(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13))
            .lineLimit(1)
            .foregroundStyle(modelControlTint)
            .padding(.horizontal, 4)
            .frame(height: 32)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
    }

    /// 换模型时,如果新模型也支持现在这档强度,就保持不动;不支持就回到默认。
    private func keptEffort(for route: ManagedModelRoute) -> String? {
        guard let effort = management.currentModelSelection?.reasoningEffort,
              route.reasoningEfforts.contains(where: { $0.id == effort }) else { return nil }
        return effort
    }

    private var currentRoute: ManagedModelRoute? {
        guard let selection = management.currentModelSelection else { return nil }
        return management.modelRoutes.first {
            $0.provider == selection.provider && $0.model == selection.model
        }
    }

    /// 强度只上中文:宿主的英文名(Off / Low / High / Max)不上屏。
    private func effortTitle(_ effort: ManagedReasoningEffort) -> String {
        switch effort.id.lowercased() {
        case "off", "none", "disabled": return "关"
        case "low", "minimal": return "低"
        case "medium", "mid": return "中"
        case "high": return "高"
        case "max", "maximum", "xhigh": return "最高"
        default: return effort.name
        }
    }

    /// 「默认强度」后面补上它现在等价的档,例如「默认强度 · 高」。
    private func defaultEffortTitle(for route: ManagedModelRoute) -> String {
        guard let id = route.defaultEffort,
              let effort = route.reasoningEfforts.first(where: { $0.id == id }) else { return "默认强度" }
        return "默认强度 · \(effortTitle(effort))"
    }

    /// 模型菜单里一行一个模型,只写模型名:同一个模型被两个提供商报了也只出现一次。
    private var listedModelRoutes: [ManagedModelRoute] {
        var seen = Set<String>()
        return management.modelRoutes.filter { seen.insert($0.model).inserted }
    }

    private var modelDisplayName: String {
        if let selection = management.currentModelSelection { return selection.model }
        return model.modelName.isEmpty ? "模型" : model.modelName
    }

    private var reasoningEffortTitle: String? {
        guard let selection = management.currentModelSelection,
              let effortID = selection.reasoningEffort,
              let route = management.modelRoutes.first(where: {
                  $0.provider == selection.provider && $0.model == selection.model
              }),
              let effort = route.reasoningEfforts.first(where: { $0.id == effortID }) else {
            return nil
        }
        return effort.name
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 9) {
                ForEach(Array(pendingAttachments.enumerated()), id: \.offset) { index, attachment in
                    HStack(spacing: 5) {
                        Image(systemName: "photo")
                        Text(attachment.name).lineLimit(1)
                        Button { pendingAttachments.remove(at: index) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("移除图片 \(attachment.name)")
                    }
                    .font(.caption)
                    .padding(.leading, 10)
                    .padding(.trailing, 2)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var composerEnabled: Bool {
        guard model.pendingQuestion == nil, model.pendingPermission == nil, !isSelectingAccessMode else { return false }
        if model.turnRunning { return busyEnterMode == "steer" ? model.canSteer : model.canSend }
        return model.canSend
    }

    private var canSubmit: Bool {
        guard composerEnabled else { return false }
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if model.turnRunning && busyEnterMode == "steer" {
            return hasText && pendingAttachments.isEmpty
        }
        return model.turnRunning ? hasText : (hasText || !pendingAttachments.isEmpty)
    }

    private func submitDraft() {
        model.refreshModelProviderReadiness()
        guard canSubmit else { return }
        dismissComposerKeyboard()
        let text = draft
        if let command = Self.parseSlashCommand(text) {
            draft = ""
            Task { await runSlashCommand(name: command.name, input: command.input) }
            return
        }
        let wasRunning = model.turnRunning
        // 一按发送就清空:失败那条留在气泡里,重试原样再发,新打的字进新气泡。
        draft = ""
        Task {
            let succeeded: Bool
            if model.turnRunning && busyEnterMode == "steer" {
                succeeded = await model.steer(text)
            } else {
                succeeded = await model.send(text, attachments: pendingAttachments)
            }
            if succeeded {
                let id = model.items.last(where: { if case .user = $0.kind { return true }; return false })?.id
                if let id {
                    // `send` sets turnRunning for the turn it just started, so
                    // an ordinary idle send used to be labelled "已排队" for a
                    // moment. The label describes the queue the message joined,
                    // which only exists if a turn was already running.
                    if wasRunning && busyEnterMode == "steer" { model.markSteered(itemID: id) }
                    else if wasRunning { model.markQueued(itemID: id) }
                }
                pendingAttachments.removeAll()
                attachmentError = nil
                dismissComposerKeyboard()
                // One explicit jump shows the new turn; subsequent streaming
                // uses the bounded follow task until the user moves into history.
                nearBottom = true
                userScrolledAway = false
                scrollToLatestTrigger += 1
            } else if draft.isEmpty {
                // The send was refused before it produced a row (host not
                // ready, session switching, busy): keep the text so the person
                // can retry instead of losing the message.
                draft = text
            }
        }
    }

    private func dismissComposerKeyboard() {
        inputFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

    @MainActor
    private func executeCommand(_ descriptor: NativeCommandDescriptor, input: String,
                                attachments: [HarnessAttachment]) async {
        guard !isExecutingCommand else { return }
        isExecutingCommand = true
        defer { isExecutingCommand = false }
        if let result = await model.executeCommand(name: descriptor.name, input: input, attachments: attachments) {
            if result.kind == "success" { pendingAttachments.removeAll() }
            commandExecution = result
            showCommandResult = true
        }
    }

    private func openWorkspaceResult(_ path: String) {
        let normalized = Self.normalizedWorkspacePath(path)
        guard !normalized.isEmpty, !normalized.split(separator: "/").contains("..") else {
            attachmentError = "这个路径不能预览。"
            return
        }
        // A tool can write a file seconds before its bytes are materialized
        // here; the cached list is therefore a hint, not the authority. Refresh
        // and retry, then fall back to a unique basename match before saying
        // anything failed.
        if !model.files.contains(where: { $0.relativePath == normalized }) {
            model.refreshFiles()
        }
        // The tool result and the file list can disagree only in Unicode
        // normalization (a Chinese name written NFC, listed NFD); try the
        // canonical spelling before falling back to a unique basename.
        let canonical = normalized.precomposedStringWithCanonicalMapping
        if let match = model.files.first(where: { $0.relativePath == normalized })
            ?? model.files.first(where: { $0.relativePath.precomposedStringWithCanonicalMapping == canonical })
            ?? Self.uniqueBasenameMatch(normalized, in: model.files) {
            initialWorkbenchPath = match.relativePath
            showWorkbench = true
            return
        }
        // The write may still be in flight: keep the path and tell the person
        // to retry instead of claiming the file does not exist.
        pendingPreviewPath = normalized
        attachmentError = "文件还在写入或同步中，请稍后重试预览。"
    }

    /// Accepts the shapes a tool result or markdown link can produce:
    /// `/dsh/workspace/a.pdf`, `file:///…/a.pdf`, `sandbox:a.pdf`, `./a.pdf`.
    static func normalizedWorkspacePath(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["file://", "sandbox:"] where path.hasPrefix(prefix) {
            path = String(path.dropFirst(prefix.count))
        }
        if let decoded = path.removingPercentEncoding { path = decoded }
        if path.hasPrefix("/dsh/workspace/") {
            path = String(path.dropFirst("/dsh/workspace/".count))
        }
        if path.hasPrefix("./") { path = String(path.dropFirst(2)) }
        // A Chinese name can arrive decomposed (NFD) from a tool result while
        // the materialized tree lists it composed (NFC); compare in one form.
        path = path.precomposedStringWithCanonicalMapping
        return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func uniqueBasenameMatch(_ path: String, in files: [WorkspaceFile]) -> WorkspaceFile? {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let wanted = name.precomposedStringWithCanonicalMapping
        let matches = files.filter { file in
            let candidate = file.relativePath.split(separator: "/").last.map(String.init) ?? file.relativePath
            return candidate.precomposedStringWithCanonicalMapping == wanted
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private var composerPlaceholder: String {
        if let issue = model.modelProviderIssue { return issue }
        if !model.turnRunning { return "发消息" }
        return busyEnterMode == "steer" ? "补充当前任务…" : "排入下一轮…"
    }

    private var sendButtonLabel: String {
        guard model.turnRunning else { return "发送消息" }
        return busyEnterMode == "steer" ? "补充当前任务" : "排入下一轮"
    }

    private static var imageContentTypes: [UTType] {
        [.png, .jpeg, .gif] + [UTType(filenameExtension: "webp")].compactMap { $0 }
    }

    private func loadAttachments(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            attachmentError = "无法读取所选图片：\(error.localizedDescription)"
        case .success(let urls):
            guard !urls.isEmpty else { return }
            let existingCount = pendingAttachments.count
            let existingBytes = pendingAttachments.reduce(0) { $0 + $1.data.count }
            Task {
                do {
                    let attachments = try await Task.detached(priority: .userInitiated) {
                        guard existingCount + urls.count <= 20 else { throw AttachmentImportError.tooMany }
                        var totalBytes = existingBytes
                        for url in urls {
                            let hasScope = url.startAccessingSecurityScopedResource()
                            defer { if hasScope { url.stopAccessingSecurityScopedResource() } }
                            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
                            guard size <= 20 * 1024 * 1024 else {
                                throw AttachmentImportError.tooLarge(url.lastPathComponent)
                            }
                            totalBytes += size
                        }
                        guard totalBytes <= 200 * 1024 * 1024 else { throw AttachmentImportError.totalTooLarge }
                        return try urls.map { url -> HarnessAttachment in
                            let hasScope = url.startAccessingSecurityScopedResource()
                            defer { if hasScope { url.stopAccessingSecurityScopedResource() } }
                            let ext = url.pathExtension.lowercased()
                            let mimeTypes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
                                             "gif": "image/gif", "webp": "image/webp"]
                            guard let mimeType = mimeTypes[ext],
                                  let type = UTType(filenameExtension: ext), type.conforms(to: .image) else {
                                throw AttachmentImportError.unsupportedType(url.lastPathComponent)
                            }
                            let data = try Data(contentsOf: url, options: .mappedIfSafe)
                            return HarnessAttachment(name: url.lastPathComponent, mimeType: mimeType, data: data)
                        }
                    }.value
                    pendingAttachments.append(contentsOf: attachments)
                    attachmentError = nil
                } catch {
                    attachmentError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Slash commands (the DSH input trigger)

    /// The draft's leading `/token` while it is still a bare token. This is
    /// the DSH `ui-input-trigger` shape: the menu opens for a leading trigger
    /// and closes once the token is followed by whitespace.
    private var slashToken: String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"),
              !trimmed.dropFirst().contains(where: { $0.isWhitespace }) else { return nil }
        return String(trimmed.dropFirst())
    }

    private var slashMatches: [NativeCommandDescriptor] {
        guard let token = slashToken else { return [] }
        let commands = model.availableCommands
        guard !token.isEmpty else { return Array(commands.prefix(6)) }
        return commands.filter { descriptor in
            descriptor.name.localizedCaseInsensitiveContains(token)
                || descriptor.description.localizedCaseInsensitiveContains(token)
        }.prefix(6).map { $0 }
    }

    /// The in-place command menu: names and hints are the live DSH catalog.
    @ViewBuilder
    private var slashCommandMenu: some View {
        let matches = slashMatches
        VStack(alignment: .leading, spacing: 0) {
            if model.commandsLoading && model.availableCommands.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("正在读取 DSH 命令…").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .padding(12)
            } else if let error = model.commandsError, model.availableCommands.isEmpty {
                HStack(spacing: 8) {
                    Text(error).font(.system(size: 13)).foregroundStyle(.orange)
                    Spacer(minLength: 0)
                    Button("重试") { Task { await model.loadCommands() } }
                        .font(.system(size: 13))
                }
                .padding(12)
            } else if matches.isEmpty {
                Text("没有匹配的命令").font(.system(size: 13))
                    .foregroundStyle(.secondary).padding(12)
            } else {
                ForEach(matches) { descriptor in
                    Button { pickCommand(descriptor) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("/\(descriptor.name)")
                                .font(.system(size: 15, weight: .semibold))
                            Text(descriptor.description)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0xF2 / 255, green: 0xF3 / 255, blue: 0xF5 / 255),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func pickCommand(_ descriptor: NativeCommandDescriptor) {
        draft = "/\(descriptor.name) "
        inputFocused = true
    }

    static func parseSlashCommand(_ text: String) -> (name: String, input: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst()
        let name = body.prefix { !$0.isWhitespace }
        guard !name.isEmpty else { return nil }
        let input = body.dropFirst(name.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(name), input)
    }

    private func runSlashCommand(name: String, input: String) async {
        guard let descriptor = model.availableCommands.first(where: { $0.name == name }) else {
            attachmentError = "没有这条命令：/\(name)"
            if draft.isEmpty { draft = "/\(name)" + (input.isEmpty ? "" : " \(input)") }
            return
        }
        await executeCommand(descriptor, input: input, attachments: pendingAttachments)
    }

    // MARK: - Workspace file import (DSH file attachments)

    /// Imports the picked files into the session workspace through the
    /// Worker's `phone/import*` service (the phone DSH path for a verbatim
    /// file: the prompt API accepts images only, budget §A.5's analogue is the
    /// workspace), then inserts their path so the agent can read them.
    private func loadWorkspaceFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            attachmentError = "无法读取所选文件：\(error.localizedDescription)"
        case .success(let urls):
            guard !urls.isEmpty else { return }
            guard let sessionID = model.currentSessionID else {
                attachmentError = "本地引擎还没启动，启动之后才能把文件放进工作区。"
                return
            }
            Task { await importIntoWorkspace(urls, sessionID: sessionID) }
        }
    }

    private func importIntoWorkspace(_ urls: [URL], sessionID: String) async {
        // The Worker's directory-import contract: 64 MiB per file, 128 MiB and
        // 500 files per import (plugins/phone-directory-import).
        let maxFileBytes = 64 * 1024 * 1024
        let maxTotalBytes = 128 * 1024 * 1024
        let chunkBytes = 1024 * 1024
        do {
            var files: [WebEngineDirectoryImportFile] = []
            var payloads: [(path: String, data: Data)] = []
            var total = 0
            for url in urls {
                let hasScope = url.startAccessingSecurityScopedResource()
                defer { if hasScope { url.stopAccessingSecurityScopedResource() } }
                let name = url.lastPathComponent
                guard !name.isEmpty, !name.contains("/") else {
                    throw AttachmentImportError.unsupportedType(name)
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
                    as? NSNumber)?.intValue ?? 0
                guard size > 0, size <= maxFileBytes else {
                    throw ImportFailure.tooLarge(name, size)
                }
                total += size
                guard total <= maxTotalBytes else { throw ImportFailure.totalTooLarge }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                files.append(WebEngineDirectoryImportFile(path: name, size: data.count))
                payloads.append((path: name, data: data))
            }
            let stamp = Self.importTimestamp()
            let manifest = WebEngineDirectoryImportManifest(
                sessionID: sessionID,
                targetDirectory: "/dsh/workspace",
                entryName: "files-\(stamp)",
                directories: [],
                files: files,
                totalBytes: total)
            let transport = try await model.transportForManagement()
            let sink = PhoneDSHWorkspaceImportSink(transport: transport)
            let importID = try await sink.begin(manifest)
            for payload in payloads {
                var offset = 0
                while offset < payload.data.count {
                    let end = min(offset + chunkBytes, payload.data.count)
                    try await sink.write(importID: importID, path: payload.path,
                                         offset: offset,
                                         data: payload.data.subdata(in: offset..<end))
                    offset = end
                }
            }
            let result = try await sink.commit(importID: importID)
            let reference = files.count == 1
                ? "\(result.workspacePath)/\(files[0].path)"
                : "\(result.workspacePath)/"
            fileImportNotice = "已写入工作区：\(reference)"
            let separator = draft.isEmpty ? "" : "\n"
            draft += "\(separator)\(reference)\n"
            inputFocused = true
        } catch {
            attachmentError = "导入失败：\(error.localizedDescription)"
        }
    }

    private static func importTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private enum ImportFailure: LocalizedError {
        case tooLarge(String, Int)
        case totalTooLarge

        var errorDescription: String? {
            switch self {
            case .tooLarge(let name, let size):
                return "\(name) 超过 64 MiB（\(size) 字节）。"
            case .totalTooLarge:
                return "一次最多导入 128 MiB。"
            }
        }
    }

    private var historyExport: String {
        let lines = model.items.compactMap { item -> String? in
            guard item.kind != .status else { return nil }
            return "### \(exportTitle(item))\n\n\(item.text)"
        }
        var document = ["# \(sessionTitle)"]
        document.append(contentsOf: lines)
        return document.joined(separator: "\n\n")
    }

    private func exportTitle(_ item: ChatItem) -> String {
        switch item.title {
        case "You": "你"
        case "You (steering)": "你（补充说明）"
        case "Assistant": "DSH"
        case let title where title.hasPrefix("DSH context · "):
            NativeSourceName.chinese(title.replacingOccurrences(of: "DSH context · ", with: ""))
                .map { "上下文注入 · \($0)" } ?? "上下文注入"
        case "Tool result": "工具结果"
        case "Tool error": "工具错误"
        default:
            item.title.hasPrefix("Tool call: ")
                ? "工具调用 · " + item.title.replacingOccurrences(of: "Tool call: ", with: "")
                : item.title
        }
    }

    private func savedDraft(for key: String) -> String {
        guard let data = savedDrafts.data(using: .utf8),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return "" }
        return values[key] ?? ""
    }

    private func persistDraft(_ value: String, for key: String) {
        guard !key.isEmpty else { return }
        var values = (try? JSONDecoder().decode([String: String].self, from: Data(savedDrafts.utf8))) ?? [:]
        values[key] = value
        if let data = try? JSONEncoder().encode(values), let string = String(data: data, encoding: .utf8) {
            savedDrafts = string
        }
    }
}

private enum AttachmentImportError: LocalizedError {
    case unsupportedType(String)
    case tooLarge(String)
    case tooMany
    case totalTooLarge
    var errorDescription: String? {
        switch self {
        case .unsupportedType(let name): return "不支持的图片格式：\(name)。请选 PNG、JPEG、GIF 或 WebP。"
        case .tooLarge(let name): return "图片过大：\(name) 超过单张 20 MB 的上限。"
        case .tooMany: return "一次最多添加 20 张图片。"
        case .totalTooLarge: return "所选图片合计超过 200 MB，请分批发送。"
        }
    }
}

private struct TranscriptTailPreference: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Full transcript height, so a "scroll to the tail" is skipped when the
/// content already fits the viewport: a bottom-anchored scroll on a shorter
/// transcript overshoots into empty space and reads as a blank page.
private struct TranscriptContentHeightPreference: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct QuestionCard: View {
    let question: HarnessQuestion
    let submit: (String) -> Void

    @State private var singleSelections: [String: String] = [:]
    @State private var multipleSelections: [String: Set<String>] = [:]
    @State private var customAnswers: [String: String] = [:]

    private var questions: [HarnessQuestionItem] {
        if let questions = question.questions, !questions.isEmpty { return questions }
        return [HarnessQuestionItem(id: "answer", prompt: question.prompt, options: question.options)]
    }

    private var canSubmit: Bool {
        questions.allSatisfy { item in
            let custom = customAnswers[item.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if item.multiple {
                return !(multipleSelections[item.id, default: []].isEmpty && custom.isEmpty)
            }
            return singleSelections[item.id] != nil || !custom.isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    questionHeading
                    Spacer(minLength: 0)
                    submitButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    questionHeading
                    submitButton
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let items = question.questions, !items.isEmpty, !question.prompt.isEmpty {
                        Text(question.prompt).font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(questions) { item in
                        questionControl(item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.09))
    }

    private var questionHeading: some View {
        Label("需要你的回答", systemImage: "questionmark.circle.fill")
            .font(.headline)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var submitButton: some View {
        Button("提交回答", systemImage: "arrow.up") { submitAnswers() }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(!canSubmit)
    }

    @ViewBuilder
    private func questionControl(_ item: HarnessQuestionItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.prompt).font(.subheadline.weight(.semibold))
            ForEach(item.options, id: \.self) { option in
                let selected = item.multiple
                    ? multipleSelections[item.id, default: []].contains(option)
                    : singleSelections[item.id] == option
                Button {
                    if item.multiple {
                        if selected { multipleSelections[item.id, default: []].remove(option) }
                        else { multipleSelections[item.id, default: []].insert(option) }
                    } else {
                        singleSelections[item.id] = option
                        customAnswers[item.id] = ""
                    }
                } label: {
                Label(option, systemImage: selected
                          ? (item.multiple ? "checkmark.square.fill" : "largecircle.fill.circle")
                          : (item.multiple ? "square" : "circle"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .frame(minHeight: 44, alignment: .leading)
            }
            TextField(item.options.isEmpty ? "输入回答" : "其他回答", text: binding(for: item.id))
                .textFieldStyle(.roundedBorder)
                .onChange(of: customAnswers[item.id, default: ""]) { _, value in
                    if !value.isEmpty && !item.multiple { singleSelections[item.id] = nil }
                }
            if item.multiple {
                Text("可多选，也可以补充自定义回答。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func binding(for id: String) -> Binding<String> {
        Binding(get: { customAnswers[id, default: ""] }, set: { customAnswers[id] = $0 })
    }

    private func submitAnswers() {
        var values: [String: Any] = [:]
        for item in questions {
            let custom = customAnswers[item.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if item.multiple {
                var selected = item.options.filter { multipleSelections[item.id, default: []].contains($0) }
                if !custom.isEmpty { selected.append(custom) }
                values[item.id] = selected
            } else {
                values[item.id] = singleSelections[item.id] ?? (custom.isEmpty ? "" : custom)
            }
        }
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let answer = String(data: data, encoding: .utf8) else { return }
        submit(answer)
    }
}

/// The model's streamed reasoning, following the DSH web ReasoningRow:
/// a 24pt disclosure row with the official Think icon (the DSH artwork),
/// the title, and one collapsed summary line that keeps refreshing while the
/// model thinks. Tapping opens the complete reasoning Markdown.
private struct ThinkingBlock: View {
    let text: String
    let streaming: Bool
    @State private var expanded = false

    /// DSH's collapsed summary: the first line when settled; while running,
    /// the first line of the latest COMPLETED paragraph (the growing last
    /// paragraph is skipped so the line does not jitter).
    private var summary: String {
        let raw: String
        if streaming {
            raw = Self.latestCompletedParagraphFirstLine(text)
        } else {
            raw = text.components(separatedBy: "\n").first ?? ""
        }
        return raw.replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func latestCompletedParagraphFirstLine(_ text: String) -> String {
        var currentFirst: String?
        var lastCompleted: String?
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if let first = currentFirst { lastCompleted = first }
                currentFirst = nil
            } else if currentFirst == nil {
                currentFirst = line
            }
        }
        return lastCompleted ?? currentFirst ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(expanded ? "DSHChevronUp" : "DSHThink")
                        .resizable()
                        .renderingMode(.template)
                        .frame(width: 14, height: 14)
                    Text("思考")
                        .font(.system(size: 13))
                    if !expanded, !summary.isEmpty {
                        Rectangle()
                            .fill(ChatPage.inkSecondary.opacity(0.35))
                            .frame(width: 12, height: 1)
                        ShimmerText(text: summary, active: streaming)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(ChatPage.inkSecondary)
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                NativeMarkdownBody(markdown: text.isEmpty ? "…" : text)
                    .font(.system(size: 15))
                    .foregroundStyle(ChatPage.inkSecondary)
                    .padding(.leading, 22)
            }
        }
    }
}

private struct ChatMessageRow: View {
    let item: ChatItem
    var workspaceFiles: [WorkspaceFile]
    var onOpenFile: (String) -> Void

    var body: some View {
        switch item.kind {
        case .toolCall, .toolResult:
            ToolEventCard(item: item, expanded: false, workspaceFiles: workspaceFiles, onOpenFile: onOpenFile)
        case .context:
            ContextInjectionCard(item: item)
        case .user:
            // 用户消息才用底色块:靠右、宽跟字走、上限 296;不再有「你」那层。
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 16)
                userBubble
            }
        case .assistant:
            // 助手正文不套气泡,直接排在版心上。
            assistantBody
                .contextMenu {
                    if !item.text.isEmpty {
                        Button("复制全文", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = item.text
                        }
                    }
                }
        case .reasoning:
            // The model's thinking: muted, collapsible, and never part of the
            // answer. It starts expanded while streaming, collapses when the
            // step's answer arrives.
            ThinkingBlock(text: item.text, streaming: item.streaming)
        case .status:
            EmptyView()
        }
    }

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if item.streaming { ProgressView().controlSize(.mini) }
            NativeMarkdownBody(markdown: item.text.isEmpty ? "…" : item.text)
                .font(.system(size: 17))
                .environment(\.openURL, OpenURLAction { url in
                    guard let path = workspaceRelativePath(from: url) else { return .systemAction }
                    onOpenFile(path)
                    return .handled
                })
            WorkspaceOutputReferences(text: item.text, files: workspaceFiles, onOpenFile: onOpenFile)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 贴字优先:能一行放下就用自然宽度,放不下才在 296 内换行。
    private var userBubble: some View {
        let body = Text(item.text.isEmpty ? "…" : item.text)
            .font(.system(size: 17))
            .lineSpacing(24 - 21)
            .textSelection(.enabled)
        return ViewThatFits(in: .horizontal) {
            body.fixedSize(horizontal: true, vertical: true)
            body
        }
        .padding(12)
        .background(Color(red: 232 / 255, green: 233 / 255, blue: 237 / 255),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .frame(maxWidth: 296, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func messageCard(tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Text(displayTitle).font(.caption.weight(.semibold))
                if item.streaming { ProgressView().controlSize(.mini) }
            }
            .foregroundStyle(.secondary)
            if item.kind == .assistant {
                NativeMarkdownBody(markdown: item.text.isEmpty ? "…" : item.text)
                    .padding(-16)
                    .environment(\.openURL, OpenURLAction { url in
                        guard let path = workspaceRelativePath(from: url) else { return .systemAction }
                        onOpenFile(path)
                        return .handled
                    })
            } else {
                Text(item.text.isEmpty ? "…" : item.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(tint)
            }
            WorkspaceOutputReferences(text: item.text, files: workspaceFiles, onOpenFile: onOpenFile)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button("复制", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = item.text
            }
        }
    }

    private var displayTitle: String {
        switch item.title {
        case "You": return "你"
        case "You (steering)": return "你 · 补充说明"
        case "Assistant": return "DSH"
        case let title where title.hasPrefix("DSH context · "):
            return NativeSourceName.chinese(title.replacingOccurrences(of: "DSH context · ", with: ""))
                .map { "上下文注入 · \($0)" } ?? "上下文注入"
        case "Tool result": return "工具结果"
        case "Tool error": return "工具错误"
        default:
            if item.title.hasPrefix("Tool call: ") {
                return "工具调用 · " + item.title.replacingOccurrences(of: "Tool call: ", with: "")
            }
            return item.title
        }
    }
}

/// One run of tool activity folded into a single row: the collapsed label
/// reports the count and failures, and the individual lines are one tap away.
private func toolFirstLine(_ text: String) -> String {
    text.components(separatedBy: .newlines).first ?? text
}

/// The title a tool item shows when nothing more specific is available.
private func toolDisplayTitle(_ item: ChatItem) -> String {
    if case .toolCall = item.kind {
        let name = item.title.replacingOccurrences(of: "Tool call: ", with: "")
        return ToolWording.category(forToolName: name).rowTitle
    }
    switch item.title {
    case "Tool error": return "工具错误"
    case "Tool result": return "工具结果"
    default:
        if item.title.hasPrefix("Tool call: ") {
            return "工具调用 · " + item.title.replacingOccurrences(of: "Tool call: ", with: "")
        }
        return item.title
    }
}

/// One line「动作 · 参数」for a tool row; the verb comes from the call text and
/// never says the generic「调用工具」.
private func toolActionLine(_ item: ChatItem) -> String {
    let raw = toolFirstLine(item.text).trimmingCharacters(in: .whitespaces)
    guard case .toolCall = item.kind, !raw.isEmpty else { return toolDisplayTitle(item) }
    let parts = raw.components(separatedBy: " · ")
    let rest = parts.dropFirst().joined(separator: " · ").trimmingCharacters(in: .whitespaces)
    let verb = parts.first?.lowercased() ?? ""
    let action: String
    switch true {
    case ["read", "read_file", "filesystem_read"].contains(verb): action = "读取文件"
    case ["write", "write_file", "edit", "apply_patch"].contains(verb): action = "改文件"
    case ["bash", "shell", "exec"].contains(verb): action = "运行命令"
    case ["grep", "glob", "find", "search"].contains(verb): action = "搜索"
    default: action = toolDisplayTitle(item)
    }
    var parameter = rest.isEmpty ? raw : rest
    if ["读取文件", "改文件"].contains(action) {
        parameter = parameter.components(separatedBy: "/").last ?? parameter
    }
    // A command's preview is its first line, not the first whitespace token:
    // '运行命令 · cd' hid what the command actually did.
    parameter = parameter.trimmingCharacters(in: .whitespacesAndNewlines)
    if parameter.isEmpty { parameter = raw }
    if parameter.count > 48 { parameter = String(parameter.prefix(48)) + "…" }
    return "\(action) · \(parameter)"
}

private struct ToolRunRow: View {
    let items: [ChatItem]
    var workspaceFiles: [WorkspaceFile] = []
    var onOpenFile: (String) -> Void = { _ in }
    @State private var expanded = false
    @State private var selected = 0

    /// DSH's process row: one fixed line per run. A single tool call opens its
    /// detail directly; several consecutive calls share one line whose preview
    /// switches with the chevrons, and the line first opens the list.
    var body: some View {
        if items.count == 1, let only = items.first {
            ToolEventCard(item: only, workspaceFiles: workspaceFiles, onOpenFile: onOpenFile)
        } else {
            multiple
        }
    }

    private var multiple: some View {
        let index = min(max(selected, 0), max(items.count - 1, 0))
        let item = items[index]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal")
                            .font(.system(size: 13))
                            .foregroundStyle(ChatPage.inkSecondary)
                            .layoutPriority(1)
                        Text(toolActionLine(item))
                            .font(.system(size: 13))
                            .foregroundStyle(ChatPage.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(2)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    selected = (index - 1 + items.count) % items.count
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ChatPage.inkSecondary)
                        .frame(width: 20, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("上一条命令")
                Button {
                    selected = (index + 1) % items.count
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ChatPage.inkSecondary)
                        .frame(width: 20, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("下一条命令")
                Button {
                    expanded.toggle()
                } label: {
                    Image("DSHChevronDown")
                        .resizable()
                        .renderingMode(.template)
                        .frame(width: 12, height: 12)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .foregroundStyle(ChatPage.inkSecondary)
                        .frame(width: 20, height: 28)
                }
                .buttonStyle(.plain)
            }
            .frame(height: 33)
            Rectangle()
                .fill(ChatPage.inkSecondary.opacity(0.18))
                .frame(height: 0.5)
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items) { item in
                        ToolEventCard(item: item, workspaceFiles: workspaceFiles, onOpenFile: onOpenFile)
                    }
                }
                .padding(.top, 6)
            }
        }
    }
}

private struct ToolEventCard: View {
    let item: ChatItem
    var workspaceFiles: [WorkspaceFile] = []
    var onOpenFile: (String) -> Void = { _ in }
    @State private var expanded: Bool

    init(item: ChatItem, expanded: Bool = false, workspaceFiles: [WorkspaceFile] = [], onOpenFile: @escaping (String) -> Void = { _ in }) {
        self.item = item
        self.workspaceFiles = workspaceFiles
        self.onOpenFile = onOpenFile
        _expanded = State(initialValue: expanded)
    }

    private var isError: Bool {
        if case .toolResult(let isError) = item.kind { return isError }
        return false
    }

    /// 一行「动作 · 参数」,动作是动词加对象,不写「调用工具」这种笼统词。
    private var actionLine: String { toolActionLine(item) }

    /// 有没有可展开的详情:有内容才给箭头。
    private var hasDetails: Bool {
        !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            DSHJsonBlock(text: item.text)
            if case .toolResult = item.kind {
                WorkspaceOutputReferences(text: item.text, files: workspaceFiles, onOpenFile: onOpenFile)
            }
        } label: {
            // 工具行是过程,不是内容:一行 28,图标 14 单色次要墨,文字 13,
            // 不加底色、边框、圆角;右边只在能点开时给一个小箭头。
            HStack(spacing: 9) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "terminal")
                    .font(.system(size: 14))
                    .foregroundStyle(isError ? Color(red: 0xC0/255, green: 0x39/255, blue: 0x2B/255)
                                             : Color(red: 154/255, green: 154/255, blue: 162/255))
                Text(actionLine)
                    .font(.system(size: 13))
                    .foregroundStyle(isError ? Color(red: 0xC0/255, green: 0x39/255, blue: 0x2B/255) : ChatPage.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if item.streaming {
                    ProgressView().controlSize(.mini).scaleEffect(0.8)
                } else if case .toolResult = item.kind {
                    // The DSH web tool row ends in the same status glyph.
                    Image(isError ? "DSHClose" : "DSHCheck")
                        .resizable()
                        .renderingMode(.template)
                        .frame(width: 12, height: 12)
                        .foregroundStyle(isError
                            ? Color(red: 0xC0/255, green: 0x39/255, blue: 0x2B/255)
                            : Color(red: 154/255, green: 154/255, blue: 162/255))
                }
                if hasDetails {
                    Image("DSHChevronDown")
                        .resizable()
                        .renderingMode(.template)
                        .frame(width: 12, height: 12)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .foregroundStyle(Color(red: 154/255, green: 154/255, blue: 162/255))
                }
            }
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        // 系统展开箭头会占住右侧一条;换成自己的箭头,位置才归版心管。
        .disclosureGroupStyle(FlatDisclosureStyle())
        .contextMenu {
            Button("复制详情", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.text }
        }
    }

    private func firstLine(_ text: String) -> String { text.components(separatedBy: .newlines).first ?? text }

    private var displayTitle: String {
        if case .toolCall = item.kind {
            let name = item.title.replacingOccurrences(of: "Tool call: ", with: "")
            return ToolWording.category(forToolName: name).rowTitle
        }
        switch item.title {
        case "Tool error": return "工具错误"
        case "Tool result": return "工具结果"
        default:
            if item.title.hasPrefix("Tool call: ") {
                return "工具调用 · " + item.title.replacingOccurrences(of: "Tool call: ", with: "")
            }
            return item.title
        }
    }
}

private struct ContextInjectionCard: View {
    let item: ChatItem
    @State private var expanded = false

    private var sourceName: String {
        item.title.replacingOccurrences(of: "DSH context · ", with: "")
    }

    private var summary: String {
        let firstLine = item.text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "DSH 为本轮注入的上下文"
        return String(firstLine.prefix(180))
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView([.horizontal, .vertical]) {
                Text(item.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 360)
        } label: {
            // 上下文行同工具行:一行提示,不加底色卡片;箭头表示能点开。
            HStack(spacing: 9) {
                Image(systemName: "info.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(red: 154 / 255, green: 154 / 255, blue: 162 / 255))
                Text("上下文注入 · \(sourceName)")
                    .font(.system(size: 13))
                    .foregroundStyle(ChatPage.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 154 / 255, green: 154 / 255, blue: 162 / 255))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .disclosureGroupStyle(FlatDisclosureStyle())
    }
}

private struct TraceStatusRow: View {
    let item: ChatItem

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "circle.inset.filled")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title == "Host" ? "主机事件" : item.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(item.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

private struct MarkdownContent: View {
    let text: String
    var onOpenFile: (String) -> Void = { _ in }

    private enum Block {
        case markdown(String)
        case code(String)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var markdown = ""
        var code: String?
        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let current = code {
                    result.append(.code(current))
                    code = nil
                } else {
                    if !markdown.isEmpty { result.append(.markdown(markdown)); markdown = "" }
                    code = ""
                }
                continue
            }
            if code != nil { code!.append(line + "\n") }
            else { markdown.append(line + "\n") }
        }
        if let code { result.append(.code(code)) }
        if !markdown.isEmpty { result.append(.markdown(markdown)) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .markdown(let source):
                    if let attributed = try? AttributedString(markdown: source) {
                        Text(attributed)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .environment(\.openURL, OpenURLAction { url in
                                guard let path = workspaceRelativePath(from: url) else { return .systemAction }
                                onOpenFile(path)
                                return .handled
                            })
                    } else {
                        Text(source).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .code(let source):
                    DSSCodeBlock(source: source)
                }
            }
        }
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 图标和文字之间固定 6。
private struct IconTextGap: LabelStyle {
    let gap: CGFloat
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: gap) {
            configuration.icon
            configuration.title
        }
    }
}

/// 不占右侧空间的展开样式:内容自己带箭头,系统不再留一条指示位。
private struct FlatDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.16)) { configuration.isExpanded.toggle() } }
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

private struct WorkspaceOutputReferences: View {
    let text: String
    let files: [WorkspaceFile]
    let onOpenFile: (String) -> Void

    private var referencedFiles: [WorkspaceFile] {
        files.filter { text.localizedStandardContains($0.relativePath) }.prefix(6).map { $0 }
    }

    var body: some View {
        if !referencedFiles.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(referencedFiles) { file in
                    Button {
                        onOpenFile(file.relativePath)
                    } label: {
                        HStack(spacing: 8) {
                            FileTypeGlyph.icon(for: file.relativePath, size: 18)
                            Text("预览 \(file.relativePath)")
                                .font(.footnote)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("在当前 DSH 工作区中打开此文件的预览")
                }
            }
            .padding(.top, 4)
        }
    }
}

private func workspaceRelativePath(from url: URL) -> String? {
    let scheme = url.scheme?.lowercased()
    var path: String
    switch scheme {
    case nil, "file", "sandbox":
        guard url.host == nil || url.host?.isEmpty == true else { return nil }
        path = url.path.removingPercentEncoding ?? url.path
    case "dsh-resource":
        // DSH's own file address — `dsh-resource://file/session/<id>/<path>`
        // (workspace-relative, or absolute with the leading `/` dropped) and
        // `dsh-resource://file/absolute/<path>`. The web surface accepts
        // these; a native message that quotes one used to fall through to the
        // system as an unopenable URL, which read as "the file is missing".
        guard url.host?.lowercased() == "file" else { return nil }
        let segments = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let scope = segments.first else { return nil }
        let tail: [String]
        switch scope {
        case "session" where segments.count >= 3: tail = Array(segments.dropFirst(2))
        case "absolute" where segments.count >= 2: tail = Array(segments.dropFirst())
        default: return nil
        }
        var joined = tail.joined(separator: "/")
        if joined == "dsh/workspace" { return nil }
        if joined.hasPrefix("dsh/workspace/") {
            joined = String(joined.dropFirst("dsh/workspace/".count))
        } else if joined.hasPrefix("dsh/") {
            return nil
        }
        path = joined
    default:
        return nil
    }
    if path.hasPrefix("/dsh/workspace/") {
        path = String(path.dropFirst("/dsh/workspace/".count))
    } else if path.hasPrefix("dsh/workspace/") {
        path = String(path.dropFirst("dsh/workspace/".count))
    } else if path == "/dsh/workspace" || path == "dsh/workspace" {
        return nil
    } else if path.hasPrefix("/") {
        return nil
    }
    path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let components = path.split(separator: "/")
    guard !components.isEmpty, !components.contains("."), !components.contains("..") else { return nil }
    return components.joined(separator: "/").precomposedStringWithCanonicalMapping
}

struct RuntimeDetailsPage: View {
    @Bindable var model: ChatModel

    @State private var confirmingStop = false

    /// 一行:左 16 起,值右缘 370,行高 44。
    private func runtimeRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 17))
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 15))
                .foregroundStyle(ChatPage.inkSecondary)
                .monospacedDigit()
        }
        .frame(minHeight: 44)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowSeparator(.hidden)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ChatPage.hairline)
                .frame(height: 1 / UIScreen.main.scale)
        }
    }

    /// 组标题和设置里同一套:13 号 #66666B、左 16、上 24 下 8。
    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(ChatPage.inkSecondary)
            .textCase(nil)
            .listRowInsets(EdgeInsets(top: 24, leading: 16, bottom: 8, trailing: 16))
    }

    /// 状态词 + 已运行多久,两个都在第一行。
    private var statusValue: String {
        guard let startedAt = model.startedAt, model.isStarted else { return model.displayStatus }
        let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        let elapsed: String
        if seconds < 60 {
            elapsed = "不到 1 分钟"
        } else if seconds < 3600 {
            elapsed = "\(seconds / 60) 分钟"
        } else {
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            elapsed = minutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(minutes) 分钟"
        }
        return "\(model.displayStatus) · 已运行\(elapsed)"
    }

    private var hasCounts: Bool {
        model.modelRequests > 0 || model.inputTokens > 0 || model.outputTokens > 0
    }

    var body: some View {
        List {
            if !model.isStarted {
                // 停完留在这一页:顶上写「已停止」,下面就是重新启动的按钮。
                runtimeRow("状态", "已停止")
            } else {
                runtimeRow("状态", statusValue)
            }

            if hasCounts {
                Section {
                    runtimeRow("模型调用", "\(model.modelRequests)")
                    runtimeRow("输入 Token", model.inputTokens.formatted())
                    runtimeRow("输出 Token", model.outputTokens.formatted())
                } header: {
                    groupHeader("本次运行")
                }
            }

            Section {
                // 组标题已经说了「最近出错」,行里不再重复一个同名标签,只放那句话。
                Text(model.userFacingError ?? "最近没有出错")
                    .font(.system(size: 17))
                    .foregroundStyle(model.userFacingError == nil ? ChatPage.inkSecondary : ChatPage.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 44)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
            } header: {
                groupHeader("最近出错")
            }

            Section {
                if model.isStarted {
                    Button("停止本地引擎") { confirmingStop = true }
                        .font(.system(size: 17))
                        .foregroundStyle(ChatPage.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                } else {
                    Button("启动本地引擎") { Task { await model.start() } }
                        .font(.system(size: 17))
                        .foregroundStyle(ChatPage.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                }
            } footer: {
                Text("停止后,正在跑的任务会停下来,不会再接着做。")
                    .font(.system(size: 13))
                    .foregroundStyle(ChatPage.inkSecondary)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.white)
        .environment(\.defaultMinListRowHeight, 44)
        .navigationTitle("运行状态")
        .navigationBarTitleDisplayMode(.large)
        .tint(ChatPage.accent)
        .confirmationDialog("停止本地引擎?", isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("取消", role: .cancel) {}
            Button("停止", role: .destructive) { Task { await model.stop() } }
        } message: {
            Text("正在跑的任务会停下来。会话和文件都还在。")
        }
    }
}

private struct CommandExecutionResultPage: View {
    let execution: NativeCommandExecution
    let onOpenFile: (String) -> Void
    @State private var model = ChatModel.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label(execution.kind == "success" ? "命令已完成" : "命令执行失败",
                          systemImage: execution.kind == "success" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(execution.kind == "success" ? Color.primary : Color.red)
                    Text(execution.line)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    if let text = execution.text, !text.isEmpty {
                        MarkdownContent(text: text, onOpenFile: onOpenFile)
                        WorkspaceOutputReferences(text: text, files: model.files, onOpenFile: onOpenFile)
                    } else {
                        Text("这次没有更多输出。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(18)
            }
            .navigationTitle("命令结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() }.trailingBarText() }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: execution.text ?? execution.line,
                              subject: Text("命令结果"),
                              preview: SharePreview("/\(execution.name)")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("分享命令结果")
                }
            }
        }
    }
}

private struct NativeTrajectoryRow: View {
    let entry: NativeTrajectoryEntry
    let onOpenFile: (String) -> Void
    @State private var expanded = false

    private var payloadText: String {
        guard let data = try? entry.payload.encoded() else { return "无法格式化此事件的原始数据。" }
        return String(data: data, encoding: .utf8) ?? "无法读取此事件的原始数据。"
    }

    private var categoryTitle: String {
        switch entry.category {
        case .userMessage: "用户消息"
        case .assistantMessage: "助手消息"
        case .systemPrompt: "系统提示"
        case .steeringMessage: "补充说明"
        case .developerMessage: "开发者消息"
        case .toolCall: "工具调用"
        case .toolResult: "工具结果"
        case .requestBoundary: "模型请求"
        case .compaction: "上下文整理"
        case .command: "DSH 命令"
        case .sessionBoundary: "会话边界"
        case .otherBusiness: "会话事件"
        }
    }

    private var categoryIcon: String {
        switch entry.category {
        case .userMessage: "person"
        case .assistantMessage: "sparkles"
        case .systemPrompt: "doc.text"
        case .steeringMessage: "arrow.uturn.forward"
        case .developerMessage: "wrench.and.screwdriver"
        case .toolCall: "terminal"
        case .toolResult: "checkmark.circle"
        case .requestBoundary: "arrow.up.right.circle"
        case .compaction: "arrow.trianglehead.2.clockwise.rotate.90"
        case .command: "command"
        case .sessionBoundary: "rectangle.stack"
        case .otherBusiness: "circle.dashed"
        }
    }

    private var showsPreviewInCollapsedRow: Bool {
        switch entry.category {
        case .userMessage, .assistantMessage, .steeringMessage, .toolCall, .toolResult, .command:
            true
        default:
            false
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if !entry.preview.isEmpty {
                    MarkdownContent(text: entry.preview, onOpenFile: onOpenFile)
                    WorkspaceOutputReferences(text: entry.preview, files: ChatModel.shared.files, onOpenFile: onOpenFile)
                }
                Text(payloadText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 9))
                    .contextMenu {
                        Button("复制事件数据", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = payloadText
                        }
                    }
            }
            .padding(.top, 8)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: categoryIcon)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(categoryTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("#\(entry.seq)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    if showsPreviewInCollapsedRow && !entry.preview.isEmpty {
                        Text(entry.preview)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(expanded ? nil : 2)
                    }
                    // 只留时间:eventType 是宿主那边的英文名,不该上屏。
                    Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .tint(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

/// Debug-only sheet token so `PDSH_DEBUG_SHEET=provider` can present the model
/// provider page without UI automation.
struct DebugSheetToken: Identifiable {
    let value: String
    var id: String { value }
}

// 页头规矩(全站一个数):文字左缘 20,标题仍居中;右侧按钮的右缘跟着 20。
// iOS 26 给工具栏按钮套了一层玻璃胶囊,文字墨迹会比栏边多缩进 13,
// 去掉胶囊之后还剩 2 的差,只有 offset 能真的补上(padding 在这一层会被夹住)。
extension View {
    func leadingBarText() -> some View { self.buttonStyle(.plain).offset(x: -2) }
    func trailingBarText() -> some View { self.buttonStyle(.plain).offset(x: 2) }
}


/// 权限卡本体。真实对话和 `-uiPreview chat.permission` 用同一份画法,
/// 文案、颜色、按钮尺寸不会两处漂移。
struct PermissionCardView: View {
    let permission: ChatPermission
    var isBusy: Bool = false
    var onAllow: () -> Void = {}
    var onDeny: () -> Void = {}

    var body: some View {
        let category = ToolWording.category(forToolName: permission.tool)
        let detail = ToolWording.detail(for: category, arguments: permission.arguments)
        VStack(alignment: .leading, spacing: 10) {
            Label("等待授权", systemImage: "hand.raised.fill")
                .font(.headline)
            // 标题是中文问句;工具名、宿主给的英文 reason 都不上屏。
            Text(category.permissionTitle)
                .font(.subheadline.weight(.semibold))
            if let detail {
                Text(detail)
                    .font(.system(size: 15, design: category == .execute ? .monospaced : .default))
                    .foregroundStyle(ChatPage.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Button {
                onAllow()
            } label: {
                Text("允许一次")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(ChatPage.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isBusy)

            Button {
                onDeny()
            } label: {
                Text("拒绝")
                    .font(.system(size: 15))
                    .foregroundStyle(ChatPage.inkSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ChatPage.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
