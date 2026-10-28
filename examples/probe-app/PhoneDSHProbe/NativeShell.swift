// SPDX-License-Identifier: MIT
// NativeShell.swift
// 原生外壳的骨架（重构第一步）：底部四标签 对话 / 会话 / 工作区 / 设置。
// 会话占一格是产品决定（高频检索）；定时任务并进会话页的第二段。

import SwiftUI

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

/// The one status indicator: green means the host is running, amber means it is
/// parked in the background, grey means stopped.
struct RunStatusDot: View {
    let started: Bool
    let parked: Bool

    private var color: Color {
        if parked { return Color(red: 0xC7 / 255, green: 0x77 / 255, blue: 0) }
        return started
            ? Color(red: 0x0E / 255, green: 0x9F / 255, blue: 0x6E / 255)
            : Color(uiColor: .tertiaryLabel)
    }

    private var label: String {
        if parked { return "后台暂停" }
        return started ? "运行中" : "未启动"
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: NativeHeaderStyle.statusDot, height: NativeHeaderStyle.statusDot)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .padding(.trailing, 4)
    }
}

/// The app is one screen: the conversation. Everything else is reached from the
/// sessions drawer in the top-left, the way phone coding clients do it. There is
/// deliberately no bottom tab bar.
struct NativeShell: View {
    init() {
        // 页面底全 App 纯白:分组列表默认那层 #F2F2F7 会和白卡片叠出接缝,
        // 分层靠间距和分隔线,不靠底色差。
        UITableView.appearance().backgroundColor = .white
        UICollectionView.appearance().backgroundColor = .white
    }

    @State private var drawerOpen = false
    @State private var dragOffset: CGFloat = 0
    private let drawerWidth: CGFloat = 320
    #if DEBUG
    @State private var preview = PreviewScreen.requested
    #endif

