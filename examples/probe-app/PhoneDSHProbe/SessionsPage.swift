// SPDX-License-Identifier: MIT
// Native mobile adaptation of DSH's workspace/session sidebar.

import SwiftUI
import UIKit

/// One Chinese relative time for session rows: 刚刚 / n 分钟前 / n 小时前, and a
/// plain date once it is older than a day.
enum SessionTime {
    private static let minutes: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans")
        f.dateFormat = "M月d日"
        return f
    }()

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) 小时前" }
        return minutes.string(from: date)
    }
}


/// 宿主给的默认标题(new conversation / workspace)不上屏:名字翻不出就用我们自己的说法,
/// 撞名的时候从第二个起带序号。
enum DrawerTitles {
    private static let defaultSessions: Set<String> = ["new conversation", "新会话", "conversation", "untitled"]
    private static let defaultWorkspaces: Set<String> = ["workspace", "工作区", "工作文件夹", "default"]

    static func sessionTitle(_ raw: String, index: Int) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || defaultSessions.contains(trimmed.lowercased()) {
            return index > 1 ? "新会话 \(index)" : "新会话"
        }
        return trimmed
    }

    static func workspaceTitle(_ raw: String, index: Int) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || defaultWorkspaces.contains(trimmed.lowercased()) {
            return index > 1 ? "工作文件夹 \(index)" : "工作文件夹"
        }
        return lastSegmentName(trimmed, fallback: "未命名文件夹")
    }

    /// 宿主只给路径时,只取最后一段当名字:半截路径比不显示更糟。
    static func lastSegmentName(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let segment = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        let name = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." || name == "~" { return fallback }
        return middleTruncate(name, limit: 12)
    }

    /// 超过限额中间截断,省略号用「…」。
    static func middleTruncate(_ text: String, limit: Int) -> String {
        let chars = Array(text)
        guard chars.count > limit, limit > 1 else { return text }
        let head = (limit - 1) / 2
        let tail = limit - 1 - head
        return String(chars.prefix(head)) + "…" + String(chars.suffix(tail))
    }
}

struct SessionsPage: View {
    var onSelect: () -> Void = {}

    /// 抽屉里三处共用的颜色:正文 #111114、次要 #66666B、运行中 #B45309(全站只有这一个橙)。
    static let dark = Color(red: 0x11 / 255, green: 0x11 / 255, blue: 0x14 / 255)
    static let ink = Color(red: 0x66 / 255, green: 0x66 / 255, blue: 0x6B / 255)
    /// 运行中是正常状态,不抢眼:和「5 分钟前」同一档灰,不许用橙色(橙留给「要你注意」)。
    static let runningInk = Color(red: 0x66 / 255, green: 0x66 / 255, blue: 0x6B / 255)

    @State private var management = DSHManagementModel.shared
    @State private var chat = ChatModel.shared
    @State private var showSchedules = false
    @State private var renameSessionTarget: ManagedSession?
    @State private var renameWorkspaceTarget: ManagedWorkspace?
    @State private var renameText = ""
    @State private var workspacePath = ""
    @State private var showingAddWorkspace = false
    @State private var showingFolderPicker = false
    @State private var archivedToast = false
    @State private var deleteWorkspaceTarget: ManagedWorkspace?
    @State private var showArchived = false
    @State private var query = ""

