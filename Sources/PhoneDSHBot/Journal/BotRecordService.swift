// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// How one memory claim was learned. The value is derived from record
/// references, never from the session kind or the model's own wording.
public enum BotRecordTrust: String, Codable, Sendable, Equatable {
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

/// One reference's host-observed state, used by the read/recall
/// `evidence_status` view (spec/bot/v2 §1.5.1). Never persisted.
public struct BotRecordEvidencePoint: Sendable, Equatable {
    public let ref: String
    /// The record's own timestamp. `nil` when it does not resolve, was erased,
    /// or carries no usable time.
    public let observedAtMS: Int64?
    public let recordType: String?
    public let trust: BotRecordTrust?
    public let resolved: Bool
    public let erased: Bool
    /// The version derivable from the record itself (P lane). Kept optional so
    /// existing test doubles and callers that only know existence/time keep
    /// compiling; `BotRecordService` always fills it for real records.
    public let version: BotSourceVersion?

    public init(ref: String, observedAtMS: Int64?, recordType: String?,
                trust: BotRecordTrust?, resolved: Bool, erased: Bool = false,
                version: BotSourceVersion? = nil) {
        self.ref = ref
        self.observedAtMS = observedAtMS
        self.recordType = recordType
        self.trust = trust
        self.resolved = resolved
        self.erased = erased
        self.version = version
    }
}

/// One batched resolve result for a read/recall call: all references are
/// resolved from a single event-log scan and one session-log read per session.
public struct BotRecordEvidenceSnapshot: Sendable, Equatable {
    public let points: [String: BotRecordEvidencePoint]

    public init(points: [String: BotRecordEvidencePoint]) {
        self.points = points
    }

    public func point(for reference: String) -> BotRecordEvidencePoint? {
        points[reference] ?? BotRecordReference.canonicalize(reference).flatMap { points[$0] }
    }
}

public enum BotRecordServiceError: Error, Sendable, Equatable {
    case unclaimedSession
    case sessionOutOfScope
    case unknownRecord
    case erasedRecord
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
    /// One batched resolve per read/recall call (spec/bot/v2 §1.5.1).
    func evidenceSnapshot(for references: [String], callerBotID: String,
                          callerSessionID: String) async throws -> BotRecordEvidenceSnapshot
}

public extension BotRecordEvidenceResolving {
    /// Deterministic fallback for simple test doubles: resolve each reference
    /// on its own. `BotRecordService` overrides it with one event-log scan.
    func evidenceSnapshot(for references: [String], callerBotID: String,
                          callerSessionID: String) async throws -> BotRecordEvidenceSnapshot {
        var points: [String: BotRecordEvidencePoint] = [:]
        for raw in references {
            guard let canonical = BotRecordReference.canonicalize(raw),
                  points[canonical] == nil else { continue }
            do {
                let evidence = try await resolveEvidence(
                    [canonical], callerBotID: callerBotID, callerSessionID: callerSessionID)
                points[canonical] = BotRecordEvidencePoint(
                    ref: canonical, observedAtMS: nil, recordType: nil,
                    trust: evidence.trust, resolved: true)
            } catch BotRecordServiceError.erasedRecord {
                points[canonical] = BotRecordEvidencePoint(
                    ref: canonical, observedAtMS: nil, recordType: nil,
                    trust: nil, resolved: false, erased: true)
            } catch {
                points[canonical] = BotRecordEvidencePoint(
                    ref: canonical, observedAtMS: nil, recordType: nil,
                    trust: nil, resolved: false)
            }
        }
        return BotRecordEvidenceSnapshot(points: points)
    }
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
public actor BotRecordService: BotRecordEvidenceResolving, BotSourceStateResolving {
    public static let maximumHits = 20
    public static let maximumAround = 20
    public static let maximumQueryScalars = 200
    public static let maximumEvidence = 8
    /// 50 recall hits × 8 evidence refs is the frozen upper bound; the batch is
    /// counted over distinct canonical references.
    public static let maximumBatchEvidence = 512
    /// G-3 durable context observation carrier. Kept as the frozen string here
    /// so the journal does not depend on the context-source module.
    static let contextObservedType = "context.observed"
    public static let maximumRawBytes = 16 * 1024
    public static let maximumOutputBytes = 256 * 1024

    private struct EventRecord {
        var event: BotEvent
        var raw: String
        var searchable: String
    }

    private let store: SQLiteDomainStore
    private let gateway: BotGateway
    private let sessionLogLocator: @Sendable (String) -> URL?
    private let now: @Sendable () -> Int64
    /// Optional real file producer (G-1 r5 §4.5). nil means the App has not
    /// wired a VFS→host resolver, so file freshness must stay
    /// `refresh-not-performed`; the resolver never guesses.
    private let fileRechecks: (any BotFileSourceRechecking)?

    /// Identical record calls in one maintenance run were replaying the same
    /// large output at every step. A hit is only reused when the durable event
    /// head and the session-log file stamps are unchanged; otherwise the
    /// normal bounded result is produced again.
    private struct RecentRecordOutput {
        var fingerprint: String
        var total: Int
        var first: String?
        var next: String?
        var totalChars: Int
    }
    private var recentRecordOutputs: [String: RecentRecordOutput] = [:]
    private var recentRecordOrder: [String] = []
    private static let recentRecordLimit = 64

    public init(store: SQLiteDomainStore, gateway: BotGateway, workspaceRoot: URL,
                sessionLogLocator: (@Sendable (String) -> URL?)? = nil,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
                fileRechecks: (any BotFileSourceRechecking)? = nil) {
        self.store = store
        self.gateway = gateway
        self.now = now
        let defaultSessionLogLocator: @Sendable (String) -> URL? = { @Sendable sessionID -> URL? in
            let manager: FileManager = .default
            let sessionsPath = workspaceRoot
                .appendingPathComponent("materialized/home/sessions", isDirectory: true)
                .path
            // DSH writes `<sessions>/<project>/<sessionID>/session.v*.jsonl`;
            // older fixtures and direct callers also use
            // `<sessions>/<sessionID>/session.v*.jsonl`. Try the direct layout
            // first, then one project directory, newest file wins.
            var candidatePaths = [sessionsPath + "/" + sessionID]
            if let projects = try? manager.contentsOfDirectory(atPath: sessionsPath) {
                for project in projects {
                    candidatePaths.append(sessionsPath + "/" + project + "/" + sessionID)
                }
            }
            for directory in candidatePaths {
                guard let names = try? manager.contentsOfDirectory(atPath: directory) else { continue }
                let candidates = names
                    .filter { $0.hasPrefix("session.v") && $0.hasSuffix(".jsonl") }
                    .sorted { lhs, rhs in
                        let left = (try? manager.attributesOfItem(
                            atPath: directory + "/" + lhs)[.modificationDate] as? Date) ?? .distantPast
                        let right = (try? manager.attributesOfItem(
                            atPath: directory + "/" + rhs)[.modificationDate] as? Date) ?? .distantPast
                        return left > right
                    }
                if let newest = candidates.first {
                    return URL(fileURLWithPath: directory).appendingPathComponent(newest)
                }
            }
            return nil
        }
        self.sessionLogLocator = sessionLogLocator ?? defaultSessionLogLocator
        self.fileRechecks = fileRechecks
    }

    // MARK: - Command bridge

    /// Runs `phone record …` argv (without the leading `phone record` words).
    /// The caller session is host-resolved out-of-band; `--session` only filters.
    public nonisolated static func bridge(arguments: [String], callerSessionID: String,
                                          service: BotRecordService) async -> BotRecordCommandOutput {
        await service.execute(arguments: arguments, callerSessionID: callerSessionID)
    }

    private func finish(tool: String, result: EncodedResult,
                        callerSessionID: String, arguments: [String],
                        sessions: [String]) async throws -> BotRecordCommandOutput {
        let key = callerSessionID + "\u{1F}" + arguments.joined(separator: "\u{1F}")
        var stamps: [String] = ["h:\(result.head)"]
        for sessionID in Set(sessions).sorted() {
            guard let url = sessionLogLocator(sessionID),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                stamps.append("\(sessionID):missing")
                continue
            }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            stamps.append("\(sessionID):\(size):\(modified)")
        }
        let fingerprint = stamps.joined(separator: "|")
        if let cached = recentRecordOutputs[key], cached.fingerprint == fingerprint {
            return try Self.cachedOutput(tool: tool, cached: cached)
        }
        let output = try Self.output(
            tool: tool, data: result.value, truncated: result.truncated,
            total: result.total, first: result.first, next: result.next,
            totalChars: result.totalChars)
        recentRecordOutputs[key] = RecentRecordOutput(
            fingerprint: fingerprint, total: result.total, first: result.first,
            next: result.next, totalChars: result.totalChars)
        recentRecordOrder.removeAll { $0 == key }
        recentRecordOrder.append(key)
        while recentRecordOrder.count > Self.recentRecordLimit {
            recentRecordOutputs.removeValue(forKey: recentRecordOrder.removeFirst())
        }
        return output
    }

