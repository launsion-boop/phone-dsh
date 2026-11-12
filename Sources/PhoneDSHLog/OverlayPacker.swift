// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLog: the boot overlay packer.
//
// PLAN §2.3, D21 and spec/v1/wal.md §8. The overlay is a gzip member
// that inflates to a POSIX (ustar) archive whose entries are only
// `home/...` and `workspace/...`: directories and regular files with their
// modes. `/dsh/tmp`, the WAL, the manifest and the step records never appear.
// Symlinks are rejected because the worker VFS has no symlink model.
//
// D21 supersedes the earlier "uncompressed tar overlay": the pinned runtime's
// `storage/image-gzip` inflates every image and overlay as a gzip member, so
// the tar bytes are wrapped in gzip here. The manifest and mseq contracts do
// not change.
//
// The gzip member is assembled from independent raw-DEFLATE fragments (one per
// tar entry) so a warm boot only recompresses files whose lstat identity
// changed. The system zlib is the only compressor; no package is added. The
// decompressed ustar stays byte-identical to the pre-D21 packer.
//
// One bounded `overlay-compose` line per pack makes the tree composition and
// the fragment-cache hit visible in `boot-timings.log`: the walk that already
// feeds the archive also rolls file bytes up to the top-level directories, so
// no second filesystem pass is added.

import Darwin
import Foundation
import zlib

/// Result of writing an overlay to a file.
public struct OverlayPackResult: Equatable, Sendable {
    public var url: URL
    public var byteCount: Int
    public var entryCount: Int

    public init(url: URL, byteCount: Int, entryCount: Int) {
        self.url = url
        self.byteCount = byteCount
        self.entryCount = entryCount
    }
}

/// Composition of one boot-overlay pack, reported once through the boot log.
///
/// `bytes` is the sum of the regular files' source bytes, `entries` counts every
/// ustar entry (directories included) and `files` only regular files. `top` is
/// the three largest top-level directories below `home/` or `workspace/`,
/// ordered by bytes descending (name ascending on a tie). `unchanged` counts
/// files whose cached DEFLATE fragment was reused and `reused_bytes` is their
/// source-byte total, so `reused_bytes / bytes` is the byte hit rate; the cold
/// path reports both as zero.
struct OverlayComposition: Equatable, Sendable {
    struct TopDirectory: Equatable, Sendable {
        var directory: String
        var bytes: Int
    }

    var bytes: Int
    var entries: Int
    var topDirectories: [TopDirectory]
    var files: Int
    var unchanged: Int
    var reusedBytes: Int

    /// `overlay-compose bytes=<n> entries=<n> top=<dir>:<bytes>,... files=<n>
    /// unchanged=<n> reused_bytes=<n>` — one line, at most three directories.
    var line: String {
        let top = topDirectories
            .map { "\($0.directory):\($0.bytes)" }
            .joined(separator: ",")
        return "overlay-compose bytes=\(bytes) entries=\(entries) top=\(top) "
            + "files=\(files) unchanged=\(unchanged) reused_bytes=\(reusedBytes)"
    }
}

/// Packs `materialized/{home,workspace}` as a deterministic gzip-compressed tar
/// (wal.md §8, D21).
public struct OverlayPacker: Sendable {
    /// Root that contains `home/` and `workspace/`.
    public let materializedDirectory: URL

    /// Optional per-file fragment cache directory. `nil` keeps the public
    /// in-memory behaviour: every entry is freshly compressed.
    private let fragmentCacheDirectory: URL?
    private let diagnostics: OverlayFragmentCacheDiagnostics?

    public init(materializedDirectory: URL) {
        self.materializedDirectory = materializedDirectory
        self.fragmentCacheDirectory = nil
        self.diagnostics = Self.defaultDiagnostics(for: materializedDirectory)
    }

    /// Convenience initializer for a workspace root.
    public init(root: URL) {
        let materializedDirectory = WorkspacePaths(root: root).materializedDirectory
        self.materializedDirectory = materializedDirectory
        self.fragmentCacheDirectory = nil
        self.diagnostics = Self.defaultDiagnostics(for: materializedDirectory)
    }

