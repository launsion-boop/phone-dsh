// SPDX-License-Identifier: MIT
// MCPConnectorPage: the setup page a Discover connector card pushes for a
// hosted MCP connector (Tencent Docs today). Connect opens the provider's
// authorization page in the system sheet; disconnect removes the Worker row,
// the egress grant and the Keychain record.

import PhoneDSH
import ProbeKit
import SwiftUI

struct MCPConnectorPage: View {
    let connector: PhoneMCPConnector
    let title: String
    @State private var service = MCPConnectorService.shared
    @State private var confirmDisconnect = false

    var body: some View {
        List {
            Section {
                switch service.state(connector) {
                case .notConnected:
                    connectButton(NativeText("连接\(title)", "Connect \(title)"))
                case .connecting:
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(NativeText("正在等待\(title)授权…", "Waiting for \(title) authorization…"))
                    }
                case .needsReauth:
                    Label(NativeText("授权已失效", "Authorization expired"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    connectButton(NativeText("重新连接", "Reconnect"))
                    disconnectButton
                case .connected:
                    Label(NativeText("已连接", "Connected"), systemImage: "checkmark.circle")
                    disconnectButton
                }
            } header: {
                Text(NativeText("\(title)账号", "\(title) account"))
            } footer: {
                Text(NativeText(
                    "授权在\(title)的页面完成。访问令牌只保存在本机钥匙串，由本机在调用时附加，不会进入对话引擎。",
                    "You authorize on \(title)'s own page. The access token stays in this phone's keychain and is attached by the app on each call; it never enters the chat engine."))
            }

            if let error = service.errorText[connector.id] {
                Section {
                    Text(error)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("connector.\(connector.id).error")
                }
            }
        }
        .homeGroupedList()
        .navigationTitle(title)
        .confirmationDialog(NativeText("断开\(title)？", "Disconnect \(title)?"),
                            isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button(NativeText("断开连接", "Disconnect"), role: .destructive) {
                Task { await service.disconnect(connector) }
            }
        } message: {
            Text(NativeText("将删除本机保存的授权，对话里不再能使用\(title)的工具。",
                            "The saved authorization is deleted from this phone and \(title) tools leave the chat."))
        }
    }

    private func connectButton(_ label: String) -> some View {
        Button {
            Task { await service.connect(connector) }
        } label: {
            Label(label, systemImage: "person.crop.circle.badge.plus")
        }
        .accessibilityIdentifier("connector.\(connector.id).connect")
    }

    private var disconnectButton: some View {
        Button(role: .destructive) {
            confirmDisconnect = true
        } label: {
            Label(NativeText("断开连接", "Disconnect"), systemImage: "rectangle.portrait.and.arrow.right")
        }
        .accessibilityIdentifier("connector.\(connector.id).disconnect")
    }
}