    /// Case-insensitive title match; an empty query keeps every row.
    private func matchesQuery(_ session: ManagedSession) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return displaySessionTitle(session).localizedCaseInsensitiveContains(trimmed)
    }
    @State private var collapsedWorkspaceIDs = Set(UserDefaults.standard.stringArray(forKey: "phone-dsh.sidebar.collapsed-workspaces") ?? [])
    @State private var selectedQueueSession: ManagedSession?
    @State private var showingConfiguration = false

    private var orderedWorkspaces: [ManagedWorkspace] {
        let byID = Dictionary(uniqueKeysWithValues: management.workspaces.map { ($0.id, $0) })
        let ordered = management.workspaceOrder.compactMap { byID[$0] }
        let listed = Set(ordered.map(\.id))
        return ordered + management.workspaces.filter { !listed.contains($0.id) }
    }

    private var archivedSessions: [ManagedSession] {
        guard showArchived else { return [] }
        return management.archivedSessions
    }

    private var ungroupedSessions: [ManagedSession] {
        pinnedFirst(management.ungroupedSessions).filter(matchesQuery)
    }

    private var visibleWorkspaces: [ManagedWorkspace] { orderedWorkspaces }

    /// 抽屉里真的什么都没有:没有文件夹、也没有会话。只有这时才出那块大空态。
    private var isCompletelyEmpty: Bool {
        visibleWorkspaces.isEmpty && ungroupedSessions.isEmpty && management.archivedSessions.isEmpty
    }

    /// The path is informational here, so it is shortened to the tail the user
    /// recognises instead of the full container path.
    private func workspaceDisplayPath(_ workspace: ManagedWorkspace) -> String? {
        let path = workspace.path
        guard !path.isEmpty else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        return parts.count > 2 ? "…/" + parts.suffix(2).joined(separator: "/") : path
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task { if await management.createSession() != nil { onSelect() } }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 20, weight: .regular))
                            Text("新建会话").font(.system(size: 17))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(newSessionBlocked == nil
                                         ? Color(red: 0x2F / 255, green: 0x5B / 255, blue: 0xFF / 255)
                                         : Color(red: 0x8A / 255, green: 0x8A / 255, blue: 0x90 / 255))
                        .frame(maxHeight: .infinity)
                        .overlay(alignment: .bottom) {
                            // 分隔线自绘,面板内右缘留 16。
                            Rectangle()
                                .fill(Color(red: 0xDD / 255, green: 0xDC / 255, blue: 0xE2 / 255))
                                .frame(width: 288, height: 0.5)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
                    .frame(height: 44)
                    .disabled(newSessionBlocked != nil)
                    .animation(.easeInOut(duration: 0.2), value: newSessionBlocked)
                    if let reason = newSessionBlocked {
                        Text(reason)
                            .font(.system(size: 13))
                            .foregroundStyle(Color(red: 0x66 / 255, green: 0x66 / 255, blue: 0x6B / 255))
                            .fixedSize(horizontal: false, vertical: true)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 0, trailing: 16))
                            .listRowSeparator(.hidden)
                            .transition(.opacity)
                    }
                    if let errorText = management.error ?? chat.userFacingError {
                        // 真实错误原样贴出来:固定一句「读不到会话」会把签名、
                        // 停止、权限这些完全不同的失败说成同一件事。
                        HStack(spacing: 12) {
                            Text(errorText)
                                .font(.system(size: 13))
                                .foregroundStyle(ChatPage.danger)
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            Button("重试") {
                                Task {
                                    chat.clearError()
                                    await management.refresh()
                                }
                            }
                            .font(.system(size: 17))
                            .foregroundStyle(ChatPage.accent)
                        }
                        .frame(height: 44)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowSeparator(.hidden)
                    }
                    // 不属于任何工作文件夹的会话紧贴在新建会话行下面(中间就是那条 0.5 线),
                    // 不加「未分组」标题:它只是排在最上面的几条会话。
                    ForEach(ungroupedSessions) { session in sessionRow(session) }
                }

                Section {
                    if isCompletelyEmpty {
                        // 全空(没有文件夹、也没有会话)才出这块大空态。
                        // 只是没有文件夹、但还有不归属文件夹的会话时,一个字都不出。
                        VStack(alignment: .center, spacing: 0) {
                            // 空态:文字落在这一栏的中线上;按钮仍是满宽,和列表同宽。
                            Text("还没有工作文件夹")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(SessionsPage.dark)
                                .multilineTextAlignment(.center)
                            Text("选一个文件夹,会话和文件都放在里面。")
                                .font(.system(size: 13))
                                .foregroundStyle(SessionsPage.ink)
                                .multilineTextAlignment(.center)
                                .padding(.top, 8)
                            Button { showingFolderPicker = true } label: {
                                Text("选择文件夹")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 50)
                                    .background(ChatPage.accent, in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 24)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        // 列表自己在新一段之前留了 24,这里不再补,补了就成 47。
                        .padding(.bottom, 8)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.white)
                    }
                }

                ForEach(visibleWorkspaces) { workspace in
                    let rows = pinnedFirst(management.sessions(in: workspace)).filter(matchesQuery)
                    // 文件夹是一行,不是吸顶的分组标题:整行点=展开收起,⋯ 只吃它自己那 32。
                    Section {
                        workspaceRow(workspace, count: rows.count)
                        if isWorkspaceExpanded(workspace.id) {
                            if rows.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("还没有会话")
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(Color(red: 0x11 / 255, green: 0x11 / 255, blue: 0x14 / 255))
                                    Text("点上面的「新建会话」开始。")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color(red: 0x66 / 255, green: 0x66 / 255, blue: 0x6B / 255))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 24)
                                .padding(.bottom, 8)
                            } else {
                                ForEach(rows) { session in sessionRow(session) }
                            }
                        }
                    }
                }

                // 组内最后一行:添加工作文件夹(系统文件夹选择器),不是页头右上角那个「添加」。
                // 全空态里已经有「选择文件夹」那颗按钮,这一行就不再出现,免得两个入口。
                if !isCompletelyEmpty {
                    Section {
                        Button { showingFolderPicker = true } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus")
                                    .font(.system(size: 16, weight: .medium))
                                Text("添加工作文件夹")
                                    .font(.system(size: 17))
                                Spacer(minLength: 8)
                            }
                            .foregroundStyle(ChatPage.accent)
                            .frame(height: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowSeparator(.hidden)
                    }
                }

                // 全空的时候连同「已归档 0」一起收起来:空态就该是空的,
                // 一屏大白块下面再挂一行「已归档,0」是噪音。
                if !isCompletelyEmpty {
                    Section {
                        if !showArchived {
                            EmptyView()
                        } else if management.archivedSessions.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("没有已归档的会话").font(.body)
                                Text("归档的会话会留在这里，随时可以恢复。")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        } else {
                            ForEach(management.archivedSessions.filter(matchesQuery)) { session in archivedRow(session) }
                        }
                    } header: {
                        Button {
                            withAnimation { showArchived.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: showArchived ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("已归档")
                                Spacer()
                                Text("\(management.archivedSessions.count)")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

            }
            .listStyle(.plain)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索会话")
            // 归档完那句提示:浮在列表上,不占布局(插一行会让下面的会话整体跳一下),两秒自己消失。
            .overlay(alignment: .top) {
                if archivedToast {
                    Text("已归档,在「已归档」里能找回来")
                        .font(.system(size: 13))
                        .foregroundStyle(SessionsPage.ink)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Color(red: 0xF2 / 255, green: 0xF3 / 255, blue: 0xF5 / 255),
                                    in: RoundedRectangle(cornerRadius: 12))
                        .padding(.top, 92)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            // 分隔线一律自绘:系统那层会从面板左缘拉到右缘,和 16..304 那套对不上。
            .listRowSeparator(.hidden)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemBackground))

            .sheet(isPresented: $showSchedules) {
                NavigationStack { NativeAutomationPage() }
                    .presentationDragIndicator(.visible)
            }

            .task { await management.refresh() }
            .refreshable { await management.refresh() }
            .sheet(isPresented: $showingConfiguration) { NativeConfigurationPage() }
            .navigationDestination(item: $selectedQueueSession) { session in
                SessionQueuePage(session: session, management: management)
            }
            // 用 alert 不用 confirmationDialog:后者在这个机型上渲染成只有一个「删除」的弹层,
            // 「取消」不出现,用户只剩删和点外面两条路。alert 两个按钮都在,一眼能看清。
            .alert(
                deleteWorkspaceTarget.map { "删除「\(displayWorkspaceTitle($0))」?" } ?? "",
                isPresented: Binding(get: { deleteWorkspaceTarget != nil },
                                     set: { if !$0 { deleteWorkspaceTarget = nil } }),
                presenting: deleteWorkspaceTarget) { workspace in
                    Button("取消", role: .cancel) { deleteWorkspaceTarget = nil }
                    Button("删除", role: .destructive) {
                        Task { await management.deleteWorkspace(workspace); deleteWorkspaceTarget = nil }
                    }
                } message: { _ in
                    Text("里面的会话会留着,只是不再放在这个文件夹里。")
                }
            .fileImporter(isPresented: $showingFolderPicker,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                // 选文件夹用系统选择器,不再让用户手输路径。
                guard case .success(let urls) = result, let url = urls.first else { return }
                Task { _ = await management.createWorkspace(at: url.path) }
            }
            .alert("添加工作区", isPresented: $showingAddWorkspace) {
                TextField("DSH Worker 中已存在的绝对路径", text: $workspacePath)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("取消", role: .cancel) { workspacePath = "" }
                Button("添加") {
                    let path = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { _ = await management.createWorkspace(at: path); workspacePath = "" }
                }
            } message: {
                Text("选中的文件夹要在手机上已经存在。这里只是把它记下来,不会复制或移动里面的文件。")
            }
            .alert("重命名会话", isPresented: Binding(
                get: { renameSessionTarget != nil }, set: { if !$0 { renameSessionTarget = nil } })) {
                    TextField("会话标题", text: $renameText)
                    Button("取消", role: .cancel) { renameSessionTarget = nil }
                    Button("保存") {
                        guard let session = renameSessionTarget else { return }
                        Task { await management.rename(session, to: renameText); renameSessionTarget = nil }
                    }
                }
            .alert("重命名工作文件夹", isPresented: Binding(
                get: { renameWorkspaceTarget != nil }, set: { if !$0 { renameWorkspaceTarget = nil } })) {
                    TextField("工作文件夹名称", text: $renameText)
                    Button("取消", role: .cancel) { renameWorkspaceTarget = nil }
                    Button("保存") {
                        guard let workspace = renameWorkspaceTarget else { return }
                        Task { await management.renameWorkspace(workspace, to: renameText); renameWorkspaceTarget = nil }
                    }
                }
        }
    }

    /// 文件夹一行 44:箭头 12 在左 16,名字 17 semibold 距箭头 7,「· N 个会话」13 距名字 6,
    /// ⋯ 20 的热区 32×44 落在右缘 304(面板 320 减左右各 16)。
    private func workspaceRow(_ workspace: ManagedWorkspace, count: Int) -> some View {
        HStack(spacing: 0) {
            Button { toggleWorkspace(workspace.id) } label: {
                HStack(spacing: 0) {
                    Image(systemName: isWorkspaceExpanded(workspace.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 0x66 / 255, green: 0x66 / 255, blue: 0x6B / 255))
                        .frame(width: 12, alignment: .leading)
                    Text(displayWorkspaceTitle(workspace))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(SessionsPage.dark)
                        .lineLimit(1)
                        .padding(.leading, 7)
                    if count > 0 {
                        Text("· \(count) 个会话")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(red: 0x66 / 255, green: 0x66 / 255, blue: 0x6B / 255))
                            .padding(.leading, 6)
                    }
                    Spacer(minLength: 8)
                }
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(displayWorkspaceTitle(workspace))，\(count) 个会话")
            .accessibilityHint(isWorkspaceExpanded(workspace.id) ? "收起工作文件夹的会话" : "展开工作文件夹的会话")

            Menu {
                Button("在这里新建会话") { createSession(in: workspace) }
                Button("重命名") { renameWorkspaceTarget = workspace; renameText = workspace.title }
                // 只删文件夹这个分组,里面的会话留着,落回不归属文件夹那一段。
                Button("删除工作文件夹", role: .destructive) { deleteWorkspaceTarget = workspace }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20))
                    .foregroundStyle(Color(red: 0x66 / 255, green: 0x66 / 255, blue: 0x6B / 255))
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(displayWorkspaceTitle(workspace)) 的选项")
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowSeparator(.hidden)
    }

    private func workspaceHeader(_ workspace: ManagedWorkspace, count: Int) -> some View {
        HStack {
            Button { toggleWorkspace(workspace.id) } label: {
                HStack(spacing: 7) {
                    Image(systemName: isWorkspaceExpanded(workspace.id) ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                    Image(systemName: "folder")
                    Text(displayWorkspaceTitle(workspace)).font(.subheadline.weight(.semibold))
                    if count > 0 {
                        Text("·").font(.caption).foregroundStyle(.tertiary)
                        Text("\(count) 个会话").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(displayWorkspaceTitle(workspace))，\(count) 个会话")
            .accessibilityHint(isWorkspaceExpanded(workspace.id) ? "收起工作文件夹的会话" : "展开工作文件夹的会话")
            Spacer()
            Menu {
                Button("在这里新建会话") { createSession(in: workspace) }
                Button("重命名工作文件夹") { renameWorkspaceTarget = workspace; renameText = workspace.title }
                Button("复制路径") { UIPasteboard.general.string = workspace.path }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 32, height: 30)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(displayWorkspaceTitle(workspace)) 的选项")
        }
        .textCase(nil)
    }

    private func isWorkspaceExpanded(_ id: String) -> Bool {
        !collapsedWorkspaceIDs.contains(id)
    }

    private func toggleWorkspace(_ id: String) {
        if collapsedWorkspaceIDs.contains(id) { collapsedWorkspaceIDs.remove(id) }
        else { collapsedWorkspaceIDs.insert(id) }
        UserDefaults.standard.set(Array(collapsedWorkspaceIDs).sorted(), forKey: "phone-dsh.sidebar.collapsed-workspaces")
    }

    /// 新建会话这一行为什么按不动,一句话说清;能按就是 nil。
    private var newSessionBlocked: String? {
        if !chat.isStarted { return "先启动本地引擎,才能新建会话。" }
        if chat.busy || chat.turnRunning || chat.keepingAlive { return "这一轮跑完就能新建" }
        return nil
    }

    /// 同名(或都是默认名)的会话从第二个起加序号,顺序跟列表一致。
    private func displaySessionTitle(_ session: ManagedSession) -> String {
        let ordered = orderedWorkspaces.flatMap { management.sessions(in: $0) } + management.ungroupedSessions
        var index = 0
        for candidate in ordered {
            let base = DrawerTitles.sessionTitle(candidate.title, index: 1)
            if base == DrawerTitles.sessionTitle(session.title, index: 1) { index += 1 }
            if candidate.id == session.id { break }
        }
        return DrawerTitles.sessionTitle(session.title, index: max(index, 1))
    }

    private func displayWorkspaceTitle(_ workspace: ManagedWorkspace) -> String {
        let ordered = orderedWorkspaces
        let index = (ordered.firstIndex(where: { $0.id == workspace.id }) ?? 0) + 1
        return DrawerTitles.workspaceTitle(workspace.title, index: index)
    }

    private func pinnedFirst(_ sessions: [ManagedSession]) -> [ManagedSession] {
        let pinRank = Dictionary(uniqueKeysWithValues: management.pinnedSessionIDs.enumerated().map { ($0.element, $0.offset) })
        return sessions.enumerated().sorted { lhs, rhs in
            let leftRank = pinRank[lhs.element.id] ?? Int.max
            let rightRank = pinRank[rhs.element.id] ?? Int.max
            return leftRank == rightRank ? lhs.offset < rhs.offset : leftRank < rightRank
        }.map(\.element)
    }

    @ViewBuilder
    private func sessionRow(_ session: ManagedSession) -> some View {
        // 行右边不再挂常驻的 ⋯:一屏十一个点会把列表淹了。菜单改成按住整行出来,
        // 按下时整行铺 #F2F3F5、圆角 12、0.15 秒渐入,松手菜单才出来。
        Button { open(session) } label: {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 17, height: 17)
                VStack(alignment: .leading, spacing: 3) {
                    Text(displaySessionTitle(session)).font(.body).lineLimit(1)
                    HStack(spacing: 5) {
                        Text(SessionTime.relative(session.updatedAt))
                        if session.running {
                            Text("·")
                            // 运行中的点挪到「运行中」前面,6 实心 #66666B,离字 4:
                            // 点连着字才读得成状态,挪到行首会变成第二行一个孤零零的符号。
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(SessionsPage.runningInk)
                                    .frame(width: 6, height: 6)
                                Text("运行中")
                            }
                            .foregroundStyle(SessionsPage.runningInk)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 4)
                if ChatModel.shared.currentSessionID == session.id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Color(red: 0x11 / 255, green: 0x11 / 255, blue: 0x14 / 255))
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(SessionRowButtonStyle())
        .accessibilityIdentifier("session-\(session.id)")
        .contextMenu {
            Button("重命名会话") { renameSessionTarget = session; renameText = session.title }
            // 引擎只有归档,没有删除(用户已在卡上选了这条):能恢复的动作不写成红字,也不弹确认窗。
            Button("归档会话") { archiveSession(session) }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowSeparator(.hidden)
        .overlay(alignment: .bottomLeading) {
            // 面板内左 16 右 16:320 宽的面板,线正好 288。
            Rectangle()
                .fill(Color(red: 0xDD / 255, green: 0xDC / 255, blue: 0xE2 / 255))
                .frame(width: 288, height: 0.5)
        }
    }

    private func archivedRow(_ session: ManagedSession) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(displaySessionTitle(session)).lineLimit(1)
                Text(SessionTime.relative(session.updatedAt)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("恢复") { Task { await management.unarchive(session) } }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }

    /// 归档;如果归档的是正开着的那个,页面回到空屏,并给一句两秒就消失的提示。
    private func archiveSession(_ session: ManagedSession) {
        let wasCurrent = ChatModel.shared.currentSessionID == session.id
        Task {
            await management.archive(session)
            guard management.error == nil, !management.archivedIDs.isEmpty || wasCurrent else { return }
            if wasCurrent {
                await ChatModel.shared.detachArchivedSession()
                withAnimation(.easeOut(duration: 0.15)) { archivedToast = true }
                try? await Task.sleep(for: .seconds(2))
                withAnimation(.easeIn(duration: 0.2)) { archivedToast = false }
            }
        }
    }

    private func open(_ session: ManagedSession) {
        Task { if await management.select(session) { onSelect() } }
    }

    private func fork(_ session: ManagedSession) {
        Task { if await management.fork(session) != nil { onSelect() } }
    }

    private func createSession(in workspace: ManagedWorkspace) {
        Task { if await management.createSession(workspaceID: workspace.id) != nil { onSelect() } }
    }

}

/// 列表行按下时的反馈:整行铺 #F2F3F5、圆角 12、0.15 秒渐入。
/// 不用缩放:缩放会把时间那行字一起放大,松手回弹还和列表滚动抢手感。
private struct SessionRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(red: 0xF2 / 255, green: 0xF3 / 255, blue: 0xF5 / 255))
                    .opacity(configuration.isPressed ? 1 : 0)
            )
            .animation(.easeIn(duration: 0.15), value: configuration.isPressed)
    }
}

