// SPDX-License-Identifier: MIT

import Combine
import PhoneDSHBot
import SwiftUI

struct BotMemoryVersionInfo: Identifiable, Hashable {
    let id: String
    var version: Int
    var content: String
    var deleted: Bool
    var deletionReason: String?
    var updatedAt: Date
    var author: String
    var evidence: [String]
}

struct BotMemoryDocumentInfo: Identifiable, Hashable {
    let id: String
    var path: String
    var scope: String
    var content: String
    var version: Int
    var updatedAt: Date
    var author: String
    var evidence: [String]
    var versions: [BotMemoryVersionInfo]

    var isUserRoot: Bool { scope == "user" }
    var fileName: String { path.split(separator: "/").last.map(String.init) ?? path }
}

struct BotMaintenanceChangeInfo: Identifiable, Hashable {
    var id: String { path }
    var path: String
    var scope: String
    var beforeVersion: Int
    var afterVersion: Int
    var deleted: Bool
}

struct BotMaintenanceBatchInfo: Identifiable, Hashable {
    var id: String { batchID }
    var batchID: String
    var status: String
    var trigger: String
    var startedAt: Date
    var finishedAt: Date
    var changedDocuments: Int
    var changes: [BotMaintenanceChangeInfo]
    var failureCode: String?
    var checksPassed: Bool
    var rolledBack: Bool
    var canRollback: Bool
    var tokensUsed: Int
    var notification: Bool
}

struct BotMemoryTreeItem: Identifiable, Equatable {
    let id: String
    var name: String
    var isDirectory: Bool
    var document: BotMemoryDocumentInfo?
    var children: [BotMemoryTreeItem]
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
    var creator: String?
    var completionCriteria: String?
    var routineConstraints: String?
    var runStatus: String?
    var runID: String?
}

struct BotGrantInfo: Identifiable, Equatable {
    let id: String
    var tool: String
    var operation: String
    var resource: String
    var scope: String
    var sessionID: String?
    var createdAt: Date
    var source: String
}

struct BotReconciliationInfo: Identifiable, Equatable {
    var id: String { routineID }
    let routineID: String
    var routineTitle: String
    var attempt: Int
    var runID: String
    var error: String?
    var effectSummary: String?
}

struct BotApprovalRecord: Identifiable, Equatable {
    let id: String
    var parameterSummary: String
    var decision: String
    var decidedAt: Date
}

struct BotInfoSnapshot {
    var botName: String
    var memories: [BotMemoryDocumentInfo]
    var routines: [BotRoutineInfo]
    var approvals: [BotApprovalRecord]
    var grants: [BotGrantInfo] = []
    var reconciliations: [BotReconciliationInfo] = []
    var presence: RoutinePresence = RoutinePresence(level: .foreground)
    var proactiveSettings: ProactiveSettings = ProactiveSettingsStore.productionDefault
    var maintenance: BotMaintenanceBatchInfo?
    var maintenanceEnabled = false
    var maintenanceDailyTokens = 0
    var maintenanceDailyBudget = 0
}

struct BotInfoDriver {
    var load: () async throws -> BotInfoSnapshot
    var rename: (String) async throws -> Void
    var forget: (BotMemoryDocumentInfo) async throws -> Void
    /// Physically erases one document and every historical version.
    var eraseDocument: (BotMemoryDocumentInfo) async throws -> Void = { _ in }
    /// Physically erases this Bot's agent root only.
    var erase: () async throws -> Void
    /// Erases the shared user scope for every Bot; a separate confirmed entry.
    var eraseShared: () async throws -> Void = {}
    var setRoutineEnabled: (String, Bool) async throws -> Void
    var revokeGrant: (String) async throws -> Void = { _ in }
    var cancelRoutine: (String) async throws -> Void = { _ in }
    var resolveReconciliation: (String, String) async throws -> Void = { _, _ in }
    /// Returns the normalized value the host actually persisted.
    var saveProactiveSettings: (ProactiveSettings) async throws -> ProactiveSettings = { $0 }
    var setMaintenanceEnabled: (Bool) async throws -> Void = { _ in }
    var rollbackMaintenance: (String) async throws -> Void = { _ in }
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
    @Published private(set) var memories: [BotMemoryDocumentInfo]
    @Published private(set) var routines: [BotRoutineInfo]
    @Published private(set) var approvals: [BotApprovalRecord]
    @Published private(set) var grants: [BotGrantInfo]
    @Published private(set) var reconciliations: [BotReconciliationInfo]
    @Published private(set) var presence: RoutinePresence
    @Published private(set) var proactiveSettings: ProactiveSettings
    @Published private(set) var maintenance: BotMaintenanceBatchInfo?
    @Published private(set) var maintenanceEnabled = false
    @Published private(set) var maintenanceDailyTokens = 0
    @Published private(set) var maintenanceDailyBudget = 0
    @Published var highlightedRoutineID: String?
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
        grants = snapshot?.grants ?? []
        reconciliations = snapshot?.reconciliations ?? []
        presence = snapshot?.presence ?? RoutinePresence(level: .foreground)
        proactiveSettings = snapshot?.proactiveSettings ?? ProactiveSettingsStore.productionDefault
        maintenance = snapshot?.maintenance
        maintenanceEnabled = snapshot?.maintenanceEnabled ?? false
        maintenanceDailyTokens = snapshot?.maintenanceDailyTokens ?? 0
        maintenanceDailyBudget = snapshot?.maintenanceDailyBudget ?? 0
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
            grants = snapshot.grants
            reconciliations = snapshot.reconciliations
            presence = snapshot.presence
            proactiveSettings = snapshot.proactiveSettings
            maintenance = snapshot.maintenance
            maintenanceEnabled = snapshot.maintenanceEnabled
            maintenanceDailyTokens = snapshot.maintenanceDailyTokens
            maintenanceDailyBudget = snapshot.maintenanceDailyBudget
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