    /// Internal initializer used by `WorkspaceLog` (durable cache) and by the
    /// incremental-overlay tests (cache plus a recompression counter).
    init(materializedDirectory: URL,
         fragmentCacheDirectory: URL?,
         diagnostics: OverlayFragmentCacheDiagnostics? = nil) {
        self.materializedDirectory = materializedDirectory
        self.fragmentCacheDirectory = fragmentCacheDirectory
        self.diagnostics = diagnostics ?? Self.defaultDiagnostics(for: materializedDirectory)
    }

    init(root: URL,
         fragmentCacheDirectory: URL?,
         diagnostics: OverlayFragmentCacheDiagnostics? = nil) {
        let materializedDirectory = WorkspacePaths(root: root).materializedDirectory
        self.materializedDirectory = materializedDirectory
        self.fragmentCacheDirectory = fragmentCacheDirectory
        self.diagnostics = diagnostics ?? Self.defaultDiagnostics(for: materializedDirectory)
    }

    /// The public packer reports through the same `boot-timings.log` the host
    /// already owns. The log sits beside the workspace root, so a failure to
    /// append can never fail the pack.
    private static func defaultDiagnostics(for materializedDirectory: URL)
        -> OverlayFragmentCacheDiagnostics {
        let bootLog = materializedDirectory.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("boot-timings.log")
        return OverlayFragmentCacheDiagnostics(sink: { line in
            LogFile.appendLine(line, to: bootLog)
        })
    }

    /// Returns the complete gzip-compressed overlay bytes (D21).
    public func data() throws -> Data {
        var result = Data()
        try forEachGzippedChunk { chunk in
            result.append(chunk)
        }
        return result
    }

    /// Returns the uncompressed ustar bytes that ``data()`` wraps.
    ///
    /// Kept internal for the D21 assertions: the tar inside the gzip member
    /// must stay byte-identical to the pre-D21 overlay.
    func tarData() throws -> Data {
        var result = Data()
        try forEachChunk { chunk in
            result.append(chunk)
        }
        return result
    }

