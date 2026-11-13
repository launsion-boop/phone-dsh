// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLog: per-file DEFLATE fragment cache for the
// boot overlay (wal.md §8, D21).
//
// The overlay's contractual bytes are the *decompressed* ustar. That lets the
// gzip member be assembled from one independently compressed fragment per tar
// entry: a fragment never refers back into the previous one, so their raw
// DEFLATE streams concatenate. This cache keeps those fragments keyed by the
// lstat identity of the source file, so a boot only recompresses files that
// changed since the previous boot.
//
// Layout under `<workspace>/overlay-frags/`:
//   index.json          format version, zlib version and one entry per file
//   frag-<uuid>.bin     one raw-DEFLATE fragment
//
// Crash safety: fragments are written to a temporary file and renamed into
// place; `index.json` is replaced atomically afterwards. The index names the
// exact fragment file, length and CRC-32 it expects. A missing, truncated, or
// mismatching fragment invalidates the whole index (a full rebuild), so a torn
// cache can never contribute bytes to an overlay. Fragment data is deliberately
// not fsynced one file at a time (that would make a cold cache slower than the
// recompression it avoids); losing it to a crash is detected by the index
// length/CRC check. Orphaned fragment files are removed only after the new index
// is durable.

import Darwin
import Foundation

/// Identity of one materialized file. Any field changing invalidates its
/// fragment: the path, size, mtime/ctime with nanoseconds and inode come from
/// the lstat the overlay walk already performs.
struct OverlayFragmentKey: Codable, Equatable {
    var path: String
    var size: Int64
    var mtimeSec: Int64
    var mtimeNsec: Int64
    var ctimeSec: Int64
    var ctimeNsec: Int64
    var inode: UInt64
}

/// One cached fragment plus the metadata the gzip trailer needs.
struct OverlayFragment {
    var bytes: Data
    var uncompressedLength: Int
    var crc: UInt32
}

/// Counts fragments rebuilt versus reused and carries the one-line composition
/// summary to the boot log. Production installs the boot-log sink; the
/// incremental-overlay tests can inject their own sink and inspect
/// ``lastComposition``.
final class OverlayFragmentCacheDiagnostics: @unchecked Sendable {
    typealias Sink = @Sendable (String) -> Void

    private let lock = NSLock()
    private let sink: Sink?
    private var rebuilt = 0
    private var reused = 0
    private var composition: OverlayComposition?

    init(sink: Sink? = nil) {
        self.sink = sink
    }

    var recompressedFileCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return rebuilt
    }

    var reusedFileCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reused
    }

    /// The most recent pack's composition, or nil before the first pack.
    var lastComposition: OverlayComposition? {
        lock.lock()
        defer { lock.unlock() }
        return composition
    }

    func recordRecompression() {
        lock.lock()
        rebuilt += 1
        lock.unlock()
    }

    func recordReuse() {
        lock.lock()
        reused += 1
        lock.unlock()
    }

    /// Publishes the summary and emits exactly one line when a sink is
    /// installed. The sink runs outside the lock so a slow log append cannot
    /// serialize fragment-cache accounting.
    func recordComposition(_ summary: OverlayComposition) {
        lock.lock()
        composition = summary
        let sink = self.sink
        lock.unlock()
        sink?(summary.line)
    }
}

final class OverlayFragmentCache {
    static let directoryName = "overlay-frags"
    static let indexFileName = "index.json"
    static let fragmentPrefix = "frag-"
    static let fragmentSuffix = ".bin"
    /// Bump whenever the fragment encoding changes: a cache written by another
    /// encoder must not be mixed into a fresh overlay.
    private static let format = 1

    private struct Index: Codable {
        var format: Int
        var zlibVersion: String
        var entries: [Entry]
    }

    private struct Entry: Codable {
        var key: OverlayFragmentKey
        var file: String
        var compressedLength: Int
        var uncompressedLength: Int
        var crc: UInt32
        var compressedCRC: UInt32
    }

    private struct StoredFragment {
        var key: OverlayFragmentKey
        var file: String
        var bytes: Data
        var uncompressedLength: Int
        var crc: UInt32
        var compressedCRC: UInt32
    }

    private let directory: URL
    private let diagnostics: OverlayFragmentCacheDiagnostics?
    private var prepared = false
    private var entriesByPath: [String: StoredFragment] = [:]
    /// Fragments the current overlay build actually used. Writing only these
    /// drops entries for paths that no longer exist.
    private var used: [String: StoredFragment] = [:]

    init(directory: URL, diagnostics: OverlayFragmentCacheDiagnostics? = nil) {
        self.directory = directory
        self.diagnostics = diagnostics
    }

    // MARK: - Loading

    /// Creates the cache directory and loads a validated index. Every failure
    /// is non-fatal: the overlay still packs, just without cached fragments.
    func prepare() {
        do {
            try LogFile.ensureDirectory(directory)
        } catch {
            return
        }
        prepared = true
        load()
    }

