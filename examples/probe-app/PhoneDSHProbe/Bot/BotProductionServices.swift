// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSH
import PhoneDSHAgentCore
import PhoneDSHBot
import PhoneDSHEngine
import UniformTypeIdentifiers
#if canImport(ProbeKit)
import ProbeKit
#endif

func botProductionString(_ value: PhoneDSHBot.BotJSONValue?) -> String? {
    guard case .string(let text)? = value else { return nil }
    return text
}

func botProductionInt(_ value: PhoneDSHBot.BotJSONValue?) -> Int? {
    guard case .number(let number)? = value, number.isFinite, number.rounded() == number else { return nil }
    return Int(exactly: number)
}

func botProductionNowMilliseconds() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1_000)
}

enum BotProductionError: LocalizedError {
    case brainUnavailable
    case invalidService(String)

    var errorDescription: String? {
        switch self {
        case .brainUnavailable: return "Bot 大脑 planner 尚未接入，消息和审批动作未执行。"
        case .invalidService(let message): return message
        }
    }
}

protocol BotProductionTurnStopping: Actor {
    func stopCurrentTurn(turnID: String?) async throws
}

actor BotProductionUnavailablePlanner: BotUserActionPlanning {
    func plan(_ action: BotUserAction, trust: BotUserActionTrust) async throws -> BotUserActionPlanOutcome {
        .rejected(reason: BotProductionError.brainUnavailable.localizedDescription)
    }
}

struct BotProductionContext: Equatable, Sendable {
    var botID: String
    var botName: String
}

struct BotProductionRuntimeContext: Sendable {
    let botID: String
    /// The profile name of this Bot. It is the fallback after the last
    /// `renamed` system event, so a new Bot is not shown as the legacy name.
    let fallbackName: String

    func current(domain: SQLiteDomainStore) async throws -> BotProductionContext {
        let name = try await legacyName(domain: domain) ?? fallbackName
        return BotProductionContext(botID: botID, botName: name)
    }

    /// The name from the last `renamed` system event, or nil when the Bot was
    /// never renamed. Bootstrap uses this to decide `name_explicit`.
    func legacyName(domain: SQLiteDomainStore) async throws -> String? {
        var name: String?
        for event in try await BotProductionEventReader.all(domain: domain) {
            guard event.type == "ui.system_event", event.principal.botId == botID,
                  botProductionString(event.data["event"]) == "renamed",
                  let candidate = botProductionString(event.data["botName"])?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty else { continue }
            name = candidate
        }
        return name
    }
}

struct BotProductionComposition {
    let sessionID: String
    let planner: any BotUserActionPlanning
    var turnStopping: (any BotProductionTurnStopping)? = nil
}

/// The single production authority for one Bot's durable dependencies.
///
/// `BotMCPRuntime` owns exactly one `RoutineMachine` and one `BotMemory`; the
/// composition root creates those once and injects them here. No second
/// routine store or memory-fact wrapper is constructed for the UI path.
actor BotProductionEnvironment {
    let botID: String
    private(set) var sessionID: String
    /// Cached log URL for `sessionID`. It is refreshed on `connect` and on an
    /// S6 epoch switch; the row service still re-validates it against the
    /// session id so a stale cache can never keep the chat on the archived
    /// epoch.
    private(set) var sessionLogURL: URL?
    let domain: SQLiteDomainStore
    let routineMachine: RoutineMachine
    let memory: BotMemory
    let grants: BotGrantStore
    /// The workspace root this runtime actually uses. The session-log locator
    /// must scan this tree, never the process-global App Documents default:
    /// the BotE2E composition injects a temporary root and a global scan would
    /// silently miss every log written there.
    let workspaceRoot: URL
    let runtimeContext: BotProductionRuntimeContext
    private var planner: any BotUserActionPlanning
    private var turnStopping: (any BotProductionTurnStopping)?
    private var routineCanceller: (@Sendable (String) async -> RoutineCancellationResult)?

    init(domain: SQLiteDomainStore, botID: String, sessionID: String,
         routineMachine: RoutineMachine, memory: BotMemory,
         grants: BotGrantStore,
         planner: (any BotUserActionPlanning)? = nil,
         turnStopping: (any BotProductionTurnStopping)? = nil,
         sessionLogURL: URL? = nil,
         workspaceRoot: URL = BotProductionPaths.workspaceRoot(),
         fallbackName: String = "大肥鱼") {
        self.botID = botID
        self.sessionID = sessionID
        self.sessionLogURL = sessionLogURL
        self.workspaceRoot = workspaceRoot
        self.domain = domain
        self.routineMachine = routineMachine
        self.memory = memory
        self.grants = grants
        self.runtimeContext = BotProductionRuntimeContext(botID: botID, fallbackName: fallbackName)
        self.planner = planner ?? BotProductionUnavailablePlanner()
        self.turnStopping = turnStopping
    }

    func connect(_ composition: BotProductionComposition) throws {
        guard !composition.sessionID.isEmpty else {
            throw BotProductionError.invalidService("Bot 主会话 ID 不能为空")
        }
        sessionID = composition.sessionID
        sessionLogURL = BotSessionLogLocator.latestFile(
            sessionID: composition.sessionID, workspaceRoot: workspaceRoot)
        planner = composition.planner
        turnStopping = composition.turnStopping
    }

    func context() async throws -> BotProductionContext {
        try await runtimeContext.current(domain: domain)
    }

    func legacyName() async throws -> String? {
        try await runtimeContext.legacyName(domain: domain)
    }

    /// Advances the durable main-session pointer after an epoch switch. The
    /// planner and turn-stopping seams stay bound; the session id and the log
    /// URL the row/record services read both move to the new epoch. The row
    /// service still re-validates the cached URL on every rebuild.
    func updateSessionID(_ sessionID: String) {
        self.sessionID = sessionID
        sessionLogURL = BotSessionLogLocator.latestFile(
            sessionID: sessionID, workspaceRoot: workspaceRoot)
    }

    /// One read of the current epoch and its log. A cached URL that belongs to
    /// the replaced session is ignored; the resolver falls back to the current
    /// session's newest `session.v*.jsonl`.
    func sessionSnapshot() -> (sessionID: String, logURL: URL?) {
        (sessionID, BotSessionLogSelection.logURL(
            sessionID: sessionID, explicit: sessionLogURL,
            latest: { BotSessionLogLocator.latestFile(sessionID: $0, workspaceRoot: workspaceRoot) }))
    }

    func currentPlanner() -> any BotUserActionPlanning { planner }
    func currentTurnStopping() -> (any BotProductionTurnStopping)? { turnStopping }

    func setRoutineCanceller(
        _ canceller: (@Sendable (String) async -> RoutineCancellationResult)?
    ) {
        routineCanceller = canceller
    }

    func cancelRoutine(_ routineID: String) async -> RoutineCancellationResult {
        guard let routineCanceller else {
            return RoutineCancellationResult(cancelled: false, reason: "routine canceller is not configured")
        }
        return await routineCanceller(routineID)
    }
}

enum BotProductionEventReader {
    static func all(domain: SQLiteDomainStore) async throws -> [BotEvent] {
        var result: [BotEvent] = []
        var cursor = 0
        while true {
            let page = try await domain.events(after: cursor, limit: 500)
            guard !page.isEmpty else { return result }
            result.append(contentsOf: page)
            cursor = page.last?.commitSeq ?? cursor
            if page.count < 500 { return result }
        }
    }
}

enum BotProductionPaths {
    static func workspaceRoot() -> URL {
        #if canImport(ProbeKit)
        return ChatHostConfiguration.workspaceRoot()
        #else
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chat-host", isDirectory: true)
        #endif
    }
}

enum BotSessionLogLocator {
    /// Newest `session.v*.jsonl` for `sessionID` under the **owning**
    /// workspace root. Callers pass the same root their composition was built
    /// with; there is deliberately no process-global fallback.
    static func latestFile(sessionID: String, workspaceRoot: URL) -> URL? {
        let root = workspaceRoot
            .appendingPathComponent("materialized/home/sessions", isDirectory: true)
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var candidates: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("session.v"), url.pathExtension == "jsonl",
                  url.deletingLastPathComponent().lastPathComponent == sessionID,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { continue }
            candidates.append((url, values.contentModificationDate ?? .distantPast))
        }
        return candidates.sorted { $0.modified > $1.modified }.first?.url
    }

    static func events(sessionID: String, workspaceRoot: URL) throws -> [BotDSHSessionEvent] {
        guard let url = latestFile(sessionID: sessionID, workspaceRoot: workspaceRoot) else { return [] }
        return BotDSHSessionEvent.parseJSONL(try Data(contentsOf: url)).events
    }
}

