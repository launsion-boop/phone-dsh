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
