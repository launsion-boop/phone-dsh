// SPDX-License-Identifier: MIT

import Combine
import PhoneDSHBot
import SwiftUI

/// One sentence appended to every erasure confirmation. The erasure scope is
/// the session logs and memory documents (P02 §5.3); the App's tool operation
/// journal is outside that scope and may still hold the original text. The
/// wording is user-facing only and never exposes the journal path.
private let botErasureToolLogNotice = "；App 内部的操作日志可能仍保留原文。"

/// Fixture-only seam: open one erasure confirmation directly so the UI capture
/// proves the appended scope sentence without driving a destructive action.
enum BotMemoryConfirmationPreview: Equatable {
    case eraseMemory
    case eraseShared
    case eraseSharedFinal
}

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
    /// Human-readable creator source for the main row. Raw references belong
    /// to `creatorDetail` and stay in the routine detail disclosure.
    var creator: String?
    var completionCriteria: String?
    var routineConstraints: String?
    var runStatus: String?
    var runID: String?
    var nextDue: Date?
    var quietDeferredFrom: Date?
    var quietDeferredUntil: Date?
    var creatorDetail: String?
    /// Raw error behind `lastResult`; display-only, never in the main row.
    var lastResultDetail: String?
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
    /// Human-readable effect summary shown in the one reconciliation block.
    var effectSummary: String?
    /// Raw effect record (`operation · target · reason`) for the detail
    /// disclosure; never shown in the main row.
    var effectDetail: String?
}

