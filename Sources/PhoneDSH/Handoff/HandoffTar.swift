// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: uncompressed ustar codec.
//
// PLAN §2.5 (D15) and spec/v1/handoff.md §3–§5. The snapshot payload
// is the log module's overlay tar; the segment payloads are ustar archives
// whose only entries are complete `wal/*.xlwal` segment files. This file owns
// the small deterministic ustar writer/reader used for the segment archives
// and the segment writer seam that the golden vectors pin.

import Darwin
import Foundation
import PhoneDSHLog
import PhoneDSHWire

/// One entry of a ustar archive produced or consumed by the handoff path.
public struct HandoffTarEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case file
        case directory
    }

    /// Archive-relative name (`home/...`, `workspace/...` or `wal/...`).
    public var name: String
    public var mode: mode_t
    public var kind: Kind
    /// File bytes; empty for directories.
    public var data: Data

    public init(name: String, mode: mode_t = 0o644, kind: Kind = .file,
                data: Data = Data()) {
        self.name = name
        self.mode = mode
        self.kind = kind
        self.data = data
    }
}

/// Minimal deterministic ustar (POSIX.1-1988) encoder/decoder. No compression,
/// no PAX headers and no symlinks (the VFS has no symlink model).
public enum HandoffTar {
    public static let headerBytes = 512
    public static let trailerBytes = 1024

    // MARK: Encoding

    /// Encodes the entries into one in-memory archive.
    public static func encode(_ entries: [HandoffTarEntry]) throws -> Data {
        var output = Data()
        for entry in entries {
            try append(entry, to: &output)
        }
        output.append(Data(count: trailerBytes))
        return output
    }