    private var indexURL: URL {
        directory.appendingPathComponent(Self.indexFileName)
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(Index.self, from: data),
              index.format == Self.format,
              index.zlibVersion == OverlayZlib.version else {
            return
        }
        var loaded: [String: StoredFragment] = [:]
        for entry in index.entries {
            guard Self.isValidFragmentName(entry.file),
                  entry.compressedLength > 0,
                  entry.uncompressedLength >= 512,
                  entry.uncompressedLength % 512 == 0,
                  loaded[entry.key.path] == nil,
                  let bytes = try? Data(contentsOf: directory.appendingPathComponent(entry.file),
                                        options: [.mappedIfSafe]),
                  bytes.count == entry.compressedLength,
                  UInt32(truncatingIfNeeded: OverlayZlib.crc32(bytes)) == entry.compressedCRC else {
                // One bad fragment means the cache cannot be trusted at all:
                // ignore it and rebuild every fragment this boot.
                return
            }
            loaded[entry.key.path] = StoredFragment(
                key: entry.key,
                file: entry.file,
                bytes: bytes,
                uncompressedLength: entry.uncompressedLength,
                crc: entry.crc,
                compressedCRC: entry.compressedCRC)
        }
        entriesByPath = loaded
    }

    private static func isValidFragmentName(_ name: String) -> Bool {
        name.hasPrefix(fragmentPrefix)
            && name.hasSuffix(fragmentSuffix)
            && !name.contains("/")
            && !name.contains("..")
    }

    // MARK: - Lookup and storage

    /// Returns the validated fragment for `key` and marks its path as used.
    /// A mismatching key is a miss; the file is recompressed by the caller.
    func fragment(for key: OverlayFragmentKey) -> OverlayFragment? {
        guard let stored = entriesByPath[key.path], stored.key == key else {
            return nil
        }
        used[key.path] = stored
        diagnostics?.recordReuse()
        return OverlayFragment(bytes: stored.bytes,
                               uncompressedLength: stored.uncompressedLength,
                               crc: stored.crc)
    }

    /// Persists one freshly built fragment. Failures are ignored: the fragment
    /// in memory is still what the caller writes to the overlay.
    func store(_ bytes: Data, uncompressedLength: Int, crc: UInt32,
               for key: OverlayFragmentKey) {
        guard prepared else { return }
        let file = Self.fragmentPrefix + UUID().uuidString + Self.fragmentSuffix
        let target = directory.appendingPathComponent(file)
        let temporary = directory.appendingPathComponent(".frag-\(UUID().uuidString).tmp")
        let compressedCRC = UInt32(truncatingIfNeeded: OverlayZlib.crc32(bytes))
        do {
            let descriptor = try LogFile.open(temporary,
                                              flags: O_WRONLY | O_CREAT | O_TRUNC,
                                              mode: 0o644)
            do {
                try LogFile.writeAll(fd: descriptor, data: bytes)
            } catch {
                Darwin.close(descriptor)
                try? LogFile.unlink(temporary)
                return
            }
            Darwin.close(descriptor)
            do {
                try LogFile.rename(temporary, to: target)
            } catch {
                try? LogFile.unlink(temporary)
                return
            }
        } catch {
            try? LogFile.unlink(temporary)
            return
        }
        used[key.path] = StoredFragment(
            key: key,
            file: file,
            bytes: bytes,
            uncompressedLength: uncompressedLength,
            crc: crc,
            compressedCRC: compressedCRC)
    }

    // MARK: - Persisting

    /// Replaces the index and then removes fragment files no current path
    /// references. Must be called only after the overlay itself was written:
    /// until then the old index/fragments are still the last durable state.
    func finish() {
        guard prepared else { return }
        let entries = used.values
            .sorted { $0.key.path < $1.key.path }
            .map { stored in
                Entry(key: stored.key,
                      file: stored.file,
                      compressedLength: stored.bytes.count,
                      uncompressedLength: stored.uncompressedLength,
                      crc: stored.crc,
                      compressedCRC: stored.compressedCRC)
            }
        let index = Index(format: Self.format,
                          zlibVersion: OverlayZlib.version,
                          entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(index) else { return }
        do {
            // Publish the fragment names before an index can reference them.
            // If a crash loses a fragment's data instead, the load-time
            // length/CRC check rejects the index and rebuilds.
            try LogFile.fsyncDirectory(directory)
            try LogFile.atomicWrite(data, to: indexURL)
        } catch {
            return
        }
        removeUnreferencedFragments()
    }

    private func removeUnreferencedFragments() {
        let referenced = Set(used.values.map(\.file))
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: directory.path) else { return }
        for name in names {
            if name.hasPrefix(Self.fragmentPrefix) && name.hasSuffix(Self.fragmentSuffix) {
                if !referenced.contains(name) {
                    try? FileManager.default.removeItem(
                        at: directory.appendingPathComponent(name))
                }
            } else if name.hasPrefix(".frag-") && name.hasSuffix(".tmp") {
                try? FileManager.default.removeItem(
                    at: directory.appendingPathComponent(name))
            }
        }
    }
}
