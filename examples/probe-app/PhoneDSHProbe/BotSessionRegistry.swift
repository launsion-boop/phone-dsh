// SPDX-License-Identifier: MIT

import Foundation

/// The one App-side value that names the Bot data root. Kept outside the
/// `@MainActor` registry so nonisolated importer code can read it without an
/// actor hop. `BotSessionRegistry.botDataDirectory` exposes the same value.
enum BotDataRoot {
    /// Must stay equal to `BotWorkspaceLayout.defaultBotDataDirectory` in
    /// `Sources/PhoneDSHBot/Attachments/BotWorkspaceLayout.swift`.
    static let path = "/dsh/workspace/.dshbot"
}

/// App 侧判断“某个 DSH 会话属于 Bot 运行时”的单一来源。
/// Bot 运行时在创建 / 恢复 / claim 会话时登记；DSH 各页面只读调用。
@MainActor
final class BotSessionRegistry {
    static let shared: BotSessionRegistry = BotSessionRegistry()

    /// Bot 保留的会话 id 前缀：`gb-`。
    static let sessionIDPrefix: String = "gb-"

    /// Bot 数据根目录前缀（无尾部 `/`）。与 `BotDataRoot.path` 相同。
    static let botDataDirectory: String = BotDataRoot.path

    private static let defaultsKey = "phoneDSH.botSession.registry.v1"

    private let defaults: UserDefaults
    private var registered: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        registered = Set(stored.filter {
            !$0.isEmpty && !$0.hasPrefix(Self.sessionIDPrefix)
        })
    }

    /// true = 该 session 不得出现在任何 DSH 页面。
    /// `gb-` 前缀先判定，不读登记集合、不做 I/O。
    func isBotSession(_ sessionID: String) -> Bool {
        if sessionID.isEmpty { return false }
        if sessionID.hasPrefix(Self.sessionIDPrefix) { return true }
        return registered.contains(sessionID)
    }

    /// 登记一个会话 id（幂等；空串忽略；立即持久化）。
    /// `gb-` id 已被前缀覆盖，不再写持久化集合，保证
    /// `registeredSessionIDs()` 只含需要额外解释的旧 id。
    func register(_ sessionID: String) {
        guard !sessionID.isEmpty, !sessionID.hasPrefix(Self.sessionIDPrefix),
              !registered.contains(sessionID) else { return }
        registered.insert(sessionID)
        persist()
    }

    func register(contentsOf sessionIDs: [String]) {
        var changed = false
        for sessionID in sessionIDs where !sessionID.isEmpty
            && !sessionID.hasPrefix(Self.sessionIDPrefix)
            && !registered.contains(sessionID) {
            registered.insert(sessionID)
            changed = true
        }
        if changed { persist() }
    }

    func unregister(_ sessionID: String) {
        guard registered.remove(sessionID) != nil else { return }
        persist()
    }

    /// 已登记的非前缀 id（诊断/测试用，返回稳定排序）。
    func registeredSessionIDs() -> [String] {
        registered.sorted()
    }

    /// true = 该 workspace 路径属于 Bot 私有数据区（等于 botDataDirectory
    /// 或在其子路径下）。DSH 抽屉/工作区浏览不得显示该文件夹。
    func isBotWorkspacePath(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var candidate = path
        while candidate.count > 1, candidate.hasSuffix("/") {
            candidate.removeLast()
        }
        let root = Self.botDataDirectory
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    private func persist() {
        defaults.set(registered.sorted(), forKey: Self.defaultsKey)
    }
}