    func forget(_ document: BotMemoryDocumentInfo) async {
        do {
            try await driver?.forget(document)
            memories.removeAll { $0.id == document.id }
        } catch {
            actionError = "忘记失败：\(error.localizedDescription)"
        }
    }

    func setMainBot(_ isMain: Bool) {
        guard isMainBot != isMain else { return }
        isMainBot = isMain
    }

    /// Physically erases one document and every historical version, then
    /// re-reads the host authority. The fixture path only edits local state.
    func erase(_ document: BotMemoryDocumentInfo) async {
        guard let driver else {
            memories.removeAll { $0.id == document.id }
            return
        }
        do {
            try await driver.eraseDocument(document)
            await refresh()
        } catch {
            actionError = "抹除失败：\(error.localizedDescription)"
        }
    }

    func erase() async {
        guard let driver else {
            memories.removeAll { $0.scope != "user" }
            return
        }
        do {
            try await driver.erase()
            await refresh()
        } catch {
            actionError = "抹除失败：\(error.localizedDescription)"
        }
    }

    func eraseShared() async {
        guard let driver else {
            memories.removeAll { $0.scope == "user" }
            return
        }
        do {
            try await driver.eraseShared()
            await refresh()
        } catch {
            actionError = "抹除共享 user/ 记忆失败：\(error.localizedDescription)"
        }
    }

    func setMaintenanceEnabled(_ enabled: Bool) async {
        let previous = maintenanceEnabled
        maintenanceEnabled = enabled
        do {
            try await driver?.setMaintenanceEnabled(enabled)
        } catch {
            maintenanceEnabled = previous
            actionError = "保存记忆整理开关失败：\(error.localizedDescription)"
        }
    }

    func rollbackMaintenance() async {
        guard let batch = maintenance else { return }
        do {
            try await driver?.rollbackMaintenance(batch.batchID)
            await refresh()
        } catch {
            actionError = "回滚记忆整理失败：\(error.localizedDescription)"
        }
    }

    var quietStartDate: Date { Self.timeDate(proactiveSettings.quietStart) }
    var quietEndDate: Date { Self.timeDate(proactiveSettings.quietEnd) }

    func setDND(_ value: Bool) async {
        var next = proactiveSettings
        next.dnd = value
        await persist(next)
    }

    func setQuietStart(_ date: Date) async {
        var next = proactiveSettings
        next.quietStart = Self.timeText(date)
        await persist(next)
    }

    func setQuietEnd(_ date: Date) async {
        var next = proactiveSettings
        next.quietEnd = Self.timeText(date)
        await persist(next)
    }

    private func persist(_ settings: ProactiveSettings) async {
        do {
            proactiveSettings = try await driver?.saveProactiveSettings(settings) ?? settings
            if let driver {
                presence = try await driver.load().presence
            }
        } catch {
            actionError = "打扰设置保存失败：\(error.localizedDescription)"
        }
    }

    private static func timeDate(_ value: String) -> Date {
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
        let hour = pieces.count == 2 ? Int(pieces[0]) ?? 23 : 23
        let minute = pieces.count == 2 ? Int(pieces[1]) ?? 0 : 0
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        components.minute = minute
        components.second = 0
        return Calendar.current.date(from: components) ?? Date()
    }

