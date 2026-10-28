// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHController: side-effect ledger.
//
// PLAN §2.4 (D10) and spec/v1/exec.md §2/§5. The host keeps one
// persisted entry per exec `idem_key` (or MCP `Idempotency-Key`) under
// `exec/<key>.json`. A repeated key with the same `argv` and `cwd` is replayed
// from the recorded event stream and never executed again; a different `argv`
// or `cwd` is a conflict. Only those two fields participate in the comparison —
// deadline, grace, env, confine and transport fields do not. The table is
// bounded by the 64 MB journal quota with LRU eviction of entries whose step
// is already journaled.

import Foundation
import PhoneDSHLog
import PhoneDSHWire

/// Artifact kind of one ledger entry.
public enum SideEffectKind: String, Codable, Equatable, Sendable {
    case exec
    case mcp
}

/// One persisted dedup entry (exec.md §2). For MCP calls the canonical JSON of
/// the tool arguments object takes the `argv` slot as a single element and
/// `cwd` is the request's workspace root.
public struct SideEffectEntry: Codable, Equatable, Sendable {
    public var version: Int
    public var kind: SideEffectKind
    public var key: String
    public var execID: String?
    public var argv: [String]
    public var cwd: String
    public var stepID: String?
    public var turnID: String?
    public var createdAtMilliseconds: Int64
    public var lastAccessMilliseconds: Int64
    public var terminal: Bool
    /// Canonical JSON text of each recorded EXEC_EVT, in emit order.
    public var events: [String]
    /// Recorded MCP response body, replayed verbatim.
    public var response: Data?
    public var status: Int?
    /// An entry may be evicted only after its step is journaled (exec.md §2).
    public var journaled: Bool
    /// Optional D20 association supplied by EXEC_REQ. Older entries remain
    /// unassociated rather than guessing a step during recovery.
    public var toolKey: String?
    public var requiresMseq: UInt64?

    public init(version: Int = 1, kind: SideEffectKind, key: String,
                execID: String? = nil, argv: [String], cwd: String,
                stepID: String? = nil, turnID: String? = nil,
                createdAtMilliseconds: Int64, lastAccessMilliseconds: Int64,
                terminal: Bool = false, events: [String] = [],
                response: Data? = nil, status: Int? = nil, journaled: Bool = false,
                toolKey: String? = nil, requiresMseq: UInt64? = nil) {
        self.version = version
        self.kind = kind
        self.key = key
        self.execID = execID
        self.argv = argv
        self.cwd = cwd
        self.stepID = stepID
        self.turnID = turnID
        self.createdAtMilliseconds = createdAtMilliseconds
        self.lastAccessMilliseconds = lastAccessMilliseconds
        self.terminal = terminal
        self.events = events
        self.response = response
        self.status = status
        self.journaled = journaled
        self.toolKey = toolKey
        self.requiresMseq = requiresMseq
    }

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case kind
        case key
        case execID = "exec_id"
        case argv
        case cwd
        case stepID = "step_id"
        case turnID = "turn_id"
        case createdAtMilliseconds = "created_at_ms"
        case lastAccessMilliseconds = "last_access_ms"
        case terminal
        case events
        case response
        case status
        case journaled
        case toolKey = "tool_key"
        case requiresMseq = "requires_mseq"
    }
}

/// Result of an exec dedup lookup.
public enum ExecReplay: Equatable, Sendable {
    case miss
    case started(SideEffectEntry)
    case replay(SideEffectEntry)
    case conflict(SideEffectEntry)
}

/// Result of an MCP dedup lookup.
public enum MCPReplay: Equatable, Sendable {
    case miss
    case started(SideEffectEntry)
    case replay(SideEffectEntry)
    case conflict(SideEffectEntry)
}

/// Errors of ``SideEffectLedger``.
public enum LedgerError: Error, Equatable, Sendable {
    case invalidKey(String)
    case missingEntry(String)
    case quotaExceeded(limit: Int, used: Int)
    case corrupt(String)
}