    /// Streams the archive into `url` through a temporary file (`fsync`,
    /// rename, `fsync` directory).
    @discardableResult
    public static func write(_ entries: [HandoffTarEntry], to url: URL) throws -> Int {
        let directory = url.deletingLastPathComponent()
        try HandoffFile.ensureDirectory(directory)
        let temporary = directory.appendingPathComponent(".handoff-tar-\(UUID().uuidString)")
        try HandoffFile.unlink(temporary)
        var byteCount = 0
        do {
            try HandoffFile.writeAtomically(path: temporary) { handle in
                for entry in entries {
                    var chunk = Data()
                    try append(entry, to: &chunk)
                    try handle.write(contentsOf: chunk)
                    byteCount += chunk.count
                }
                let trailer = Data(count: trailerBytes)
                try handle.write(contentsOf: trailer)
                byteCount += trailer.count
            }
            try HandoffFile.rename(temporary, to: url)
            try HandoffFile.fsyncDirectory(directory)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return byteCount
    }

    private static func append(_ entry: HandoffTarEntry, to output: inout Data) throws {
        guard isSafeRelativeName(entry.name) else {
            throw HandoffError.badRequest("tar entry name is not a safe relative path")
        }
        let name = entry.kind == .directory && !entry.name.hasSuffix("/")
            ? entry.name + "/"
            : entry.name
        output.append(try header(name: name, entry: entry))
        if entry.kind == .file {
            output.append(entry.data)
            let remainder = entry.data.count % headerBytes
            if remainder != 0 {
                output.append(Data(count: headerBytes - remainder))
            }
        }
    }

    private static func header(name: String, entry: HandoffTarEntry) throws -> Data {
        var header = [UInt8](repeating: 0, count: headerBytes)
        let (prefix, shortName) = try splitName(name)
        writeField(shortName, into: &header, offset: 0, length: 100)
        writeOctal(UInt64(entry.mode & 0o7777), into: &header, offset: 100, length: 8)
        writeOctal(0, into: &header, offset: 108, length: 8)
        writeOctal(0, into: &header, offset: 116, length: 8)
        writeOctal(UInt64(entry.data.count), into: &header, offset: 124, length: 12)
        writeOctal(0, into: &header, offset: 136, length: 12)
        for index in 148..<156 { header[index] = 0x20 }
        header[156] = entry.kind == .directory ? UInt8(ascii: "5") : UInt8(ascii: "0")
        writeField("ustar", into: &header, offset: 257, length: 6)
        header[263] = UInt8(ascii: "0")
        header[264] = UInt8(ascii: "0")
        if let prefix {
            writeField(prefix, into: &header, offset: 345, length: 155)
        }
        let checksum = header.reduce(UInt32(0)) { $0 &+ UInt32($1) }
        let octal = String(checksum, radix: 8)
        let padded = String(repeating: "0", count: max(0, 6 - octal.count)) + octal
        for (index, byte) in Array(padded.utf8).enumerated() where index < 6 {
            header[148 + index] = byte
        }
        header[154] = 0
        header[155] = 0x20
        return Data(header)
    }

    private static func splitName(_ name: String) throws -> (prefix: String?, name: String) {
        let bytes = Array(name.utf8)
        if bytes.count <= 100 { return (nil, name) }
        var split: Int?
        for index in stride(from: bytes.count - 1, through: 1, by: -1) where bytes[index - 1] == 47 {
            let prefixCount = index - 1
            let nameCount = bytes.count - index
            if prefixCount > 0, prefixCount <= 155, nameCount <= 100 {
                split = index
                break
            }
        }
        guard let split else {
            throw HandoffError.badRequest("tar entry name exceeds the ustar fields")
        }
        let prefix = String(decoding: bytes[0..<(split - 1)], as: UTF8.self)
        let remainder = String(decoding: bytes[split...], as: UTF8.self)
        return (prefix, remainder)
    }

    private static func writeField(_ value: String, into header: inout [UInt8],
                                   offset: Int, length: Int) {
        let bytes = Array(value.utf8)
        for index in 0..<min(bytes.count, length) {
            header[offset + index] = bytes[index]
        }
    }

    private static func writeOctal(_ value: UInt64, into header: inout [UInt8],
                                   offset: Int, length: Int) {
        let digits = String(value, radix: 8)
        let padded = String(repeating: "0", count: max(0, length - 1 - digits.count)) + digits
        let bytes = Array(padded.utf8)
        for index in 0..<min(bytes.count, length - 1) {
            header[offset + index] = bytes[index]
        }
        header[offset + length - 1] = 0
    }

    // MARK: Decoding

    /// Parses one archive. Any unsupported entry type, unsafe name, duplicate
    /// name, bad checksum or truncated data is an error: a payload that the
    /// phone or the remote cannot apply atomically is never partially used.
    public static func decode(_ data: Data) throws -> [HandoffTarEntry] {
        let bytes = [UInt8](data)
        var entries: [HandoffTarEntry] = []
        var seen: Set<String> = []
        var offset = 0
        while offset + headerBytes <= bytes.count {
            let header = Array(bytes[offset..<(offset + headerBytes)])
            if header.allSatisfy({ $0 == 0 }) { break }
            try verifyChecksum(header)
            let name = try stringField(header, offset: 0, length: 100)
            let prefix = try stringField(header, offset: 345, length: 155)
            let fullName = prefix.isEmpty ? name : prefix + "/" + name
            guard isSafeRelativeName(fullName) else {
                throw HandoffError.payloadMismatch("tar entry name is unsafe")
            }
            let mode = try octalField(header, offset: 100, length: 8)
            let size = try octalField(header, offset: 124, length: 12)
            let type = header[156]
            guard type == UInt8(ascii: "0") || type == UInt8(ascii: "5") else {
                throw HandoffError.payloadMismatch("tar entry type is not a file or directory")
            }
            guard !seen.contains(fullName) else {
                throw HandoffError.payloadMismatch("duplicate tar entry")
            }
            seen.insert(fullName)
            offset += headerBytes
            if type == UInt8(ascii: "5") {
                guard size == 0 else {
                    throw HandoffError.payloadMismatch("tar directory carries data")
                }
                entries.append(HandoffTarEntry(name: fullName, mode: mode_t(mode),
                                               kind: .directory))
                continue
            }
            let sizeInt = Int(size)
            guard sizeInt >= 0, offset + sizeInt <= bytes.count else {
                throw HandoffError.payloadMismatch("tar entry data is truncated")
            }
            let payload = Data(bytes[offset..<(offset + sizeInt)])
            entries.append(HandoffTarEntry(name: fullName, mode: mode_t(mode),
                                           kind: .file, data: payload))
            offset += sizeInt
            let remainder = sizeInt % headerBytes
            if remainder != 0 { offset += headerBytes - remainder }
        }
        return entries
    }

    /// Reads and parses one archive file.
    public static func read(from url: URL) throws -> [HandoffTarEntry] {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw HandoffError.badRequest("handoff tar is unreadable")
        }
        return try decode(data)
    }

