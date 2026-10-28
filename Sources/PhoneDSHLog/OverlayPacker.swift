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
// not change. Only the system Compression framework is used (no new package).

import Compression
import Darwin
import Foundation

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

/// Packs `materialized/{home,workspace}` as a deterministic gzip-compressed tar
/// (wal.md §8, D21).
public struct OverlayPacker: Sendable {
    /// Root that contains `home/` and `workspace/`.
    public let materializedDirectory: URL

    public init(materializedDirectory: URL) {
        self.materializedDirectory = materializedDirectory
    }

    /// Convenience initializer for a workspace root.
    public init(root: URL) {
        self.materializedDirectory = WorkspacePaths(root: root).materializedDirectory
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
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                do {
                    _ = try OverlayPacker(materializedDirectory: directory).forEachGzippedChunk { chunk in
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
                                    url: url))
            default:
                throw LogError.materializationFailed("overlay entry is not a file or directory")
            }
        }
    }

    // MARK: - Gzip encoding (D21)

    /// Emits one gzip member: fixed header, the same tar chunks as the
    /// pre-D21 packer, then the CRC32/ISIZE trailer.
    ///
    /// One chunk is held back so the encoder can mark the last tar chunk as
    /// `COMPRESSION_STREAM_FINALIZE`; nothing else about the tar changes.
    @discardableResult
    private func forEachGzippedChunk(_ body: (Data) throws -> Void) throws -> Int {
        let encoder = try GzipEncoder()
        try body(encoder.header)
        var pending: Data?
        let count = try forEachChunk { chunk in
            if let previous = pending {
                let encoded = try encoder.encode(previous, final: false)
                if encoded.isEmpty == false { try body(encoded) }
            }
            pending = chunk
        }
        if let last = pending {
            let encoded = try encoder.encode(last, final: true)
            if encoded.isEmpty == false { try body(encoded) }
        }
        try body(encoder.trailer())
        return count
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

// MARK: - Streaming gzip encoder (D21)

/// Streaming gzip encoder over the system Compression framework.
///
/// The overlay is exactly one gzip member. The header is fixed (mtime 0, no
/// file name, OS 255) so packing the same tree twice yields identical bytes;
/// the trailer carries the RFC 1952 CRC-32 and ISIZE of the uncompressed tar.
private final class GzipEncoder {
    private static let outputCapacity = 64 * 1024
    /// RFC 1952 header: magic, DEFLATE, no flags, mtime 0, no extra flags,
    /// OS = unknown (255).
    private static let headerBytes: [UInt8] = [
        0x1f, 0x8b, 0x08, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0xff,
    ]

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var entry = UInt32(index)
        for _ in 0..<8 {
            entry = (entry & 1) == 1
                ? (entry >> 1) ^ 0xEDB8_8320
                : entry >> 1
        }
        return entry
    }

    private var stream: compression_stream
    private let output: UnsafeMutablePointer<UInt8>
    private var streamInitialized = false
    private var checksum: UInt32 = 0xffff_ffff
    private var uncompressedSize: UInt32 = 0
    private var finalized = false

    init() throws {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.outputCapacity)
        self.output = buffer
        self.stream = compression_stream(dst_ptr: buffer,
                                         dst_size: Self.outputCapacity,
                                         src_ptr: UnsafePointer(buffer),
                                         src_size: 0,
                                         state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE,
                                      COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw LogError.materializationFailed("the system compressor could not start")
        }
        streamInitialized = true
        stream.dst_ptr = output
        stream.dst_size = Self.outputCapacity
    }

    deinit {
        if streamInitialized {
            compression_stream_destroy(&stream)
        }
        output.deallocate()
    }

    /// The fixed gzip header.
    var header: Data { Data(Self.headerBytes) }

    /// Compresses one tar chunk. `final` must be set on the last chunk only.
    func encode(_ input: Data, final: Bool) throws -> Data {
        guard !finalized else {
            throw LogError.materializationFailed("the overlay compressor is already finalized")
        }
        updateChecksum(input)
        var encoded = Data()
        if input.isEmpty {
            try encodeBuffer(UnsafePointer(output), count: 0, final: final, into: &encoded)
            return encoded
        }
        try input.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            try encodeBuffer(base, count: raw.count, final: final, into: &encoded)
        }
        return encoded
    }

    /// The gzip trailer: CRC-32 and ISIZE, both little-endian.
    func trailer() throws -> Data {
        guard finalized else {
            throw LogError.materializationFailed("the overlay compressor did not finish")
        }
        var trailer = Data()
        appendLittleEndian(checksum ^ 0xffff_ffff, to: &trailer)
        appendLittleEndian(uncompressedSize, to: &trailer)
        return trailer
    }

    // MARK: Internals

    private func encodeBuffer(_ first: UnsafePointer<UInt8>, count: Int,
                              final: Bool, into encoded: inout Data) throws {
        var source = first
        var remaining = count
        let flags = final ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
        var iterations = 0
        while true {
            iterations += 1
            guard iterations <= 1_000_000 else {
                throw LogError.materializationFailed("overlay DEFLATE made no progress")
            }
            stream.src_ptr = source
            stream.src_size = remaining
            let status = compression_stream_process(&stream, flags)
            let consumed = remaining - stream.src_size
            source = source.advanced(by: consumed)
            remaining -= consumed
            let produced = Self.outputCapacity - stream.dst_size
            if produced > 0 {
                encoded.append(output, count: produced)
                stream.dst_ptr = output
                stream.dst_size = Self.outputCapacity
            }
            switch status {
            case COMPRESSION_STATUS_END:
                finalized = true
                return
            case COMPRESSION_STATUS_OK:
                if remaining > 0 { continue }
                if final { continue }
                // A full destination buffer can still hide pending output.
                if produced == Self.outputCapacity { continue }
                return
            default:
                throw LogError.materializationFailed("overlay DEFLATE failed")
            }
        }
    }

    private func updateChecksum(_ data: Data) {
        uncompressedSize &+= UInt32(truncatingIfNeeded: data.count)
        var value = checksum
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                value = Self.crcTable[Int((value ^ UInt32(byte)) & 0xff)] ^ (value >> 8)
            }
        }
        checksum = value
    }

    private func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
