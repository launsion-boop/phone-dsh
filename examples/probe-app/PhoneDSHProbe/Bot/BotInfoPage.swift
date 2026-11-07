// SPDX-License-Identifier: MIT

import Combine
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
    var erase: () async throws -> Void
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

    private let driver: BotInfoDriver?
    private let fixtureError: String?

    init(snapshot: BotInfoSnapshot? = nil, driver: BotInfoDriver? = nil, fixtureError: String? = nil) {
        let name = snapshot?.botName ?? "大肥鱼"
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
        self.driver = driver
        self.fixtureError = fixtureError
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
            botName = snapshot.botName
            draftName = snapshot.botName
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

    func erase() async {
        do {
            try await driver?.erase()
            memories = []
        } catch {
            actionError = "抹除失败：\(error.localizedDescription)"
        }
    }

    func setRoutine(_ routine: BotRoutineInfo, enabled: Bool) async {
        do {
            try await driver?.setRoutineEnabled(routine.id, enabled)
            guard let index = routines.firstIndex(where: { $0.id == routine.id }) else { return }
            routines[index].enabled = enabled
        } catch {
            actionError = "Routine 更新失败：\(error.localizedDescription)"
        }
    }
}

struct BotInfoPage: View {
    @ObservedObject var model: BotInfoModel

    var body: some View {
        NavigationStack {
            List {
                Section("Bot") {
                    HStack(spacing: 12) {
                        BotStaticAvatar(size: 48)
                        TextField("Bot 名", text: $model.draftName)
                            .textInputAutocapitalization(.never)
                            .accessibilityIdentifier("bot.info.name")
                    }
                    Button("保存名称") { Task { await model.rename() } }
                        .disabled(model.draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("bot.info.rename")
                }
                Section("数据") {
                    NavigationLink {
                        BotMemoryPage(model: model)
                    } label: {
                        BotInfoEntryLabel(title: "记忆", systemImage: "brain", state: model.memoryState,
                                          count: model.memories.count)
                    }
                    .accessibilityIdentifier("bot.info.memory")
                    NavigationLink {
                        BotRoutinesPage(model: model)
                    } label: {
                        BotInfoEntryLabel(title: "Routines", systemImage: "repeat", state: model.routinesState,
                                          count: model.routines.count)
                    }
                    .accessibilityIdentifier("bot.info.routines")
                    NavigationLink {
                        BotApprovalHistoryPage(model: model)
                    } label: {
                        BotInfoEntryLabel(title: "审批记录", systemImage: "checkmark.shield", state: model.approvalsState,
                                          count: model.approvals.count)
                    }
                    .accessibilityIdentifier("bot.info.approvals")
                }
                if let error = model.actionError {
                    Section {
                        Text(error)
                            .foregroundStyle(NativeParityTokens.error)
                            .botSecondaryFont()
                    }
                }
            }
            .homeGroupedList()
            .navigationTitle("Bot 信息")
            .toolbar { Button("刷新") { Task { await model.refresh() } } }
            .task {
                if model.memoryState == .loading { await model.refresh() }
            }
        }
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
                .frame(width: 24)
            Text(title)
            Spacer()
            switch state {
            case .loaded: Text("\(count)").foregroundStyle(HomeSpec.textTertiary)
            case .loading: ProgressView()
            case .failed: Text("读取失败").foregroundStyle(NativeParityTokens.error)
            }
        }
        .frame(minHeight: 44)
    }
}

private struct BotMemoryPage: View {
    @ObservedObject var model: BotInfoModel
    @State private var forgetting: BotMemoryFact?
    @State private var confirmErase = false

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
                if model.memories.isEmpty {
                    Text("还没有已保存的记忆。")
                        .foregroundStyle(HomeSpec.textSecondary)
                } else {
                    ForEach(model.memories) { fact in
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
                    Button("抹除全部记忆", role: .destructive) { confirmErase = true }
                        .disabled(model.memories.isEmpty)
                        .accessibilityIdentifier("bot.memory.erase")
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
        .confirmationDialog("抹除这个 Bot 的全部记忆？", isPresented: $confirmErase) {
            Button("全部抹除", role: .destructive) { Task { await model.erase() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会移除 facts 和派生视图，不能在页面内回滚。")
        }
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
                BotFailureRow(message: "Routines 读取失败：\(message)。这不代表没有例行任务。") {
                    Task { await model.refresh() }
                }
                .listRowBackground(Color.clear)
            case .loaded:
                if model.routines.isEmpty {
                    Text("还没有 Routines。")
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
        .navigationTitle("Routines")
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