    /// A path is safe when it is relative, slash-separated, and has no empty,
    /// `.` or `..` component. The tar is unpacked only below a staging root.
    public static func isSafeRelativeName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/") else { return false }
        let trimmed = name.hasSuffix("/") ? String(name.dropLast()) : name
        guard !trimmed.isEmpty else { return false }
        for component in trimmed.split(separator: "/", omittingEmptySubsequences: false) {
            guard !component.isEmpty, component != ".", component != ".." else {
                return false
            }
        }
        return true
    }

    private static func verifyChecksum(_ header: [UInt8]) throws {
        let stored = try octalField(header, offset: 148, length: 8)
        var sum: UInt32 = 0
        for (index, byte) in header.enumerated() {
            sum &+= UInt32(index >= 148 && index < 156 ? 0x20 : byte)
        }
        guard UInt64(sum) == stored else {
            throw HandoffError.payloadMismatch("tar header checksum mismatch")
        }
    }

    private static func stringField(_ header: [UInt8], offset: Int, length: Int)
        throws -> String {
        let slice = header[offset..<(offset + length)].prefix { $0 != 0 }
        guard !slice.contains(0) else {
            throw HandoffError.payloadMismatch("tar header contains a NUL in a string field")
        }
        return String(decoding: slice, as: UTF8.self)
    }

    private static func octalField(_ header: [UInt8], offset: Int, length: Int)
        throws -> UInt64 {
        let slice = header[offset..<(offset + length)].prefix { $0 != 0 }
        var value: UInt64 = 0
        var sawDigit = false
        for byte in slice {
            if byte == 0x20 { continue }
            guard byte >= 48, byte <= 55 else {
                throw HandoffError.payloadMismatch("tar header field is not octal")
            }
            sawDigit = true
            value = (value << 3) | UInt64(byte - 48)
        }
        guard sawDigit else { return 0 }
        return value
    }
}

// MARK: - Segment writer

/// One complete WAL segment file as it travels in a handoff archive.
public struct HandoffSegmentFile: Equatable, Sendable {
    /// `wal/<epoch:08d>.<segment:06d>.xlwal`.
    public var file: String
    public var bytes: Data

    public init(file: String, bytes: Data) throws {
        guard HandoffSegmentDescriptor.isValidFileName(file) else {
            throw HandoffError.badRequest("segment file name is invalid")
        }
        self.file = file
        self.bytes = bytes
    }

    /// The descriptor of this file, computed from the WAL header and records.
    public func descriptor() throws -> HandoffSegmentDescriptor {
        let segment = try Self.segment(bytes: bytes)
        let mutations = segment.records.filter { !$0.isEpochClose }
        guard let last = mutations.map(\.mseq).max() else {
            throw HandoffError.badRequest("a handoff segment carries no mutation record")
        }
        let descriptor = HandoffSegmentDescriptor(file: file,
                                                  firstMseq: segment.header.firstMseq,
                                                  lastMseq: last,
                                                  bytes: UInt64(bytes.count))
        try descriptor.validate()
        return descriptor
    }

    /// Decodes and verifies every header/record CRC of the segment.
    public func segment() throws -> WALSegment {
        try Self.segment(bytes: bytes)
    }

    private static func segment(bytes: Data) throws -> WALSegment {
        do {
            return try WALSegment.decode(bytes)
        } catch {
            throw HandoffError.payloadMismatch("WAL segment header or record CRC mismatch")
        }
    }
}

