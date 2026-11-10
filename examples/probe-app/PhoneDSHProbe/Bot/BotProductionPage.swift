// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHBot
import ProbeKit
import SwiftUI

private struct BotInfoRequest: Identifiable {
    let id = UUID()
    let section: BotInfoSection?
}

// Production entry for the Bot conversation. ChatModel owns the single
// BotRuntimeComposition (row service, info service, driver); this page only
// presents them. A missing runtime is a visible error, never a fixture.

@MainActor
final class BotProductionHub: ObservableObject {
    @Published private(set) var chatModel: BotChatModel?
    @Published private(set) var infoModel: BotInfoModel?
    @Published private(set) var profileCenter: BotProfileCenter?
    @Published private(set) var error: String?

    private var connecting = false

    func connect(chat: ChatModel) async {
        guard chatModel == nil, !connecting else { return }
        connecting = true
        defer { connecting = false }
        error = nil
        for _ in 0..<40 {
            if let composition = chat.botRuntime {
                do {
                    try await install(composition: composition, chat: chat)
                } catch {
                    self.error = "Bot 运行时读取失败：\(error.localizedDescription)"
                }
                return
            }
            if !chat.isStarted {
                await chat.start()
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        error = "Bot 运行时还没有准备好。请先启动引擎，然后重试。"
    }

    func retry(chat: ChatModel) async {
        chatModel = nil
        infoModel = nil
        profileCenter = nil
        error = nil
        connecting = false
        await chat.retryBotRuntime()
        await connect(chat: chat)
    }

    private func install(composition: BotRuntimeComposition, chat: ChatModel) async throws {
        let environment = composition.environment
        let context = try await environment.context()
        let legacyName = try? await environment.legacyName()
        let profile = BotProfileCenter(
            botID: environment.botID,
            store: BotProfileStore(directory: Self.profileDirectory()),
            legacyName: legacyName,
            fallbackName: context.botName)
        await profile.bootstrap()
        try await composition.rows.start()
        let driver = await composition.rows.chatDriver()
        let model = BotChatModel(
            context: BotRuntimeContext(botID: environment.botID, botName: context.botName),
            driver: driver, profileCenter: profile)
        if let initial = try? await driver.watch(0) {
            model.apply(initial)
        }
        await model.refreshPresentation()
        if let transport = try? await chat.transportForManagement() {
            let remote = composition.remote
            model.attachmentImporter = BotWorkspaceAttachmentImporter(
                transport: transport,
                sessionID: { try await remote.ensureMainSessionID() })
        }
        let info = await composition.info.infoDriver()
        profileCenter = profile
        chatModel = model
        infoModel = BotInfoModel(driver: info, profileCenter: profile)
    }

    /// `Application Support/PhoneDSHBot` holds `agents-index.json` and
    /// `runtime-settings.json`, next to the rest of the app's Bot data.
    static func profileDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("PhoneDSHBot", isDirectory: true)
    }
}

struct BotProductionPage: View {
    @State private var chat = ChatModel.shared
    @StateObject private var hub = BotProductionHub()
    @State private var infoRequest: BotInfoRequest?
    @State private var showDeviceConnections = false
    @State private var deviceCoordinator = DeviceSessionCoordinator.shared

    var body: some View {
        Group {
            if let model = hub.chatModel {
                VStack(spacing: 0) {
                    runtimeBanner
                    BotChatPage(model: model,
                                onOpenInfo: { presentInfo(nil) },
                                onOpenInfoSection: { presentInfo($0) },
                                hasOnlineDevices: deviceCoordinator.hasOnlineDevices,
                                onConnectDevice: { showDeviceConnections = true })
                }
                .task { await model.watchLoop() }
                .task { await model.liveLoop() }
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
            if let info = hub.infoModel {
                BotInfoPage(model: info, initialSection: request.section)
                    .homeSheetChrome()
            }
        }
        .task {
            if hub.chatModel == nil { await hub.connect(chat: chat) }
        }
    }

    private func presentInfo(_ section: BotInfoSection?) {
        infoRequest = BotInfoRequest(section: section)
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
