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
    @AppStorage("personalAgent.displayName") private var agentName = "Personal Agent"

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
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(agentName).font(.system(size: HomeSpec.navTitleSize, weight: .semibold))
                Text(model.isRunning ? "处理中" : "今天需要处理什么？")
                    .font(.caption).foregroundStyle(HomeSpec.textSecondary)
            }
            Spacer()
            Button(action: onOpenMemory) {
                Image(systemName: "person.crop.circle")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("个人上下文与 Memory")
            Menu {
                Button("在 DSH 中查看", action: onOpenDSH)
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, HomeSpec.chromeInset)
        .padding(.vertical, 8)
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
    }

    private var messagesEmpty: Bool {
        model.messages.isEmpty && model.streamingText.isEmpty && model.activeStatus == nil
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("今天需要处理什么？").font(.title3.weight(.semibold))
            ForEach(suggestions, id: \.self) { suggestion in
                Button(suggestion) { model.draft = suggestion }
                    .buttonStyle(.plain)
                    .foregroundStyle(HomeSpec.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 20)
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
            Text(question.text)
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
        VStack(spacing: 6) {
            HStack {
                Text("本次来源")
                Menu {
                    ForEach(PersonalAgentSourceSelection.allCases, id: \.self) { source in
                        Button(sourceTitle(source)) { model.sourceSelection = source }
                    }
                    Divider()
                    Button("管理连接器") { onManageConnector(nil) }
                } label: {
                    Label(sourceTitle(model.sourceSelection), systemImage: "chevron.up.chevron.down")
                }
                Spacer()
            }
            .font(.caption).foregroundStyle(HomeSpec.textSecondary)
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button("GitHub") { selectSource(.github, connectorID: "github") }
                    Button("Gmail") { selectSource(.gmail, connectorID: "gmail") }
                    Button("文件") { model.sourceSelection = .files }
                    Button("管理连接器") { onManageConnector(nil) }
                } label: {
                    Image(systemName: "plus.circle").font(.title2).frame(width: 44, height: 44)
                }
                .accessibilityLabel("添加来源")
                TextField("输入…，也可 @ 指定来源", text: $model.draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 10)
                Menu {
                    Button("GitHub") { selectSource(.github, connectorID: "github") }
                    Button("Gmail") { selectSource(.gmail, connectorID: "gmail") }
                    Button("文件") { model.sourceSelection = .files }
                    Button("管理连接器") { onManageConnector(nil) }
                } label: {
                    Text("@").frame(width: 36, height: 44)
                }
                .accessibilityLabel("指定来源")
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
                        .frame(width: 36, height: 44)
                }
                .accessibilityLabel(voice.recording ? "结束听写" : "听写")
                Button {
                    if model.isRunning { Task { await model.cancel() } } else { Task { await model.send() } }
                } label: {
                    Image(systemName: model.isRunning ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.title2).frame(width: 44, height: 44)
                }
                .disabled(!model.isRunning && (model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.isModelConfigured))
                .accessibilityLabel(model.isRunning ? "停止" : "发送")
            }
            .padding(.horizontal, 8)
            .background(HomeSpec.surface, in: RoundedRectangle(cornerRadius: HomeSpec.composerOpenRadius))
            if !voice.status.isEmpty {
                Text(voice.status).font(.caption2).foregroundStyle(HomeSpec.textSecondary)
            }
        }
        .padding(.horizontal, HomeSpec.chromeInset)
        .padding(.bottom, 8)
    }

    private func selectSource(_ source: PersonalAgentSourceSelection, connectorID: String) {
        model.sourceSelection = source
        if !connectors.contains(where: { $0.connectorID == connectorID && $0.state == .connected }) {
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
