// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLog: the host journal.
//
// PLAN §2.3 (D2/D18) and spec/v1/channel.md §3.5–§3.6. Journal
// records of `0x30` are appended to one append-only file with the same two ack
// levels as the WAL: level 1 after write(), level 2 when the epoch closes and
// the file has been F_FULLFSYNCed together with the WAL. The journal has no
// droppable set (it is the record of side effects), so its 64 MB quota fails
// loud before a record is appended.

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
    private var recoveredBodies: [JournalBody] = []
    private var sessionsSinceClose: Set<String> = []
    private var failed = false
    private let ackBroadcaster = AckBroadcaster<JournalAck>(replayLimit: 64)

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
        self.recoveredBodies = recovered.bodies
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

    /// Validated journal records recovered from the framed, CRC-checked file.
    /// The host uses this snapshot to rebuild controller projections after a
    /// crash between durable append and the in-memory observer.
    public func recoveredSnapshot() -> [JournalBody] { recoveredBodies }

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
        try quota.requireJournalSpace(used: byteCount, additionalBytes: payload.count)
        do {
            try LogFile.writeAll(fd: descriptor, data: payload)
        } catch {
            failed = true
            throw error
        }
        byteCount += payload.count
        lastJseqBySession[body.sessionID] = body.jseq
        recoveredBodies.append(body)
        sessionsSinceClose.insert(body.sessionID)
        let ack = JournalAck(level: .write, sessionID: body.sessionID, uptoJseq: body.jseq)
        ackBroadcaster.yield(ack)
        return body.jseq
    }

    /// D18 epoch sync: F_FULLFSYNC the journal and emit level-2 acks for every
    /// session that appended since the previous close.
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
        return acks
    }

    /// Acquires an advisory lock-free snapshot of the journal size.
    public func sizeInBytes() -> Int { byteCount }

    // MARK: - File format

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
        var header = Data()
        header.append(Self.magic)
        header.appendUInt16BigEndian(1)
        header.appendUInt16BigEndian(0)
        header.appendUInt32BigEndian(CRC32C.checksum(header))

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