/// The Swift segment writer seam. The golden vectors pin its bytes against
/// `spec/v1/golden/wal`: `encode` reproduces the gold
/// `file_hex` byte for byte.
public enum HandoffSegmentWriter {
    /// Encodes one complete WAL segment (header + records).
    public static func encode(firstMseq: UInt64, bootID: Data,
                              records: [WALRecord]) throws -> Data {
        do {
            let header = try WALSegmentHeader(firstMseq: firstMseq, bootID: bootID)
            return try WALSegment(header: header, records: records).encoded()
        } catch let error as HandoffError {
            throw error
        } catch {
            throw HandoffError.badRequest("cannot encode a WAL segment")
        }
    }

    /// Re-encodes one segment file, verifying its records.
    public static func encode(segmentAt url: URL) throws -> Data {
        let segment: WALSegmentFile
        do {
            segment = try WALReader.segment(at: url)
        } catch {
            throw HandoffError.payloadMismatch("WAL segment cannot be read")
        }
        return try encode(firstMseq: segment.header.firstMseq,
                          bootID: segment.header.bootID,
                          records: segment.records)
    }

    /// Builds one uncompressed tar of complete `wal/...` files.
    public static func archive(_ files: [HandoffSegmentFile]) throws -> Data {
        var entries: [HandoffTarEntry] = []
        var seen: Set<String> = []
        for file in files {
            guard seen.insert(file.file).inserted else {
                throw HandoffError.badRequest("duplicate segment file")
            }
            _ = try file.descriptor()
            entries.append(HandoffTarEntry(name: file.file, data: file.bytes))
        }
        return try HandoffTar.encode(entries)
    }

    /// Streams the segment archive to disk and returns its byte count.
    @discardableResult
    public static func writeArchive(_ files: [HandoffSegmentFile], to url: URL) throws -> Int {
        var entries: [HandoffTarEntry] = []
        var seen: Set<String> = []
        for file in files {
            guard seen.insert(file.file).inserted else {
                throw HandoffError.badRequest("duplicate segment file")
            }
            _ = try file.descriptor()
            entries.append(HandoffTarEntry(name: file.file, data: file.bytes))
        }
        return try HandoffTar.write(entries, to: url)
    }
}

/// Reads and validates the segment archives of §4/§5.
public enum HandoffSegmentArchive {
    /// Parses the tar; the only entries are `wal/*.xlwal` files.
    public static func decode(_ data: Data) throws -> [HandoffSegmentFile] {
        try decode(try HandoffTar.decode(data))
    }

    /// Parses already-decoded tar entries; the only entries are
    /// `wal/*.xlwal` files.
    public static func decode(_ entries: [HandoffTarEntry]) throws -> [HandoffSegmentFile] {
        var files: [HandoffSegmentFile] = []
        for entry in entries {
            guard entry.kind == .file,
                  HandoffSegmentDescriptor.isValidFileName(entry.name) else {
                throw HandoffError.payloadMismatch(
                    "segments payload contains an entry that is not a WAL segment")
            }
            files.append(try HandoffSegmentFile(file: entry.name, bytes: entry.data))
        }
        return files
    }

    public static func read(from url: URL) throws -> [HandoffSegmentFile] {
        try decode(HandoffTar.read(from: url))
    }

    /// Checks the descriptors of the request against the tar entries and
    /// returns the files ordered by their first mutation mseq.
    public static func validate(files: [HandoffSegmentFile],
                                descriptors: [HandoffSegmentDescriptor])
        throws -> [(descriptor: HandoffSegmentDescriptor, segment: WALSegment)] {
        guard files.count == descriptors.count else {
            throw HandoffError.payloadMismatch(
                "segment descriptors and payload entries have different counts")
        }
        var byName: [String: HandoffSegmentFile] = [:]
        for file in files {
            guard byName.updateValue(file, forKey: file.file) == nil else {
                throw HandoffError.payloadMismatch("duplicate segment payload entry")
            }
        }
        var validated: [(descriptor: HandoffSegmentDescriptor, segment: WALSegment)] = []
        for rawDescriptor in descriptors {
            try rawDescriptor.validate()
            guard let file = byName.removeValue(forKey: rawDescriptor.file) else {
                throw HandoffError.payloadMismatch(
                    "segment descriptor has no payload entry")
            }
            let segment: WALSegment
            do {
                segment = try file.segment()
            } catch {
                throw HandoffError.payloadMismatch("segment header or record CRC mismatch")
            }
            let mutations = segment.records.filter { !$0.isEpochClose }
            let last = mutations.map(\.mseq).max() ?? 0
            guard UInt64(file.bytes.count) == rawDescriptor.bytes,
                  segment.header.firstMseq == rawDescriptor.firstMseq,
                  last == rawDescriptor.lastMseq else {
                throw HandoffError.payloadMismatch(
                    "segment descriptor does not match its payload bytes")
            }
            validated.append((descriptor: rawDescriptor, segment: segment))
        }
        guard byName.isEmpty else {
            throw HandoffError.payloadMismatch("segment payload has an undeclared entry")
        }
        return validated.sorted { $0.descriptor.firstMseq < $1.descriptor.firstMseq }
    }

