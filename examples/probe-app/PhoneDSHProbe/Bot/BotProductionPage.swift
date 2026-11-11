// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHBot
import ProbeKit
import SwiftUI

// Production entry for the Bot conversation. ChatModel owns the single
// BotRuntimeComposition (shared MCP runtime, HTTP server and outbox); this hub
// owns the selected-Bot page models and their per-Bot caches.

@MainActor
@Observable
final class BotProductionHub {
    /// The Bot page and the Bot drawer are siblings in NativeShell; both read
    /// this one hub so the selected Bot, page model and composition stay one
    /// authority.
    static let shared = BotProductionHub()

    private(set) var roster: BotRosterModel?
    private(set) var composition: BotRuntimeComposition?
    private(set) var chatModels: [String: BotChatModel] = [:]
    private(set) var infoModels: [String: BotInfoModel] = [:]
    private(set) var profileCenters: [String: BotProfileCenter] = [:]
    private(set) var selectedID: String?
    var error: String?
    private(set) var connecting = false
    private var selectionWatch: Task<Void, Never>?
    private var currentChat: ChatModel?
    private var pendingDeepLink: URL?
    /// A routine-due notification asks the page to present routine rows. The
    /// page owns the sheet; the hub only publishes the request so a cold launch
    /// can wait for the Bot page to mount.
    var pendingInfo: BotInfoPresentationRequest?
    /// Mirrors the Bot page's tab/scene visibility. The 500ms selection watch
    /// is UI-only polling; it stops while the page is hidden and resyncs
    /// immediately when the page becomes visible.
    private var pageActive = true

    var selectedBotID: String? { roster?.selectedBotID ?? selectedID }
    var chatModel: BotChatModel? { selectedID.flatMap { chatModels[$0] } }
    var infoModel: BotInfoModel? { selectedID.flatMap { infoModels[$0] } }
    var selectedIsMainBot: Bool { roster?.selectedIsMainBot ?? false }
    var entries: [BotRosterEntry] { roster?.entries ?? [] }
    var visibleEntries: [BotRosterEntry] { roster?.visibleEntries ?? [] }
    var mainBotID: String? { roster?.mainBotID }

    func appearance(for botID: String) -> BotFishAppearance? {
        roster?.appearance(for: botID)
    }