struct BotApprovalRecord: Identifiable, Equatable {
    let id: String
    var parameterSummary: String
    var decision: String
    /// Durable reason code for a cancellation; mapped to one human sentence by
    /// `BotApprovalReceipt.cancellationReason` in the row.
    var reason: String? = nil
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
    /// One human-readable line from the host's last failed identity
    /// registration; nil when the runtime has no current bridge error.
    var bridgeStatus: String?
    /// Per-entry failures. Each entry is independent: one failed projection
    /// must not mark the other pages as failed. The value is human-facing
    /// copy; the host logs the raw error separately.
    var memoryError: String? = nil
    var routinesError: String? = nil
    var approvalsError: String? = nil
    var grantsError: String? = nil
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
    @Published private(set) var bridgeStatus: String?
    @Published var highlightedRoutineID: String?
    @Published private(set) var memoryState: BotInfoLoadState
    @Published private(set) var routinesState: BotInfoLoadState
    @Published private(set) var approvalsState: BotInfoLoadState
    @Published private(set) var grantsState: BotInfoLoadState
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
        bridgeStatus = snapshot?.bridgeStatus
        let initial: BotInfoLoadState
        if let fixtureError { initial = .failed(fixtureError) }
        else { initial = snapshot == nil && driver != nil ? .loading : .loaded }
        memoryState = initial
        routinesState = initial
        approvalsState = initial
        grantsState = initial
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
                grantsState = .failed(fixtureError)
            } else {
                memoryState = .loaded
                routinesState = .loaded
                approvalsState = .loaded
                grantsState = .loaded
            }
            return
        }
        memoryState = .loading
        routinesState = .loading
        approvalsState = .loading
        grantsState = .loading
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
            bridgeStatus = snapshot.bridgeStatus
            memoryState = snapshot.memoryError.map(BotInfoLoadState.failed) ?? .loaded
            routinesState = snapshot.routinesError.map(BotInfoLoadState.failed) ?? .loaded
            approvalsState = snapshot.approvalsError.map(BotInfoLoadState.failed) ?? .loaded
            grantsState = snapshot.grantsError.map(BotInfoLoadState.failed) ?? .loaded
        } catch {
            // The page never prints a host type name, an English
            // `localizedDescription` or an internal error code. The raw error
            // belongs to the diagnostic log.
            BotRebindDiagnostics.emit(
                "bot-info refresh error=\(String(reflecting: error))")
            let message = "暂时读不出来，请稍后重试。"
            memoryState = .failed(message)
            routinesState = .failed(message)
            approvalsState = .failed(message)
            grantsState = .failed(message)
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
    /// Fixture/preview override for the profile description. Production reads
    /// `BotProfile.description` through the model and leaves this nil.
    private let descriptionOverride: String?
    /// Fixture-only erasure-confirmation preview; production leaves this nil.
    private let memoryConfirmationPreview: BotMemoryConfirmationPreview?
    @Environment(\.dismiss) private var dismiss
    /// A type-erased path: the same stack pushes both `BotInfoSection` and the
    /// memory document detail. A `[BotInfoSection]` path silently refuses the
    /// second value type, which left a tapped memory row highlighted but never
    /// pushed (F5).
    @State private var path = NavigationPath()
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var deleteError: String?

    init(model: BotInfoModel, isMainBot: Bool = false,
         initialSection: BotInfoSection? = nil,
         highlightRoutineID: String? = nil,
         onDelete: (() async throws -> Void)? = nil,
         description: String? = nil,
         memoryConfirmationPreview: BotMemoryConfirmationPreview? = nil) {
        self.model = model
        self.isMainBot = isMainBot
        self.highlightRoutineID = highlightRoutineID
        self.onDelete = onDelete
        self.descriptionOverride = description
        self.memoryConfirmationPreview = memoryConfirmationPreview
        var initialPath = NavigationPath()
        if let initialSection { initialPath.append(initialSection) }
        _path = State(initialValue: initialPath)
    }

    private var nameChanged: Bool {
        let draft = model.draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !draft.isEmpty && draft != model.botName
    }

    private var displayDescription: String {
        let override = descriptionOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !override.isEmpty { return override }
        let profile = model.botDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return profile.isEmpty ? "你的私人 Bot，替你跟进任务和提醒" : profile
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
                            .multilineTextAlignment(.center)
                        Text(displayDescription)
                            .font(.system(size: 14))
                            .foregroundStyle(HomeSpec.textPlaceholder)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                Section {
                    TextField("", text: $model.draftName, prompt: Text("给 Bot 起个名字"),
                              axis: .vertical)
                        .lineLimit(1...4)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("bot.info.name")
                    if nameChanged {
                        Button {
                            Task { await model.rename() }
                        } label: {
                            Text("保存名称").fontWeight(.semibold)
                        }
                        .accessibilityIdentifier("bot.info.rename")
                    }
                } header: {
                    Text("Bot 名称")
                }

                Section {
                    BotAppearanceEditor(model: model)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                } header: {
                    Text("外观")
                }

                Section {
                    BotPresenceSection(model: model)
                } header: {
                    Text("在场")
                }

                Section {
                    BotDisruptionSection(model: model)
                } header: {
                    Text("打扰")
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
                        BotInfoEntryLabel(title: "常设授权", systemImage: "key", state: model.grantsState,
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
                    }
                }
            }
            .homeGroupedList()
            .navigationTitle("Bot 信息")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: BotInfoSection.self) { section in
                switch section {
                case .memory: BotMemoryPage(
                    model: model, preview: memoryConfirmationPreview)
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
                // The sheet can be reopened long after the first load (for
                // example after the Bot created a routine in chat). Re-read the
                // host authority every time it appears; a cached snapshot must
                // not turn a real routine into "还没有例行任务".
                await model.refresh()
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
                Text("删除会中止运行、拒绝待审批、撤销授权、归档会话，并清除这个 Bot 的记忆、例行任务和待处理消息，无法撤销。")
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

extension BotInfoModel {
    /// The profile's free-form description, empty when the profile is absent.
    /// The model already owns the profile center; exposing the value here keeps
    /// the info page from growing a second profile source.
    var botDescription: String {
        profileCenter?.profile?.description ?? ""
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
    private let preview: BotMemoryConfirmationPreview?
    @State private var forgetting: BotMemoryDocumentInfo?
    @State private var confirmErase = false
    @State private var confirmShared = false
    @State private var confirmSharedAgain = false
    @State private var confirmRollback = false

    init(model: BotInfoModel, preview: BotMemoryConfirmationPreview? = nil) {
        self.model = model
        self.preview = preview
    }

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
                BotFailureRow(message: "记忆读取失败：\(message)这不代表没有记忆。") {
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
                    if let budget = maintenanceBudgetText {
                        Text(budget)
                            .foregroundStyle(maintenanceBudgetExhausted
                                             ? BotUIPalette.danger : HomeSpec.textTertiary)
                            .accessibilityIdentifier("bot.memory.maintenance.budget")
                    }
                }
                if let batch = model.maintenance {
                    maintenanceSection(batch)
                }
                if botDocuments.isEmpty && sharedDocuments.isEmpty {
                    Section {
                        Text("还没有已保存的记忆。")
                            .foregroundStyle(HomeSpec.textSecondary)
                    }
                } else {
                    memorySection(
                        title: "本 Bot 的记忆",
                        documents: botDocuments,
                        root: "agent")
                    memorySection(
                        title: "所有 Bot 共享的记忆",
                        documents: sharedDocuments,
                        root: "user")
                    erasureSection
                }
            }
        }
        .homeGroupedList()
        .navigationTitle("记忆")
        .task {
            // Each data entry re-reads the host authority when it appears; a
            // snapshot cached by the sheet must not hide a newer record.
            if model.memoryState != .loading { await model.refresh() }
        }
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
            Text("忘记只移除当前版本，历史版本仍保留。")
        }
        .confirmationDialog("抹除这个 Bot 的记忆？", isPresented: $confirmErase) {
            Button("抹除这个 Bot 的记忆", role: .destructive) { Task { await model.erase() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会永久删除这个 Bot 的记忆和全部历史版本，相关内容也会从旧对话里移除，共享记忆不受影响，无法撤销\(botErasureToolLogNotice)")
        }
        .confirmationDialog("抹除所有 Bot 共享的记忆？", isPresented: $confirmShared) {
            Button("继续", role: .destructive) {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    confirmSharedAgain = true
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有 Bot 共享的记忆和全部历史版本会被永久删除，相关内容也会从旧对话里移除，无法撤销\(botErasureToolLogNotice)")
        }
        .confirmationDialog("最后确认：抹除全部共享记忆？", isPresented: $confirmSharedAgain) {
            Button("抹除共享记忆", role: .destructive) { Task { await model.eraseShared() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有 Bot 会立即失去这些共享记忆，全部历史版本也会被永久删除，无法撤销\(botErasureToolLogNotice)")
        }
        .task {
            // Fixture/preview only: production passes nil and never opens a
            // destructive confirmation by itself.
            guard let preview else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            switch preview {
            case .eraseMemory: confirmErase = true
            case .eraseShared: confirmShared = true
            case .eraseSharedFinal: confirmSharedAgain = true
            }
        }
    }

    private var maintenanceBudgetExhausted: Bool {
        model.maintenanceDailyBudget > 0
            && model.maintenanceDailyTokens >= model.maintenanceDailyBudget
    }

    private var maintenanceBudgetText: String? {
        guard model.maintenanceDailyBudget > 0 else { return nil }
        if maintenanceBudgetExhausted { return "今日整理额度已用完。" }
        let ratio = BotUIFormat.percent(used: model.maintenanceDailyTokens,
                                        total: model.maintenanceDailyBudget)
        return "今日整理额度已用 \(ratio)。"
    }

    private var erasureSection: some View {
        Section {
            if !botDocuments.isEmpty {
                Button("抹除这个 Bot 的记忆（含全部版本）") {
                    confirmErase = true
                }
                .buttonStyle(BotDestructiveButtonStyle())
                .accessibilityIdentifier("bot.memory.erase")
            }
            if !sharedDocuments.isEmpty {
                Button("抹除所有 Bot 共享的记忆（含全部版本）") {
                    confirmShared = true
                }
                .buttonStyle(BotDestructiveButtonStyle())
                .accessibilityIdentifier("bot.memory.erase.shared")
            }
        } header: {
            Text("危险操作")
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
                Text("\(batch.changedDocuments) 份文档 · 检查\(batch.checksPassed ? "通过" : "未通过")")
                    .botCaptionFont()
                    .foregroundStyle(HomeSpec.textTertiary)
                ForEach(batch.changes) { change in
                    Text(maintenanceChangeLabel(change))
                        .botCaptionFont()
                        .foregroundStyle(HomeSpec.textSecondary)
                }
                DisclosureGroup("查看详情") {
                    ForEach(batch.changes) { change in
                        Text(maintenanceChangeDetail(change))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(HomeSpec.textSecondary)
                            .textSelection(.enabled)
                    }
                    if let failure = batch.failureCode, !failure.isEmpty {
                        Text("失败原因：\(failure)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(BotUIPalette.danger)
                            .textSelection(.enabled)
                    }
                    Text("本次用量：\(batch.tokensUsed) token")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(HomeSpec.textSecondary)
                }
                .accessibilityIdentifier("bot.memory.maintenance.detail")
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
        default: return "状态未知"
        }
    }

    private func maintenanceChangeLabel(_ change: BotMaintenanceChangeInfo) -> String {
        let name = maintenanceDocumentName(change.path, scope: change.scope)
        return change.deleted
            ? "\(name)：已删除"
            : "\(name)：第 \(change.beforeVersion) 版 → 第 \(change.afterVersion) 版"
    }

    private func maintenanceChangeDetail(_ change: BotMaintenanceChangeInfo) -> String {
        change.deleted
            ? "\(change.path)：已删除"
            : "\(change.path)：第 \(change.beforeVersion) 版 → 第 \(change.afterVersion) 版"
    }

    /// Main-view label for one maintenance change. The `user/`/`agent/` root
    /// and full path stay in the detail; INDEX.md and profile.md get a purpose
    /// label instead of a bare file name.
    private func maintenanceDocumentName(_ path: String, scope: String) -> String {
        var relative = path
        if relative.hasPrefix("user/") { relative.removeFirst(5) }
        else if relative.hasPrefix("agent/") { relative.removeFirst(6) }
        let fileName = relative.split(separator: "/").last.map(String.init) ?? relative
        let shared = scope == "user" || path.hasPrefix("user/")
        if fileName == "INDEX.md" {
            return shared ? "共享索引 INDEX.md" : "本 Bot 索引 INDEX.md"
        }
        if fileName == "profile.md" {
            return shared ? "共享资料 profile.md" : "本 Bot 资料 profile.md"
        }
        return shared ? "共享记忆 \(relative)" : "本 Bot 记忆 \(relative)"
    }

    @ViewBuilder
    private func memorySection(
        title: String,
        documents: [BotMemoryDocumentInfo],
        root: String
    ) -> some View {
        Section {
            if documents.isEmpty {
                Text("还没有文档。")
                    .foregroundStyle(HomeSpec.textSecondary)
            } else {
                ForEach(BotMemoryTreeItem.build(documents: documents, root: root)) { item in
                    BotMemoryTreeRowView(item: item) { document in
                        forgetting = document
                    }
                }
            }
        } header: {
            Text(title)
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
                        Text("第 \(document.version) 版 · \(BotUIFormat.dateTime(document.updatedAt)) · \(evidenceLabel(document))")
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
        document.evidence.isEmpty ? "无来源" : "\(document.evidence.count) 条来源"
    }
}

struct BotMemoryDocumentView: View {
    let document: BotMemoryDocumentInfo
    let onForget: () -> Void
    let onErase: () -> Void
    /// Fixture-only: open the erasure confirmation on appearance.
    var autoConfirmErase = false
    @State private var confirmErase = false
    @Environment(\.dismiss) private var dismiss

    private var evidenceSummary: String {
        var counts: [String: Int] = [:]
        for reference in document.evidence {
            counts[evidenceKind(reference), default: 0] += 1
        }
        let order = ["对话来源", "记录来源", "其他来源"]
        let parts = order.compactMap { name in
            counts[name].map { "\(name) \($0) 条" }
        }
        return parts.isEmpty ? "无来源" : parts.joined(separator: " · ")
    }

    private func evidenceKind(_ reference: String) -> String {
        if reference.hasPrefix("record://session/") { return "对话来源" }
        if reference.hasPrefix("record://event/") { return "记录来源" }
        return "其他来源"
    }

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

            Section {
                if document.evidence.isEmpty {
                    Text("没有来源引用。")
                        .foregroundStyle(HomeSpec.textSecondary)
                } else {
                    DisclosureGroup {
                        ForEach(document.evidence, id: \.self) { reference in
                            Text(reference)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(HomeSpec.textSecondary)
                                .textSelection(.enabled)
                        }
                    } label: {
                        Text(evidenceSummary)
                            .foregroundStyle(HomeSpec.textPrimary)
                    }
                    .accessibilityIdentifier("bot.memory.document.evidence")
                }
                LabeledContent("作者", value: document.author.isEmpty ? "未知" : document.author)
                LabeledContent("更新时间", value: BotUIFormat.dateTime(document.updatedAt))
            } header: {
                Text("来源")
            }

            Section("版本") {
                ForEach(document.versions.sorted { $0.version > $1.version }) { version in
                    DisclosureGroup {
                        Text(version.deleted
                             ? "这一版已被删除。"
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
                            Text("第 \(version.version) 版")
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
                .buttonStyle(BotDestructiveButtonStyle())
                .accessibilityIdentifier("bot.memory.document.erase")
            }
        }
        .confirmationDialog("抹除这份文档？", isPresented: $confirmErase) {
            Button("抹除文档和全部版本", role: .destructive) {
                onErase()
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会永久删除这份文档和全部历史版本，相关内容也会从旧对话里移除，共享记忆的其他文档不受影响，无法撤销\(botErasureToolLogNotice)")
        }
        .task {
            guard autoConfirmErase else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            confirmErase = true
        }
        .homeGroupedList()
        .navigationTitle(document.fileName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension BotMemoryTreeItem {
    /// Builds the tree below one memory root: the render starts at the root's
    /// children instead of showing an `agent`/`user` folder row that repeats
    /// the section title. Documents outside the requested root (defensive, for
    /// an inconsistent host record) still render from their own root.
    static func build(documents: [BotMemoryDocumentInfo], root: String? = nil) -> [BotMemoryTreeItem] {
        guard let root, !root.isEmpty else {
            return build(documents: documents, prefix: "")
        }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let inside = documents.filter { $0.path.hasPrefix(prefix) }
        let outside = documents.filter { !$0.path.hasPrefix(prefix) }
        return build(documents: inside, prefix: prefix)
            + build(documents: outside, prefix: "")
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
                BotFailureRow(message: "例行任务读取失败：\(message)这不代表没有例行任务。") {
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
            // Entering the data entry re-reads the host authority even when the
            // sheet's shared model is already loaded. The first open is owned
            // by the sheet's root task (state is `.loading`), so this avoids a
            // duplicate initial load while still catching a routine created
            // after the last snapshot.
            if model.routinesState != .loading { await model.refresh() }
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
        let showsReconciliation = routine.runStatus == "needs-reconciliation"
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(routine.title)
                    .botTitleFont()
                    .foregroundStyle(HomeSpec.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                BotStatusPill(text: routineStatus(routine), tone: routineTone(routine))
            }

            VStack(alignment: .leading, spacing: 10) {
                BotDetailField(label: "排程", value: routine.schedule)
                if let nextDue = routine.nextDue {
                    BotDetailField(label: "下次到期", value: BotUIFormat.dateTime(nextDue))
                }
                BotDetailField(label: "时区",
                               value: BotUIFormat.routineTimeZone(routine.timeZone))
                BotDetailField(label: "交付",
                               value: BotUIFormat.routineDelivery(routine.delivery))
                if let from = routine.quietDeferredFrom,
                   let until = routine.quietDeferredUntil {
                    BotDetailField(
                        label: "安静时段延后",
                        value: "原定 \(BotUIFormat.dateTime(from))，延后至 \(BotUIFormat.dateTime(until))",
                        layout: .stacked)
                } else if routine.quiet {
                    Label("安静时段会延后", systemImage: "moon")
                        .botCaptionFont()
                        .foregroundStyle(HomeSpec.textSecondary)
                }
                if let creator = routine.creator, !creator.isEmpty {
                    BotDetailField(label: "设立者", value: creator)
                }
                if let criteria = routine.completionCriteria, !criteria.isEmpty {
                    BotDetailField(
                        label: "完成条件",
                        value: BotUIFormat.routineFreeTextNeedsDetail(criteria)
                            ? routineFreeTextSummary : criteria,
                        layout: .stacked)
                }
                if let constraints = routine.routineConstraints, !constraints.isEmpty {
                    BotDetailField(
                        label: "约束",
                        value: BotUIFormat.routineFreeTextNeedsDetail(constraints)
                            ? routineFreeTextSummary : constraints,
                        layout: .stacked)
                }
            }

            if routine.urgent {
                Label("紧急：\(routine.urgentReason ?? "未说明")", systemImage: "exclamationmark")
                    .botCaptionFont()
                    .foregroundStyle(NativeParityTokens.warning)
            }

            if showsReconciliation {
                reconciliationBlock(reconciliation)
            } else {
                Text(routine.lastResult)
                    .botSecondaryFont()
                    .foregroundStyle(HomeSpec.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            BotRoutineActionArea(
                routine: routine,
                showsReconciliation: showsReconciliation,
                onCancel: { confirmingCancel = routine },
                onAcknowledge: {
                    guard let reconciliation else { return }
                    Task { await model.resolve(reconciliation, decision: "acknowledge") }
                },
                onRetry: {
                    guard let reconciliation else { return }
                    Task { await model.resolve(reconciliation, decision: "retry") }
                },
                onToggle: {
                    Task { await model.setRoutine(routine, enabled: !routine.enabled) }
                })

            routineDetailDisclosure(routine, reconciliation: reconciliation)
        }
        .padding(.vertical, 4)
    }

    private var routineFreeTextSummary: String {
        "原文包含执行提示。"
    }

    @ViewBuilder
    private func reconciliationBlock(_ reconciliation: BotReconciliationInfo?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("这次运行的结果没有确认", systemImage: "exclamationmark.triangle")
                .botSecondaryFont(weight: .medium)
                .foregroundStyle(NativeParityTokens.warning)
            Text(reconciliation?.effectSummary ?? "已尝试执行这次运行，结果未确认。")
                .botSecondaryFont()
                .foregroundStyle(HomeSpec.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = reconciliation?.error,
               let reason = BotUIFormat.routineReconciliationReason(error) {
                Text("原因：\(reason)")
                    .botSecondaryFont()
                    .foregroundStyle(HomeSpec.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NativeParityTokens.warning.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func routineDetailDisclosure(_ routine: BotRoutineInfo,
                                         reconciliation: BotReconciliationInfo?) -> some View {
        let fields = routineRawFields(routine, reconciliation: reconciliation)
        if !fields.isEmpty {
            BotRoutineDetailDisclosure(routineID: routine.id, fields: fields)
        }
    }

    private func routineRawFields(_ routine: BotRoutineInfo,
                                  reconciliation: BotReconciliationInfo?) -> [(String, String)] {
        var fields: [(String, String)] = [("任务编号", routine.id), ("时区标识", routine.timeZone)]
        if let creatorDetail = routine.creatorDetail, !creatorDetail.isEmpty {
            fields.append(("设立者原始信息", creatorDetail))
        }
        if let constraints = routine.routineConstraints,
           BotUIFormat.routineFreeTextNeedsDetail(constraints) {
            fields.append(("约束原文", constraints))
        }
        if let criteria = routine.completionCriteria,
           BotUIFormat.routineFreeTextNeedsDetail(criteria) {
            fields.append(("完成条件原文", criteria))
        }
        if let runID = routine.runID, !runID.isEmpty {
            fields.append(("运行编号", runID))
        }
        if let effectDetail = reconciliation?.effectDetail, !effectDetail.isEmpty {
            fields.append(("效果记录", effectDetail))
        }
        if let error = reconciliation?.error, !error.isEmpty {
            fields.append(("原始原因", error))
        }
        if let lastResultDetail = routine.lastResultDetail, !lastResultDetail.isEmpty {
            fields.append(("上次运行详情", lastResultDetail))
        }
        return fields
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

private enum BotDetailFieldLayout {
    case inline, stacked
}

/// One routine field. Short values keep a stable two-column grid with the
/// label and value both left aligned; long values put the label on its own
/// line above the value. The old `LabeledContent` rows right-aligned short
/// values and switched alignment when a value wrapped.
private struct BotDetailField: View {
    let label: String
    let value: String
    var layout: BotDetailFieldLayout = .inline

    var body: some View {
        Group {
            switch layout {
            case .inline:
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    labelView.frame(width: 64, alignment: .leading)
                    valueView.frame(maxWidth: .infinity, alignment: .leading)
                }
            case .stacked:
                VStack(alignment: .leading, spacing: 6) {
                    labelView
                    valueView
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var labelView: some View {
        Text(label)
            .botSecondaryFont()
            .foregroundStyle(HomeSpec.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var valueView: some View {
        Text(value)
            .botFont(size: 15, lineHeight: 22, style: .subheadline)
            .foregroundStyle(HomeSpec.textPrimary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The routine action area: at most two rows, primary/secondary capsules for
/// the reconciliation decision, then the text-level pause/resume and the red
/// destructive cancel action separated from it.
private struct BotRoutineActionArea: View {
    let routine: BotRoutineInfo
    let showsReconciliation: Bool
    let onCancel: () -> Void
    let onAcknowledge: () -> Void
    let onRetry: () -> Void
    let onToggle: () -> Void

    private var canCancel: Bool {
        routine.runStatus == "started" || routine.runStatus == "waiting-approval"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if showsReconciliation {
                HStack(spacing: 10) {
                    Button("确认完成", action: onAcknowledge)
                        .buttonStyle(BotCardButtonStyle(kind: .primary))
                        .accessibilityIdentifier("bot.routine.reconcile.ack.\(routine.id)")
                    Button("重试", action: onRetry)
                        .buttonStyle(BotCardButtonStyle(kind: .secondary))
                        .accessibilityIdentifier("bot.routine.reconcile.retry.\(routine.id)")
                }
            }
            HStack(spacing: 0) {
                if canCancel {
                    Button("取消运行", action: onCancel)
                        .buttonStyle(BotDestructiveButtonStyle())
                        .accessibilityIdentifier("bot.routine.cancel.\(routine.id)")
                    Divider().frame(height: 20)
                }
                Button(routine.enabled ? "暂停" : "恢复", action: onToggle)
                    .buttonStyle(BotTextButtonStyle())
                    .accessibilityIdentifier("bot.routine.toggle.\(routine.id)")
            }
        }
    }
}

/// The single "详情" surface for raw routine references: ids, the IANA time
/// zone, raw creator/effect records and the unedited constraints. Values are
/// selectable so they can be copied; none of them is printed in the main row.
private struct BotRoutineDetailDisclosure: View {
    let routineID: String
    let fields: [(String, String)]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(expanded ? "收起详情" : "查看详情")
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
            }
            .buttonStyle(BotTextButtonStyle())
            .accessibilityIdentifier("bot.routine.detail.\(routineID)")

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(fields.indices, id: \.self) { index in
                        let field = fields[index]
                        VStack(alignment: .leading, spacing: 3) {
                            Text(field.0)
                                .botCaptionFont()
                                .foregroundStyle(HomeSpec.textSecondary)
                            Text(field.1)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(HomeSpec.textPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HomeSpec.userBubble.opacity(0.6),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

private struct BotGrantsPage: View {
    @ObservedObject var model: BotInfoModel

    var body: some View {
        List {
            switch model.grantsState {
            case .loading:
                ProgressView().frame(maxWidth: .infinity)
            case .failed(let message):
                BotFailureRow(message: "常设授权读取失败：\(message)这不代表没有授权。") {
                    Task { await model.refresh() }
                }
                .listRowBackground(Color.clear)
            case .loaded:
                loadedContent
            }
        }
        .homeGroupedList()
        .navigationTitle("常设授权")
        .task {
            // Each data entry re-reads the host authority when it appears; a
            // snapshot cached by the sheet must not hide a newer record.
            if model.grantsState != .loading { await model.refresh() }
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
            if model.grants.isEmpty {
                Text("还没有常设授权。")
                    .foregroundStyle(HomeSpec.textSecondary)
            } else {
                Section {
                    ForEach(model.grants) { grant in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(BotUIFormat.grantOperationTitle(grant.operation))
                                    .botTitleFont()
                                    .foregroundStyle(HomeSpec.textPrimary)
                                Spacer(minLength: 8)
                                BotStatusPill(text: BotUIFormat.grantScope(grant.scope), tone: .neutral)
                            }
                            Text(BotUIFormat.grantResourceSummary(
                                grant.resource, operation: grant.operation))
                                .botSecondaryFont()
                                .foregroundStyle(HomeSpec.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("来源：\(BotUIFormat.grantSource(grant.source)) · \(BotUIFormat.dateTime(grant.createdAt))")
                                .botCaptionFont()
                                .foregroundStyle(HomeSpec.textTertiary)
                            DisclosureGroup("详情") {
                                VStack(alignment: .leading, spacing: 8) {
                                    grantDetailRow("工具", grant.tool)
                                    grantDetailRow("操作", grant.operation)
                                    grantDetailRow("完整资源", grant.resource)
                                    if let sessionID = grant.sessionID, !sessionID.isEmpty {
                                        grantDetailRow("会话", sessionID)
                                    }
                                }
                                .padding(.top, 4)
                            }
                            .font(.system(size: 13))
                            .foregroundStyle(HomeSpec.textSecondary)
                            .accessibilityIdentifier("bot.grant.detail.\(grant.id)")
                            Rectangle()
                                .fill(HomeSpec.borderList)
                                .frame(height: 0.5)
                            Button("撤销这条授权", role: .destructive) {
                                Task { await model.revocation(of: grant) }
                            }
                            .buttonStyle(BotDestructiveButtonStyle())
                            .accessibilityIdentifier("bot.grant.revoke.\(grant.id)")
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
    }

    /// The raw identifiers, full path/URL and session id stay folded here so
    /// the main row can stay readable. Values remain selectable for support.
    private func grantDetailRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .botCaptionFont()
                .foregroundStyle(HomeSpec.textTertiary)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(HomeSpec.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct BotPresenceSection: View {
    @ObservedObject var model: BotInfoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("当前级别", value: model.presence.level.displayName)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("bot.info.presence.level")
            if let bridgeStatus = model.bridgeStatus {
                LabeledContent("连接状态", value: bridgeStatus)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("bot.info.presence.bridge")
            }
            // The count is host authority, not a level decoration: a foreground
            // App can still have routine-due notifications registered, and the
            // matrix checks this line in the foreground. Show the actual count
            // even when it is zero (permission denied / DND) instead of hiding
            // the row; add the earliest registered fire time when one exists.
            LabeledContent("已登记提醒", value: notificationSummary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("bot.info.presence.notifications")
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
                        Text("原定 \(BotUIFormat.dateTime(Date(timeIntervalSince1970: TimeInterval(item.scheduledFor) / 1_000)))，延后到 \(BotUIFormat.dateTime(Date(timeIntervalSince1970: TimeInterval(item.deferredUntil) / 1_000)))")
                            .botCaptionFont()
                            .foregroundStyle(HomeSpec.textSecondary)
                    }
                    .accessibilityIdentifier("bot.info.presence.deferred.\(item.routineId)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bot.info.presence")
    }

    /// Host-registered count plus the earliest registered time. The time is
    /// shown only when the host has one; the count is never inferred from the
    /// routine list.
    private var notificationSummary: String {
        let count = "\(model.presence.scheduledNotificationCount) 条"
        guard let at = model.presence.nextNotificationAt else { return count }
        let date = Date(timeIntervalSince1970: Double(at) / 1_000)
        return "\(count) · 下次 \(BotUIFormat.dateTime(date))"
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
            .environment(\.locale, BotUIFormat.locale)
            .accessibilityIdentifier("bot.info.quiet.start")
        DatePicker("安静时段结束",
                   selection: Binding(
                       get: { model.quietEndDate },
                       set: { value in Task { await model.setQuietEnd(value) } }),
                   displayedComponents: .hourAndMinute)
            .environment(\.locale, BotUIFormat.locale)
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
                BotFailureRow(message: "审批记录读取失败：\(message)") {
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
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(record.decision)
                                    .botSecondaryFont(weight: .medium)
                                    .foregroundStyle(HomeSpec.textSecondary)
                                Spacer(minLength: 8)
                                Text(BotUIFormat.dateTime(record.decidedAt))
                                    .botCaptionFont()
                                    .foregroundStyle(HomeSpec.textTertiary)
                            }
                            // F7: a cancelled decision must say why in one
                            // human sentence. Old events may have no reason;
                            // they still get the generic sentence instead of
                            // leaking a raw code or showing nothing.
                            if record.decision.hasPrefix("已取消") {
                                Text("原因：\(BotApprovalReceipt.cancellationReason(record.reason) ?? "审批已取消")")
                                    .botCaptionFont()
                                    .foregroundStyle(HomeSpec.textTertiary)
                                    .accessibilityIdentifier("bot.approval.reason.\(record.id)")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .homeGroupedList()
        .navigationTitle("审批记录")
        .task {
            // Each data entry re-reads the host authority when it appears; a
            // snapshot cached by the sheet must not hide a newer record.
            if model.approvalsState != .loading { await model.refresh() }
        }
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
