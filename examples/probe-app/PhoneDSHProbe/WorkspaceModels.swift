// SPDX-License-Identifier: MIT
// Per-backend model registry (D2).
//
// `ChatModel.shared` and `DSHManagementModel.shared` remain the phone
// instances. A paired PC gets its own pair, created from the PCLink client, so
// drafts, scroll state and in-flight turns cannot cross between workspaces.
// The drawer, ChatPage and SessionsPage read the current pair from the
// environment; phone-fixed surfaces (Bot runtime, DeviceTaskManager, device
// sessions, MCP/model/Agent-preset settings) keep using `.shared`.

import Foundation
import PhoneDSHPCLink
import ProbeKit
import SwiftUI

@MainActor
@Observable
final class WorkspaceModels {
    static let shared = WorkspaceModels()

    let phoneChat: ChatModel
    let phoneManagement: DSHManagementModel
    let pcLink: PCLinkWorkspace

    private(set) var selected: DrawerBackendSetting
    private(set) var pcChat: ChatModel?
    private(set) var pcManagement: DSHManagementModel?
    private(set) var pcMachineId: String?

    init(phoneChat: ChatModel = .shared,
         phoneManagement: DSHManagementModel = .shared,
         pcLink: PCLinkWorkspace? = nil) {
        self.phoneChat = phoneChat
        self.phoneManagement = phoneManagement
        self.pcLink = pcLink ?? PCLinkWorkspace()
        #if DEBUG
        // Unattended simulator E2E: land on the PC segment without a tap.
        if let raw = ProcessInfo.processInfo.environment["PDSH_PCLINK_BACKEND"],
           let value = DrawerBackendSetting(rawValue: raw) {
            self.selected = value
            DrawerBackendSetting.save(value)
        } else {
            self.selected = DrawerBackendSetting.load()
        }
        #else
        self.selected = DrawerBackendSetting.load()
        #endif
        self.pcLink.onStatusChanged = { [weak self] status in
            self?.apply(status)
        }
    }

    var isPhoneSelected: Bool { selected == .phone }

    /// The current backend's identity, or nil while the PC segment is unpaired.
    var currentBackendID: BackendID? {
        if selected == .phone { return .phone }
        guard let pcMachineId else { return nil }
        return .pc(machineId: pcMachineId)
    }

    var currentChat: ChatModel? {
        selected == .phone ? phoneChat : pcChat
    }

    var currentManagement: DSHManagementModel? {
        selected == .phone ? phoneManagement : pcManagement
    }

    /// Management used by the drawer even in the unpaired/offline empty states.
    var managementOrPhone: DSHManagementModel {
        currentManagement ?? phoneManagement
    }

    /// `PCDrawerPhase` for the drawer's list region.
    var drawerPhase: PCDrawerPhase {
        PCLinkDrawerPolicy.phase(selected: selected,
                                 hasRecord: pcLink.record != nil,
                                 presence: pcLink.presence)
    }

    /// One-line note above a cached PC list while the PC is not reachable.
    var pcCachedListNote: String? {
        guard !isPhoneSelected else { return nil }
        return PCLinkDrawerPolicy.cachedListNote(presence: pcLink.presence,
                                                 capturedAt: currentManagement?.cacheCapturedAt,
                                                 hasRows: !(currentManagement?.sessions.isEmpty ?? true))
    }

    var currentConnection: PCWorkspaceConnection {
        selected == .phone ? .online : pcLink.connection
    }

    var isCurrentOnline: Bool {
        selected == .phone || pcLink.presence.isOnline
    }

    /// PC display name for the default drawer group and the ChatPage subtitle.
    var pcWorkspaceTitle: String {
        let name = pcLink.peerName.isEmpty ? pcLink.pcMachineId ?? "电脑" : pcLink.peerName
        return "PC 工作区 · \(name)"
    }

    func startAtLaunch() async {
        await pcLink.startAtLaunch()
        apply(pcLink.status)
        if selected == .pc, let pcChat, pcLink.isOnline {
            await pcChat.start()
        }
    }

    /// Foreground return: wake the PC relay even when the selected segment is
    /// the phone (the PC record may still be live) and resynchronize the PC
    /// pump's follow stream. Router/background delivery stays in the app.
    func scenePhaseChanged(_ isActive: Bool) async {
        guard isActive else { return }
        await pcLink.scenePhaseChanged(true)
        await pcChat?.foregroundResumedForPC()
    }

    /// Persist the segment choice (P18). Selecting PC never requires pairing and
    /// never falls back to the phone when the PC turns out to be offline.
    func select(_ value: DrawerBackendSetting) {
        guard selected != value else { return }
        selected = value
        DrawerBackendSetting.save(value)
        switch value {
        case .phone:
            // The phone model is already owned by the app; a cold start is
            // idempotent and never tears down a running turn.
            Task { [phoneChat] in
                if !phoneChat.isStarted { await phoneChat.start() }
            }
        case .pc:
            apply(pcLink.status)
            if let pcChat, pcLink.isOnline {
                Task { await pcChat.start() }
            }
        }
    }

    /// Rebuild the PC models when the pairing record appears, disappears or
    /// changes machine. Called after every status refresh.
    private func apply(_ status: PCLinkClientStatus) {
        guard let record = status.record else {
            if let old = pcChat {
                Task { await old.stop() }
            }
            pcChat = nil
            pcManagement = nil
            pcMachineId = nil
            return
        }
        guard pcMachineId != record.peerMachineId || pcChat == nil else { return }

        if let old = pcChat { Task { await old.stop() } }
        let backend = PCWorkspaceBackend(machineId: record.peerMachineId,
                                         displayName: record.peerName,
                                         client: pcLink.client)
        let runtime = PCWorkspaceRuntime(
            backendID: .pc(machineId: record.peerMachineId),
            backend: backend,
            client: pcLink.client,
            connection: { [weak pcLink] in pcLink?.connection ?? .unpaired })
        let chat = ChatModel(pcRuntime: runtime)
        let management = DSHManagementModel(chat: { chat })
        pcChat = chat
        pcManagement = management
        pcMachineId = record.peerMachineId
        if selected == .pc, pcLink.isOnline {
            Task { await chat.start() }
        }
    }
}

// MARK: - Environment

private struct WorkspaceModelsKey: EnvironmentKey {
    @MainActor static let defaultValue = WorkspaceModels.shared
}

extension EnvironmentValues {
    var workspaceModels: WorkspaceModels {
        get { self[WorkspaceModelsKey.self] }
        set { self[WorkspaceModelsKey.self] = newValue }
    }
}
