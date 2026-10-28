// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLog: workspace paths, manifest,
// POSIX file helpers and the acknowledgement broadcaster.
//
// PLAN §2.3 (D11/D17/D18) and spec/v1/wal.md §1, §7. Everything here
// is Foundation + Darwin only. Absolute local paths are never embedded in the
// source or in an error message: only workspace-relative names and `/dsh/...`
// VFS paths appear.

import Darwin
import Foundation
import PhoneDSHWire

// MARK: - Errors

/// The quota-managed log streams of PLAN §2.3.
public enum LogResource: String, Equatable, Sendable {
    case wal
    case journal
}

/// Errors of the workspace log. Every case is fail loud: the caller closes
/// admission instead of silently dropping data.
public enum LogError: Error, Equatable, Sendable {
    /// `WAL_CORRUPT`: a non-tail CRC/length/mseq failure or a manifest that no
    /// longer matches the WAL (D19, D11).
    case corrupt(String)
    /// A materialization I/O failure; a host defect, not a protocol error.
    case materializationFailed(String)
    /// Quota exceeded after compaction; never a silent drop (wal.md §9).
    case quotaExceeded(resource: LogResource, limit: Int, used: Int)
    /// The overlay refused a symlink (wal.md §8).
    case overlaySymlink(String)
    /// A tar entry exceeds the ustar name/prefix fields.
    case overlayPathTooLong(String)
    /// A barrier names an mseq that was never appended.
    case invalidBarrier(String)
    /// A bounded sequence of epoch closes still left the durable watermark
    /// below the WAL tail (D18); the host must fail loud rather than advertise
    /// a fence below the on-disk tail.
    case epochCoverageFailed(String)
    /// The facade is used before recovery completed.
    case notReady(String)
    /// The log was closed after a fatal write failure.
    case closed
    /// A VFS mutation would grow one file past the configured single-file
    /// budget. This is a resource refusal, not a protocol error: no mseq is
    /// consumed and nothing is appended.
    case vfsRefused(path: String, limit: Int, projected: Int)
    /// A POSIX call failed; `code` is `errno`.
    case posix(operation: String, code: Int32)
}

extension LogError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .corrupt(let reason):
            return "WAL_CORRUPT: \(reason)"
        case .materializationFailed(let reason):
            return "materialization failed: \(reason)"
        case .quotaExceeded(let resource, let limit, let used):
            return "\(resource.rawValue) quota exceeded: \(used) > \(limit) bytes"
        case .overlaySymlink(let path):
            return "overlay rejects symlink \(path)"
        case .overlayPathTooLong(let path):
            return "overlay entry exceeds the ustar name fields: \(path)"
        case .invalidBarrier(let reason):
            return "invalid barrier: \(reason)"
        case .epochCoverageFailed(let reason):
            return "epoch close did not cover the WAL tail: \(reason)"
        case .notReady(let reason):
            return "workspace log is not ready: \(reason)"
        case .closed:
            return "workspace log is closed after a write failure"
        case .vfsRefused(let path, let limit, let projected):
            return "VFS_REFUSED: \(path) would grow to \(projected) bytes, above the single-file limit of \(limit) bytes"
        case .posix(let operation, let code):
            return "\(operation) failed: errno \(code)"
        }
    }
}

extension LogError: VFSResourceRefusalProviding {
    /// The single-file budget refusal is the one non-closing resource answer
    /// (channel.md §4.8, §8). Every other log failure — WAL corruption, a
    /// materialization I/O failure or a quota still exceeded after compaction —
    /// stays a host defect and keeps the fail-loud path of wal.md §9/§10.
    public var vfsResourceRefusal: VFSResourceRefusal? {
        guard case .vfsRefused(let path, let limit, let projected) = self else {
            return nil
        }
        return VFSResourceRefusal(
            path: path,
            limitBytes: UInt64(max(0, limit)),
            projectedBytes: UInt64(max(0, projected)),
            reason: .fileTooLarge,
            message: description)
    }
}

// MARK: - Workspace layout