    private static func cachedOutput(tool: String,
                                     cached: RecentRecordOutput) throws -> BotRecordCommandOutput {
        let value = BotJSONValue.object([
            "ok": .bool(true),
            "tool": .string(tool),
            "cached": .bool(true),
            "duplicate": .bool(true),
            "truncated": .bool(false),
            "total": .number(Double(cached.total)),
            "first": cached.first.map(BotJSONValue.string) ?? .null,
            "next": cached.next.map(BotJSONValue.string) ?? .null,
            "totalChars": .number(Double(cached.totalChars)),
            "data": .object([
                "cached": .bool(true),
                "message": .string("相同查询/读取自上次调用后未变化；请复用上一条工具结果，不再重复展开。"),
                "first": cached.first.map(BotJSONValue.string) ?? .null,
                "next": cached.next.map(BotJSONValue.string) ?? .null,
                "total": .number(Double(cached.total)),
                "totalChars": .number(Double(cached.totalChars)),
            ]),
        ])
        return BotRecordCommandOutput(stdout: try encode(value) + "\n", exitCode: 0)
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
                let sessions = [callerSessionID] + (session.map { [$0] } ?? [])
                return try await finish(tool: "record.search", result: result,
                                        callerSessionID: callerSessionID,
                                        arguments: arguments, sessions: sessions)
            case let .read(reference, around):
                let result = try await read(reference: reference, around: around,
                                            callerSessionID: callerSessionID)
                let sessions: [String]
                if case let .session(sessionID, _)? = BotRecordReference.parse(reference) {
                    sessions = [callerSessionID, sessionID]
                } else {
                    sessions = [callerSessionID]
                }
                return try await finish(tool: "record.read", result: result,
                                        callerSessionID: callerSessionID,
                                        arguments: arguments, sessions: sessions)
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
            var around = 0
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
        var total: Int
        var first: String?
        var next: String?
        var totalChars: Int
        var head: Int
    }

    private struct SearchHit {
        var value: BotJSONValue
        var ref: String
        var key: String
        var time: Int64
        var rank: Int
    }

    /// Default search indexes the readable projection, not a nested tool
    /// result that merely echoed another record. The raw record remains
    /// available through an explicit `read` by ref.
    /// Default search indexes only the outer readable text. Nested
    /// `conversation.tool_result` payloads are never walked recursively: a
    /// record bridge echo is reduced to a short marker, and other payloads
    /// contribute their top-level message text only.
    static func searchProjection(type: String, data: BotJSONValue) -> String {
        if ["conversation.tool_result", "tool/result"].contains(type),
           recordToolOutput(data) != nil {
            return "phone record search output (nested body omitted from default search)"
        }
        var parts: [String] = []
        var total = 0
        func append(_ text: String?) {
            guard let text, !text.isEmpty, total < 8_000 else { return }
            let bounded = String(text.unicodeScalars.prefix(4_000))
            parts.append(bounded)
            total += bounded.unicodeScalars.count
        }
        func appendTextBlocks(_ value: BotJSONValue?) {
            guard let value else { return }
            switch value {
            case let .string(text):
                append(text)
            case let .array(blocks):
                // Canonical text blocks only. Reasoning/thinking blocks are
                // internal and must not become ordinary searchable text.
                for block in blocks {
                    guard let object = block.objectValue,
                          object["type"]?.stringValue == "text" else { continue }
                    append(object["text"]?.stringValue)
                }
            default:
                break
            }
        }
        // Other carriers (context.observed payload, device results, ordinary
        // tool output) used to be searchable. Keep a bounded structured
        // projection, but never walk the record bridge's raw lines/hits and
        // never treat a reasoning/thinking object as final text.
        let skippedStructuredKeys: Set<String> = [
            "raw", "rawOutput", "raw_output", "lines", "hits", "snippet",
            "stream", "usage", "derivation", "source_version", "reasoning",
            "thinking", "arguments",
        ]
        func appendStructured(_ value: BotJSONValue, depth: Int) {
            guard depth < 6, total < 8_000 else { return }
            switch value {
            case let .string(text):
                append(text)
            case let .number(number):
                append(String(number))
            case let .bool(flag):
                append(flag ? "true" : "false")
            case let .array(values):
                values.forEach { appendStructured($0, depth: depth + 1) }
            case let .object(object):
                if let kind = object["type"]?.stringValue,
                   kind == "reasoning" || kind == "thinking" { return }
                for (key, item) in object
                where !skippedStructuredKeys.contains(key) {
                    appendStructured(item, depth: depth + 1)
                }
            case .null:
                break
            }
        }
        // DSH v4 top-level user/message and conversation.user_message data:
        // `data.content` is a canonical block array. Legacy fixtures may use
        // `data.message.content`; accept both, but never walk arbitrary nested
        // JSON into the index.
        if let message = data["message"]?.objectValue {
            appendTextBlocks(message["content"])
            append(message["text"]?.stringValue)
        }
        appendTextBlocks(data["content"])
        append(data["text"]?.stringValue)
        append(data["title"]?.stringValue)
        let explicitTextTypes: Set<String> = [
            "user/message", "conversation.user_message",
            "assistant/message", "conversation.assistant_message",
            "memory.document_written", "memory.document_deleted",
            "session/title", "session/title-llm-request",
            "agent/inbox/spliced",
        ]
        if !explicitTextTypes.contains(type) {
            appendStructured(data, depth: 0)
        }
        if type.hasPrefix("memory.document") {
            append(data["path"]?.stringValue)
            for ref in data["evidence"]?.arrayValue ?? [] { append(ref.stringValue) }
        }
        return parts.joined(separator: " ")
    }