// MARK: - Incremental watch feed

/// Health of the Bot page's incremental watch feed.
///
/// A transient read failure never throws out of `BotProductionRowService.watch`:
/// the loop keeps the last good projection and reports `.degraded` until the
/// next successful poll. `reason` is a stable diagnostic token, never user copy;
/// the page maps `.degraded` to its own "实时更新中断，正在重连" line.
enum BotProductionWatchHealth: Equatable, Sendable {
    case healthy
    case degraded(reason: String, since: Int64)

    var isDegraded: Bool {
        if case .degraded = self { return true }
        return false
    }

    var reason: String? {
        guard case .degraded(let reason, _) = self else { return nil }
        return reason
    }

    var since: Int64? {
        guard case .degraded(_, let since) = self else { return nil }
        return since
    }

    /// The log token: `ok` or `degraded:<reason>`.
    var verdict: String {
        guard let reason else { return "ok" }
        return "degraded:\(reason)"
    }
}

/// One `bot-watch` poll line. Every field is O(1) to produce; the whole
/// transcript is never materialized to print it.
struct BotProductionWatchPoll: Equatable, Sendable {
    var milliseconds: Int
    var sessionBytes: UInt64
    var newLines: Int
    var events: Int
    var rows: Int
    var cursor: Int
    var verdict: String

    var logLine: String {
        "bot-watch ms=\(milliseconds) sessionBytes=\(sessionBytes) newLines=\(newLines)"
            + " events=\(events) rows=\(rows) cursor=\(cursor) verdict=\(verdict)"
    }
}

/// File metadata only. Reading an unchanged file must not open it at all, so
/// the incremental tail checks this before it touches any bytes.
struct BotSessionLogFileState: Equatable, Sendable {
    var size: UInt64
    var modified: Date
    /// The inode/file system number; a different value means the path now
    /// names a different file (rotation/replacement).
    var fileNumber: UInt64?
}

/// Byte source seam for the session-log tail. The production implementation is
/// `BotSessionLogFileIO`; tests inject a counter/failure wrapper.
protocol BotSessionLogReading: Sendable {
    func state(at url: URL) throws -> BotSessionLogFileState?
    func read(at url: URL, offset: UInt64, maxBytes: Int) throws -> Data
}

extension BotSessionLogReading {
    func readHead(at url: URL, maxBytes: Int) throws -> Data {
        try read(at: url, offset: 0, maxBytes: maxBytes)
    }
}

struct BotSessionLogFileIO: BotSessionLogReading {
    static let live = BotSessionLogFileIO()

    func state(at url: URL) throws -> BotSessionLogFileState? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return nil }
        let attributes = try manager.attributesOfItem(atPath: url.path)
        return BotSessionLogFileState(
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modified: attributes[.modificationDate] as? Date ?? .distantPast,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    func read(at url: URL, offset: UInt64, maxBytes: Int) throws -> Data {
        guard maxBytes > 0 else { return Data() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: maxBytes) ?? Data()
    }
}

/// Append-only cache for one session JSONL file.
///
/// Each entry keeps the stat identity, a prefix fingerprint, the byte offset it
/// has consumed, the bytes of a torn final line (never parsed until the newline
/// arrives), the parsed events and their diagnostics. A poll that sees the same
/// size, mtime and inode reads nothing at all; a poll after an append reads only
/// the appended bytes. A shrink, a replaced inode, a different prefix
/// fingerprint or a missing entry re-parses the file from byte 0.
struct BotSessionLogTail: Sendable {
    struct Entry: Sendable {
        var size: UInt64
        var modified: Date
        var fileNumber: UInt64?
        var fingerprint: Data
        /// Bytes handed to the parser so far (all of them are complete lines
        /// except `pending`, which is not yet newline-terminated).
        var offset: UInt64
        var pending: Data
        var events: [BotDSHSessionEvent]
        var skipped: [BotDSHSessionLogSkippedRecord]
        /// Complete lines consumed, used for physical line numbers.
        var lineCount: Int
        /// True once the first non-empty record was seen. The session header
        /// is only ever skipped on that record, including across a cold empty
        /// file whose first bytes arrive on a later poll.
        var firstRecordSeen: Bool
        /// Raw records for `BotTurnProcessProjector`; only the current log
        /// needs them. `nil` means this epoch was parsed events-only.
        var records: [JSONValue]?
    }

    struct Refresh: Sendable {
        var url: URL?
        var events: [BotDSHSessionEvent]
        var diagnostics: BotDSHSessionLogDiagnostics
        var records: [JSONValue]
        /// Complete lines parsed by this refresh (all of them after a re-parse).
        var newLines: Int
        var size: UInt64
        var reparsed: Bool

        static let empty = Refresh(
            url: nil, events: [], diagnostics: .empty, records: [],
            newLines: 0, size: 0, reparsed: false)
    }

    enum Failure: Error, Equatable {
        /// A cached path disappeared. The caller keeps the last good
        /// projection and reports degraded instead of wiping the chat.
        case unavailable
    }

    static let fingerprintBytes = 1_024
    static let chunkBytes = 4 << 20

    let io: any BotSessionLogReading
    private(set) var entries: [URL: Entry] = [:]

    init(io: any BotSessionLogReading = BotSessionLogFileIO.live) {
        self.io = io
    }

    func size(of url: URL) -> UInt64? { entries[url]?.size }

    mutating func reset(_ url: URL? = nil) {
        if let url { entries[url] = nil } else { entries.removeAll() }
    }

    mutating func refresh(_ url: URL, needRecords: Bool) throws -> Refresh {
        guard let state = try io.state(at: url) else {
            // A cached file that vanished is a read race, not an empty session:
            // keep the last good projection and let the caller retry.
            if entries[url] != nil { throw Failure.unavailable }
            return Refresh.empty
        }

        let cached = entries[url]
        var fullReparse = cached == nil
        var fingerprint = cached?.fingerprint

        if let cached {
            let identityChanged = cached.size != state.size
                || cached.modified != state.modified
                || cached.fileNumber != state.fileNumber
            let recordsReady = !needRecords || cached.records != nil
            if !identityChanged, recordsReady {
                // Size + mtime + inode identical: zero byte reads. Only the
                // metadata is refreshed so a later touch is not missed.
                var entry = cached
                entry.size = state.size
                entry.modified = state.modified
                entry.fileNumber = state.fileNumber
                entries[url] = entry
                return Refresh(
                    url: url, events: entry.events,
                    diagnostics: BotDSHSessionLogDiagnostics(skipped: entry.skipped),
                    records: entry.records ?? [], newLines: 0, size: entry.size,
                    reparsed: false)
            }

            if !recordsReady || state.size < cached.offset || state.size < cached.size {
                fullReparse = true
            } else if let cachedNumber = cached.fileNumber,
                      let current = state.fileNumber, cachedNumber != current {
                fullReparse = true
            } else {
                // The metadata moved: verify the prefix before trusting an
                // append. A replaced file whose prefix differs is re-parsed.
                let head = try io.readHead(at: url, maxBytes: Self.fingerprintBytes)
                let comparable = Data(head.prefix(cached.fingerprint.count))
                if comparable != cached.fingerprint {
                    fullReparse = true
                } else {
                    // Grow the cached fingerprint when the file outgrew it;
                    // an empty file must not keep an empty fingerprint.
                    fingerprint = head
                }
            }
        }

        if fullReparse {
            let data = try readAll(at: url, upTo: state.size)
            let parsed = Self.parse(data, firstLineNumber: 1, skipHeader: true,
                                    needRecords: needRecords)
            let entry = Entry(
                size: UInt64(data.count), modified: state.modified,
                fileNumber: state.fileNumber,
                fingerprint: Data(data.prefix(Self.fingerprintBytes)),
                offset: UInt64(data.count), pending: parsed.pending,
                events: parsed.events, skipped: parsed.skipped,
                lineCount: parsed.lines,
                firstRecordSeen: parsed.firstRecordSeen,
                records: needRecords ? parsed.records : nil)
            entries[url] = entry
            return Refresh(
                url: url, events: entry.events,
                diagnostics: BotDSHSessionLogDiagnostics(skipped: entry.skipped),
                records: entry.records ?? [], newLines: parsed.lines,
                size: entry.size, reparsed: true)
        }

        guard var entry = cached else { return Refresh.empty }
        var appended = Data()
        while entry.offset < state.size {
            let want = Int(min(state.size - entry.offset, UInt64(Self.chunkBytes)))
            let chunk = try io.read(at: url, offset: entry.offset, maxBytes: want)
            guard !chunk.isEmpty else { break }
            appended.append(chunk)
            entry.offset += UInt64(chunk.count)
        }
        let parsed = Self.parse(
            entry.pending + appended, firstLineNumber: entry.lineCount + 1,
            skipHeader: !entry.firstRecordSeen, needRecords: needRecords)
        entry.events.append(contentsOf: parsed.events)
        entry.skipped.append(contentsOf: parsed.skipped)
        entry.lineCount += parsed.lines
        entry.firstRecordSeen = entry.firstRecordSeen || parsed.firstRecordSeen
        if needRecords {
            entry.records = (entry.records ?? []) + parsed.records
        }
        entry.pending = parsed.pending
        // A short read leaves the entry behind the observed size on purpose:
        // the next poll then sees `size > offset` and retries the rest instead
        // of taking the no-op path.
        entry.size = entry.offset
        entry.modified = state.modified
        entry.fileNumber = state.fileNumber
        if let fingerprint { entry.fingerprint = fingerprint }
        entries[url] = entry
        return Refresh(
            url: url, events: entry.events,
            diagnostics: BotDSHSessionLogDiagnostics(skipped: entry.skipped),
            records: entry.records ?? [], newLines: parsed.lines,
            size: entry.size, reparsed: false)
    }

