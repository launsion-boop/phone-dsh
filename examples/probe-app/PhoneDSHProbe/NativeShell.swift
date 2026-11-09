// SPDX-License-Identifier: MIT
// NativeShell.swift
// 原生外壳的骨架（重构第一步）：底部四标签 对话 / 会话 / 工作区 / 设置。
// 会话占一格是产品决定（高频检索）；定时任务并进会话页的第二段。

import ProbeKit
import SwiftUI
import PhoneDSH
import PhoneDSHAgentCore
import UIKit

/// The four places the native shell can be. Chat owns the composed turn;
/// Sessions owns history + scheduled runs; Workspace owns files and the
/// workbench; Settings owns every switch in the app.
enum NativeTab: String, CaseIterable, Identifiable {
    case chat, sessions, workspace, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "对话"
        case .sessions: return "会话"
        case .workspace: return "工作区"
        case .settings: return "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .sessions: return "clock.arrow.circlepath"
        case .workspace: return "folder"
        case .settings: return "gearshape"
        }
    }
}

/// One set of numbers for every native screen header, so the four tabs land on
/// the same baseline instead of each page inventing its own inset.
enum NativeHeaderStyle {
    static let barHeight: CGFloat = 44
    static let horizontalInset: CGFloat = 16
    static let titleSize: CGFloat = 17
    static let statusDot: CGFloat = 8
}

/// Green means the configured host is running; amber marks missing model
/// configuration or a parked host, and grey means stopped.
struct RunStatusDot: View {
    let started: Bool
    let parked: Bool
    let needsModelConfiguration: Bool

    private var color: Color {
        if needsModelConfiguration || parked { return NativeParityTokens.warning }
        return started
            ? HomeSpec.success
            : Color(uiColor: .tertiaryLabel)
    }

    private var label: String {
        if needsModelConfiguration { return "待配置模型服务" }
        if parked { return "后台暂停" }
        return started ? "运行中" : ""
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: NativeHeaderStyle.statusDot, height: NativeHeaderStyle.statusDot)
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label.isEmpty ? "运行状态" : label)
        .padding(.trailing, 4)
    }
}

/// Wide windows keep sessions beside the conversation; compact windows use a
/// push-aside drawer. Both layouts retain the same conversation view and draft.
struct NativeShell: View {
    init() {
        // HomeSpec chrome for every list, pushed page and sheet: #F7F7F7 page,
        // white rows, a flat navigation bar.
        HomeAppearance.apply()
    }

    @State private var drawerOpen = false
    /// Bottom menu selection; 任务 (the chat page) is where the app opens.
    @State private var selectedTab: HomeTab = .tasks
    @State private var keyboardVisible = false
    /// Tabs whose root page is covered by a pushed page. The bar belongs to
    /// the first-level pages only, so it leaves while the selected tab has
    /// something pushed and returns when the root shows again.
    @State private var pushedTabs: Set<HomeTab> = []
    @State private var sidebarCollapsed = false
    @State private var dragOffset: CGFloat = 0
    @State private var preferences = NativeChatPreferences.shared
    private let drawerWidth: CGFloat = 320
    #if DEBUG
    @State private var preview = PreviewScreen.requested
    #endif

