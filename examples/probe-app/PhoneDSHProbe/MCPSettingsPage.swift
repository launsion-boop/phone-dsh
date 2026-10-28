// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — native MCP network and credential configuration.
//
// This sheet is an editor for the Worker's existing `/dsh/home/mcp.json`
// registry (the same `phone/mcpList` / `phone/mcpUpsert` / `phone/mcpRemove`
// Remote methods the Web tab uses), plus the host-only exact-origin/path grant
// and dedicated MCP Keychain. It is not a second registry and it never puts a
// real header value into the Worker or UserDefaults.

import Foundation
import Observation
import PhoneDSH
import PhoneDSHAgentCore
import ProbeKit
import SwiftUI

struct MCPSettingsPage: View {
    @State private var model: MCPSettingsModel
    private let draft: MCPControlDraft?

    @MainActor
    init(host: MCPConfigurationHost,
         draft: MCPControlDraft? = nil,
         settings: PhoneMCPAccessSettings = .shared) {
        self.draft = draft
        _model = State(initialValue: MCPSettingsModel(
            host: host,
            settings: settings,
            isHostRunning: { MCPSettingsPage.hostIsRunning(host) },
            makeTransport: { try await MCPSettingsPage.makeTransport(host: host) },
            refreshPolicy: { MCPSettingsPage.refreshHostPolicy(host: host) }))
    }

    private static func hostIsRunning(_ host: MCPConfigurationHost) -> Bool {
        switch host {
        case .native: return ChatModel.shared.isStarted
        case .web: return WebHostModel.shared.isStarted
        }
    }

    private static func makeTransport(host: MCPConfigurationHost) async throws -> any DSHRemoteTransport {
        switch host {
        case .native: return try await ChatModel.shared.transportForManagement()
        case .web: return try await WebHostModel.shared.makeTransportForPage()
        }
    }

    private static func refreshHostPolicy(host: MCPConfigurationHost) {
        switch host {
        case .native: ChatModel.shared.refreshMCPAccessPolicy()
        case .web: WebHostModel.shared.refreshMCPAccessPolicy()
        }
    }

    var body: some View {
        if let draft {
            // The Web tab could not finish a row that needs a native-only
            // authentication value. It opens the same sheet with the
            // non-secret fields prefilled; saving here writes the Keychain,
            // commits the exact grant and upserts the one Worker registry.
            MCPEditorPage(model: model, server: nil, controlDraft: draft)
        } else {
            list
        }
    }

    private var list: some View {
        List {
            Section {
                if !model.hostRunning {
                    ContentUnavailableView("主机尚未启动",
                                           systemImage: "network",
                                           description: Text("先启动本地引擎,才能读取和修改这些服务器。"))
                } else if model.loading && model.rows.isEmpty {
                    ProgressView("正在读取 MCP 注册表…")
                } else if model.rows.isEmpty {
                    ContentUnavailableView("尚未添加 MCP 服务器",
                                           systemImage: "server.rack",
                                           description: Text("在网页版里加过的服务器,这里也能看到;两边是同一份列表。"))
                } else {
                    ForEach(model.rows) { row in
                        NavigationLink {
                            MCPEditorPage(model: model, server: row)
                        } label: {
                            MCPSummaryRow(server: row)
                        }
                    }
                }
            } header: {
                Text("Streamable HTTP MCP")
            } footer: {
                Text("每个服务器只放行它自己的地址和端口。这里填的授权和密钥只留在本机,模型和搜索用的密钥不会拿来给服务器用。")
            }

            if let error = model.errorText {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }
            if let notice = model.notice {
                Section {
                    Text(notice).foregroundStyle(.green)
                }
            }

            Section("操作") {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("刷新注册表", systemImage: "arrow.clockwise")
                }
                .disabled(model.loading || !model.hostRunning)
                NavigationLink {
                    MCPEditorPage(model: model, server: nil)
                } label: {
                    Label("添加 MCP 服务器", systemImage: "plus.circle")
                }
                .disabled(!model.hostRunning)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.white)
        .navigationTitle("MCP 网络与密钥")
        .navigationBarTitleDisplayMode(.large)
        .task { await model.refresh() }
    }
}