    private static func timeText(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 23, components.minute ?? 0)
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

    func cancelRoutine(_ routine: BotRoutineInfo) async {
        do {
            try await driver?.cancelRoutine(routine.id)
            await refresh()
        } catch {
            actionError = "取消运行失败：\(error.localizedDescription)"
        }
    }

    func revocation(of grant: BotGrantInfo) async {
        do {
            try await driver?.revokeGrant(grant.id)
            grants.removeAll { $0.id == grant.id }
        } catch {
            actionError = "撤销授权失败：\(error.localizedDescription)"
        }
    }

    func reconciliation(for routine: BotRoutineInfo) -> BotReconciliationInfo? {
        reconciliations.first { $0.routineID == routine.id }
    }

    func resolve(_ item: BotReconciliationInfo, decision: String) async {
        do {
            try await driver?.resolveReconciliation(item.routineID, decision)
            reconciliations.removeAll { $0.routineID == item.routineID }
            await refresh()
        } catch {
            actionError = "处理对账失败：\(error.localizedDescription)"
        }
    }
}

/// The three data destinations also reachable from the Bot page's “…” menu.
enum BotInfoSection: Hashable {
    case memory
    case routines
    case approvals
    case grants
}

/// A request to present the information page at one section. Routine-due
/// notifications also carry the routine row to highlight after the push.
struct BotInfoPresentationRequest: Identifiable, Equatable {
    let id = UUID()
    var section: BotInfoSection?
    var routineID: String?
}

