// SPDX-License-Identifier: MIT
// W4: shared group-commit write and close-only watermark persistence.

import Foundation
import XCTest
@testable import PhoneDSHLog
import PhoneDSHWire

final class W4GroupCommitTests: XCTestCase {
    func testAppendBatchSharesOneWriteAndKeepsMseqOrder() async throws {
        let root = LogTestSupport.root(for: self)
        let log = try WorkspaceLog(
            configuration: LogTestSupport.configuration(root: root,
                                                       groupCommitDelay: 0.05),
            bootID: LogTestSupport.bootID())
        let mutations = (0..<5).map { index in
            LogTestSupport.write("/dsh/workspace/w4-\(index).txt",
                                 data: "payload-\(index)")
        }
        let mseqs = try await log.appendBatch(mutations)
        XCTAssertEqual(mseqs, [1, 2, 3, 4, 5])

        let counters = await log.writerCountersForTesting()
        XCTAssertEqual(counters.batchCount, 1, "one batch for the whole appendBatch")
        XCTAssertEqual(counters.recordWriteCount, 1,
                       "all five records must share one write()")

        for (index, mutation) in mutations.enumerated() {
            let url = WorkspacePaths(root: root).materializedDirectory
                .appendingPathComponent(String(mutation.path.dropFirst("/dsh/".count)))
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8),
                           "payload-\(index)")
        }
    }

    func testMaterializedWatermarkIsPersistedOnlyAtEpochClose() async throws {
        let root = LogTestSupport.root(for: self)
        let log = try WorkspaceLog(
            configuration: LogTestSupport.configuration(root: root),
            bootID: LogTestSupport.bootID())
        _ = try await log.append(LogTestSupport.write("/dsh/workspace/a", data: "a"))
        _ = try await log.append(LogTestSupport.write("/dsh/workspace/b", data: "b"))

        // The in-memory copy is current; `manifest.json` still names the old
        // watermark (wal.md §13).
        let watermark = try await log.materialize()
        XCTAssertEqual(watermark, 2)
        let beforeClose = try ManifestStore(root: root).read()
        XCTAssertEqual(beforeClose?.materializedUptoMseq ?? 0, 0)

        _ = try await log.closeEpoch()
        let afterClose = try XCTUnwrap(try ManifestStore(root: root).read())
        XCTAssertEqual(afterClose.materializedUptoMseq, 2)
    }

    func testIdleSealDoesNotWriteANewEpoch() async throws {
        let root = LogTestSupport.root(for: self)
        let log = try WorkspaceLog(
            configuration: LogTestSupport.configuration(root: root),
            bootID: LogTestSupport.bootID())
        _ = try await log.append(LogTestSupport.write("/dsh/workspace/a", data: "a"))
        _ = try await log.closeEpoch()

        let before = try XCTUnwrap(try ManifestStore(root: root).read())
        let ack = try await log.sealEpochCoveringTail()
        XCTAssertEqual(ack.uptoMseq, 1)
        let after = try XCTUnwrap(try ManifestStore(root: root).read())
        XCTAssertEqual(after.lastDurableEpoch, before.lastDurableEpoch,
                       "an idle seal must not close another epoch")
        XCTAssertEqual(after.materializedUptoMseq, before.materializedUptoMseq)
    }
}