/// `Library/xl/<workspace_id>/` of wal.md §1. All paths are derived from the
/// caller-supplied root; none is persisted inside the workspace or the repo.
public struct WorkspacePaths: Equatable, Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var walDirectory: URL { root.appendingPathComponent("wal", isDirectory: true) }
    public var materializedDirectory: URL {
        root.appendingPathComponent("materialized", isDirectory: true)
    }
    public var materializedHomeDirectory: URL {
        materializedDirectory.appendingPathComponent("home", isDirectory: true)
    }
    public var materializedWorkspaceDirectory: URL {
        materializedDirectory.appendingPathComponent("workspace", isDirectory: true)
    }
    public var stagingDirectory: URL {
        root.appendingPathComponent("materialized.staging", isDirectory: true)
    }
    public var manifestURL: URL { root.appendingPathComponent("manifest.json") }
    public var manifestTemporaryURL: URL {
        root.appendingPathComponent("manifest.json.tmp")
    }
    public var journalURL: URL { root.appendingPathComponent("journal.xljournal") }
    public var reconcileMarkerURL: URL {
        root.appendingPathComponent("reconcile.inprogress")
    }
    public var stepsDirectory: URL { root.appendingPathComponent("steps", isDirectory: true) }
    public var execDirectory: URL { root.appendingPathComponent("exec", isDirectory: true) }

    /// `<root>/overlay-<boot_id>.tar`, rebuilt for every boot (wal.md §8).
    /// The name is the pre-D21 route contract; the bytes are gzip (D21).
    public func overlayURL(bootID: String) -> URL {
        root.appendingPathComponent("overlay-\(bootID).tar")
    }

    /// Creates the directories the log owns. `steps/` and `exec/` belong to
    /// other host components and are not created here.
    public func createDirectories() throws {
        try LogFile.ensureDirectory(root)
        try LogFile.ensureDirectory(walDirectory)
        try LogFile.ensureDirectory(materializedDirectory)
        try LogFile.ensureDirectory(materializedHomeDirectory)
        try LogFile.ensureDirectory(materializedWorkspaceDirectory)
    }
}

/// Names of WAL segments: `wal/<epoch:08d>.<segment:06d>.xlwal` (wal.md §1).
public struct WALSegmentName: Equatable, Comparable, Sendable {
    public static let maximumEpoch: UInt64 = 99_999_999
    public static let maximumSegment: UInt64 = 999_999

    public let epoch: UInt64
    public let segment: UInt64

    public init(epoch: UInt64, segment: UInt64) throws {
        guard epoch >= 1, epoch <= Self.maximumEpoch else {
            throw LogError.corrupt("segment epoch \(epoch) is outside 1...99999999")
        }
        guard segment <= Self.maximumSegment else {
            throw LogError.corrupt("segment number \(segment) is outside 0...999999")
        }
        self.epoch = epoch
        self.segment = segment
    }

    /// Parses a bare file name; `nil` for unrelated files in `wal/`.
    public init?(fileName: String) {
        let parts = fileName.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "xlwal",
              parts[0].count == 8, parts[1].count == 6,
              let epoch = UInt64(parts[0]), let segment = UInt64(parts[1]),
              epoch >= 1, epoch <= Self.maximumEpoch, segment <= Self.maximumSegment
        else { return nil }
        self.epoch = epoch
        self.segment = segment
    }

    public var fileName: String {
        "\(Self.padded(epoch, width: 8)).\(Self.padded(segment, width: 6)).xlwal"
    }

    /// Decimal zero-padding without `String(format:)`, which pulls in locale
    /// machinery and is not fork-safe.
    private static func padded(_ value: UInt64, width: Int) -> String {
        let digits = String(value)
        guard digits.count < width else { return digits }
        return String(repeating: "0", count: width - digits.count) + digits
    }

    /// The manifest `segments[].file` form, `wal/<name>` (wal.md §7).
    public var manifestFile: String { "wal/" + fileName }

    public func url(in directory: URL) -> URL {
        // Constructed from the path string: `URL.appendingPathComponent` is not
        // fork-safe on Darwin (it may abort in a forked child).
        URL(fileURLWithPath: directory.path + "/" + fileName)
    }