/// Bot 信息: the avatar and name on top, the name editor, then the Bot's own
/// data (memory, routines, approvals). Same grouped-list chrome as 我的.
struct BotInfoPage: View {
    @ObservedObject var model: BotInfoModel
    let isMainBot: Bool
    let highlightRoutineID: String?
    let onDelete: (() async throws -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var path: [BotInfoSection]
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var deleteError: String?

    init(model: BotInfoModel, isMainBot: Bool = false,
         initialSection: BotInfoSection? = nil,
         highlightRoutineID: String? = nil,
         onDelete: (() async throws -> Void)? = nil) {
        self.model = model
        self.isMainBot = isMainBot
        self.highlightRoutineID = highlightRoutineID
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
                    Text("点选即保存。")
                }

                Section {
                    BotPresenceSection(model: model)
                } header: {
                    Text("在场")
                } footer: {
                    Text("前台全功能；后台保活靠静音音频继续运行；App 被挂起或杀掉后只能靠预定的本地通知提醒 routine 到期。")
                }

                Section {
                    BotDisruptionSection(model: model)
                } header: {
                    Text("打扰")
                } footer: {
                    Text("设置对所有 Bot 生效，改动立即持久化。勿扰关闭所有主动提醒和 routine 到期通知；安静时段延后非紧急提醒，紧急 routine 仍按理由放行。什么值得说、什么算紧急属于记忆偏好，不在这里编辑。")
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
                    NavigationLink(value: BotInfoSection.grants) {
                        BotInfoEntryLabel(title: "常设授权", systemImage: "key", state: model.approvalsState,
                                          count: model.grants.count)
                    }
                    .accessibilityIdentifier("bot.info.grants")
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
                        .buttonStyle(BotDestructiveButtonStyle(fillsWidth: true))
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
                case .grants: BotGrantsPage(model: model)
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
                // Mutating an @ObservedObject during view construction
                // invalidates the graph that is building this view. Apply the
                // deep-link highlight only after the view is installed.
                if model.highlightedRoutineID != highlightRoutineID {
                    model.highlightedRoutineID = highlightRoutineID
                }
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

    private static func timeText(_ milliseconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000))
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
    @State private var forgetting: BotMemoryDocumentInfo?
    @State private var confirmErase = false
    @State private var confirmShared = false
    @State private var confirmSharedAgain = false
    @State private var confirmRollback = false

    private var botDocuments: [BotMemoryDocumentInfo] {
        model.memories.filter { $0.scope != "user" }
    }

    private var sharedDocuments: [BotMemoryDocumentInfo] {
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
                Section {
                    Toggle("后台记忆整理", isOn: Binding(
                        get: { model.maintenanceEnabled },
                        set: { value in
                            Task { await model.setMaintenanceEnabled(value) }
                        }))
                        .accessibilityIdentifier("bot.memory.maintenance.toggle")
                } header: {
                    Text("后台整理")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("默认关闭。开启后，只在对话安静、没有待审批且 App 在前台时，宿主才会发起一次独立的后台会话，对照原始记录整理记忆。每次运行是一个批次，检查不过会整批回滚。")
                        if model.maintenanceDailyBudget > 0 {
                            let exhausted = model.maintenanceDailyTokens >= model.maintenanceDailyBudget
                            Text(exhausted
                                 ? "今日整理预算已用完（\(model.maintenanceDailyTokens)/\(model.maintenanceDailyBudget) token）。"
                                 : "今日整理已用 \(model.maintenanceDailyTokens)/\(model.maintenanceDailyBudget) token。")
                                .foregroundStyle(exhausted ? BotUIPalette.danger : HomeSpec.textTertiary)
                                .accessibilityIdentifier("bot.memory.maintenance.budget")
                        }
                    }
                }
                if let batch = model.maintenance {
                    maintenanceSection(batch)
                }
                if botDocuments.isEmpty && sharedDocuments.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("还没有已保存的记忆。")
                                .foregroundStyle(HomeSpec.textSecondary)
                            Text("本 Bot 自己的文档和所有 Bot 共享的文档都会显示在这里；两个根下的 INDEX.md 是每回合注入的索引。")
                                .botCaptionFont()
                                .foregroundStyle(HomeSpec.textTertiary)
                        }
                    }
                } else {
                    memorySection(
                        title: "本 Bot 的工作知识（agent/）",
                        documents: botDocuments,
                        footer: "只属于这个 Bot；其他 Bot 看不到。Task 和 routine 只能提交到 agent/inbox/<会话>/。",
                        eraseTitle: "抹除这个 Bot 的 agent 文档（含全部版本）",
                        eraseIdentifier: "bot.memory.erase") {
                        confirmErase = true
                    }
                    memorySection(
                        title: "共享的用户记忆（user/）",
                        documents: sharedDocuments,
                        footer: "user/ 是所有 Bot 共享、彼此可见的一份文档树；清除后每个 Bot 都会失去这些内容。",
                        eraseTitle: "抹除所有 Bot 共享的 user/ 文档（含全部版本）",
                        eraseIdentifier: "bot.memory.erase.shared") {
                        confirmShared = true
                    }
                }
            }
        }
        .homeGroupedList()
        .navigationTitle("记忆")
        .navigationDestination(for: BotMemoryDocumentInfo.self) { document in
            BotMemoryDocumentView(
                document: document,
                onForget: { forgetting = document },
                onErase: { Task { await model.erase(document) } }
            )
        }
        .confirmationDialog("回滚这次整理？", isPresented: $confirmRollback) {
            Button("整批回滚", role: .destructive) {
                Task { await model.rollbackMaintenance() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("本批改动过的每份文档都会恢复到整理前的版本；之后又被改过的文档会保留并报告冲突。")
        }
        .confirmationDialog("忘记这份文档？", isPresented: Binding(
            get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }
        )) {
            Button("忘记", role: .destructive) {
                if let forgetting { Task { await model.forget(forgetting) } }
                forgetting = nil
            }
            Button("取消", role: .cancel) { forgetting = nil }
        } message: {
            Text("忘记只移除当前版本：历史版本、原始记录和已经写入事件载荷里的内容仍保留。")
        }
        .confirmationDialog("抹除这个 Bot 的 agent 记忆？", isPresented: $confirmErase) {
            Button("抹除本 Bot 的 agent/ 文档", role: .destructive) { Task { await model.erase() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("物理删除这个 Bot 的 agent/ 文档树和全部历史版本，并清除事件载荷及派生视图中与它们相同的内容。共享 user/ 不受影响。已关闭会话里的对应聊天原文也会被墓碑替换；对话会接续到新会话。此操作不可撤销。")
        }
        .confirmationDialog("抹除所有 Bot 共享的 user/ 文档？", isPresented: $confirmShared) {
            Button("继续", role: .destructive) {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    confirmSharedAgain = true
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会影响每一个 Bot：共享 user/ 文档树和全部历史版本会被物理删除；已关闭会话里的对应聊天原文也会被墓碑替换。此操作不可撤销。")
        }
        .confirmationDialog("最后确认：抹除全部共享 user/ 记忆？", isPresented: $confirmSharedAgain) {
            Button("抹除共享 user/ 记忆", role: .destructive) { Task { await model.eraseShared() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("物理删除所有 Bot 共享的 user/ 文档树、全部历史版本，并清除事件载荷及派生视图中与它们相同的内容。所有 Bot 会立即失去这些记忆。已关闭会话里的对应聊天原文也会被墓碑替换。此操作不可撤销。")
        }
    }

    @ViewBuilder
    private func maintenanceSection(_ batch: BotMaintenanceBatchInfo) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(maintenanceStatusLabel(batch.status, rolledBack: batch.rolledBack))
                        .foregroundStyle(HomeSpec.textPrimary)
                    Spacer()
                    Text(BotUIFormat.dateTime(batch.finishedAt))
                        .botCaptionFont()
                        .foregroundStyle(HomeSpec.textTertiary)
                }
                Text("\(batch.changedDocuments) 份文档 · \(batch.tokensUsed) token · 检查\(batch.checksPassed ? "通过" : "未通过")")
                    .botCaptionFont()
                    .foregroundStyle(HomeSpec.textTertiary)
                ForEach(batch.changes) { change in
                    Text("\(change.deleted ? "删除" : "v\(change.beforeVersion)→v\(change.afterVersion)") · \(change.path)")
                        .botCaptionFont()
                        .foregroundStyle(HomeSpec.textSecondary)
                }
                if let failure = batch.failureCode, !failure.isEmpty {
                    Text("失败原因：\(failure)")
                        .botCaptionFont()
                        .foregroundStyle(BotUIPalette.danger)
                }
            }
            .accessibilityIdentifier("bot.memory.maintenance.batch")
            if batch.canRollback {
                Button("回滚这次整理", role: .destructive) {
                    confirmRollback = true
                }
                .accessibilityIdentifier("bot.memory.maintenance.rollback")
            }
        } header: {
            Text("上次整理")
        } footer: {
            Text(batch.rolledBack
                 ? "这一批已整批回滚，历史仍保留在记录里。"
                 : "只显示最近一次批次；本批的每一次写入都带版本前提和引用。")
        }
    }

    private func maintenanceStatusLabel(_ status: String, rolledBack: Bool) -> String {
        if rolledBack { return "已回滚" }
        switch status {
        case "committed": return "已完成"
        case "cancelled": return "已取消（已写入的保留）"
        case "failed": return "未完成"
        case "rolled_back": return "已整批回滚"
        case "rollback_failed": return "回滚有冲突"
        default: return status
        }
    }

    @ViewBuilder
    private func memorySection(
        title: String,
        documents: [BotMemoryDocumentInfo],
        footer: String,
        eraseTitle: String,
        eraseIdentifier: String,
        onErase: @escaping () -> Void
    ) -> some View {
        Section {
            if documents.isEmpty {
                Text("这个根下还没有文档。")
                    .foregroundStyle(HomeSpec.textSecondary)
            } else {
                ForEach(BotMemoryTreeItem.build(documents: documents)) { item in
                    BotMemoryTreeRowView(item: item) { document in
                        forgetting = document
                    }
                }
                Button(eraseTitle, role: .destructive, action: onErase)
                    .accessibilityIdentifier(eraseIdentifier)
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }

}

private struct BotMemoryTreeRowView: View {
    let item: BotMemoryTreeItem
    let onForget: (BotMemoryDocumentInfo) -> Void
    @State private var expanded = true

    var body: some View {
        if item.isDirectory {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(item.children) { child in
                    BotMemoryTreeRowView(item: child, onForget: onForget)
                }
            } label: {
                Label(item.name, systemImage: "folder")
                    .foregroundStyle(HomeSpec.textPrimary)
            }
        } else if let document = item.document {
            NavigationLink(value: document) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(HomeSpec.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(document.fileName)
                            .foregroundStyle(HomeSpec.textPrimary)
                        Text("v\(document.version) · \(BotUIFormat.dateTime(document.updatedAt)) · \(evidenceLabel(document))")
                            .botCaptionFont()
                            .foregroundStyle(HomeSpec.textTertiary)
                    }
                }
            }
            .accessibilityIdentifier("bot.memory.document.\(document.path)")
            .swipeActions {
                Button("忘记", role: .destructive) { onForget(document) }
            }
        }
    }

    private func evidenceLabel(_ document: BotMemoryDocumentInfo) -> String {
        document.evidence.isEmpty ? "无引用" : "\(document.evidence.count) 条引用"
    }
}

