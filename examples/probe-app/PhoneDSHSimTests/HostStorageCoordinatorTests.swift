// SPDX-License-Identifier: MIT
// W3 App-side storage scanner and five-level actions. Outbox entries and
// attachment bytes are user data: they are counted and never auto-deleted.

import Foundation
import XCTest
import PhoneDSHController
import ProbeKit

final class HostStorageCoordinatorTests: XCTestCase {
    private var root: URL!
    private var documents: URL!
    private var caches: URL!
    private var workspace: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-w3-storage-\(UUID().uuidString)", isDirectory: true)
        documents = root.appendingPathComponent("Documents", isDirectory: true)
        caches = root.appendingPathComponent("Library/Caches/pdsh/ws", isDirectory: true)
        workspace = root.appendingPathComponent("Library/xl/ws", isDirectory: true)
        for directory in [documents, caches, workspace].compactMap({ $0 }) {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func paths() -> HostStoragePaths {
        HostStoragePaths(workspaceRoot: workspace,
                         documentsRoot: documents,
                         cachesRoot: caches)
    }

    private func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testScannerCountsOutboxAttachmentsAndExcludesThemFromHostInternal() throws {
        try write(documents.appendingPathComponent("send-outbox/attachments/rpc/a"),
                  String(repeating: "x", count: 4096))
        try write(workspace.appendingPathComponent("wal/00000001.000000.xlwal"),
                  String(repeating: "w", count: 1024))
        let usage = HostStorageScanner(paths: paths()).scan()
        XCTAssertEqual(usage.outboxAttachmentBytes, 4096)
        XCTAssertEqual(usage.hostInternalBytes, 1024)
        XCTAssertEqual(usage.budgetedBytes, 1024 + 4096)
    }

    func testHardLinksAreCountedOnce() throws {
        let source = workspace.appendingPathComponent("wal/a")
        try write(source, String(repeating: "z", count: 2048))
        let cache = caches.appendingPathComponent("overlay-cache.tar")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: source, to: cache)
        let usage = HostStorageScanner(paths: paths()).scan()
        XCTAssertEqual(usage.hostInternalBytes, 2048,
                       "the cache hard link must not double-count the WAL bytes")
    }

    func testLevelOnePrunesCachesButNeverTheOutbox() async throws {
        try write(caches.appendingPathComponent("overlay-cache.tar"), "cache")
        try write(caches.appendingPathComponent("transcript-snapshots/phone/s.json"), "{}")
        let attachment = documents.appendingPathComponent("send-outbox/attachments/rpc/a")
        try write(attachment, "attachment")
        let coordinator = HostStorageCoordinator(paths: paths())
        let decision = HostStorageDecision(level: .one,
                                           actions: [.reclaimDroppable, .pruneCaches],
                                           userSurface: .silent,
                                           reason: "level one")
        let report = try await coordinator.apply(decision)
        XCTAssertGreaterThan(report.removedBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: caches.appendingPathComponent("overlay-cache.tar").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: caches.appendingPathComponent("transcript-snapshots").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.path),
                      "outbox attachments are user data and survive every level")
    }

    func testLevelFourPrunesThenThrowsAndStillKeepsTheOutbox() async throws {
        let attachment = documents.appendingPathComponent("send-outbox/attachments/rpc/a")
        try write(attachment, "attachment")
        let coordinator = HostStorageCoordinator(paths: paths())
        let decision = HostStoragePolicy.standard.decision(
            for: HostStorageUsage(workspaceLogicalBytes: 300 * 1024 * 1024,
                                  availableImportantBytes: 0,
                                  volumeBytes: 64_000 * 1024 * 1024),
            workspaceBucketBytes: 288 * 1024 * 1024,
            writeWouldFail: true)
        XCTAssertEqual(decision.level, .four)
        do {
            _ = try await coordinator.apply(decision)
            XCTFail("level four must fail the write")
        } catch {
            XCTAssertTrue(error is HostStorageFailure)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.path))
    }

    func testLegacyTranscriptMigrationIsReentrant() async throws {
        try write(documents.appendingPathComponent("transcript-snapshots/phone/s.json"), "{}")
        let coordinator = HostStorageCoordinator(paths: paths())
        let first = await coordinator.migrateLegacyCachesIfNeeded()
        XCTAssertTrue(first.contains { $0.hasPrefix("transcript:") })
        let target = caches.appendingPathComponent("transcript-snapshots/phone/s.json")
        XCTAssertEqual(try Data(contentsOf: target), Data("{}".utf8))
        let second = await coordinator.migrateLegacyCachesIfNeeded()
        XCTAssertFalse(second.contains { $0.hasPrefix("transcript:") })
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: documents.appendingPathComponent("transcript-snapshots/phone/s.json").path),
                      "rollback keeps the old copy")
    }

    func testLargestWorkspaceFilesAreBoundedAndRelative() throws {
        try write(workspace.appendingPathComponent("materialized/workspace/big.bin"),
                  String(repeating: "b", count: 2048))
        try write(workspace.appendingPathComponent("materialized/workspace/small.txt"), "s")
        let files = HostStorageScanner(paths: paths()).largestWorkspaceFiles(limit: 1)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.relativePath, "big.bin")
        XCTAssertFalse(files.first?.relativePath.hasPrefix("/") == true)
    }
}