    public static func < (lhs: WALSegmentName, rhs: WALSegmentName) -> Bool {
        if lhs.epoch != rhs.epoch { return lhs.epoch < rhs.epoch }
        return lhs.segment < rhs.segment
    }
}

// MARK: - Manifest (wal.md §7)

/// One `segments[]` entry of `manifest.json`.
public struct ManifestSegment: Codable, Equatable, Sendable {
    public var file: String
    public var epoch: UInt64
    public var firstMseq: UInt64
    public var lastMseq: UInt64

    public init(file: String, epoch: UInt64, firstMseq: UInt64, lastMseq: UInt64) {
        self.file = file
        self.epoch = epoch
        self.firstMseq = firstMseq
        self.lastMseq = lastMseq
    }

    enum CodingKeys: String, CodingKey {
        case file
        case epoch
        case firstMseq = "first_mseq"
        case lastMseq = "last_mseq"
    }
}

/// The WAL checkpoint of wal.md §7, validated by schema/manifest.schema.json.
public struct Manifest: Codable, Equatable, Sendable {
    public static let currentFormat = 1

    public var format: Int
    public var bootID: String
    public var materializedUptoMseq: UInt64
    public var lastMseq: UInt64
    public var lastDurableEpoch: UInt64
    public var segments: [ManifestSegment]

    public init(format: Int = Manifest.currentFormat,
                bootID: String,
                materializedUptoMseq: UInt64,
                lastMseq: UInt64,
                lastDurableEpoch: UInt64,
                segments: [ManifestSegment]) {
        self.format = format
        self.bootID = bootID
        self.materializedUptoMseq = materializedUptoMseq
        self.lastMseq = lastMseq
        self.lastDurableEpoch = lastDurableEpoch
        self.segments = segments
    }

    enum CodingKeys: String, CodingKey {
        case format
        case bootID = "boot_id"
        case materializedUptoMseq = "materialized_upto_mseq"
        case lastMseq = "last_mseq"
        case lastDurableEpoch = "last_durable_epoch"
        case segments
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Manifest {
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw LogError.corrupt("manifest.json is not valid")
        }
        guard manifest.format == Manifest.currentFormat else {
            throw LogError.corrupt("manifest format \(manifest.format) is not 1")
        }
        guard WireValidation.isValidBootID(manifest.bootID) else {
            throw LogError.corrupt("manifest boot_id is not 32 lowercase hex characters")
        }
        return manifest
    }
}

/// `manifest.json` of one workspace: atomic read and D18 atomic write.
public struct ManifestStore: Sendable {
    public let paths: WorkspacePaths

    public init(root: URL) {
        self.paths = WorkspacePaths(root: root)
    }

    public init(paths: WorkspacePaths) {
        self.paths = paths
    }

    /// Reads the manifest; `nil` when the file does not exist. A malformed
    /// file throws `LogError.corrupt`; recovery applies the missing-manifest
    /// rule (wal.md §7.2) to both.
    public func read() throws -> Manifest? {
        guard LogFile.exists(paths.manifestURL) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: paths.manifestURL, options: [.mappedIfSafe])
        } catch {
            throw LogError.corrupt("manifest.json is unreadable")
        }
        return try Manifest.decode(data)
    }

    /// `manifest.json.tmp` → fsync → rename → fsync directory (wal.md §7.1).
    public func write(_ manifest: Manifest) throws {
        let data = try manifest.encoded()
        try LogFile.atomicWrite(data,
                                to: paths.manifestURL,
                                temporaryURL: paths.manifestTemporaryURL)
    }
}

// MARK: - VFS metrics

/// Byte counts by the VFS prefixes the memory proxy reports (PLAN §2.5).
public struct WorkspaceLogMetrics: Equatable, Sendable {
    /// `/dsh/workspace/**`.
    public var workspaceBytes: Int
    /// `/dsh/home/sessions/**`.
    public var homeSessionsBytes: Int
    /// `/dsh/tmp/**`; volatile, never materialized, always 0 here.
    public var tmpBytes: Int
    /// `/dsh/home/**` outside `sessions/`.
    public var otherBytes: Int
    /// Bytes currently occupied by WAL segments including headers.
    public var walBytes: Int
    /// Bytes currently occupied by the journal file.
    public var journalBytes: Int