/// Persisted dedup/replay table for exec and MCP side effects (D10).
public actor SideEffectLedger {
    /// The 64 MB journal quota (PLAN §2.3, budgets.md §5).
    public static let defaultQuotaBytes = 64 * 1024 * 1024

    /// Workspace root, `Library/xl/<workspace_id>/`.
    public nonisolated let root: URL
    public let quotaBytes: Int
    public private(set) var totalBytes: Int = 0

    private let clock: any HostClock
    private let execDirectory: URL
    private var entries: [String: SideEffectEntry] = [:]

    public init(root: URL,
                quotaBytes: Int = SideEffectLedger.defaultQuotaBytes,
                clock: any HostClock = SystemHostClock()) throws {
        self.root = root
        self.quotaBytes = max(0, quotaBytes)
        self.clock = clock
        self.execDirectory = root.appendingPathComponent("exec", isDirectory: true)
        try ControllerFileStore.ensureDirectory(execDirectory)
        let loaded = try Self.loadFromDisk(execDirectory: execDirectory)
        self.entries = loaded.entries
        self.totalBytes = loaded.totalBytes
    }

    // MARK: - Exec dedup

    /// Starts a new exec entry or returns the recorded one. A repeated key
    /// with a different `argv`/`cwd` is a conflict and never executes; the
    /// intent entry is persisted before the caller starts the process.
    public func prepareExec(idemKey: String, execID: String, argv: [String],
                            cwd: String, stepID: String? = nil,
                            turnID: String? = nil, toolKey: String? = nil,
                            requiresMseq: UInt64? = nil) throws -> ExecReplay {
        try validateKey(idemKey)
        guard WireValidation.isValidIdentifier(execID) else {
            throw LedgerError.invalidKey(execID)
        }
        if var entry = entries[idemKey] {
            guard entry.kind == .exec, entry.argv == argv, entry.cwd == cwd else {
                return .conflict(entry)
            }
            if entry.toolKey == nil, let toolKey {
                entry.toolKey = toolKey
                entry.requiresMseq = requiresMseq
            }
            entry.lastAccessMilliseconds = nowMilliseconds
            try write(entry)
            return .replay(entry)
        }
        let now = nowMilliseconds
        var entry = SideEffectEntry(kind: .exec, key: idemKey, execID: execID,
                                    argv: argv, cwd: cwd, stepID: stepID,
                                    turnID: turnID,
                                    createdAtMilliseconds: now,
                                    lastAccessMilliseconds: now,
                                    toolKey: toolKey, requiresMseq: requiresMseq)
        entry.events = []
        try write(entry)
        return .started(entry)
    }

    /// Replays a recorded exec event stream. A key with no terminal event
    /// means the previous host died mid-execution: a terminal `interrupted`
    /// error event is appended and replayed instead of executing (exec.md §2).
    public func replayExec(idemKey: String, argv: [String],
                           cwd: String) throws -> ExecReplay {
        try validateKey(idemKey)
        guard var entry = entries[idemKey] else { return .miss }
        guard entry.kind == .exec, entry.argv == argv, entry.cwd == cwd else {
            return .conflict(entry)
        }
        if !entry.terminal {
            let event = SideEffectLedger.interruptedEvent(execID: entry.execID,
                                                          idemKey: idemKey)
            entry.events.append(event)
            entry.terminal = true
        }
        entry.lastAccessMilliseconds = nowMilliseconds
        try write(entry)
        return .replay(entry)
    }

    /// Records one already-emitted EXEC_EVT (canonical JSON object). The
    /// caller records before emitting, so a replay never omits an event.
    @discardableResult
    public func appendExecEvent(idemKey: String, event: Data) throws -> SideEffectEntry {
        try validateKey(idemKey)
        guard var entry = entries[idemKey], entry.kind == .exec else {
            throw LedgerError.missingEntry(idemKey)
        }
        let canonical: Data
        do {
            canonical = try CanonicalJSON.canonicalize(event)
        } catch {
            throw LedgerError.corrupt("exec event is not a canonical JSON object")
        }
        guard let text = String(data: canonical, encoding: .utf8) else {
            throw LedgerError.corrupt("exec event is not UTF-8")
        }
        entry.events.append(text)
        if Self.isTerminalExecEvent(canonical) {
            entry.terminal = true
        }
        entry.lastAccessMilliseconds = nowMilliseconds
        try write(entry)
        return entry
    }

    // MARK: - MCP dedup

    /// Records one MCP response under its idempotency key (exec.md §5).
    /// `arguments` is the canonical JSON of the tool arguments object; it is
    /// compared with `cwd` only, exactly like the exec `argv`/`cwd` pair.
    @discardableResult
    public func recordMCP(idempotencyKey: String, arguments: Data,
                          cwd: String, response: Data,
                          status: Int = 200) throws -> MCPReplay {
        try validateKey(idempotencyKey)
        let canonicalArguments: Data
        do {
            canonicalArguments = try CanonicalJSON.canonicalize(arguments)
        } catch {
            throw LedgerError.corrupt("MCP arguments are not a canonical JSON object")
        }
        guard let argumentText = String(data: canonicalArguments, encoding: .utf8) else {
            throw LedgerError.corrupt("MCP arguments are not UTF-8")
        }
        let argv = [argumentText]
        if var entry = entries[idempotencyKey] {
            guard entry.kind == .mcp, entry.argv == argv, entry.cwd == cwd else {
                return .conflict(entry)
            }
            entry.lastAccessMilliseconds = nowMilliseconds
            try write(entry)
            return .replay(entry)
        }
        let now = nowMilliseconds
        let entry = SideEffectEntry(kind: .mcp, key: idempotencyKey, argv: argv,
                                    cwd: cwd, createdAtMilliseconds: now,
                                    lastAccessMilliseconds: now,
                                    terminal: true, events: [],
                                    response: response, status: status,
                                    journaled: true)
        try write(entry)
        return .started(entry)
    }

    /// Replays a recorded MCP response for a repeated idempotency key.
    public func replayMCP(idempotencyKey: String, arguments: Data,
                          cwd: String) throws -> MCPReplay {
        try validateKey(idempotencyKey)
        let canonicalArguments: Data
        do {
            canonicalArguments = try CanonicalJSON.canonicalize(arguments)
        } catch {
            throw LedgerError.corrupt("MCP arguments are not a canonical JSON object")
        }
        guard let argumentText = String(data: canonicalArguments, encoding: .utf8) else {
            throw LedgerError.corrupt("MCP arguments are not UTF-8")
        }
        guard var entry = entries[idempotencyKey] else { return .miss }
        guard entry.kind == .mcp, entry.argv == [argumentText], entry.cwd == cwd else {
            return .conflict(entry)
        }
        entry.lastAccessMilliseconds = nowMilliseconds
        try write(entry)
        return .replay(entry)
    }

    // MARK: - Queries and retention

    /// One entry by key.
    public func entry(forKey key: String) -> SideEffectEntry? {
        entries[key]
    }

    /// All keys currently retained, sorted.
    public func keys() -> [String] {
        entries.keys.sorted()
    }

    /// Persisted values for boot-time step evidence reconstruction.
    public func allEntries() -> [SideEffectEntry] {
        entries.keys.sorted().compactMap { entries[$0] }
    }

    /// Marks the entry's step journaled and durable so it becomes evictable
    /// under quota pressure (exec.md §2 retention rule).
    @discardableResult
    public func markJournaled(key: String) throws -> SideEffectEntry {
        guard var entry = entries[key] else {
            throw LedgerError.missingEntry(key)
        }
        entry.journaled = true
        try write(entry)
        return entry
    }

    // MARK: - Persistence and quota

    private var nowMilliseconds: Int64 {
        clock.now.millisecondsSinceEpoch
    }

    private static func loadFromDisk(execDirectory: URL) throws
        -> (entries: [String: SideEffectEntry], totalBytes: Int) {
        var entries: [String: SideEffectEntry] = [:]
        var totalBytes = 0
        for name in ControllerFileStore.fileNames(in: execDirectory)
        where name.hasSuffix(".json") {
            let key = String(name.dropLast(".json".count))
            guard WireValidation.isValidIdemKey(key) else { continue }
            let url = execDirectory.appendingPathComponent(name)
            guard let entry = try ControllerFileStore.readJSON(SideEffectEntry.self,
                                                                from: url) else {
                continue
            }
            guard entry.key == key, entry.version == 1 else {
                throw LedgerError.corrupt("ledger entry key or version mismatch")
            }
            entries[key] = entry
            totalBytes += ControllerFileStore.fileSize(url)
        }
        return (entries, totalBytes)
    }

    private func write(_ entry: SideEffectEntry) throws {
        let url = entryURL(entry.key)
        let data = try ControllerFileStore.encode(entry)
        let oldSize = ControllerFileStore.fileSize(url)
        if oldSize == 0 && data.count > quotaBytes {
            throw LedgerError.quotaExceeded(limit: quotaBytes, used: totalBytes)
        }
        let projected = totalBytes - oldSize + data.count
        if projected > quotaBytes {
            try evict(until: quotaBytes, adding: data.count - oldSize,
                      excluding: entry.key)
        }
        try ControllerFileStore.writeAtomic(data, to: url)
        totalBytes += data.count - oldSize
        entries[entry.key] = entry
    }

    /// LRU eviction of already-journaled entries. Un-journaled steps are never
    /// evicted; if only pinned entries remain the ledger fails loud.
    private func evict(until limit: Int, adding: Int, excluding key: String) throws {
        var reclaimed = 0
        let candidates = entries.values
            .filter { $0.journaled && $0.key != key }
            .sorted { $0.lastAccessMilliseconds < $1.lastAccessMilliseconds }
        for candidate in candidates {
            if totalBytes - reclaimed + adding <= limit { return }
            let url = entryURL(candidate.key)
            let removedSize = ControllerFileStore.fileSize(url)
            try ControllerFileStore.removeIfExists(url)
            totalBytes -= removedSize
            reclaimed += removedSize
            entries.removeValue(forKey: candidate.key)
        }
        if totalBytes + adding > limit {
            throw LedgerError.quotaExceeded(limit: limit, used: totalBytes)
        }
    }

    private func entryURL(_ key: String) -> URL {
        execDirectory.appendingPathComponent(key + ".json")
    }

    private func validateKey(_ key: String) throws {
        guard WireValidation.isValidIdemKey(key) else {
            throw LedgerError.invalidKey(key)
        }
    }

    // MARK: - Event helpers

    static func isTerminalExecEvent(_ event: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: event),
              let dictionary = object as? [String: Any],
              let type = dictionary["type"] as? String else {
            return false
        }
        return type == "exit" || type == "error"
    }

    static func interruptedEvent(execID: String?, idemKey: String) -> String {
        var fields: [String: Any] = [
            "type": "error",
            "code": "interrupted",
            "message": "host restarted before the terminal exec event",
            "idem_key": idemKey,
        ]
        if let execID { fields["exec_id"] = execID }
        if let data = try? JSONSerialization.data(withJSONObject: fields,
                                                  options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "{\"code\":\"interrupted\",\"type\":\"error\"}"
    }
}