    /// Streams the gzip-compressed overlay (header, DEFLATE chunks, trailer).
    public func stream() -> AsyncThrowingStream<Data, Error> {
        let directory = materializedDirectory
        let cacheDirectory = fragmentCacheDirectory
        let diagnostics = self.diagnostics
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                do {
                    _ = try OverlayPacker(materializedDirectory: directory,
                                          fragmentCacheDirectory: cacheDirectory,
                                          diagnostics: diagnostics)
                        .forEachGzippedChunk { chunk in
                            continuation.yield(chunk)
                        }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Writes the gzip-compressed overlay to `url` through a temporary file and
    /// a rename.
    public func pack(to url: URL) throws -> OverlayPackResult {
        try pack(to: url, gzip: true)
    }

    /// Writes the same deterministic ustar **without** the D21 gzip wrapper.
    ///
    /// The D15 handoff snapshot is a full uncompressed tar by contract
    /// (handoff.md §3), so it uses this path; only the boot overlay is gzip
    /// (D21).
    public func packUncompressed(to url: URL) throws -> OverlayPackResult {
        try pack(to: url, gzip: false)
    }

    private func pack(to url: URL, gzip: Bool) throws -> OverlayPackResult {
        let directory = url.deletingLastPathComponent()
        try LogFile.ensureDirectory(directory)
        let temporary = directory.appendingPathComponent(".overlay-\(getpid()).tmp")
        try LogFile.unlink(temporary)
        let descriptor = try LogFile.open(temporary,
                                          flags: O_WRONLY | O_CREAT | O_TRUNC,
                                          mode: 0o644)
        var byteCount = 0
        var entryCount = 0
        do {
            if gzip {
                entryCount = try forEachGzippedChunk { chunk in
                    try LogFile.writeAll(fd: descriptor, data: chunk)
                    byteCount += chunk.count
                }
            } else {
                entryCount = try forEachChunk { chunk in
                    try LogFile.writeAll(fd: descriptor, data: chunk)
                    byteCount += chunk.count
                }
            }
            try LogFile.fsync(fd: descriptor)
        } catch {
            Darwin.close(descriptor)
            try? LogFile.unlink(temporary)
            throw error
        }
        Darwin.close(descriptor)
        try LogFile.rename(temporary, to: url)
        try LogFile.fsyncDirectory(directory)
        return OverlayPackResult(url: url, byteCount: byteCount, entryCount: entryCount)
    }

    /// Number of tar entries without building the archive.
    public func entryCount() throws -> Int {
        try entries().count
    }

    // MARK: - Entry enumeration

    private struct Entry {
        var name: String
        var mode: mode_t
        var size: Int
        var isDirectory: Bool
        var url: URL?
        var mtimeSec: Int64 = 0
        var mtimeNsec: Int64 = 0
        var ctimeSec: Int64 = 0
        var ctimeNsec: Int64 = 0
        var inode: UInt64 = 0

        /// The lstat identity that makes a cached fragment reusable. Files are
        /// content-addressed by metadata, not by rereading them: a change to
        /// size, mtime, ctime or inode is a miss and recompresses one file.
        var fragmentKey: OverlayFragmentKey {
            OverlayFragmentKey(path: name,
                               size: Int64(size),
                               mtimeSec: mtimeSec,
                               mtimeNsec: mtimeNsec,
                               ctimeSec: ctimeSec,
                               ctimeNsec: ctimeNsec,
                               inode: inode)
        }
    }

    private func entries() throws -> [Entry] {
        var result: [Entry] = []
        for root in ["home", "workspace"] {
            let rootURL = materializedDirectory.appendingPathComponent(root, isDirectory: true)
            var info = stat()
            guard lstat(rootURL.path, &info) == 0 else { continue }
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                throw LogError.materializationFailed("overlay root is not a directory")
            }
            result.append(Entry(name: root + "/",
                                mode: info.st_mode & mode_t(0o7777),
                                size: 0,
                                isDirectory: true,
                                url: nil))
            try appendEntries(of: rootURL, prefix: root, into: &result)
        }
        return result
    }

    private func appendEntries(of directory: URL, prefix: String, into result: inout [Entry]) throws {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names.sorted() {
            let url = directory.appendingPathComponent(name)
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                throw LogError.materializationFailed("overlay entry vanished during packing")
            }
            let kind = info.st_mode & S_IFMT
            let entryName = prefix + "/" + name
            switch kind {
            case S_IFLNK:
                throw LogError.overlaySymlink("/dsh/" + entryName)
            case S_IFDIR:
                result.append(Entry(name: entryName + "/",
                                    mode: info.st_mode & mode_t(0o7777),
                                    size: 0,
                                    isDirectory: true,
                                    url: nil))
                try appendEntries(of: url, prefix: entryName, into: &result)
            case S_IFREG:
                result.append(Entry(name: entryName,
                                    mode: info.st_mode & mode_t(0o7777),
                                    size: Int(info.st_size),
                                    isDirectory: false,
                                    url: url,
                                    mtimeSec: Int64(info.st_mtimespec.tv_sec),
                                    mtimeNsec: Int64(info.st_mtimespec.tv_nsec),
                                    ctimeSec: Int64(info.st_ctimespec.tv_sec),
                                    ctimeNsec: Int64(info.st_ctimespec.tv_nsec),
                                    inode: UInt64(info.st_ino)))
            default:
                throw LogError.materializationFailed("overlay entry is not a file or directory")
            }
        }
    }

    // MARK: - Gzip encoding (D21)

