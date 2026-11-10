// SPDX-License-Identifier: MIT
// PHONE-ONLY: Agent presets are a phone-settings surface in v1 (plan v2 §6.1);
// the calls resolve through ChatModel's current (phone) backend.

import Observation
import PhoneDSHAgentCore
import SwiftUI

struct NativeAgentPreset: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let isDefault: Bool
    let broken: String?
    let custom: Bool
}

@MainActor
@Observable
final class NativeAgentPresetsModel {
    private(set) var presets: [NativeAgentPreset] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var yaml = ""
    private(set) var yamlTitle = ""
    private(set) var isOpeningSession = false

    // Like permission.defaultPreset, the phone image pins this in its home
    // patch. A healthy preset can still be selected for a specific new session.
    var defaultReadOnlyReason: String {
        NativeText("默认预设由此 Worker 的启动配置锁定。可用“使用预设”创建指定预设的新会话。",
                   "The startup profile locks the default preset. Use a preset to open a new session with it.")
    }

    var creatorUnavailableReason: String? {
        guard let creator = presets.first(where: { $0.id == "cordis" }) else {
            return NativeText("当前引擎没有提供创造模式预设。", "This engine does not provide a creator preset.")
        }
        return creator.broken
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try await ChatModel.shared.transportForManagement()
            let value = try await client.call("agentPresets/list", args: .object([:]))
            guard let rows = value["presets"]?.arrayValue else {
                throw ProviderError.invalidResponse("agentPresets/list returned no presets array")
            }
            presets = rows.compactMap { row in
                guard let id = row["id"]?.stringValue else { return nil }
                return NativeAgentPreset(
                    id: id,
                    title: row["name"]?.stringValue ?? id,
                    detail: row["description"]?.stringValue ?? "",
                    isDefault: row["isDefault"]?.boolValue ?? false,
                    broken: row["broken"]?.stringValue,
                    custom: false)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func showYAML(_ preset: NativeAgentPreset) async -> Bool {
        do {
            let client = try await ChatModel.shared.transportForManagement()
            let value = try await client.call("agentPresets/read", args: .object([
                "agentPreset": .string(preset.id),
            ]))
            guard let document = value["content"]?.stringValue else {
                error = NativeText("引擎没有返回这个预设的配置内容。", "The engine did not return this preset's configuration.")
                return false
            }
            yaml = document
            yamlTitle = preset.title
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func openSession(presetID: String) async -> Bool {
        guard !isOpeningSession else { return false }
        isOpeningSession = true
        defer { isOpeningSession = false }
        // Re-read health before creating; a broken or absent preset must not
        // silently fall back to an ordinary session.
        await refresh()
        guard error == nil else { return false }
        guard let preset = presets.first(where: { $0.id == presetID }) else {
            error = NativeText("这个预设已不可用，请刷新后重试。", "This preset is no longer available. Refresh and retry.")
            return false
        }
        guard preset.broken == nil else { error = preset.broken; return false }
        guard await ChatModel.shared.newSession(preset: presetID) else {
            error = ChatModel.shared.userFacingError
                ?? NativeText("当前会话忙碌，请稍后再打开新会话。", "The current session is busy. Try opening a new session later.")
            return false
        }
        error = nil
        return true
    }
}

struct NativeAgentPresetsPage: View {
    var onOpenSession: () -> Void = {}
    @State private var model = NativeAgentPresetsModel()
    @State private var showYAML = false

    var body: some View {
        List {
            Section {
                Button {
                    Task {
                        if await model.openSession(presetID: "cordis") { onOpenSession() }
                    }
                } label: {
                    Label(NativeText("让 Agent 创建预设", "Create a preset with Agent"), systemImage: "plus")
                }
                .disabled(model.isLoading || model.isOpeningSession || model.creatorUnavailableReason != nil)
                .accessibilityIdentifier("presets.create")
                Text(NativeText("进入创造模式但不自动发送任务，现有草稿会保留。", "Opens creator mode without sending a prompt. Your draft is preserved."))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Text(NativeText("可创建使用手机内建工具的本地 Agent 预设。外部套件与新 JavaScript 插件需使用桌面 DSH。", "Create local Agent presets using this phone's built-in tools. External packages and new JavaScript plugins require desktop DSH."))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                if let reason = model.creatorUnavailableReason, !model.isLoading {
                    Text(NativeText("创造模式当前不可用：", "Creator mode is unavailable: ") + reason)
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                if model.isLoading && model.presets.isEmpty {
                    ProgressView(NativeText("正在读取预设…", "Loading presets…"))
                }
                if !model.isLoading && model.presets.isEmpty && model.error == nil {
                    Text(NativeText("当前引擎没有预设。", "This engine has no presets."))
                }
                ForEach(model.presets) { preset in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(preset.title).font(.system(size: HomeSpec.bodySize, weight: .semibold))
                            if preset.isDefault {
                                HomeTag(text: NativeText("默认", "Default"))
                            }
                            if preset.custom {
                                HomeTag(text: NativeText("自定义", "Custom"))
                            }
                        }
                        Text(preset.id).font(.system(size: 13).monospaced()).foregroundStyle(.secondary)
                        if !preset.detail.isEmpty {
                            Text(preset.detail).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        if let broken = preset.broken {
                            Text(broken).font(.system(size: 13)).foregroundStyle(.orange)
                        }
                        HStack {
                            Button(NativeText("查看配置", "View configuration")) {
                                Task {
                                    showYAML = await model.showYAML(preset)
                                }
                            }
                            .accessibilityIdentifier("presets.read.\(preset.id)")
                            Button(NativeText("使用预设", "Use preset")) {
                                Task {
                                    if await model.openSession(presetID: preset.id) { onOpenSession() }
                                }
                            }
                            .disabled(preset.broken != nil || model.isOpeningSession || model.isLoading)
                            .accessibilityIdentifier("presets.use.\(preset.id)")
                            Label(NativeText("默认已锁定", "Default locked"), systemImage: "lock")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 6)
                }
            } footer: {
                Text(model.defaultReadOnlyReason)
            }
            if let error = model.error {
                Section {
                    Text(error).foregroundStyle(.red)
                    Button(NativeText("重新读取", "Reload")) { Task { await model.refresh() } }
                }
            }
        }
        .homeGroupedList()
        .navigationTitle(NativeText("Agent 预设", "Agent Presets"))
        .phoneOwnedSettingsNotice()
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refresh() }
        .task { await model.refresh() }
        .sheet(isPresented: $showYAML) {
            NavigationStack {
                ScrollView {
                    Text(model.yaml)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .accessibilityIdentifier("presets.yaml")
                }
                    .navigationTitle(model.yamlTitle)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(NativeText("完成", "Done")) { showYAML = false }
                        }
                    }
            }
            .homeSheetChrome()
        }
    }
}