    var body: some View {
        GeometryReader { proxy in
            // Leave at least 580 points for the conversation beside the sidebar.
            let usesSidebar = proxy.size.width >= drawerWidth + 580
            let sidebarVisible = usesSidebar && !sidebarCollapsed
            let modalDrawerVisible = !usesSidebar && drawerOpen
            let panelOpen = usesSidebar
                ? Binding(get: { !sidebarCollapsed }, set: { sidebarCollapsed = !$0 })
                : $drawerOpen

            ZStack(alignment: .topLeading) {
                tabPages(usesSidebar: usesSidebar, sidebarVisible: sidebarVisible,
                         bottomInset: proxy.safeAreaInsets.bottom)
                .frame(width: max(0, proxy.size.width - (sidebarVisible ? drawerWidth : 0)))
                // A persistent sidebar sits beside the page; the phone drawer
                // slides over it instead, so the page itself never moves.
                .offset(x: sidebarVisible ? drawerWidth : 0)
                .accessibilityHidden(modalDrawerVisible)

                // Scrim over the page: tap or swipe left to close. It follows
                // the drag so the page brightens as the drawer leaves.
                if modalDrawerVisible {
                    Color.black
                        .opacity(0.28 * drawerProgress)
                        .contentShape(Rectangle())
                        .onTapGesture { closeDrawer() }
                        .gesture(closeDrag)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }

                SessionsDrawerPanel(isOpen: panelOpen,
                                    topInset: proxy.safeAreaInsets.top,
                                    bottomInset: proxy.safeAreaInsets.bottom,
                                    isPersistent: usesSidebar)
                    .offset(x: drawerOffset(usesSidebar: usesSidebar, sidebarVisible: sidebarVisible))
                    .shadow(color: .black.opacity(modalDrawerVisible ? 0.12 : 0), radius: 20, x: 6)
                    .simultaneousGesture(modalDrawerVisible ? closeDrag : nil)
                    .allowsHitTesting(sidebarVisible || modalDrawerVisible)
                    .accessibilityHidden(!sidebarVisible && !modalDrawerVisible)
            }
            .ignoresSafeArea()
            .preferredColorScheme(preferences.appearance.colorScheme)
            .onChange(of: usesSidebar) { _, _ in
                drawerOpen = false
                dragOffset = 0
            }
            // The session drawer belongs to 任务; leaving that tab closes it.
            .onChange(of: selectedTab) { _, tab in
                if tab != .tasks { closeDrawer() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardVisible = false
            }
        }
        #if DEBUG
        // `-uiPreview <screen>` lands straight on one screen, so review passes
        // never depend on taps or swipes. Names match docs/screen-inventory.md.
        .fullScreenCover(item: $preview) { screen in
            NavigationStack { screen.body }
        }
        #endif
        #if DEBUG
        .task {
            // The host loads an empty transcript on boot, so the sample is
            // re-applied for a few seconds after launch.
            guard ChatModel.sampleRequested else { return }
            for _ in 0..<8 {
                ChatModel.installSampleConversationIfRequested()
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
        #endif
    }

    @Environment(\.colorScheme) private var colorScheme

    /// The four bottom-menu pages above the bottom menu. All pages stay alive
    /// (only the selected one is visible and hit-testable) so switching never
    /// drops a draft, a scroll position or a running turn.
    ///
    /// The bar is stacked *below* the pages, not attached as a safe-area
    /// inset: this layer ignores the safe area (the drawer must cover the
    /// whole screen), so an inset would sit on the physical bottom edge and
    /// overlap the pages' own bottom chrome. Stacked, the pages end at the
    /// bar's top edge (so the composer and its stats line rest on it) and the
    /// bar draws the home-indicator area itself from the measured inset. It
    /// leaves while the keyboard is up so the composer rides the keyboard,
    /// and while a second-level page is pushed on the selected tab.
    private func tabPages(usesSidebar: Bool, sidebarVisible: Bool, bottomInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            tabPageStack(usesSidebar: usesSidebar, sidebarVisible: sidebarVisible)
                .frame(maxHeight: .infinity)
            if !keyboardVisible && !pushedTabs.contains(selectedTab) {
                HomeTabBar(selection: $selectedTab, bottomInset: bottomInset)
            }
        }
    }

    private func tabPageStack(usesSidebar: Bool, sidebarVisible: Bool) -> some View {
        ZStack {
            tabPage(.bot) {
                NavigationStack {
                    BotProductionPage().environment(\.botFishPaused, selectedTab != .bot)
                        .toolbar(.hidden, for: .navigationBar)
                        .modifier(tabRoot(.bot))
                }
            }
            tabPage(.tasks) {
                NavigationStack {
                    ChatPage(openDrawer: {
                        if usesSidebar {
                            withAnimation(.easeInOut(duration: 0.22)) { sidebarCollapsed.toggle() }
                        } else {
                            openDrawer()
                        }
                    }, drawerExpanded: sidebarVisible)
                    .modifier(tabRoot(.tasks))
                }
            }
            tabPage(.discover) {
                NavigationStack { ConnectorsPage().modifier(tabRoot(.discover)) }
            }
            tabPage(.me) {
                NavigationStack {
                    SettingsPage(isTab: true, onOpenSession: { selectedTab = .tasks })
                        .modifier(tabRoot(.me))
                }
            }
        }
    }

    private func tabRoot(_ tab: HomeTab) -> TabRootTracker {
        TabRootTracker(tab: tab, pushedTabs: $pushedTabs)
    }

    private func tabPage<Content: View>(_ tab: HomeTab, @ViewBuilder content: () -> Content) -> some View {
        let selected = selectedTab == tab
        return content()
            .opacity(selected ? 1 : 0)
            .allowsHitTesting(selected)
            .accessibilityHidden(!selected)
    }

    /// The phone drawer's x: 0 open, following a leftward drag, fully off
    /// screen (plus its shadow) closed. A persistent sidebar is just shown or hidden.
    private func drawerOffset(usesSidebar: Bool, sidebarVisible: Bool) -> CGFloat {
        if usesSidebar { return sidebarVisible ? 0 : -drawerWidth }
        return drawerOpen ? min(0, dragOffset) : -(drawerWidth + 32)
    }

    /// 1 when the drawer is fully open, falling to 0 as it is dragged away.
    private var drawerProgress: CGFloat {
        drawerOpen ? max(0, 1 + dragOffset / drawerWidth) : 0
    }

    /// 展开 0.28 秒、收回 0.22 秒,用系统那条曲线;已经开着时再点不加第二层。
    private func openDrawer() {
        guard !drawerOpen else { return }
        // Question-card text fields also need to release the keyboard.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        withAnimation(.easeInOut(duration: 0.28)) { drawerOpen = true }
    }

    private func closeDrawer() {
        guard drawerOpen else { return }
        dragOffset = 0
        withAnimation(.easeInOut(duration: 0.22)) { drawerOpen = false }
    }

    private var closeDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // 只跟手往左,而且只认横向为主的拖动:抽屉里上下滑列表不能把它带走。
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragOffset = min(0, value.translation.width)
            }
            .onEnded { value in
                // 拖过一半就收,不到就弹回;甩得够快也算收。
                let projected = value.predictedEndTranslation.width
                if value.translation.width < -drawerWidth / 2 || projected < -drawerWidth / 2 {
                    closeDrawer()
                } else {
                    withAnimation(.easeInOut(duration: 0.22)) { dragOffset = 0 }
                }
            }
    }
}

