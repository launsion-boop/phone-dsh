// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLog: the W6 content-addressed blob store.
//
// spec/v1/wal.md §14.1/§14.5. A blob is one mutation's `data`, named by the
// lowercase SHA-256 of its exact bytes and stored at
// `blobs/sha256/<first two hex digits>/<sha256>`, mode 0600. Blobs are
// immutable: never rewritten in place, never truncated, never chmod-ed, only
// ever renamed from a temporary file in the same shard directory. There is no
// manifest member and no ref-count file: the WAL is the single reference
// source, so the live set is derived from retained blob-write records.

import Darwin
import Foundation
import PhoneDSHWire

/// One stored blob: its lowercase hex digest, raw digest bytes and length.
public struct BlobRef: Equatable, Sendable {
    public var sha256: String
    public var digestBytes: Data
    public var byteCount: Int

    public init(sha256: String, digestBytes: Data, byteCount: Int) {
        self.sha256 = sha256
        self.digestBytes = digestBytes
        self.byteCount = byteCount
    }
}

public extension WALRecord {
    /// Resolves one WAL record to the VFS mutation a replay applies.
    ///
    /// An inline mutation decodes exactly as before (byte-identical legacy
    /// behaviour). A §14.2 blob-write record is resolved from `store`, with its
    /// bytes verified, and returned as the pre-W6 inline write form at the same
    /// mseq. A missing, short or digest-mismatched blob throws the same
    /// `WAL_CORRUPT` (`LogError.corrupt`) the WAL reader uses; it is never
    /// reported as an empty body. The epoch-close record has no mutation body.
    func resolvedMutationBody(using store: WorkspaceBlobStore) throws -> VfsMutationBody {
        guard !isEpochClose else {
            throw LogError.corrupt("epoch-close record has no mutation body")
        }
        guard isBlobWrite else { return try mutationBody() }
        guard let blob = try blobWrite() else {
            throw LogError.corrupt("blob-write record did not decode")
        }
        let data = try store.read(digest: blob.sha256Hex,
                                  expectedLength: Int(blob.blobLength))
        return VfsMutationBody(op: .write,
                               mode: blob.mode,
                               mflags: blob.mflags,
                               appendFrom: blob.appendFrom,
                               path: blob.path,
                               data: data)
    }
}

/// The content-addressed store of `Library/xl/<workspace_id>/blobs/` (wal.md
/// §14.1). The type is a plain class: the WAL writer actor and the recovery
/// pass each own one; there is no cross-instance mutable state to race on.
public final class WorkspaceBlobStore {
    /// `<root>/blobs`.
    public let blobDirectory: URL
    /// `<root>/blobs/sha256`.
    public let shardRoot: URL

    /// Digests this instance created in this process boot. A later write of the
    /// same bytes verifies only the length for these (wal.md §14.1).
    private var createdThisBoot: Set<String> = []
    /// Blobs written since the last epoch close; §5.2 step 1 fsyncs them.
    private var writtenThisEpoch: Set<String> = []
    /// Shard directories that received a new blob this epoch; fsynced with the
    /// blobs so the rename itself is durable before the close record.
    private var dirtyShardDirectories: Set<String> = []
    private var temporaryCounter: UInt64 = 0

    public init(root: URL) {
        self.blobDirectory = root.appendingPathComponent("blobs", isDirectory: true)
        self.shardRoot = blobDirectory.appendingPathComponent("sha256", isDirectory: true)
    }

    public convenience init(paths: WorkspacePaths) {
        self.init(root: paths.root)
    }

    // MARK: - Layout

    /// `true` for a 64-character lowercase hex digest.
    public static func isValidDigest(_ digest: String) -> Bool {
        guard digest.count == 64 else { return false }
        return digest.allSatisfy { character in
            (character >= "0" && character <= "9") || (character >= "a" && character <= "f")
        }
    }