    private func readAll(at url: URL, upTo size: UInt64) throws -> Data {
        guard size > 0 else { return Data() }
        var data = Data()
        while UInt64(data.count) < size {
            let want = Int(min(size - UInt64(data.count), UInt64(Self.chunkBytes)))
            let chunk = try io.read(at: url, offset: UInt64(data.count), maxBytes: want)
            guard !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return data
    }

    private struct Parsed {
        var events: [BotDSHSessionEvent] = []
        var skipped: [BotDSHSessionLogSkippedRecord] = []
        var records: [JSONValue] = []
        var pending = Data()
        var lines = 0
        var firstRecordSeen = false
    }

    private struct SessionHeaderProbe: Decodable {
        var type: String
        var version: Int
    }

    /// Parses the newline-terminated prefix of `data` with exactly the
    /// `BotDSHSessionEvent.parseJSONL` rules (header on the first record of the
    /// file, unparseable records skipped and numbered by physical line). The
    /// unterminated tail is returned as `pending` and is never parsed twice.
    private static func parse(_ data: Data, firstLineNumber: Int, skipHeader: Bool,
                              needRecords: Bool) -> Parsed {
        var parsed = Parsed()
        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            parsed.pending = data
            return parsed
        }
        parsed.pending = Data(data[data.index(after: lastNewline)...])
        let complete = data[data.startIndex...lastNewline]
        let decoder = JSONDecoder()
        // `complete` ends with the newline, so its split has one phantom empty
        // element; the remaining elements are the physical lines.
        let lines = complete.split(separator: 0x0A, omittingEmptySubsequences: false)
            .dropLast()
        var lineNumber = firstLineNumber
        var firstRecord = skipHeader
        for line in lines {
            defer { lineNumber += 1 }
            let trimmed = line.drop(while: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D })
            guard !trimmed.isEmpty else { continue }
            let record = Data(trimmed)
            parsed.firstRecordSeen = true
            if firstRecord {
                firstRecord = false
                if let header = try? decoder.decode(SessionHeaderProbe.self, from: record),
                   header.type == "session", header.version == 4 {
                    if needRecords, let value = try? JSONValue.parse(record) {
                        parsed.records.append(value)
                    }
                    continue
                }
            }
            do {
                parsed.events.append(try decoder.decode(BotDSHSessionEvent.self, from: record))
            } catch {
                parsed.skipped.append(BotDSHSessionLogSkippedRecord(
                    lineNumber: lineNumber, seq: skippedSeq(in: record)))
            }
            if needRecords, let value = try? JSONValue.parse(record) {
                parsed.records.append(value)
            }
        }
        parsed.lines = lines.count
        return parsed
    }

    private static func skippedSeq(in record: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: record) as? [String: Any],
              let number = object["seq"] as? NSNumber else { return nil }
        return number.intValue
    }
}

struct BotProductionHistoryPage: Sendable, Equatable {
    var rows: [BotRow]
    var nextCursor: String?
    var hasMore: Bool
}

/// Loads the main-chat epoch chain from durable `runtime.started` events. Each
/// entry keeps its physical session id; the row projector stitches them in
/// first-start order so an epoch switch does not make the old conversation
/// disappear. A repeated `runtime.started` for the same id is deduplicated.
///
/// The polling path never re-reads the journal: the caller keeps the durable
/// `uiEvents` in memory and passes the already-parsed current epoch events.
enum BotProductionSessionEpochs {
    /// Epoch order, oldest first, from the durable `runtime.started` chain.
    /// The current main session is always present exactly once.
    static func orderedSessionIDs(botID: String, currentSessionID: String,
                                  uiEvents: [BotEvent]) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        for event in uiEvents where event.type == "runtime.started"
            && event.principal.botId == botID
            && event.principal.kind == BotSessionKind.chat.rawValue {
            guard let sessionID = event.data["sessionId"]?.stringValue
                ?? event.principal.sessionId, !sessionID.isEmpty else { continue }
            if seen.insert(sessionID).inserted { ordered.append(sessionID) }
        }
        if seen.insert(currentSessionID).inserted { ordered.append(currentSessionID) }
        return ordered
    }

    /// Builds the projections from already-cached parsed epochs. Archived
    /// epochs come from the incremental tail cache (a stat-only hit once read);
    /// an unreadable archived log stays out of the chain exactly like the old
    /// `try? Data(contentsOf:)` path instead of failing the current poll.
    static func load(ordered: [String], currentSessionID: String,
                     logURLs: [String: URL],
                     logTail: inout BotSessionLogTail,
                     currentEvents: [BotDSHSessionEvent]) -> [BotSessionEpochProjection] {
        var epochs: [BotSessionEpochProjection] = []
        for sessionID in ordered {
            let events: [BotDSHSessionEvent]
            if sessionID == currentSessionID {
                events = currentEvents
            } else if let url = logURLs[sessionID] {
                events = (try? logTail.refresh(url, needRecords: false).events) ?? []
            } else {
                events = []
            }
            if sessionID != currentSessionID && events.isEmpty { continue }
            epochs.append(BotSessionEpochProjection(sessionID: sessionID, events: events))
        }
        if epochs.isEmpty {
            epochs.append(BotSessionEpochProjection(sessionID: currentSessionID, events: []))
        }
        return epochs
    }
}