/// 抽屉面板本体:宽 320、贴左三条边不留圆角、右侧上下两角 22,
/// 顶部从安全区下缘开始,不盖状态栏。
struct SessionsDrawerPanel: View {
    @Binding var isOpen: Bool
    var topInset: CGFloat
    var bottomInset: CGFloat = 0
    var isPersistent = false
    private let width: CGFloat = 320

    var body: some View {
        HomeDrawer(isOpen: $isOpen, topInset: topInset, bottomInset: bottomInset,
                       isPersistent: isPersistent)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(HomeSpec.page)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                              bottomTrailingRadius: isPersistent ? 0 : 22,
                                              topTrailingRadius: isPersistent ? 0 : 22,
                                              style: .continuous))

            // 读屏:整页设成模态,焦点进面板。三条退路并存——点遮罩、面板左滑、
            // 转子里的「关闭会话列表」;两指手势(escape)也留着。
            .accessibilityElement(children: .contain)
            .accessibilityLabel("会话列表")
            .accessibilityAddTraits(isPersistent ? [] : .isModal)
            .accessibilityAction(.escape) { close() }
            .accessibilityAction(named: Text("关闭会话列表")) { close() }
            // 这句会念出来,也让这条退路在无障碍树里查得到:自定义动作本身不进 describe-ui。
            .accessibilityHint(isPersistent ? "" : "两指画 Z 或从转子里选「关闭会话列表」都能收回。")
    }

    private func close() {
        withAnimation(.easeInOut(duration: 0.22)) { isOpen = false }
    }
}

/// The folder list remains a separate page, and each folder opens its files.
struct WorkspaceFoldersPage: View {
    @State private var management = DSHManagementModel.shared
    @State private var showingNewWorkspace = false
    @State private var newWorkspaceName = ""