    public init(workspaceBytes: Int = 0,
                homeSessionsBytes: Int = 0,
                tmpBytes: Int = 0,
                otherBytes: Int = 0,
                walBytes: Int = 0,
                journalBytes: Int = 0) {
        self.workspaceBytes = workspaceBytes
        self.homeSessionsBytes = homeSessionsBytes
        self.tmpBytes = tmpBytes
        self.otherBytes = otherBytes
        self.walBytes = walBytes
        self.journalBytes = journalBytes
    }

    /// The logical VFS bytes the budget proxy compares with 150 MB (PLAN §2.5).
    public var totalVFSBytes: Int {
        workspaceBytes + homeSessionsBytes + tmpBytes + otherBytes
    }

    /// Bare metric for one prefix of the memory proxy.
    public func bytes(forPrefix prefix: String) -> Int {
        switch prefix {
        case "/dsh/workspace": return workspaceBytes
        case "/dsh/home/sessions": return homeSessionsBytes
        case "/dsh/tmp": return tmpBytes
        default: return otherBytes
        }
    }
}

// MARK: - Acknowledgement broadcaster

/// Fan-out of cumulative acks to any number of observers.
///
/// `WorkspaceLogging.acks()` is synchronous in the W0 protocol, so the stream
/// factory cannot be actor-isolated. The broadcaster is lock-protected and the
/// actor only calls `yield`.
///
/// Cumulative acks are state snapshots: a subscriber that starts after an
/// append must still learn the current watermark instead of waiting for the
/// next append or epoch close. When `replayLimit > 0` the most recent
/// `replayLimit` elements are retained and replayed to every new subscriber
/// before any later live element (the replay happens under the same lock that
/// registers the continuation, so ordering is preserved).
final class AckBroadcaster<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var replayBuffer: [Element] = []
    private let replayLimit: Int
    private var finished = false

    init(replayLimit: Int = 0) {
        self.replayLimit = max(0, replayLimit)
    }

    func stream(bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded)
        -> AsyncStream<Element> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            let identifier = UUID()
            lock.lock()
            if finished {
                lock.unlock()
                continuation.finish()
                return
            }
            continuations[identifier] = continuation
            for element in replayBuffer {
                continuation.yield(element)
            }
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: identifier)
                self.lock.unlock()
            }
        }
    }

    func yield(_ element: Element) {
        lock.lock()
        if replayLimit > 0 {
            replayBuffer.append(element)
            if replayBuffer.count > replayLimit {
                replayBuffer.removeFirst(replayBuffer.count - replayLimit)
            }
        }
        let targets = Array(continuations.values)
        lock.unlock()
        for target in targets {
            target.yield(element)
        }
    }

    func finish() {
        lock.lock()
        finished = true
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for target in targets {
            target.finish()
        }
    }
}

// MARK: - POSIX file helpers