private struct MCPSummaryRow: View {
    let server: MCPServerSummary

    /// 宿主给的是 connected / connecting / error 这种原值,一个都不上屏。
    static func statusText(_ raw: String) -> String {
        switch raw.lowercased() {
        case "connected", "ready", "ok": return "已连接"
        case "connecting", "pending", "starting": return "连接中"
        case "error", "failed", "disconnected": return "出错"
        default: return "未知"
        }
    }


    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(server.serverName).font(.headline)
                Text(Self.statusText(server.status))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.14), in: Capsule())
                    .foregroundStyle(statusColor)
            }
            Text(server.url)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 8) {
                Label(server.grant == nil ? "未授权网络" : "已授权精确 URL",
                      systemImage: server.grant == nil ? "exclamationmark.triangle" : "checkmark.shield")
                if !server.headers.isEmpty {
                    Label("\(server.headers.filter(\.hasStoredValue).count)/\(server.headers.count) 个密钥",
                          systemImage: "key")
                }
            }
            .font(.caption2)
            .foregroundStyle(server.grant == nil ? Color.orange : Color.secondary)
            if server.error != nil {
                Text("连不上这个服务器")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
    }

    private var statusColor: Color {
        switch server.status {
        case "connected": return .green
        case "error": return .red
        case "disabled": return .secondary
        default: return .orange
        }
    }
}

private struct MCPEditorPage: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MCPServerDraft
    @State private var saving = false
    @State private var errorText: String?

    let model: MCPSettingsModel
    let existing: MCPServerSummary?

    init(model: MCPSettingsModel,
         server: MCPServerSummary?,
         controlDraft: MCPControlDraft? = nil) {
        self.model = model
        self.existing = server
        if let controlDraft {
            _draft = State(initialValue: MCPServerDraft(controlDraft: controlDraft))
        } else {
            _draft = State(initialValue: server.map { MCPServerDraft(server: $0) } ?? .new())
        }
    }

    var body: some View {
        Form {
            Section("服务器") {
                TextField("名称（A-Z a-z 0-9 _ -）", text: $draft.serverName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(existing != nil)
                TextField("MCP URL（http(s)://host/path）", text: $draft.url)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textContentType(.URL)
                Toggle("启用", isOn: $draft.enabled)
                TextField("工具调用超时（毫秒）", text: $draft.toolCallTimeoutMs)
                    .keyboardType(.numberPad)
            }

            Section {
                ForEach($draft.headers) { $header in
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Header，例如 Authorization", text: $header.name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("环境变量名（可留空自动生成）", text: $header.envName)
                            .font(.caption.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField(header.hasStoredValue ? "已保存；留空保持不变" : "认证值（只写入设备 Keychain）",
                                    text: $header.value)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.password)
                    }
                }
                .onDelete { offsets in draft.headers.remove(atOffsets: offsets) }
                Button {
                    draft.headers.append(MCPHeaderDraft())
                } label: {
                    Label("添加认证头", systemImage: "plus")
                }
            } header: {
                Text("认证头与设备密钥")
            } footer: {
                Text("值只存在这台手机的钥匙串里,不会写进配置文件,也不会进日志。留空就是保留已经存过的值。")
            }

            if let errorText {
                Section {
                    Text(errorText).foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    if saving {
                        ProgressView()
                    } else {
                        Text(existing == nil ? "保存并连接" : "保存修改并重连")
                    }
                }
                .disabled(saving || draft.serverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || draft.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let existing {
                    Button(role: .destructive) {
                        Task {
                            saving = true
                            await model.remove(existing)
                            saving = false
                            if model.errorText == nil { dismiss() }
                            else { errorText = model.errorText }
                        }
                    } label: {
                        Label("删除并撤销授权与密钥", systemImage: "trash")
                    }
                    .disabled(saving)
                }
            }
        }
        .navigationTitle(existing == nil ? "添加 MCP 服务器" : "编辑 MCP 服务器")
        .navigationBarTitleDisplayMode(.inline)
    }

    @MainActor
    private func save() async {
        saving = true
        defer { saving = false }
        await model.save(draft)
        if model.errorText == nil {
            dismiss()
        } else {
            errorText = model.errorText
        }
    }
}