    var body: some View {
        List {
            ForEach(management.workspaces) { workspace in
                NavigationLink {
                    // The file list is rooted at the materialized workspace;
                    // a folder's absolute host path is not a relative prefix.
                    FilesPage()
                } label: {
                    HStack(spacing: 12) {
                        Text(Self.displayName(workspace))
                            .font(.system(size: HomeSpec.bodySize))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 12)
                        Text(workspace.sessionIDs.count == 1
                             ? "1 个会话"
                             : "\(workspace.sessionIDs.count) 个会话")
                            .font(.system(size: 15))
                            .foregroundStyle(ChatPage.inkSecondary)
                    }
                    .frame(minHeight: 44)
                }
            }
            if management.workspaces.isEmpty {
                VStack(spacing: 8) {
                    Text("还没有工作文件夹")
                        .font(.system(size: HomeSpec.bodySize, weight: .semibold))
                    Text("会话把生成的文件放在文件夹里。新建一个文件夹给它用。")
                        .font(.system(size: 13))
                        .foregroundStyle(ChatPage.inkSecondary)
                        .multilineTextAlignment(.center)
                    Button {
                        showingNewWorkspace = true
                    } label: {
                        Text("添加工作文件夹")
                            .font(.system(size: HomeSpec.bodySize, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(ChatPage.accent, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }
        }
        .homeGroupedList()
        .navigationTitle("工作文件夹")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("添加") { showingNewWorkspace = true }
                    .font(.system(size: HomeSpec.bodySize, weight: .semibold))
                    .foregroundStyle(ChatPage.accent)
            }
        }
        .alert("新建工作文件夹", isPresented: $showingNewWorkspace) {
            TextField("名字", text: $newWorkspaceName)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("取消", role: .cancel) { newWorkspaceName = "" }
            Button("创建") {
                let name = newWorkspaceName
                newWorkspaceName = ""
                Task { _ = await management.createWorkspaceFolder(named: name) }
            }
        } message: {
            // A picked host folder cannot be registered (the Worker stats the
            // VFS); this creates the folder there first.
            Text("会在 DSH 工作区里新建同名文件夹并登记为工作文件夹。")
        }
        .homeGroupedList()
    }

    /// 自带的那个文件夹叫「默认文件夹」,用户自己建的按原名显示。
    static func displayName(_ workspace: ManagedWorkspace) -> String {
        let raw = workspace.title
        if DrawerTitles.isDefaultWorkspace(raw) { return DrawerTitles.defaultFolderName }
        return raw
    }
}

/// One row in the drawer's bottom group: 17pt label, optional secondary count,
/// 48pt tall, chevron on the right.
struct DrawerRow: View {
    let title: String
    let systemImage: String
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 18))
                    .frame(width: 22)
                Text(title).font(.system(size: HomeSpec.bodySize))
                Spacer()
                if let badge {
                    Text(badge).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, NativeHeaderStyle.horizontalInset)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The egress allow list: one address per row, edited through an add dialog and
/// a long-press delete menu. The allow-all switch takes the whole list out of
/// play without hiding it — the rows stay readable and a line in the header says
/// they are not in use.
struct EgressAllowListPage: View {
    @State private var model = ChatModel.shared
    /// 名单本身。开关打开时它只是暂存:回来的时候照原样还给用户。
    @State private var list = ""
    @State private var adding = false
    @State private var draft = ""
    @State private var addProblem: String?
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    private static let stashKey = "phoneDSH.egressListBeforeAllowAll"

    private var allowAll: Bool {
        model.egressAllow.trimmingCharacters(in: .whitespacesAndNewlines) == ChatSettings.allowAllEgress
    }

    private var hosts: [String] {
        Self.parse(list)
    }