/// Small POSIX layer shared by the WAL, journal, materializer and overlay.
enum LogFile {
    static func ensureDirectory(_ url: URL, mode: mode_t = 0o755) throws {
        let path = url.path
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw LogError.materializationFailed("expected a directory at a workspace path")
            }
            return
        }
        do {
            try FileManager.default.createDirectory(at: url,
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: mode])
        } catch {
            throw LogError.materializationFailed("cannot create a workspace directory")
        }
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func size(_ url: URL) throws -> Int {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw LogError.posix(operation: "lstat", code: errno)
        }
        return Int(info.st_size)
    }

    static func readAll(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw LogError.posix(operation: "read", code: EIO)
        }
    }

    static func open(_ url: URL, flags: Int32, mode: mode_t = 0o644) throws -> Int32 {
        let descriptor = url.path.withCString { Darwin.open($0, flags, mode) }
        guard descriptor >= 0 else {
            throw LogError.posix(operation: "open", code: errno)
        }
        return descriptor
    }

    static func writeAll(fd: Int32, data: Data) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw LogError.posix(operation: "write", code: errno)
                }
                offset += written
            }
        }
    }

    static func fsync(fd: Int32) throws {
        guard Darwin.fsync(fd) == 0 else {
            throw LogError.posix(operation: "fsync", code: errno)
        }
    }

    /// `F_FULLFSYNC`: the level-2 durability primitive of D7/D18.
    static func fullFsync(fd: Int32) throws {
        guard fcntl(fd, F_FULLFSYNC) == 0 else {
            throw LogError.posix(operation: "F_FULLFSYNC", code: errno)
        }
    }

    static func fullFsync(url: URL) throws {
        let descriptor = try open(url, flags: O_WRONLY)
        defer { Darwin.close(descriptor) }
        try fullFsync(fd: descriptor)
    }

    static func fsyncDirectory(_ url: URL) throws {
        var descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY) }
        if descriptor < 0 {
            descriptor = url.path.withCString { Darwin.open($0, O_RDONLY) }
        }
        guard descriptor >= 0 else {
            throw LogError.posix(operation: "open directory", code: errno)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw LogError.posix(operation: "fsync directory", code: errno)
        }
    }

    static func truncate(_ url: URL, to size: Int) throws {
        let descriptor = try open(url, flags: O_WRONLY)
        defer { Darwin.close(descriptor) }
        guard Darwin.ftruncate(descriptor, off_t(size)) == 0 else {
            throw LogError.posix(operation: "ftruncate", code: errno)
        }
        try fsync(fd: descriptor)
    }

    static func unlink(_ url: URL) throws {
        guard url.path.withCString({ Darwin.unlink($0) }) == 0 || errno == ENOENT else {
            throw LogError.posix(operation: "unlink", code: errno)
        }
    }

    static func rename(_ from: URL, to destination: URL) throws {
        let result = from.path.withCString { source in
            destination.path.withCString { target in
                Darwin.rename(source, target)
            }
        }
        guard result == 0 else {
            throw LogError.posix(operation: "rename", code: errno)
        }
    }

    /// Writes `data` to `temporaryURL`, fsyncs it, renames it over `url`, then
    /// fsyncs the containing directory (wal.md §7.1). `mode` is the temporary
    /// file mode; the recovery backup passes 0600 so a preimage is never
    /// group/world readable, even before the rename.
    static func atomicWrite(_ data: Data,
                            to url: URL,
                            temporaryURL: URL? = nil,
                            mode: mode_t = 0o644) throws {
        let temporary = temporaryURL ?? url.appendingPathExtension("tmp")
        try ensureDirectory(url.deletingLastPathComponent())
        let descriptor = try open(temporary, flags: O_WRONLY | O_CREAT | O_TRUNC, mode: mode)
        do {
            guard fchmod(descriptor, mode) == 0 else {
                throw LogError.posix(operation: "fchmod", code: errno)
            }
            try writeAll(fd: descriptor, data: data)
            try fsync(fd: descriptor)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        Darwin.close(descriptor)
        try rename(temporary, to: url)
        try fsyncDirectory(url.deletingLastPathComponent())
    }

    /// POSIX `mkdir -p` under `url`; returns the directories actually created.
    @discardableResult
    static func createDirectoryTree(_ url: URL, mode: mode_t = 0o755) throws -> [URL] {
        var missing: [URL] = []
        var cursor = url
        while !FileManager.default.fileExists(atPath: cursor.path) {
            missing.append(cursor)
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }
        for directory in missing.reversed() {
            do {
                try FileManager.default.createDirectory(at: directory,
                                                        withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: mode])
            } catch {
                // A concurrent creator or a path that appeared is fine.
                if !FileManager.default.fileExists(atPath: directory.path) {
                    throw LogError.materializationFailed("cannot create a directory")
                }
            }
        }
        return missing.reversed()
    }

    static func removeTree(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw LogError.materializationFailed("cannot remove a materialized path")
        }
    }

    static func copyTree(_ from: URL, to destination: URL) throws {
        try removeTree(destination)
        do {
            try FileManager.default.copyItem(at: from, to: destination)
        } catch {
            throw LogError.materializationFailed("cannot copy the materialized tree")
        }
    }

    static func fileMode(_ url: URL) throws -> mode_t {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw LogError.posix(operation: "lstat", code: errno)
        }
        return info.st_mode & mode_t(0o7777)
    }

    static func isDirectory(_ url: URL) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw LogError.posix(operation: "lstat", code: errno)
        }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    static func isRegularFile(_ url: URL) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw LogError.posix(operation: "lstat", code: errno)
        }
        return (info.st_mode & S_IFMT) == S_IFREG
    }

    static func setMode(_ url: URL, mode: mode_t) throws {
        guard url.path.withCString({ Darwin.chmod($0, mode) }) == 0 else {
            throw LogError.posix(operation: "chmod", code: errno)
        }
    }

    /// `realpath(3)` form of a path; used to compare enumerator URLs with the
    /// workspace root on macOS, where `/var` is reported as `/private/var`.
    static func canonicalPath(_ url: URL) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if url.path.withCString({ Darwin.realpath($0, &buffer) }) != nil {
            return String(cString: buffer)
        }
        return url.path
    }

    static func currentTimeMilliseconds() -> UInt64 {
        let seconds = Date().timeIntervalSince1970
        return UInt64(max(0, seconds) * 1000)
    }
}