private struct BotMemoryDocumentView: View {
    let document: BotMemoryDocumentInfo
    let onForget: () -> Void
    let onErase: () -> Void
    @State private var confirmErase = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Text(document.content.isEmpty ? "（空文档）" : document.content)
                    .botBodyFont()
                    .foregroundStyle(HomeSpec.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("正文")
            } footer: {
                Text("路径：\(document.path)")
            }

            Section("来源") {
                if document.evidence.isEmpty {
                    Text("没有 record:// 引用：这是 agent 的推断或当前 Bot 直接写的。")
                        .foregroundStyle(HomeSpec.textSecondary)
                } else {
                    ForEach(document.evidence, id: \.self) { reference in
                        Text(reference)
                            .font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                LabeledContent("作者", value: document.author)
                LabeledContent("更新时间", value: BotUIFormat.dateTime(document.updatedAt))
            }

            Section("版本") {
                ForEach(document.versions.sorted { $0.version > $1.version }) { version in
                    DisclosureGroup {
                        Text(version.deleted
                             ? "这一版已删除（\(version.deletionReason ?? "forget")）。"
                             : (version.content.isEmpty ? "（空文档）" : version.content))
                            .botBodyFont()
                            .foregroundStyle(version.deleted ? HomeSpec.textSecondary : HomeSpec.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !version.evidence.isEmpty {
                            ForEach(version.evidence, id: \.self) { reference in
                                Text(reference)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(HomeSpec.textTertiary)
                            }
                        }
                    } label: {
                        HStack {
                            Text("v\(version.version)")
                                .foregroundStyle(HomeSpec.textPrimary)
                            if version.version == document.version { Text("当前").botCaptionFont() }
                            Spacer()
                            Text(BotUIFormat.dateTime(version.updatedAt))
                                .botCaptionFont()
                                .foregroundStyle(HomeSpec.textTertiary)
                            if version.deleted {
                                Image(systemName: "trash")
                                    .foregroundStyle(HomeSpec.textTertiary)
                            }
                        }
                    }
                }
            }

            Section {
                Button("忘记这份文档", role: .destructive) {
                    onForget()
                    dismiss()
                }
                .accessibilityIdentifier("bot.memory.document.forget")
                Button("抹除这份文档和全部历史版本", role: .destructive) {
                    confirmErase = true
                }
                .accessibilityIdentifier("bot.memory.document.erase")
            } footer: {
                Text("忘记只移除当前版本；历史版本和原始记录仍保留。抹除会物理删除这份文档、全部历史版本，以及事件载荷和派生视图中与它相同的内容；已关闭会话里的对应聊天原文也会被墓碑替换，对话会接续到新会话。抹除不可撤销。")
            }
        }
        .confirmationDialog("抹除这份文档？", isPresented: $confirmErase) {
            Button("抹除文档和全部版本", role: .destructive) {
                onErase()
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("物理删除 \(document.path) 的全部版本，并清除事件载荷和派生视图中与它相同的内容。共享记忆的其他文档不受影响；已关闭会话里的对应聊天原文也会被墓碑替换。此操作不可撤销。")
        }
        .homeGroupedList()
        .navigationTitle(document.path)
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension BotMemoryTreeItem {
    static func build(documents: [BotMemoryDocumentInfo]) -> [BotMemoryTreeItem] {
        build(documents: documents, prefix: "")
    }

    private static func build(documents: [BotMemoryDocumentInfo], prefix: String) -> [BotMemoryTreeItem] {
        var names: [String: (isDirectory: Bool, document: BotMemoryDocumentInfo?)] = [:]
        for document in documents where document.path.hasPrefix(prefix) {
            let remainder = document.path.dropFirst(prefix.count)
            guard !remainder.isEmpty else { continue }
            let pieces = remainder.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard let head = pieces.first, !head.isEmpty else { continue }
            let isDirectory = pieces.count > 1
            names[String(head)] = (isDirectory, isDirectory ? nil : document)
        }
        return names.keys.sorted().map { name in
            let childPath = prefix + name
            let entry = names[name]!
            if entry.isDirectory {
                return BotMemoryTreeItem(
                    id: childPath, name: name, isDirectory: true, document: nil,
                    children: build(documents: documents, prefix: childPath + "/"))
            }
            return BotMemoryTreeItem(
                id: childPath, name: name, isDirectory: false,
                document: entry.document, children: [])
        }
    }
}

private struct BotRoutinesPage: View {
    @ObservedObject var model: BotInfoModel
    @State private var confirmingCancel: BotRoutineInfo?

    var body: some View {
        ScrollViewReader { proxy in
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
                        routineRow(routine)
                            .id("bot.routine.row.\(routine.id)")
                            .accessibilityIdentifier("bot.routine.row.\(routine.id)")
                            .listRowBackground(model.highlightedRoutineID == routine.id
                                               ? HomeSpec.userBubble : nil)
                    }
                }
            }
        }
        .homeGroupedList()
        .navigationTitle("例行任务")
        .task {
            guard let id = model.highlightedRoutineID else { return }
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation { proxy.scrollTo("bot.routine.row.\(id)", anchor: .center) }
        }
        .onChange(of: model.highlightedRoutineID) { _, newValue in
            guard let id = newValue else { return }
            withAnimation { proxy.scrollTo("bot.routine.row.\(id)", anchor: .center) }
        }
        .confirmationDialog("取消这次运行？", isPresented: Binding(
            get: { confirmingCancel != nil }, set: { if !$0 { confirmingCancel = nil } }
        )) {
            Button("取消运行", role: .destructive) {
                if let routine = confirmingCancel {
                    Task { await model.cancelRoutine(routine) }
                }
                confirmingCancel = nil
            }
            Button("返回", role: .cancel) { confirmingCancel = nil }
        } message: {
            Text("正在执行的回合会被中止；已经产生的效果会保留。")
        }
        }
    }