    var body: some View {
        List {
            Section {
                Toggle("允许连任何网站", isOn: allowAllBinding)
                    .frame(minHeight: 48)
            } footer: {
                Text("打开之后,下面这些地址就不起作用了。")
            }

            Section {
                if hosts.isEmpty {
                    Text(allowAll ? "现在全部能连。" : "还没有地址,现在连不出去。")
                        .foregroundStyle(SessionsPage.ink)
                        .frame(minHeight: 48)
                    Button {
                        restoreDefaults()
                    } label: {
                        Text("恢复成默认的")
                            .foregroundStyle(ChatPage.accent)
                            .frame(minHeight: 48, alignment: .leading)
                    }
                } else {
                    ForEach(hosts, id: \.self) { host in
                        Text(host)
                            .frame(minHeight: 48)
                            .contentShape(Rectangle())
                            .contextMenu {
                                // 开关开着也留这条:名单里有一张过期的地址,
                                // 用户想清掉的正是它,不能逼他先去关开关。
                                Button("删除这个地址", role: .destructive) {
                                    delete(host)
                                }
                            }
                    }
                }
                // 空名单也能加:只给「恢复成默认的」,用户就没法只加自己要的那一条。
                if !allowAll {
                    Button {
                        draft = ""
                        addProblem = nil
                        adding = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .semibold))
                            Text("添加地址")
                        }
                        .foregroundStyle(ChatPage.accent)
                        .frame(minHeight: 48, alignment: .leading)
                    }
                }
            } header: {
                HStack(spacing: 8) {
                    Text("地址")
                    Spacer(minLength: 8)
                    if allowAll {
                        Text("现在不起作用")
                            .font(.system(size: 13))
                            .textCase(nil)
                            .foregroundStyle(SessionsPage.ink)
                    } else if !hosts.isEmpty {
                        Text("\(hosts.count) 个地址")
                            .font(.system(size: 13))
                            .textCase(nil)
                            .foregroundStyle(SessionsPage.ink)
                    }
                }
            }
        }
        .homeGroupedList()
        .navigationTitle("网络访问")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
        .overlay(alignment: .top) {
            // 名单顶上那一行:滚到哪儿都看得见,两秒自己走。
            if let toast {
                HStack(spacing: 0) {
                    Text(toast)
                        .font(.system(size: 13))
                        .foregroundStyle(SessionsPage.ink)
                        .padding(.leading, 12)
                        .padding(.trailing, 14)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(HomeSpec.userBubble)
                        )
                    Spacer(minLength: 0)
                }
                .padding(.leading, 16)
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
        .overlay {
            if adding {
                addDialog
            }
        }
        .onDisappear { stash() }
    }

    // MARK: - 开关

    private var allowAllBinding: Binding<Bool> {
        Binding(
            get: { allowAll },
            set: { on in
                if on {
                    // 先把当前名单留住,关掉开关时原样还回来。
                    stash()
                    ChatSettings.egressAllow = ChatSettings.allowAllEgress
                    model.egressAllow = ChatSettings.egressAllow
                } else {
                    let saved = Self.parse(UserDefaults.standard.string(forKey: Self.stashKey) ?? "")
                    list = Self.join(saved.isEmpty ? Self.parse(ChatSettings.defaultEgressAllow) : saved)
                    // 关开关这一下必须真的写回去:那个 " * " 就是「全部允许」本身。
                    stash()
                    writeStored()
                }
            }
        )
    }

    // MARK: - 名单

    private func load() {
        if allowAll {
            let saved = UserDefaults.standard.string(forKey: Self.stashKey) ?? ""
            list = Self.join(Self.parse(saved.isEmpty ? ChatSettings.defaultEgressAllow : saved))
        } else {
            list = Self.join(Self.parse(ChatSettings.egressAllow))
        }
    }

    /// 名单变了:先留住,再决定要不要写进配置。
    /// 开关打开时那不是「生效的名单」,只留档,等开关关掉才写回去。
    private func persist() {
        stash()
        guard !allowAll else { return }
        writeStored()
    }

    private func writeStored() {
        ChatSettings.egressAllow = list
        model.egressAllow = list
    }

    private func stash() {
        UserDefaults.standard.set(list, forKey: Self.stashKey)
    }

    private func restoreDefaults() {
        list = Self.join(Self.parse(ChatSettings.defaultEgressAllow))
        stash()
        writeStored()
        show("已恢复成默认的那些地址。")
    }

    private func delete(_ host: String) {
        list = Self.join(hosts.filter { $0 != host })
        persist()
        show("已删掉。它现在连不上了。")
    }

    private func show(_ text: String) {
        toastTask?.cancel()
        toast = text
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    // MARK: - 添加

    private var addDialog: some View {
        ZStack {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture { adding = false }
            VStack(alignment: .leading, spacing: 12) {
                Text("添加地址")
                    .font(.system(size: HomeSpec.bodySize, weight: .semibold))
                TextField("只写域名,不用写 http://", text: $draft)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: 44)
                    .onChange(of: draft) { _, _ in addProblem = nil }
                if let addProblem {
                    Text(addProblem)
                        .font(.system(size: 13))
                        .foregroundStyle(ChatPage.danger)
                }
                HStack(spacing: 12) {
                    Button("取消") { adding = false }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(SessionsPage.ink)
                    Button("添加") { submitDraft() }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(ChatPage.accent)
                        .disabled(Self.trim(draft).isEmpty)
                }
                .font(.system(size: HomeSpec.bodySize))
            }
            .padding(20)
            .frame(maxWidth: 300)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
            )
            .padding(.horizontal, 32)
        }
    }

    private func submitDraft() {
        let value = Self.trim(draft).lowercased()
        // 带 http:// 的、带路径的、带空格的,整条判错——这一页只要域名。
        let looksLikeHost = value.contains(".")
            && !value.contains("/")
            && !value.contains(":")
            && !value.contains(" ")
            && !value.contains("@")
        guard looksLikeHost else {
            addProblem = "只写域名,例如 api.deepseek.com。"
            return
        }
        guard !hosts.contains(value) else {
            adding = false
            return
        }
        list = Self.join(hosts + [value])
        persist()
        adding = false
    }

    // MARK: - 字符串

    private static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parse(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { trim(String($0)).lowercased() }
            .filter { !$0.isEmpty && $0 != ChatSettings.allowAllEgress }
    }

    private static func join(_ hosts: [String]) -> String {
        hosts.joined(separator: ", ")
    }
}

