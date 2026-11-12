// SPDX-License-Identifier: MIT
// HomeDrawer: the session drawer in the home design language (HomeSpec).
// Top to bottom: the full-width 新会话 capsule, the 文件夹 section with its +
// button and every folder's sessions. The app-wide settings surface owns the
// 定时任务 entry; the drawer deliberately has no duplicate.

import PhoneDSH
import ProbeKit
import SwiftUI
import UIKit

struct HomeDrawer: View {
    @Binding var isOpen: Bool
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    var isPersistent = false

    @Environment(\.workspaceModels) private var models
    /// The drawer, ChatPage and SessionsPage read the selected backend's pair;
    /// the phone singleton is only the fallback for the unpaired PC empty state.
    private var chat: ChatModel { models.currentChat ?? models.phoneChat }
    private var management: DSHManagementModel { models.currentManagement ?? models.phoneManagement }
    @State private var collapsedFolderIDs: Set<String> = []
    @State private var showPairing = false

    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renameSession: ManagedSession?
    @State private var renameFolder: ManagedWorkspace?
    @State private var deleteFolder: ManagedWorkspace?
    @State private var renameText = ""
    @State private var archivedToast = false
    /// Session order held for as long as the drawer is open. A switch refreshes
    /// `management.sessions` (newest first); applying that reorder under the
    /// user's finger would move the row they just tapped. The fresh order is
    /// adopted on the next open.
    @State private var sessionOrder: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    entriesCard
                    // pclink-pacing: 手机 | PC sits below the 新会话 pill (it
                    // used to be above). The selection is persisted (P18) and
                    // never changes because the PC is down.
                    PCDrawerSegment()
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 10)
                    if models.showsPCStateCard {
                        // No pairing, or nothing cached and nothing reachable:
                        // the card is all there is to show. The decision uses
                        // the PC scope's own rows, never the phone fallback.
                        PCDrawerStateView(onPair: { showPairing = true })
                    } else {
                        if let note = models.pcCachedListNote {
                            // A cached list stays readable while the phone
                            // reconnects or the PC is unreachable; the strip
                            // dates it so it is never mistaken for live rows.
                            pcCachedListNote(note)
                        }
                        if let message = errorMessage {
                            errorRow(message)
                                .transition(.opacity)
                        }
                        if Self.foldersEnabled {
                            folderSectionHeader
                                .padding(.top, 16)
                        } else {
                            Color.clear.frame(height: 16)
                        }
                        folders
                    }
                }
                .animation(.easeOut(duration: 0.15), value: errorMessage)
                .padding(.top, topInset + HomeSpec.navTop)
                .padding(.bottom, bottomInset + 24)
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("drawer.scroll")
        }
        .background(HomeSpec.page)
        .overlay(alignment: .top) {
            if archivedToast {
                Text("已归档，可在 我的 › 已归档会话 里找回")
                    .font(.system(size: 13))
                    .foregroundStyle(HomeSpec.textSecondary)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(HomeSpec.surface, in: Capsule())
                    .homeFloatingShadow()
                    .padding(.top, topInset + 8)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .task(id: backendTaskID) {
            collapsedFolderIDs = WorkspaceStorage.collapsedWorkspaceIDs(for: currentBackendID)
            // The held list order belongs to this backend (P18: phone and PC may
            // carry the same session ID); a backend switch adopts a fresh order.
            sessionOrder.removeAll()
            rememberSessionOrder()
            // The unpaired/offline PC segment has no list to read; never call
            // the phone management under a PC header.
            if !showsPCState { await management.refresh() }
            rememberSessionOrder()
        }
        .sheet(isPresented: $showPairing) {
            NavigationStack { PCPairingPage() }
        }
        .onChange(of: management.sessions.map(\.id)) { _, _ in rememberSessionOrder() }
        .onChange(of: management.workspaces) { _, _ in rememberSessionOrder() }
        .onChange(of: isOpen) { _, open in
            // Keep the held order through the close animation; a fresh order is
            // adopted only when the drawer opens again.
            if open {
                sessionOrder.removeAll()
                rememberSessionOrder()
            }
        }
        .onDisappear { sessionOrder.removeAll() }
        .onChange(of: models.pcLink.isOnline) { _, online in
            if online, !showsPCState { management.refreshSoon() }
        }
        .alert("新建文件夹", isPresented: $showNewFolder) {
            TextField("文件夹名称", text: $newFolderName)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("取消", role: .cancel) { newFolderName = "" }
            Button("创建") {
                let name = newFolderName
                newFolderName = ""
                Task { _ = await management.createWorkspaceFolder(named: name) }
            }
        } message: {
            Text("会在工作区里新建同名文件夹，之后的会话和文件都可以放进去。")
        }
        .alert("编辑名称", isPresented: Binding(
            get: { renameSession != nil }, set: { if !$0 { renameSession = nil } })) {
            TextField("会话名称", text: $renameText)
            Button("取消", role: .cancel) { renameSession = nil }
            Button("保存") {
                guard let session = renameSession else { return }
                let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                renameSession = nil
                guard !title.isEmpty else { return }
                Task { await management.rename(session, to: title) }
            }
        }
        .alert("重命名文件夹", isPresented: Binding(
            get: { renameFolder != nil }, set: { if !$0 { renameFolder = nil } })) {
            TextField("文件夹名称", text: $renameText)
            Button("取消", role: .cancel) { renameFolder = nil }
            Button("保存") {
                guard let folder = renameFolder else { return }
                let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                renameFolder = nil
                guard !title.isEmpty else { return }
                Task { await management.renameWorkspace(folder, to: title) }
            }
        }
        .alert(deleteFolder.map { "删除「\(folderTitle($0))」？" } ?? "",
               isPresented: Binding(get: { deleteFolder != nil },
                                    set: { if !$0 { deleteFolder = nil } }),
               presenting: deleteFolder) { folder in
            Button("取消", role: .cancel) { deleteFolder = nil }
            Button("删除", role: .destructive) {
                Task { await management.deleteWorkspace(folder); deleteFolder = nil }
            }
        } message: { _ in
            Text("里面的会话会留着，只是不再放在这个文件夹里。")
        }
    }

    private var currentBackendID: BackendID { models.currentBackendID ?? .phone }

    private var showsPCState: Bool {
        guard !models.isPhoneSelected else { return false }
        return models.drawerPhase != .ready
    }

    private var backendTaskID: String {
        models.currentBackendID?.storageScope ?? "pc:unpaired"
    }

    // MARK: - New session

    /// The drawer's one filled control: a full-width white capsule with the
    /// "new conversation" glyph centred with its label. When the engine cannot
    /// take a new session, the whole capsule disables and the reason moves
    /// below it instead of sitting on the row's trailing edge. The reason row
    /// is always laid out at one line's height, so its appearance cannot push
    /// the folder/session list down.
    private var entriesCard: some View {
        VStack(spacing: 6) {
            Button {
                Task { if await management.createSession() != nil { close() } }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus.bubble")
                        .font(.system(size: 20, weight: .regular))
                    Text(NativeText("新会话", "New Session"))
                        .font(.system(size: 17, weight: .medium))
                }
                .foregroundStyle(newSessionDisabled ? HomeSpec.textPlaceholder : HomeSpec.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(HomeSpec.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(HomeSpec.borderList, lineWidth: 0.5))
                .contentShape(Capsule())
            }
            .buttonStyle(HomeDrawerPillStyle())
            .disabled(newSessionDisabled)
            .accessibilityLabel(NativeText("新会话", "New Session"))
            .accessibilityIdentifier("drawer.new-session")
            ZStack {
                if let reason = newSessionBlocked {
                    Text(reason)
                        .font(.system(size: 13))
                        .foregroundStyle(HomeSpec.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: HomeDrawerNewSessionPolicy.reasonLineHeight)
            .animation(.easeOut(duration: 0.15), value: newSessionBlocked)
        }
        .padding(.horizontal, 16)
    }

    /// Why 新会话 is unavailable, in a few words; nil when it can be pressed.
    /// A session switch's transient `busy` is not a reason: the capsule stays
    /// disabled for it, but the list must not move for it.
    private var newSessionBlocked: String? {
        if !models.isPhoneSelected {
            switch models.drawerPhase {
            case .pair: return "连接电脑后可新建会话"
            case .connecting: return "正在连接电脑"
            case .offline: return "电脑离线，无法新建会话"
            case .ready, .phone: break
            }
        }
        return HomeDrawerNewSessionPolicy.reason(
            isStarted: chat.isStarted,
            turnRunning: chat.turnRunning,
            keepingAlive: chat.keepingAlive, engineStarting: chat.enginePhase == .starting)?.text
    }

    private var newSessionDisabled: Bool {
        if !models.isPhoneSelected {
            switch models.drawerPhase {
            case .pair, .connecting, .offline: return true
            case .ready, .phone: break
            }
        }
        return HomeDrawerNewSessionPolicy.isDisabled(
            isStarted: chat.isStarted,
            busy: chat.busy,
            turnRunning: chat.turnRunning,
            keepingAlive: chat.keepingAlive)
    }

    /// A transient failure while the tapped session opens is suppressed until
    /// the switch settles; the drawer closes on success and shows a real
    /// failure afterwards.
    private var errorMessage: String? {
        chat.isSwitchingSession ? nil : management.error ?? chat.userFacingError
    }

    /// Strip above a cached PC list. Plain text: the recovery action lives in
    /// the segment's empty state, and a new Button here would be a new
    /// page-contract action.
    private func pcCachedListNote(_ note: String) -> some View {
        Text(note)
            .font(.system(size: 12))
            .foregroundStyle(HomeSpec.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(HomeSpec.userBubble, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, HomeSpec.contentInset)
            .padding(.bottom, 8)
            .accessibilityIdentifier("pc-cached-list-note")
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(NativePagePalette.danger)
                .lineLimit(3)
            Spacer(minLength: 8)
            Button("重试") {
                Task {
                    chat.clearError()
                    await management.refresh()
                }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(HomeSpec.textPrimary)
        }
        .padding(.horizontal, HomeSpec.contentInset)
        .padding(.top, 12)
    }

    // MARK: - Folders

    /// Folder management (the 文件夹 title, 新建文件夹, the empty-folder hint) is
    /// not offered yet. Session groups such as 手机工作区 still show; flip this
    /// to re-open folder creation.
    static let foldersEnabled = false

    private var folderSectionHeader: some View {
        HStack(spacing: 0) {
            Text("文件夹")
                .font(.system(size: HomeSpec.processSize, weight: .medium))
                .foregroundStyle(HomeSpec.textSecondary)
            Spacer(minLength: 8)
            Button { showNewFolder = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(HomeSpec.textSecondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("新建文件夹")
        }
        .padding(.leading, HomeSpec.contentInset)
        .padding(.trailing, 12)
        .frame(height: 36)
    }

    private var orderedFolders: [ManagedWorkspace] {
        management.workspaceIndex.orderedWorkspaces
    }

    /// Every session has a folder: sessions the host lists outside any folder
    /// belong to the default one (手机工作区 / Phone Workspace). With no default
    /// folder registered yet they still show as that group, never as "unfiled".
    private func sessions(in folder: ManagedWorkspace,
                          heldOrderRank rank: [String: Int]) -> [ManagedSession] {
        inHeldOrder(rawSessions(in: folder), rank: rank)
    }

    /// The host's current order for one folder, before the drawer's held order.
    private func rawSessions(in folder: ManagedWorkspace) -> [ManagedSession] {
        // One cached snapshot per body: membership + the cwd fallback are
        // precomputed, never an O(sessions × workspaces) scan under the finger.
        let index = management.workspaceIndex
        let own = index.sessions(in: folder)
        if models.isPhoneSelected {
            guard folder.id == defaultFolder?.id else { return pinnedFirst(own) }
            return pinnedFirst(own + index.ungroupedSessions)
        }
        // PC: a session the workspace list has not enrolled yet still belongs
        // to the workspace whose host path owns its cwd (longest match). This
        // is what turns the old single "PC 工作区" pile into real groups.
        let extra = index.extraSessions(in: folder.id)
        return pinnedFirst(own + extra)
    }

    private var defaultFolder: ManagedWorkspace? {
        orderedFolders.first { management.isDefaultWorkspace($0) }
    }

    private var listState: PCDrawerListState {
        PCLinkDrawerPolicy.listState(isLoading: management.isLoading,
                                     error: management.error,
                                     sessionCount: management.activeSessions.count)
    }

    /// Sessions shown outside a workspace header, before the drawer's held
    /// order: the phone's default folder rule is unchanged; a PC session joins
    /// its workspace when `workspace/follow` lists it or its cwd matches a
    /// workspace path, and only the rest is loose.
    private var rawLooseSessions: [ManagedSession] {
        let index = management.workspaceIndex
        if models.isPhoneSelected {
            return defaultFolder == nil ? pinnedFirst(index.ungroupedSessions) : []
        }
        guard !orderedFolders.isEmpty else { return pinnedFirst(index.ungroupedSessions) }
        return pinnedFirst(index.looseSessions)
    }

    /// Built once per body instead of once per folder: the old code created a
    /// 3,500-entry rank dictionary for every Workspace on every body pass.
    private var heldOrderRank: [String: Int] {
        guard !sessionOrder.isEmpty else { return [:] }
        return Dictionary(uniqueKeysWithValues: sessionOrder.enumerated()
            .map { ($0.element, $0.offset) })
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(NativeText("正在读取 PC 会话…", "Loading PC sessions…"))
                .font(.system(size: 14))
                .foregroundStyle(HomeSpec.textPlaceholder)
        }
        .padding(.horizontal, HomeSpec.contentInset)
        .padding(.top, 8)
        .frame(height: 36)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var folders: some View {
        let rank = heldOrderRank
        let loose = inHeldOrder(rawLooseSessions, rank: rank)
        LazyVStack(alignment: .leading, spacing: 4) {
            if !models.isPhoneSelected {
                switch listState {
                case .loading:
                    loadingRow
                case .error:
                    // The error row above carries the message and 重试; never
                    // fall through to the "no PC sessions" empty state.
                    EmptyView()
                case .empty:
                    Text("还没有 PC 会话。点上面的「新会话」在电脑上新建一个。")
                        .font(.system(size: 14))
                        .foregroundStyle(HomeSpec.textPlaceholder)
                        .padding(.horizontal, HomeSpec.contentInset)
                        .padding(.top, 8)
                case .rows:
                    EmptyView()
                }
            }
            if Self.foldersEnabled && orderedFolders.isEmpty && loose.isEmpty {
                Text("还没有文件夹。点右上角的 + 新建一个，会话和文件都能放进去。")
                    .font(.system(size: 14))
                    .foregroundStyle(HomeSpec.textPlaceholder)
                    .padding(.horizontal, HomeSpec.contentInset)
                    .padding(.top, 8)
            }
            if !loose.isEmpty {
                looseHeader(count: loose.count)
                if isExpanded(Self.looseGroupID) {
                    ForEach(loose) { session in sessionRow(session) }
                }
            }
            ForEach(orderedFolders) { folder in
                let sessions = sessions(in: folder, heldOrderRank: rank)
                folderHeader(folder, count: sessions.count)
                if isExpanded(folder.id) {
                    if sessions.isEmpty {
                        Text("还没有会话")
                            .font(.system(size: 14))
                            .foregroundStyle(HomeSpec.textPlaceholder)
                            .padding(.leading, 50)
                            .frame(height: 36)
                    } else {
                        ForEach(sessions) { session in sessionRow(session) }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .animation(.easeOut(duration: 0.18), value: collapsedFolderIDs)
    }

    private func folderHeader(_ folder: ManagedWorkspace, count: Int) -> some View {
        groupHeader(id: folder.id, icon: "folder", title: folderTitle(folder), count: count)
            .contextMenu {
                Button("在这里新建会话", systemImage: "square.and.pencil") {
                    Task { if await management.createSession(workspaceID: folder.id) != nil { close() } }
                }
                if Self.foldersEnabled {
                    Button("重命名", systemImage: "pencil") {
                        renameText = folderTitle(folder)
                        renameFolder = folder
                    }
                    Button("删除文件夹", systemImage: "trash", role: .destructive) { deleteFolder = folder }
                }
            }
    }

    /// The default folder before the host has registered one: same shape,
    /// same name, no folder menu.
    private func looseHeader(count: Int) -> some View {
        let title: String
        if models.isPhoneSelected {
            title = DrawerTitles.defaultFolderName
        } else if orderedFolders.isEmpty {
            // No workspace baseline yet: keep the old group name as a
            // degraded fallback rather than inventing a workspace title.
            title = models.pcWorkspaceTitle
        } else {
            title = NativeText("未分组", "Ungrouped")
        }
        return groupHeader(id: Self.looseGroupID, icon: "folder", title: title, count: count)
    }

    private func groupHeader(id: String, icon: String, title: String, count: Int) -> some View {
        Button { toggle(id) } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HomeSpec.textPlaceholder)
                    .rotationEffect(.degrees(isExpanded(id) ? 90 : 0))
                    .frame(width: 12)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(HomeSpec.textSecondary)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: HomeSpec.bodySize, weight: .semibold))
                    .foregroundStyle(HomeSpec.textPrimary)
                    .lineLimit(1)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 14).monospacedDigit())
                        .foregroundStyle(HomeSpec.textPlaceholder)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(HomeDrawerRowStyle(radius: 12))
        .accessibilityLabel("\(title)，\(count) 个会话")
        .accessibilityValue(isExpanded(id) ? "已展开" : "已收起")
    }

    private func sessionRow(_ session: ManagedSession) -> some View {
        // The optimistic target is selected before the open starts, so the row
        // under the finger highlights in the same frame as the close.
        let current = chat.displayedSessionID == session.id
        return Button { open(session) } label: {
            HStack(spacing: 8) {
                Text(sessionTitle(session))
                    .font(.system(size: HomeSpec.bodySize, weight: current ? .medium : .regular))
                    .foregroundStyle(HomeSpec.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Group {
                    if session.running {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(HomeSpec.textSecondary)
                    } else {
                        Text(SessionTime.relative(session.updatedAt))
                            .font(.system(size: 13))
                            .foregroundStyle(HomeSpec.textPlaceholder)
                            .lineLimit(1)
                    }
                }
                // A running spinner and a relative time have different widths;
                // reserving one trailing slot keeps the title from reflowing
                // when a row starts or finishes a turn.
                .frame(width: 64, alignment: .trailing)
            }
            .padding(.leading, 42)
            .padding(.trailing, 12)
            .frame(height: 44)
            .background(current ? HomeSpec.userBubble : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(HomeDrawerRowStyle(radius: 12))
        .accessibilityIdentifier("session-\(session.id)")
        .accessibilityAddTraits(current ? .isSelected : [])
        .contextMenu {
            Button("编辑名称", systemImage: "pencil") {
                renameText = sessionTitle(session)
                renameSession = session
            }
            Button("归档", systemImage: "archivebox") { archive(session) }
        }
    }

    // MARK: - Helpers

    static let hairline = NativeParityTokens.color(light: 0xF0F0F0, dark: 0x2A2A2E)
    private static let looseGroupID = "__loose__"

    private func folderTitle(_ folder: ManagedWorkspace) -> String {
        if !models.isPhoneSelected {
            // The DSH workspace title is the group name on the PC; the
            // computer-name suffix would merge every workspace into one.
            return PCLinkWorkspaceGrouping.title(folder.title, fallback: "工作区")
        }
        let index = (orderedFolders.firstIndex(where: { $0.id == folder.id }) ?? 0) + 1
        return DrawerTitles.workspaceTitle(folder.title, index: index)
    }

    private func sessionTitle(_ session: ManagedSession) -> String {
        DrawerTitles.sessionTitle(session.title, index: 1)
    }

    private func pinnedFirst(_ sessions: [ManagedSession]) -> [ManagedSession] {
        let rank = Dictionary(uniqueKeysWithValues: management.pinnedSessionIDs.enumerated()
            .map { ($0.element, $0.offset) })
        return sessions.enumerated().sorted { lhs, rhs in
            let left = rank[lhs.element.id] ?? Int.max
            let right = rank[rhs.element.id] ?? Int.max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    /// Keeps the first-seen order while the drawer is open; sessions that
    /// appear later are appended after it. `sessions` is newest-first after a
    /// refresh, so without this hold a switch that bumped the selected
    /// session's `updatedAt` would reorder the list under the tap.
    private func inHeldOrder(_ sessions: [ManagedSession],
                             rank: [String: Int]) -> [ManagedSession] {
        guard !rank.isEmpty else { return sessions }
        return sessions.enumerated().sorted { lhs, rhs in
            let left = rank[lhs.element.id] ?? Int.max
            let right = rank[rhs.element.id] ?? Int.max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    private func rememberSessionOrder() {
        let known = Set(sessionOrder)
        let displayed = rawLooseSessions.map(\.id)
            + orderedFolders.flatMap { rawSessions(in: $0).map(\.id) }
        let additions = displayed.filter { !known.contains($0) }
        guard !additions.isEmpty else { return }
        sessionOrder.append(contentsOf: additions)
    }

    private func isExpanded(_ id: String) -> Bool { !collapsedFolderIDs.contains(id) }

    private func toggle(_ id: String) {
        if collapsedFolderIDs.contains(id) { collapsedFolderIDs.remove(id) }
        else { collapsedFolderIDs.insert(id) }
        WorkspaceStorage.setCollapsedWorkspaceIDs(collapsedFolderIDs, for: currentBackendID)
    }

    private func open(_ session: ManagedSession) {
        let target = HomeDrawerSwitchPolicy.Session(
            id: session.id, title: sessionTitle(session))
        switch HomeDrawerSwitchPolicy.tap(
            target,
            currentSessionID: chat.currentSessionID,
            pending: chat.pendingSessionSwitch) {
        case .close:
            // Already open or already switching there: close now, no second
            // open. The wide sidebar stays put.
            if HomeDrawerSwitchPolicy.closesDrawer(isPersistent: isPersistent) { close() }
        case .beginSwitch:
            // Only the lightweight selection/title is written in the tap frame.
            // The worker that opens the session starts after the drawer's
            // 0.22s close animation, so its main-thread work cannot swallow the
            // animation; the wide sidebar only needs one runloop.
            management.stageOptimisticSelect(session, title: target.title)
            switch HomeDrawerSwitchPolicy.startGate(isPersistent: isPersistent) {
            case .afterDrawerClosed:
                close { management.startStagedOptimisticSelect() }
            case .nextRunloop:
                management.startStagedOptimisticSelectOnNextRunloop()
            }
        }
    }

    /// Archive; when it is the open session the chat page detaches and a
    /// two-second note says where to find it again.
    private func archive(_ session: ManagedSession) {
        let wasCurrent = chat.currentSessionID == session.id
        Task {
            await management.archive(session)
            guard management.error == nil else { return }
            if wasCurrent { await chat.detachArchivedSession() }
            withAnimation(.easeOut(duration: 0.15)) { archivedToast = true }
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeIn(duration: 0.2)) { archivedToast = false }
        }
    }

    /// Closes the phone drawer and runs `completion` only when the 0.22s
    /// animation has finished. Session switches use this to delay their heavy
    /// work until after the drawer is gone. The persistent sidebar never
    /// closes, so its completion runs immediately (its caller uses the
    /// next-runloop start instead).
    private func close(completion: (() -> Void)? = nil) {
        guard !isPersistent else { completion?(); return }
        withAnimation(.easeInOut(duration: HomeDrawerSwitchPolicy.closeDuration)) {
            isOpen = false
        } completion: {
            completion?()
        }
    }
}

/// The pill dims slightly while pressed; no scaling, so the drawer never jumps.
private struct HomeDrawerPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(Capsule().fill(Color.black.opacity(configuration.isPressed ? 0.06 : 0)))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Pressed rows tint with the bubble gray; no scaling, so the list never jumps.
private struct HomeDrawerRowStyle: ButtonStyle {
    var radius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(HomeSpec.userBubble.opacity(configuration.isPressed ? 0.7 : 0)))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - 手机 | PC segment (P09/P18)

/// 手机 | PC. The selected side persists through P18
/// (`phone-dsh.drawer.backend`); selecting PC while unpaired opens the pairing
/// entry but never changes the selection back.
struct PCDrawerSegment: View {
    @Environment(\.workspaceModels) private var models

    private var selection: DrawerBackendSetting { models.selected }

    var body: some View {
        HStack(spacing: 0) {
            segmentButton(.phone, title: NativeText("手机", "Phone"))
            segmentButton(.pc, title: "PC")
        }
        .padding(2)
        .background(HomeSpec.userBubble, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("工作区")
    }

    private func segmentButton(_ value: DrawerBackendSetting, title: String) -> some View {
        let selected = selection == value
        return Button {
            models.select(value)
        } label: {
            Text(title)
                .font(.system(size: 15, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? HomeSpec.textPrimary : HomeSpec.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(selected ? HomeSpec.surface : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(
                    selected ? HomeSpec.borderList : Color.clear, lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}
