// SPDX-License-Identifier: MIT

import ProbeKit
import SwiftUI
import UIKit

enum ShellChatRoute: Hashable {
    case model
}

struct AppShell: View {
    @State private var chat = ChatModel.shared
    @State private var composition = AppComposition.shared
    @AppStorage("personalAgent.displayName") private var agentName = "小肥鱼"
    @AppStorage("personalAgent.ownerName") private var ownerName = ""
    @AppStorage("personalAgent.onboarding.completed") private var onboardingCompleted = false
    @State private var connectorModel = DiscoverConnectorModel()
    @State private var connectorConfiguration = ConnectorConfigurationModel()
    @State private var attention = AppAttentionModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: AppTab
    @State private var chatPath: [ShellChatRoute] = []
    @State private var discoverPath: [DiscoverRoute] = []
    @State private var profilePath: [ProfileRoute] = []
    @State private var chatFocus: ChatFocus?
    @State private var dshApprovalFocus: String?
    @State private var keyboardVisible = false
    @State private var handledLaunchRoute = false
    @State private var dshRouteTask: Task<Void, Never>?
    private let attentionSources: [any AttentionSource]

    init(initialTab: AppTab? = nil, attentionSources: [any AttentionSource]? = nil) {
        self.attentionSources = attentionSources ?? [
            AppComposition.shared.chatAttention,
            ConnectorAttentionSource(registry: AppComposition.shared.registry),
        ]
        _selection = State(initialValue: initialTab ?? Self.previewInitialTab ?? .chat)
    }

    private var dockBottomInset: CGFloat {
        keyboardVisible || componentPreviewActive ? 0 : AppDockMetrics.reservedHeight
    }

    private var componentPreviewActive: Bool {
        #if DEBUG
        if let preview = PreviewScreen.requested { return !preview.isAppShellPreview }
        #endif
        return false
    }

    private var needsOnboarding: Bool {
        guard !onboardingCompleted, ownerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              agentName == "Personal Agent" || agentName == "小肥鱼" else { return false }
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-personalOnboarding") { return true }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return false }
        #if DEBUG
        if PreviewScreen.requested != nil { return false }
        #endif
        return true
    }

    private var badges: [AppTab: Int] {
        [
            .chat: attention.chatItems.count,
            .dsh: attention.dshItems.count + directDSHAttentionCount,
            .discover: attention.discoverItems.count,
        ]
    }

    private var directDSHAttentionCount: Int {
        Int(chat.pendingPermission == nil ? 0 : 1)
            + Int(chat.pendingQuestion == nil ? 0 : 1)
            + Int(chat.engineNeedsReset ? 1 : 0)
    }

    var body: some View {
        if needsOnboarding {
            PersonalAgentOnboardingPage()
        } else {
            appContent
        }
    }

