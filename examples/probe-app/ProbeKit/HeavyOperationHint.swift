// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — App-side "this tool call may be heavy" hint (S1-E).
//
// A local, no-network classification of one already-parsed `toolCall`: the
// Worker/Agent is not asked, no size is estimated, and nothing is blocked. The
// tool card renders a small "可能较重" badge when one of the typical phone
// hotspots is recognised. Command parsing is quote- and chain-aware so a
// string inside `echo`/`cat` is not mistaken for an invocation.

import Foundation

/// The heavy-operation families the pre-hint recognises.
public enum HeavyOperation: String, CaseIterable, Sendable {
    /// `git clone` without `--depth` (a full-history clone).
    case fullGitClone
    /// `npm install`, `pnpm install`, bare `yarn` and their aliases.
    case dependencyInstall
    /// `pip install` / `python -m pip install`.
    case pipInstall
    /// `curl`/`wget` download.
    case download
    /// `unzip` / `tar` extraction.
    case extract
}

public enum HeavyOperationHint {
    /// The badge copy shown on the tool card.
    public static let badge = "可能较重"

    /// Tool names whose command argument may be inspected. Names containing
    /// `bash`, `shell`, `exec`, `terminal` or `command` are accepted too, so an
    /// MCP plugin's runner is covered without a per-plugin list.
    private static let shellishNames: Set<String> = [
        "bash", "pwsh", "sh", "zsh", "shell", "exec", "terminal",
        "run_terminal_cmd", "run_command", "run_shell_command",
    ]

    /// Argument keys that carry the command line, in priority order.
    private static let commandKeys = ["command", "cmd", "commandLine", "command_line", "script"]

    /// Recognises the heavy families in one tool call.
    ///
    /// - Parameters:
    ///   - toolName: The tool name from the `toolCall` event.
    ///   - arguments: The flattened scalar arguments the App already parsed.
    /// - Returns: The recognised families, de-duplicated and in stable order.
    public static func operations(toolName: String,
                                  arguments: [String: String]) -> [HeavyOperation] {
        guard isShellish(toolName) else { return [] }
        var found = Set<HeavyOperation>()
        for key in commandKeys {
            guard let line = arguments[key], !line.isEmpty else { continue }
            found.formUnion(operations(inCommandLine: line))
        }
        return HeavyOperation.allCases.filter { found.contains($0) }
    }

    /// Convenience for the tool row: `true` when any badge should be shown.
    public static func isHeavy(toolName: String, arguments: [String: String]) -> Bool {
        !operations(toolName: toolName, arguments: arguments).isEmpty
    }

    /// Parses a shell command line into the heavy families it invokes.
    ///
    /// Quoted strings are skipped as commands, `&&`/`||`/`|`/`;`/newlines split
    /// the line, and leading `sudo`/`env`/assignment prefixes are ignored.
    public static func operations(inCommandLine line: String) -> [HeavyOperation] {
        var found = Set<HeavyOperation>()
        for command in splitCommandList(line) {
            let tokens = tokenize(command)
            guard !tokens.isEmpty else { continue }
            found.formUnion(operations(inTokens: stripPrefixes(tokens)))
        }
        return HeavyOperation.allCases.filter { found.contains($0) }
    }

    // MARK: - Detection

    private static func isShellish(_ toolName: String) -> Bool {
        let lower = toolName.lowercased()
        if shellishNames.contains(lower) { return true }
        return ["bash", "shell", "exec", "terminal", "command"].contains {
            lower.contains($0)
        }
    }