    var body: some View {
        // 推走式:菜单在下层,固定不动;当前页面整体右移 320 把菜单让出来,
        // 中间没有遮罩。点页面、在页面上左滑、转子里的「关闭会话列表」都能收回。
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                SessionsDrawerPanel(isOpen: $drawerOpen,
                                    topInset: proxy.safeAreaInsets.top,
                                    bottomInset: proxy.safeAreaInsets.bottom)
                    .allowsHitTesting(drawerOpen)
                    .accessibilityHidden(!drawerOpen)

                NavigationStack {
                    ChatPage(openDrawer: { openDrawer() })
                }
                // 白对白时阴影不够用,再加一条 0.5 的断线:#D5D4DB,只贴页面左缘、只在抽屉开着时出现。
                // 它挂在页面自己身上(所以在 offset 之前),跟着页面走;0.5 宽不参与布局,
                // 也不随内容滚动。阴影保持原深度,两样一起加深会变成一道黑边。
                .overlay(alignment: .leading) {
                    if drawerOpen {
                        Rectangle()
                            .fill(Color(red: 0xD5 / 255, green: 0xD4 / 255, blue: 0xDB / 255))
                            .frame(width: 0.5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .offset(x: contentOffset)
                // 页面左缘一条柔和阴影,让它看得出压在菜单上面。
                .shadow(color: .black.opacity(contentOffset > 0 ? 0.18 : 0), radius: 16, x: -8)
                .accessibilityHidden(drawerOpen)

                // 「点页面任意处收回」只盖页面露出来的那块,不盖抽屉。
                // 这一层必须靠布局定位(左边让出 contentOffset),不能挂在被 offset 的页面上:
                // overlay 的命中区停在改写前的 0..402,抽屉那 320 点整块被它吃掉,
                // 于是抽屉里所有控件都点不动。
                if drawerOpen {
                    HStack(spacing: 0) {
                        Color.clear
                            .frame(width: max(0, min(drawerWidth, contentOffset)))
                            .allowsHitTesting(false)
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { closeDrawer() }
                            .gesture(closeDrag)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
                }
            }
            .ignoresSafeArea()
            // 菜单盖着状态栏那一条,那上面的字必须深色;只有抽屉开着时把外观压成浅色。
            .preferredColorScheme(drawerOpen ? .light : nil)
        }
        #if DEBUG
        // `-uiPreview <screen>` lands straight on one screen, so review passes
        // never depend on taps or swipes. Names match docs/screen-inventory.md.
        .fullScreenCover(item: $preview) { screen in
            NavigationStack { screen.body }
                // The review cover has no way back by construction (each screen
                // is the root of its own stack); this dismiss button keeps the
                // screenshot pass from looking like a set of dead ends.
                .overlay(alignment: .topLeading) {
                    Button {
                        preview = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .accessibilityLabel("关闭预览")
                }
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

    /// 页面右移的距离:开着是 320,拖动时跟手减。
    private var contentOffset: CGFloat {
        drawerOpen ? max(0, drawerWidth + dragOffset) : 0
    }

    /// 展开 0.28 秒、收回 0.22 秒,用系统那条曲线;已经开着时再点不加第二层。
    private func openDrawer() {
        guard !drawerOpen else { return }
        withAnimation(.easeInOut(duration: 0.28)) { drawerOpen = true }
    }

    private func closeDrawer() {
        guard drawerOpen else { return }
        dragOffset = 0
        withAnimation(.easeInOut(duration: 0.22)) { drawerOpen = false }
    }

    private var closeDrag: some Gesture {
        DragGesture()
            .onChanged { value in
                // 只跟手往左:往右没有东西可让。
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
    private let width: CGFloat = 320

    var body: some View {
        SessionsDrawer(isOpen: $isOpen, topInset: topInset, bottomInset: bottomInset)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            // 面板是白纸,不跟系统深色走:盖到状态栏下面时,状态栏的字必须是深色。
            .background(Color.white)
            .environment(\.colorScheme, .light)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                              bottomTrailingRadius: 22, topTrailingRadius: 22,
                                              style: .continuous))

            // 读屏:整页设成模态,焦点进面板。三条退路并存——点遮罩、面板左滑、
            // 转子里的「关闭会话列表」;两指手势(escape)也留着。
            .accessibilityElement(children: .contain)
            .accessibilityLabel("会话列表")
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape) { close() }
            .accessibilityAction(named: Text("关闭会话列表")) { close() }
            // 这句会念出来,也让这条退路在无障碍树里查得到:自定义动作本身不进 describe-ui。
            .accessibilityHint("两指画 Z 或从转子里选「关闭会话列表」都能收回。")
    }

    private func close() {
        withAnimation(.easeInOut(duration: 0.22)) { isOpen = false }
    }
}

/// Sessions, scheduled tasks, work folders — and settings as its last row, so
/// the drawer is the only map of the app.
struct SessionsDrawer: View {
    @Binding var isOpen: Bool
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    @State private var showSettings = false
    @State private var showSchedules = false
    @State private var showFolders = false
    @State private var management = DSHManagementModel.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // One 44pt row, not a large title plus a toolbar: the drawer
                // covers the screen, so closing must be visible, and a second
                // control in this row would make the title ambiguous.
                HStack(spacing: 0) {
                    Text("会话")
                        .font(.system(size: 17, weight: .semibold))
                    Spacer()
                }
                .padding(.leading, NativeHeaderStyle.horizontalInset)
                .frame(height: NativeHeaderStyle.barHeight)
                // 面板贴屏幕顶;NavigationStack 自己已经让开安全区,这里只补设计的 16。
                .padding(.top, 16)

                SessionsPage(onSelect: { isOpen = false })
                    .toolbar(.hidden, for: .navigationBar)

                Divider()

                // The three global entries sit together at the bottom, out of
                // the session list, so they read as the app's furniture.
                VStack(spacing: 0) {
                    DrawerRow(title: "定时任务", systemImage: "clock.arrow.circlepath", badge: management.scheduleRecords.isEmpty ? nil : "\(management.scheduleRecords.count)") {
                        showSchedules = true
                    }
                    DrawerRow(title: "工作文件夹", systemImage: "folder", badge: management.workspaces.isEmpty ? nil : "\(management.workspaces.count)") {
                        showFolders = true
                    }
                    DrawerRow(title: "设置", systemImage: "gearshape") {
                        showSettings = true
                    }
                }
                .background(Color.white)
                .padding(.bottom, bottomInset + 16)
            }
            .background(Color.white)
            .sheet(isPresented: $showSettings) {
                NavigationStack { SettingsPage() }
                    .presentationDragIndicator(.visible)
            }
            .navigationDestination(isPresented: $showSchedules) { NativeAutomationPage() }
            .navigationDestination(isPresented: $showFolders) { WorkspaceFoldersPage() }
        }
    }
}

/// The folder list is its own page: from the drawer it is one row, and each
/// folder opens the file list for that folder.
struct WorkspaceFoldersPage: View {
    @State private var management = DSHManagementModel.shared
    @State private var pickingFolder = false

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
                            .font(.system(size: 17))
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
                        .font(.system(size: 17, weight: .semibold))
                    Text("会话把生成的文件放在文件夹里。挑一个手机上的文件夹给它用。")
                        .font(.system(size: 13))
                        .foregroundStyle(ChatPage.inkSecondary)
                        .multilineTextAlignment(.center)
                    Button {
                        pickingFolder = true
                    } label: {
                        Text("添加工作文件夹")
                            .font(.system(size: 17, weight: .semibold))
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
        .navigationTitle("工作文件夹")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("添加") { pickingFolder = true }
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ChatPage.accent)
            }
        }
        .fileImporter(isPresented: $pickingFolder,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await management.createWorkspace(at: url.path) }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.white)
    }

    /// 自带的那个文件夹叫「默认文件夹」,用户自己建的按原名显示。
    static func displayName(_ workspace: ManagedWorkspace) -> String {
        let raw = workspace.title
        if raw.lowercased() == "workspace" { return "默认文件夹" }
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
                Text(title).font(.system(size: 17))
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
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16))
            } footer: {
                Text("打开之后,下面这些地址就不起作用了。")
            }

            Section {
                if hosts.isEmpty {
                    Text(allowAll ? "现在全部能连。" : "还没有地址,现在连不出去。")
                        .foregroundStyle(SessionsPage.ink)
                        .frame(minHeight: 48)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16))
                    Button {
                        restoreDefaults()
                    } label: {
                        Text("恢复成默认的")
                            .foregroundStyle(ChatPage.accent)
                            .frame(minHeight: 48, alignment: .leading)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16))
                    }
                } else {
                    ForEach(hosts, id: \.self) { host in
                        Text(host)
                            .frame(minHeight: 48)
                            .contentShape(Rectangle())
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16))
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
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16))
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
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.white)
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
                                .fill(Color(red: 0xF2 / 255, green: 0xF3 / 255, blue: 0xF5 / 255))
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
                    .font(.system(size: 17, weight: .semibold))
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
                .font(.system(size: 17))
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
    case settingsSearch = "settings.search"
    case settingsNetwork = "settings.network"
    case settingsPlugins = "settings.plugins"
    case settingsAbout = "settings.about"
    case settingsRuntime = "settings.runtime"
    case sessions
    case sessionsSchedules = "sessions.schedules"
    case workspace
    case workspaceFiles = "workspace.files"
    case configuration
    case chatAssistant = "chat.assistant"
    case chatFailed = "chat.failed"
    case chatQueued = "chat.queued"
    case chatPermission = "chat.permission"
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

    @ViewBuilder
    var body: some View {
        switch self {
        case .settings: SettingsPage()
        case .settingsModel: ModelProviderSettingsPage()
        case .settingsSearch: WebSearchSettingsPage()
        case .settingsNetwork: EgressAllowListPage()
        case .settingsPlugins: NativeConfigurationPage()
        case .settingsAbout: SettingsAboutPage()
        case .settingsRuntime: RuntimeDetailsPage(model: ChatModel.shared)
        case .sessions: SessionsPage(onSelect: {})
        case .sessionsSchedules: NativeAutomationPage()
        case .workspace: WorkspaceFoldersPage()
        case .workspaceFiles: FilesPage()
        case .configuration: PDSHShellPage()
        case .chatAssistant: ChatPage(previewItems: PreviewChatItems.assistant)
        case .chatFailed: ChatPage(previewItems: PreviewChatItems.failed)
        case .chatQueued: ChatPage(previewItems: PreviewChatItems.queued)
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

/// 抽屉的预览外壳:宽 320、白底、页头一行,里面就是真正的 SessionsPage。
/// 只给验收用,数据由 `installPreviewData` 造假,不碰宿主。
struct DrawerPreview: View {
    let sessionCount: Int
    var workspaceCount: Int = 2
    var forcedError: String? = nil
    let management = DSHManagementModel.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("会话").font(.system(size: 17, weight: .semibold))
                Spacer()
            }
            .padding(.leading, 16)
            .frame(height: 44)
            .padding(.top, 16)

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

/// The 关于 group on its own, for review screenshots.
struct SettingsAboutPage: View {
    var body: some View {
        List {
            LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            Text("会话记录和文件都保存在这台手机上。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif

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
