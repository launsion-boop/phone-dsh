// SPDX-License-Identifier: MIT

import Combine
import PhoneDSHBot
import SwiftUI

struct BotMemoryFact: Identifiable, Equatable {
    let id: String
    var text: String
    var tier: String
    var scope: String
    var source: String
    var learnedAt: Date
}

struct BotRoutineInfo: Identifiable, Equatable {
    let id: String
    var title: String
    var schedule: String
    var timeZone: String
    var delivery: String
    var quiet: Bool
    var urgent: Bool
    var urgentReason: String?
    var lastResult: String
    var enabled: Bool
}

struct BotApprovalRecord: Identifiable, Equatable {
    let id: String
    var parameterSummary: String
    var decision: String
    var decidedAt: Date
}

struct BotInfoSnapshot {
    var botName: String
    var memories: [BotMemoryFact]
    var routines: [BotRoutineInfo]
    var approvals: [BotApprovalRecord]
}

struct BotInfoDriver {
    var load: () async throws -> BotInfoSnapshot
    var rename: (String) async throws -> Void
    var forget: (BotMemoryFact) async throws -> Void
    /// Erases this Bot's agent scope only.
    var erase: () async throws -> Void
    /// Erases the shared user scope for every Bot; a separate confirmed entry.
    var eraseShared: () async throws -> Void = {}
    var setRoutineEnabled: (String, Bool) async throws -> Void
}

enum BotInfoLoadState: Equatable {
    case loading
    case loaded
    case failed(String)
}

@MainActor
final class BotInfoModel: ObservableObject {
    @Published private(set) var botName: String
    @Published var draftName: String
    @Published private(set) var memories: [BotMemoryFact]
    @Published private(set) var routines: [BotRoutineInfo]
    @Published private(set) var approvals: [BotApprovalRecord]
    @Published private(set) var memoryState: BotInfoLoadState
    @Published private(set) var routinesState: BotInfoLoadState
    @Published private(set) var approvalsState: BotInfoLoadState
    @Published var actionError: String?
    /// The profile's appearance is the authority for the preview and for the
    /// 4 hairstyle thumbnails; selecting one saves immediately.
    @Published private(set) var appearance: BotFishAppearance
    /// Mirrors the roster main-Bot pointer so the avatar gets the crown.
    @Published private(set) var isMainBot = false

    private let driver: BotInfoDriver?
    private let fixtureError: String?
    private var profileCenter: BotProfileCenter?
    private var profileCancellables: Set<AnyCancellable> = []

    init(snapshot: BotInfoSnapshot? = nil, driver: BotInfoDriver? = nil, fixtureError: String? = nil,
         appearance: BotFishAppearance = .classic, profileCenter: BotProfileCenter? = nil) {
        let name = snapshot?.botName ?? profileCenter?.displayName ?? "大肥鱼"
        botName = name
        draftName = name
        memories = snapshot?.memories ?? []
        routines = snapshot?.routines ?? []
        approvals = snapshot?.approvals ?? []
        let initial: BotInfoLoadState
        if let fixtureError { initial = .failed(fixtureError) }
        else { initial = snapshot == nil && driver != nil ? .loading : .loaded }
        memoryState = initial
        routinesState = initial
        approvalsState = initial
        self.appearance = profileCenter?.appearance ?? appearance
        self.driver = driver
        self.fixtureError = fixtureError
        attach(profileCenter: profileCenter)
    }