    private static func recordToolOutput(_ data: BotJSONValue) -> String? {
        var found: String?
        func walk(_ value: BotJSONValue, depth: Int) {
            guard found == nil, depth < 8 else { return }
            switch value {
            case let .string(text):
                guard text.count >= 8, text.hasPrefix("{"),
                      let parsed = try? BotJSONValue.parse(Data(text.utf8)) else { return }
                if let tool = parsed["tool"]?.stringValue,
                   ["record.search", "record.read"].contains(tool) {
                    found = tool
                }
            case let .array(values): values.forEach { walk($0, depth: depth + 1) }
            case let .object(object):
                for (_, item) in object { walk(item, depth: depth + 1) }
            case .number, .bool, .null: break
            }
        }
        walk(data, depth: 0)
        return found
    }

    private static func primaryText(type: String, data: BotJSONValue) -> String {
        var parts: [String] = []
        func walk(_ value: BotJSONValue, depth: Int) {
            guard depth < 6, parts.reduce(0, { $0 + $1.count }) < 4_000 else { return }
            switch value {
            case let .string(text):
                if !text.hasPrefix("{") { parts.append(text) }
            case let .array(values): values.forEach { walk($0, depth: depth + 1) }
            case let .object(object):
                for key in ["message", "content", "text", "data"] {
                    if let item = object[key] { walk(item, depth: depth + 1) }
                }
            default: break
            }
        }
        walk(data, depth: 0)
        let text = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? type : text
    }

    /// Original user/message first, then observation/memory, then assistant
    /// final text, then title/tool/index-like secondary carriers.
    static func searchRank(_ type: String) -> Int {
        switch type {
        case "user/message", "conversation.user_message": return 0
        case "memory.document_written", "memory.document_deleted", "context.observed": return 1
        case "assistant/message", "conversation.assistant_message": return 2
        default: return 3
        }
    }

    private static func dedupeType(_ type: String) -> String {
        switch type {
        case "conversation.tool_result", "tool/result": return "tool-result"
        case "conversation.user_message", "user/message": return "user-message"
        case "conversation.assistant_message", "assistant/message": return "assistant-message"
        default: return type
        }
    }

    private static func dedupeKey(type: String, time: Int64, data: BotJSONValue) -> String {
        let normalized = dedupeType(type)
        return "\(normalized)|\(time)|\(primaryText(type: normalized, data: data))"
    }

    private static func excerpt(_ text: String, needle: String) -> String {
        let value = snippet(text, needle: needle)
        if value.unicodeScalars.count <= 240 { return value }
        let end = value.unicodeScalars.index(value.unicodeScalars.startIndex, offsetBy: 240)
        return String(String.UnicodeScalarView(value.unicodeScalars[..<end]))
    }

    private static func trustLabel(type: String, data: BotJSONValue) -> String? {
        switch type {
        case "conversation.user_message", "user/message":
            return "user"
        case "conversation.assistant_message", "assistant/message":
            return "assistant"
        case "conversation.tool_result", "tool/result", "context.observed":
            return "observation"
        case "memory.document_written", "memory.document_deleted":
            return data["trust"]?.stringValue
        default:
            return nil
        }
    }

    /// A tool result is an argument to the next model call. Keep every single
    /// search/read bounded so one wide query or a large record cannot grow the
    /// next step without limit; the model gets explicit total/first/next hints.
    public static let maximumReturnedChars = 8_000

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
        var rawHits: [SearchHit] = []
        var total = 0
        for sessionID in sessions {
            guard let lines = try? sessionLines(sessionID: sessionID) else { continue }
            for line in lines {
                let data = Self.sessionData(line.raw)
                let projected = data.map {
                    Self.searchProjection(type: line.type, data: $0)
                } ?? line.searchable
                guard !line.erased,
                      since == nil || line.time >= since!,
                      projected.lowercased().contains(needle) else { continue }
                total += 1
                let ref = "record://session/\(sessionID)#\(line.seq)"
                let key = data.map {
                    Self.dedupeKey(type: line.type, time: line.time, data: $0)
                } ?? "\(line.type)|\(line.time)|\(line.seq)"
                rawHits.append(SearchHit(
                    value: .object([
                        "ref": .string(ref),
                        "record": .string("session"),
                        "sessionId": .string(sessionID),
                        "seq": .number(Double(line.seq)),
                        "type": .string(line.type),
                        "time": .number(Double(line.time)),
                        "snippet": .string(Self.snippet(projected, needle: needle)),
                        "excerpt": .string(Self.excerpt(projected, needle: needle)),
                        "trust": data.flatMap { Self.trustLabel(type: line.type, data: $0) }
                            .map(BotJSONValue.string) ?? .null,
                        "hitTruncated": .bool(projected.unicodeScalars.count > 240),
                    ]),
                    ref: ref, key: key, time: line.time,
                    rank: Self.searchRank(line.type)))
            }
        }
        for record in events where record.event.principal.botId == caller.botId {
            guard !record.event.isErasedPayload,
                  since == nil || record.event.time >= since!,
                  record.searchable.lowercased().contains(needle),
                  let commitSeq = record.event.commitSeq else { continue }
            total += 1
            let ref = "record://event/\(commitSeq)"
            var fields: [String: BotJSONValue] = [
                "ref": .string(ref),
                "record": .string("event"),
                "commitSeq": .number(Double(commitSeq)),
                "type": .string(record.event.type),
                "time": .number(Double(record.event.time)),
                "snippet": .string(Self.snippet(record.searchable, needle: needle)),
                "excerpt": .string(Self.excerpt(record.searchable, needle: needle)),
                "trust": Self.trustLabel(
                    type: record.event.type, data: record.event.data)
                    .map(BotJSONValue.string) ?? .null,
                "hitTruncated": .bool(record.searchable.unicodeScalars.count > 240),
            ]
            if let sessionID = record.event.principal.sessionId {
                fields["sessionId"] = .string(sessionID)
            }
            rawHits.append(SearchHit(
                value: .object(fields), ref: ref,
                key: Self.dedupeKey(type: record.event.type, time: record.event.time,
                                    data: record.event.data),
                time: record.event.time,
                rank: Self.searchRank(record.event.type)))
        }
        rawHits.sort { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.time != rhs.time { return lhs.time > rhs.time }
            return lhs.ref < rhs.ref
        }
        var deduped: [SearchHit] = []
        var keptByKey: [String: Int] = [:]
        for hit in rawHits {
            let key = hit.key.isEmpty ? hit.ref : hit.key
            if let index = keptByKey[key] {
                var object = deduped[index].value.objectValue ?? [:]
                var alsoAt = object["alsoAt"]?.arrayValue ?? []
                alsoAt.append(.string(hit.ref))
                object["alsoAt"] = .array(alsoAt)
                deduped[index].value = .object(object)
            } else {
                keptByKey[key] = deduped.count
                deduped.append(hit)
            }
        }
        let hits = Array(deduped.prefix(Self.maximumHits))
        let nextRef = deduped.count > Self.maximumHits ? deduped[Self.maximumHits].ref : nil
        let firstRef = hits.first?.ref
        let overflow = total > hits.count
        let data = BotJSONValue.object([
            "query": .string(query),
            "since": since.map { BotJSONValue.number(Double($0)) } ?? .null,
            "hits": .array(hits.map(\.value)),
            "total": .number(Double(total)),
            "deduped": .number(Double(deduped.count)),
            "first": firstRef.map(BotJSONValue.string) ?? .null,
            "next": nextRef.map(BotJSONValue.string) ?? .null,
            "truncated": .bool(overflow),
        ])
        return EncodedResult(
            value: data, truncated: overflow, total: total, first: firstRef,
            next: nextRef, totalChars: 0,
            head: events.compactMap(\.event.commitSeq).max() ?? 0)
    }