    /// Emits one gzip member assembled from one independent raw-DEFLATE
    /// fragment per tar entry, then the 1024 zero bytes, the final empty block
    /// and the CRC-32/ISIZE trailer.
    ///
    /// A fragment starts a fresh zlib stream and ends with Z_SYNC_FLUSH, so no
    /// back-reference crosses a fragment and concatenation is a valid DEFLATE
    /// stream. The decompressed tar is byte-identical to ``forEachChunk``.
    @discardableResult
    private func forEachGzippedChunk(_ body: (Data) throws -> Void) throws -> Int {
        let entries = try entries()
        let cache: OverlayFragmentCache?
        if let directory = fragmentCacheDirectory {
            let created = OverlayFragmentCache(directory: directory,
                                               diagnostics: diagnostics)
            created.prepare()
            cache = created
        } else {
            cache = nil
        }

        try body(OverlayZlib.gzipHeader)
        var totalLength: UInt64 = 0
        var checksum: uLong = 0
        var fileCount = 0
        var sourceBytes = 0
        var unchangedFiles = 0
        var reusedBytes = 0

        for entry in entries {
            let header = try tarHeader(for: entry)
            if entry.isDirectory {
                let fragment = try OverlayZlib.deflate([header])
                try body(fragment)
                totalLength &+= 512
                checksum = OverlayZlib.combine(checksum,
                                               OverlayZlib.crc32(header),
                                               length: 512)
                continue
            }
            guard let url = entry.url else {
                throw LogError.materializationFailed("overlay entry has no file")
            }
            fileCount += 1
            sourceBytes += entry.size
            let key = entry.fragmentKey
            if let cached = cache?.fragment(for: key) {
                try body(cached.bytes)
                totalLength &+= UInt64(cached.uncompressedLength)
                checksum = OverlayZlib.combine(checksum,
                                               uLong(cached.crc),
                                               length: cached.uncompressedLength)
                unchangedFiles += 1
                reusedBytes += entry.size
                continue
            }

            let data = try LogFile.readAll(url)
            guard data.count == entry.size else {
                throw LogError.materializationFailed("overlay file changed during packing")
            }
            try verifyUnchanged(entry, url: url)
            let remainder = data.count % 512
            let padding = remainder == 0 ? Data() : Data(count: 512 - remainder)
            var chunks = [header, data]
            if !padding.isEmpty { chunks.append(padding) }
            let uncompressedLength = 512 + data.count + padding.count
            let crc = UInt32(truncatingIfNeeded: OverlayZlib.crc32(chunks))
            let fragment = try OverlayZlib.deflate(chunks)
            diagnostics?.recordRecompression()
            cache?.store(fragment,
                         uncompressedLength: uncompressedLength,
                         crc: crc,
                         for: key)
            try body(fragment)
            totalLength &+= UInt64(uncompressedLength)
            checksum = OverlayZlib.combine(checksum,
                                           uLong(crc),
                                           length: uncompressedLength)
        }

        // The tar's 1024-byte zero trailer is itself a fragment, followed by
        // the BFINAL block that closes the concatenation.
        let zeros = Data(count: 1024)
        let zeroFragment = try OverlayZlib.deflate([zeros])
        try body(zeroFragment)
        totalLength &+= 1024
        checksum = OverlayZlib.combine(checksum,
                                       OverlayZlib.crc32(zeros),
                                       length: 1024)
        try body(OverlayZlib.finalEmptyBlock)
        try body(OverlayZlib.gzipTrailer(crc: checksum, size: totalLength))
        if let diagnostics {
            // Everything here comes from the walk above; there is no second
            // pass over the materialized tree.
            let composition = OverlayComposition(
                bytes: sourceBytes,
                entries: entries.count,
                topDirectories: Self.topDirectories(from: entries),
                files: fileCount,
                unchanged: unchangedFiles,
                reusedBytes: reusedBytes)
            diagnostics.recordComposition(composition)
        }
        cache?.finish()
        return entries.count
    }

