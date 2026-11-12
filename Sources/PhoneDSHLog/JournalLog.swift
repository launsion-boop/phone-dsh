// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLog: the host journal.
//
// PLAN §2.3 (D2/D18) and spec/v1/channel.md §3.5–§3.6. Journal
// records of `0x30` are appended to one append-only file with the same two ack
// levels as the WAL: level 1 after write(), level 2 when the epoch closes and
// the file has been F_FULLFSYNCed together with the WAL.
//
// W2 / PC-20261112-w2-journal-step-pruning: once a step's `completed` record is
// level-2 durable its journal entries are no longer needed for replay, so the
// 64 MiB quota has a discardable set (budgets.md §8, exec.md §7). The rewrite is
// atomic (`*.tmp` + fsync + rename + directory fsync), `jseq` is never reused,
// JOURNAL_ACK keeps its two levels, and an entry whose step has no completed
// record is never deleted.

import Darwin
import Foundation
import PhoneDSHWire

/// Cumulative journal acknowledgement (`JOURNAL_ACK`, channel.md §3.6).
public struct JournalAck: Equatable, Sendable {
    public var level: AckLevel
    public var sessionID: String
    public var uptoJseq: UInt64

    public init(level: AckLevel, sessionID: String, uptoJseq: UInt64) {
        self.level = level
        self.sessionID = sessionID
        self.uptoJseq = uptoJseq
    }

    /// The `0x31` payload.
    public var wireBody: JournalAckBody {
        JournalAckBody(level: level.wireLevel, sessionID: sessionID, uptoJseq: uptoJseq)
    }
}