    private func attach(profileCenter center: BotProfileCenter?) {
        self.profileCenter = center
        profileCancellables.removeAll()
        guard let center else { return }
        center.$displayName
            .sink { [weak self] value in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.draftName == self.botName { self.draftName = value }
                    self.botName = value
                }
            }
            .store(in: &profileCancellables)
        center.$appearance
            .sink { [weak self] value in
                Task { @MainActor [weak self] in self?.appearance = value }
            }
            .store(in: &profileCancellables)
        center.$errorMessage
            .sink { [weak self] value in
                Task { @MainActor [weak self] in
                    if let value { self?.actionError = value }
                }
            }
            .store(in: &profileCancellables)
    }

    /// Selects a color/hairstyle: the preview changes immediately and the
    /// profile store receives only the changed field.
    func select(color: BotFishColor) async {
        if let profileCenter {
            await profileCenter.select(color: color)
        } else {
            var next = appearance
            next.color = color
            next.autoColor = false
            appearance = next
        }
    }

    func select(hairstyle: BotFishHairstyle) async {
        if let profileCenter {
            await profileCenter.select(hairstyle: hairstyle)
        } else {
            var next = appearance
            next.hairstyle = hairstyle
            next.autoHairstyle = false
            appearance = next
        }
    }

    func appearance(for hairstyle: BotFishHairstyle) -> BotFishAppearance {
        var value = appearance
        value.hairstyle = hairstyle
        value.autoHairstyle = false
        return value
    }

    func refresh() async {
        guard let driver else {
            if let fixtureError {
                memoryState = .failed(fixtureError)
                routinesState = .failed(fixtureError)
                approvalsState = .failed(fixtureError)
            } else {
                memoryState = .loaded
                routinesState = .loaded
                approvalsState = .loaded
            }
            return
        }
        memoryState = .loading
        routinesState = .loading
        approvalsState = .loading
        do {
            let snapshot = try await driver.load()
            let name = profileCenter?.displayName ?? snapshot.botName
            if draftName == botName { draftName = name }
            botName = name
            memories = snapshot.memories
            routines = snapshot.routines
            approvals = snapshot.approvals
            memoryState = .loaded
            routinesState = .loaded
            approvalsState = .loaded
        } catch {
            let message = error.localizedDescription
            memoryState = .failed(message)
            routinesState = .failed(message)
            approvalsState = .failed(message)
        }
    }

    func rename() async {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            actionError = "Bot 名不能为空。"
            return
        }
        do {
            try await driver?.rename(name)
            botName = name
            draftName = name
            do {
                try await profileCenter?.rename(name)
            } catch {
                actionError = "名字已写入对话，但资料同步失败：\(error.localizedDescription)"
            }
        } catch {
            actionError = "改名失败：\(error.localizedDescription)"
        }
    }

    func forget(_ fact: BotMemoryFact) async {
        do {
            try await driver?.forget(fact)
            memories.removeAll { $0.id == fact.id }
        } catch {
            actionError = "忘记失败：\(error.localizedDescription)"
        }
    }

    func setMainBot(_ isMain: Bool) {
        guard isMainBot != isMain else { return }
        isMainBot = isMain
    }

    /// Only this Bot's agent facts disappear from the page; shared facts stay
    /// visible and remain available to every Bot.
    func erase() async {
        do {
            try await driver?.erase()
            memories.removeAll { $0.scope != "user" }
        } catch {
            actionError = "抹除失败：\(error.localizedDescription)"
        }
    }

    func eraseShared() async {
        do {
            try await driver?.eraseShared()
            memories.removeAll { $0.scope == "user" }
        } catch {
            actionError = "清除共享记忆失败：\(error.localizedDescription)"
        }
    }

    func setRoutine(_ routine: BotRoutineInfo, enabled: Bool) async {
        do {
            try await driver?.setRoutineEnabled(routine.id, enabled)
            guard let index = routines.firstIndex(where: { $0.id == routine.id }) else { return }
            routines[index].enabled = enabled
        } catch {
            actionError = "例行任务更新失败：\(error.localizedDescription)"
        }
    }
}

/// The three data destinations also reachable from the Bot page's “…” menu.
enum BotInfoSection: Hashable {
    case memory
    case routines
    case approvals
}