    private static func sessionData(_ raw: String) -> BotJSONValue? {
        (try? BotJSONValue.parse(Data(raw.utf8)))?["data"]
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
            guard !lines[target].erased else { throw BotRecordServiceError.erasedRecord }
            let start = max(0, target - around)
            let end = min(lines.count - 1, target + around)
            let shadow = lines.compactMap { line -> (BotRecordReference, (start: Int, end: Int))? in
                guard let range = line.surfaceOp?.range, range ~= seq else { return nil }
                return (.session(sessionID: sessionID, seq: line.seq), (range.lowerBound, range.upperBound))
            }.last
            var encoded: [BotJSONValue] = []
            let windowCount = end - start + 1
            let lineBudget = max(512, (Self.maximumReturnedChars - 1_800) / windowCount)
            var totalChars = 0
            for index in start...end {
                let line = lines[index]
                totalChars += line.raw.unicodeScalars.count
                var fields: [String: BotJSONValue] = [
                    "ref": .string("record://session/\(sessionID)#\(line.seq)"),
                    "record": .string("session"),
                    "sessionId": .string(sessionID),
                    "seq": .number(Double(line.seq)),
                    "type": .string(line.type),
                    "time": .number(Double(line.time)),
                ]
                let (rawText, truncated) = Self.boundedRaw(line.raw, maxChars: lineBudget)
                fields["raw"] = .string(rawText)
                fields["truncated"] = .bool(truncated)
                if line.erased { fields["erased"] = .bool(true) }
                if let range = line.surfaceOp?.range {
                    fields["replaces"] = .object([
                        "startRef": .string("record://session/\(sessionID)#\(range.lowerBound)"),
                        "endRef": .string("record://session/\(sessionID)#\(range.upperBound)"),
                    ])
                } else if let shadow, line.seq == seq, index == target {
                    fields["shadowedBy"] = .string(shadow.0.canonical)
                }
                encoded.append(.object(fields))
            }
            let firstRef = "record://session/\(sessionID)#\(lines[start].seq)"
            let nextRef = end + 1 < lines.count
                ? "record://session/\(sessionID)#\(lines[end + 1].seq)" : nil
            let truncated = encoded.contains { $0["truncated"]?.boolValue == true }
            return EncodedResult(value: .object([
                "ref": .string(reference.canonical),
                "lines": .array(encoded),
                "totalChars": .number(Double(totalChars)),
                "first": .string(firstRef),
                "next": nextRef.map(BotJSONValue.string) ?? .null,
                "truncated": .bool(truncated),
            ]), truncated: truncated, total: encoded.count, first: firstRef,
               next: nextRef, totalChars: totalChars,
               head: events.compactMap(\.event.commitSeq).max() ?? 0)
        case let .event(commitSeq):
            guard let record = events.first(where: { $0.event.commitSeq == commitSeq }) else {
                throw BotRecordServiceError.unknownRecord
            }
            guard record.event.principal.botId == caller.botId else {
                throw BotRecordServiceError.sessionOutOfScope
            }
            guard !record.event.isErasedPayload else {
                throw BotRecordServiceError.erasedRecord
            }
            let totalChars = record.raw.unicodeScalars.count
            let (rawText, truncated) = Self.boundedRaw(
                record.raw, maxChars: max(512, Self.maximumReturnedChars - 1_500))
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
                "totalChars": .number(Double(totalChars)),
                "first": .string(reference.canonical),
                "next": .null,
                "truncated": .bool(truncated),
            ]), truncated: truncated, total: 1, first: reference.canonical,
               next: nil, totalChars: totalChars,
               head: events.compactMap(\.event.commitSeq).max() ?? 0)
        }
    }

    // MARK: - Evidence

    public func resolveEvidence(_ references: [String], callerBotID: String,
                                callerSessionID: String) async throws -> BotRecordEvidence {
        guard references.count <= Self.maximumEvidence else {
            throw BotRecordServiceError.invalidArguments
        }
        var canonical: [String] = []
        for raw in references {
            guard let reference = BotRecordReference.parse(raw) else {
                throw BotRecordServiceError.invalidReference
            }
            canonical.append(reference.canonical)
        }
        let snapshot = try await evidenceSnapshot(
            for: canonical, callerBotID: callerBotID, callerSessionID: callerSessionID)
        var trust = BotRecordTrust.assistant
        for ref in canonical {
            guard let point = snapshot.points[ref] else {
                throw BotRecordServiceError.unknownRecord
            }
            if point.erased { throw BotRecordServiceError.erasedRecord }
            // Existence is the only hard requirement. A record whose trust
            // cannot be inferred keeps the pre-existing `assistant` aggregate;
            // it must not turn a formerly legal reference into an error.
            guard point.resolved else {
                throw BotRecordServiceError.unknownRecord
            }
            if let pointTrust = point.trust {
                trust = merge(trust, pointTrust)
            }
        }
        return BotRecordEvidence(trust: trust, refs: canonical)
    }

    /// One batched resolve for a read/recall call (spec/bot/v2 §1.5.1): a
    /// single event-log scan and at most one session-log read per session.
    /// Invalid, foreign or erased references come back as unresolved/erased
    /// points instead of throwing, because `evidence_status` is a display view.
    public func evidenceSnapshot(for references: [String], callerBotID: String,
                                 callerSessionID: String) async throws -> BotRecordEvidenceSnapshot {
        let records = try await resolveRecords(
            references, callerBotID: callerBotID, callerSessionID: callerSessionID)
        var points: [String: BotRecordEvidencePoint] = [:]
        for record in records {
            // Invalid input is reported by `sourceStates`; the display view has
            // always skipped it, and that shape stays unchanged.
            guard BotRecordReference.parse(record.ref) != nil else { continue }
            guard points[record.ref] == nil else { continue }
            points[record.ref] = BotRecordEvidencePoint(
                ref: record.ref,
                observedAtMS: record.observedAtMS,
                recordType: record.recordType,
                trust: record.trust,
                resolved: record.resolved,
                erased: record.erased,
                version: record.version)
        }
        return BotRecordEvidenceSnapshot(points: points)
    }

    /// Per-reference facts and the version derivable from the record itself
    /// (P lane). This is the resolver L/M/R can reuse; it does not decide live
    /// vs stale — that is the provenance read model's single authority.
    public func sourceStates(for references: [String], callerBotID: String,
                             callerSessionID: String) async throws -> [BotSourceState] {
        let records = try await resolveRecords(
            references, callerBotID: callerBotID, callerSessionID: callerSessionID)
        return records.map(Self.sourceState(from:))
    }

    /// G-1 r20: only the frozen observation carriers may carry the grant id,
    /// at the event data root (`conversation.tool_result`) or flat data
    /// (`context.observed`). Old writers omit it and old readers ignore it.
    static func carrierGrantId(type: String, data: BotJSONValue) -> String? {
        guard type == "conversation.tool_result" || type == "context.observed" else {
            return nil
        }
        guard let value = data["grant_id"]?.stringValue,
              !value.isEmpty, value.unicodeScalars.count <= 128 else {
            return nil
        }
        return value
    }

    private static func sourceState(from record: ResolvedRecord) -> BotSourceState {
        BotSourceState(
            ref: record.ref,
            resolved: record.resolved,
            erased: record.erased,
            observedAtMS: record.observedAtMS,
            recordType: record.recordType,
            trust: record.trust,
            version: record.version,
            grantId: record.grantId)
    }

    /// Real file recheck for a provenance resource. Returns nil when the App
    /// did not configure the producer; the read model then reports
    /// `refresh-not-performed` rather than claiming the source is fresh.
    public func recheckFile(_ resource: BotFileResourceIdentity, botID: String,
                            baseline: BotFileBaseline?) async -> BotFileRecheckResult? {
        guard let fileRechecks else { return nil }
        return await fileRechecks.recheck(resource, botID: botID, baseline: baseline)
    }

    /// One batched resolve shared by `evidenceSnapshot` and `sourceStates`:
    /// a single event-log scan and at most one session-log read per session.
    /// Distinct references are capped at the frozen recall batch bound.
    private struct ResolvedRecord {
        var ref: String
        var resolved: Bool
        var erased: Bool
        var observedAtMS: Int64?
        var recordType: String?
        var trust: BotRecordTrust?
        /// Version for observations only; non-observation records legally have
        /// no source version (G-1 §2.2) and unresolved/erased records are
        /// explained by the provenance state, not by an invented digest.
        var version: BotSourceVersion?
        /// Real authorization grant captured at observation time (G-1 r20).
        var grantId: String? = nil
    }

    private func resolveRecords(_ references: [String], callerBotID: String,
                                callerSessionID: String) async throws -> [ResolvedRecord] {
        // The read/recall batch can legitimately carry 50 hits × 8 evidence
        // refs (the frozen RecallMemory upper bound), so the cap is on distinct
        // canonical references and comfortably covers that ceiling.
        var unique: [String] = []
        var seen = Set<String>()
        for raw in references {
            let canonical = BotRecordReference.canonicalize(raw) ?? raw
            guard seen.insert(canonical).inserted else { continue }
            unique.append(canonical)
        }
        guard unique.count <= Self.maximumBatchEvidence else {
            throw BotRecordServiceError.invalidArguments
        }
        let caller = try await principal(for: callerSessionID, botID: callerBotID)
        let events = try await allEvents()
        let owned = ownedSessions(botID: caller.botId, callerSessionID: callerSessionID, events: events)
        let calls = toolCalls(events)
        var eventsByCommit: [Int: EventRecord] = [:]
        for record in events {
            guard let commitSeq = record.event.commitSeq else { continue }
            if eventsByCommit[commitSeq] == nil { eventsByCommit[commitSeq] = record }
        }
        var linesBySession: [String: [BotSessionLogLine]] = [:]
        var result: [ResolvedRecord] = []
        for canonical in unique {
            guard let reference = BotRecordReference.parse(canonical) else {
                result.append(ResolvedRecord(
                    ref: canonical, resolved: false, erased: false,
                    observedAtMS: nil, recordType: nil, trust: nil))
                continue
            }
            switch reference {
            case let .session(sessionID, seq):
                guard owned.contains(sessionID) else {
                    result.append(ResolvedRecord(
                        ref: canonical, resolved: false, erased: false,
                        observedAtMS: nil, recordType: nil, trust: nil))
                    continue
                }
                if linesBySession[sessionID] == nil {
                    linesBySession[sessionID] = (try? sessionLines(sessionID: sessionID)) ?? []
                }
                guard let line = linesBySession[sessionID]?.first(where: { $0.seq == seq }) else {
                    result.append(ResolvedRecord(
                        ref: canonical, resolved: false, erased: false,
                        observedAtMS: nil, recordType: nil, trust: nil))
                    continue
                }
                if line.erased {
                    // G-1: an erased record is still *resolved* (the record
                    // exists); erased is a separate state. The tombstone keeps
                    // the original time but not the original type/trust.
                    result.append(ResolvedRecord(
                        ref: canonical, resolved: true, erased: true,
                        observedAtMS: Self.usableTime(line.time),
                        recordType: nil, trust: nil))
                    continue
                }
                let observed = Self.usableTime(line.time)
                let trust = inferredTrust(for: line, sessionID: sessionID, calls: calls)
                result.append(ResolvedRecord(
                    ref: canonical, resolved: true, erased: false,
                    observedAtMS: observed,
                    recordType: line.type,
                    trust: trust,
                    version: Self.observationVersion(
                        ref: canonical, trust: trust,
                        text: Self.observationText(inSessionLine: line.raw),
                        observedAtMS: observed),
                    grantId: Self.carrierGrantId(type: line.type, data: Self.sessionData(line.raw) ?? .object([:]))))
            case let .event(commitSeq):
                guard let record = eventsByCommit[commitSeq],
                      record.event.principal.botId == caller.botId else {
                    result.append(ResolvedRecord(
                        ref: canonical, resolved: false, erased: false,
                        observedAtMS: nil, recordType: nil, trust: nil))
                    continue
                }
                result.append(Self.eventRecord(
                    ref: canonical, record: record, calls: calls))
            }
        }
        return result
    }

    /// Event facts shared by the session-authorized batch and L's owner-only
    /// event retry (context observations have no DSH session).
    private static func eventRecord(ref: String, record: EventRecord,
                                    calls: [String: [String: String]]) -> ResolvedRecord {
        let event = record.event
        let carrierGrantId = event.data["grant_id"]?.stringValue
        if event.isErasedPayload {
            return ResolvedRecord(
                ref: ref, resolved: true, erased: true,
                observedAtMS: Self.usableTime(event.time),
                recordType: event.type, trust: nil, grantId: carrierGrantId)
        }
        let isContext = event.type == Self.contextObservedType
        let contextObserved = event.data["observed_at_ms"]?.intValue.map { Int64($0) }
        let observed = isContext
            ? (contextObserved ?? Self.usableTime(event.time))
            : Self.usableTime(event.time)
        let trust = Self.inferredTrust(
            for: event, calls: calls, sessionID: event.principal.sessionId)
        let version: BotSourceVersion?
        if isContext {
            version = Self.contextObservationVersion(
                from: event, ref: ref, observedAtMS: observed)
        } else {
            version = Self.observationVersion(
                ref: ref, trust: trust,
                text: Self.observationText(in: event),
                observedAtMS: observed,
                normalizeWebText: Self.isWebObservationEvent(event))
        }
        return ResolvedRecord(
            ref: ref, resolved: true, erased: false,
            observedAtMS: observed, recordType: event.type,
            trust: trust, version: version,
            grantId: Self.carrierGrantId(type: event.type, data: event.data))
    }

    /// Event-only facts for a Bot, used by L when the carrier has no DSH
    /// session (for example `context.observed`). Session refs are ignored here;
    /// they still require the claimed caller session.
    private func eventStates(for references: [String], botID: String) async -> [BotSourceState] {
        guard !references.isEmpty else { return [] }
        var unique: [String] = []
        var seen = Set<String>()
        for raw in references {
            guard let parsed = BotRecordReference.parse(raw),
                  case .event = parsed else { continue }
            let canonical = parsed.canonical
            guard seen.insert(canonical).inserted else { continue }
            unique.append(canonical)
        }
        guard !unique.isEmpty, unique.count <= Self.maximumBatchEvidence else { return [] }
        guard let events = try? await allEvents() else { return [] }
        let calls = toolCalls(events)
        var byCommit: [Int: EventRecord] = [:]
        for record in events {
            guard let sequence = record.event.commitSeq, byCommit[sequence] == nil else { continue }
            byCommit[sequence] = record
        }
        var result: [BotSourceState] = []
        for canonical in unique {
            guard let parsed = BotRecordReference.parse(canonical),
                  let sequence = parsed.commitSeq else { continue }
            if let record = byCommit[sequence],
               record.event.principal.botId == botID {
                result.append(Self.sourceState(
                    from: Self.eventRecord(ref: canonical, record: record, calls: calls)))
            } else {
                result.append(BotSourceState(
                    ref: canonical, resolved: false, erased: false,
                    observedAtMS: nil, recordType: nil, trust: nil, version: nil))
            }
        }
        return result
    }

    /// G-1 §2.1: `content-sha256` is computed over the source's readable text,
    /// UTF-8 bytes. It is only attached to observations; user messages, Bot
    /// output and review assertions legally carry no source version.
    static func observationVersion(ref: String, trust: BotRecordTrust?,
                                   text: String?, observedAtMS: Int64?,
                                   normalizeWebText: Bool = false) -> BotSourceVersion? {
        guard trust == .observation else { return nil }
        guard var text, !text.isEmpty else {
            return .unknown(.recordWithoutContent)
        }
        if normalizeWebText {
            text = text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .unknown(.recordWithoutContent) }
        }
        let digest = SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return .known(BotKnownSourceVersion(
            kind: .contentSHA256,
            value: "sha256:" + digest,
            observedAtMS: observedAtMS,
            basisRef: ref,
            subject: .recordText))
    }

    /// One text block per `data.message.content` entry, joined with newlines.
    /// A Worker-generated observation envelope wraps the source text; the
    /// digest is over the envelope body, not the XML header.
    static func observationText(inSessionLine raw: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(
                with: Data(raw.utf8)) as? [String: Any],
              let data = object["data"] as? [String: Any],
              let message = data["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return nil }
        let text = content.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n")
        return normalizedObservationText(text)
    }

    static func observationText(in event: BotEvent) -> String? {
        if event.type == "conversation.tool_result" {
            let content = event.data["message"]?["content"]?.arrayValue ?? []
            let text = content.compactMap { block -> String? in
                guard block["type"]?.stringValue == "text" else { return nil }
                return block["text"]?.stringValue
            }.joined(separator: "\n")
            return normalizedObservationText(text)
        }
        if event.type == "comm.inbound" {
            return normalizedObservationText(event.data["text"]?.stringValue ?? "")
        }
        if event.type == DeviceTaskResultOutbox.recordEventType,
           let result = event.data["deviceTaskResult"]?.stringValue {
            return normalizedObservationText(result)
        }
        return nil
    }

    /// G-1 §4.5.1 web/connector text normalization. Only web/connector
    /// observations use it; file bytes and other record-text hashes stay
    /// unchanged.
    static func isWebObservationEvent(_ event: BotEvent) -> Bool {
        if event.type == Self.contextObservedType,
           let kind = event.data["resource"]?["kind"]?.stringValue {
            return kind == "web-url" || kind == "connector-resource"
        }
        guard event.type == "conversation.tool_result" else { return false }
        let content = event.data["message"]?["content"]?.arrayValue ?? []
        for block in content where block["type"]?.stringValue == "text" {
            if let text = block["text"]?.stringValue,
               let envelope = BotObservationEnvelope.decode(text) {
                return envelope.source == "web" || envelope.source == "connector"
            }
        }
        return false
    }

    /// True when a tool result carries a complete Worker observation envelope
    /// in one of its text blocks. The envelope is structural (v1 §4.3), so it
    /// can stand in for a missing durable `conversation.tool_call` record.
    static func hasObservationEnvelope(in event: BotEvent) -> Bool {
        guard event.type == "conversation.tool_result" else { return false }
        let content = event.data["message"]?["content"]?.arrayValue ?? []
        for block in content where block["type"]?.stringValue == "text" {
            if let text = block["text"]?.stringValue,
               BotObservationEnvelope.decode(text) != nil {
                return true
            }
        }
        return false
    }

    /// G-3 `context.observed` carries a flat `source_version` (known or
    /// unknown). P reads that structured member instead of inventing a digest;
    /// an absent member is an explicit `source-unversioned`.
    static func contextObservationVersion(from event: BotEvent, ref: String,
                                          observedAtMS: Int64?) -> BotSourceVersion {
        guard let object = event.data["source_version"]?.objectValue else {
            return .unknown(.sourceUnversioned)
        }
        if let raw = object["reason"]?.stringValue,
           let reason = BotSourceVersionUnknownReason(rawValue: raw) {
            return .unknown(reason)
        }
        guard let basisRaw = object["basis"]?.stringValue,
              let basis = BotSourceVersionKind(rawValue: basisRaw),
              let value = object["value"]?.stringValue, !value.isEmpty else {
            return .unknown(.sourceUnversioned)
        }
        let versionObserved = object["observed_at_ms"]?.intValue.map { Int64($0) }
        let basisRef = object["basis_ref"]?.stringValue
        let subject = object["subject"]?.stringValue.flatMap(BotSourceVersionSubject.init)
            ?? (basis == .contentSHA256 ? .recordText : nil)
        return .known(BotKnownSourceVersion(
            kind: basis, value: value,
            observedAtMS: versionObserved ?? observedAtMS,
            basisRef: basisRef ?? ref,
            subject: subject))
    }

    private static func normalizedObservationText(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        if let envelope = BotObservationEnvelope.decode(text) {
            return envelope.text.isEmpty ? nil : envelope.text
        }
        return text
    }

    /// A record timestamp is only an observation time when it is positive; 0
    /// and negative values are "no time" (unknown), never a fake epoch.
    private static func usableTime(_ time: Int64) -> Int64? {
        time > 0 ? time : nil
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

    /// Session ids this Bot owns for record/erasure purposes: the caller plus
    /// every session mentioned by a durable event. The session-epoch eraser
    /// uses the same set, so `phone record` and erasure cannot disagree about
    /// which logs belong to the Bot.
    public func ownedSessionIDs(botID: String, callerSessionID: String) async throws -> [String] {
        let events = try await allEvents()
        return ownedSessions(botID: botID, callerSessionID: callerSessionID, events: events)
            .sorted()
    }

    private func ownedSessions(botID: String, callerSessionID: String,
                               events: [EventRecord]) -> Set<String> {
        var sessions: Set<String> = callerSessionID.isEmpty ? [] : [callerSessionID]
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

    private func inferredTrust(for line: BotSessionLogLine, sessionID: String,
                       calls: [String: [String: String]]) -> BotRecordTrust? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.raw.utf8)) as? [String: Any],
              let data = object["data"] as? [String: Any] else { return nil }
        switch line.type {
        case "user/message":
            let source = data["source"] as? [String: Any]
            guard source?["kind"] as? String == "user",
                  Self.isUserRPC(source?["rpcId"] as? String) else { return .assistant }
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

    private static func inferredTrust(
        for event: BotEvent, calls: [String: [String: String]], sessionID: String?
    ) -> BotRecordTrust? {
        switch event.type {
        case "conversation.user_message":
            let source = event.data["source"]
            guard source?["kind"]?.stringValue == "user",
                  Self.isUserRPC(source?["rpcId"]?.stringValue) else { return .assistant }
            return .user
        case "conversation.tool_call":
            let name = event.data["name"]?.stringValue ?? ""
            let arguments = event.data["arguments"]?.stringValue
            return BotRecordService.externalTool(name, arguments: arguments) ? .observation : .assistant
        case "conversation.tool_result":
            let callID = event.data["message"]?["toolCallId"]?.stringValue
                ?? event.data["callId"]?.stringValue
            if let callID, let sessionID, let name = calls[sessionID]?[callID] {
                return BotRecordService.externalTool(name, arguments: nil) ? .observation : .assistant
            }
            return BotRecordService.hasObservationEnvelope(in: event) ? .observation : .assistant
        case BotRecordService.contextObservedType:
            return .observation
        default:
            if event.type == DeviceTaskResultOutbox.recordEventType,
               case let .object(data) = event.data,
               data["deviceTaskResult"] != nil {
                return .observation
            }
            return .assistant
        }
    }

    private func merge(_ lhs: BotRecordTrust, _ rhs: BotRecordTrust) -> BotRecordTrust {
        let order: [BotRecordTrust: Int] = [.assistant: 0, .observation: 1, .user: 2]
        return (order[lhs] ?? 0) >= (order[rhs] ?? 0) ? lhs : rhs
    }

    private static func isUserRPC(_ rpcID: String?) -> Bool {
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

    /// Full canonical readable text of one record for the maintenance
    /// document-vs-evidence check. Unlike the command output this is not
    /// 8k-bounded; it is never persisted or logged.
    func canonicalRecordText(_ raw: String, callerSessionID: String) async throws -> String {
        guard let reference = BotRecordReference.parse(raw) else {
            throw BotRecordServiceError.invalidReference
        }
        let caller = try await principal(for: callerSessionID, botID: nil)
        let events = try await allEvents()
        let owned = ownedSessions(
            botID: caller.botId, callerSessionID: callerSessionID, events: events)
        let recordRaw: String
        switch reference {
        case let .session(sessionID, seq):
            guard owned.contains(sessionID) else {
                throw BotRecordServiceError.sessionOutOfScope
            }
            guard let lines = try? sessionLines(sessionID: sessionID),
                  let line = lines.first(where: { $0.seq == seq }) else {
                throw BotRecordServiceError.unknownRecord
            }
            guard !line.erased else { throw BotRecordServiceError.erasedRecord }
            recordRaw = line.raw
        case let .event(commitSeq):
            guard let record = events.first(where: { $0.event.commitSeq == commitSeq }) else {
                throw BotRecordServiceError.unknownRecord
            }
            guard record.event.principal.botId == caller.botId else {
                throw BotRecordServiceError.sessionOutOfScope
            }
            guard !record.event.isErasedPayload else {
                throw BotRecordServiceError.erasedRecord
            }
            recordRaw = record.raw
        }
        return BotMemoryMaintenanceText.readableText(raw: recordRaw)
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
                                           searchable: Self.searchProjection(
                                               type: event.type, data: event.data)))
            }
            guard let last = page.last?.commitSeq else { break }
            cursor = last
            if page.count < 500 { break }
        }
        return records
    }

    private func sessionLines(sessionID: String) throws -> [BotSessionLogLine] {
        guard let url = sessionLogLocator(sessionID),
              let data = try? Data(contentsOf: url) else {
            throw BotRecordServiceError.unknownRecord
        }
        return BotSessionLogReader.lines(from: data)
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

    private static func boundedRaw(_ raw: String, maxChars: Int) -> (String, Bool) {
        let scalars = raw.unicodeScalars
        guard scalars.count > maxChars else { return (raw, false) }
        let end = scalars.index(scalars.startIndex, offsetBy: maxChars)
        return (String(String.UnicodeScalarView(scalars[..<end])), true)
    }

    // MARK: - Envelopes

    private static func output(tool: String, data: BotJSONValue,
                               truncated: Bool, total: Int = 0,
                               first: String? = nil, next: String? = nil,
                               totalChars: Int = 0) throws -> BotRecordCommandOutput {
        var value = BotJSONValue.object([
            "ok": .bool(true),
            "tool": .string(tool),
            "egress": .bool(false),
            "scope": .string("bot"),
            "data": data,
            "truncated": .bool(truncated),
            "total": .number(Double(total)),
            "first": first.map(BotJSONValue.string) ?? .null,
            "next": next.map(BotJSONValue.string) ?? .null,
            "totalChars": .number(Double(totalChars)),
            "nextCursor": .null,
        ])
        if case var .object(object) = value {
            if var dataObject = object["data"]?.objectValue {
                dataObject["truncated"] = .bool(truncated)
                dataObject["total"] = .number(Double(total))
                dataObject["first"] = first.map(BotJSONValue.string) ?? .null
                dataObject["next"] = next.map(BotJSONValue.string) ?? .null
                if tool == "record.read" {
                    dataObject["totalChars"] = .number(Double(totalChars))
                }
                object["data"] = .object(dataObject)
                value = .object(object)
            }
        }
        var text = try encode(value)
        if text.unicodeScalars.count > maximumReturnedChars {
            let compact = BotJSONValue.object([
                "ok": .bool(true),
                "tool": .string(tool),
                "egress": .bool(false),
                "scope": .string("bot"),
                "truncated": .bool(true),
                "total": .number(Double(total)),
                "first": first.map(BotJSONValue.string) ?? .null,
                "next": next.map(BotJSONValue.string) ?? .null,
                "totalChars": .number(Double(totalChars)),
                "data": .object([
                    "truncated": .bool(true),
                    "total": .number(Double(total)),
                    "first": first.map(BotJSONValue.string) ?? .null,
                    "next": next.map(BotJSONValue.string) ?? .null,
                    "totalChars": .number(Double(totalChars)),
                    "message": .string("单次结果超过 8000 字符；已省略正文，请用 first/next 定位或缩小窗口。"),
                ]),
            ])
            text = try encode(compact)
        }
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
        case .erasedRecord: return "record_erased"
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
        case .erasedRecord:
            return "该记录已被抹除"
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
        case .unclaimedSession, .sessionOutOfScope, .unknownRecord, .erasedRecord, .unavailable:
            return 1
        case .invalidReference, .invalidQuery, .invalidSince, .invalidAround, .invalidArguments:
            return 2
        }
    }
}

