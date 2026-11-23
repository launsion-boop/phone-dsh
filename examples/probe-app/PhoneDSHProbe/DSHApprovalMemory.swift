// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHBot

/// A conservative, tool-aware gate for DSH's app-local "always allow".
///
/// DSH itself only has `allowed-once` on the wire. The app remembers a standing
/// answer locally, but only for operations that are safe to repeat:
/// - `bash` gets one stable scope for non-destructive commands; destructive
///   commands get no scope and therefore no "always" button;
/// - file mutation tools (write/edit/delete/move/...) never get a scope;
/// - a small set of read-only tools may be remembered by tool name;
/// - unknown/MCP tools never get a scope.
enum DSHApprovalPolicy {
    /// Keep the local decision for one day. A later session should ask again
    /// unless the user makes a new standing decision.
    static let ttl: TimeInterval = 24 * 60 * 60

    private static let safeTools: Set<String> = [
        "read", "glob", "grep", "web_search", "web_fetch",
        "job_list", "job_output", "job_status", "todo_write",
    ]

    private static let destructiveTools: Set<String> = [
        "write", "edit", "delete", "move", "rename", "rm", "mkdir",
        "chmod", "chown", "truncate", "shred", "dd", "mkfs",
    ]

    /// The key to persist, or nil when this request must stay one-shot.
    ///
    /// A standing answer is stored per *action class*, not per command text:
    /// after one "always" for a delete, the next delete of a different path is
    /// the same decision for the person. Classes come from the same host
    /// classifier the Bot gate uses, so the workbench and a Bot agree on what
    /// "same kind of command" means. A command the classifier cannot place
    /// (`exec:unknown`) never gets a standing key.
    static func grantKey(tool: String, arguments: [String: String]) -> String? {
        let name = tool.lowercased()
        if name == "bash" {
            guard let command = arguments["command"]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
                return nil
            }
            switch BotShellActionClassifier.classify(command: command) {
            case .execRead: return "bash:read"
            case .execDelete: return "bash:delete"
            case .execGitReset: return "bash:git-reset"
            case .execUnknown: return nil
            }
        }
        if destructiveTools.contains(name) { return nil }
        guard safeTools.contains(name) else { return nil }
        return "tool:\(name)"
    }

    /// Only a single, clearly read-only command is a read. Shell separators
    /// and pipes are rejected: `ls; rm ...` and `cat x | …` are not read-only
    /// as a whole. This intentionally errs toward asking.
    static func isReadOnlyBash(_ command: String) -> Bool {
        BotShellActionClassifier.isPlainReadOnly(command)
    }
}

enum DSHApprovalScopeTitle {
    /// The stored key is a class id; the settings row says what it covers.
    static func title(_ scope: String) -> String {
        switch scope {
        case "bash:read": return "只读命令（bash:read）"
        case "bash:delete": return "删除文件或目录（bash:delete）"
        case "bash:git-reset": return "丢弃 Git 未提交改动（bash:git-reset）"
        default:
            if scope.hasPrefix("tool:") {
                return "只读工具 \(scope.dropFirst(5))"
            }
            return scope
        }
    }
}

struct DSHApprovalGrant: Identifiable, Equatable {
    let sessionID: String
    let scope: String
    let decidedAt: Date

    var id: String { "\(sessionID)|\(scope)" }
}

/// The app's "always allow" memory for one DSH session.
///
/// Entries are session+scope, never just tool: a standing `bash` answer for
/// non-destructive commands cannot silently authorize `rm`, and write/edit
/// requests never get an always button. Entries expire after
/// `DSHApprovalPolicy.ttl`; an allow-once/deny removes the matching entry.
enum DSHApprovalMemory {
    private static let defaultsKey = "dev.phone-dsh.dsh-permission-always.v2"
    private static let legacyKey = "dev.phone-dsh.dsh-permission-always.v1"

    static func isAllowed(sessionID: String, scope: String, now: Date = Date()) -> Bool {
        guard !sessionID.isEmpty, !scope.isEmpty else { return false }
        guard let decidedAt = load()[sessionID]?[scope] else { return false }
        guard now >= decidedAt, now.timeIntervalSince(decidedAt) < DSHApprovalPolicy.ttl else {
            return false
        }
        return true
    }

    static func remember(sessionID: String, scope: String, now: Date = Date()) {
        guard !sessionID.isEmpty, !scope.isEmpty else { return }
        var all = pruned(load(), now: now)
        all[sessionID, default: [:]][scope] = now
        write(all)
        // v1 had no timestamps and therefore no safe way to know whether an
        // entry is still valid; it must not beat the new TTL.
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }

    static func forget(sessionID: String, scope: String) {
        guard !sessionID.isEmpty, !scope.isEmpty else { return }
        var all = load()
        all[sessionID]?.removeValue(forKey: scope)
        if all[sessionID]?.isEmpty == true { all.removeValue(forKey: sessionID) }
        write(all)
    }

    static func activeGrants(now: Date = Date()) -> [DSHApprovalGrant] {
        pruned(load(), now: now).flatMap { sessionID, scopes in
            scopes.map { DSHApprovalGrant(sessionID: sessionID, scope: $0.key,
                                          decidedAt: $0.value) }
        }.sorted { $0.decidedAt > $1.decidedAt }
    }

    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }

    private static func pruned(_ entries: [String: [String: Date]], now: Date) -> [String: [String: Date]] {
        entries.reduce(into: [:]) { result, pair in
            let fresh = pair.value.filter { _, date in
                now >= date && now.timeIntervalSince(date) < DSHApprovalPolicy.ttl
            }
            if !fresh.isEmpty { result[pair.key] = fresh }
        }
    }

    private static func load() -> [String: [String: Date]] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: [String: Date]].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func write(_ entries: [String: [String: Date]]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
