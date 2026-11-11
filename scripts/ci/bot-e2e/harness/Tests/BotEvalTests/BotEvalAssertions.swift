// SPDX-License-Identifier: MIT
// phone-dsh Bot eval runner — assertion evaluation over one repeat's evidence.
//
// Every predicate is a pure function over an EvalSnapshot. The live runner and
// the negative-direction unit test feed the same functions, so an assertion
// cannot become "true because the evaluator was never exercised".

import CryptoKit
import Foundation
import PhoneDSHBot
import PhoneDSHAgentCore

struct EvalReply: Equatable {
    var botID: String
    var text: String
    var turnNumber: Int?
    var actionIndex: Int
}

struct EvalToolCallRecord: Equatable {
    var botID: String
    var name: String
    var arguments: String
}

struct EvalSnapshot {
    var mainBotID: String
    var botIDs: [String: String]
    var events: [BotEvent]
    var replies: [EvalReply]
    var toolCalls: [EvalToolCallRecord]
    var memories: [String: [BotMemoryDocument]]
    var workspaces: [String: URL]
    var scratchRoot: URL
    var echoRequests: [EvalEchoRequest] = []
}

struct EvalAssertionResult {
    var type: String
    var ok: Bool
    var detail: String
    var expectedOK: Bool
    var bot: String?
    var turn: Int?
}

enum EvalAssertions {
    static func evaluate(_ assertion: EvalAssertion, snapshot: EvalSnapshot) -> EvalAssertionResult {
        let expected = assertion.expectOK
        do {
            let (ok, detail) = try evaluateOne(assertion, snapshot: snapshot)
            return EvalAssertionResult(
                type: assertion.type, ok: ok, detail: detail, expectedOK: expected,
                bot: assertion.bot, turn: assertion.turn)
        } catch {
            return EvalAssertionResult(
                type: assertion.type, ok: false,
                detail: "evaluation error: \(error.localizedDescription)",
                expectedOK: expected, bot: assertion.bot, turn: assertion.turn)
        }
    }

    private static func evaluateOne(_ assertion: EvalAssertion,
                                    snapshot: EvalSnapshot) throws -> (Bool, String) {
        switch assertion.type {
        case "reply_contains", "reply_not_contains":
            let (replies, label) = try selectedReplies(assertion, snapshot: snapshot)
            guard !replies.isEmpty else {
                return (false, "no visible assistant reply for \(label)")
            }
            let value = assertion.value ?? ""
            let matches = replies.filter { $0.text.contains(value) }
            let contains = !matches.isEmpty
            if assertion.type == "reply_contains" {
                return (contains, contains
                    ? "reply contains \(quoted(value))"
                    : "reply does not contain \(quoted(value)); \(replyDigest(replies))")
            }
            return (!contains, !contains
                ? "reply does not contain \(quoted(value))"
                : "reply contains \(quoted(value)); \(replyDigest(matches))")

        case "bot_event", "no_bot_event":
            let events = matchingEvents(assertion, snapshot: snapshot)
            let found = !events.isEmpty
            if assertion.type == "bot_event" {
                return (found, found
                    ? "found \(events.count) \(assertion.event ?? "?") event(s)"
                    : "no \(assertion.event ?? "?") event matched \(whereDescription(assertion))")
            }
            return (!found, !found
                ? "no \(assertion.event ?? "?") event matched \(whereDescription(assertion))"
                : "found \(events.count) forbidden \(assertion.event ?? "?") event(s)")

        case "tool_called", "no_tool_call":
            let calls = matchingToolCalls(assertion, snapshot: snapshot)
            let found = !calls.isEmpty
            if assertion.type == "tool_called" {
                return (found, found
                    ? "called \(assertion.name ?? "?") \(calls.count) time(s)"
                    : "tool \(assertion.name ?? "?") was not called\(toolListDescription(snapshot))")
            }
            return (!found, !found
                ? "tool \(assertion.name ?? "?") was not called"
                : "tool \(assertion.name ?? "?") was called \(calls.count) time(s)")

        case "memory_contains", "memory_absent":
            let botID = try resolveBot(assertion.bot, snapshot: snapshot)
            let facts = matchingMemories(assertion, botID: botID, snapshot: snapshot)
            let found = !facts.isEmpty
            if assertion.type == "memory_contains" {
                return (found, found
                    ? "found \(facts.count) matching memory fact(s)"
                    : "no memory fact matched \(quoted(assertion.value ?? "")) for \(botID)")
            }
            return (!found, !found
                ? "no memory fact matched \(quoted(assertion.value ?? "")) for \(botID)"
                : "found \(facts.count) forbidden memory fact(s)")

        case "approval_count":
            let botID = try resolveBot(assertion.bot, snapshot: snapshot)
            let count = snapshot.events.filter {
                $0.type == "approval.requested" && $0.principal.botId == botID
            }.count
            if let expected = assertion.equals {
                return (count == expected, "approval requests: \(count), expected exactly \(expected)")
            }
            if let maximum = assertion.max {
                return (count <= maximum, "approval requests: \(count), maximum \(maximum)")
            }
            throw EvalAssertionError.invalid("approval_count needs equals or max")

        case "echo_requests":
            let method = assertion.method?.uppercased()
            let matching = snapshot.echoRequests.filter { request in
                if let method, request.method != method { return false }
                if let path = assertion.path, request.path != path { return false }
                return true
            }
            if let expected = assertion.equals {
                return (matching.count == expected,
                        "echo requests\(echoFilterDescription(assertion)): \(matching.count), "
                        + "expected exactly \(expected)")
            }
            if let maximum = assertion.max {
                return (matching.count <= maximum,
                        "echo requests\(echoFilterDescription(assertion)): \(matching.count), "
                        + "maximum \(maximum)")
            }
            throw EvalAssertionError.invalid("echo_requests needs equals or max")

        case "file_exists", "no_file", "file_contains", "file_regex", "file_json_path":
            return try evaluateFile(assertion, snapshot: snapshot)

        case "workspace_command":
            return try evaluateCommand(assertion, snapshot: snapshot)

        default:
            throw EvalAssertionError.invalid("unknown assertion type \(assertion.type)")
        }
    }