#if DEBUG
/// Debug-only screen router: one launch argument, one screen. Names are the
/// same ones used in docs/screen-inventory.md.
enum PreviewScreen: String, Identifiable, CaseIterable {
    case settings
    case settingsModel = "settings.model"
    case settingsModelAdd = "settings.model.add"
    case settingsSearch = "settings.search"
    case settingsNetwork = "settings.network"
    case settingsPlugins = "settings.plugins"
    case settingsPermissions = "settings.permissions"
    case settingsPermissionsTab = "settings.permissions.tab"
    case settingsAbout = "settings.about"
    case settingsRuntime = "settings.runtime"
    case filesPreviewText = "files.preview.text"
    case filesPreviewMarkdown = "files.preview.markdown"
    case filesPreviewHTML = "files.preview.html"
    case filesPreviewChat = "files.preview.chat"
    case filesPreviewFiles = "files.preview.files"
    case filesPreviewLong = "files.preview.long"
    case filesPreviewPDF = "files.preview.pdf"
    case filesPreviewImage = "files.preview.image"
    case filesPreviewOffice = "files.preview.office"
    case filesPreviewAudio = "files.preview.audio"
    case filesPreview3D = "files.preview.3d"
    case sessions
    case sessionsSchedules = "sessions.schedules"
    case workspace
    case workspaceFiles = "workspace.files"
    case configuration
    case chatAssistant = "chat.assistant"
    case chatOfficial = "chat.official"
    case chatFailed = "chat.failed"
    case chatQueued = "chat.queued"
    case chatPermission = "chat.permission"
    case chatQuestion = "chat.question"
    case sessionsMany = "sessions.many"
    case sessionsEmpty = "sessions.empty"
    case sessionsNothing = "sessions.nothing"
    case sessionsUngrouped = "sessions.ungrouped"
    case sessionsError = "sessions.error"
    case chatLong = "chat.long"
    case chatDraft = "chat.draft"
    case codeBlock = "code.block"

    var id: String { rawValue }

    static var requested: PreviewScreen? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-uiPreview"),
              arguments.count > index + 1 else { return nil }
        let value = arguments[index + 1]
        guard value != "sample" else { return nil }
        return PreviewScreen(rawValue: value)
    }

    @MainActor
    @ViewBuilder
    var body: some View {
        switch self {
        case .settings: SettingsPage()
        case .settingsModel: ModelProviderSettingsPage()
        case .settingsModelAdd:
            ModelProviderEditorPage(profile: ProviderProfile(id: "", displayName: "", baseURL: "https://api.deepseek.com/v1", model: "deepseek-flash"), isNew: true, onSaved: { _ in })
        case .settingsSearch: WebSearchSettingsPage()
        case .settingsNetwork: EgressAllowListPage()
        case .settingsPlugins: NativeConfigurationPage()
        case .settingsPermissions: PhonePermissionsPage(preview: true)
        case .settingsPermissionsTab: SettingsPage(initialTab: .permissions)
        case .settingsAbout: SettingsAboutPage()
        case .settingsRuntime: RuntimeDetailsPage(model: ChatModel.shared)
        case .filesPreviewText:
            PreviewDebugRoute(path: "preview-fixtures/notes.txt",
                              text: "第一行：预览已经可以直接从会话打开。\n第二行：长文本会分页加载，不再只显示 200 行。\n第三行：关闭一次就能回到来源。\n")
        case .filesPreviewMarkdown:
            PreviewDebugRoute(path: "preview-fixtures/notes.md",
                              text: "# 预览验收\n\n这是 Markdown 预览。\n\n- 直接打开，不经过文件列表\n- 深色模式可读\n\n```swift\nlet preview = true\n```\n")
        case .filesPreviewHTML:
            PreviewDebugRoute(path: "preview-fixtures/page.html",
                              text: "<!doctype html><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><style>body{font:16px -apple-system;padding:24px;background:#fff;color:#111}h1{font-size:28px}</style><h1>HTML 预览</h1><p id=\"s\">JavaScript 未运行。</p><script>document.getElementById('s').textContent='JavaScript 已运行 · '+(1+1);</script>")
        case .filesPreviewChat:
            PreviewDebugChat(path: "preview-fixtures/notes.txt")
        case .filesPreviewFiles:
            PreviewDebugFiles(path: "preview-fixtures/notes.md")
        case .filesPreviewLong:
            PreviewDebugLong(path: "preview-fixtures/long.log")
        case .filesPreviewPDF:
            PreviewDebugPDF(path: "preview-fixtures/sample.pdf")
        case .filesPreviewImage:
            PreviewDebugImage(path: "preview-fixtures/sample.png")
        case .filesPreviewOffice:
            PreviewDebugOffice(path: "preview-fixtures/sample.rtf")
        case .filesPreviewAudio:
            PreviewDebugAudio(path: "preview-fixtures/sample.wav")
        case .filesPreview3D:
            PreviewDebug3D(path: "preview-fixtures/cube.glb")
        case .sessions: SessionsPage(onSelect: {})
        case .sessionsSchedules: NativeAutomationPage()
        case .workspace: WorkspaceFoldersPage()
        case .workspaceFiles: FilesPage()
        case .configuration: PDSHShellPage()
        case .chatAssistant: ChatPage(previewItems: PreviewChatItems.assistant)
        case .chatOfficial: ChatPage(previewItems: PreviewChatItems.official)
        case .chatFailed: ChatPage(previewItems: PreviewChatItems.failed)
        case .chatQueued: ChatPage(previewItems: PreviewChatItems.queued)
        case .chatQuestion: ChatPage(previewItems: PreviewChatItems.assistant)
        case .sessionsMany:
            DrawerPreview(sessionCount: 40)
        case .sessionsEmpty:
            DrawerPreview(sessionCount: 0)
        case .sessionsUngrouped:
            // 只有不归属文件夹的会话:大空态一个字都不该出现。
            DrawerPreview(sessionCount: 3, workspaceCount: 0)
        case .sessionsError:
            // 读不到会话:一行报错 + 行尾重试,恢复后整行消失。
            DrawerPreview(sessionCount: 2, workspaceCount: 1, forcedError: "读不到会话")
        case .sessionsNothing:
            // 真·全空:一个会话、一个工作文件夹都没有,验空态离新建行 24。
            DrawerPreview(sessionCount: 0, workspaceCount: 0)
        case .chatLong:
            ChatPage(previewItems: PreviewChatItems.longThread, previewDraft: PreviewChatItems.draft5000)
        case .chatDraft:
            // 空对话 + 超长草稿:只看输入框长什么样,不被同文本的气泡干扰。
            ChatPage(previewItems: [], previewDraft: PreviewChatItems.draft5000)
        case .chatPermission:
            // 权限卡单独一屏,拿真数据前也能验收文案与两个按钮。
            VStack(alignment: .leading, spacing: 0) {
                Color.white
                PermissionCardView(permission: ChatPermission(id: "p-perm",
                                                              tool: "write_file",
                                                              summary: "",
                                                              arguments: ["path": "notes/todo.md"]))
                PermissionCardView(permission: ChatPermission(id: "p-perm2",
                                                              tool: "run_command",
                                                              summary: "",
                                                              arguments: ["command": "swift build"]))
                    .background(Color.white)
                Color.white
            }
            .background(Color.white)
        case .codeBlock:
            ScrollView {
                DSSCodeBlock(source: PreviewChatItems.longCode, language: "swift")
                    .padding(.horizontal, 16)
                    .padding(.top, 40)
            }
        }
    }
}