/// Reads the same durable rows the production Bot page renders. One instance
/// belongs to the composition root; the UI passes its driver around instead of
/// constructing another projection authority.
///
/// Polling is incremental. The session log is read only from its last consumed
/// byte, the durable event journal only after its last `commitSeq`, and both
/// caches are keyed by the inputs that can invalidate them. `rebuild()` stays
/// the full-projection entry point for `start()` and epoch changes; it re-uses
/// the same caches, so a start followed by a poll does not re-read them.
actor BotProductionRowService {
    private let environment: BotProductionEnvironment
    private let history: BotRowHistory
    private let remote: BotDSHRemoteRuntime?
    private var dispatcher: BotUserActionDispatcher?
    private var plannerIdentity: ObjectIdentifier?
    private var started = false
    private var currentPresentation = BotRuntimePresentation()
    /// Tool steps per turn, re-projected only after the session log grew.
    private var processes: [Int: BotTurnProcess] = [:]
    private var processLogURL: URL?
    private var liveGeneration = 0
    /// Read-only evidence of session-log records the last refresh skipped.
    private(set) var sessionLogDiagnostics = BotDSHSessionLogDiagnostics.empty

    // MARK: Incremental watch state

    private var logTail: BotSessionLogTail
    private var uiEvents: [BotEvent] = []
    private var uiEventCursor = 0
    private var epochStartCount = 0
    private var epochs: [BotSessionEpochProjection] = []
    private var epochsSessionID: String?
    private var epochsStartCount = 0
    private var epochLogURLs: [String: URL] = [:]
    private var health = BotProductionWatchHealth.healthy
    private var failureCount = 0
    private var retryNotBefore = Date.distantPast
    private var lastPoll: BotProductionWatchPoll?
    private var lastPollSessionBytes: UInt64 = 0
    private var lastPollEventCount = 0

    static let uiEventPageSize = 500
    /// Short retry ladder for transient read failures. It never changes the
    /// caller's 800 ms cadence; it only skips the expensive read after a
    /// failure instead of hammering a file the Worker is rewriting.
    static let degradedBackoff: [TimeInterval] = [0.25, 0.5, 1, 2]

    init(environment: BotProductionEnvironment, history: BotRowHistory = BotRowHistory(),
         remote: BotDSHRemoteRuntime? = nil,
         logIO: any BotSessionLogReading = BotSessionLogFileIO.live) {
        self.environment = environment
        self.history = history
        self.remote = remote
        self.logTail = BotSessionLogTail(io: logIO)
    }

    func start() async throws {
        guard !started else { return }
        try await rebuild()
        await updateDispatcher()
        started = true
    }

    private func updateDispatcher() async {
        let planner = await environment.currentPlanner()
        let identity = ObjectIdentifier(planner)
        guard identity != plannerIdentity else { return }
        plannerIdentity = identity
        dispatcher = BotUserActionDispatcher(store: environment.domain, planner: planner)
    }

    /// Full projection entry point for `start()` and history reads. The reads
    /// stay incremental: a cache whose identity key matches is not re-read.
    private func rebuild() async throws {
        let inputs = try await collectInputs()
        try await project(inputs)
    }

    /// The stage that failed, used as the `.degraded` reason token. The
    /// underlying error text stays out of the log line.
    private struct WatchStepFailure: Error {
        var stage: String
    }

    /// One consistent set of projection inputs. Every field is already parsed
    /// and cached; building this does not re-read an unchanged transcript.
    private struct WatchInputs {
        var sessionID: String
        var logURL: URL?
        var log: BotSessionLogTail.Refresh
        var uiEvents: [BotEvent]
        var epochs: [BotSessionEpochProjection]
        var heldRequestNonces: [String: String]
        /// No input changed since the last successful projection. The poll can
        /// return the (empty) row batch without re-projecting anything.
        var unchanged: Bool
    }

    private func collectInputs() async throws -> WatchInputs {
        let snapshot = await environment.sessionSnapshot()
        let sessionID = snapshot.sessionID
        let logURL = snapshot.logURL

        let log: BotSessionLogTail.Refresh
        do {
            if let logURL {
                log = try logTail.refresh(logURL, needRecords: true)
            } else {
                log = .empty
                processLogURL = nil
                processes = [:]
            }
        } catch {
            throw WatchStepFailure(stage: "session-log")
        }

        let epochChanged = epochsSessionID != nil && epochsSessionID != sessionID
        let appended: Int
        do {
            appended = try await pollUIEvents(forceFull: epochChanged)
        } catch {
            throw WatchStepFailure(stage: "ui-events")
        }

        let ordered = BotProductionSessionEpochs.orderedSessionIDs(
            botID: environment.botID, currentSessionID: sessionID,
            uiEvents: uiEvents)
        var epochsRebuilt = false
        if epochs.isEmpty || epochChanged || epochStartCount != epochsStartCount
            || !epochs.contains(where: { $0.sessionID == sessionID }) {
            let urls = resolveEpochLogURLs(
                ordered: ordered, currentSessionID: sessionID, currentLogURL: logURL)
            epochs = BotProductionSessionEpochs.load(
                ordered: ordered, currentSessionID: sessionID, logURLs: urls,
                logTail: &logTail, currentEvents: log.events)
            epochLogURLs.merge(urls) { _, new in new }
            epochsSessionID = sessionID
            epochsStartCount = epochStartCount
            epochsRebuilt = true
            // A log whose epoch left the chain only takes memory.
            let orderedSet = Set(ordered)
            for stale in epochLogURLs.keys.filter({ !orderedSet.contains($0) }) {
                if let url = epochLogURLs.removeValue(forKey: stale) {
                    logTail.reset(url)
                }
            }
        } else if let index = epochs.firstIndex(where: { $0.sessionID == sessionID }) {
            epochs[index].events = log.events
        }

        let heldRequestNonces = await remote?.heldChatActionNonces(sessionID: sessionID) ?? [:]
        let unchanged = appended == 0 && !epochsRebuilt && !epochChanged
            && log.newLines == 0 && !log.reparsed
        return WatchInputs(sessionID: sessionID, logURL: logURL, log: log,
                           uiEvents: uiEvents, epochs: epochs,
                           heldRequestNonces: heldRequestNonces,
                           unchanged: unchanged)
    }

    private func project(_ inputs: WatchInputs) async throws {
        do {
            _ = try await history.rebuild(
                botID: environment.botID, epochs: inputs.epochs,
                uiEvents: inputs.uiEvents,
                heldRequestNonces: inputs.heldRequestNonces)
        } catch {
            throw WatchStepFailure(stage: "projection")
        }
        sessionLogDiagnostics = inputs.log.diagnostics
        updateProcesses(inputs.log, url: inputs.logURL)
        currentPresentation = BotRuntimePresentationFactory.make(
            botID: environment.botID, sessionID: inputs.sessionID,
            sessionEvents: inputs.log.events, uiEvents: inputs.uiEvents)
    }

    /// Appends only the events committed after the cached `commitSeq`. A
    /// journal that moves backwards is a reset, so its cache is rebuilt once.
    /// Returns how many events were appended (a reset reports at least one).
    private func pollUIEvents(forceFull: Bool) async throws -> Int {
        var appended = 0
        var didReset = forceFull
        if forceFull { resetUICache() }
        var pages = 0
        while true {
            let page = try await environment.domain.events(
                after: uiEventCursor, limit: Self.uiEventPageSize)
            guard !page.isEmpty else { return didReset ? max(appended, 1) : appended }
            if uiEventCursor > 0,
               let firstSeq = page.first?.commitSeq, firstSeq <= uiEventCursor {
                resetUICache()
                didReset = true
                pages += 1
                if pages > 8 { return max(appended, 1) }
                continue
            }
            uiEvents.append(contentsOf: page)
            appended += page.count
            if let last = page.last?.commitSeq, last > uiEventCursor {
                uiEventCursor = last
            }
            epochStartCount += page.reduce(0) {
                $0 + (Self.isEpochStart($1, botID: environment.botID) ? 1 : 0)
            }
            if page.count < Self.uiEventPageSize {
                return didReset ? max(appended, 1) : appended
            }
            pages += 1
            if pages > 10_000 { return max(appended, 1) }
        }
    }

    private func resetUICache() {
        uiEvents.removeAll(keepingCapacity: true)
        uiEventCursor = 0
        epochStartCount = 0
    }

    private static func isEpochStart(_ event: BotEvent, botID: String) -> Bool {
        event.type == "runtime.started"
            && event.principal.botId == botID
            && event.principal.kind == BotSessionKind.chat.rawValue
    }

    private func resolveEpochLogURLs(ordered: [String], currentSessionID: String,
                                     currentLogURL: URL?) -> [String: URL] {
        var urls: [String: URL] = [:]
        for sessionID in ordered {
            if sessionID == currentSessionID, let currentLogURL {
                urls[sessionID] = currentLogURL
                continue
            }
            if let cached = epochLogURLs[sessionID] {
                urls[sessionID] = cached
                continue
            }
            if let url = BotSessionLogLocator.latestFile(
                sessionID: sessionID, workspaceRoot: environment.workspaceRoot) {
                urls[sessionID] = url
            }
        }
        return urls
    }

    private func updateProcesses(_ log: BotSessionLogTail.Refresh, url: URL?) {
        guard url != nil else { return }
        guard processLogURL != url || log.newLines > 0 || log.reparsed else { return }
        processLogURL = url
        processes = BotTurnProcessProjector.make(records: log.records)
    }

    func turnProcesses() -> [Int: BotTurnProcess] { processes }

    /// Live frames of the visible main-chat turn. One subscriber at a time;
    /// a newer subscription replaces an older one, and only the current one
    /// detaches the observer when it ends.
    func liveFrames() -> AsyncStream<BotLiveTurnFrame> {
        liveGeneration += 1
        let generation = liveGeneration
        let (stream, continuation) = AsyncStream<BotLiveTurnFrame>.makeStream(bufferingPolicy: .bufferingNewest(512))
        guard let remote else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.endLive(generation: generation) }
        }
        Task { await remote.setLiveObserver { frame in continuation.yield(frame) } }
        return stream
    }

    private func endLive(generation: Int) async {
        guard generation == liveGeneration else { return }
        await remote?.setLiveObserver(nil)
    }

    func presentation() async throws -> BotRuntimePresentation {
        try await start()
        return currentPresentation
    }

    /// The 800 ms poll. An I/O race never throws out of here: a failed read
    /// keeps the last good projection, records `.degraded` and returns an empty
    /// non-reset batch with the caller's cursor; the next successful poll
    /// restores `.healthy`.
    func watch(after cursor: Int) async throws -> BotRowBatch {
        let startedAt = Date()
        if health.isDegraded, Date() < retryNotBefore {
            let rows = await history.history().count
            await recordPoll(startedAt: startedAt, newLines: 0,
                             events: lastPollEventCount, cursor: cursor,
                             verdict: health.verdict, bytes: lastPollSessionBytes,
                             rows: rows)
            return BotRowBatch(rows: [], deletes: [], cursor: cursor, reset: false)
        }
        do {
            let inputs = try await collectInputs()
            if !inputs.unchanged {
                try await project(inputs)
            }
            markHealthy()
            let batch = await history.watch(after: cursor)
            let rows = await history.history().count
            await recordPoll(startedAt: startedAt, newLines: inputs.log.newLines,
                             events: inputs.log.events.count, cursor: batch.cursor,
                             verdict: "ok", bytes: inputs.log.size, rows: rows)
            return batch
        } catch {
            markDegraded(error)
            let rows = await history.history().count
            await recordPoll(startedAt: startedAt, newLines: 0,
                             events: lastPollEventCount, cursor: cursor,
                             verdict: health.verdict, bytes: lastPollSessionBytes,
                             rows: rows)
            return BotRowBatch(rows: [], deletes: [], cursor: cursor, reset: false)
        }
    }

    /// Current health of the incremental watch feed. Phase 2's supervised loop
    /// and the page's reconnect line read this; no user copy is built here.
    func watchHealth() -> BotProductionWatchHealth { health }

    /// The last completed poll. Same numbers as the emitted `bot-watch` line.
    func lastWatchPoll() -> BotProductionWatchPoll? { lastPoll }

    private func markHealthy() {
        health = .healthy
        failureCount = 0
        retryNotBefore = .distantPast
    }

    private func markDegraded(_ error: Error) {
        let stage = (error as? WatchStepFailure)?.stage ?? "unknown"
        if case .degraded(_, let since) = health {
            health = .degraded(reason: stage, since: since)
        } else {
            health = .degraded(reason: stage, since: botProductionNowMilliseconds())
        }
        failureCount += 1
        let index = min(failureCount, Self.degradedBackoff.count) - 1
        retryNotBefore = Date().addingTimeInterval(Self.degradedBackoff[index])
    }

    /// One line per poll on the same `chat-status.log` channel as `perf`. Every
    /// field is O(1); the transcript is never materialized to build the line.
    private func recordPoll(startedAt: Date, newLines: Int, events: Int,
                            cursor: Int, verdict: String, bytes: UInt64,
                            rows: Int) async {
        let poll = BotProductionWatchPoll(
            milliseconds: Int(max(0, Date().timeIntervalSince(startedAt)) * 1_000),
            sessionBytes: bytes, newLines: newLines, events: events, rows: rows,
            cursor: cursor, verdict: verdict)
        lastPoll = poll
        lastPollSessionBytes = bytes
        lastPollEventCount = events
        let line = poll.logLine
        await MainActor.run { BotRebindDiagnostics.emit(line) }
    }

    func history(before rowID: String?, limit: Int) async throws -> BotProductionHistoryPage {
        try await rebuild()
        let rows = await history.history()
        let end = try rowID.map { id in
            guard let index = rows.firstIndex(where: { $0.id == id }) else {
                throw BotProductionError.invalidService("历史行游标不可用")
            }
            return index
        } ?? rows.endIndex
        let eligible = rows[..<end]
        let page = eligible.suffix(max(1, limit))
        return BotProductionHistoryPage(rows: Array(page), nextCursor: page.first?.id,
                                        hasMore: eligible.count > page.count)
    }

    func perform(_ action: BotUserAction) async throws -> BotActionResult {
        try await start()
        await updateDispatcher()
        guard let dispatcher else { return .rejected(reason: BotProductionError.brainUnavailable.localizedDescription) }
        return try await dispatcher.dispatch(action)
    }

    func stopCurrentTurn(turnID: String?) async throws {
        guard let stopping = await environment.currentTurnStopping() else {
            throw BotProductionError.brainUnavailable
        }
        try await stopping.stopCurrentTurn(turnID: turnID)
    }
}