    // MARK: - Selection helpers

    private static func resolveBot(_ raw: String?, snapshot: EvalSnapshot) throws -> String {
        let name = raw ?? "main"
        if name == "main" { return snapshot.mainBotID }
        if let id = snapshot.botIDs[name] { return id }
        throw EvalAssertionError.invalid("unknown bot \(name)")
    }

    private static func selectedReplies(_ assertion: EvalAssertion,
                                        snapshot: EvalSnapshot) throws -> ([EvalReply], String) {
        let botID = try resolveBot(assertion.bot, snapshot: snapshot)
        let replies = snapshot.replies.filter { $0.botID == botID }
        if let turn = assertion.turn {
            let selected = replies.filter { $0.turnNumber == turn }
            return (selected, "\(assertion.bot ?? "main") turn \(turn)")
        }
        guard let latest = replies.map(\.turnNumber).compactMap({ $0 }).max() else {
            return ([], assertion.bot ?? "main")
        }
        return (replies.filter { $0.turnNumber == latest }, "\(assertion.bot ?? "main") turn \(latest)")
    }

    private static func matchingEvents(_ assertion: EvalAssertion,
                                       snapshot: EvalSnapshot) -> [BotEvent] {
        let botID = (try? resolveBot(assertion.bot, snapshot: snapshot)) ?? snapshot.mainBotID
        return snapshot.events.filter { event in
            guard event.type == assertion.event else { return false }
            guard event.principal.botId == botID else { return false }
            if let needle = assertion.payloadContains, !needle.isEmpty {
                let data = (try? JSONEncoder().encode(event.data)) ?? Data()
                let payload = String(decoding: data, as: UTF8.self)
                if !payload.contains(needle) { return false }
            }
            guard let whereFields = assertion.whereFields, !whereFields.isEmpty else { return true }
            return whereFields.allSatisfy { key, expected in
                guard case .object(let data) = event.data else { return false }
                return data[key] == expected
            }
        }
    }

    private static func matchingToolCalls(_ assertion: EvalAssertion,
                                          snapshot: EvalSnapshot) -> [EvalToolCallRecord] {
        let botID = (try? resolveBot(assertion.bot, snapshot: snapshot)) ?? snapshot.mainBotID
        let expectedName = assertion.name ?? ""
        return snapshot.toolCalls.filter { call in
            guard call.botID == botID else { return false }
            guard matchesToolName(expectedName, call.name) else { return false }
            if let needle = assertion.argumentsContains, !needle.isEmpty {
                return call.arguments.contains(needle)
            }
            return true
        }
    }

    private static func matchingMemories(_ assertion: EvalAssertion,
                                         botID: String,
                                         snapshot: EvalSnapshot) -> [BotMemoryDocument] {
        let value = assertion.value ?? ""
        return (snapshot.memories[botID] ?? []).filter { document in
            guard document.content.contains(value) else { return false }
            if let scope = assertion.scope, document.scope.rawValue != scope { return false }
            if let source = assertion.source, document.source?.kind.rawValue != source { return false }
            return true
        }
    }

    private static func echoFilterDescription(_ assertion: EvalAssertion) -> String {
        var parts: [String] = []
        if let method = assertion.method { parts.append("method \(method.uppercased())") }
        if let path = assertion.path { parts.append("path \(path)") }
        return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
    }