// MARK: - Provenance fact adapter (G-1 r8, L's `BotProvenanceEvidenceResolving`)

extension BotRecordService: BotProvenanceEvidenceResolving {
    /// Bridges P's record facts to L's provenance read model. P only maps the
    /// facts it owns; identity/latest/current stay L's responsibility.
    public func sourceFacts(for refs: [String], botID: String?, sessionID: String?)
        async -> [String: BotProvenanceSourceFact] {
        guard let botID, !refs.isEmpty else { return [:] }
        let states: [BotSourceState]
        if let sessionID, !sessionID.isEmpty {
            states = (try? await sourceStates(
                for: refs, callerBotID: botID,
                callerSessionID: sessionID)) ?? []
        } else {
            // L retries owner-only groups for carriers without a DSH session
            // (notably context.observed). Only event refs are resolvable here;
            // session refs still require the claimed caller session.
            states = await eventStates(for: refs, botID: botID)
        }
        var result: [String: BotProvenanceSourceFact] = [:]
        for state in states {
            result[state.ref] = BotProvenanceSourceFact(
                resolved: state.resolved,
                erased: state.erased,
                observedAtMS: state.observedAtMS,
                recordType: state.recordType,
                trust: state.trust?.rawValue,
                version: state.version?.provenanceSourceVersion(basisRef: state.ref))
        }
        return result
    }
}