// MARK: - Big-endian byte cursors (module-internal; the W0 helpers are internal
// to PhoneDSHWire and WAL bodies are opaque here).

extension Data {
    mutating func appendUInt16BigEndian(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt32BigEndian(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt64BigEndian(_ value: UInt64) {
        append(UInt8((value >> 56) & 0xFF))
        append(UInt8((value >> 48) & 0xFF))
        append(UInt8((value >> 40) & 0xFF))
        append(UInt8((value >> 32) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    func uint8BigEndian(at offset: Int) -> UInt8 {
        self[index(startIndex, offsetBy: offset)]
    }

    func uint32BigEndian(at offset: Int) -> UInt32 {
        (UInt32(uint8BigEndian(at: offset)) << 24) |
            (UInt32(uint8BigEndian(at: offset + 1)) << 16) |
            (UInt32(uint8BigEndian(at: offset + 2)) << 8) |
            UInt32(uint8BigEndian(at: offset + 3))
    }

    func uint64BigEndian(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(uint8BigEndian(at: offset + index))
        }
        return value
    }
}

// MARK: - SHA-256 (used by the reconcile snapshot comparison)

/// Minimal SHA-256 (FIPS 180-4), lowercase hex output. The host already links
/// no crypto provider for the workspace log; reconcile only needs a digest of
/// caller-supplied bytes.
public enum SHA256 {
    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
        0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
        0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
        0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
        0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    /// Lowercase hex digest of `data`.
    public static func hash(_ data: Data) -> String {
        var state: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }

        var schedule = [UInt32](repeating: 0, count: 64)
        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            for index in 0..<16 {
                let offset = chunkStart + index * 4
                schedule[index] = (UInt32(message[offset]) << 24)
                    | (UInt32(message[offset + 1]) << 16)
                    | (UInt32(message[offset + 2]) << 8)
                    | UInt32(message[offset + 3])
            }
            for index in 16..<64 {
                let s0 = rotateRight(schedule[index - 15], by: 7)
                    ^ rotateRight(schedule[index - 15], by: 18)
                    ^ (schedule[index - 15] >> 3)
                let s1 = rotateRight(schedule[index - 2], by: 17)
                    ^ rotateRight(schedule[index - 2], by: 19)
                    ^ (schedule[index - 2] >> 10)
                schedule[index] = schedule[index - 16] &+ s0
                    &+ schedule[index - 7] &+ s1
            }

            var a = state[0], b = state[1], c = state[2], d = state[3]
            var e = state[4], f = state[5], g = state[6], h = state[7]
            for index in 0..<64 {
                let s1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
                let choose = (e & f) ^ (~e & g)
                let temp1 = h &+ s1 &+ choose &+ roundConstants[index] &+ schedule[index]
                let s0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ majority
                h = g; g = f; f = e; e = d &+ temp1
                d = c; c = b; b = a; a = temp1 &+ temp2
            }
            state[0] = state[0] &+ a
            state[1] = state[1] &+ b
            state[2] = state[2] &+ c
            state[3] = state[3] &+ d
            state[4] = state[4] &+ e
            state[5] = state[5] &+ f
            state[6] = state[6] &+ g
            state[7] = state[7] &+ h
        }
        return state.map { String(format: "%08x", $0) }.joined()
    }

    /// Streaming digest for large trees.
    public final class Hasher {
        private var buffer = Data()
        private var state: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        private var byteCount: UInt64 = 0
        private var schedule = [UInt32](repeating: 0, count: 64)

        public init() {}

        public func update(_ data: Data) {
            byteCount &+= UInt64(data.count)
            buffer.append(data)
            consume(force: false)
        }

        public var hexDigest: String {
            var tail = buffer
            let bitLength = byteCount * 8
            tail.append(0x80)
            while tail.count % 64 != 56 { tail.append(0) }
            for shift in stride(from: 56, through: 0, by: -8) {
                tail.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
            }
            let savedBuffer = buffer
            buffer = tail
            consume(force: true)
            buffer = savedBuffer
            return state.map { String(format: "%08x", $0) }.joined()
        }

        private func consume(force: Bool) {
            var offset = 0
            while buffer.count - offset >= 64 {
                process(buffer, offset: offset)
                offset += 64
            }
            if offset > 0 {
                buffer = Data(buffer.dropFirst(offset))
            }
        }

        private func process(_ bytes: Data, offset: Int) {
            for index in 0..<16 {
                let base = offset + index * 4
                schedule[index] = (UInt32(bytes[bytes.index(bytes.startIndex, offsetBy: base)]) << 24)
                    | (UInt32(bytes[bytes.index(bytes.startIndex, offsetBy: base + 1)]) << 16)
                    | (UInt32(bytes[bytes.index(bytes.startIndex, offsetBy: base + 2)]) << 8)
                    | UInt32(bytes[bytes.index(bytes.startIndex, offsetBy: base + 3)])
            }
            for index in 16..<64 {
                let s0 = rotateRight(schedule[index - 15], by: 7)
                    ^ rotateRight(schedule[index - 15], by: 18)
                    ^ (schedule[index - 15] >> 3)
                let s1 = rotateRight(schedule[index - 2], by: 17)
                    ^ rotateRight(schedule[index - 2], by: 19)
                    ^ (schedule[index - 2] >> 10)
                schedule[index] = schedule[index - 16] &+ s0
                    &+ schedule[index - 7] &+ s1
            }
            var a = state[0], b = state[1], c = state[2], d = state[3]
            var e = state[4], f = state[5], g = state[6], h = state[7]
            for index in 0..<64 {
                let s1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
                let choose = (e & f) ^ (~e & g)
                let temp1 = h &+ s1 &+ choose &+ roundConstants[index] &+ schedule[index]
                let s0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ majority
                h = g; g = f; f = e; e = d &+ temp1
                d = c; c = b; b = a; a = temp1 &+ temp2
            }
            state[0] = state[0] &+ a
            state[1] = state[1] &+ b
            state[2] = state[2] &+ c
            state[3] = state[3] &+ d
            state[4] = state[4] &+ e
            state[5] = state[5] &+ f
            state[6] = state[6] &+ g
            state[7] = state[7] &+ h
        }
    }

    private static func rotateRight(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }

    /// Hashes a file by streaming it in bounded chunks.
    public static func hashFile(_ url: URL) throws -> String {
        let hasher = Hasher()
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw LogError.posix(operation: "open", code: EIO)
        }
        defer { try? handle.close() }
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 256 * 1024)
            } catch {
                throw LogError.posix(operation: "read", code: EIO)
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(chunk)
        }
        return hasher.hexDigest
    }
}