    static func matchesToolName(_ expected: String, _ actual: String) -> Bool {
        if expected == actual { return true }
        let bare = actual.split(separator: "__").last.map(String.init) ?? actual
        return expected == bare
    }

    // MARK: - Files

    private static func botWorkspace(_ assertion: EvalAssertion,
                                     snapshot: EvalSnapshot) throws -> (botID: String, root: URL) {
        let botID = try resolveBot(assertion.bot, snapshot: snapshot)
        guard let root = snapshot.workspaces[botID] else {
            throw EvalAssertionError.invalid("no materialized workspace for \(assertion.bot ?? "main")")
        }
        return (botID, root)
    }

    private static func safeRelativePath(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EvalAssertionError.invalid("empty path") }
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("\\") else {
            throw EvalAssertionError.invalid("path must be relative: \(trimmed)")
        }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains(".."), !parts.contains(".") else {
            throw EvalAssertionError.invalid("path escapes the Bot workspace: \(trimmed)")
        }
        return parts.joined(separator: "/")
    }

    private static func evaluateFile(_ assertion: EvalAssertion,
                                     snapshot: EvalSnapshot) throws -> (Bool, String) {
        let (_, root) = try botWorkspace(assertion, snapshot: snapshot)
        guard let rawPath = assertion.path else {
            throw EvalAssertionError.invalid("\(assertion.type) needs path")
        }
        let path = try safeRelativePath(rawPath)
        let url = root.appendingPathComponent(path)
        let exists = FileManager.default.fileExists(atPath: url.path)
        switch assertion.type {
        case "file_exists":
            return (exists, exists ? "file exists: \(path)" : "file missing: \(path)")
        case "no_file":
            return (!exists, !exists ? "file absent: \(path)" : "file exists: \(path)")
        case "file_contains":
            guard exists else { return (false, "file missing: \(path)") }
            let data = try Data(contentsOf: url)
            let text = String(decoding: data, as: UTF8.self)
            let value = assertion.value ?? ""
            let ok = text.contains(value)
            return (ok, ok ? "file \(path) contains \(quoted(value))"
                : "file \(path) does not contain \(quoted(value))")
        case "file_regex":
            guard exists else { return (false, "file missing: \(path)") }
            let data = try Data(contentsOf: url)
            let text = String(decoding: data, as: UTF8.self)
            let pattern = assertion.value ?? ""
            let ok = text.range(of: pattern, options: .regularExpression) != nil
            return (ok, ok ? "file \(path) matches \(quoted(pattern))"
                : "file \(path) does not match \(quoted(pattern))")
        case "file_json_path":
            guard exists else { return (false, "file missing: \(path)") }
            let data = try Data(contentsOf: url)
            let document = try JSONSerialization.jsonObject(with: data)
            let resolved = try resolveJSONPath(assertion.value ?? "", in: document)
            let ok = resolved != nil && !(resolved is NSNull)
            return (ok, ok ? "file \(path) resolves \(quoted(assertion.value ?? ""))"
                : "file \(path) does not resolve \(quoted(assertion.value ?? ""))")
        default:
            throw EvalAssertionError.invalid("not a file assertion: \(assertion.type)")
        }
    }

    private static func resolveJSONPath(_ path: String, in document: Any) throws -> Any? {
        var current: Any? = document
        for rawComponent in path.split(separator: ".") {
            var component = String(rawComponent)
            var indexes: [String] = []
            while let open = component.lastIndex(of: "["), component.hasSuffix("]") {
                let index = String(component[component.index(after: open)..<component.index(before: component.endIndex)])
                indexes.insert(index, at: 0)
                component = String(component[..<open])
            }
            if !component.isEmpty {
                guard let object = current as? [String: Any], let next = object[component] else {
                    return nil
                }
                current = next
            }
            for index in indexes {
                guard let number = Int(index) else { return nil }
                guard let array = current as? [Any], array.indices.contains(number) else { return nil }
                current = array[number]
            }
        }
        return current
    }

    // MARK: - workspace_command

    private static func evaluateCommand(_ assertion: EvalAssertion,
                                        snapshot: EvalSnapshot) throws -> (Bool, String) {
        let (_, root) = try botWorkspace(assertion, snapshot: snapshot)
        guard let command = assertion.command, !command.isEmpty else {
            throw EvalAssertionError.invalid("workspace_command needs command")
        }
        let forbidden = try workerVFSOnlyPath(in: command)
        if let forbidden {
            return (false, "worker_vfs_only: \(forbidden) exists only in the Worker VFS; "
                + "the host cannot reproduce the command")
        }
        let copy = snapshot.scratchRoot
            .appendingPathComponent("check-workspace-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copy) }
        if FileManager.default.fileExists(atPath: root.path) {
            let contents = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)
            for item in contents {
                try FileManager.default.copyItem(
                    at: item, to: copy.appendingPathComponent(item.lastPathComponent))
            }
        }
        let rewritten = command.replacingOccurrences(of: "/dsh/workspace", with: copy.path)
        let timeout = assertion.timeoutS ?? 180
        let result = try runBash(rewritten, in: copy, timeout: timeout)
        let detail = "exit \(result.status)\(result.timedOut ? " (timed out)" : "")"
            + (result.tail.isEmpty ? "" : ": \(result.tail)")
            + "\n[environment: host-bash; worker VFS: not used; path: /dsh/workspace -> \(copy.path)]"
        return (result.status == 0 && !result.timedOut, detail)
    }

    private struct CommandResult {
        var status: Int32
        var timedOut: Bool
        var tail: String
    }

    private static func runBash(_ command: String, in directory: URL,
                                timeout: TimeInterval) throws -> CommandResult {
        let stdoutURL = directory.appendingPathComponent(".eval-stdout")
        let stderrURL = directory.appendingPathComponent(".eval-stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = directory
        process.standardOutput = stdout
        process.standardError = stderr
        var timedOut = false
        do {
            try process.run()
        } catch {
            try? stdout.close()
            try? stderr.close()
            throw error
        }
        let deadline = Date().addingTimeInterval(max(1, timeout))
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            timedOut = true
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        try? stdout.close()
        try? stderr.close()
        var combined = Data()
        if let out = try? Data(contentsOf: stdoutURL) { combined.append(out) }
        if let err = try? Data(contentsOf: stderrURL) {
            if !combined.isEmpty { combined.append(0x0A) }
            combined.append(err)
        }
        var text = String(decoding: combined, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 600 {
            text = "…" + String(text.suffix(600))
        }
        try? FileManager.default.removeItem(at: stdoutURL)
        try? FileManager.default.removeItem(at: stderrURL)
        return CommandResult(status: process.terminationStatus, timedOut: timedOut, tail: text)
    }

    private static func workerVFSOnlyPath(in command: String) throws -> String? {
        let pattern = #"(?<![A-Za-z0-9_/])/dsh[^\s"'`;|&()<>\\]*"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        for match in regex.matches(in: command, range: range) {
            guard let matchRange = Range(match.range, in: command) else { continue }
            var token = String(command[matchRange])
            while let last = token.last, ".,;:".contains(last) { token.removeLast() }
            if token == "/dsh/workspace" || token.hasPrefix("/dsh/workspace/") {
                if token.contains("/../") || token.hasSuffix("/..") {
                    return token
                }
                continue
            }
            return token
        }
        return nil
    }

    // MARK: - Descriptions

    private static func quoted(_ value: String) -> String {
        "\"\(value)\""
    }

    private static func whereDescription(_ assertion: EvalAssertion) -> String {
        guard let whereFields = assertion.whereFields, !whereFields.isEmpty else { return "" }
        let rendered = whereFields.keys.sorted().map { "\($0)=\(whereFields[$0]?.display ?? "?")" }
        return "where " + rendered.joined(separator: ", ")
    }

    private static func replyDigest(_ replies: [EvalReply]) -> String {
        replies.map { reply in
            "len=\(reply.text.count) sha256=\(EvalRedaction.sha256(Data(reply.text.utf8)).prefix(16))"
        }.joined(separator: "; ")
    }

    private static func toolListDescription(_ snapshot: EvalSnapshot) -> String {
        let names = Set(snapshot.toolCalls.map(\.name)).sorted()
        guard !names.isEmpty else { return "; no tool calls were recorded" }
        return "; recorded tools: \(names.joined(separator: ", "))"
    }
}

enum EvalAssertionError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let detail): return detail
        }
    }
}

extension JSONValue {
    var display: String {
        switch self {
        case .string(let value): return value
        case .number(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .array, .object:
            let data = (try? JSONEncoder().encode(self)) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }
}

enum EvalRedaction {
    static func redact(_ text: String, secrets: [String]) -> String {
        var value = text
        for secret in secrets where !secret.isEmpty {
            value = value.replacingOccurrences(of: secret, with: "<redacted>")
        }
        value = replace(value, pattern: #"sk-[A-Za-z0-9_-]{8,}"#, with: "sk-<redacted>")
        value = replace(value, pattern: #"(?i)(authorization\s*:\s*)[^\r\n]+"#,
                        with: "$1<redacted>")
        value = replace(value, pattern: #"(?i)(x-api-key\s*[=:]\s*)[^\s"',;]+"#,
                        with: "$1<redacted>")
        return value
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func replace(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