/// Bot 信息: the avatar and name on top, the name editor, then the Bot's own
/// data (memory, routines, approvals). Same grouped-list chrome as 我的.
struct BotInfoPage: View {
    @ObservedObject var model: BotInfoModel
    let isMainBot: Bool
    let onDelete: (() async throws -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var path: [BotInfoSection]
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var deleteError: String?

    init(model: BotInfoModel, isMainBot: Bool = false,
         initialSection: BotInfoSection? = nil,
         onDelete: (() async throws -> Void)? = nil) {
        self.model = model
        self.isMainBot = isMainBot
        self.onDelete = onDelete
        _path = State(initialValue: initialSection.map { [$0] } ?? [])
    }

    private var nameChanged: Bool {
        let draft = model.draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !draft.isEmpty && draft != model.botName
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    VStack(spacing: 12) {
                        BotFishView(state: .idle, size: 80, appearance: model.appearance,
                                    crowned: isMainBot, still: true)
                        Text(model.botName)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(HomeSpec.textPrimary)
                        Text("你的私人 Bot，替你跟进任务和提醒")
                            .font(.system(size: 14))
                            .foregroundStyle(HomeSpec.textPlaceholder)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                Section {
                    HomeFieldRow(title: "名称") {
                        TextField("", text: $model.draftName, prompt: Text("给 Bot 起个名字"))
                            .textInputAutocapitalization(.never)
                            .accessibilityIdentifier("bot.info.name")
                    }
                    if nameChanged {
                        Button {
                            Task { await model.rename() }
                        } label: {
                            Text("保存名称").fontWeight(.semibold)
                        }
                        .accessibilityIdentifier("bot.info.rename")
                    }
                } header: {
                    Text("名称")
                }

                Section {
                    BotAppearanceEditor(model: model)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                } header: {
                    Text("外观")
                } footer: {
                    Text("只改发型和颜色，与桌面 DSH Bot 一致；点选即保存，自动外观保留给以后的多 Bot 接入。")
                }

                Section("数据") {
                    NavigationLink(value: BotInfoSection.memory) {
                        BotInfoEntryLabel(title: "记忆", systemImage: "brain", state: model.memoryState,
                                          count: model.memories.count)
                    }
                    .accessibilityIdentifier("bot.info.memory")
                    NavigationLink(value: BotInfoSection.routines) {
                        BotInfoEntryLabel(title: "例行任务", systemImage: "repeat", state: model.routinesState,
                                          count: model.routines.count)
                    }
                    .accessibilityIdentifier("bot.info.routines")
                    NavigationLink(value: BotInfoSection.approvals) {
                        BotInfoEntryLabel(title: "审批记录", systemImage: "checkmark.shield", state: model.approvalsState,
                                          count: model.approvals.count)
                    }
                    .accessibilityIdentifier("bot.info.approvals")
                }

                if let error = model.actionError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 14))
                            .foregroundStyle(BotUIPalette.danger)
                    }
                }

                if onDelete != nil {
                    Section {
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            HStack {
                                Text(deleting ? "正在删除…" : "删除这个 Bot")
                                if deleting { Spacer(); ProgressView().controlSize(.small) }
                            }
                        }
                        .disabled(deleting)
                        .accessibilityIdentifier("bot.info.delete")
                        if let deleteError {
                            Label(deleteError, systemImage: "exclamationmark.triangle")
                                .font(.system(size: 14))
                                .foregroundStyle(BotUIPalette.danger)
                                .accessibilityIdentifier("bot.info.delete.error")
                        }
                    } header: {
                        Text("危险操作")
                    } footer: {
                        Text("删除会中止运行中的回合、拒绝待审批、撤销授权、归档 DSH 会话并清除本 Bot 的 agent 记忆。至少保留一个 Bot。")
                    }
                }
            }
            .homeGroupedList()
            .navigationTitle("Bot 信息")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: BotInfoSection.self) { section in
                switch section {
                case .memory: BotMemoryPage(model: model)
                case .routines: BotRoutinesPage(model: model)
                case .approvals: BotApprovalHistoryPage(model: model)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("刷新")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .task {
                model.setMainBot(isMainBot)
                if model.memoryState == .loading { await model.refresh() }
            }
            .onChange(of: isMainBot) { _, newValue in
                model.setMainBot(newValue)
            }
            .confirmationDialog("删除这个 Bot？", isPresented: $confirmDelete) {
                Button("删除", role: .destructive) {
                    deleting = true
                    deleteError = nil
                    Task {
                        do {
                            try await onDelete?()
                            dismiss()
                        } catch {
                            deleteError = deleteFailureText(error)
                        }
                        deleting = false
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("删除后不能从页面内撤销。最后一个 Bot 不能删除。")
            }
        }
    }

    private func deleteFailureText(_ error: Error) -> String {
        if let profileError = error as? BotProfileStoreError {
            switch profileError {
            case .lastBot: return "这是最后一个 Bot，不能删除。"
            case .unknownBot: return "这个 Bot 已经不存在。"
            default: return profileError.description
            }
        }
        if let failure = error as? BotDeletionFailure { return failure.description }
        return "删除失败：\(error.localizedDescription)"
    }
}

private struct BotInfoEntryLabel: View {
    let title: String
    let systemImage: String
    let state: BotInfoLoadState
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(HomeSpec.textPrimary)
                .frame(width: 24, height: 24)
            Text(title)
                .font(.system(size: HomeSpec.bodySize))
                .foregroundStyle(HomeSpec.textPrimary)
            Spacer(minLength: 8)
            switch state {
            case .loaded:
                Text("\(count)")
                    .font(.system(size: 15))
                    .foregroundStyle(HomeSpec.textPlaceholder)
            case .loading: ProgressView().controlSize(.small)
            case .failed:
                Text("读取失败")
                    .font(.system(size: 15))
                    .foregroundStyle(BotUIPalette.danger)
            }
        }
        .frame(minHeight: 32)
    }
}

