// SPDX-License-Identifier: MIT

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

@Observable
final class NativeAgentPresetsModel {
    private(set) var presets: [NativeAgentPreset] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var yaml = ""
    private(set) var yamlTitle = ""

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try await ChatModel.shared.transportForManagement()
            let value = try await client.call("agentPresets/list", args: .object(["action": .string("list")]))
            let rows = value["roster"]?["presets"]?.arrayValue ?? []
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

    func selectDefault(_ preset: NativeAgentPreset) async {
        guard preset.broken == nil else {
            error = preset.broken
            return
        }
        do {
            let client = try await ChatModel.shared.transportForManagement()
            let settings = try await client.call("settings/describe", args: .object([:]))
            let descriptor = settings["namespaces"]?.arrayValue?.first {
                $0["ns"]?.stringValue == "agent-preset-registry"
            }
            guard let revision = descriptor?["revision"]?.intValue,
                  descriptor?["value"]?["selectedDefault"] != nil else {
                error = NativeText("当前引擎没有提供可写的默认预设设置。", "This engine does not expose a writable default preset setting.")
                return
            }
            _ = try await client.call("settings/update", args: .object([
                "ns": .string("agent-preset-registry"),
                "patch": .object(["selectedDefault": .string(preset.id)]),
                "expectedRevision": .number(Double(revision)),
            ]))
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func showYAML(_ preset: NativeAgentPreset) async -> Bool {
        do {
            let client = try await ChatModel.shared.transportForManagement()
            let value = try await client.call("agentPresets/read", args: .object([
                "action": .string("read"), "presetId": .string(preset.id),
            ]))
            guard let document = value["document"]?["content"]?.stringValue else {
                error = NativeText("引擎没有返回这个预设的配置内容。", "The engine did not return this preset's configuration.")
                return false
            }
            yaml = document
            yamlTitle = preset.title
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func startCreator() async {
        await ChatModel.shared.newSession(preset: "cordis")
    }
}

struct NativeAgentPresetsPage: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = NativeAgentPresetsModel()
    @State private var showYAML = false

    var body: some View {
        List {
            Section {
                Button {
                    Task {
                        await model.startCreator()
                        dismiss()
                    }
                } label: {
                    Label(NativeText("让 Agent 创建预设", "Create a preset with Agent"), systemImage: "plus")
                }
                Text(NativeText("进入创造模式但不自动发送任务，现有草稿会保留。", "Opens creator mode without sending a prompt. Your draft is preserved."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                if model.isLoading && model.presets.isEmpty {
                    ProgressView(NativeText("正在读取预设…", "Loading presets…"))
                }
                ForEach(model.presets) { preset in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(preset.title).font(.headline)
                            if preset.isDefault {
                                Text(NativeText("默认", "Default"))
                                    .font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                            }
                            if preset.custom {
                                Text(NativeText("自定义", "Custom")).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Text(preset.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        if !preset.detail.isEmpty {
                            Text(preset.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                        if let broken = preset.broken {
                            Text(broken).font(.caption).foregroundStyle(.orange)
                        }
                        HStack {
                            Button(NativeText("查看配置", "View configuration")) {
                                Task {
                                    showYAML = await model.showYAML(preset)
                                }
                            }
                            Button(NativeText("设为默认", "Make default")) {
                                Task { await model.selectDefault(preset) }
                            }
                            .disabled(preset.broken != nil)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            if let error = model.error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle(NativeText("Agent 预设", "Agent Presets"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refresh() }
        .task { await model.refresh() }
        .sheet(isPresented: $showYAML) {
            NavigationStack {
                TextEditor(text: .constant(model.yaml))
                    .font(.system(.body, design: .monospaced))
                    .disabled(true)
                    .padding(12)
                    .navigationTitle(model.yamlTitle)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(NativeText("完成", "Done")) { showYAML = false }
                        }
                    }
            }
        }
    }
}
