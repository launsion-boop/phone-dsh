// SPDX-License-Identifier: MIT
// The boot overlay is reused while the materialized watermark is unchanged;
// packing the whole tree on every boot made start-up O(workspace).

import Foundation
import XCTest
@testable import PhoneDSHLog
import PhoneDSHLog
import PhoneDSHWire

final class OverlayCacheTests: XCTestCase {
    private let bootA = String(repeating: "a", count: 32)
    private let bootB = String(repeating: "b", count: 32)
    private let bootC = String(repeating: "c", count: 32)

    private func makeLog() throws -> (WorkspaceLog, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-overlay-\(UUID().uuidString)", isDirectory: true)
        let configuration = WorkspaceLogConfiguration(root: root, groupCommitDelay: 0)
        let log = try WorkspaceLog(configuration: configuration,
                                   bootID: Data(repeating: 0x33, count: 16))
        return (log, root)
    }

    private func write(_ path: String, _ text: String) -> VfsMutationBody {
        VfsMutationBody(op: .write, mode: 0o644, path: path, data: Data(text.utf8))
    }

    func testOverlayTarsAreExcludedFromBackup() async throws {
        let (log, root) = try makeLog()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await log.recover()
        _ = try await log.append(write("/dsh/workspace/a.txt", "first"))

        let bootURL = try await log.overlay(bootID: bootA)
        let cacheURL = root.appendingPathComponent("overlay-cache.tar")
        let fragmentCacheURL = root.appendingPathComponent(
            OverlayFragmentCache.directoryName, isDirectory: true)
        for url in [bootURL, cacheURL, fragmentCacheURL] {
            let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(values.isExcludedFromBackup, true,
                           "\(url.lastPathComponent) is derived and must not be backed up")
        }
    }

    /// The whole-tree watermark cache still misses after a single mutation, but
    /// the per-file fragments of unchanged files are reused: their fragment
    /// file names survive into the new index.
    func testOverlayReusesUnchangedFileFragmentsAcrossAMutation() async throws {
        let (log, root) = try makeLog()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await log.recover()
        _ = try await log.append(write("/dsh/workspace/a.txt", "first"))
        _ = try await log.append(write("/dsh/workspace/b.txt", "second"))
        _ = try await log.overlay(bootID: bootA)
        let before = try fragmentIndex(root)
        XCTAssertEqual(before.count, 2)

        _ = try await log.append(write("/dsh/workspace/new.txt", "new"))
        _ = try await log.overlay(bootID: bootB)
        let after = try fragmentIndex(root)
        XCTAssertEqual(before["workspace/a.txt"], after["workspace/a.txt"],
                       "an unchanged file must keep its fragment file")
        XCTAssertEqual(before["workspace/b.txt"], after["workspace/b.txt"],
                       "an unchanged file must keep its fragment file")
        XCTAssertNotNil(after["workspace/new.txt"])
        XCTAssertEqual(after.count, 3)
    }

    private func fragmentIndex(_ root: URL) throws -> [String: String] {
        let cache = root.appendingPathComponent(OverlayFragmentCache.directoryName,
                                                 isDirectory: true)
        let index = cache.appendingPathComponent(OverlayFragmentCache.indexFileName)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: index))
        guard let root = object as? [String: Any],
              let entries = root["entries"] as? [[String: Any]] else {
            return [:]
        }
        var result: [String: String] = [:]
        for entry in entries {
            guard let key = entry["key"] as? [String: Any],
                  let path = key["path"] as? String,
                  let file = entry["file"] as? String else { continue }
            result[path] = file
        }
        return result
    }

    /// After a mutation the whole-tree cache is rebuilt from fragments; its
    /// bytes must match both a no-cache pack and `packOverlay()`.
    func testIncrementalOverlayAfterAMutationEqualsAColdBuild() async throws {
        let (log, root) = try makeLog()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await log.recover()
        _ = try await log.append(write("/dsh/workspace/a.txt", "first"))
        _ = try await log.append(write("/dsh/workspace/b.txt", "second"))
        _ = try await log.overlay(bootID: bootA)

        _ = try await log.append(write("/dsh/workspace/a.txt", "third"))
        let incrementalURL = try await log.overlay(bootID: bootB)
        let incremental = try Data(contentsOf: incrementalURL)
        let cold = try OverlayPacker(
            materializedDirectory: WorkspacePaths(root: root).materializedDirectory).data()
        XCTAssertEqual(incremental, cold,
                       "the fragment-assembled overlay must equal a cold build")
        let packed = try await log.packOverlay()
        XCTAssertEqual(packed, incremental)
    }

    func testOverlayIsReusedWhileTheMaterializedWatermarkIsUnchanged() async throws {
        let (log, root) = try makeLog()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await log.recover()
        _ = try await log.append(write("/dsh/workspace/a.txt", "first"))

        let firstURL = try await log.overlay(bootID: bootA)
        let firstData = try Data(contentsOf: firstURL)
        let firstAttributes = try FileManager.default.attributesOfItem(atPath: firstURL.path)
        let firstModified = try XCTUnwrap(firstAttributes[.modificationDate] as? Date)

        // A later boot with the same materialized tree links the cache
        // instead of repacking (the cache file is not rewritten).
        let cacheURL = root.appendingPathComponent("overlay-cache.tar")
        let cacheModified = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date)
        let secondURL = try await log.overlay(bootID: bootB)
        XCTAssertEqual(secondURL.lastPathComponent, "overlay-\(bootB).tar")
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
        XCTAssertEqual(try Data(contentsOf: secondURL), firstData)
        let cacheModifiedAfter = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date)
        XCTAssertEqual(cacheModifiedAfter, cacheModified, "the cached overlay must not be repacked")

        // A new materialized mutation invalidates the cache.
        _ = try await log.append(write("/dsh/workspace/a.txt", "second"))
        let thirdURL = try await log.overlay(bootID: bootC)
        XCTAssertEqual(thirdURL.lastPathComponent, "overlay-\(bootC).tar")
        XCTAssertNotEqual(try Data(contentsOf: thirdURL), firstData,
                          "a changed tree must repack")
        let sidecar = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("overlay-cache.json")))
        let sidecarWatermark = (sidecar as? [String: Any])?["watermark"] as? UInt64
        XCTAssertEqual(sidecarWatermark, 2)
    }
}
