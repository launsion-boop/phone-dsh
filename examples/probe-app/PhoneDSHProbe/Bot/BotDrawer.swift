// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHBot
import SwiftUI

/// The App-side write surface the drawer needs. Reading always comes from the
/// one `BotRosterModel`; this only names the mutations so the capture fixtures
/// and the production hub can wire the same view to different hosts.
struct BotDrawerActions {
    var select: (String) -> Void = { _ in }
    var create: (String, BotFishColor, BotFishHairstyle) async throws -> BotProfile = { _, _, _ in
        throw BotDrawerError.unavailable
    }
    var rename: (String, String) async throws -> Void = { _, _ in }
    var setMain: (String) async -> Void = { _ in }
    var setHidden: (String, Bool) async -> Void = { _, _ in }
    var delete: (String) async throws -> Void = { _ in }
    var appearance: (String) -> Void = { _ in }
    var manage: () -> Void = {}
    var retry: () -> Void = {}
    var close: () -> Void = {}
}

enum BotDrawerError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Bot 运行时还没有准备好。"
        }
    }
}

enum BotAddValidation {
    static let maxNameLength = 60

    static func trimmed(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Matches `BotProfileStore.validateName`: UTF-16 units, like dsh-bot's
    /// record limit, not grapheme clusters.
    static func problem(for name: String) -> String? {
        let value = trimmed(name)
        if value.isEmpty { return "名称不能为空。" }
        if value.utf16.count > maxNameLength {
            return "名称最多 \(maxNameLength) 个字符，当前 \(value.utf16.count) 个。"
        }
        return nil
    }
}

/// The drawer panel: same width, corners, scrim target and accessibility
/// contract as `SessionsDrawerPanel`. Only the content differs; NativeShell
/// owns the slide/scrim/persistent mechanics for both panels.
struct BotDrawerPanel: View {
    @Binding var isOpen: Bool
    var topInset: CGFloat
    var bottomInset: CGFloat = 0
    var isPersistent = false
    var roster: BotRosterModel?
    var error: String?
    var actions = BotDrawerActions()
    var initiallyShowingAdd = false
    var initialAddName = ""
    private let width: CGFloat = 320

    var body: some View {
        Group {
            if let roster {
                BotDrawer(roster: roster, topInset: topInset, bottomInset: bottomInset,
                          error: error, actions: resolvedActions,
                          initiallyShowingAdd: initiallyShowingAdd,
                          initialAddName: initialAddName)
            } else {
                BotDrawerLoading(topInset: topInset, bottomInset: bottomInset, error: error)
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(HomeSpec.page)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                          bottomTrailingRadius: isPersistent ? 0 : 22,
                                          topTrailingRadius: isPersistent ? 0 : 22,
                                          style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bot 列表")
        .accessibilityAddTraits(isPersistent ? [] : .isModal)
        .accessibilityAction(.escape) { close() }
        .accessibilityAction(named: Text("关闭 Bot 列表")) { close() }
        .accessibilityHint(isPersistent ? "" : "两指画 Z 或从转子里选「关闭 Bot 列表」都能收回。")
        .accessibilityIdentifier("bot.drawer.panel")
    }

    /// Drawer-owned closing stays inside the panel; the host may do extra work
    /// first (for example installing the selected Bot's page model).
    private var resolvedActions: BotDrawerActions {
        var value = actions
        let performClose = actions.close
        value.close = {
            performClose()
            guard !isPersistent else { return }
            withAnimation(.easeInOut(duration: 0.22)) { isOpen = false }
        }
        return value
    }

    private func close() {
        withAnimation(.easeInOut(duration: 0.22)) { isOpen = false }
    }
}

private struct BotDrawerLoading: View {
    var topInset: CGFloat
    var bottomInset: CGFloat
    var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bot")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(HomeSpec.textPrimary)
                .padding(.horizontal, HomeSpec.chromeInset)
            if let error {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(BotUIPalette.danger)
                    .padding(.horizontal, HomeSpec.chromeInset)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在连接 Bot…")
                        .font(.system(size: 13))
                        .foregroundStyle(HomeSpec.textSecondary)
                }
                .padding(.horizontal, HomeSpec.chromeInset)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, topInset + HomeSpec.navTop + 4)
        .padding(.bottom, bottomInset + 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(HomeSpec.page)
    }
}

/// The Bot rail. It consumes only `BotRosterModel` (visible entries, main
/// pointer, unread and live runtime states); no second roster or runtime state
/// lives here.
struct BotDrawer: View {
    @State private var roster: BotRosterModel
    var topInset: CGFloat
    var bottomInset: CGFloat
    var error: String?
    var actions: BotDrawerActions

