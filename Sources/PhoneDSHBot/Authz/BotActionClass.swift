// SPDX-License-Identifier: MIT

import Foundation

/// The risk class one tool call belongs to.
///
/// A `BotToolEffect` already carries the exact instance (`tool`, `operation`,
/// `resource`). A *standing* approval must not be stored against that instance:
/// `rm -rf build` and `rm -rf dist` are the same decision for the person, and
/// storing the path made every later delete ask again. The action class is the
/// coarser key a standing decision is stored under.
///
/// Only classes whose consequence is understood and whose scope is one command
/// family are standable. `exec:unknown` is deliberately not: an unparsed
/// command must stay a per-call decision, never a class-wide one.
public enum BotActionClass: String, Codable, Sendable, CaseIterable {
    /// A single, clearly read-only command. No card is drawn for it today; the
    /// class exists so a standing read decision can never be confused with a
    /// write.
    case execRead = "exec:read"
    /// Delete files or directories (`rm`, `find -delete`).
    case execDelete = "exec:delete"
    /// Discard uncommitted Git changes (`git reset --hard`, `git checkout -- .`).
    case execGitReset = "exec:git-reset"
    /// A command the classifier cannot place (interpreter, pipe, unknown
    /// binary, unparseable). It always keeps the one-shot answer.
    case execUnknown = "exec:unknown"

    /// Whether "always allow" may persist this class.
    public var isStandable: Bool {
        switch self {
        case .execRead, .execDelete, .execGitReset: return true
        case .execUnknown: return false
        }
    }

    /// The words under the approval card's standing button.
    public var zhTitle: String {
        switch self {
        case .execRead: return "只读命令"
        case .execDelete: return "删除文件或目录"
        case .execGitReset: return "丢弃 Git 未提交改动"
        case .execUnknown: return "无法归类的命令"
        }
    }

    public var enTitle: String {
        switch self {
        case .execRead: return "read-only commands"
        case .execDelete: return "deleting files or directories"
        case .execGitReset: return "discarding uncommitted Git changes"
        case .execUnknown: return "commands this build cannot classify"
        }
    }
}

/// Conservative classification of one `bash -c` command.
///
/// The classifier is advisory: it never decides whether a command may run, it
/// only decides which *class* a standing approval may cover. A command it
/// cannot prove is read-only or one known destructive family becomes
/// `execUnknown`, whose standing answer is refused by construction.
public enum BotShellActionClassifier {
    /// Commands whose whole effect is reading. A pipe, redirect, substitution
    /// or separator disqualifies the command from `execRead`: the text after
    /// it can write.
    private static let readOnlyCommands: Set<String> = [
        "ls", "pwd", "cat", "head", "tail", "grep", "rg", "wc", "stat",
        "du", "df", "echo", "which", "date", "whoami", "true", "file",
        "realpath", "basename", "dirname", "jq", "jaq", "printf",
    ]
    private static let readOnlyGitSubcommands: Set<String> = [
        "status", "diff", "log", "show", "rev-parse", "ls-files",
    ]

    public static func classify(command: String, workspace: String? = nil) -> BotActionClass {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .execUnknown }
        // Destructive families first: `rm -rf x; ls` reads as a delete, not as
        // `ls`, and the class must cover the whole command.
        if isDelete(text) { return .execDelete }
        if isGitReset(text) { return .execGitReset }
        if isPlainReadOnly(text) { return .execRead }
        return .execUnknown
    }

    /// The one destructive family the host already classifies for `bash`.
    /// Kept in step with `BotApprovalPatternAnalyzer`.
    public static func isDelete(_ command: String) -> Bool {
        if matches(#"(?:^|[;&|]\s*)rm\s+(?:[^\s;&|]+\s+)*-"#, command) { return true }
        if command.hasPrefix("rm ") { return true }
        if matches(#"(?:^|[;&|]\s*)find\s+[^\n]*(?:\s|^)-delete(?:\s|$)"#, command) { return true }
        return false
    }

    public static func isGitReset(_ command: String) -> Bool {
        matches(#"(?:^|[;&|]\s*)git\s+reset\s+[^\n]*--hard"#, command)
    }

    /// Same shape as the DSH-side read-only rule: one simple command and
    /// nothing that can redirect, substitute or chain. Deliberately stricter
    /// than the analyzer's destructive patterns; a false negative only means
    /// "ask again", never a widened grant.
    public static func isPlainReadOnly(_ command: String) -> Bool {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              !text.contains(";"), !text.contains("|"), !text.contains("&"),
              !text.contains("<"), !text.contains(">"), !text.contains("`"),
              !text.contains("$("), !text.contains("\n"), !text.contains("\r") else {
            return false
        }
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let first = tokens.first else { return false }
        if first == "git" {
            guard tokens.count > 1 else { return false }
            return readOnlyGitSubcommands.contains(tokens[1])
        }
        if first == "find" {
            return !tokens.dropFirst().contains {
                ["-delete", "-exec", "-execdir", "-ok", "-fprint"].contains($0)
            }
        }
        return readOnlyCommands.contains(first)
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}