/// 抽屉的预览外壳:宽 320、白底,里面就是真正的 SessionsPage。
/// 只给验收用,数据由 `installPreviewData` 造假,不碰宿主。
struct DrawerPreview: View {
    let sessionCount: Int
    var workspaceCount: Int = 2
    var forcedError: String? = nil
    let management = DSHManagementModel.shared

    var body: some View {
        VStack(spacing: 0) {
            SessionsPage(onSelect: {})
        }
        .frame(width: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white)
        .task {
            management.installPreviewData(sessionCount: sessionCount, workspaceCount: workspaceCount)
            if let forcedError { management.installPreviewError(forcedError) }
        }
    }
}

#endif

/// The About page is used by production settings in every build configuration.
struct SettingsAboutPage: View {
    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image("LogoBackground")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    Text("Phone DSH")
                        .font(.system(size: HomeSpec.navTitleSize, weight: .semibold))
                    Text("运行在手机上的 DeepSeek Harness")
                        .font(.system(size: 14))
                        .foregroundStyle(HomeSpec.textPlaceholder)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }
            Section {
                LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                LabeledContent("构建", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
            } footer: {
                Text("会话记录和文件都保存在这台手机上。")
            }
        }
        .homeGroupedList()
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#if DEBUG
/// 预览用的一份消息,本地造的,不碰宿主。
enum PreviewChatItems {
    static let user1 = ChatItem(id: "p-u1", kind: .user, title: "你", text: "hello test 123")
    static let user2 = ChatItem(id: "p-u2", kind: .user, title: "你",
                                text: "Create note.txt in the workspace with content hello dsh")
    static let tool = ChatItem(id: "p-tool", kind: .toolCall, title: "工具",
                               text: "Read · Package.swift")
    static let assistantReply = ChatItem(id: "p-a1", kind: .assistant, title: "DSH", text: """
    先看了工程的入口,`.build` 目录已经在忽略列表里。

    ```swift
    let scheme = "PhoneDSHProbe"
    let destination = "platform=iOS Simulator"
    ```

    接下来我会把这一段改动落到 `ChatPage.swift`,然后重新编译验证。
    """)