struct BotProductionApproval: Sendable, Equatable, Identifiable {
    var id: String
    /// Human-readable action + operation labels; never an id or digest.
    var parameterSummary: String
    var decision: BotGrantDecision
    /// `once` / `session` / `until` for an allow; nil for a deny.
    var scope: String?
    /// `allowed` / `denied` / `timed-out` / `expired` / `cancelled`.
    var status: String?
    /// Durable cancellation/denial reason code (`worker_restarted`, …). The
    /// UI maps it through `BotApprovalReceipt.cancellationReason`; the raw
    /// value never reaches the page.
    var reason: String?
    var decidedAtMS: Int64
}

struct BotProductionGrant: Sendable, Equatable, Identifiable {
    var id: String
    var tool: String
    var operation: String
    var resource: String
    var scope: String
    var sessionID: String?
    var createdAtMS: Int64
    var source: String
}

struct BotProductionReconciliation: Sendable, Equatable, Identifiable {
    var id: String { routineID }
    var routineID: String
    var routineTitle: String
    var attempt: Int
    var runID: String
    var error: String?
    var effectKey: String?
    var effectGeneration: Int?
    var effectAttempt: Int?
    /// Human-readable effect summary for the single reconciliation block.
    var effectSummary: String?
    /// Raw effect record (`operation · target · reason`) for the detail
    /// disclosure; the main row never prints the effect key.
    var effectDetail: String?
}

struct BotProductionMemoryDocument: Sendable {
    var document: PhoneDSHBot.BotMemoryDocument
    var versions: [PhoneDSHBot.BotMemoryDocumentVersion]
}

struct BotProductionInfoSnapshot: Sendable {
    var botName: String
    var memories: [BotProductionMemoryDocument]
    var routines: [Routine]
    var approvals: [BotProductionApproval]
    var grants: [BotProductionGrant]
    var reconciliations: [BotProductionReconciliation]
    var presence: RoutinePresence
    var proactiveSettings: ProactiveSettings
    var maintenance: BotMemoryMaintenanceBatchView?
    var maintenanceEnabled: Bool
    var maintenanceDailyTokens: Int
    var maintenanceDailyBudget: Int
    /// Last failed App identity registration for this runtime, if any. Read
    /// only; the info page renders it as one status line.
    var bridgeStatus: PhoneDSHBot.BotBridgeDiagnostic?
    /// Per-entry failure messages. Each data entry loads independently so a
    /// broken projection only fails its own page. The raw error goes to the
    /// diagnostic log; this string is the human-facing copy.
    var memoryError: String?
    var routinesError: String?
    var approvalsError: String?
    var grantsError: String?
}

