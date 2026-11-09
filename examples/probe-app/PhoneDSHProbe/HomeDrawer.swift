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

    @State private var management = DSHManagementModel.shared
    @State private var chat = ChatModel.shared
    @State private var collapsedFolderIDs = Set(UserDefaults.standard.stringArray(
        forKey: "phone-dsh.sidebar.collapsed-workspaces") ?? [])

    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renameSession: ManagedSession?
    @State private var renameFolder: ManagedWorkspace?
    @State private var deleteFolder: ManagedWorkspace?
    @State private var renameText = ""
    @State private var archivedToast = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    entriesCard
                    if let message = management.error ?? chat.userFacingError {
                        errorRow(message)
                    }
                    if Self.foldersEnabled {
                        folderSectionHeader
                            .padding(.top, 16)
                    } else {
                        Color.clear.frame(height: 16)
                    }
                    folders
                }
                .padding(.top, topInset + HomeSpec.navTop)
                .padding(.bottom, bottomInset + 24)
            }
            .scrollIndicators(.hidden)
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
        .task { await management.refresh() }
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

    // MARK: - New session

    /// The drawer's one filled control: a full-width white capsule with the
    /// "new conversation" glyph centred with its label. When the engine cannot
    /// take a new session, the whole capsule disables and the reason moves
    /// below it instead of sitting on the row's trailing edge.
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
                .foregroundStyle(newSessionBlocked == nil ? HomeSpec.textPrimary : HomeSpec.textPlaceholder)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(HomeSpec.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(HomeSpec.borderList, lineWidth: 0.5))
                .contentShape(Capsule())
            }
            .buttonStyle(HomeDrawerPillStyle())
            .disabled(newSessionBlocked != nil)
            .accessibilityLabel(NativeText("新会话", "New Session"))
            if let reason = newSessionBlocked {
                Text(reason)
                    .font(.system(size: 13))
                    .foregroundStyle(HomeSpec.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
    }

    /// Why 新会话 is unavailable, in a few words; nil when it can be pressed.
    private var newSessionBlocked: String? {
        if !chat.isStarted { return NativeText("引擎未启动", "Engine not started") }
        if chat.busy || chat.turnRunning || chat.keepingAlive {
            return NativeText("本轮结束后可用", "Available after this turn")
        }
        return nil
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
        let byID = Dictionary(uniqueKeysWithValues: management.workspaces.map { ($0.id, $0) })
        let ordered = management.workspaceOrder.compactMap { byID[$0] }
        let listed = Set(ordered.map(\.id))
        return ordered + management.workspaces.filter { !listed.contains($0.id) }
    }

    /// Every session has a folder: sessions the host lists outside any folder
    /// belong to the default one (手机工作区 / Phone Workspace). With no default
    /// folder registered yet they still show as that group, never as "unfiled".
    private func sessions(in folder: ManagedWorkspace) -> [ManagedSession] {
        let own = management.sessions(in: folder)
        guard folder.id == defaultFolder?.id else { return pinnedFirst(own) }
        return pinnedFirst(own + management.ungroupedSessions)
    }

    private var defaultFolder: ManagedWorkspace? {
        orderedFolders.first { management.isDefaultWorkspace($0) }
    }

    @ViewBuilder
    private var folders: some View {
        let loose = defaultFolder == nil ? pinnedFirst(management.ungroupedSessions) : []
        VStack(alignment: .leading, spacing: 4) {
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
                let sessions = sessions(in: folder)
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
        groupHeader(id: Self.looseGroupID, icon: "folder", title: DrawerTitles.defaultFolderName, count: count)
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
        let current = chat.currentSessionID == session.id
        return Button { open(session) } label: {
            HStack(spacing: 8) {
                Text(sessionTitle(session))
                    .font(.system(size: HomeSpec.bodySize, weight: current ? .medium : .regular))
                    .foregroundStyle(HomeSpec.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
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

    private func isExpanded(_ id: String) -> Bool { !collapsedFolderIDs.contains(id) }

    private func toggle(_ id: String) {
        if collapsedFolderIDs.contains(id) { collapsedFolderIDs.remove(id) }
        else { collapsedFolderIDs.insert(id) }
        UserDefaults.standard.set(Array(collapsedFolderIDs).sorted(),
                                  forKey: "phone-dsh.sidebar.collapsed-workspaces")
    }

    private func open(_ session: ManagedSession) {
        Task { if await management.select(session) { close() } }
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

    private func close() {
        guard !isPersistent else { return }
        withAnimation(.easeInOut(duration: 0.22)) { isOpen = false }
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