    /// Rolls file bytes up to the first directory below `home/` or `workspace/`
    /// and returns the three largest. Files directly under either root are not
    /// part of a directory rollup. Names are bounded/sanitized so one hostile
    /// path cannot break the single log line or make it unbounded.
    private static func topDirectories(from entries: [Entry]) -> [OverlayComposition.TopDirectory] {
        var rollup: [String: Int] = [:]
        for entry in entries where !entry.isDirectory {
            let parts = entry.name.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  parts[0] == "home" || parts[0] == "workspace" else { continue }
            let directory = "\(parts[0])/\(parts[1])"
            rollup[directory, default: 0] += entry.size
        }
        return rollup
            .filter { $0.value > 0 }
            .sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }
            .prefix(3)
            .map {
                OverlayComposition.TopDirectory(directory: boundedLogToken($0.key),
                                                bytes: $0.value)
            }
    }

    private static func boundedLogToken(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/@+")
        var sanitized = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            sanitized.append(allowed.contains(scalar)
                ? scalar
                : UnicodeScalar(UInt8(ascii: "_")))
        }
        let text = String(sanitized)
        return text.count <= 80 ? text : String(text.prefix(80))
    }

    /// The cache key comes from the lstat performed by ``entries()``. If the
    /// file changed while it was read, its cached fragment would be filed
    /// under stale metadata; fail loud just like the size check.
    private func verifyUnchanged(_ entry: Entry, url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw LogError.materializationFailed("overlay entry vanished during packing")
        }
        guard Int(info.st_size) == entry.size,
              Int64(info.st_mtimespec.tv_sec) == entry.mtimeSec,
              Int64(info.st_mtimespec.tv_nsec) == entry.mtimeNsec,
              Int64(info.st_ctimespec.tv_sec) == entry.ctimeSec,
              Int64(info.st_ctimespec.tv_nsec) == entry.ctimeNsec,
              UInt64(info.st_ino) == entry.inode else {
            throw LogError.materializationFailed("overlay file changed during packing")
        }
    }

    // MARK: - Tar encoding

    @discardableResult
    private func forEachChunk(_ body: (Data) throws -> Void) throws -> Int {
        let entries = try entries()
        for entry in entries {
            try body(tarHeader(for: entry))
            if let url = entry.url {
                let data = try LogFile.readAll(url)
                guard data.count == entry.size else {
                    throw LogError.materializationFailed("overlay file changed during packing")
                }
                try body(data)
                let remainder = data.count % 512
                if remainder != 0 {
                    try body(Data(count: 512 - remainder))
                }
            }
        }
        try body(Data(count: 1024))
        return entries.count
    }

    private func tarHeader(for entry: Entry) throws -> Data {
        var header = [UInt8](repeating: 0, count: 512)
        let (prefix, name) = try splitName(entry.name)
        writeField(name, into: &header, offset: 0, length: 100)
        writeOctal(UInt64(entry.mode), into: &header, offset: 100, length: 8)
        writeOctal(0, into: &header, offset: 108, length: 8) // uid
        writeOctal(0, into: &header, offset: 116, length: 8) // gid
        writeOctal(UInt64(entry.size), into: &header, offset: 124, length: 12)
        writeOctal(0, into: &header, offset: 136, length: 12) // mtime
        for index in 148..<156 { header[index] = 0x20 } // checksum placeholder
        header[156] = entry.isDirectory ? UInt8(ascii: "5") : UInt8(ascii: "0")
        writeField("ustar", into: &header, offset: 257, length: 6)
        header[263] = UInt8(ascii: "0")
        header[264] = UInt8(ascii: "0")
        if let prefix {
            writeField(prefix, into: &header, offset: 345, length: 155)
        }
        let checksum = header.reduce(UInt32(0)) { $0 &+ UInt32($1) }
        let octal = String(format: "%06o", checksum)
        for (index, byte) in Array(octal.utf8).enumerated() where index < 6 {
            header[148 + index] = byte
        }
        header[154] = 0
        header[155] = 0x20
        return Data(header)
    }

    /// ustar name/prefix split: `name` ≤ 100 bytes, `prefix` ≤ 155 bytes.
    private func splitName(_ name: String) throws -> (prefix: String?, name: String) {
        let bytes = Array(name.utf8)
        if bytes.count <= 100 {
            return (nil, name)
        }
        var split: Int?
        for index in stride(from: bytes.count - 1, through: 1, by: -1) {
            guard bytes[index - 1] == UInt8(ascii: "/") else { continue }
            let prefixCount = index - 1
            let nameCount = bytes.count - index
            if prefixCount <= 155 && nameCount <= 100 && prefixCount > 0 {
                split = index
                break
            }
        }
        guard let split else {
            throw LogError.overlayPathTooLong(name)
        }
        let prefix = String(decoding: bytes[0..<(split - 1)], as: UTF8.self)
        let remainder = String(decoding: bytes[split...], as: UTF8.self)
        return (prefix, remainder)
    }

    private func writeField(_ value: String, into header: inout [UInt8],
                            offset: Int, length: Int) {
        let bytes = Array(value.utf8)
        for index in 0..<min(bytes.count, length) {
            header[offset + index] = bytes[index]
        }
    }

    private func writeOctal(_ value: UInt64, into header: inout [UInt8],
                            offset: Int, length: Int) {
        let digits = String(value, radix: 8)
        let padded = String(repeating: "0", count: max(0, length - 1 - digits.count)) + digits
        let bytes = Array(padded.utf8)
        for index in 0..<min(bytes.count, length - 1) {
            header[offset + index] = bytes[index]
        }
        header[offset + length - 1] = 0
    }
}