    @ViewBuilder
    private func routineRow(_ routine: BotRoutineInfo) -> some View {
        let reconciliation = model.reconciliation(for: routine)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(routine.title)
                    .botTitleFont()
                    .foregroundStyle(HomeSpec.textPrimary)
                Spacer()
                BotStatusPill(text: routineStatus(routine), tone: routineTone(routine))
            }
            LabeledContent("排程", value: routine.schedule)
            LabeledContent("时区", value: routine.timeZone)
            LabeledContent("交付", value: routine.delivery)
            if let creator = routine.creator {
                LabeledContent("设立者", value: creator)
            }
            if let criteria = routine.completionCriteria, !criteria.isEmpty {
                LabeledContent("完成条件", value: criteria)
            }
            if let constraints = routine.routineConstraints, !constraints.isEmpty {
                LabeledContent("约束", value: constraints)
            }
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

            if routine.runStatus == "started" || routine.runStatus == "waiting-approval" {
                Button("取消运行") { confirmingCancel = routine }
                    .buttonStyle(BotTextButtonStyle())
                    .botHitTarget()
                    .accessibilityIdentifier("bot.routine.cancel.\(routine.id)")
            }
            if routine.runStatus == "needs-reconciliation", let reconciliation {
                VStack(alignment: .leading, spacing: 6) {
                    Label("执行结果未知，需要确认", systemImage: "exclamationmark.triangle")
                        .botCaptionFont()
                        .foregroundStyle(NativeParityTokens.warning)
                    if let summary = reconciliation.effectSummary {
                        Text("已产生的效果：\(summary)")
                            .botCaptionFont()
                            .foregroundStyle(HomeSpec.textSecondary)
                    }
                    if let error = reconciliation.error {
                        Text("原因：\(error)")
                            .botCaptionFont()
                            .foregroundStyle(HomeSpec.textSecondary)
                    }
                    HStack(spacing: 16) {
                        Button("确认完成") {
                            Task { await model.resolve(reconciliation, decision: "acknowledge") }
                        }
                        .buttonStyle(BotTextButtonStyle())
                        .botHitTarget()
                        .accessibilityIdentifier("bot.routine.reconcile.ack.\(routine.id)")
                        Button("重试") {
                            Task { await model.resolve(reconciliation, decision: "retry") }
                        }
                        .buttonStyle(BotTextButtonStyle())
                        .botHitTarget()
                        .accessibilityIdentifier("bot.routine.reconcile.retry.\(routine.id)")
                    }
                }
            }
            Button(routine.enabled ? "暂停" : "恢复") {
                Task { await model.setRoutine(routine, enabled: !routine.enabled) }
            }
            .buttonStyle(BotTextButtonStyle())
            .botHitTarget()
            .accessibilityIdentifier("bot.routine.toggle.\(routine.id)")
        }
        .padding(.vertical, 4)
    }

    private func routineStatus(_ routine: BotRoutineInfo) -> String {
        switch routine.runStatus {
        case "started": return "运行中"
        case "waiting-approval": return "等待审批"
        case "needs-reconciliation": return "待确认"
        case "scheduled": return "等待触发"
        default: return routine.enabled ? "已启用" : "已暂停"
        }
    }

    private func routineTone(_ routine: BotRoutineInfo) -> BotStatusTone {
        switch routine.runStatus {
        case "started": return .accent
        case "needs-reconciliation": return .warning
        default: return routine.enabled ? .success : .neutral
        }
    }
}

