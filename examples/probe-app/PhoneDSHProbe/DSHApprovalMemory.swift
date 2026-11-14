// SPDX-License-Identifier: MIT

import Foundation

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
    static func grantKey(tool: String, arguments: [String: String]) -> String? {
        let name = tool.lowercased()
        if name == "bash" {
            guard let command = arguments["command"]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
                return nil
            }
            guard !isDestructiveBash(command), isReadOnlyBash(command) else { return nil }
            return "bash:read-only"
        }
        if destructiveTools.contains(name) { return nil }
        guard safeTools.contains(name) else { return nil }
        return "tool:\(name)"
    }

    static func isDestructiveBash(_ command: String) -> Bool {
        let patterns = [
            #"(?:^|[;&|]\s*)rm\s+"#,
            #"(?:^|[;&|]\s*)sudo\s+rm\s+"#,
            #"(?:^|[;&|]\s*)git\s+reset\s+[^\n]*--hard"#,
            #"(?:^|[;&|]\s*)find\s+[^\n]*(?:\s|^)-delete(?:\s|$)"#,
            #"(?:^|[;&|]\s*)(?:dd|mkfs|shred|truncate)\b"#,
            #"(?:^|[;&|]\s*)chmod\s+-R\b"#,
            #"(?:^|[;&|]\s*)chown\s+-R\b"#,
        ]
        return patterns.contains {
            command.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// Only a single, clearly read-only command may get a standing DSH grant.
    /// Shell separators and pipes are rejected: `ls; rm ...` and `cat x | …`
    /// are not read-only as a whole. This intentionally errs toward asking.
    static func isReadOnlyBash(_ command: String) -> Bool {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              !text.contains(";"), !text.contains("|"), !text.contains("&"),
              !text.contains("<"), !text.contains(">"), !text.contains("`"),
              !text.contains("$("), !text.contains("\n"), !text.contains("\r") else { return false }
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let first = tokens.first else { return false }
        if first == "git" {
            guard tokens.count > 1 else { return false }
            return ["status", "diff", "log", "show", "rev-parse", "ls-files"].contains(tokens[1])
        }
        if first == "find" {
            return !tokens.dropFirst().contains { ["-delete", "-exec", "-execdir", "-ok"].contains($0) }
        }
        let allowed: Set<String> = [
            "ls", "pwd", "cat", "head", "tail", "grep", "rg", "wc",
            "stat", "du", "df", "echo", "which", "date", "whoami", "true",
        ]
        return allowed.contains(first)
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