    static var official: [ChatItem] {
        let now = Date()
        var rows: [ChatItem] = []
        var user = ChatItem(id: "official-user", kind: .user, title: "You",
                            text: "请把官方 DSH 的消息结构完整适配到 iOS 原生。")
        user.turn = 1
        user.timestamp = now.addingTimeInterval(-180)
        rows.append(user)
        var context = ChatItem(id: "official-context", kind: .context,
                               title: "DSH context · agent-instructions",
                               text: "PDSH_CONTEXT_INJECTION_MUST_NOT_APPEAR")
        context.turn = 1
        rows.append(context)
        var thinking = ChatItem(id: "official-thinking", kind: .reasoning, title: "思考",
                                text: "先对照官方事件结构。\n需要保留 thinking、工具和 Markdown 的原始顺序。\n\n再检查输入区和统计。")
        thinking.turn = 1
        rows.append(thinking)
        var bash = ChatItem(id: "official-bash", kind: .toolCall, title: "Tool call: bash", text: "")
        bash.turn = 1
        bash.callID = "official-bash-call"
        bash.toolName = "bash"
        bash.argumentsRaw = #"{"command":"xcodebuild test","description":"运行原生回归测试"}"#
        bash.arguments = .object(["command": .string("xcodebuild test"), "description": .string("运行原生回归测试")])
        bash.toolOutput = "12 tests passed"
        bash.toolMetadata = .object(["exitCode": .number(0)])
        bash.toolState = .ok
        rows.append(bash)
        let paths = ["DESIGN.md", "PRD.md", "app-map.md", "states.md", "NativeChat.swift", "NativeMarkdown.swift"]
        for (index, path) in paths.enumerated() {
            var edit = ChatItem(id: "official-edit-\(index)", kind: .toolCall, title: "Tool call: edit", text: "")
            edit.turn = 1
            edit.callID = "official-edit-call-\(index)"
            edit.toolName = "edit"
            edit.argumentsRaw = #"{"file_path":"docs/design/phone-dsh-app/\#(path)"}"#
            edit.arguments = .object([
                "file_path": .string("docs/design/phone-dsh-app/\(path)"),
                "old_string": .string("旧结构"),
                "new_string": .string("官方原生结构"),
            ])
            edit.toolOutput = "Updated"
            edit.toolState = .ok
            rows.append(edit)
        }
        var answer = ChatItem(id: "official-answer", kind: .assistant, title: "Assistant", text: """
        ## 官方消息结构

        正文支持 **粗体**、*斜体*、~~删除线~~、`Package.swift` 和 [安全链接](https://github.com/deepseek-ai/deepseek-harness)。

        - [x] thinking 与工具调用
        - [ ] iOS 原生 Markdown

        > 消息、过程和输入区使用同一套官方结构。

        | 模块 | 状态 |
        |:--|--:|
        | Markdown | 原生 |
        | TeX | $x^2 + y^2 = z^2$ |

        ```swift
        struct NativeChat: View {
            let official = true
        }
        ```

        $$
        E = mc^2
        $$

        原始 HTML 保持字面：<b>不会执行</b>。[^note]

        [^note]: 流式与历史恢复使用同一事件投影。
        """)
        answer.turn = 1
        answer.timestamp = now
        answer.messageID = "official-message"
        answer.turnUsage = NativeTurnUsage(value: .object([
            "inputTokens": .number(48_000), "outputTokens": .number(2_160),
            "cacheReadTokens": .number(150_000), "cacheWriteTokens": .number(0),
        ]))
        rows.append(answer)
        return rows
    }

    /// 一条很长的用户消息 + 一条长回答,用来验正文不折叠、行高不炸。
    static let longThread: [ChatItem] = [
        ChatItem(id: "p-l1", kind: .user, title: "你", text: draft5000),
        ChatItem(id: "p-l2", kind: .assistant, title: "DSH", text: String(repeating: "这段是模型的回答,用来核对长正文的行高与滚动是否正常。\n", count: 12))
    ]

    /// 5000 字,含换行、中英混排、长英文单词和数字,验输入框在极限下的样子。
    static let draft5000: String = {
        let unit = "把这句话放进输入框里,看看行高和滚动还正不正常。Mixed English words like accessibilityIdentifier and 1234567890 should wrap.\n"
        var text = ""
        while text.count < 5000 { text += unit }
        return String(text.prefix(5000))
    }()

    static let longCode = """
    let scheme = "PhoneDSHProbeExampleLongLineToCheckHorizontalScroll"
    let destination = "platform=iOS Simulator,id=65F16681"
    """

    static var assistant: [ChatItem] { [user1, tool, assistantReply] }
    static var failed: [ChatItem] { [user1, user2] }
    static var queued: [ChatItem] { [user1, ChatItem(id: "p-u3", kind: .user, title: "你",
                                                     text: "把这周的日志按天归档")] }
}
#endif

/// Marks a tab's root page: a push covers it (onDisappear) and a pop shows it
/// again (onAppear). Tabs switch by opacity, which fires neither, and sheets
/// leave the root on screen, so only navigation pushes hide the bar.
private struct TabRootTracker: ViewModifier {
    let tab: HomeTab
    @Binding var pushedTabs: Set<HomeTab>

    func body(content: Content) -> some View {
        content
            .onAppear { pushedTabs.remove(tab) }
            .onDisappear { pushedTabs.insert(tab) }
    }
}