/// Append-only journal file of one workspace.
public actor JournalLog {
    public static let magic = Data([0x58, 0x4C, 0x4A, 0x52, 0x4E, 0x4C, 0x31, 0x00])
    public static let headerBytes = 16

    public let configuration: WorkspaceLogConfiguration
    public let bootID: Data
    public private(set) var byteCount: Int

    private let paths: WorkspacePaths
    private let quota: LogQuota
    private var descriptor: Int32 = -1
    private var lastJseqBySession: [String: UInt64] = [:]
    /// Highest level-2 (epoch fsync) journal position of each session. A
    /// recovered file that has not been closed by this process is deliberately
    /// absent until the first epoch close fsyncs it again.
    private var durableJseqBySession: [String: UInt64] = [:]
    private var entries: [JournalEntry] = []
    private var sessionsSinceClose: Set<String> = []
    private var failed = false
    private let ackBroadcaster = AckBroadcaster<JournalAck>(replayLimit: 64)

    /// One recovered/appended body plus the step identity it belongs to.
    private struct JournalEntry {
        var body: JournalBody
        /// `nil` when the record cannot be mapped to a D20 step (header,
        /// malformed or unknown shape). Such an entry is never pruned.
        var group: EntryGroup?
        /// `true` when the record itself is the step's terminal `completed`
        /// (`done`) projection.
        var isCompleted: Bool
    }

    /// Step identity of a journal group: the session plus the D20 key (or the
    /// legacy decimal ordinal when no key is present).
    private struct EntryGroup: Hashable {
        var sessionID: String
        var identity: String
    }

    /// Opens the journal, rebuilds the per-session jseq high-water marks and
    /// truncates an incomplete trailing record.
    public init(configuration: WorkspaceLogConfiguration, bootID: Data) throws {
        guard bootID.count == 16 else {
            throw LogError.corrupt("boot_id must be 16 raw bytes")
        }
        self.configuration = configuration
        self.bootID = bootID
        let workspacePaths = WorkspacePaths(root: configuration.root)
        self.paths = workspacePaths
        self.quota = LogQuota(configuration: configuration)
        try workspacePaths.createDirectories()
        let recovered = try JournalLog.openAndRecoverJournal(paths: workspacePaths)
        self.byteCount = recovered.byteCount
        self.descriptor = recovered.descriptor
        self.lastJseqBySession = recovered.lastJseq
        self.entries = recovered.bodies.map(Self.entry(for:))
    }

    deinit {
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    /// Cumulative journal acks.
    public nonisolated func acks() -> AsyncStream<JournalAck> {
        ackBroadcaster.stream()
    }

    /// Highest jseq per session known to the file.
    public func lastJseq(sessionID: String) -> UInt64 {
        lastJseqBySession[sessionID] ?? 0
    }

    /// Highest level-2 durable jseq per session, as known to this process.
    /// Recovered bytes become durable again at the first epoch close.
    public func durableJseq(sessionID: String) -> UInt64 {
        durableJseqBySession[sessionID] ?? 0
    }

    /// Validated journal records recovered from the framed, CRC-checked file
    /// that are still needed for projection replay. Entries pruned after a
    /// durable close are no longer returned, so this snapshot stays bounded.
    public func recoveredSnapshot() -> [JournalBody] { entries.map(\.body) }

    /// Appends one `0x30` record and emits its level-1 ack after write().
    public func append(_ body: JournalBody) async throws -> UInt64 {
        guard !failed else { throw LogError.closed }
        try body.validate()
        if body.jseq <= (lastJseqBySession[body.sessionID] ?? 0) {
            // D2: deduplicate by (session_id, jseq); a reconnect may resend.
            let ack = JournalAck(level: .write, sessionID: body.sessionID,
                                 uptoJseq: body.jseq)
            ackBroadcaster.yield(ack)
            return body.jseq
        }
        let payload = try encode(body)
        do {
            try quota.requireJournalSpace(used: byteCount, additionalBytes: payload.count)
        } catch let error as LogError {
            guard case .quotaExceeded = error else { throw error }
            // budgets.md §8: on a quota overflow the durable, completed
            // entries are the discardable set. If none can be dropped the
            // append still fails loud; the quota itself never grows.
            let pruned = try pruneDurableEntries()
            guard pruned > 0 else { throw error }
            try quota.requireJournalSpace(used: byteCount, additionalBytes: payload.count)
        }
        do {
            try LogFile.writeAll(fd: descriptor, data: payload)
        } catch {
            failed = true
            throw error
        }
        byteCount += payload.count
        lastJseqBySession[body.sessionID] = body.jseq
        entries.append(Self.entry(for: body))
        sessionsSinceClose.insert(body.sessionID)
        let ack = JournalAck(level: .write, sessionID: body.sessionID, uptoJseq: body.jseq)
        ackBroadcaster.yield(ack)
        return body.jseq
    }

    /// D18 epoch sync: F_FULLFSYNC the journal and emit level-2 acks for every
    /// session that appended since the previous close. Afterwards the durable
    /// completed entries are pruned (budgets.md §8: only after the level-2
    /// fsync, never before it).
    @discardableResult
    public func closeEpoch() async throws -> [JournalAck] {
        guard !failed else { throw LogError.closed }
        guard descriptor >= 0 else { return [] }
        try LogFile.fullFsync(fd: descriptor)
        var acks: [JournalAck] = []
        for session in sessionsSinceClose.sorted() {
            guard let jseq = lastJseqBySession[session] else { continue }
            let ack = JournalAck(level: .epochFsync, sessionID: session, uptoJseq: jseq)
            acks.append(ack)
            ackBroadcaster.yield(ack)
        }
        sessionsSinceClose.removeAll()
        // Every byte in the file is now level-2 durable, including records
        // recovered from a previous process that this process has not closed
        // yet. A later close covers them for pruning purposes.
        for (session, jseq) in lastJseqBySession {
            durableJseqBySession[session] = max(durableJseqBySession[session] ?? 0, jseq)
        }
        _ = try pruneDurableEntries()
        return acks
    }

    /// Acquires an advisory lock-free snapshot of the journal size.
    public func sizeInBytes() -> Int { byteCount }

    // MARK: - Pruning (budgets.md §8, exec.md §7)

    /// Whole-entry deletion of every step whose terminal `completed` record is
    /// level-2 durable and whose whole group is covered by the durable
    /// watermark. Returns the number of entries removed.
    @discardableResult
    public func pruneDurableEntries() throws -> Int {
        guard !failed, descriptor >= 0, !entries.isEmpty else { return 0 }
        var completedJseq: [EntryGroup: UInt64] = [:]
        var highestByGroup: [EntryGroup: UInt64] = [:]
        for entry in entries {
            guard let group = entry.group else { continue }
            highestByGroup[group] = max(highestByGroup[group] ?? 0, entry.body.jseq)
            guard entry.isCompleted else { continue }
            completedJseq[group] = max(completedJseq[group] ?? 0, entry.body.jseq)
        }
        guard !completedJseq.isEmpty else { return 0 }
        var prunable: Set<EntryGroup> = []
        for (group, completion) in completedJseq {
            let durable = durableJseqBySession[group.sessionID] ?? 0
            guard completion <= durable else { continue }
            // Never drop a group with an entry above the durable watermark:
            // the later entry is not yet covered by level 2.
            guard highestByGroup[group] ?? 0 <= durable else { continue }
            prunable.insert(group)
        }
        guard !prunable.isEmpty else { return 0 }
        // Keep the highest-jseq entry of every session as the persisted
        // high-water mark. The journal header format is fixed (wal.md §7.1 has
        // no `jseq_base` field), so dropping the last entry would make the next
        // process report a lower `lastJseq`; the channel would then reject the
        // next contiguous record as a gap (channel.md §3.5, D2). One retained
        // entry per session is a whole entry, not a half-deleted record, and
        // replay of it is idempotent.
        var highestJseq: [String: UInt64] = [:]
        for entry in entries {
            highestJseq[entry.body.sessionID] = max(
                highestJseq[entry.body.sessionID] ?? 0, entry.body.jseq)
        }
        let kept = entries.filter { entry in
            guard let group = entry.group, prunable.contains(group) else { return true }
            if entry.body.jseq == highestJseq[entry.body.sessionID] { return true }
            // Keep the terminal `completed` record too when a later post-done
            // entry is the high-water mark: replay then still reconstructs a
            // terminal step instead of a stray in-progress record.
            return entry.isCompleted && entry.body.jseq == completedJseq[group]
        }
        let removed = entries.count - kept.count
        try rewrite(entries: kept)
        entries = kept
        return removed
    }

    /// Atomic whole-file rewrite: temporary file, fsync, rename over the
    /// journal and fsync the directory (wal.md §7.1 order). A kill before the
    /// rename leaves the old file; a kill after it leaves the new one. The
    /// descriptor is reopened in every outcome so later appends never write to
    /// an unlinked inode.
    private func rewrite(entries kept: [JournalEntry]) throws {
        var data = Self.header()
        for entry in kept {
            data.append(try encode(entry.body))
        }
        defer {
            if descriptor >= 0 {
                Darwin.close(descriptor)
                descriptor = -1
            }
            do {
                descriptor = try LogFile.open(paths.journalURL,
                                              flags: O_WRONLY | O_APPEND)
                byteCount = try LogFile.size(paths.journalURL)
            } catch {
                failed = true
            }
        }
        try LogFile.atomicWrite(data, to: paths.journalURL)
    }

    // MARK: - File format

    private static func header() -> Data {
        var header = Data()
        header.append(Self.magic)
        header.appendUInt16BigEndian(1)
        header.appendUInt16BigEndian(0)
        header.appendUInt32BigEndian(CRC32C.checksum(header))
        return header
    }

    /// Classifies one record for retention. Only a JSON object with a D20
    /// `key` (or a legacy `step_id`) is a step entry; everything else is kept.
    private static func entry(for body: JournalBody) -> JournalEntry {
        guard let object = try? JSONSerialization.jsonObject(with: body.record),
              let dictionary = object as? [String: Any] else {
            return JournalEntry(body: body, group: nil, isCompleted: false)
        }
        let type = (dictionary["type"] as? String) ?? (dictionary["t"] as? String)
        let identity = (dictionary["key"] as? String)
            ?? (dictionary["XL_IDEMPOTENCY_KEY"] as? String)
            ?? stepIdentity(dictionary["step_id"])
        guard type != "header", let identity else {
            return JournalEntry(body: body, group: nil, isCompleted: false)
        }
        let completed = type == "completed" || type == "done"
        return JournalEntry(
            body: body,
            group: EntryGroup(sessionID: body.sessionID, identity: identity),
            isCompleted: completed)
    }

    private static func stepIdentity(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        if let number = value as? NSNumber,
           number.doubleValue.rounded() == number.doubleValue,
           number.doubleValue >= 1 {
            return String(number.int64Value)
        }
        return nil
    }

    private func encode(_ body: JournalBody) throws -> Data {
        var payload = Data()
        payload.appendUInt64BigEndian(body.jseq)
        let sessionBytes = Data(body.sessionID.utf8)
        guard sessionBytes.count <= Int(UInt16.max) else {
            throw LogError.corrupt("journal session_id exceeds u16")
        }
        payload.appendUInt16BigEndian(UInt16(sessionBytes.count))
        payload.append(sessionBytes)
        payload.append(body.record)
        guard payload.count <= Int(UInt32.max) - 8 else {
            throw LogError.corrupt("journal record is too large")
        }
        var encoded = Data(capacity: 8 + payload.count)
        encoded.appendUInt32BigEndian(UInt32(payload.count))
        encoded.appendUInt32BigEndian(CRC32C.checksum(payload))
        encoded.append(payload)
        return encoded
    }

    private static func openAndRecoverJournal(paths: WorkspacePaths) throws
        -> (descriptor: Int32, byteCount: Int, lastJseq: [String: UInt64], bodies: [JournalBody]) {
        let header = Self.header()

        guard LogFile.exists(paths.journalURL) else {
            let descriptor = try LogFile.open(paths.journalURL,
                                              flags: O_WRONLY | O_CREAT | O_EXCL,
                                              mode: 0o644)
            try LogFile.writeAll(fd: descriptor, data: header)
            return (descriptor, header.count, [:], [])
        }

        let data = try LogFile.readAll(paths.journalURL)
        if data.isEmpty {
            let descriptor = try LogFile.open(paths.journalURL, flags: O_WRONLY | O_APPEND)
            try LogFile.writeAll(fd: descriptor, data: header)
            return (descriptor, header.count, [:], [])
        }
        guard data.count >= header.count,
              Data(data.prefix(Self.magic.count)) == Self.magic,
              data.uint32BigEndian(at: 12) == CRC32C.checksum(data.prefix(12))
        else {
            throw LogError.corrupt("journal header failed verification")
        }

        var lastJseq: [String: UInt64] = [:]
        var bodies: [JournalBody] = []
        var offset = header.count
        var validEnd = offset
        while offset + 8 <= data.count {
            let length = Int(data.uint32BigEndian(at: offset))
            guard length >= 1, offset + 8 + length <= data.count else { break }
            let payload = data.subdata(in: (offset + 8)..<(offset + 8 + length))
            guard data.uint32BigEndian(at: offset + 4) == CRC32C.checksum(payload),
                  payload.count >= 10
            else {
                throw LogError.corrupt("journal record CRC failed")
            }
            let jseq = payload.uint64BigEndian(at: 0)
            let sessionLength = Int((UInt16(payload.uint8BigEndian(at: 8)) << 8)
                | UInt16(payload.uint8BigEndian(at: 9)))
            guard payload.count >= 10 + sessionLength,
                  let session = String(data: payload.subdata(in: 10..<(10 + sessionLength)),
                                       encoding: .utf8)
            else {
                throw LogError.corrupt("journal record session_id is invalid")
            }
            let record = payload.subdata(in: (10 + sessionLength)..<payload.count)
            let body = JournalBody(jseq: jseq, sessionID: session, record: record)
            try body.validate()
            bodies.append(body)
            lastJseq[session] = max(lastJseq[session] ?? 0, jseq)
            offset += 8 + length
            validEnd = offset
        }
        if validEnd < data.count {
            // A torn tail from a process kill; the level-1 promise covers only
            // complete write() calls, so truncate it.
            try LogFile.truncate(paths.journalURL, to: validEnd)
        }
        let descriptor = try LogFile.open(paths.journalURL, flags: O_WRONLY | O_APPEND)
        return (descriptor, validEnd, lastJseq, bodies)
    }
}
