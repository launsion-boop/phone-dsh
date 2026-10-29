// SPDX-License-Identifier: MIT
// A fully materialized, durable history is its own checkpoint: recovery must
// not re-scan it against the WAL after a crash (the 18 s boot).

import Foundation
import XCTest
@testable import PhoneDSHLog
import PhoneDSHLog
import PhoneDSHWire

final class RecoveryFastPathTests: XCTestCase {
    func testFullyMaterializedDurableHistorySkipsTheVerificationPass() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-fastpath-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = WorkspaceLogConfiguration(root: root,
                                                      singleFileLimitBytes: 8 * 1024 * 1024,
                                                      groupCommitDelay: 0)
        let log = try WorkspaceLog(configuration: configuration,
                                   bootID: Data(repeating: 0x11, count: 16))
        _ = try await log.recover()
        _ = try await log.append(VfsMutationBody(
            op: .write, mode: 0o644, path: "/dsh/workspace/a.bin",
            data: Data(repeating: 0x41, count: 2 * 1024 * 1024)))
        _ = try await log.closeEpoch()

        // Simulate the crash window the 18 s boot hit: the WAL segment holds
        // more records than the manifest lists (the manifest rewrite had not
        // happened yet), while every record is already materialized and its
        // epoch is durable.
        let store = ManifestStore(root: root)
        var lagging = try XCTUnwrap(store.read())
        var last = try XCTUnwrap(lagging.segments.last)
        last.lastMseq -= 1
        lagging.segments[lagging.segments.count - 1] = last
        try store.write(lagging)

        // Corrupt the materialized copy in place (same size). The old
        // verification pass would report a contentMismatch and refuse to boot;
        // the checkpoint is proven, so recovery trusts the fsynced tree.
        let materialized = root.appendingPathComponent("materialized/workspace/a.bin")
        var bytes = try Data(contentsOf: materialized)
        bytes[0] = 0x00
        try bytes.write(to: materialized)

        let reopened = try WorkspaceLog(configuration: configuration,
                                        bootID: Data(repeating: 0x22, count: 16))
        let report = try await reopened.recover()
        XCTAssertEqual(report.materializedUptoMseq, report.ackedMseq)
    }
}