// MARK: - P → L derivation mapping (Plan A)

extension BotSourceVersion {
    /// Maps P's version (including the r13 subject) to L's derivation input.
    /// L still owns the resource identity and fills it in prepareDerivation.
    public func provenanceSourceVersion(basisRef: String? = nil) -> BotProvenanceSourceVersion {
        switch self {
        case let .known(known):
            let subject = known.subject.flatMap {
                BotProvenanceSourceVersionSubject(rawValue: $0.rawValue)
            }
            let basis = BotProvenanceSourceVersion.BotSourceBasis(
                rawValue: known.kind.rawValue) ?? .contentSHA256
            return .known(
                basis: basis,
                value: known.value,
                observedAtMS: known.observedAtMS,
                basisRef: known.basisRef,
                subject: subject)
        case let .unknown(reason):
            let mapped = BotProvenanceSourceVersion.BotSourceUnknownReason(
                rawValue: reason.rawValue) ?? .sourceUnversioned
            return .unknown(reason: mapped, observedAtMS: nil, basisRef: basisRef)
        }
    }
}

extension BotSourceBaseline {
    /// One P baseline as the derivation source L's prepareDerivation accepts.
    /// Role and version are passed through; resource stays nil so L derives it
    /// from the real carrier and fails closed when it cannot.
    public func provenanceSource() -> BotDerivationSource {
        BotDerivationSource(
            record: record,
            role: role.flatMap { BotDerivationRole(rawValue: $0.rawValue) },
            resource: nil,
            sourceVersion: sourceVersion?.provenanceSourceVersion(basisRef: record),
            grantId: grantId)
    }
}