    func connect(chat: ChatModel) async {
        guard composition == nil, !connecting else { return }
        connecting = true
        defer { connecting = false }
        error = nil
        currentChat = chat
        for _ in 0..<40 {
            if let composition = chat.botRuntime {
                let roster = composition.rosterModel
                self.composition = composition
                self.roster = roster
                composition.onBotDeleted = { [weak self] botID in
                    self?.dropCaches(botID)
                }
                let initial = roster.selectedBotID
                if let initial {
                    do { try await select(initial) }
                    catch { self.error = "Bot 运行时读取失败：\(error.localizedDescription)" }
                }
                startSelectionWatch()
                return
            }
            if !chat.isStarted { await chat.start() }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        error = "Bot 运行时还没有准备好。请先启动引擎，然后重试。"
    }

    func retry(chat: ChatModel) async {
        stopSelectionWatch()
        for model in chatModels.values { model.setPageActive(false) }
        composition = nil
        roster = nil
        selectedID = nil
        chatModels.removeAll()
        infoModels.removeAll()
        profileCenters.removeAll()
        error = nil
        connecting = false
        await chat.retryBotRuntime()
        await connect(chat: chat)
    }

    func select(_ botID: String) async throws {
        guard let composition, let roster else { throw BotRuntimeError.unavailable }
        guard roster.bots.contains(where: { $0.id == botID }) else {
            throw BotTeamHostError.botNotFound(botID)
        }
        if let previous = selectedID, previous != botID {
            chatModels[previous]?.setPageActive(false)
        }
        if chatModels[botID] == nil {
            try await installModels(botID: botID, composition: composition)
        }
        try await composition.select(botID)
        selectedID = botID
        error = nil
    }

    /// A link names a Bot explicitly. A legacy `main` link resolves through
    /// the current main pointer; a link to a live Bot switches the page first.
    /// Row links go to the chat row; routine links present the routine list.
    func handleDeepLink(_ url: URL) -> Bool {
        guard let roster, let link = BotDeepLink(url: url),
              let target = BotMainPointerRouting.deepLinkBotID(link.botID, in: roster.roster) else {
            return false
        }
        if let routineID = link.routineID {
            Task {
                do {
                    if target != selectedID { try await select(target) }
                    pendingInfo = BotInfoPresentationRequest(
                        section: .routines, routineID: routineID)
                } catch {
                    self.error = "深链切换 Bot 失败：\(error.localizedDescription)"
                }
            }
            return true
        }
        if target == selectedID, let model = chatModels[target] {
            return model.openDeepLink(url)
        }
        pendingDeepLink = url
        Task {
            do { try await select(target) }
            catch { self.error = "深链切换 Bot 失败：\(error.localizedDescription)" }
            if let pending = pendingDeepLink {
                pendingDeepLink = nil
                _ = chatModels[target]?.openDeepLink(pending)
            }
        }
        return true
    }

    func deleteBot(_ botID: String) async throws {
        guard let composition else { throw BotRuntimeError.unavailable }
        try await composition.deleteBot(botID)
        dropCaches(botID)
        if let next = composition.rosterModel.selectedBotID {
            do { try await select(next) }
            catch { self.error = "切换到剩余 Bot 失败：\(error.localizedDescription)" }
        }
    }

    func createBot(name: String, description: String, color: BotFishColor?,
                   hairstyle: BotFishHairstyle?) async throws -> BotProfile {
        guard let composition else { throw BotRuntimeError.unavailable }
        return try await composition.createBot(
            name: name, description: description, color: color, hairstyle: hairstyle)
    }

    /// Loads (and installs on demand) one Bot's info model for the management
    /// menu's 外观 destination without changing the selected conversation.
    func infoModel(for botID: String) async throws -> BotInfoModel {
        if let info = infoModels[botID] { return info }
        guard let composition else { throw BotRuntimeError.unavailable }
        guard roster?.bots.contains(where: { $0.id == botID }) == true else {
            throw BotTeamHostError.botNotFound(botID)
        }
        try await installModels(botID: botID, composition: composition)
        guard let info = infoModels[botID] else { throw BotRuntimeError.unavailable }
        return info
    }

    private func installModels(botID: String,
                               composition: BotRuntimeComposition) async throws {
        let roster = composition.rosterModel
        let profile = roster.profile(for: botID)
        let center = profileCenters[botID] ?? BotProfileCenter(
            botID: botID, store: composition.profileStore,
            legacyName: nil,
            fallbackName: profile?.name ?? "大肥鱼")
        await center.loadProfile()
        let unit = try await composition.ensureUnit(for: botID)
        try await unit.rows.start()
        let driver = await unit.rows.chatDriver()
        let context = try await unit.environment.context()
        let model = BotChatModel(
            context: BotRuntimeContext(botID: botID, botName: context.botName),
            driver: driver, profileCenter: center)
        if let initial = try? await driver.watch(0) { model.apply(initial) }
        await model.refreshPresentation()
        if let chat = currentChat, let transport = try? await chat.transportForManagement() {
            let remote = unit.remote
            model.attachmentImporter = BotWorkspaceAttachmentImporter(
                transport: transport,
                sessionID: { try await remote.ensureMainSessionID() })
        }
        let infoDriver = await unit.info.infoDriver()
        let info = BotInfoModel(driver: infoDriver, profileCenter: center)
        if let profile {
            model.setMainBot(profile.id == roster.mainBotID)
            info.setMainBot(profile.id == roster.mainBotID)
        }
        model.onInteraction = { [weak composition] in
            composition?.noteInteraction(for: botID)
        }
        profileCenters[botID] = center
        chatModels[botID] = model
        infoModels[botID] = info
        roster.setRuntimeState(
            BotRosterRuntimeState(fishState: model.fishState, activity: model.activity,
                                  isRunning: model.runningTurnID != nil,
                                  pendingApprovalCount: model.pendingApprovalCount,
                                  runtimeState: composition.state),
            for: botID)
    }

    private func startSelectionWatch() {
        guard selectionWatch == nil, pageActive, roster != nil else { return }
        selectionWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.syncSelection()
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func stopSelectionWatch() {
        selectionWatch?.cancel()
        selectionWatch = nil
    }

    /// The page's visibility change. Pausing stops the only hub-owned polling
    /// loop; resuming starts it with an immediate read so a selection made
    /// while hidden is applied before the first frame.
    func setPageActive(_ active: Bool) {
        guard pageActive != active else { return }
        pageActive = active
        if active {
            if roster != nil { startSelectionWatch() }
        } else {
            stopSelectionWatch()
        }
    }

    private func syncSelection() async {
        guard let roster else { return }
        if let selected = roster.selectedBotID, selected != selectedID {
            if chatModels[selected] == nil {
                do { try await select(selected) }
                catch { self.error = "切换 Bot 失败：\(error.localizedDescription)" }
            } else {
                selectedID = selected
            }
        }
    }

    private func dropCaches(_ botID: String) {
        chatModels[botID]?.setPageActive(false)
        chatModels.removeValue(forKey: botID)
        infoModels.removeValue(forKey: botID)
        profileCenters.removeValue(forKey: botID)
        if selectedID == botID { selectedID = nil }
    }
}

enum BotRuntimeError: Error, LocalizedError {
    case unavailable
    var errorDescription: String? { "Bot 运行时还没有准备好。" }
}

struct BotProductionPage: View {
    var openDrawer: () -> Void
    @State private var chat = ChatModel.shared
    @State private var hub = BotProductionHub.shared
    @Environment(\.botPageActive) private var botPageActive

    init(openDrawer: @escaping () -> Void = {}) {
        self.openDrawer = openDrawer
    }
    @State private var infoRequest: BotInfoPresentationRequest?
    @State private var showDeviceConnections = false
    @State private var deviceCoordinator = DeviceSessionCoordinator.shared

    var body: some View {
        Group {
            if let model = hub.chatModel {
                VStack(spacing: 0) {
                    runtimeBanner
                    BotChatPage(model: model,
                                isMainBot: hub.selectedIsMainBot,
                                onOpenInfo: { presentInfo(nil) },
                                onOpenInfoSection: { presentInfo($0) },
                                onSelectBot: { botID in
                                    Task {
                                        do { try await hub.select(botID) }
                                        catch { report(error) }
                                    }
                                },
                                peerAppearance: { hub.appearance(for: $0) },
                                peerIsMainBot: { $0 == hub.mainBotID },
                                peerReaction: { hub.roster?.entry(for: $0)?.reaction },
                                openDrawer: openDrawer,
                                hasOnlineDevices: deviceCoordinator.hasOnlineDevices,
                                onConnectDevice: { showDeviceConnections = true },
                                handleExternalDeepLink: { hub.handleDeepLink($0) })
                }
                .id(model.context.botID)
                .onAppear { model.setPageActive(botPageActive) }
                .onDisappear { model.setPageActive(false) }
                .task(id: "watch:\(model.context.botID):\(botPageActive)") {
                    guard botPageActive else {
                        model.setPageActive(false)
                        return
                    }
                    model.setPageActive(true)
                    await model.watchLoop()
                }
                .task(id: "live:\(model.context.botID):\(botPageActive)") {
                    guard botPageActive else {
                        model.setPageActive(false)
                        return
                    }
                    model.setPageActive(true)
                    await model.liveLoop()
                }
                .sheet(isPresented: $showDeviceConnections) {
                    NavigationStack { NativeDeviceConnectionPage() }.homeSheetChrome()
                }
            } else if let error = hub.error {
                unavailable(error)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在连接 Bot…")
                        .botSecondaryFont()
                        .foregroundStyle(HomeSpec.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(HomeSpec.page)
                .task { await hub.connect(chat: chat) }
            }
        }
        .background(HomeSpec.page)
        .sheet(item: $infoRequest) { request in
            if let info = hub.infoModel, let botID = hub.selectedBotID {
                BotInfoPage(model: info, isMainBot: hub.selectedIsMainBot,
                            initialSection: request.section,
                            highlightRoutineID: request.routineID,
                            onDelete: { try await hub.deleteBot(botID) })
                    .homeSheetChrome()
            }
        }
        .task {
            if hub.chatModel == nil { await hub.connect(chat: chat) }
            consumePendingInfoRequest()
        }
        .onChange(of: hub.pendingInfo) { _, _ in consumePendingInfoRequest() }
        .onAppear {
            hub.setPageActive(botPageActive)
            hub.chatModel?.setPageActive(botPageActive)
            consumePendingInfoRequest()
        }
        .onDisappear {
            hub.setPageActive(false)
            hub.chatModel?.setPageActive(false)
        }
        .onChange(of: botPageActive) { _, active in
            hub.setPageActive(active)
            hub.chatModel?.setPageActive(active)
        }
    }

    private func presentInfo(_ section: BotInfoSection?) {
        infoRequest = BotInfoPresentationRequest(section: section, routineID: nil)
    }

    private func consumePendingInfoRequest() {
        guard let request = hub.pendingInfo else { return }
        hub.pendingInfo = nil
        infoRequest = request
    }

    private func report(_ error: Error) {
        hub.error = error.localizedDescription
    }

    @ViewBuilder
    private var runtimeBanner: some View {
        if let issue = chat.botRuntimeIssue {
            banner(issue, isError: true)
        } else if chat.botRuntimeState == .recovering {
            banner("Bot 连接中断，正在重新同步…", isError: false)
        } else if chat.botRuntimeState == .connecting {
            banner("Bot 正在连接…", isError: false)
        }
    }

    private func banner(_ text: String, isError: Bool) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .botSecondaryFont()
                .foregroundStyle(isError ? NativeParityTokens.error : HomeSpec.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("重试") {
                Task { await hub.retry(chat: chat) }
            }
            .botSecondaryFont(weight: .medium)
            .foregroundStyle(HomeSpec.textPrimary)
            .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.horizontal, HomeSpec.chromeInset)
        .padding(.vertical, 6)
        .background(HomeSpec.surface)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bot.runtime.status")
    }

    private func unavailable(_ message: String) -> some View {
        VStack(spacing: 16) {
            BotFailureRow(message: message)
            Button("重试") {
                Task { await hub.retry(chat: chat) }
            }
            .buttonStyle(BotTextButtonStyle())
            .botHitTarget()
            .accessibilityIdentifier("bot.runtime.retry")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(HomeSpec.contentInset)
        .background(HomeSpec.page)
    }
}

// MARK: - Bot drawer host

private struct BotAppearanceRequest: Identifiable {
    let id = UUID()
    let botID: String
}

/// Production host for the Bot rail. NativeShell owns the slide/scrim/
/// persistent mechanics, exactly as it does for the session drawer; this view
/// supplies the one shared hub, the management/Add dialogs and the per-Bot
/// profile actions.
struct BotDrawerHost: View {
    @Binding var isOpen: Bool
    var topInset: CGFloat
    var bottomInset: CGFloat = 0
    var isPersistent = false

    @State private var hub = BotProductionHub.shared
    @State private var showingManage = false
    @State private var appearanceRequest: BotAppearanceRequest?

    var body: some View {
        BotDrawerPanel(isOpen: $isOpen, topInset: topInset, bottomInset: bottomInset,
                       isPersistent: isPersistent, roster: hub.roster,
                       error: hub.error, actions: actions)
            .sheet(isPresented: $showingManage) {
                if let roster = hub.roster {
                    BotManageList(roster: roster, actions: actions)
                }
            }
            .sheet(item: $appearanceRequest) { request in
                BotAppearanceSheet(botID: request.botID, hub: hub)
                    .homeSheetChrome()
            }
            .task {
                if hub.roster == nil {
                    await hub.connect(chat: ChatModel.shared)
                }
            }
    }

    private var actions: BotDrawerActions {
        var value = BotDrawerActions()
        value.select = { botID in
            Task {
                do { try await hub.select(botID) }
                catch { hub.error = "切换 Bot 失败：\(error.localizedDescription)" }
            }
        }
        value.create = { name, color, hairstyle in
            try await hub.createBot(name: name, description: "", color: color, hairstyle: hairstyle)
        }
        value.rename = { botID, name in
            guard let roster = hub.roster else { throw BotRuntimeError.unavailable }
            try await roster.rename(botID, to: name)
        }
        value.setMain = { botID in
            await hub.roster?.setMain(botID)
        }
        value.setHidden = { botID, hidden in
            await hub.roster?.setHidden(botID, hidden: hidden)
        }
        value.delete = { botID in
            try await hub.deleteBot(botID)
        }
        value.manage = { showingManage = true }
        value.appearance = { botID in openAppearance(botID) }
        value.retry = { Task { await hub.retry(chat: ChatModel.shared) } }
        value.close = { if !isPersistent { isOpen = false } }
        return value
    }

    private func openAppearance(_ botID: String) {
        if showingManage {
            showingManage = false
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                appearanceRequest = BotAppearanceRequest(botID: botID)
            }
        } else {
            appearanceRequest = BotAppearanceRequest(botID: botID)
        }
    }
}

private struct BotAppearanceSheet: View {
    let botID: String
    let hub: BotProductionHub
    @Environment(\.dismiss) private var dismiss
    @State private var model: BotInfoModel?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let model {
                BotInfoPage(model: model, isMainBot: hub.mainBotID == botID,
                             onDelete: { try await hub.deleteBot(botID) })
            } else if let loadError {
                VStack(spacing: 16) {
                    BotFailureRow(message: loadError)
                    Button("关闭") { dismiss() }
                        .buttonStyle(BotTextButtonStyle())
                        .botHitTarget()
                }
                .padding(HomeSpec.contentInset)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在读取 Bot 信息…")
                        .botSecondaryFont()
                        .foregroundStyle(HomeSpec.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(HomeSpec.page)
            }
        }
        .task {
            guard model == nil, loadError == nil else { return }
            do { model = try await hub.infoModel(for: botID) }
            catch { loadError = error.localizedDescription }
        }
    }
}