private struct BotGrantsPage: View {
    @ObservedObject var model: BotInfoModel

    var body: some View {
        List {
            switch model.approvalsState {
            case .loading:
                ProgressView().frame(maxWidth: .infinity)
            case .failed(let message):
                BotFailureRow(message: "常设授权读取失败：\(message)。这不代表没有授权。") {
                    Task { await model.refresh() }
                }
                .listRowBackground(Color.clear)
            case .loaded:
                loadedContent
            }
        }
        .homeGroupedList()
        .navigationTitle("常设授权")
    }

    @ViewBuilder
    private var loadedContent: some View {
            if model.grants.isEmpty {
                Text("还没有常设授权。一次性授权只在执行时有效，不会出现在这里。")
                    .foregroundStyle(HomeSpec.textSecondary)
            } else {
                Section {
                    ForEach(model.grants) { grant in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(grant.tool)
                                    .botTitleFont()
                                    .foregroundStyle(HomeSpec.textPrimary)
                                Spacer()
                                BotStatusPill(text: grant.scope, tone: .neutral)
                            }
                            Text("\(grant.operation) · \(grant.resource)")
                                .botCaptionFont()
                                .foregroundStyle(HomeSpec.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("来源：\(grant.source) · \(BotUIFormat.dateTime(grant.createdAt))")
                                .botCaptionFont()
                                .foregroundStyle(HomeSpec.textTertiary)
                            Button("撤销这条授权", role: .destructive) {
                                Task { await model.revocation(of: grant) }
                            }
                            .buttonStyle(BotTextButtonStyle())
                            .botHitTarget()
                            .accessibilityIdentifier("bot.grant.revoke.\(grant.id)")
                        }
                        .padding(.vertical, 4)
                    }
                } footer: {
                    Text("撤销后，同一操作需要重新审批；常设授权只属于这个 Bot。")
                }
            }
    }
}