private struct SessionQueuePage: View {
    let session: ManagedSession
    let management: DSHManagementModel
    @State private var editingItem: ManagedQueueItem?
    @State private var replacement = ""

    var body: some View {
        List {
            if management.queueSessionID != session.id {
                Section { ProgressView("正在读取队列…") }
            } else if management.queueItems.isEmpty {
                ContentUnavailableView("没有在排队的消息", systemImage: "tray",
                                       description: Text("发消息时选「排到下一轮」，它就会等在这里。"))
            } else {
                ForEach(management.queueItems) { item in
                    Section(item.lane == "next-turn" ? "下一轮" : "当前步骤") {
                        Text(item.text.isEmpty ? "（没有文本内容）" : item.text)
                            .font(.body).textSelection(.enabled)
                        HStack {
                            Button("编辑") { editingItem = item; replacement = item.text }
                            Spacer()
                            Button("设为当前引导") { Task { await management.updateQueue(item, action: "steer") } }
                            Spacer()
                            Button("移除", role: .destructive) { Task { await management.updateQueue(item, action: "remove") } }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            if let error = management.error {
                Section("错误") { Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.white)
        .navigationTitle("待处理队列")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await management.refreshQueue(for: session.id) }
        .task { await management.refreshQueue(for: session.id) }
        .sheet(item: $editingItem) { item in
            NavigationStack {
                TextEditor(text: $replacement)
                    .padding()
                    .navigationTitle("编辑队列消息")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { editingItem = nil }.leadingBarText() }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                Task { await management.updateQueue(item, action: "edit", replacement: replacement); editingItem = nil }
                            }
                        }
                    }
            }
        }
    }
}
