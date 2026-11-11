// SPDX-License-Identifier: MIT

import Foundation

/// How one memory claim was learned. The value is derived from record
/// references, never from the session kind or the model's own wording.
public enum BotRecordTrust: String, Sendable, Equatable {
    case user
    case observation
    case assistant
}

public struct BotRecordEvidence: Sendable, Equatable {
    public var trust: BotRecordTrust
    public var refs: [String]

    public init(trust: BotRecordTrust, refs: [String]) {
        self.trust = trust
        self.refs = refs
    }
}

public enum BotRecordServiceError: Error, Sendable, Equatable {
    case unclaimedSession
    case sessionOutOfScope
    case unknownRecord
    case invalidReference
    case invalidQuery
    case invalidSince
    case invalidAround
    case invalidArguments
    case unavailable(String)
}

public protocol BotRecordEvidenceResolving: Sendable {
    func resolveEvidence(_ references: [String], callerBotID: String,
                         callerSessionID: String) async throws -> BotRecordEvidence
}

public struct BotRecordCommandOutput: Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32

    public init(stdout: String, stderr: String = "", exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// Read-only search/read over the host's materialized DSH session logs and
/// the SQLite `bot_events` store. Every entry point resolves the caller from a
/// claimed session; no argument can name another Bot.
public actor BotRecordService: BotRecordEvidenceResolving {
    public static let maximumHits = 20
    public static let maximumAround = 20
    public static let maximumQueryScalars = 200
    public static let maximumEvidence = 8
    public static let maximumRawBytes = 16 * 1024
    public static let maximumOutputBytes = 256 * 1024

    private struct SessionLine {
        var seq: Int
        var raw: String
        var type: String
        var time: Int64
        var surfaceOp: (start: Int, end: Int)?
        var searchable: String
    }

    private struct EventRecord {
        var event: BotEvent
        var raw: String
        var searchable: String
    }

    private let store: SQLiteDomainStore
    private let gateway: BotGateway
    private let sessionLogLocator: @Sendable (String) -> URL?
    private let now: @Sendable () -> Int64

    public init(store: SQLiteDomainStore, gateway: BotGateway, workspaceRoot: URL,
                sessionLogLocator: (@Sendable (String) -> URL?)? = nil,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }) {
        self.store = store
        self.gateway = gateway
        self.now = now
        self.sessionLogLocator = sessionLogLocator ?? { sessionID in
            let directory = workspaceRoot
                .appendingPathComponent("materialized/home/sessions", isDirectory: true)
                .appendingPathComponent(sessionID, isDirectory: true)
            let manager = FileManager.default
            guard let files = try? manager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { return nil }
            return files
                .filter { $0.lastPathComponent.hasPrefix("session.v") && $0.pathExtension == "jsonl" }
                .sorted { lhs, rhs in
                    let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return left > right
                }
                .first
        }
    }

    // MARK: - Command bridge

    /// Runs `phone record …` argv (without the leading `phone record` words).
    /// The caller session is host-resolved out-of-band; `--session` only filters.
    public nonisolated static func bridge(arguments: [String], callerSessionID: String,
                                          service: BotRecordService) async -> BotRecordCommandOutput {
        await service.execute(arguments: arguments, callerSessionID: callerSessionID)
    }

    /// Runs one `phone record` argv. The host shell calls this with the
    /// out-of-band session; tests call it directly.
    public func execute(arguments: [String], callerSessionID: String) async -> BotRecordCommandOutput {
        do {
            let command = try Self.parse(arguments)
            switch command {
            case let .search(query, since, session):
                let result = try await search(query: query, since: since, session: session,
                                              callerSessionID: callerSessionID)
                return try Self.output(tool: "record.search", data: result.value,
                                       truncated: result.truncated)
            case let .read(reference, around):
                let result = try await read(reference: reference, around: around,
                                            callerSessionID: callerSessionID)
                return try Self.output(tool: "record.read", data: result.value,
                                       truncated: result.truncated)
            }
        } catch let error as BotRecordUsageError {
            return Self.failure(tool: error.tool, code: error.code, message: error.message, exitCode: 2)
        } catch let error as BotRecordServiceError {
            let tool = arguments.first == "read" ? "record.read" : "record.search"
            return Self.failure(tool: tool, code: Self.code(for: error),
                                message: Self.message(for: error),
                                exitCode: Self.exitCode(for: error))
        } catch {
            return Self.failure(tool: arguments.first == "read" ? "record.read" : "record.search",
                                code: "unavailable", message: "record store is unavailable", exitCode: 1)
        }
    }

    private enum Command {
        case search(query: String, since: Int64?, session: String?)
        case read(reference: String, around: Int)
    }

    private struct BotRecordUsageError: Error {
        var tool: String
        var code: String
        var message: String
    }

    private static func parse(_ arguments: [String]) throws -> Command {
        guard let verb = arguments.first else {
            throw BotRecordUsageError(tool: "record.search", code: "invalid_arguments",
                                      message: "usage: phone record search|read …")
        }
        switch verb {
        case "search":
            var words: [String] = []
            var since: Int64?
            var session: String?
            var index = 1
            while index < arguments.count {
                let word = arguments[index]
                switch word {
                case "--since":
                    guard index + 1 < arguments.count, since == nil else {
                        throw BotRecordUsageError(tool: "record.search", code: "invalid_since",
                                                  message: "--since takes one RFC3339 or epoch-ms value")
                    }
                    since = try parseSince(arguments[index + 1])
                    index += 2
                case "--session":
                    guard index + 1 < arguments.count, session == nil else {
                        throw BotRecordUsageError(tool: "record.search", code: "invalid_arguments",
                                                  message: "--session takes one session id")
                    }
                    let candidate = arguments[index + 1]
                    guard BotRecordReference.validSessionID(candidate) else {
                        throw BotRecordUsageError(tool: "record.search", code: "invalid_arguments",
                                                  message: "--session must be a D-6 session id")
                    }
                    session = candidate
                    index += 2
                default:
                    guard !word.hasPrefix("--") else {
                        throw BotRecordUsageError(tool: "record.search", code: "invalid_arguments",
                                                  message: "unknown flag \(word)")
                    }
                    words.append(word)
                    index += 1
                }
            }
            let query = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, query.unicodeScalars.count <= maximumQueryScalars else {
                throw BotRecordUsageError(tool: "record.search", code: "invalid_query",
                                          message: "the query must be 1...\(maximumQueryScalars) characters")
            }
            return .search(query: query, since: since, session: session)
        case "read":
            var reference: String?
            var around = 2
            var index = 1
            while index < arguments.count {
                let word = arguments[index]
                if word == "--around" {
                    guard index + 1 < arguments.count,
                          let value = Int(arguments[index + 1]),
                          (0...maximumAround).contains(value) else {
                        throw BotRecordUsageError(tool: "record.read", code: "invalid_around",
                                                  message: "--around must be an integer in 0...\(maximumAround)")
                    }
                    around = value
                    index += 2
                    continue
                }
                guard !word.hasPrefix("--"), reference == nil else {
                    throw BotRecordUsageError(tool: "record.read", code: "invalid_arguments",
                                              message: "usage: phone record read <record-ref> [--around N]")
                }
                reference = word
                index += 1
            }
            guard let reference else {
                throw BotRecordUsageError(tool: "record.read", code: "invalid_arguments",
                                          message: "usage: phone record read <record-ref> [--around N]")
            }
            guard BotRecordReference.parse(reference) != nil else {
                throw BotRecordUsageError(tool: "record.read", code: "invalid_reference",
                                          message: "the argument is not a canonical record:// reference")
            }
            return .read(reference: reference, around: around)
        default:
            throw BotRecordUsageError(tool: "record.search", code: "invalid_arguments",
                                      message: "unknown record subcommand \(verb)")
        }
    }

    private static func parseSince(_ raw: String) throws -> Int64 {
        if let number = Int64(raw), number >= 0 {
            return number
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) {
            return Int64(date.timeIntervalSince1970 * 1_000)
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: raw) {
            return Int64(date.timeIntervalSince1970 * 1_000)
        }
        throw BotRecordUsageError(tool: "record.search", code: "invalid_since",
                                  message: "--since must be RFC3339 or epoch milliseconds")
    }

    // MARK: - Search

    private struct EncodedResult {
        var value: BotJSONValue
        var truncated: Bool
    }

    private func search(query: String, since: Int64?, session: String?,
                        callerSessionID: String) async throws -> EncodedResult {
        let caller = try await principal(for: callerSessionID, botID: nil)
        let events = try await allEvents()
        let owned = ownedSessions(botID: caller.botId, callerSessionID: callerSessionID, events: events)
        if let session, !owned.contains(session) {
            throw BotRecordServiceError.sessionOutOfScope
        }
        let sessions = session.map { [$0] } ?? owned.sorted()
        let needle = query.lowercased()
        var hits: [BotJSONValue] = []
        var overflow = false
        for sessionID in sessions {
            guard let lines = try? sessionLines(sessionID: sessionID) else { continue }
            for line in lines {
                guard since == nil || line.time >= since!,
                      line.searchable.lowercased().contains(needle) else { continue }
                if hits.count == Self.maximumHits { overflow = true; break }
                hits.append(.object([
                    "ref": .string("record://session/\(sessionID)#\(line.seq)"),
                    "record": .string("session"),
                    "sessionId": .string(sessionID),
                    "seq": .number(Double(line.seq)),
                    "type": .string(line.type),
                    "time": .number(Double(line.time)),
                    "snippet": .string(Self.snippet(line.searchable, needle: needle)),
                ]))
            }
            if overflow { break }
        }
        if !overflow {
            for record in events where record.event.principal.botId == caller.botId {
                guard since == nil || record.event.time >= since!,
                      record.searchable.lowercased().contains(needle),
                      let commitSeq = record.event.commitSeq else { continue }
                if hits.count == Self.maximumHits { overflow = true; break }
                var fields: [String: BotJSONValue] = [
                    "ref": .string("record://event/\(commitSeq)"),
                    "record": .string("event"),
                    "commitSeq": .number(Double(commitSeq)),
                    "type": .string(record.event.type),
                    "time": .number(Double(record.event.time)),
                    "snippet": .string(Self.snippet(record.searchable, needle: needle)),
                ]
                if let sessionID = record.event.principal.sessionId {
                    fields["sessionId"] = .string(sessionID)
                }
                hits.append(.object(fields))
            }
        }
        hits.sort { lhs, rhs in
            let left = lhs["time"]?.numberValue ?? 0
            let right = rhs["time"]?.numberValue ?? 0
            if left != right { return left > right }
            return (lhs["ref"]?.stringValue ?? "") < (rhs["ref"]?.stringValue ?? "")
        }
        let data = BotJSONValue.object([
            "query": .string(query),
            "since": since.map { BotJSONValue.number(Double($0)) } ?? .null,
            "hits": .array(hits),
        ])
        return EncodedResult(value: data, truncated: overflow)
    }

    // MARK: - Read

    private func read(reference raw: String, around: Int,
                      callerSessionID: String) async throws -> EncodedResult {
        guard let reference = BotRecordReference.parse(raw) else {
            throw BotRecordServiceError.invalidReference
        }
        let caller = try await principal(for: callerSessionID, botID: nil)
        let events = try await allEvents()
        let owned = ownedSessions(botID: caller.botId, callerSessionID: callerSessionID, events: events)
        switch reference {
        case let .session(sessionID, seq):
            guard owned.contains(sessionID) else { throw BotRecordServiceError.sessionOutOfScope }
            guard let lines = try? sessionLines(sessionID: sessionID) else {
                throw BotRecordServiceError.unknownRecord
            }
            guard let target = lines.firstIndex(where: { $0.seq == seq }) else {
                throw BotRecordServiceError.unknownRecord
            }
            let start = max(0, target - around)
            let end = min(lines.count - 1, target + around)
            let shadow = lines.compactMap { line -> (BotRecordReference, (start: Int, end: Int))? in
                guard let range = line.surfaceOp, range.start...range.end ~= seq else { return nil }
                return (.session(sessionID: sessionID, seq: line.seq), range)
            }.last
            var encoded: [BotJSONValue] = []
            for index in start...end {
                let line = lines[index]
                var fields: [String: BotJSONValue] = [
                    "ref": .string("record://session/\(sessionID)#\(line.seq)"),
                    "record": .string("session"),
                    "sessionId": .string(sessionID),
                    "seq": .number(Double(line.seq)),
                    "type": .string(line.type),
                    "time": .number(Double(line.time)),
                ]
                let (rawText, truncated) = Self.boundedRaw(line.raw)
                fields["raw"] = .string(rawText)
                fields["truncated"] = .bool(truncated)
                if let range = line.surfaceOp {
                    fields["replaces"] = .object([
                        "startRef": .string("record://session/\(sessionID)#\(range.start)"),
                        "endRef": .string("record://session/\(sessionID)#\(range.end)"),
                    ])
                } else if let shadow, line.seq == seq, index == target {
                    fields["shadowedBy"] = .string(shadow.0.canonical)
                }
                encoded.append(.object(fields))
            }
            return EncodedResult(value: .object([
                "ref": .string(reference.canonical),
                "lines": .array(encoded),
            ]), truncated: encoded.contains { $0["truncated"]?.boolValue == true })
        case let .event(commitSeq):
            guard let record = events.first(where: { $0.event.commitSeq == commitSeq }) else {
                throw BotRecordServiceError.unknownRecord
            }
            guard record.event.principal.botId == caller.botId else {
                throw BotRecordServiceError.sessionOutOfScope
            }
            let (rawText, truncated) = Self.boundedRaw(record.raw)
            return EncodedResult(value: .object([
                "ref": .string(reference.canonical),
                "lines": .array([.object([
                    "ref": .string(reference.canonical),
                    "record": .string("event"),
                    "commitSeq": .number(Double(commitSeq)),
                    "type": .string(record.event.type),
                    "time": .number(Double(record.event.time)),
                    "raw": .string(rawText),
                    "truncated": .bool(truncated),
                ])]),
            ]), truncated: truncated)
        }
    }

    // MARK: - Evidence

    public func resolveEvidence(_ references: [String], callerBotID: String,
                                callerSessionID: String) async throws -> BotRecordEvidence {
        guard references.count <= Self.maximumEvidence else {
            throw BotRecordServiceError.invalidArguments
        }
        let caller = try await principal(for: callerSessionID, botID: callerBotID)
        let events = try await allEvents()
        let owned = ownedSessions(botID: caller.botId, callerSessionID: callerSessionID, events: events)
        let calls = toolCalls(events)
        var trust = BotRecordTrust.assistant
        var canonical: [String] = []
        for raw in references {
            guard let reference = BotRecordReference.parse(raw) else {
                throw BotRecordServiceError.invalidReference
            }
            canonical.append(reference.canonical)
            switch reference {
            case let .session(sessionID, seq):
                guard owned.contains(sessionID),
                      let lines = try? sessionLines(sessionID: sessionID),
                      let line = lines.first(where: { $0.seq == seq }) else {
                    throw BotRecordServiceError.unknownRecord
                }
                if let inferred = inferredTrust(for: line, sessionID: sessionID, calls: calls) {
                    trust = merge(trust, inferred)
                }
            case let .event(commitSeq):
                guard let record = events.first(where: { $0.event.commitSeq == commitSeq }),
                      record.event.principal.botId == caller.botId else {
                    throw BotRecordServiceError.unknownRecord
                }
                if let inferred = inferredTrust(for: record.event, calls: calls) {
                    trust = merge(trust, inferred)
                }
            }
        }
        return BotRecordEvidence(trust: trust, refs: canonical)
    }

    private func principal(for sessionID: String, botID: String?) async throws -> BotGatewayPrincipal {
        guard BotRecordReference.validSessionID(sessionID),
              let principal = await gateway.tokens.lookupSession(sessionID) else {
            throw BotRecordServiceError.unclaimedSession
        }
        if let botID, principal.botId != botID {
            throw BotRecordServiceError.unclaimedSession
        }
        return principal
    }

    private func ownedSessions(botID: String, callerSessionID: String,
                               events: [EventRecord]) -> Set<String> {
        var sessions: Set<String> = [callerSessionID]
        for record in events where record.event.principal.botId == botID {
            if let sessionID = record.event.principal.sessionId { sessions.insert(sessionID) }
            if case let .dsh(sessionID, _) = record.event.origin { sessions.insert(sessionID) }
        }
        return sessions
    }

    private func toolCalls(_ events: [EventRecord]) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        for record in events {
            guard record.event.type == "conversation.tool_call",
                  let sessionID = record.event.principal.sessionId,
                  let callID = record.event.data["callId"]?.stringValue,
                  let name = record.event.data["name"]?.stringValue else { continue }
            result[sessionID, default: [:]][callID] = name
        }
        return result
    }

    private func inferredTrust(for line: SessionLine, sessionID: String,
                       calls: [String: [String: String]]) -> BotRecordTrust? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.raw.utf8)) as? [String: Any],
              let data = object["data"] as? [String: Any] else { return nil }
        switch line.type {
        case "user/message":
            let source = data["source"] as? [String: Any]
            guard source?["kind"] as? String == "user",
                  isUserRPC(source?["rpcId"] as? String) else { return .assistant }
            return .user
        case "tool/call":
            let name = data["name"] as? String ?? ""
            let arguments = data["arguments"] as? String
            return Self.externalTool(name, arguments: arguments) ? .observation : .assistant
        case "tool/result":
            let callID = (data["message"] as? [String: Any])?["toolCallId"] as? String
                ?? (data["source"] as? [String: Any])?["callId"] as? String
            guard let callID, let name = calls[sessionID]?[callID] else { return .assistant }
            return Self.externalTool(name, arguments: nil) ? .observation : .assistant
        default:
            return .assistant
        }
    }

    private func inferredTrust(for event: BotEvent,
                       calls: [String: [String: String]]) -> BotRecordTrust? {
        switch event.type {
        case "conversation.user_message":
            let source = event.data["source"]
            guard source?["kind"]?.stringValue == "user",
                  isUserRPC(source?["rpcId"]?.stringValue) else { return .assistant }
            return .user
        case "conversation.tool_call":
            let name = event.data["name"]?.stringValue ?? ""
            let arguments = event.data["arguments"]?.stringValue
            return Self.externalTool(name, arguments: arguments) ? .observation : .assistant
        case "conversation.tool_result":
            let callID = event.data["message"]?["toolCallId"]?.stringValue
                ?? event.data["callId"]?.stringValue
            guard let callID, let sessionID = event.principal.sessionId,
                  let name = calls[sessionID]?[callID] else { return .assistant }
            return Self.externalTool(name, arguments: nil) ? .observation : .assistant
        default:
            return .assistant
        }
    }

    private func merge(_ lhs: BotRecordTrust, _ rhs: BotRecordTrust) -> BotRecordTrust {
        let order: [BotRecordTrust: Int] = [.assistant: 0, .observation: 1, .user: 2]
        return (order[lhs] ?? 0) >= (order[rhs] ?? 0) ? lhs : rhs
    }

    private func isUserRPC(_ rpcID: String?) -> Bool {
        guard let rpcID else { return true }
        guard !rpcID.isEmpty else { return false }
        let nonUser = ["held:", "agent:", "routine:", "task-turn:", "task-settled:", "task-interrupted:"]
        if nonUser.contains(where: { rpcID.hasPrefix($0) }) { return false }
        return ["bot-", "user-action:", "card-answer:"].contains(where: { rpcID.hasPrefix($0) })
    }

    static func externalTool(_ name: String, arguments: String?) -> Bool {
        if ["web_fetch", "web_search", "Task", "AwaitTask", "StopSubagent"].contains(name) {
            return true
        }
        if name.hasPrefix("mcp__phone__android_") || name.hasPrefix("mcp__phone__ble_") {
            return true
        }
        if name.hasPrefix("mcp__phone__") { return false }
        if name.hasPrefix("mcp__") { return true }
        if name == "read", let arguments,
           let object = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
           let path = object["path"] as? String,
           path.contains("/imports/attachments-") {
            return true
        }
        return false
    }

    // MARK: - Storage

    private func allEvents() async throws -> [EventRecord] {
        var records: [EventRecord] = []
        var cursor = 0
        let codec = BotEventEnvelopeCodec()
        while true {
            let page = try await store.events(after: cursor, limit: 500)
            if page.isEmpty { break }
            for event in page {
                let raw = (try? codec.encode(event))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                records.append(EventRecord(event: event, raw: raw,
                                           searchable: Self.searchable(event.data)))
            }
            guard let last = page.last?.commitSeq else { break }
            cursor = last
            if page.count < 500 { break }
        }
        return records
    }

    private func sessionLines(sessionID: String) throws -> [SessionLine] {
        guard let url = sessionLogLocator(sessionID),
              let data = try? Data(contentsOf: url) else {
            throw BotRecordServiceError.unknownRecord
        }
        var lines: [SessionLine] = []
        var first = true
        for rawLine in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let line = String(decoding: rawLine, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, let object = try? JSONSerialization.jsonObject(
                with: Data(line.utf8)) as? [String: Any] else { continue }
            if first {
                first = false
                if object["type"] as? String == "session" { continue }
            }
            guard let seq = object["seq"] as? Int,
                  let type = object["type"] as? String else { continue }
            let time = (object["time"] as? NSNumber)?.int64Value ?? 0
            var surface: (start: Int, end: Int)?
            if let op = object["surfaceOp"] as? [String: Any],
               op["op"] as? String == "replace",
               let start = op["startSeq"] as? Int,
               let end = op["endSeq"] as? Int, start <= end {
                surface = (start, end)
            }
            let data = object["data"] ?? [:]
            lines.append(SessionLine(
                seq: seq, raw: line, type: type, time: time, surfaceOp: surface,
                searchable: Self.searchable(data)))
        }
        return lines
    }

    private static func searchable(_ value: BotJSONValue) -> String {
        var parts: [String] = []
        func walk(_ value: BotJSONValue, depth: Int) {
            guard depth < 12, parts.reduce(0, { $0 + $1.utf8.count }) < 64 * 1024 else { return }
            switch value {
            case let .string(text): parts.append(text)
            case let .number(number): parts.append(String(number))
            case let .bool(flag): parts.append(flag ? "true" : "false")
            case let .array(values): values.forEach { walk($0, depth: depth + 1) }
            case let .object(object):
                for (key, item) in object where !["rawOutput", "raw", "stream", "usage", "arguments"].contains(key) {
                    parts.append(key)
                    walk(item, depth: depth + 1)
                }
            case .null: break
            }
        }
        walk(value, depth: 0)
        return parts.joined(separator: " ")
    }

    private static func searchable(_ value: Any) -> String {
        var parts: [String] = []
        func walk(_ value: Any, depth: Int) {
            guard depth < 12, parts.reduce(0, { $0 + $1.utf8.count }) < 64 * 1024 else { return }
            switch value {
            case let text as String: parts.append(text)
            case let number as NSNumber: parts.append(number.stringValue)
            case let array as [Any]: array.forEach { walk($0, depth: depth + 1) }
            case let object as [String: Any]:
                for (key, item) in object where !["rawOutput", "raw", "stream", "usage"].contains(key) {
                    parts.append(key)
                    walk(item, depth: depth + 1)
                }
            default: break
            }
        }
        walk(value, depth: 0)
        return parts.joined(separator: " ")
    }

    private static func snippet(_ text: String, needle: String) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard let range = single.lowercased().range(of: needle) else {
            return String(single.prefix(180))
        }
        let start = single.index(range.lowerBound, offsetBy: -80, limitedBy: single.startIndex)
            ?? single.startIndex
        let end = single.index(range.upperBound, offsetBy: 80, limitedBy: single.endIndex)
            ?? single.endIndex
        return String(single[start..<end])
    }

    private static func boundedRaw(_ raw: String) -> (String, Bool) {
        let data = Data(raw.utf8)
        guard data.count > maximumRawBytes else { return (raw, false) }
        return (String(decoding: data.prefix(maximumRawBytes), as: UTF8.self), true)
    }

    // MARK: - Envelopes

    private static func output(tool: String, data: BotJSONValue,
                               truncated: Bool) throws -> BotRecordCommandOutput {
        let value = BotJSONValue.object([
            "ok": .bool(true),
            "tool": .string(tool),
            "egress": .bool(false),
            "scope": .string("bot"),
            "data": data,
            "truncated": .bool(truncated),
            "nextCursor": .null,
        ])
        let text = try encode(value)
        if text.utf8.count > maximumOutputBytes {
            return failure(tool: tool, code: "output_too_large",
                           message: "the result exceeds 256 KiB; narrow the query or read a smaller window",
                           exitCode: 1)
        }
        return BotRecordCommandOutput(stdout: text + "\n", exitCode: 0)
    }

    private static func failure(tool: String, code: String, message: String,
                                exitCode: Int32) -> BotRecordCommandOutput {
        let value = BotJSONValue.object([
            "ok": .bool(false),
            "tool": .string(tool),
            "error": .object(["code": .string(code), "message": .string(message)]),
        ])
        let text = (try? encode(value)) ?? #"{"ok":false,"tool":"record.search","error":{"code":"unavailable","message":"record store is unavailable"}}"#
        return BotRecordCommandOutput(stdout: text + "\n", exitCode: exitCode)
    }

    private static func encode(_ value: BotJSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func code(for error: BotRecordServiceError) -> String {
        switch error {
        case .unclaimedSession: return "unclaimed_session"
        case .sessionOutOfScope: return "session_out_of_scope"
        case .unknownRecord: return "unknown_record"
        case .invalidReference: return "invalid_reference"
        case .invalidQuery: return "invalid_query"
        case .invalidSince: return "invalid_since"
        case .invalidAround: return "invalid_around"
        case .invalidArguments: return "invalid_arguments"
        case .unavailable: return "unavailable"
        }
    }

    private static func message(for error: BotRecordServiceError) -> String {
        switch error {
        case .unclaimedSession:
            return "the calling DSH session is not claimed by this Bot runtime"
        case .sessionOutOfScope:
            return "the requested session does not belong to this Bot"
        case .unknownRecord:
            return "no record exists at that reference"
        case .invalidReference:
            return "the argument is not a canonical record:// reference"
        case .invalidQuery:
            return "the query is invalid"
        case .invalidSince:
            return "--since must be RFC3339 or epoch milliseconds"
        case .invalidAround:
            return "--around must be an integer in 0...20"
        case .invalidArguments:
            return "the record command arguments are invalid"
        case let .unavailable(detail):
            return detail
        }
    }

    private static func exitCode(for error: BotRecordServiceError) -> Int32 {
        switch error {
        case .unclaimedSession, .sessionOutOfScope, .unknownRecord, .unavailable:
            return 1
        case .invalidReference, .invalidQuery, .invalidSince, .invalidAround, .invalidArguments:
            return 2
        }
    }
}