    /// The `sha256/<hh>` shard directory of a digest.
    public func shardDirectory(for digest: String) throws -> URL {
        guard Self.isValidDigest(digest) else {
            throw LogError.corrupt("blob digest is not 64 lowercase hex characters")
        }
        return shardRoot.appendingPathComponent(String(digest.prefix(2)), isDirectory: true)
    }

    /// The final path of a digest; it never changes for the same bytes.
    public func blobURL(for digest: String) throws -> URL {
        try shardDirectory(for: digest).appendingPathComponent(digest)
    }

    /// Raw bytes of a lowercase hex digest.
    static func digestBytes(_ digest: String) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(digest.count / 2)
        var index = digest.startIndex
        while index < digest.endIndex {
            let next = digest.index(index, offsetBy: 2)
            if let byte = UInt8(digest[index..<next], radix: 16) { bytes.append(byte) }
            index = next
        }
        return Data(bytes)
    }

    // MARK: - Write

    /// Writes `data` to its content address and returns the reference. An
    /// existing blob is never overwritten: it is length-checked (and
    /// digest-checked unless this instance created it in this boot) and reused.
    @discardableResult
    public func write(_ data: Data) throws -> BlobRef {
        guard !data.isEmpty else {
            throw LogError.corrupt("a blob-write record carries at least one byte")
        }
        guard data.count <= WireLimits.walBlobMaxBytes else {
            throw LogError.corrupt("a blob exceeds one mutation's 15 MiB")
        }
        let digest = SHA256.hash(data)
        let shard = try shardDirectory(for: digest)
        let finalURL = shard.appendingPathComponent(digest)

        if LogFile.exists(finalURL) {
            let existing = try LogFile.size(finalURL)
            guard existing == data.count else {
                throw LogError.corrupt(
                    "existing blob \(digest) is \(existing) bytes, expected \(data.count)")
            }
            if !createdThisBoot.contains(digest) {
                guard try SHA256.hashFile(finalURL) == digest else {
                    throw LogError.corrupt("existing blob \(digest) does not match its digest")
                }
            }
            createdThisBoot.insert(digest)
            return BlobRef(sha256: digest,
                           digestBytes: Self.digestBytes(digest),
                           byteCount: data.count)
        }

        try LogFile.ensureDirectory(shardRoot)
        try LogFile.ensureDirectory(shard)
        temporaryCounter &+= 1
        let temporary = shard.appendingPathComponent(
            ".pdsh-blob-\(getpid())-\(temporaryCounter)")
        try LogFile.unlink(temporary)
        let descriptor = try LogFile.open(temporary,
                                          flags: O_WRONLY | O_CREAT | O_TRUNC,
                                          mode: 0o600)
        do {
            try LogFile.writeAll(fd: descriptor, data: data)
        } catch {
            Darwin.close(descriptor)
            try? LogFile.unlink(temporary)
            throw error
        }
        Darwin.close(descriptor)
        do {
            try LogFile.rename(temporary, to: finalURL)
        } catch {
            try? LogFile.unlink(temporary)
            throw LogError.posix(operation: "rename blob", code: errno)
        }
        createdThisBoot.insert(digest)
        writtenThisEpoch.insert(digest)
        dirtyShardDirectories.insert(shard.path)
        return BlobRef(sha256: digest,
                       digestBytes: Self.digestBytes(digest),
                       byteCount: data.count)
    }

    // MARK: - Read / verify

    /// Verifies existence, length and (outside the creating boot) digest, and
    /// returns the blob URL. A failure is `WAL_CORRUPT` (`LogError.corrupt`).
    @discardableResult
    public func verifiedURL(digest: String, expectedLength: Int) throws -> URL {
        let url = try blobURL(for: digest)
        guard LogFile.exists(url), (try? LogFile.isRegularFile(url)) == true else {
            throw LogError.corrupt("blob \(digest) referenced by a retained record is missing")
        }
        let size = try LogFile.size(url)
        guard size == expectedLength else {
            throw LogError.corrupt(
                "blob \(digest) is \(size) bytes, its record names \(expectedLength)")
        }
        if !createdThisBoot.contains(digest) {
            guard try SHA256.hashFile(url) == digest else {
                throw LogError.corrupt("blob \(digest) does not match its digest")
            }
        }
        return url
    }

    /// Existence and length check without hashing the bytes. Recovery uses it
    /// for retained records at or below the materialized watermark, whose bytes
    /// are not replayed; a replayed record reads through ``verifiedURL`` and is
    /// digest-checked before it is applied (wal.md §14.5).
    @discardableResult
    public func verifyLength(digest: String, expectedLength: Int) throws -> URL {
        let url = try blobURL(for: digest)
        guard LogFile.exists(url), (try? LogFile.isRegularFile(url)) == true else {
            throw LogError.corrupt("blob \(digest) referenced by a retained record is missing")
        }
        let size = try LogFile.size(url)
        guard size == expectedLength else {
            throw LogError.corrupt(
                "blob \(digest) is \(size) bytes, its record names \(expectedLength)")
        }
        return url
    }

    /// Reads and verifies one blob. The materializer applies exactly these
    /// bytes (wal.md §14.5: verify before apply).
    public func read(digest: String, expectedLength: Int) throws -> Data {
        let url = try verifiedURL(digest: digest, expectedLength: expectedLength)
        return try LogFile.readAll(url)
    }

    // MARK: - Durability

    /// §5.2 step 1: fsync every blob written in this epoch and the shard
    /// directories that received them, before the close record of step 2.
    public func fsyncEpoch() throws {
        for digest in writtenThisEpoch.sorted() {
            guard let url = try? blobURL(for: digest), LogFile.exists(url) else { continue }
            let descriptor = try LogFile.open(url, flags: O_RDONLY)
            do {
                try LogFile.fsync(fd: descriptor)
            } catch {
                Darwin.close(descriptor)
                throw error
            }
            Darwin.close(descriptor)
        }
        for path in dirtyShardDirectories.sorted() {
            try LogFile.fsyncDirectory(URL(fileURLWithPath: path))
        }
        writtenThisEpoch.removeAll()
        dirtyShardDirectories.removeAll()
    }

    // MARK: - Reference and reclamation (wal.md §14.5)

    /// Size of the live blobs in `digests`. A missing file is not silently
    /// counted as zero: a retained record must have its blob.
    public func liveByteCount(digests: Set<String>) throws -> Int {
        var total = 0
        for digest in digests {
            let url = try blobURL(for: digest)
            guard LogFile.exists(url) else {
                throw LogError.corrupt("live blob \(digest) is missing")
            }
            total += try LogFile.size(url)
        }
        return total
    }

    /// Deletes every file in `blobs/sha256/**` that is not in `liveDigests`.
    /// Manifest-before-deletion is the caller's duty: it runs this only after
    /// the shorter manifest is durable and the referencing segments are gone.
    /// Returns the removed digests (temporary files are removed too, by path).
    @discardableResult
    public func collectGarbage(liveDigests: Set<String>) throws -> [String] {
        guard LogFile.exists(shardRoot) else { return [] }
        var removed: [String] = []
        var dirtyDirectories: Set<String> = []
        let shards = (try? FileManager.default.contentsOfDirectory(atPath: shardRoot.path)) ?? []
        for shardName in shards.sorted() {
            let shard = shardRoot.appendingPathComponent(shardName, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: shard.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: shard.path)) ?? []
            for entry in entries {
                let url = shard.appendingPathComponent(entry)
                guard (try? LogFile.isRegularFile(url)) == true else { continue }
                let keep = Self.isValidDigest(entry) && liveDigests.contains(entry)
                guard !keep else { continue }
                try LogFile.unlink(url)
                if Self.isValidDigest(entry) { removed.append(entry) }
                dirtyDirectories.insert(shard.path)
            }
        }
        for path in dirtyDirectories.sorted() {
            try LogFile.fsyncDirectory(URL(fileURLWithPath: path))
        }
        return removed.sorted()
    }
}
