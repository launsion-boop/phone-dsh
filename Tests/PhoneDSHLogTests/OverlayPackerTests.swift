// SPDX-License-Identifier: MIT
// OverlayPacker: gzip-wrapped ustar content (D21), ordering, exclusions,
// symlinks and determinism.

import Foundation
import XCTest
import zlib
@testable import PhoneDSHLog

final class OverlayPackerTests: XCTestCase {
    private func makeTree(_ test: XCTestCase) throws -> URL {
        let root = LogTestSupport.root(for: test)
        try WorkspacePaths(root: root).createDirectories()
        let paths = WorkspacePaths(root: root)
        try FileManager.default.createDirectory(
            at: paths.materializedHomeDirectory.appendingPathComponent("emptydir"),
            withIntermediateDirectories: true)
        try Data("hello\n".utf8).write(
            to: paths.materializedHomeDirectory.appendingPathComponent("notes.txt"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640],
            ofItemAtPath: paths.materializedHomeDirectory.appendingPathComponent("notes.txt").path)
        let sub = paths.materializedWorkspaceDirectory.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data([0x00, 0x01, 0x02, 0xFF]).write(
            to: sub.appendingPathComponent("data.bin"))
        return root
    }

    func testOverlayHasDeterministicVfsEntriesAndModes() throws {
        let root = try makeTree(self)
        let packer = OverlayPacker(root: root)
        let first = try packer.data()
        let second = try packer.data()
        XCTAssertEqual(first, second, "overlay packing must be deterministic")
        XCTAssertEqual([UInt8](first.prefix(2)), [0x1f, 0x8b],
                       "D21: the overlay is one gzip member")
        let tar = try GzipParser.decompress(first)
        XCTAssertEqual(tar, try packer.tarData(),
                       "D21: the tar inside the gzip member is byte-identical")

        let entries = try TarParser.parse(tar)
        XCTAssertEqual(entries.map(\.name), [
            "home/",
            "home/emptydir/",
            "home/notes.txt",
            "workspace/",
            "workspace/sub/",
            "workspace/sub/data.bin",
        ])
        XCTAssertEqual(entries.map(\.typeflag), ["5", "5", "0", "5", "5", "0"])
        let notes = try XCTUnwrap(entries.first { $0.name == "home/notes.txt" })
        XCTAssertEqual(notes.mode, 0o640)
        XCTAssertEqual(String(decoding: notes.data, as: UTF8.self), "hello\n")
        let binary = try XCTUnwrap(entries.first { $0.name == "workspace/sub/data.bin" })
        XCTAssertEqual([UInt8](binary.data), [0x00, 0x01, 0x02, 0xFF])
    }

    func testOverlayExcludesNonVfsRootsAndHiddenState() throws {
        let root = try makeTree(self)
        let paths = WorkspacePaths(root: root)
        try Data("outside".utf8).write(to: paths.materializedDirectory.appendingPathComponent("extra.txt"))
        try FileManager.default.createDirectory(
            at: paths.materializedDirectory.appendingPathComponent("tmp"),
            withIntermediateDirectories: true)
        try Data("volatile".utf8).write(
            to: paths.materializedDirectory.appendingPathComponent("tmp/scratch"))
        try Data("{}".utf8).write(to: paths.manifestURL)
        try Data("hidden".utf8).write(
            to: paths.materializedHomeDirectory.appendingPathComponent(".hidden"))

        let entries = try TarParser.parse(
            try GzipParser.decompress(try OverlayPacker(root: root).data()))
        let names = entries.map(\.name)
        XCTAssertFalse(names.contains { $0.contains("extra") })
        XCTAssertFalse(names.contains { $0.contains("tmp") })
        XCTAssertFalse(names.contains { $0.contains("manifest") })
        XCTAssertTrue(names.contains("home/.hidden"))
    }