    /// Validates the mutation ranges of §4: contiguous from `base + 1` to
    /// `walSeq`, no gap and nothing above `walSeq`; a segment may begin at or
    /// below the base and is then replayed idempotently by the remote.
    public static func mutationRecords(
        _ validated: [(descriptor: HandoffSegmentDescriptor, segment: WALSegment)],
        baseMseq: UInt64, walSeq: UInt64
    ) throws -> [WALRecord] {
        var records: [WALRecord] = []
        var expected = baseMseq + 1
        for (_, segment) in validated {
            for record in segment.records where !record.isEpochClose {
                if record.mseq <= baseMseq { continue }
                guard record.mseq == expected else {
                    throw HandoffError.segmentContinuity(
                        "expected mseq \(expected), got \(record.mseq)")
                }
                guard record.mseq <= walSeq else {
                    throw HandoffError.segmentContinuity(
                        "mseq \(record.mseq) is above wal_seq \(walSeq)")
                }
                records.append(record)
                expected += 1
            }
        }
        guard expected == walSeq + 1 else {
            throw HandoffError.segmentContinuity(
                "segments do not cover (\(baseMseq), \(walSeq)]")
        }
        return records
    }
}

// MARK: - File helpers

enum HandoffFile {
    static func ensureDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url,
                                                    withIntermediateDirectories: true)
        } catch {
            throw HandoffError.applyFailed("cannot create a handoff directory")
        }
    }

    static func unlink(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw HandoffError.applyFailed("cannot remove a handoff file")
        }
    }

    static func rename(_ from: URL, to destination: URL) throws {
        guard from.path.withCString({ source in
            destination.path.withCString { target in Darwin.rename(source, target) }
        }) == 0 else {
            throw HandoffError.applyFailed("cannot rename a handoff file")
        }
    }

    static func fsyncDirectory(_ url: URL) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else {
            throw HandoffError.applyFailed("cannot open a handoff directory")
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw HandoffError.applyFailed("cannot fsync a handoff directory")
        }
    }

    static func fullFsync(_ url: URL) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_WRONLY) }
        guard descriptor >= 0 else {
            throw HandoffError.applyFailed("cannot open a handoff file")
        }
        defer { Darwin.close(descriptor) }
        guard fcntl(descriptor, F_FULLFSYNC) == 0 else {
            throw HandoffError.applyFailed("F_FULLFSYNC failed for a handoff file")
        }
    }

    /// Writes a file through `temporary` + fsync; the caller renames it.
    static func writeAtomically(path: URL, body: (FileHandle) throws -> Void) throws {
        let descriptor = path.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        }
        guard descriptor >= 0 else {
            throw HandoffError.applyFailed("cannot create a handoff file")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            try body(handle)
            guard Darwin.fsync(descriptor) == 0 else {
                throw HandoffError.applyFailed("cannot fsync a handoff file")
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        Darwin.close(descriptor)
    }

    static func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw HandoffError.applyFailed("cannot write a handoff file")
        }
    }

    static func fileSize(_ url: URL) throws -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes?[.size] as? NSNumber)?.intValue else {
            throw HandoffError.badRequest("handoff file is missing")
        }
        return size
    }

    static func currentTimeMilliseconds() -> UInt64 {
        UInt64(max(0, Date().timeIntervalSince1970) * 1000)
    }
}
