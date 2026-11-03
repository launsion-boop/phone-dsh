// SPDX-License-Identifier: MIT

import Foundation
import Observation
import ProbeKit

struct DiscoverConnectorDescriptor: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let supported: String
    let unsupported: String
    let example: String

    static let github = DiscoverConnectorDescriptor(
        id: "github", title: "GitHub", detail: NativeText("仓库、Issue、PR 与 Checks", "Repositories, issues, PRs and checks"),
        systemImage: "chevron.left.forwardslash.chevron.right",
        supported: NativeText("读取授权的仓库、Issue、PR、review 与 Checks。", "Read authorized repositories, issues, PRs, reviews and checks."),
        unsupported: NativeText("当前未配置账号；不会自动 merge、rebase 或 force push。", "No account is configured; merge, rebase and force push are not automatic."),
        example: NativeText("查看这个 PR 的修改、争议和当前 Checks。", "Summarize this PR's changes, discussion and current checks."))

    static let gmail = DiscoverConnectorDescriptor(
        id: "gmail", title: "Gmail", detail: NativeText("邮件、线程与每日简报", "Messages, threads and the daily brief"),
        systemImage: "envelope",
        supported: NativeText("在授权后有界搜索邮件、读取线程并保留来源链接。", "Search and read authorized threads with source links."),
        unsupported: NativeText("当前未配置 OAuth；不会创建草稿、发送或批量修改邮件。", "OAuth is not configured; drafts, sending and bulk changes are unavailable."),
        example: NativeText("总结今天未读邮件，列出需要我回复的。", "Summarize today's unread mail and identify replies."))

    static let all = [github, gmail]
}

enum ShellConnectorError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        NativeText("连接器运行时正在接入，当前不能读取或修改真实账号。", "The connector runtime is not connected; no real account can be read or changed.")
    }
}

actor ShellConnectorRegistry: ConnectorRegistry {
    static let shared = ShellConnectorRegistry()

    func state(of connectorID: String) async -> ConnectorRecord {
        ConnectorRecord(connectorID: connectorID, state: .disconnected,
                        issue: ShellConnectorError.unavailable.localizedDescription)
    }

    func grant(of connectorID: String) async -> ConnectorGrant? { nil }

    nonisolated func updates() -> AsyncStream<ConnectorRecord> {
        AsyncStream { continuation in
            continuation.onTermination = { _ in }
        }
    }

    func revoke(_ connectorID: String) async throws {
        throw ShellConnectorError.unavailable
    }
}

@MainActor
@Observable
final class DiscoverConnectorModel {
    let registry: any ConnectorRegistry
    private(set) var records: [String: ConnectorRecord] = [:]
    private(set) var grants: [String: ConnectorGrant] = [:]
    private(set) var isLoading = false
    private(set) var error: String?

    init(registry: any ConnectorRegistry = ShellConnectorRegistry.shared) {
        self.registry = registry
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        error = nil
        for descriptor in DiscoverConnectorDescriptor.all {
            records[descriptor.id] = await registry.state(of: descriptor.id)
            grants[descriptor.id] = await registry.grant(of: descriptor.id)
        }
    }

    func observeUpdates() async {
        for await record in registry.updates() {
            guard !Task.isCancelled else { return }
            records[record.connectorID] = record
        }
    }

    func revoke(_ connectorID: String) async {
        do {
            try await registry.revoke(connectorID)
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

func nativeConnectorStateTitle(_ state: ConnectorState) -> String {
    switch state {
    case .disconnected: NativeText("未连接", "Disconnected")
    case .connecting: NativeText("连接中", "Connecting")
    case .connected: NativeText("已连接", "Connected")
    case .needsAttention: NativeText("待处理", "Needs attention")
    case .expired: NativeText("授权已过期", "Expired")
    case .revoked: NativeText("已撤权", "Revoked")
    case .error: NativeText("连接失败", "Error")
    }
}
