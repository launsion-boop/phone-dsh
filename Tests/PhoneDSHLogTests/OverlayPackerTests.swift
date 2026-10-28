// SPDX-License-Identifier: MIT
// OverlayPacker: gzip-wrapped ustar content (D21), ordering, exclusions,
// symlinks and determinism.

import Foundation
import XCTest
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
}
