// SPDX-License-Identifier: MIT
// W3: every successful epoch close reclaims droppable WAL segments, not only
// the quota path (wal.md §12). The level-2 ack and manifest are already
// durable when the unlink happens.

import Foundation
import XCTest
@testable import PhoneDSHLog
import PhoneDSHLog
import PhoneDSHWire

final class WALReclaimTimingTests: XCTestCase {
    private func write(_ path: String, _ text: String) -> VfsMutationBody {
        VfsMutationBody(op: .write, mode: 0o644, path: path, data: Data(text.utf8))
    }

    func testSecondEpochCloseDropsTheOlderClosedSegment() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-w3-reclaim-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = WorkspaceLogConfiguration(root: root, groupCommitDelay: 0)
        let log = try WorkspaceLog(configuration: configuration,
                                   bootID: Data(repeating: 0x44, count: 16))
        _ = try await log.recover()
        _ = try await log.append(write("/dsh/workspace/a.txt", "first"))
        _ = try await log.closeEpoch()

        let wal = root.appendingPathComponent("wal", isDirectory: true)
        let afterFirst = try FileManager.default.contentsOfDirectory(atPath: wal.path).sorted()
        XCTAssertTrue(afterFirst.contains(where: { $0.hasPrefix("00000001.") }),
                      "the first epoch's close segment is the newest at this point")

        _ = try await log.append(write("/dsh/workspace/a.txt", "second"))
        _ = try await log.closeEpoch()
        let afterSecond = try FileManager.default.contentsOfDirectory(atPath: wal.path).sorted()
        XCTAssertFalse(afterSecond.contains(where: { $0.hasPrefix("00000001.") }),
                       "the second close must reclaim the now-droppable first epoch")
        XCTAssertTrue(afterSecond.contains(where: { $0.hasPrefix("00000002.") }),
                      "the newest close segment is retained")
    }

    func testEpochCloseObserverRunsAfterTheClose() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-w3-observer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = WorkspaceLogConfiguration(root: root, groupCommitDelay: 0)
        let log = try WorkspaceLog(configuration: configuration,
                                   bootID: Data(repeating: 0x45, count: 16))
        _ = try await log.recover()
        let probe = EpochCloseProbe()
        _ = await log.addEpochCloseObserver { result in
            await probe.record(result)
        }
        _ = try await log.append(write("/dsh/workspace/a.txt", "first"))
        _ = try await log.closeEpoch()
        let epochs = await probe.epochs()
        XCTAssertEqual(epochs, [1])
    }
}

private actor EpochCloseProbe {
    private var values: [UInt64] = []
    func record(_ result: WALEpochCloseResult) { values.append(result.epoch) }
    func epochs() -> [UInt64] { values }
}