    @State private var showingAdd = false
    @State private var renameEntry: BotRosterEntry?
    @State private var renameText = ""
    @State private var deleteEntry: BotRosterEntry?
    @State private var actionError: String?
    @State private var deleting = false

    init(roster: BotRosterModel, topInset: CGFloat, bottomInset: CGFloat,
         error: String? = nil, actions: BotDrawerActions = BotDrawerActions(),
         initiallyShowingAdd: Bool = false, initialAddName: String = "") {
        _roster = State(initialValue: roster)
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.error = error
        self.actions = actions
        _showingAdd = State(initialValue: initiallyShowingAdd)
        _addInitialName = State(initialValue: initialAddName)
    }

    @State private var addInitialName = ""

    private var visibleEntries: [BotRosterEntry] { roster.visibleEntries }
    private var lastBot: Bool { roster.bots.count <= 1 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    addButton
                        .padding(.horizontal, HomeSpec.chromeInset)
                        .padding(.top, 8)
                    if let message = error ?? roster.loadError ?? roster.actionError ?? actionError {
                        errorRow(message)
                    }
                    botRows
                    if visibleEntries.isEmpty {
                        Text("还没有 Bot。点上面的「添加 Bot」创建一个。")
                            .font(.system(size: 13))
                            .foregroundStyle(HomeSpec.textPlaceholder)
                            .padding(.horizontal, HomeSpec.chromeInset)
                            .padding(.top, 16)
                    }
                }
                .padding(.top, topInset + HomeSpec.navTop)
                .padding(.bottom, bottomInset + 24)
            }
            .scrollIndicators(.hidden)
        }
        .background(HomeSpec.page)
        .task { await roster.refresh() }
        .sheet(isPresented: $showingAdd) {
            BotAddDialog(actions: actions, initialName: addInitialName)
        }
        .alert("给 Bot 改名", isPresented: renameBinding) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) { renameEntry = nil }
            Button("保存") { performRename() }
        } message: {
            Text("去空格后不能为空，最多 \(BotAddValidation.maxNameLength) 个字符。")
        }
        .alert(deleteEntry.map { "删除「\($0.name)」？" } ?? "",
               isPresented: deleteBinding) {
            Button("取消", role: .cancel) { deleteEntry = nil }
            Button("删除", role: .destructive) { performDelete() }
        } message: {
            Text("会中止运行中的回合、拒绝待审批、撤销授权、归档 DSH 会话，并删除这个 Bot 的记忆、例行任务和待处理消息。此操作不可撤销，至少保留一个 Bot。")
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("Bot")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(HomeSpec.textPrimary)
            Spacer(minLength: 8)
            Button {
                actions.manage()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(HomeSpec.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("管理 Bot")
            .accessibilityIdentifier("bot.drawer.manage")
        }
        .padding(.leading, HomeSpec.chromeInset)
        .padding(.trailing, 8)
        .frame(height: 40)
    }

    /// The drawer's single filled control, same capsule as the session
    /// drawer's 新会话 button.
    private var addButton: some View {
        Button {
            addInitialName = ""
            showingAdd = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .regular))
                Text("添加 Bot")
                    .font(.system(size: 17, weight: .medium))
            }
            .foregroundStyle(HomeSpec.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(HomeSpec.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(HomeSpec.borderList, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(BotDrawerPillStyle())
        .accessibilityLabel("添加 Bot")
        .accessibilityIdentifier("bot.drawer.add")
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(BotUIPalette.danger)
                .lineLimit(3)
            Spacer(minLength: 8)
            Button("重试") {
                actionError = nil
                roster.loadError = nil
                actions.retry()
                Task { await roster.refresh() }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(HomeSpec.textPrimary)
        }
        .padding(.horizontal, HomeSpec.chromeInset)
        .padding(.top, 12)
    }

    private var botRows: some View {
        VStack(spacing: 2) {
            ForEach(visibleEntries) { entry in
                BotDrawerRow(entry: entry,
                             selected: roster.selectedBotID == entry.id,
                             onSelect: { select(entry) })
                    .contextMenu {
                        BotRowMenuContent(entry: entry, isLastBot: lastBot,
                                          onRename: { beginRename(entry) },
                                          onAppearance: { actions.appearance(entry.id) },
                                          onSetMain: { Task { await actions.setMain(entry.id) } },
                                          onSetHidden: { Task { await actions.setHidden(entry.id, !entry.isHidden) } },
                                          onDelete: { deleteEntry = entry })
                    }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
    }

    private func select(_ entry: BotRosterEntry) {
        actions.select(entry.id)
        actions.close()
    }

    private func beginRename(_ entry: BotRosterEntry) {
        renameText = entry.name
        renameEntry = entry
    }

    private func performRename() {
        guard let entry = renameEntry else { return }
        let name = BotAddValidation.trimmed(renameText)
        renameEntry = nil
        guard let problem = BotAddValidation.problem(for: name) else {
            Task {
                do { try await actions.rename(entry.id, name) }
                catch { actionError = "改名失败：\(error.localizedDescription)" }
            }
            return
        }
        actionError = problem
    }

    private func performDelete() {
        guard let entry = deleteEntry else { return }
        deleteEntry = nil
        deleting = true
        Task {
            do {
                try await actions.delete(entry.id)
                actionError = nil
            } catch {
                actionError = deleteFailureText(error)
            }
            deleting = false
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameEntry != nil }, set: { if !$0 { renameEntry = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { deleteEntry != nil }, set: { if !$0 { deleteEntry = nil } })
    }
}

private struct BotDrawerRow: View {
    let entry: BotRosterEntry
    let selected: Bool
    let onSelect: () -> Void

    private var statusText: String {
        if entry.pendingApprovalCount > 0 {
            return "\(entry.pendingApprovalCount) 项待审批"
        }
        if entry.isRunning {
            if let activity = entry.activity, !activity.detail.isEmpty {
                return activity.detail
            }
            switch entry.fishState {
            case .thinking: return "思考中"
            case .working: return "执行工具中"
            case .speaking, .streaming: return "回复中"
            case .alerting: return "等待确认"
            case .sleeping: return "休息中"
            default: return "运行中"
            }
        }
        if let last = entry.lastMessageAt {
            return BotDrawerTime.relative(last)
        }
        return "还没有消息"
    }

    private var statusColor: Color {
        entry.pendingApprovalCount > 0 ? NativeParityTokens.warning : HomeSpec.textSecondary
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                BotFishView(state: entry.fishState, size: 38, appearance: entry.appearance,
                            crowned: entry.isMainBot, reaction: entry.reaction)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(HomeSpec.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(statusText)
                        .font(.system(size: 12.5))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                if entry.unreadCount > 0 {
                    Text(entry.unreadCount > 99 ? "99+" : "\(entry.unreadCount)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(HomeSpec.primaryButtonInk)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(NativeParityTokens.error, in: Capsule())
                        .accessibilityLabel("\(entry.unreadCount) 条未读")
                        .accessibilityIdentifier("bot.drawer.unread.\(entry.id)")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 60)
            .background(selected ? HomeSpec.userBubble : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(BotDrawerRowStyle(radius: 12))
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("bot.drawer.row.\(entry.id)")
    }

    private var accessibilityText: String {
        var parts = [entry.name]
        if entry.isMainBot { parts.append("主 Bot") }
        parts.append(statusText)
        if entry.unreadCount > 0 { parts.append("\(entry.unreadCount) 条未读") }
        return parts.joined(separator: "，")
    }
}

/// One context menu shared by the drawer row and the management list.
struct BotRowMenuContent: View {
    let entry: BotRosterEntry
    let isLastBot: Bool
    let onRename: () -> Void
    let onAppearance: () -> Void
    let onSetMain: () -> Void
    let onSetHidden: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button("改名", systemImage: "pencil", action: onRename)
        Button("外观", systemImage: "paintpalette", action: onAppearance)
        if !entry.isMainBot {
            Button("设为主 Bot", systemImage: "crown", action: onSetMain)
        }
        Button(entry.isHidden ? "取消隐藏" : "隐藏",
               systemImage: entry.isHidden ? "eye" : "eye.slash",
               action: onSetHidden)
        Divider()
        if isLastBot {
            Text("这是最后一个 Bot，不能删除。")
        } else {
            Button("删除 Bot", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }
}

/// The management list reached from the drawer's “…” control. It is the only
/// place hidden Bots remain visible; every action is real record mutation.
struct BotManageList: View {
    @State private var roster: BotRosterModel
    var actions: BotDrawerActions
    @Environment(\.dismiss) private var dismiss

    @State private var renameEntry: BotRosterEntry?
    @State private var renameText = ""
    @State private var deleteEntry: BotRosterEntry?
    @State private var actionError: String?
    @State private var deleting = false

    init(roster: BotRosterModel, actions: BotDrawerActions = BotDrawerActions()) {
        _roster = State(initialValue: roster)
        self.actions = actions
    }

    private var lastBot: Bool { roster.bots.count <= 1 }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(roster.entries) { entry in
                        manageRow(entry)
                    }
                } header: {
                    Text("全部 Bot")
                } footer: {
                    Text("隐藏的 Bot 只在这里出现；取消隐藏后回到 Bot 列表。至少保留一个 Bot。")
                }

                if let message = roster.actionError ?? actionError {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 14))
                            .foregroundStyle(BotUIPalette.danger)
                            .accessibilityIdentifier("bot.manage.error")
                    }
                }
            }
            .homeGroupedList()
            .navigationTitle("管理 Bot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .alert("给 Bot 改名", isPresented: renameBinding) {
                TextField("名称", text: $renameText)
                Button("取消", role: .cancel) { renameEntry = nil }
                Button("保存") { performRename() }
            } message: {
                Text("去空格后不能为空，最多 \(BotAddValidation.maxNameLength) 个字符。")
            }
            .alert(deleteEntry.map { "删除「\($0.name)」？" } ?? "",
                   isPresented: deleteBinding) {
                Button("取消", role: .cancel) { deleteEntry = nil }
                Button("删除", role: .destructive) { performDelete() }
            } message: {
                Text("会中止运行中的回合、拒绝待审批、撤销授权、归档 DSH 会话，并删除这个 Bot 的记忆、例行任务和待处理消息。此操作不可撤销，至少保留一个 Bot。")
            }
        }
    }

    private func manageRow(_ entry: BotRosterEntry) -> some View {
        HStack(spacing: 12) {
            BotFishView(state: entry.fishState, size: 36, appearance: entry.appearance,
                        crowned: entry.isMainBot, still: true, reaction: entry.reaction)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(HomeSpec.textPrimary)
                        .lineLimit(1)
                    if entry.isMainBot {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(NativeParityTokens.warning)
                            .accessibilityLabel("主 Bot")
                    }
                    if entry.isHidden {
                        Text("已隐藏")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(HomeSpec.textSecondary)
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(HomeSpec.userBubble, in: Capsule())
                    }
                }
                Text(entry.description.isEmpty ? "还没有描述" : entry.description)
                    .font(.system(size: 12.5))
                    .foregroundStyle(HomeSpec.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Menu {
                BotRowMenuContent(entry: entry, isLastBot: lastBot,
                                  onRename: {
                                      renameText = entry.name
                                      renameEntry = entry
                                  },
                                  onAppearance: { openAppearance(entry) },
                                  onSetMain: { Task { await actions.setMain(entry.id) } },
                                  onSetHidden: { Task { await actions.setHidden(entry.id, !entry.isHidden) } },
                                  onDelete: { deleteEntry = entry })
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(HomeSpec.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(entry.name) 的操作")
            .accessibilityIdentifier("bot.manage.menu.\(entry.id)")
        }
        .contentShape(Rectangle())
        .accessibilityIdentifier("bot.manage.row.\(entry.id)")
    }

    private func openAppearance(_ entry: BotRosterEntry) {
        actions.appearance(entry.id)
        dismiss()
    }

    private func performRename() {
        guard let entry = renameEntry else { return }
        let name = BotAddValidation.trimmed(renameText)
        renameEntry = nil
        guard let problem = BotAddValidation.problem(for: name) else {
            Task {
                do { try await actions.rename(entry.id, name) }
                catch { actionError = "改名失败：\(error.localizedDescription)" }
            }
            return
        }
        actionError = problem
    }

    private func performDelete() {
        guard let entry = deleteEntry else { return }
        deleteEntry = nil
        deleting = true
        Task {
            do {
                try await actions.delete(entry.id)
                actionError = nil
            } catch {
                actionError = deleteFailureText(error)
            }
            deleting = false
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameEntry != nil }, set: { if !$0 { renameEntry = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { deleteEntry != nil }, set: { if !$0 { deleteEntry = nil } })
    }
}

/// The add-Bot dialog: name plus the same hairstyle/colour picker as the info
/// page. Only a trimmed name <= 60 UTF-16 units enables 创建.
struct BotAddDialog: View {
    var actions: BotDrawerActions
    var initialName = ""
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var color: BotFishColor = .blue
    @State private var hairstyle: BotFishHairstyle = .long
    @State private var saving = false
    @State private var error: String?

    init(actions: BotDrawerActions, initialName: String = "") {
        self.actions = actions
        self.initialName = initialName
        _name = State(initialValue: initialName)
    }

    private var validationProblem: String? {
        BotAddValidation.problem(for: name)
    }

    private var draftAppearance: BotFishAppearance {
        BotFishAppearance(color: color, hairstyle: hairstyle,
                          autoColor: false, autoHairstyle: false)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    BotFishView(state: .idle, size: 104, appearance: draftAppearance)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("新 Bot 预览，\(color.displayName)，\(hairstyle.displayName)")

                    VStack(alignment: .leading, spacing: 6) {
                        Text("名字")
                            .font(.system(size: 13))
                            .foregroundStyle(HomeSpec.textSecondary)
                        TextField("给这个 Bot 取个名字", text: $name)
                            .font(.system(size: HomeSpec.bodySize))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.leading, 12)
                            .padding(.trailing, 48)
                            .frame(height: 48)
                            .background(HomeSpec.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(HomeSpec.borderList, lineWidth: 0.5))
                            .accessibilityIdentifier("bot.add.name")
                            .overlay(alignment: .trailing) {
                                if !name.isEmpty {
                                    Button {
                                        name = ""
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(HomeSpec.textTertiary)
                                            .frame(width: 44, height: 44)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("清除名字")
                                    .accessibilityIdentifier("bot.add.name.clear")
                                    .padding(.trailing, 2)
                                }
                            }
                        if let validationProblem {
                            Text(validationProblem)
                                .font(.system(size: 12.5))
                                .foregroundStyle(BotUIPalette.danger)
                                .accessibilityIdentifier("bot.add.name.hint")
                        } else {
                            Text("去空格后最多 \(BotAddValidation.maxNameLength) 个字符。")
                                .font(.system(size: 12.5))
                                .foregroundStyle(HomeSpec.textTertiary)
                        }
                    }

                    BotAppearancePicker(
                        appearance: draftAppearance,
                        showsPreview: false,
                        identifierPrefix: "bot.add.appearance",
                        onSelectColor: { color = $0 },
                        onSelectHairstyle: { hairstyle = $0 })

                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 13))
                            .foregroundStyle(BotUIPalette.danger)
                            .accessibilityIdentifier("bot.add.error")
                    }
                }
                .padding(HomeSpec.contentInset)
            }
            .background(HomeSpec.page)
            .navigationTitle("添加 Bot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .accessibilityIdentifier("bot.add.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "创建中…" : "创建") { submit() }
                        .fontWeight(.semibold)
                        .disabled(validationProblem != nil || saving)
                        .accessibilityIdentifier("bot.add.create")
                }
            }
        }
    }

    private func submit() {
        guard validationProblem == nil, !saving else { return }
        let trimmed = BotAddValidation.trimmed(name)
        saving = true
        error = nil
        Task {
            do {
                let created = try await actions.create(trimmed, color, hairstyle)
                saving = false
                dismiss()
                actions.select(created.id)
                actions.close()
            } catch {
                self.error = "创建失败：\(error.localizedDescription)"
                saving = false
            }
        }
    }
}

enum BotDrawerTime {
    private static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    static func relative(_ milliseconds: Int64, now: Date = Date()) -> String {
        guard milliseconds > 0 else { return "还没有消息" }
        let dateValue = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        let seconds = now.timeIntervalSince(dateValue)
        if seconds < 60 { return "刚刚" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) 小时前" }
        return date.string(from: dateValue)
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


/// Same pressed states as the session drawer, local so the Bot capture target
/// does not need to compile the whole HomeDrawer/DSH management stack.
private struct BotDrawerPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(Capsule().fill(Color.black.opacity(configuration.isPressed ? 0.06 : 0)))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct BotDrawerRowStyle: ButtonStyle {
    var radius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(HomeSpec.userBubble.opacity(configuration.isPressed ? 0.7 : 0)))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
