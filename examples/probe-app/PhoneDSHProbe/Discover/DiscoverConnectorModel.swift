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
        unsupported: NativeText("不会自动 merge、rebase 或 force push。", "Merge, rebase and force push are not automatic."),
        example: NativeText("查看这个 PR 的修改、争议和当前 Checks。", "Summarize this PR's changes, discussion and current checks."))

    static let gmail = DiscoverConnectorDescriptor(
        id: "gmail", title: "Gmail", detail: NativeText("邮件、线程与每日简报", "Messages, threads and the daily brief"),
        systemImage: "envelope",
        supported: NativeText("在授权后有界搜索邮件、读取线程并保留来源链接。", "Search and read authorized threads with source links."),
        unsupported: NativeText("草稿、回复、发送和转发分别授权；不会批量修改邮件。", "Drafts, replies, sending and forwarding have separate grants; bulk modification is unavailable."),
        example: NativeText("总结今天未读邮件，列出需要我回复的。", "Summarize today's unread mail and identify replies."))

    static let all = [github, gmail]
}

@MainActor
@Observable
final class DiscoverConnectorModel {
    let registry: any ConnectorRegistry
    private(set) var records: [String: ConnectorRecord] = [:]
    private(set) var grants: [String: ConnectorGrant] = [:]
    private(set) var isLoading = false
    private(set) var error: String?

    init(registry: any ConnectorRegistry = AppComposition.shared.registry) {
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
            if let persistent = registry as? PersistentConnectorRegistry,
               persistent === AppComposition.shared.registry {
                try await AppComposition.shared.revoke(connectorID)
            } else {
                try await registry.revoke(connectorID)
            }
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