    private var appContent: some View {
        ZStack {
            retained(.chat) { chatRoot }
            retained(.dsh) {
                NativeShell(dockBottomInset: dockBottomInset, approvalFocusID: dshApprovalFocus)
            }
            retained(.discover) { discoverRoot }
            retained(.profile) { profileRoot }
        }
        .background(HomeSpec.page)
        .toolbar(selection == .dsh ? .hidden : .visible, for: .navigationBar)
        .tint(HomeSpec.textPrimary)
        .overlay(alignment: .bottom) {
            if !keyboardVisible && !componentPreviewActive {
                AppDock(selection: selection, badges: badges, onSelect: select)
                    .padding(.bottom, AppDockMetrics.bottomSpacing)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            VisibleAnchorView(anchor: chat.anchor)
                .frame(width: 2, height: 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        #if DEBUG
        .overlay(alignment: .bottomTrailing) {
            Text("DSH Worker 锚点")
                .font(.system(size: 1))
                .opacity(0.01)
                .frame(width: 8, height: 8)
                .allowsHitTesting(false)
                .accessibilityLabel("DSH Worker 锚点")
                .accessibilityIdentifier("shell.worker-anchor")
                .accessibilityHidden(false)
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeOut(duration: 0.18)) { keyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.18)) { keyboardVisible = false }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { keyboardVisible = false }
        }
        .onOpenURL { url in
            if let route = AppDeepLink.parse(url) { open(route) }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDeepLink.notificationName)) { notification in
            let url = notification.object as? URL
                ?? (notification.userInfo?["route"] as? String).flatMap(URL.init(string:))
            if let url, let route = AppDeepLink.parse(url) { open(route) }
        }
        .task {
            attention.start(sources: attentionSources)
            await connectorModel.refresh()
            try? await composition.chatAttention.refresh()
            Task {
                await composition.recoverOperations()
                try? await composition.chatAttention.refresh()
            }
            guard !handledLaunchRoute else { return }
            handledLaunchRoute = true
            if let route = AppDeepLink.launchRoute() { open(route) }
        }
        .task {
            while !Task.isCancelled {
                try? await composition.chatAttention.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onDisappear {
            attention.stop()
            dshRouteTask?.cancel()
        }
    }

    @ViewBuilder
    private func retained<Content: View>(_ tab: AppTab,
                                         @ViewBuilder content: () -> Content) -> some View {
        Group {
            if selection == tab {
                content()
            } else {
                content().hidden()
            }
        }
        .allowsHitTesting(selection == tab)
        .accessibilityHidden(selection != tab)
        .zIndex(selection == tab ? 1 : 0)
    }

    private var chatRoot: some View {
        NavigationStack(path: $chatPath) {
            PersonalAgentChatPage(
                model: composition.personalModel, focus: chatFocus,
                connectors: connectorModel.records.values.sorted { $0.connectorID < $1.connectorID },
                dailyBrief: .shared, followUpCoordinator: composition.followUpCoordinator,
                bottomInset: dockBottomInset,
                onConfigureModel: { chatPath = [.model] },
                onOpenDSH: { open(.dsh(sessionID: nil, approvalID: nil)) },
                onManageConnector: { id in
                    if let id { open(.discover(.connector(id))) }
                    else { open(.discover(nil)) }
                },
                onOpenMemory: {
                    selection = .profile
                    profilePath = [.personalAgent]
                },
                onUndoOperation: { id in
                    Task { await composition.personalModel.undoOperation(id) }
                })
            .navigationDestination(for: ShellChatRoute.self) { route in
                switch route {
                case .model: ModelProviderSettingsPage()
                }
            }
        }
    }

    private var discoverRoot: some View {
        NavigationStack(path: $discoverPath) {
            DiscoverPage(model: connectorModel, dockBottomInset: dockBottomInset)
                .navigationDestination(for: DiscoverRoute.self) { route in
                    switch route {
                    case .connector(let id):
                        let descriptor = DiscoverConnectorDescriptor.all.first { $0.id == id }
                            ?? DiscoverConnectorDescriptor.github
                        ConnectorDetailPage(descriptor: descriptor, model: connectorModel) {
                            open(.chat(focus: nil))
                        } configuration: {
                            ConnectorConfigurationView(connectorID: id, model: connectorConfiguration)
                        }
                    case .plugins(let focus):
                        PluginCatalogPage(focus: focus)
                    case .devices:
                        NativeDeviceConnectionPage()
                    }
                }
        }
        .toolbar(.visible, for: .navigationBar)
    }

    private var profileRoot: some View {
        NavigationStack(path: $profilePath) {
            ProfilePage(dockBottomInset: dockBottomInset)
                .navigationDestination(for: ProfileRoute.self) { route in
                    switch route {
                    case .personalAgent: PersonalAgentSettingsPage()
                    case .memory:
                        PersonalMemoryPage(store: composition.memories,
                                           principal: composition.personalModel.principal,
                                           domainStore: composition.domain)
                    case .model: ModelProviderSettingsPage()
                    case .permissionDefaults: makePermissionDefaultsView()
                    case .phonePermissions: PhonePermissionsPage(embedded: true)
                    case .network: EgressAllowListPage()
                    case .folders: WorkspaceFoldersPage()
                    case .archivedSessions: makeArchivedSessionsView()
                    case .engine: RuntimeDetailsPage(model: chat)
                    case .general: ProfileGeneralSettingsPage()
                    case .about: SettingsAboutPage()
                    case .licenses: makeLicensesView()
                    }
                }
        }
        .toolbar(.visible, for: .navigationBar)
    }

    private func select(_ tab: AppTab) {
        if tab == .chat { composition.refreshModelConfiguration() }
        if tab == .dsh, chat.pendingPermission != nil || chat.pendingQuestion != nil {
            open(.dsh(sessionID: chat.currentSessionID,
                      approvalID: chat.pendingPermission?.id ?? chat.pendingQuestion?.requestID))
            return
        }
        if tab != .profile, let item = attention.items(for: owner(for: tab)).first {
            open(item.route)
            return
        }
        if selection == tab {
            switch tab {
            case .chat: chatPath.removeAll()
            case .dsh: break
            case .discover: discoverPath.removeAll()
            case .profile: profilePath.removeAll()
            }
        }
        selection = tab
    }

    private func owner(for tab: AppTab) -> AttentionOwner {
        switch tab {
        case .chat: .chat
        case .dsh: .dsh
        case .discover: .discover
        case .profile: .discover
        }
    }

    private func open(_ route: AppRoute) {
        switch route {
        case .chat(let focus):
            composition.refreshModelConfiguration()
            chatPath.removeAll()
            chatFocus = focus
            selection = .chat
        case .dsh(let sessionID, let approvalID):
            dshApprovalFocus = approvalID
            selection = .dsh
            if let sessionID, sessionID != chat.currentSessionID {
                dshRouteTask?.cancel()
                dshRouteTask = Task { @MainActor in
                    for _ in 0..<600 {
                        if chat.isStarted && !chat.busy {
                            await chat.selectSession(sessionID)
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(100))
                        if Task.isCancelled { return }
                    }
                }
            }
        case .discover(let focus):
            selection = .discover
            switch focus {
            case .connector(let id): discoverPath = [.connector(id)]
            case .plugin(let id): discoverPath = [.plugins(focus: id)]
            case .device(let id): discoverPath = [.devices(focus: id)]
            case nil: discoverPath.removeAll()
            }
        case .profile(let focus):
            selection = .profile
            switch focus {
            case .memory: profilePath = [.memory]
            case .model: profilePath = [.model]
            case .permissions: profilePath = [.phonePermissions]
            case .privacy: profilePath = [.network]
            case .engine: profilePath = [.engine]
            case nil: profilePath.removeAll()
            }
        }
    }

    private static var previewInitialTab: AppTab? {
        #if DEBUG
        switch PreviewScreen.requested {
        case .appChat: .chat
        case .appDSH: .dsh
        case .appDiscover: .discover
        case .appProfile: .profile
        default: nil
        }
        #else
        nil
        #endif
    }
}