    func testOverlayRejectsSymlinks() throws {
        let root = try makeTree(self)
        let link = WorkspacePaths(root: root).materializedHomeDirectory
            .appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path,
                                                   withDestinationPath: "/tmp")
        XCTAssertThrowsError(try OverlayPacker(root: root).data()) { error in
            guard case LogError.overlaySymlink = error else {
                return XCTFail("expected overlaySymlink, got \(error)")
            }
        }
    }

    func testOverlayStreamMatchesDataAndPacksToAFile() async throws {
        let root = try makeTree(self)
        let packer = OverlayPacker(root: root)
        let data = try packer.data()
        var streamed = Data()
        for try await chunk in packer.stream() {
            streamed.append(chunk)
        }
        XCTAssertEqual(streamed, data)

        let output = root.appendingPathComponent("overlay.tar")
        let result = try packer.pack(to: output)
        XCTAssertEqual(result.byteCount, data.count)
        XCTAssertEqual(result.entryCount, 6)
        XCTAssertEqual(try Data(contentsOf: output), data)
    }

    func testOverlayUsesPrefixForLongPaths() throws {
        let root = try makeTree(self)
        let paths = WorkspacePaths(root: root)
        var directory = paths.materializedWorkspaceDirectory
        for component in ["one-long-directory", "two-long-directory", "three-long-directory"] {
            directory.appendPathComponent(component)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let longName = String(repeating: "a", count: 90) + ".txt"
        try Data("long".utf8).write(to: directory.appendingPathComponent(longName))
        let entries = try TarParser.parse(
            try GzipParser.decompress(try OverlayPacker(root: root).data()))
        XCTAssertTrue(entries.contains { $0.name.hasSuffix(longName) })
        XCTAssertTrue(entries.allSatisfy { !$0.name.isEmpty })
    }

    func testGzipMemberIsDeterministicAndKeepsThePreD21Tar() throws {
        let root = try makeTree(self)
        let packer = OverlayPacker(root: root)
        let archive = try packer.data()
        // Fixed header: magic, DEFLATE, no flags/name and mtime 0.
        XCTAssertEqual(Array(archive.prefix(10)),
                       [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        let tar = try packer.tarData()
        XCTAssertEqual(try GzipParser.decompress(archive), tar)
        // The ustar structure and modes are exactly the pre-D21 bytes.
        let entries = try TarParser.parse(tar)
        XCTAssertEqual(entries.map(\.name), [
            "home/",
            "home/emptydir/",
            "home/notes.txt",
            "workspace/",
            "workspace/sub/",
            "workspace/sub/data.bin",
        ])
        XCTAssertEqual(entries.first { $0.name == "home/notes.txt" }?.mode, 0o640)

        // The handoff snapshot keeps the uncompressed ustar contract (D15).
        let snapshot = root.appendingPathComponent("snapshot.tar")
        let result = try packer.packUncompressed(to: snapshot)
        XCTAssertEqual(result.byteCount, tar.count)
        XCTAssertEqual(try Data(contentsOf: snapshot), tar)
    }

    // MARK: - Incremental fragment cache (wal.md §8)

    /// A tree exercising every ustar edge the overlay contract cares about:
    /// nested directories, empty files, a 512-byte file, a >100-byte path that
    /// needs the ustar prefix field, and a multi-megabyte file.
    private func makeRichTree(_ test: XCTestCase) throws -> URL {
        let root = LogTestSupport.root(for: test)
        let paths = WorkspacePaths(root: root)
        try paths.createDirectories()

        let nested = paths.materializedHomeDirectory
            .appendingPathComponent("a").appendingPathComponent("b")
            .appendingPathComponent("c")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("nested\n".utf8).write(to: nested.appendingPathComponent("nested.txt"))
        try Data().write(to: paths.materializedHomeDirectory.appendingPathComponent("empty"))
        try Data(repeating: 0x5a, count: 512).write(
            to: paths.materializedWorkspaceDirectory.appendingPathComponent("exact-512.bin"))

        var longDirectory = paths.materializedWorkspaceDirectory
        for component in ["one-long-directory", "two-long-directory", "three-long-directory"] {
            longDirectory.appendPathComponent(component)
        }
        try FileManager.default.createDirectory(at: longDirectory, withIntermediateDirectories: true)
        let longName = String(repeating: "a", count: 90) + ".txt"
        try Data("long\n".utf8).write(to: longDirectory.appendingPathComponent(longName))

        try Data(repeating: 0x7f, count: 3 * 1024 * 1024).write(
            to: paths.materializedWorkspaceDirectory.appendingPathComponent("big.bin"))
        return root
    }

    private var richFileCount: Int { 5 }

    private func cacheDirectory(_ root: URL) -> URL {
        root.appendingPathComponent(OverlayFragmentCache.directoryName, isDirectory: true)
    }

    private func fragmentFiles(in cache: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
        return names.filter {
            $0.hasPrefix(OverlayFragmentCache.fragmentPrefix)
                && $0.hasSuffix(OverlayFragmentCache.fragmentSuffix)
        }.sorted()
    }

    private func indexedPaths(in cache: URL) throws -> Set<String> {
        let index = cache.appendingPathComponent(OverlayFragmentCache.indexFileName)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: index))
        guard let root = object as? [String: Any],
              let entries = root["entries"] as? [[String: Any]] else {
            return []
        }
        return Set(entries.compactMap { entry in
            (entry["key"] as? [String: Any])?["path"] as? String
        })
    }

    func testGunzipOfTheOverlayEqualsTheContractualTarForEdgeCaseEntries() throws {
        let root = try makeRichTree(self)
        let packer = OverlayPacker(root: root)
        let tar = try packer.tarData()
        let inflated = try OverlayGzipDecoder.decompress(try packer.data())
        XCTAssertEqual(inflated, tar,
                       "the decompressed overlay must be byte-identical to tarData()")

        let entries = try TarParser.parse(inflated)
        let empty = try XCTUnwrap(entries.first { $0.name == "home/empty" })
        XCTAssertEqual(empty.data.count, 0)
        let exact = try XCTUnwrap(entries.first { $0.name == "workspace/exact-512.bin" })
        XCTAssertEqual(exact.data.count, 512)
        XCTAssertEqual(exact.typeflag, "0")
        let big = try XCTUnwrap(entries.first { $0.name == "workspace/big.bin" })
        XCTAssertEqual(big.data.count, 3 * 1024 * 1024)
        XCTAssertTrue(entries.contains { $0.name.hasPrefix("workspace/one-long-directory/") },
                      "the ustar prefix field must carry the long path")
        XCTAssertTrue(entries.contains { $0.name.hasSuffix("aaaa.txt") })
    }

    func testColdAndWarmFragmentCachesProduceIdenticalOverlays() throws {
        let root = try makeRichTree(self)
        let cache = cacheDirectory(root)
        let coldDiagnostics = OverlayFragmentCacheDiagnostics()
        let cold = try OverlayPacker(root: root,
                                     fragmentCacheDirectory: cache,
                                     diagnostics: coldDiagnostics).data()
        XCTAssertEqual(coldDiagnostics.recompressedFileCount, richFileCount)
        XCTAssertEqual(coldDiagnostics.reusedFileCount, 0)
        XCTAssertEqual(cold, try OverlayPacker(root: root).data(),
                       "a cache-directory cold build must equal the no-cache build")

        let warmDiagnostics = OverlayFragmentCacheDiagnostics()
        let warm = try OverlayPacker(root: root,
                                     fragmentCacheDirectory: cache,
                                     diagnostics: warmDiagnostics).data()
        XCTAssertEqual(warm, cold, "a warm fragment cache must not change the overlay bytes")
        XCTAssertEqual(warmDiagnostics.recompressedFileCount, 0)
        XCTAssertEqual(warmDiagnostics.reusedFileCount, richFileCount)
        XCTAssertEqual(try OverlayGzipDecoder.decompress(warm),
                       try OverlayPacker(root: root).tarData())
        XCTAssertEqual(fragmentFiles(in: cache).count, richFileCount)
    }

    func testCompositionSummaryRollsUpTopDirectoriesAndReportsColdAndWarmFields() throws {
        let root = LogTestSupport.root(for: self)
        let paths = WorkspacePaths(root: root)
        try paths.createDirectories()
        let workspace = paths.materializedWorkspaceDirectory
        let home = paths.materializedHomeDirectory
        let alpha = workspace.appendingPathComponent("alpha")
        let alphaNested = alpha.appendingPathComponent("nested")
        let beta = workspace.appendingPathComponent("beta")
        let gamma = workspace.appendingPathComponent("gamma")
        let delta = workspace.appendingPathComponent("delta")
        let eta = home.appendingPathComponent("eta")
        for directory in [alphaNested, beta, gamma, delta, eta] {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
        }
        try Data(repeating: 0x61, count: 700)
            .write(to: alpha.appendingPathComponent("a.bin"))
        try Data(repeating: 0x62, count: 300)
            .write(to: alphaNested.appendingPathComponent("b.bin"))
        try Data(repeating: 0x63, count: 600)
            .write(to: beta.appendingPathComponent("c.bin"))
        try Data(repeating: 0x64, count: 500)
            .write(to: gamma.appendingPathComponent("d.bin"))
        try Data(repeating: 0x65, count: 400)
            .write(to: delta.appendingPathComponent("e.bin"))
        try Data(repeating: 0x66, count: 100)
            .write(to: eta.appendingPathComponent("f.bin"))
        // A file directly under workspace/ belongs to no top-level directory.
        try Data(repeating: 0x67, count: 50)
            .write(to: workspace.appendingPathComponent("root.txt"))

        let cache = cacheDirectory(root)
        let coldLines = LineCollector()
        let coldDiagnostics = OverlayFragmentCacheDiagnostics { coldLines.append($0) }
        _ = try OverlayPacker(root: root,
                              fragmentCacheDirectory: cache,
                              diagnostics: coldDiagnostics).data()
        let cold = try XCTUnwrap(coldDiagnostics.lastComposition)
        XCTAssertEqual(cold.bytes, 2_650)
        XCTAssertEqual(cold.entries, 15)
        XCTAssertEqual(cold.files, 7)
        XCTAssertEqual(cold.unchanged, 0, "a cold fragment cache reuses nothing")
        XCTAssertEqual(cold.reusedBytes, 0)
        XCTAssertEqual(cold.topDirectories, [
            OverlayComposition.TopDirectory(directory: "workspace/alpha", bytes: 1_000),
            OverlayComposition.TopDirectory(directory: "workspace/beta", bytes: 600),
            OverlayComposition.TopDirectory(directory: "workspace/gamma", bytes: 500),
        ], "top three only, descending; workspace/delta and home/eta are outside")
        XCTAssertEqual(coldLines.snapshot, [cold.line])
        XCTAssertEqual(cold.line,
                       "overlay-compose bytes=2650 entries=15 "
                           + "top=workspace/alpha:1000,workspace/beta:600,workspace/gamma:500 "
                           + "files=7 unchanged=0 reused_bytes=0")

        let changed = beta.appendingPathComponent("c.bin")
        try Data(repeating: 0x68, count: 650).write(to: changed)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: changed.path)

        let warmLines = LineCollector()
        let warmDiagnostics = OverlayFragmentCacheDiagnostics { warmLines.append($0) }
        _ = try OverlayPacker(root: root,
                              fragmentCacheDirectory: cache,
                              diagnostics: warmDiagnostics).data()
        let warm = try XCTUnwrap(warmDiagnostics.lastComposition)
        XCTAssertEqual(warm.bytes, 2_700)
        XCTAssertEqual(warm.entries, 15)
        XCTAssertEqual(warm.files, 7)
        XCTAssertEqual(warm.unchanged, 6, "only the rewritten file misses its fragment")
        XCTAssertEqual(warm.reusedBytes, 2_050)
        XCTAssertEqual(warm.topDirectories, [
            OverlayComposition.TopDirectory(directory: "workspace/alpha", bytes: 1_000),
            OverlayComposition.TopDirectory(directory: "workspace/beta", bytes: 650),
            OverlayComposition.TopDirectory(directory: "workspace/gamma", bytes: 500),
        ])
        XCTAssertEqual(warmLines.snapshot, [warm.line])
        XCTAssertEqual(warmDiagnostics.recompressedFileCount, 1)
        XCTAssertEqual(warmDiagnostics.reusedFileCount, 6)
    }

    func testChangingOneFileRecompressesOnlyThatFragment() throws {
        let root = LogTestSupport.root(for: self)
        let paths = WorkspacePaths(root: root)
        try paths.createDirectories()
        let files = ["a.txt", "b.txt", "c.txt"]
        for name in files {
            try Data(repeating: 0x61, count: 64).write(
                to: paths.materializedWorkspaceDirectory.appendingPathComponent(name))
        }
        let cache = cacheDirectory(root)
        let cold = try OverlayPacker(root: root, fragmentCacheDirectory: cache).data()

        let changed = paths.materializedWorkspaceDirectory.appendingPathComponent("b.txt")
        let replacement = Data(repeating: 0x62, count: 64)
        try replacement.write(to: changed)
        let bumped = Date().addingTimeInterval(30)
        try FileManager.default.setAttributes([.modificationDate: bumped],
                                              ofItemAtPath: changed.path)

        let diagnostics = OverlayFragmentCacheDiagnostics()
        let warm = try OverlayPacker(root: root,
                                     fragmentCacheDirectory: cache,
                                     diagnostics: diagnostics).data()
        XCTAssertEqual(diagnostics.recompressedFileCount, 1,
                       "only the changed file's fragment is rebuilt")
        XCTAssertEqual(diagnostics.reusedFileCount, files.count - 1)
        XCTAssertNotEqual(warm, cold)
        XCTAssertEqual(warm, try OverlayPacker(root: root).data(),
                       "the incremental overlay must equal a cold build")
        let index = try indexedPaths(in: cache)
        XCTAssertEqual(index.count, files.count)
    }

    func testDeletingAndAddingFilesDropsStaleFragments() throws {
        let root = LogTestSupport.root(for: self)
        let paths = WorkspacePaths(root: root)
        try paths.createDirectories()
        let workspace = paths.materializedWorkspaceDirectory
        for name in ["a.txt", "b.txt", "c.txt"] {
            try Data("\(name)\n".utf8).write(to: workspace.appendingPathComponent(name))
        }
        let cache = cacheDirectory(root)
        _ = try OverlayPacker(root: root, fragmentCacheDirectory: cache).data()

        try FileManager.default.removeItem(at: workspace.appendingPathComponent("b.txt"))
        let afterDelete = try OverlayPacker(root: root, fragmentCacheDirectory: cache).data()
        XCTAssertEqual(afterDelete, try OverlayPacker(root: root).data())
        XCTAssertEqual(try indexedPaths(in: cache),
                       ["workspace/a.txt", "workspace/c.txt"])
        XCTAssertEqual(fragmentFiles(in: cache).count, 2,
                       "the deleted path's fragment file is removed")

        try Data("d.txt\n".utf8).write(to: workspace.appendingPathComponent("d.txt"))
        let afterAdd = try OverlayPacker(root: root, fragmentCacheDirectory: cache).data()
        XCTAssertEqual(afterAdd, try OverlayPacker(root: root).data())
        XCTAssertEqual(try indexedPaths(in: cache),
                       ["workspace/a.txt", "workspace/c.txt", "workspace/d.txt"])
        XCTAssertEqual(fragmentFiles(in: cache).count, 3)
    }

    func testCorruptIndexAndTruncatedFragmentFallBackToAFullRebuild() throws {
        let root = try makeRichTree(self)
        let cache = cacheDirectory(root)
        let baseline = try OverlayPacker(root: root).data()
        _ = try OverlayPacker(root: root, fragmentCacheDirectory: cache).data()

        let index = cache.appendingPathComponent(OverlayFragmentCache.indexFileName)
        try Data("{ this is not the index".utf8).write(to: index)
        let corruptDiagnostics = OverlayFragmentCacheDiagnostics()
        let afterCorruptIndex = try OverlayPacker(root: root,
                                                  fragmentCacheDirectory: cache,
                                                  diagnostics: corruptDiagnostics).data()
        XCTAssertEqual(afterCorruptIndex, baseline)
        XCTAssertEqual(corruptDiagnostics.recompressedFileCount, richFileCount)
        XCTAssertEqual(corruptDiagnostics.reusedFileCount, 0)

        // The successful rebuild repaired the index.
        let repairedDiagnostics = OverlayFragmentCacheDiagnostics()
        let repaired = try OverlayPacker(root: root,
                                         fragmentCacheDirectory: cache,
                                         diagnostics: repairedDiagnostics).data()
        XCTAssertEqual(repaired, baseline)
        XCTAssertEqual(repairedDiagnostics.recompressedFileCount, 0)
        XCTAssertEqual(repairedDiagnostics.reusedFileCount, richFileCount)

        let fragment = try XCTUnwrap(fragmentFiles(in: cache).first)
        try Data([0x00]).write(to: cache.appendingPathComponent(fragment))
        let truncatedDiagnostics = OverlayFragmentCacheDiagnostics()
        let afterTruncation = try OverlayPacker(root: root,
                                                fragmentCacheDirectory: cache,
                                                diagnostics: truncatedDiagnostics).data()
        XCTAssertEqual(afterTruncation, baseline)
        XCTAssertEqual(truncatedDiagnostics.recompressedFileCount, richFileCount,
                       "a torn fragment invalidates the index instead of corrupting the overlay")
    }

    /// Rough warm-overlay timing. Off by default because it writes a 50 MB tree.
    private func pseudoRandomData(count: Int, seed: UInt64) -> Data {
        var value = seed
        var bytes = [UInt8](repeating: 0, count: count)
        for index in 0..<count {
            value = value &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes[index] = UInt8(truncatingIfNeeded: value >> 33)
        }
        return Data(bytes)
    }

    func testWarmOverlayAfterOneSmallChangePerf() throws {
        guard ProcessInfo.processInfo.environment["PDSH_PERF"] == "1" else {
            throw XCTSkip("set PDSH_PERF=1 to run the 50 MB overlay timing")
        }
        let root = LogTestSupport.root(for: self)
        let paths = WorkspacePaths(root: root)
        try paths.createDirectories()
        let workspace = paths.materializedWorkspaceDirectory
        for index in 0..<50 {
            try pseudoRandomData(count: 1024 * 1024, seed: UInt64(index) + 1)
                .write(to: workspace.appendingPathComponent("chunk-\(index).bin"))
        }
        let small = workspace.appendingPathComponent("small.bin")
        try pseudoRandomData(count: 10 * 1024, seed: 99).write(to: small)

        let cache = cacheDirectory(root)
        let output = root.appendingPathComponent("perf-overlay.tar")
        _ = try OverlayPacker(root: root, fragmentCacheDirectory: cache).pack(to: output)

        try pseudoRandomData(count: 10 * 1024, seed: 100).write(to: small)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: small.path)

        let diagnostics = OverlayFragmentCacheDiagnostics()
        let start = Date()
        let result = try OverlayPacker(root: root,
                                       fragmentCacheDirectory: cache,
                                       diagnostics: diagnostics).pack(to: output)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(diagnostics.recompressedFileCount, 1)
        print("PDSH_PERF warm overlay after one 10 KB change: "
              + String(format: "%.3f s", elapsed)
              + ", \(result.byteCount) bytes")
    }
}