struct BotPresenceSection: View {
    @ObservedObject var model: BotInfoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("当前级别", value: model.presence.level.displayName)
                .accessibilityIdentifier("bot.info.presence.level")
            if model.presence.level == .scheduledNotification {
                LabeledContent("预定通知", value: "\(model.presence.scheduledNotificationCount) 条")
                    .accessibilityIdentifier("bot.info.presence.notifications")
            }
            if model.presence.deferred.isEmpty {
                Text("没有因安静时段延后的例行任务。")
                    .botCaptionFont()
                    .foregroundStyle(HomeSpec.textSecondary)
            } else {
                ForEach(model.presence.deferred) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .botSecondaryFont(weight: .medium)
                            .foregroundStyle(HomeSpec.textPrimary)
                        Text("原定 \(Self.timeText(item.scheduledFor))，延后到 \(Self.timeText(item.deferredUntil))")
                            .botCaptionFont()
                            .foregroundStyle(HomeSpec.textSecondary)
                    }
                    .accessibilityIdentifier("bot.info.presence.deferred.\(item.routineId)")
                }
            }
        }
        .accessibilityIdentifier("bot.info.presence")
    }

    private static func timeText(_ milliseconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000))
    }
}

struct BotDisruptionSection: View {
    @ObservedObject var model: BotInfoModel

    var body: some View {
        Toggle("勿扰", isOn: Binding(
            get: { model.proactiveSettings.dnd },
            set: { value in Task { await model.setDND(value) } }))
            .accessibilityIdentifier("bot.info.dnd")
        DatePicker("安静时段开始",
                   selection: Binding(
                       get: { model.quietStartDate },
                       set: { value in Task { await model.setQuietStart(value) } }),
                   displayedComponents: .hourAndMinute)
            .accessibilityIdentifier("bot.info.quiet.start")
        DatePicker("安静时段结束",
                   selection: Binding(
                       get: { model.quietEndDate },
                       set: { value in Task { await model.setQuietEnd(value) } }),
                   displayedComponents: .hourAndMinute)
            .accessibilityIdentifier("bot.info.quiet.end")
    }
}

private extension RoutinePresenceLevel {
    var displayName: String {
        switch self {
        case .foreground: return "前台"
        case .backgroundKeepAlive: return "后台保活"
        case .scheduledNotification: return "预定通知"
        }
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
                                Text(BotUIFormat.dateTime(record.decidedAt))
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

/// The appearance editor: the four hairstyles as 40pt fish thumbnails in the
/// current color and the fifteen color dots. The page header already shows the
/// 80pt avatar, so the shared picker's own preview is turned off here. Every
/// tap saves immediately through `BotInfoModel`; no "auto" choice is exposed
/// (the model keeps nil for the future multi-Bot import path).
private struct BotAppearanceEditor: View {
    @ObservedObject var model: BotInfoModel

    var body: some View {
        BotAppearancePicker(
            appearance: model.appearance,
            isMainBot: model.isMainBot,
            showsPreview: false,
            onSelectColor: { color in Task { await model.select(color: color) } },
            onSelectHairstyle: { hairstyle in Task { await model.select(hairstyle: hairstyle) } })
    }
}