    private static func operations(inTokens tokens: [String]) -> Set<HeavyOperation> {
        guard let first = tokens.first else { return [] }
        let program = programName(first)
        var found = Set<HeavyOperation>()

        switch program {
        case "git":
            if tokens.contains("clone"),
               !tokens.contains(where: { $0 == "--depth" || $0.hasPrefix("--depth=") }) {
                found.insert(.fullGitClone)
            }
        case "npm", "pnpm":
            if let subcommand = firstSubcommand(tokens),
               ["install", "i", "ci", "add"].contains(subcommand) {
                found.insert(.dependencyInstall)
            }
        case "yarn":
            // Bare `yarn` installs dependencies; `yarn install`/`add` and the
            // other scripts are all heavy on a phone. Only a pure
            // `--version`/`--help` probe is skipped.
            let infoOnly = tokens.count > 1 && tokens.dropFirst().allSatisfy {
                ["--version", "-v", "--help", "-h"].contains($0)
            }
            if !infoOnly { found.insert(.dependencyInstall) }
        case "pip", "pip3":
            if firstSubcommand(tokens) == "install" { found.insert(.pipInstall) }
        case "python", "python3", "python3.13":
            if let dashM = tokens.firstIndex(of: "-m"),
               tokens.indices.contains(dashM + 1),
               programName(tokens[dashM + 1]) == "pip",
               tokens.indices.contains(dashM + 2),
               tokens[dashM + 2] == "install" {
                found.insert(.pipInstall)
            }
        case "curl", "wget":
            let infoOnly = tokens.dropFirst().allSatisfy {
                ["--version", "-V", "--help", "-h"].contains($0)
            }
            if !infoOnly { found.insert(.download) }
        case "unzip":
            found.insert(.extract)
        case "tar":
            if isExtraction(tokens.dropFirst()) { found.insert(.extract) }
        case "xargs":
            // `... | xargs -n1 unzip` still runs the child command.
            if let child = tokens.dropFirst().first(where: { !$0.hasPrefix("-") }) {
                found.formUnion(operations(inTokens: stripPrefixes([child])))
            }
        default:
            if program.hasPrefix("python"),
               let dashM = tokens.firstIndex(of: "-m"),
               tokens.indices.contains(dashM + 1),
               programName(tokens[dashM + 1]) == "pip",
               tokens.indices.contains(dashM + 2),
               tokens[dashM + 2] == "install" {
                found.insert(.pipInstall)
            }
        }
        return found
    }

    private static func firstSubcommand(_ tokens: [String]) -> String? {
        for token in tokens.dropFirst() {
            if token.hasPrefix("-") { continue }
            return token
        }
        return nil
    }

    private static func isExtraction(_ arguments: ArraySlice<String>) -> Bool {
        for (index, token) in arguments.enumerated() {
            if token == "--extract" || token == "--get" { return true }
            if token.hasPrefix("--") { continue }
            if token.hasPrefix("-") {
                let letters = token.dropFirst()
                if !letters.isEmpty, letters.allSatisfy({ $0.isLetter }),
                   letters.contains("x") {
                    return true
                }
                continue
            }
            // Classic `tar xzf archive` / `tar xf archive`: the first operand
            // is the option cluster.
            if index == 0, token.contains("x") { return true }
        }
        return false
    }

    private static func programName(_ token: String) -> String {
        token.split(separator: "/").last.map(String.init)?.lowercased() ?? token.lowercased()
    }

    /// Drops leading `sudo`/`env`/`time`/`command`/assignments so the real
    /// program is the first token.
    private static func stripPrefixes(_ tokens: [String]) -> [String] {
        var tokens = tokens
        var guardCount = 0
        while let first = tokens.first, guardCount < 8 {
            guardCount += 1
            let name = programName(first)
            if name == "sudo" || name == "doas" {
                tokens.removeFirst()
                while let next = tokens.first, next.hasPrefix("-") { tokens.removeFirst() }
                continue
            }
            if name == "env" || name == "time" || name == "command" || name == "nice" {
                tokens.removeFirst()
                while let next = tokens.first, next.hasPrefix("-") { tokens.removeFirst() }
                continue
            }
            if isAssignment(first) {
                tokens.removeFirst()
                continue
            }
            break
        }
        return tokens
    }

    private static func isAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "="), equals != token.startIndex else {
            return false
        }
        return token[..<equals].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    // MARK: - Shell splitting

    /// Splits a command line on unquoted `&&`, `||`, `|`, `;` and newlines.
    static func splitCommandList(_ line: String) -> [String] {
        var commands: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if escaped {
                current.append(character)
                escaped = false
                index = line.index(after: index)
                continue
            }
            if character == "\\" {
                current.append(character)
                escaped = true
                index = line.index(after: index)
                continue
            }
            if let active = quote {
                current.append(character)
                if character == active { quote = nil }
                index = line.index(after: index)
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                current.append(character)
                index = line.index(after: index)
                continue
            }
            if character == "\n" || character == ";" || character == "|" || character == "&" {
                if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                    commands.append(current)
                    current = ""
                }
                var next = line.index(after: index)
                if next < line.endIndex, line[next] == "&" || line[next] == "|" {
                    next = line.index(after: next)
                }
                index = next
                continue
            }
            current.append(character)
            index = line.index(after: index)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            commands.append(current)
        }
        return commands
    }

    /// Whitespace tokenizer that honours single/double quotes and backslash
    /// escapes and strips the quote characters.
    static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var hasToken = false
        for character in command {
            if escaped {
                current.append(character)
                hasToken = true
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                hasToken = true
                continue
            }
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
                hasToken = true
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                hasToken = true
                continue
            }
            if character.isWhitespace {
                if hasToken {
                    tokens.append(current)
                    current = ""
                    hasToken = false
                }
                continue
            }
            current.append(character)
            hasToken = true
        }
        if hasToken { tokens.append(current) }
        return tokens
    }
}
