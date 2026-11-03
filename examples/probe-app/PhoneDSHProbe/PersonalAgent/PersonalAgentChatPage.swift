// SPDX-License-Identifier: MIT

import ProbeKit
import SwiftUI

struct PersonalAgentChatPage: View {
    @Bindable var model: PersonalAgentModel
    let focus: ChatFocus?
    let connectors: [ConnectorRecord]
    let dailyBrief: DailyBriefModel?
    let followUpCoordinator: FollowUpCoordinator?
    let bottomInset: CGFloat
    let onConfigureModel: () -> Void
    let onOpenDSH: () -> Void
    let onManageConnector: (String?) -> Void
    let onOpenMemory: () -> Void
    let onUndoOperation: ((UUID) -> Void)?

    @Environment(\.scenePhase) private var scenePhase
    @State private var showFollowUps = false
    @State private var expandedArtifacts = Set<String>()
    @State private var voice = ComposerVoiceInput()
    @FocusState private var composerFocused: Bool
    @AppStorage("personalAgent.displayName") private var agentName = "小肥鱼"

    init(model: PersonalAgentModel, focus: ChatFocus? = nil, connectors: [ConnectorRecord] = [],
         dailyBrief: DailyBriefModel? = nil, followUpCoordinator: FollowUpCoordinator? = nil, bottomInset: CGFloat = 0,
         onConfigureModel: @escaping () -> Void = {}, onOpenDSH: @escaping () -> Void = {},
         onManageConnector: @escaping (String?) -> Void = { _ in }, onOpenMemory: @escaping () -> Void = {},
         onUndoOperation: ((UUID) -> Void)? = nil) {
        self.model = model
        self.focus = focus
        self.connectors = connectors
        self.dailyBrief = dailyBrief
        self.followUpCoordinator = followUpCoordinator
        self.bottomInset = bottomInset
        self.onConfigureModel = onConfigureModel
        self.onOpenDSH = onOpenDSH
        self.onManageConnector = onManageConnector
        self.onOpenMemory = onOpenMemory
        self.onUndoOperation = onUndoOperation
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let summary = model.followUpSummary {
                Button { showFollowUps = true } label: {
                    Label(summary, systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, HomeSpec.contentInset)
                        .padding(.vertical, 8)
                }
                .accessibilityLabel(summary)
            }
            timeline
            composer
        }
        .background(HomeSpec.page)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app.chat")
        .padding(.bottom, bottomInset)
        .task {
            await model.load()
            openFocusedFollowUp()
            await dailyBrief?.load()
            if let followUpCoordinator {
                _ = try? await followUpCoordinator.checkAll()
                await model.foreground()
            }
            publishDailyBriefIfChanged()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await model.foreground()
                await dailyBrief?.refreshIfNeeded()
                if let followUpCoordinator { _ = try? await followUpCoordinator.checkAll() }
                await model.foreground()
            }
        }
        .onChange(of: dailyBrief?.snapshot?.id) { _, _ in publishDailyBriefIfChanged() }
        .sheet(isPresented: $showFollowUps) {
            NavigationStack {
                FollowUpListPage(store: model.followUps)
            }
        }
    }

    private var header: some View {
        ZStack {
            Button(action: onOpenMemory) {
                HStack(spacing: 8) {
                    PhoneDSHLogo(size: 30)
                    Text(agentName)
                        .font(.system(size: HomeSpec.navTitleSize, weight: .semibold))
                        .foregroundStyle(HomeSpec.textPrimary)
                        .lineLimit(1)
                }
                .padding(.horizontal, HomeSpec.navButton)
                .frame(maxWidth: .infinity, minHeight: HomeSpec.navButton)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(agentName)，Personal Agent 设置")
            .accessibilityIdentifier("app.chat.agent-settings")
            HStack {
                Spacer()
                Menu {
                    Button("在 DSH 中查看", action: onOpenDSH)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(HomeSpec.textPrimary)
                        .frame(width: HomeSpec.navButton, height: HomeSpec.navButton)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("更多")
                .accessibilityIdentifier("app.chat.more")
            }
        }
        .padding(.horizontal, HomeSpec.chromeInset)
        .padding(.top, HomeSpec.navTop)
        .padding(.bottom, 4)
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: HomeSpec.paragraphGap) {
                    if messagesEmpty {
                        emptyState
                    }
                    if !model.isModelConfigured { modelConfigurationCard }
                    ForEach(model.messages) { message in
                        messageRow(message).id(message.id)
                        if message.role == .assistant, message.turnID == model.suggestion?.turnID,
                           let suggestion = model.suggestion {
                            PersonalAgentSuggestionCard(
                                suggestion: suggestion,
                                onDismiss: { Task { await model.dismissSuggestion() } },
                                onDecline: { Task { await model.declineSuggestion() } },
                                onChoose: { option in Task { await model.chooseSuggestion(option) } })
                                .id("suggestion-\(suggestion.turnID)")
                        }
                    }
                    if !model.streamingText.isEmpty {
                        Text(model.streamingText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("streaming")
                    }
                    if let status = model.activeStatus {
                        Label(status.text, systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: HomeSpec.processSize))
                            .foregroundStyle(HomeSpec.textSecondary)
                            .id(status.id)
                    }
                    if !model.queuedTurns.isEmpty {
                        Text("排队中 \(model.queuedTurns.count)")
                            .font(.caption).foregroundStyle(HomeSpec.textSecondary)
                    }
                    if let question = model.pendingQuestion { questionRow(question) }
                    ForEach(model.operationRecords, id: \.id) { operation in
                        operationRow(operation).id(operation.id)
                    }
                    if let notice = model.recoveryNotice ?? model.failureNotice {
                        Label(notice, systemImage: "exclamationmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(HomeSpec.textPrimary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(HomeSpec.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    ForEach(model.candidates.prefix(2)) { candidate in
                        HStack {
                            Text("可能记住：\(candidate.text)").lineLimit(2)
                            Spacer()
                            Button("记住") { Task { await model.acceptCandidate(candidate.id) } }
                            Button("不用") { Task { await model.rejectCandidate(candidate.id) } }
                        }
                        .font(.caption)
                        .padding(10)
                        .background(HomeSpec.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal, HomeSpec.contentInset)
                .padding(.vertical, 12)
            }
            .onChange(of: model.messages.count) { _, _ in
                if let id = model.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                scrollToFocusedItem(proxy: proxy)
            }
            .onChange(of: focus) { _, _ in
                openFocusedFollowUp()
                scrollToFocusedItem(proxy: proxy)
            }
            .task { scrollToFocusedItem(proxy: proxy) }
        }
        .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
    }

    private var messagesEmpty: Bool {
        model.messages.isEmpty && model.streamingText.isEmpty && model.activeStatus == nil
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            PhoneDSHLogo(size: 64)
            VStack(spacing: 7) {
                Text("你好，我是 \(agentName)")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(HomeSpec.textPrimary)
                Text("今天想一起处理什么？")
                    .font(.body)
                    .foregroundStyle(HomeSpec.textSecondary)
            }
            VStack(spacing: 10) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(suggestion) { model.draft = suggestion }
                        .buttonStyle(.plain)
                        .font(.subheadline)
                        .foregroundStyle(HomeSpec.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(HomeSpec.surface,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
        .padding(.bottom, 12)
    }

    private var suggestions: [String] {
        var values: [String] = []
        if connectors.contains(where: { $0.connectorID == "gmail" && $0.state == .connected }) {
            values.append("总结今天未读邮件，列出需要我回复的。")
        }
        if connectors.contains(where: { $0.connectorID == "github" && $0.state == .connected }) {
            values.append("查看这个 PR 的修改、争议和当前 Checks。")
        }
        if values.isEmpty { values.append("整理一份本地文件，或先去看看能连接什么。") }
        return Array(values.prefix(3))
    }

    private var modelConfigurationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("模型尚未配置").font(.headline)
            Text("配置后才能使用 Personal Agent；现有 DSH 不受影响。")
                .font(.subheadline).foregroundStyle(HomeSpec.textSecondary)
            HStack {
                Button("配置模型", action: onConfigureModel)
                Button("先去 DSH", action: onOpenDSH)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HomeSpec.surface, in: RoundedRectangle(cornerRadius: HomeSpec.listCardRadius))
    }

    private func messageRow(_ message: ConversationMessage) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
            if !message.text.isEmpty {
                Text(message.text)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(message.role == .user ? HomeSpec.userBubble : Color.clear,
                                in: RoundedRectangle(cornerRadius: 18))
                    .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
            }
            if !message.evidenceRefs.isEmpty {
                DisclosureGroup("来源 \(message.evidenceRefs.count)") {
                    ForEach(Array(message.evidenceRefs), id: \.id) { evidence in
                        VStack(alignment: .leading) {
                            Text(evidence.kind).font(.caption.weight(.semibold))
                            Text(evidence.locator).font(.caption).foregroundStyle(HomeSpec.textSecondary)
                        }
                    }
                }
                .font(.subheadline)
            }
            ForEach(message.artifacts) { artifact in
                artifactCard(artifact)
            }
        }
    }

    private func artifactCard(_ artifact: ConversationArtifactRef) -> some View {
        let expanded = expandedArtifacts.contains(artifact.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if expanded { expandedArtifacts.remove(artifact.id) } else { expandedArtifacts.insert(artifact.id) }
            } label: {
                Label(artifact.title, systemImage: expanded ? "chevron.down" : "chevron.right")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if expanded, artifact.kind == "dailyBrief", let snapshot = dailyBrief?.snapshot,
               snapshot.id == artifact.id {
                ForEach(snapshot.items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(.subheadline.weight(.medium))
                        Text(item.sourceName).font(.caption).foregroundStyle(HomeSpec.textSecondary)
                        if !item.summary.isEmpty { Text(item.summary).font(.caption) }
                    }
                    .padding(.vertical, 4)
                }
            } else if expanded {
                PersonalAgentArtifactPreview(artifactID: artifact.id)
            }
        }
        .padding(12)
        .background(HomeSpec.surface, in: RoundedRectangle(cornerRadius: HomeSpec.listCardRadius))
    }

    private func questionRow(_ question: PendingQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(question.text)
                Spacer()
                Button { Task { await model.dismissPendingQuestion() } } label: {
                    Image(systemName: "xmark")
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("关闭问题")
                .accessibilityIdentifier("app.chat.question.dismiss")
            }
            if !question.choices.isEmpty {
                ForEach(question.choices, id: \.self) { choice in
                    Button(choice) { Task { await model.answerPendingQuestion(choice) } }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HomeSpec.surface, in: RoundedRectangle(cornerRadius: HomeSpec.listCardRadius))
    }

    private func operationRow(_ operation: OperationRecord) -> some View {
        HStack {
            switch operation.phase {
            case .undoWindow:
                Text("正在发送")
                if let onUndoOperation {
                    Button("撤销") { onUndoOperation(operation.id) }
                }
            case .unknown:
                Text("正在确认最终结果；请勿重复操作。")
            default:
                EmptyView()
            }
        }
        .font(.subheadline)
    }

    private var composer: some View {
        let canSubmit = model.isRunning || (!model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                            && model.isModelConfigured)
        return VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 2) {
                Menu {
                    ForEach(PersonalAgentSourceSelection.allCases, id: \.self) { source in
                        Button(sourceTitle(source)) { selectSource(source) }
                    }
                    Divider()
                    Button("管理连接器") { onManageConnector(nil) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .medium))
                        Text(sourceTitle(model.sourceSelection))
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .foregroundStyle(HomeSpec.textSecondary)
                    .padding(.horizontal, 6)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("来源：\(sourceTitle(model.sourceSelection))")
                .accessibilityIdentifier("app.chat.source")
                TextField("输入消息", text: $model.draft, axis: .vertical)
                    .focused($composerFocused)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 4)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("app.chat.composer")
                Button {
                    if voice.recording {
                        voice.finish()
                    } else {
                        voice.start { text in
                            model.draft += (model.draft.isEmpty ? "" : " ") + text
                        }
                    }
                } label: {
                    Image(systemName: voice.recording ? "mic.fill" : "mic")
                        .font(.system(size: 19))
                        .foregroundStyle(HomeSpec.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(voice.recording ? "结束听写" : "听写")
                .accessibilityIdentifier("app.chat.voice")
                Button {
                    if model.isRunning { Task { await model.cancel() } } else { Task { await model.send() } }
                } label: {
                    Image(systemName: model.isRunning ? "stop.fill" : "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(canSubmit ? HomeSpec.primaryButtonInk : HomeSpec.iconMuted)
                        .frame(width: 32, height: 32)
                        .background(canSubmit ? HomeSpec.primaryButton : HomeSpec.userBubble, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .accessibilityLabel(model.isRunning ? "停止" : "发送")
                .accessibilityIdentifier("app.chat.send")
            }
            .padding(4)
            .background(HomeSpec.surface,
                        in: RoundedRectangle(cornerRadius: HomeSpec.composerOpenRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: HomeSpec.composerOpenRadius, style: .continuous)
                .strokeBorder(HomeSpec.borderList, lineWidth: 0.5))
            .homeComposerShadow()
            if !voice.status.isEmpty {
                Text(voice.status).font(.caption2).foregroundStyle(HomeSpec.textSecondary)
            }
        }
        .padding(.horizontal, HomeSpec.chromeInset)
        .padding(.bottom, 8)
    }

    private func selectSource(_ source: PersonalAgentSourceSelection) {
        model.sourceSelection = source
        let connectorID: String? = switch source {
        case .github: "github"
        case .gmail: "gmail"
        default: nil
        }
        if let connectorID,
           !connectors.contains(where: { $0.connectorID == connectorID && $0.state == .connected }) {
            onManageConnector(connectorID)
        }
    }

    private func sourceTitle(_ source: PersonalAgentSourceSelection) -> String {
        switch source {
        case .automatic: return "自动"
        case .github: return "GitHub"
        case .gmail: return "Gmail"
        case .files: return "文件"
        }
    }

    private func openFocusedFollowUp() {
        if case .followUp = focus { showFollowUps = true }
    }

    private func scrollToFocusedItem(proxy: ScrollViewProxy) {
        switch focus {
        case .message(let id), .operation(let id): proxy.scrollTo(id, anchor: .center)
        default: break
        }
    }

    private func publishDailyBriefIfChanged() {
        guard let snapshot = dailyBrief?.snapshot, let report = dailyBrief?.lastReport,
              report.newItemCount > 0 else { return }
        Task { await model.publishDailyBrief(snapshot: snapshot, newItemCount: report.newItemCount) }
    }
}

#if DEBUG
final class PersonalAgentPreviewMainAgentPort: MainAgentPort {
    func run(turn: MainTurnInput) -> AsyncThrowingStream<MainEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.status(StatusLine(text: "正在整理", phase: .preparing)))
            continuation.yield(.completed(AssistantMessage(text: "这是明确标记的 Preview 回答。")))
            continuation.finish()
        }
    }

    func cancel(turnID: UUID) async {}
}
#endif