/// Read/write view over the same `BotMemory` and `RoutineMachine` the
/// composition root injected; nothing here opens a second fact store.
actor BotProductionInfoService {
    private let environment: BotProductionEnvironment
    private let scheduler: RoutineScheduler?
    private let settingsStore: ProactiveSettingsStore
    private let maintenance: BotMemoryMaintenanceController?
    private let bridgeDiagnostic: (@Sendable () async -> BotBridgeDiagnostic?)?
    private var sessionEraser: BotSessionEraser?

    init(environment: BotProductionEnvironment,
         scheduler: RoutineScheduler? = nil,
         settingsStore: ProactiveSettingsStore = .shared,
         maintenance: BotMemoryMaintenanceController? = nil,
         bridgeDiagnostic: (@Sendable () async -> BotBridgeDiagnostic?)? = nil) {
        self.environment = environment
        self.scheduler = scheduler
        self.settingsStore = settingsStore
        self.maintenance = maintenance
        self.bridgeDiagnostic = bridgeDiagnostic
    }

    /// Installs the session-epoch eraser for this Bot unit. The composition
    /// sets it after the unit exists; memory erase stays unavailable until it
    /// is installed, so production never clears payloads without covering the
    /// closed session logs.
    func setSessionEraser(_ eraser: BotSessionEraser?) {
        sessionEraser = eraser
    }

    func load() async throws -> BotProductionInfoSnapshot {
        let memory = environment.memory
        let machine = environment.routineMachine
        // The page title is profile-driven; a missing runtime context must
        // not take the four data entries down with it.
        let botName = (try? await environment.context().botName) ?? ""
        let humanFailure = "暂时读不出来，请稍后重试。"

        var memories: [BotProductionMemoryDocument] = []
        var memoryError: String?
        do {
            let documents = try await memory.documents(scope: nil)
            for document in documents {
                memories.append(BotProductionMemoryDocument(
                    document: document,
                    versions: try await memory.versions(path: document.path)))
            }
        } catch {
            await logInfoProjectionFailure("memory", error)
            memoryError = humanFailure
        }

        var routines: [Routine] = []
        var routinesError: String?
        do {
            routines = try await machine.list(botId: environment.botID)
        } catch {
            await logInfoProjectionFailure("routines", error)
            routinesError = humanFailure
        }

        var approvals: [BotProductionApproval] = []
        var approvalsError: String?
        do {
            approvals = try await approvalRecords()
        } catch {
            await logInfoProjectionFailure("approvals", error)
            approvalsError = humanFailure
        }

        var grants: [BotProductionGrant] = []
        var grantsError: String?
        do {
            grants = try await standingGrants()
        } catch {
            await logInfoProjectionFailure("grants", error)
            grantsError = humanFailure
        }

        let context = await BotPresenceCenter.shared.context()
        let presence: RoutinePresence
        if let scheduler {
            presence = await scheduler.presenceSnapshot(
                appActive: context.appActive, keepingAlive: context.keepingAlive)
        } else {
            presence = RoutinePresence(
                level: RoutinePresencePolicy.level(
                    appActive: context.appActive, keepingAlive: context.keepingAlive,
                    scheduledNotificationCount: 0))
        }
        var reconciliations: [BotProductionReconciliation] = []
        if routinesError == nil {
            do {
                reconciliations = try await reconciliationRecords(provided: routines)
            } catch {
                await logInfoProjectionFailure("reconciliations", error)
            }
        }
        let maintenanceBatch = try? await maintenance?.lastBatch()
        let maintenanceSettings = await maintenance?.settings()
        let maintenanceEnabled = maintenanceSettings?.enabled ?? false
        let maintenanceBudget = await maintenance?.budgetStatus()
        let bridgeStatus: BotBridgeDiagnostic?
        if let bridgeDiagnostic {
            bridgeStatus = await bridgeDiagnostic()
        } else {
            bridgeStatus = nil
        }
        if let diagnostic = bridgeStatus {
            // The raw failure code belongs to the diagnostic log; the presence
            // line is built from the timestamp only (P09 bot-info §在场状态).
            await MainActor.run {
                BotRebindDiagnostics.emit(
                    "bot-info bridge-failure code=\(diagnostic.code)")
            }
        }
        return BotProductionInfoSnapshot(
            botName: botName, memories: memories, routines: routines, approvals: approvals,
            grants: grants, reconciliations: reconciliations,
            presence: presence, proactiveSettings: settingsStore.settings(),
            maintenance: maintenanceBatch,
            maintenanceEnabled: maintenanceEnabled,
            maintenanceDailyTokens: maintenanceBudget?.dailyTokensUsed ?? 0,
            maintenanceDailyBudget: maintenanceBudget?.dailyTokenLimit ?? 0,
            bridgeStatus: bridgeStatus,
            memoryError: memoryError,
            routinesError: routinesError,
            approvalsError: approvalsError,
            grantsError: grantsError)
    }

    /// The raw projection error belongs in the App diagnostic log. The page
    /// only ever receives the human message above.
    private func logInfoProjectionFailure(_ section: String, _ error: Error) async {
        await MainActor.run {
            BotRebindDiagnostics.emit(
                "bot-info projection=\(section) error=\(String(reflecting: error))")
        }
    }

    /// S3: enable/disable the background maintainer (default off). The switch
    /// is shared by every Bot and persisted under one P18 key.
    func setMaintenanceEnabled(_ enabled: Bool) async {
        if let maintenance {
            await maintenance.setEnabled(enabled)
        } else {
            var settings = BotMemoryMaintenanceSettingsStore.shared.settings()
            settings.enabled = enabled
            BotMemoryMaintenanceSettingsStore.shared.save(settings)
        }
    }

    /// S3: roll one batch back using the S2 restore primitive.
    func rollbackMaintenance(batchID: String) async throws {
        guard let maintenance else {
            throw BotProductionError.invalidService("记忆整理服务未接线")
        }
        let result = try await maintenance.rollback(batchID: batchID)
        guard let result else {
            throw BotProductionError.invalidService("找不到这次整理批次")
        }
        if !result.conflicts.isEmpty {
            throw BotProductionError.invalidService(
                "有 \(result.conflicts.count) 份文档在整理后又被改过，未覆盖")
        }
    }

    /// Standing grants only. A `once` grant is one execution permission, not a
    /// standing authorization, so the information page never shows it.
    func standingGrants() async -> [BotProductionGrant] {
        await environment.grants.list(botId: environment.botID)
            .filter { $0.scope != .once }
            .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
            .map {
                BotProductionGrant(
                    id: $0.id, tool: $0.tool, operation: $0.operation,
                    resource: $0.resource, scope: $0.scope.rawValue,
                    sessionID: $0.sessionId, createdAtMS: $0.createdAt, source: $0.source)
            }
    }

    func revokeGrant(_ id: String) async throws {
        _ = try await environment.grants.revoke(id: id)
    }

    func cancelRoutine(_ routineID: String) async throws {
        let result = await environment.cancelRoutine(routineID)
        guard result.cancelled else {
            throw BotProductionError.invalidService(
                "取消例行任务失败：\(result.reason ?? "routine is not running")")
        }
    }

    /// Every routine that stopped in `needs-reconciliation`, plus the effect
    /// record that produced it when one still exists. The effect is the
    /// "already produced" evidence shown before the user chooses.
    func reconciliationRecords(provided: [Routine]? = nil) async throws -> [BotProductionReconciliation] {
        let routines: [Routine]
        if let provided {
            routines = provided
        } else {
            routines = try await environment.routineMachine.list(botId: environment.botID)
        }
        var records: [BotProductionReconciliation] = []
        for routine in routines {
            guard let state = routine.runState, state.status == .needsReconciliation else { continue }
            let deliveryKey = RoutineDelivery.key(routineId: routine.id, attempt: state.attempt)
            let effectKey = "routine:\(deliveryKey)"
            let effect = try? await environment.domain.effect(effectKey)
            let matching = effect?.state == .needsReconciliation ? effect : nil
            records.append(BotProductionReconciliation(
                routineID: routine.id, routineTitle: routine.title,
                attempt: state.attempt, runID: state.runId,
                error: state.error ?? routine.lastResult?.error,
                effectKey: matching?.effectKey,
                effectGeneration: matching?.generation,
                effectAttempt: matching?.attempt,
                effectSummary: matching.map {
                    BotUIFormat.routineEffectSummary(
                        operation: $0.effect.operation,
                        reason: $0.reconciliationReason)
                },
                effectDetail: matching.map {
                    BotUIFormat.routineEffectReference(
                        operation: $0.effect.operation,
                        target: $0.effect.target,
                        reason: $0.reconciliationReason)
                }))
        }
        return records
    }

    /// Resolve a routine reconciliation from the user's explicit choice. The
    /// routine state and its delivery effect are two different authorities;
    /// both are advanced when each is still in the reconciliation state.
    func resolveReconciliation(routineID: String, decision: String) async throws {
        let now = botProductionNowMilliseconds()
        let updated = try await environment.routineMachine.resolveReconciliation(
            botId: environment.botID, routineId: routineID, decision: decision, now: now)
        guard let updated else {
            throw BotProductionError.invalidService("例行任务不存在")
        }
        guard let state = updated.runState else { return }
        let deliveryKey = RoutineDelivery.key(routineId: routineID, attempt: state.attempt)
        let effectKey = "routine:\(deliveryKey)"
        guard let record = try? await environment.domain.effect(effectKey),
              record.state == .needsReconciliation else { return }
        switch decision {
        case "acknowledge":
            try await environment.domain.ackReconciled(
                effectKey: effectKey, generation: record.generation,
                attempt: record.attempt, resultRef: "user-acknowledged")
        case "retry":
            try await environment.domain.retryNeedsReconciliation(effectKey)
        default:
            throw RoutineError.unsupportedDecision(decision)
        }
    }

    /// Persists the host-level "can disturb" authorization and wakes the
    /// scheduler so a quiet-hours or DND change is applied immediately.
    func saveProactiveSettings(_ settings: ProactiveSettings) async -> ProactiveSettings {
        settingsStore.save(settings)
        let normalized = settingsStore.settings()
        await scheduler?.applySettingsChange()
        return normalized
    }

    func rename(_ name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BotProductionError.invalidService("Bot 名不能为空。") }
        let eventID = "bot-rename-\(UUID().uuidString.lowercased())"
        let event = BotEvent(
            type: "ui.system_event", eventId: eventID, time: botProductionNowMilliseconds(),
            origin: .local(source: "user"), traceId: eventID,
            principal: BotPrincipal(botId: environment.botID, sessionId: nil, kind: "ui"),
            causationId: nil, correlationId: nil,
            data: .object(["event": .string("renamed"), "botName": .string(trimmed)]))
        _ = try await environment.domain.append(event)
    }

    func forget(path: String, expectedVersion: Int) async throws {
        let result = try await environment.memory.forget(
            path: path, expectedVersion: expectedVersion)
        guard result.ok else {
            throw BotProductionError.invalidService(result.error ?? "忘记记忆失败")
        }
    }

    /// Physical erase of one memory document and every historical version.
    /// The shared user root is not touched.
    func eraseMemory(path: String) async throws {
        let outcome = try await environment.memory.erase(
            path: path, sessionEraser: sessionEraser)
        guard outcome.ok else {
            throw BotProductionError.invalidService(outcome.error ?? "抹除记忆失败")
        }
    }

    /// Physically erases only this Bot's agent root. The shared user root is a
    /// separate explicit action (`eraseSharedMemories`) so one Bot can never
    /// wipe the documents every Bot shares.
    func eraseMemories() async throws {
        let outcome = try await environment.memory.erase(
            scope: .agent, sessionEraser: sessionEraser)
        guard outcome.ok else {
            throw BotProductionError.invalidService(outcome.error ?? "抹除记忆失败")
        }
    }

    /// Physically erases the shared user root for every Bot. Only called from
    /// the information page's separate, doubly-confirmed shared-memory entry.
    func eraseSharedMemories() async throws {
        let outcome = try await environment.memory.erase(
            scope: .user, sessionEraser: sessionEraser)
        guard outcome.ok else {
            throw BotProductionError.invalidService(outcome.error ?? "清除共享记忆失败")
        }
    }

    func setRoutineEnabled(_ routineID: String, enabled: Bool) async throws {
        _ = try await environment.routineMachine.update(
            botId: environment.botID, routineId: routineID,
            patch: RoutinePatch(enabled: enabled), now: botProductionNowMilliseconds())
        await scheduler?.applySettingsChange()
    }

    private func approvalRecords() async throws -> [BotProductionApproval] {
        var requested: [String: BotEvent] = [:]
        var records: [BotProductionApproval] = []
        for event in try await BotProductionEventReader.all(domain: environment.domain) {
            guard event.principal.botId == environment.botID else { continue }
            switch event.type {
            case "approval.requested":
                guard let id = event.data["approvalID"]?.stringValue else { continue }
                requested[id] = event
            case "approval.decided":
                guard let id = event.data["approvalID"]?.stringValue else { continue }
                let data = event.data
                let decisionRaw = data["decision"]?.stringValue ?? "deny"
                let decision: BotGrantDecision = decisionRaw == "deny" ? .deny : .allow
                let status: String
                if data["timedOut"]?.boolValue == true {
                    status = "timed-out"
                } else {
                    status = data["status"]?.stringValue
                        ?? (decision == .allow ? "allowed" : "denied")
                }
                let scope: String?
                if decision == .allow {
                    if decisionRaw == "always" {
                        scope = data["alwaysScope"]?.stringValue
                            ?? requested[id]?.data["alwaysScope"]?.stringValue
                            ?? "until"
                    } else {
                        scope = "once"
                    }
                } else {
                    scope = nil
                }
                records.append(BotProductionApproval(
                    id: id,
                    parameterSummary: Self.approvalSummary(request: requested[id]),
                    decision: decision,
                    scope: scope,
                    status: status,
                    reason: data["reason"]?.stringValue,
                    decidedAtMS: event.time))
            default:
                continue
            }
        }
        return records.sorted { $0.decidedAtMS > $1.decidedAtMS }
    }

    /// A user-readable summary built from the approval request's action and
    /// effect labels. Digests, grant ids and raw scopes never reach this string.
    private static func approvalSummary(request: BotEvent?) -> String {
        guard let data = request?.data else { return "一次操作" }
        let action = (data["action"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var labels: [String] = []
        for effect in data["effects"]?.arrayValue ?? [] {
            let raw = (effect["label"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let label = raw.isEmpty ? "工具操作" : raw
            guard !labels.contains(label) else { continue }
            labels.append(label)
        }
        if action.isEmpty {
            return labels.isEmpty ? "一次操作" : labels.joined(separator: "、")
        }
        if labels.isEmpty || labels.contains(action) { return action }
        return "\(action) · \(labels.joined(separator: "、"))"
    }
}

struct BotProductionInfoDriver {
    var load: () async throws -> BotProductionInfoSnapshot

    static func production(service: BotProductionInfoService) -> BotProductionInfoDriver {
        BotProductionInfoDriver(load: { try await service.load() })
    }

    static func production(environment: BotProductionEnvironment,
                           scheduler: RoutineScheduler? = nil,
                           settingsStore: ProactiveSettingsStore = .shared) -> BotProductionInfoDriver {
        production(service: BotProductionInfoService(
            environment: environment, scheduler: scheduler, settingsStore: settingsStore))
    }
}

/// Imports the composer's picked files into the Bot's own DSH workspace through
/// the Worker's `phone/import*` service — the same path the DSH page uses for a
/// verbatim workspace file, because the Bot's file tools run in that workspace.
/// The concrete transport and the Bot's live session id are injected; the
/// session cwd is the Bot root (`BotWorkspaceLayout`), not the shared DSH
/// workspace.
///
/// Limits are enforced before the upload: at most 10 files, each <= 25 MiB.
/// A refused or failed file is reported by name and skipped; the successful
/// subset and the text still send.
final class BotWorkspaceAttachmentImporter: BotAttachmentImporting, @unchecked Sendable {
    private let transport: any DSHRemoteTransport
    private let sessionID: @Sendable () async throws -> String
    /// Bot data root the runtime also passes to `session/create`. The import
    /// service scopes writes to the session cwd, so this must match.
    private let botDataDirectory: String

    init(transport: any DSHRemoteTransport,
         sessionID: @escaping @Sendable () async throws -> String,
         botDataDirectory: String = BotDataRoot.path) {
        self.transport = transport
        self.sessionID = sessionID
        self.botDataDirectory = botDataDirectory
    }

    func importFiles(botID: String, messageID: String, files: [URL]) async -> BotAttachmentImportResult {
        guard !files.isEmpty else { return BotAttachmentImportResult(items: [], errors: []) }

        var errors: [(name: String, reason: String)] = []
        let accepted = Array(files.prefix(BotAttachmentPolicy.maxCount))
        for extra in files.dropFirst(BotAttachmentPolicy.maxCount) {
            errors.append((name: extra.lastPathComponent,
                           reason: "每条消息最多 \(BotAttachmentPolicy.maxCount) 个附件。"))
        }

        var prepared: [(safeName: String, data: Data, mimeType: String)] = []
        var usedNames: Set<String> = []
        for url in accepted {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent.isEmpty ? "file" : url.lastPathComponent
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size > 0 else {
                errors.append((name: name, reason: "文件为空或无法读取。"))
                continue
            }
            guard Int64(size) <= BotAttachmentPolicy.maxBytes else {
                errors.append((name: name, reason: "文件超过 25 MiB。"))
                continue
            }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else {
                errors.append((name: name, reason: "文件为空或无法读取。"))
                continue
            }
            let safeName = Self.uniqueName(BotAttachmentPolicy.safeName(name), used: &usedNames)
            let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            prepared.append((safeName, data, mimeType))
        }

        guard !prepared.isEmpty else { return BotAttachmentImportResult(items: [], errors: errors) }
        let session: String
        do {
            session = try await sessionID()
        } catch {
            let reason = "Bot 会话尚未就绪：\(error.localizedDescription)"
            errors.append(contentsOf: prepared.map { (name: $0.safeName, reason: reason) })
            return BotAttachmentImportResult(items: [], errors: errors)
        }

        let botRoot = BotWorkspaceLayout.botRoot(
            botId: botID, dataDirectory: botDataDirectory)
        let manifest = WebEngineDirectoryImportManifest(
            sessionID: session,
            targetDirectory: botRoot,
            entryName: "attachments-\(messageID)",
            directories: [],
            files: prepared.map { WebEngineDirectoryImportFile(path: $0.safeName, size: $0.data.count) },
            totalBytes: prepared.reduce(0) { $0 + $1.data.count })
        let sink = PhoneDSHWorkspaceImportSink(transport: transport)
        var importID: String?
        do {
            let started = try await sink.begin(manifest)
            importID = started
            let chunk = 1024 * 1024
            for file in prepared {
                var offset = 0
                while offset < file.data.count {
                    let end = min(offset + chunk, file.data.count)
                    try await sink.write(importID: started, path: file.safeName,
                                         offset: offset, data: file.data.subdata(in: offset..<end))
                    offset = end
                }
            }
            let result = try await sink.commit(importID: started)
            let items = prepared.map { file in
                BotAttachment(
                    name: file.safeName,
                    path: "\(result.absolutePath)/\(file.safeName)",
                    size: Int64(file.data.count),
                    mimeType: file.mimeType,
                    kind: BotAttachmentPolicy.kind(name: file.safeName, mimeType: file.mimeType))
            }
            return BotAttachmentImportResult(items: items, errors: errors)
        } catch {
            if let importID { await sink.abort(importID: importID) }
            errors.append(contentsOf: prepared.map {
                (name: $0.safeName, reason: "写入工作区失败：\(error.localizedDescription)")
            })
            return BotAttachmentImportResult(items: [], errors: errors)
        }
    }

    private static func uniqueName(_ name: String, used: inout Set<String>) -> String {
        var candidate = name
        var index = 1
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        while used.contains(candidate) {
            candidate = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            index += 1
        }
        used.insert(candidate)
        return candidate
    }
}

// MARK: - Session epoch erasure (S6 step 2)

/// Holds the composition's current host without making every child closure
/// MainActor-bound. The host actor itself stays the authority; this only
/// forwards the reference.
actor BotHostReference {
    private weak var host: PhoneDSHHost?

    init(host: PhoneDSHHost? = nil) {
        self.host = host
    }

    func set(_ host: PhoneDSHHost?) {
        self.host = host
    }

    func current() -> PhoneDSHHost? { host }
}

/// Orchestrates one S6 step-2 erasure: plan the session lines, switch the main
/// chat to a new epoch, park the Worker, rewrite the closed logs through the
/// host, then resume and stage the continuity seam. The memory store calls
/// this before it clears any event payload; a throw leaves memory intact.
final class BotSessionEpochEraser: Sendable {
    private let remote: BotDSHRemoteRuntime
    private let environment: BotProductionEnvironment
    private let recordService: BotRecordService
    private let hostReference: BotHostReference
    private let workspaceRoot: URL
    /// The composition owns the automatic Worker-boot recovery. This eraser
    /// parks/resumes the host itself and then reattaches the Bot remote, so it
    /// suppresses that automatic path for the duration and releases it (with
    /// the new boot id recorded) before returning.
    private let beginManualWorkerRebind: (@Sendable () async -> Void)?
    private let endManualWorkerRebind: (@Sendable (Bool) async -> Void)?

    init(remote: BotDSHRemoteRuntime,
         environment: BotProductionEnvironment,
         recordService: BotRecordService,
         hostReference: BotHostReference,
         workspaceRoot: URL,
         beginManualWorkerRebind: (@Sendable () async -> Void)? = nil,
         endManualWorkerRebind: (@Sendable (Bool) async -> Void)? = nil) {
        self.remote = remote
        self.environment = environment
        self.recordService = recordService
        self.hostReference = hostReference
        self.workspaceRoot = workspaceRoot
        self.beginManualWorkerRebind = beginManualWorkerRebind
        self.endManualWorkerRebind = endManualWorkerRebind
    }

    func erase(_ request: BotSessionErasureRequest) async throws -> BotSessionErasureReport {
        let current = try await remote.ensureMainSessionID()
        let botIDs: Set<String>
        if request.scope == BotMemoryScope.user.rawValue {
            var ids = Set([request.botID])
            for event in (try? await BotProductionEventReader.all(domain: environment.domain)) ?? [] {
                if let botID = event.principal.botId, !botID.isEmpty { ids.insert(botID) }
            }
            botIDs = ids
        } else {
            botIDs = [request.botID]
        }
        var owned = Set<String>()
        for botID in botIDs {
            owned.formUnion((try? await recordService.ownedSessionIDs(
                botID: botID, callerSessionID: "")) ?? [])
        }
        owned.remove("")
        let planner = BotSessionErasurePlanner(workspaceRoot: workspaceRoot)
        let scan = planner.scan(
            botID: request.botID, ownedSessionIDs: owned,
            needles: request.needles, records: request.records)
        guard !scan.targets.isEmpty else {
            return BotSessionErasureReport(uncoveredRecords: scan.uncovered)
        }
        let erasureID = "session-erasure-\(UUID().uuidString.lowercased())"
        let oldSeqs = Set(scan.targets.first { $0.sessionID == current }?.seqs ?? [])
        let seam = planner.continuation(sessionID: current, erasedSeqs: oldSeqs)
        let switched = try await remote.switchMainSessionForErasure(
            erasureID: erasureID,
            erasedRecords: scan.targets.flatMap(\.records))
        await environment.updateSessionID(switched.new)
        await remote.setPendingContinuation(seam)

        guard let host = await hostReference.current() else {
            throw BotProductionError.invalidService("会话宿主尚未连接，无法改写已关闭会话日志。")
        }
        var erased: [BotErasureEventData.ErasedSessionRecord] = []
        await beginManualWorkerRebind?()
        // The follow streams of running tasks are about to be cut by the
        // deliberate park. Mark the window so the runtime reports an
        // interruption instead of a transport failure.
        await remote.beginHostPark()
        do {
            try await host.park()
            for target in scan.targets {
                let lines = planner.tombstoneLines(
                    sessionID: target.sessionID,
                    erasedSeqs: Set(target.seqs),
                    erasureID: erasureID)
                guard lines.count == target.seqs.count else {
                    throw BotProductionError.invalidService(
                        "会话 \(target.sessionID) 的待抹除行已变化，请重试。")
                }
                let request = PhoneDSHSessionErasureRequest(
                    sessionID: target.sessionID,
                    replacements: lines.map {
                        PhoneDSHSessionLineReplacement(seq: $0.seq, line: $0.data)
                    })
                let result = try await host.eraseClosedSession(request)
                let covered = Set(result.erasedSeqs)
                erased.append(contentsOf: target.seqs.compactMap { seq in
                    guard covered.contains(seq) else { return nil }
                    return BotErasureEventData.ErasedSessionRecord(
                        record: "record://session/\(target.sessionID)#\(seq)",
                        sessionId: target.sessionID, seq: seq)
                })
            }
            try await host.start()
            let transport = try await host.makeTransport()
            await remote.attachTransport(transport)
            _ = try await remote.startMainSession()
            await environment.updateSessionID(switched.new)
            await remote.endHostPark()
            // The manual path bypasses `BotRuntimeUnit.start`, so deliver the
            // interrupted Task wakes here, after the replacement Worker and
            // the new main session are ready.
            _ = await remote.deliverInterruptedTaskWakes()
            await endManualWorkerRebind?(true)
        } catch {
            // Never leave the App parked: the session switch is already
            // durable, so a resume failure is reported separately from the
            // rewrite failure.
            var transportRecovered = false
            if (try? await host.start()) != nil {
                if let transport = try? await host.makeTransport() {
                    await remote.attachTransport(transport)
                    if (try? await remote.startMainSession()) != nil {
                        transportRecovered = true
                    }
                }
            }
            await remote.endHostPark()
            await endManualWorkerRebind?(transportRecovered)
            throw error
        }

        let notice = BotEvent(
            type: "ui.notice",
            eventId: "session-epoch-\(erasureID)",
            time: request.atMS,
            origin: .local(source: "user"),
            traceId: "trace-\(erasureID)",
            principal: BotPrincipal(
                botId: request.botID, sessionId: switched.new, kind: "ipc"),
            causationId: nil,
            correlationId: erasureID,
            data: .object([
                "tone": .string("info"),
                "text": .string(
                    "已抹除的内容已从旧会话日志移除；对话已接续到新会话，未抹除的内容仍然可用。"),
            ]))
        _ = try? await environment.domain.append(notice)
        return BotSessionErasureReport(
            erasedSessionRecords: erased,
            sessionEpochs: [BotErasureEventData.SessionEpoch(
                fromSessionId: switched.old,
                toSessionId: switched.new,
                atMS: request.atMS)],
            uncoveredRecords: scan.uncovered)
    }
}