private struct BotMemoryPage: View {
    @ObservedObject var model: BotInfoModel
    @State private var forgetting: BotMemoryFact?
    @State private var confirmErase = false
    @State private var confirmShared = false
    @State private var confirmSharedAgain = false

    private var botFacts: [BotMemoryFact] {
        model.memories.filter { $0.scope != "user" }
    }

    private var sharedFacts: [BotMemoryFact] {
        model.memories.filter { $0.scope == "user" }
    }

    var body: some View {
        List {
            switch model.memoryState {
            case .loading:
                ProgressView().frame(maxWidth: .infinity)
            case .failed(let message):
                BotFailureRow(message: "记忆读取失败：\(message)。这不代表没有记忆。") {
                    Task { await model.refresh() }
                }
                .listRowBackground(Color.clear)
            case .loaded:
                if botFacts.isEmpty && sharedFacts.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("还没有已保存的记忆。")
                                .foregroundStyle(HomeSpec.textSecondary)
                            Text("本 Bot 自己的记忆和所有 Bot 共享的记忆都会显示在这里。")
                                .botCaptionFont()
                                .foregroundStyle(HomeSpec.textTertiary)
                        }
                    }
                } else {
                    Section {
                        if botFacts.isEmpty {
                            Text("这个 Bot 还没有自己的记忆。")
                                .foregroundStyle(HomeSpec.textSecondary)
                        } else {
                            ForEach(botFacts) { fact in
                                memoryRow(fact)
                            }
                            Button("抹除这个 Bot 的记忆", role: .destructive) { confirmErase = true }
                                .accessibilityIdentifier("bot.memory.erase")
                        }
                    } header: {
                        Text("本 Bot")
                    } footer: {
                        Text("只清除这个 Bot 的 agent 记忆；共享记忆和其他 Bot 的记忆不受影响。")
                    }

                    Section {
                        if sharedFacts.isEmpty {
                            Text("还没有所有 Bot 共享的记忆。")
                                .foregroundStyle(HomeSpec.textSecondary)
                        } else {
                            ForEach(sharedFacts) { fact in
                                memoryRow(fact)
                            }
                            Button("清除所有 Bot 共享的记忆", role: .destructive) {
                                confirmShared = true
                            }
                            .accessibilityIdentifier("bot.memory.erase.shared")
                        }
                    } header: {
                        Text("共享")
                    } footer: {
                        Text("user scope 的记忆属于所有 Bot；清除后每个 Bot 都会失去这些事实。")
                    }
                }
            }
        }
        .homeGroupedList()
        .navigationTitle("记忆")
        .confirmationDialog("忘记这条记忆？", isPresented: Binding(
            get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }
        )) {
            Button("忘记", role: .destructive) {
                if let forgetting { Task { await model.forget(forgetting) } }
                forgetting = nil
            }
            Button("取消", role: .cancel) { forgetting = nil }
        }
        .confirmationDialog("抹除这个 Bot 的记忆？", isPresented: $confirmErase) {
            Button("抹除本 Bot 的记忆", role: .destructive) { Task { await model.erase() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只移除这个 Bot 的 agent facts，不会动共享记忆。")
        }
        .confirmationDialog("清除所有 Bot 共享的记忆？", isPresented: $confirmShared) {
            Button("继续", role: .destructive) {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    confirmSharedAgain = true
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会影响每一个 Bot。")
        }
        .confirmationDialog("最后确认：清除全部共享记忆？", isPresented: $confirmSharedAgain) {
            Button("清除共享记忆", role: .destructive) { Task { await model.eraseShared() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作不能在页面内回滚。")
        }
    }

    @ViewBuilder
    private func memoryRow(_ fact: BotMemoryFact) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(fact.text)
                .botBodyFont()
                .foregroundStyle(HomeSpec.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(fact.tier) · \(fact.scope) · \(fact.source)")
                .botCaptionFont()
                .foregroundStyle(HomeSpec.textSecondary)
            Text(fact.learnedAt.formatted(date: .abbreviated, time: .shortened))
                .botCaptionFont()
                .foregroundStyle(HomeSpec.textTertiary)
            Button("忘记这条") { forgetting = fact }
                .buttonStyle(BotTextButtonStyle())
                .botHitTarget()
        }
        .padding(.vertical, 4)
    }
}

private struct BotRoutinesPage: View {
    @ObservedObject var model: BotInfoModel

    var body: some View {
        List {
            switch model.routinesState {
            case .loading:
                ProgressView().frame(maxWidth: .infinity)
            case .failed(let message):
                BotFailureRow(message: "例行任务读取失败：\(message)。这不代表没有例行任务。") {
                    Task { await model.refresh() }
                }
                .listRowBackground(Color.clear)
            case .loaded:
                if model.routines.isEmpty {
                    Text("还没有例行任务。")
                        .foregroundStyle(HomeSpec.textSecondary)
                } else {
                    ForEach(model.routines) { routine in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(routine.title)
                                    .botTitleFont()
                                    .foregroundStyle(HomeSpec.textPrimary)
                                Spacer()
                                BotStatusPill(text: routine.enabled ? "已启用" : "已暂停",
                                              tone: routine.enabled ? .success : .neutral)
                            }
                            LabeledContent("排程", value: routine.schedule)
                            LabeledContent("时区", value: routine.timeZone)
                            LabeledContent("交付", value: routine.delivery)
                            if routine.quiet {
                                Label("安静时段会延后", systemImage: "moon")
                                    .botCaptionFont()
                                    .foregroundStyle(HomeSpec.textSecondary)
                            }
                            if routine.urgent {
                                Label("紧急：\(routine.urgentReason ?? "未说明")", systemImage: "exclamationmark")
                                    .botCaptionFont()
                                    .foregroundStyle(NativeParityTokens.warning)
                            }
                            Text(routine.lastResult)
                                .botSecondaryFont()
                                .foregroundStyle(HomeSpec.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(routine.enabled ? "暂停" : "恢复") {
                                Task { await model.setRoutine(routine, enabled: !routine.enabled) }
                            }
                            .buttonStyle(BotTextButtonStyle())
                            .botHitTarget()
                            .accessibilityIdentifier("bot.routine.toggle.\(routine.id)")
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .homeGroupedList()
        .navigationTitle("例行任务")
    }
}

private struct BotApprovalHistoryPage: View {
    @ObservedObject var model: BotInfoModel

    var body: some View {
        List {
            switch model.approvalsState {
            case .loading:
                ProgressView().frame(maxWidth: .infinity)
            case .failed(let message):
                BotFailureRow(message: "审批记录读取失败：\(message)。") {
                    Task { await model.refresh() }
                }
                .listRowBackground(Color.clear)
            case .loaded:
                if model.approvals.isEmpty {
                    Text("还没有审批记录。")
                        .foregroundStyle(HomeSpec.textSecondary)
                } else {
                    ForEach(model.approvals) { record in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(record.parameterSummary)
                                .botBodyFont()
                                .foregroundStyle(HomeSpec.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Text(record.decision)
                                    .botSecondaryFont(weight: .medium)
                                    .foregroundStyle(HomeSpec.textSecondary)
                                Spacer()
                                Text(record.decidedAt.formatted(date: .abbreviated, time: .shortened))
                                    .botCaptionFont()
                                    .foregroundStyle(HomeSpec.textTertiary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .homeGroupedList()
        .navigationTitle("审批记录")
    }
}

/// The appearance editor: one 112pt live preview, the four hairstyles as 40pt
/// fish thumbnails in the current color, and the fifteen color dots. Every
/// tap saves immediately through `BotInfoModel`; no "auto" choice is exposed
/// (the model keeps nil for the future multi-Bot import path).
private struct BotAppearanceEditor: View {
    @ObservedObject var model: BotInfoModel

    private let columns = [GridItem(.adaptive(minimum: 44, maximum: 44), spacing: 2, alignment: .leading)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            BotFishView(state: .idle, size: 112, appearance: model.appearance,
                        crowned: model.isMainBot, allowsPoke: true)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("外观预览，\(model.appearance.color.displayName)，\(model.appearance.hairstyle.displayName)")

            VStack(alignment: .leading, spacing: 6) {
                Text("发型")
                    .font(.system(size: 13))
                    .foregroundStyle(HomeSpec.textSecondary)
                HStack(spacing: 6) {
                    ForEach(BotFishHairstyle.allCases, id: \.self) { hairstyle in
                        hairstyleButton(hairstyle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("颜色")
                    .font(.system(size: 13))
                    .foregroundStyle(HomeSpec.textSecondary)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 2) {
                    ForEach(BotFishColor.allCases, id: \.self) { color in
                        colorButton(color)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private func hairstyleButton(_ hairstyle: BotFishHairstyle) -> some View {
        let selected = model.appearance.hairstyle == hairstyle
        return Button {
            Task { await model.select(hairstyle: hairstyle) }
        } label: {
            BotFishView(state: .idle, size: 40, appearance: model.appearance(for: hairstyle),
                        crowned: model.isMainBot, still: true)
                .frame(width: 44, height: 44)
                .background(selected ? HomeSpec.userBubble : Color.clear, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(HomeSpec.primaryButton, lineWidth: selected ? 2 : 0)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hairstyle.displayName)
        .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : AccessibilityTraits())
        .accessibilityIdentifier("bot.info.appearance.hair.\(hairstyle.rawValue)")
    }

    private func colorButton(_ color: BotFishColor) -> some View {
        let selected = model.appearance.color == color
        return Button {
            Task { await model.select(color: color) }
        } label: {
            Circle()
                .fill(Self.swatch(color))
                .frame(width: 24, height: 24)
                .overlay {
                    Circle().strokeBorder(HomeSpec.borderList, lineWidth: 0.5)
                }
                .frame(width: 44, height: 44)
                .overlay {
                    Circle()
                        .strokeBorder(HomeSpec.primaryButton, lineWidth: selected ? 2 : 0)
                        .frame(width: 32, height: 32)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(color.displayName)
        .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : AccessibilityTraits())
        .accessibilityIdentifier("bot.info.appearance.color.\(color.rawValue)")
    }

    private static func swatch(_ color: BotFishColor) -> Color {
        let hex = color.hex.hasPrefix("#") ? String(color.hex.dropFirst()) : color.hex
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return .gray }
        return Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
}