/// Thread-safe line sink for the composition diagnostics.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

/// Independent gzip decoder for the tests: zlib's `inflate` with a 31-bit
/// window (gzip framing), not the packer's encoder. zlib verifies the member's
/// CRC-32 and ISIZE at Z_STREAM_END.
enum OverlayGzipDecoder {
    struct DecodeError: Error, CustomStringConvertible {
        let description: String
    }

    static func decompress(_ archive: Data) throws -> Data {
        guard archive.count > 18 else {
            throw DecodeError(description: "not a gzip member")
        }
        var stream = z_stream()
        let started = inflateInit2_(&stream, 31, zlibVersion(),
                                    Int32(MemoryLayout<z_stream>.size))
        guard started == Z_OK else {
            throw DecodeError(description: "inflateInit2 failed")
        }
        defer { _ = inflateEnd(&stream) }

        let capacity = 256 * 1024
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { output.deallocate() }
        var result = Data()
        var finished = false
        var trailing = -1
        try archive.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw DecodeError(description: "empty gzip member")
            }
            var source = base
            var remaining = raw.count
            while true {
                stream.next_in = UnsafeMutablePointer(mutating: source)
                stream.avail_in = uInt(remaining)
                stream.next_out = output
                stream.avail_out = uInt(capacity)
                let status = zlib.inflate(&stream, Z_NO_FLUSH)
                let consumed = remaining - Int(stream.avail_in)
                let produced = capacity - Int(stream.avail_out)
                source = source.advanced(by: consumed)
                remaining -= consumed
                if produced > 0 {
                    result.append(output, count: produced)
                }
                if status == Z_STREAM_END {
                    finished = true
                    trailing = remaining
                    break
                }
                guard status == Z_OK else {
                    throw DecodeError(description: "inflate failed with status \(status)")
                }
                if consumed == 0 && produced == 0 {
                    throw DecodeError(description: "truncated gzip member")
                }
            }
        }
        guard finished else {
            throw DecodeError(description: "gzip member did not finish")
        }
        guard trailing == 0 else {
            throw DecodeError(description: "bytes after the gzip member")
        }
        return result
    }
}