// MARK: - Discoverable tool-result refs (G-2 §245)

extension BotRecordService: BotToolResultRefReading {
    /// Recent successful bash/read result refs for this exact session. The seq
    /// comes from the real tool/result session line; no body is copied and no
    /// cache is used, so the next model step sees a just-appended result.
    public func recentToolResultRefs(botID: String, sessionID: String,
                                     limit: Int) async -> [BotToolResultRef] {
        guard limit > 0,
              (try? await principal(for: sessionID, botID: botID)) != nil,
              let lines = try? sessionLines(sessionID: sessionID) else { return [] }
        struct Call { var name: String; var detail: String? }
        var calls: [String: Call] = [:]
        var result: [BotToolResultRef] = []
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(
                with: Data(line.raw.utf8)) as? [String: Any],
                let data = object["data"] as? [String: Any] else { continue }
            if line.type == "tool/call" {
                let callId = data["callId"] as? String ?? ""
                let name = data["name"] as? String ?? ""
                guard !callId.isEmpty else { continue }
                calls[callId] = Call(name: name, detail: Self.toolResultDetail(
                    tool: name, arguments: data["arguments"]))
                continue
            }
            guard line.type == "tool/result", !line.erased,
                  let message = data["message"] as? [String: Any],
                  message["isError"] as? Bool != true,
                  data["error"] == nil,
                  let callId = message["toolCallId"] as? String,
                  let call = calls[callId],
                  call.name == "bash" || call.name == "read" else { continue }
            let text = Self.toolResultText(message)
            guard !text.isEmpty, !Self.isTruncatedOrRedacted(text) else { continue }
            let ref = "record://session/\(sessionID)#\(line.seq)"
            guard BotRecordReference.parse(ref)?.canonical == ref else { continue }
            result.append(BotToolResultRef(
                record: ref, tool: call.name,
                label: Self.toolResultLabel(tool: call.name, detail: call.detail)))
        }
        return Array(result.suffix(min(limit, 5)))
    }

    private static func toolResultText(_ message: [String: Any]) -> String {
        guard let blocks = message["content"] as? [[String: Any]] else {
            return message["text"] as? String ?? ""
        }
        return blocks.compactMap { block -> String? in
            block["type"] as? String == "text" ? block["text"] as? String : nil
        }.joined(separator: "\n")
    }

    private static func isTruncatedOrRedacted(_ text: String) -> Bool {
        text.contains("[pdsh-redaction") || text.contains("output-truncated")
            || text.contains("\"truncated\":true") || text.contains("reason=output-truncated")
    }

    private static func toolResultDetail(tool: String, arguments: Any?) -> String? {
        var value = arguments
        if let text = arguments as? String,
           let data = text.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) {
            value = parsed
        }
        guard let object = value as? [String: Any] else { return nil }
        if let path = (object["file_path"] as? String) ?? (object["path"] as? String) {
            return path
        }
        if tool == "bash", let command = object["command"] as? String {
            return command
        }
        return nil
    }

    private static func toolResultLabel(tool: String, detail: String?) -> String {
        var label = tool
        if let detail, !detail.isEmpty {
            label += " " + detail
        }
        label = label.replacingOccurrences(of: "\n", with: " ")
        let bounded = String(label.unicodeScalars.prefix(80))
        if bounded.lowercased().contains("token") || bounded.lowercased().contains("password")
            || bounded.lowercased().contains("secret") {
            return tool
        }
        return bounded
    }
}
