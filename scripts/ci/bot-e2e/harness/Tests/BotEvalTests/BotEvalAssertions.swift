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
    var workspaceRoot: URL
    var scratchRoot: URL
    /// The materialized `/dsh/workspace` root behind the per-Bot cwds. Card
    /// attachment paths are absolute in the Worker VFS, so `card_file_exists`
    /// maps `/dsh/workspace/...` through this root.
    var workspaceVolume: URL? = nil
    /// Parsed DSH session-log events per Bot, for `session_event`. This is the
    /// production session log (compaction checkpoints, turn origins), not the
    /// durable BotEvent journal.
    var sessionEvents: [String: [BotDSHSessionEvent]] = [:]
    var echoRequests: [EvalEchoRequest] = []
    /// Union of the tool names every model request advertised during this
    /// repeat. The mock upstream records the request body; the Worker's
    /// model-facing `tools/list` is the surface a Bot turn actually runs on.
    var advertisedTools: Set<String> = []
    /// Model-facing tool names per host-minted Bot session kind (`main`,
    /// `task`, `verifier`, `maintainer`). A restricted session must be
    /// evaluated on its own surface, never against the union of every request.
    var advertisedToolsBySession: [String: Set<String>] = [:]

    /// The surface recorded for one session kind. `main` falls back to the
    /// legacy union so a hand-built snapshot keeps its old meaning.
    func advertisedTools(for session: String) -> Set<String>? {
        if let scoped = advertisedToolsBySession[session] { return scoped }
        if session == "main" && !advertisedTools.isEmpty { return advertisedTools }
        return nil
    }
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
            let matches = replies.filter {
                $0.text.range(
                    of: value,
                    options: assertion.ignoreCase ? [.caseInsensitive] : []) != nil
            }
            let contains = !matches.isEmpty
            if assertion.type == "reply_contains" {
                return (contains, contains
                    ? "reply contains \(quoted(value))"
                    : "reply does not contain \(quoted(value)); \(replyDigest(replies))")
            }
            return (!contains, !contains
                ? "reply does not contain \(quoted(value))"
                : "reply contains \(quoted(value)); \(replyDigest(matches))")

        case "reply_regex", "reply_not_regex":
            let (replies, label) = try selectedReplies(assertion, snapshot: snapshot)
            guard !replies.isEmpty else {
                return (false, "no visible assistant reply for \(label)")
            }
            let pattern = assertion.value ?? ""
            let options: NSRegularExpression.Options = assertion.ignoreCase ? [.caseInsensitive] : []
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
                throw EvalAssertionError.invalid("invalid reply regex \(quoted(pattern))")
            }
            let matches = replies.filter { reply in
                regex.firstMatch(
                    in: reply.text,
                    range: NSRange(reply.text.startIndex..<reply.text.endIndex, in: reply.text)) != nil
            }
            let found = !matches.isEmpty
            if assertion.type == "reply_regex" {
                return (found, found
                    ? "reply matches /\(pattern)/"
                    : "reply does not match /\(pattern)/; \(replyDigest(replies))")
            }
            return (!found, !found
                ? "reply does not match /\(pattern)/"
                : "reply matches /\(pattern)/; \(replyDigest(matches))")

        case "reply_length":
            // A length budget covers the ordinary conversation, so the default
            // is every visible reply in the repeat, not only the latest turn.
            let botID = try resolveBot(assertion.bot, snapshot: snapshot)
            let allReplies = snapshot.replies.filter { $0.botID == botID }
            let replies: [EvalReply]
            let label: String
            if let turn = assertion.turn {
                replies = allReplies.filter { $0.turnNumber == turn }
                label = "\(assertion.bot ?? "main") turn \(turn)"
            } else {
                replies = allReplies
                label = assertion.bot ?? "main"
            }
            let lengths = replies.map(\.text.count).sorted()
            if lengths.isEmpty {
                return (assertion.allowNoReply,
                        assertion.allowNoReply
                            ? "no visible assistant reply for \(label) (allowed)"
                            : "no visible assistant reply for \(label)")
            }
            let median: Double
            if lengths.count % 2 == 1 {
                median = Double(lengths[lengths.count / 2])
            } else {
                median = Double(lengths[lengths.count / 2 - 1] + lengths[lengths.count / 2]) / 2
            }
            var failures: [String] = []
            if let maximum = assertion.medianMax, median > Double(maximum) {
                failures.append("median \(median) > \(maximum)")
            }
            if let maximum = assertion.eachMax, let longest = lengths.last, longest > maximum {
                failures.append("longest \(longest) > \(maximum)")
            }
            let detail = "\(label) reply chars: count \(lengths.count), median \(median), "
                + "min \(lengths.first ?? 0), max \(lengths.last ?? 0)"
                + (failures.isEmpty ? "" : "; \(failures.joined(separator: ", "))")
            return (failures.isEmpty, detail)

        case "card_count":
            let cards = matchingCards(assertion, snapshot: snapshot)
            let count = cards.count
            if let expected = assertion.equals {
                return (count == expected, "matching cards: \(count), expected exactly \(expected)\(cardDescription(cards))")
            }
            var failures: [String] = []
            if let minimum = assertion.min, count < minimum {
                failures.append("\(count) < \(minimum)")
            }
            if let maximum = assertion.max, count > maximum {
                failures.append("\(count) > \(maximum)")
            }
            return (failures.isEmpty,
                    "matching cards: \(count), min \(assertion.min.map(String.init) ?? "-"), "
                    + "max \(assertion.max.map(String.init) ?? "-")"
                    + (failures.isEmpty ? "" : "; \(failures.joined(separator: ", "))")
                    + cardDescription(cards))

        case "card_placement":
            let cards = matchingCards(assertion, snapshot: snapshot)
            guard !cards.isEmpty else {
                return (false, "no matching card.presented event for \(assertion.bot ?? "main")")
            }
            let replies = visibleReplyEvents(assertion.bot, snapshot: snapshot)
            var failures: [String] = []
            if assertion.afterReply {
                for card in cards {
                    let cardSeq = card.commitSeq ?? 0
                    if !replies.contains(where: { ($0.commitSeq ?? 0) < cardSeq }) {
                        failures.append("card \(card.eventId) has no earlier visible reply")
                    }
                }
            }
            if assertion.terminal {
                let lastCard = cards.map { $0.commitSeq ?? 0 }.max() ?? 0
                let after = replies.filter { ($0.commitSeq ?? 0) > lastCard }
                if !after.isEmpty {
                    failures.append("\(after.count) visible reply event(s) follow the last card")
                }
            }
            let detail = "cards \(cards.count), replies \(replies.count)"
                + (failures.isEmpty ? "" : "; \(failures.joined(separator: ", "))")
            return (failures.isEmpty, detail)

        case "card_file_exists":
            let cards = matchingCards(assertion, snapshot: snapshot)
            guard !cards.isEmpty else {
                return (false, "no matching card.presented event for \(assertion.bot ?? "main")")
            }
            let botID = try resolveBot(assertion.bot, snapshot: snapshot)
            guard let workspace = snapshot.workspaces[botID] else {
                throw EvalAssertionError.invalid("no materialized workspace for \(assertion.bot ?? "main")")
            }
            var checked: [String] = []
            var failures: [String] = []
            for card in cards {
                guard let data = card.data.objectValue,
                      let path = data["path"]?.stringValue, !path.isEmpty else { continue }
                checked.append(path)
                let resolved = resolveCardPath(path, workspace: workspace,
                                               volume: snapshot.workspaceVolume)
                if let resolved, FileManager.default.fileExists(atPath: resolved.path) {
                    continue
                }
                failures.append("card path is not a readable workspace file: \(path)")
            }
            if checked.isEmpty {
                return (false, "matching cards carry no path")
            }
            let detail = "card paths \(checked.count), failures \(failures.count)"
                + (failures.isEmpty ? "" : "; \(failures.joined(separator: ", "))")
            return (failures.isEmpty, detail)

        case "session_event", "no_session_event":
            let botID = try resolveBot(assertion.bot, snapshot: snapshot)
            guard let session = snapshot.sessionEvents[botID] else {
                return (false, "no parsed DSH session log for \(assertion.bot ?? "main")")
            }
            let matches = matchingSessionEvents(assertion, session: session)
            let found = !matches.isEmpty
            if assertion.type == "session_event" {
                return (found, found
                    ? "found \(matches.count) \(assertion.event ?? "?") session event(s)"
                    : "no \(assertion.event ?? "?") session event matched \(sessionFilterDescription(assertion))")
            }
            return (!found, !found
                ? "no \(assertion.event ?? "?") session event matched \(sessionFilterDescription(assertion))"
                : "found \(matches.count) forbidden \(assertion.event ?? "?") session event(s)")

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

        case "session_log_absent":
            let root = snapshot.workspaceRoot
                .appendingPathComponent("materialized/home/sessions", isDirectory: true)
            let needle = assertion.value ?? ""
            guard !needle.isEmpty else {
                return (false, "session_log_absent needs a non-empty value")
            }
            let manager = FileManager.default
            guard let enumerator = manager.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]) else {
                return (false, "no materialized session log directory at \(root.path)")
            }
            var scanned = 0
            var matches: [String] = []
            var compressed: [String] = []
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                      values.isRegularFile == true else { continue }
                guard url.lastPathComponent.hasPrefix("session.v") else { continue }
                if url.lastPathComponent.hasSuffix(".zstd") {
                    compressed.append(url.lastPathComponent)
                    continue
                }
                scanned += 1
                guard let data = try? Data(contentsOf: url) else { continue }
                if data.range(of: Data(needle.utf8)) != nil {
                    matches.append(url.lastPathComponent)
                }
            }
            if !compressed.isEmpty {
                return (false, "compressed session logs cannot be byte-scanned: \(compressed)")
            }
            if matches.isEmpty {
                return (true, "scanned \(scanned) session log file(s); none contains the word")
            }
            return (false, "session log file(s) still contain the word: \(matches)")

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

        case "tool_surface":
            if let bot = assertion.bot, bot != "main" {
                throw EvalAssertionError.invalid(
                    "tool_surface selects a session, not a Bot; use `session`")
            }
            let session = assertion.session ?? "main"
            guard EvalSessionKinds.all.contains(session) else {
                throw EvalAssertionError.invalid(
                    "tool_surface session must be one of "
                    + EvalSessionKinds.all.joined(separator: ", "))
            }
            guard let tools = snapshot.advertisedTools(for: session) else {
                return (false, "no model request recorded for the \(session) session")
            }
            guard !tools.isEmpty else {
                return (false, "the \(session) session advertised an empty tool list")
            }
            let present = assertion.present ?? []
            let absent = assertion.absent ?? []
            let exactly = assertion.exactly
            if exactly != nil && (!present.isEmpty || !absent.isEmpty) {
                throw EvalAssertionError.invalid(
                    "tool_surface `exactly` cannot be combined with present/absent")
            }
            if let exactly {
                guard !exactly.isEmpty else {
                    throw EvalAssertionError.invalid("tool_surface exactly must not be empty")
                }
                let expected = Set(exactly)
                let names = tools.sorted()
                if tools != expected {
                    return (false, "\(session) advertised tools are \(names); "
                        + "expected exactly \(expected.sorted())")
                }
                return (true, "\(session) advertised exactly \(names)")
            }
            if present.isEmpty && absent.isEmpty {
                throw EvalAssertionError.invalid("tool_surface needs present, absent or exactly")
            }
            let missing = present.filter { !tools.contains($0) }
            let leaked = absent.filter { tools.contains($0) }
            let names = tools.sorted()
            if !missing.isEmpty || !leaked.isEmpty {
                var detail = "\(session) advertised tools are \(names)"
                if !missing.isEmpty { detail += "; missing \(missing.sorted())" }
                if !leaked.isEmpty { detail += "; forbidden \(leaked.sorted())" }
                return (false, detail)
            }
            return (true, "\(session) advertised tools are \(names)")

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

    /// Distinct `card.presented` events for the filtered Bot. A progress card
    /// updated under the same `cardKey` is one card, matching the persona's
    /// "same cardKey updates one card" rule; a card without a key is identified
    /// by its durable id.
    private static func matchingCards(_ assertion: EvalAssertion,
                                      snapshot: EvalSnapshot) -> [BotEvent] {
        let botID = (try? resolveBot(assertion.bot, snapshot: snapshot)) ?? snapshot.mainBotID
        var order: [String] = []
        var latest: [String: BotEvent] = [:]
        for event in snapshot.events where event.type == "card.presented" {
            guard event.principal.botId == botID else { continue }
            let data = event.data.objectValue ?? [:]
            let card = data["card"]?.objectValue ?? [:]
            let cardType = data["cardType"]?.stringValue
                ?? card["cardType"]?.stringValue
                ?? ""
            if let include = assertion.cardTypes, !include.contains(cardType) { continue }
            if let exclude = assertion.excludeCardTypes, exclude.contains(cardType) { continue }
            if let tool = assertion.tool {
                let actual = data["tool"]?.stringValue ?? ""
                if !matchesToolName(tool, actual) { continue }
            }
            let key = data["cardKey"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                ?? data["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                ?? event.eventId
            if latest[key] == nil { order.append(key) }
            // A cardKey update replaces the rendered card; its last event is
            // the card's position for placement checks.
            latest[key] = event
        }
        return order.compactMap { latest[$0] }
    }

    /// User-visible prose: ordinary assistant text and the explicit
    /// `SendToUser` row both land in the conversation. Content-card placement
    /// must count either form as the preceding conclusion.
    private static func visibleReplyEvents(_ rawBot: String?, snapshot: EvalSnapshot) -> [BotEvent] {
        let botID = (try? resolveBot(rawBot, snapshot: snapshot)) ?? snapshot.mainBotID
        return snapshot.events.filter {
            ($0.type == "conversation.assistant_message" || $0.type == "ui.send_to_user")
                && $0.principal.botId == botID
        }
    }

    private static func resolveCardPath(_ raw: String, workspace: URL,
                                        volume: URL?) -> URL? {
        if raw.hasPrefix("/dsh/workspace/") {
            guard let volume else { return nil }
            return volume.appendingPathComponent(String(raw.dropFirst("/dsh/workspace/".count)))
        }
        if raw == "/dsh/workspace" { return volume }
        if raw.hasPrefix("/") { return nil }
        return workspace.appendingPathComponent(raw)
    }

    private static func matchingSessionEvents(_ assertion: EvalAssertion,
                                              session: [BotDSHSessionEvent]) -> [BotDSHSessionEvent] {
        session.filter { event in
            guard event.type == assertion.event else { return false }
            if let surfaceOp = assertion.surfaceOp, event.surfaceOp?.op != surfaceOp {
                return false
            }
            if let needle = assertion.payloadContains, !needle.isEmpty,
               !sessionPayload(event).contains(needle) {
                return false
            }
            guard let whereFields = assertion.whereFields, !whereFields.isEmpty else { return true }
            return whereFields.allSatisfy { key, expected in event.data[key] == expected }
        }
    }

    private static func sessionPayload(_ event: BotDSHSessionEvent) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(event.data)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func sessionFilterDescription(_ assertion: EvalAssertion) -> String {
        var parts: [String] = []
        if let surfaceOp = assertion.surfaceOp { parts.append("surfaceOp=\(surfaceOp)") }
        if let needle = assertion.payloadContains, !needle.isEmpty {
            parts.append("payload contains \(quoted(needle))")
        }
        if let whereFields = assertion.whereFields, !whereFields.isEmpty {
            parts.append(whereDescription(assertion))
        }
        return parts.isEmpty ? "" : " (" + parts.joined(separator: ", ") + ")"
    }

    private static func cardDescription(_ cards: [BotEvent]) -> String {
        guard !cards.isEmpty else { return "" }
        let types = cards.map { event -> String in
            let data = event.data.objectValue ?? [:]
            let card = data["card"]?.objectValue ?? [:]
            return data["cardType"]?.stringValue ?? card["cardType"]?.stringValue ?? "?"
        }
        return "; types \(types)"
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
