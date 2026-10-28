// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — the terminal stop seal (G2-FIX-127).
//
// `WorkspaceLog.sealForStop()` is the single owner of the terminal stop/abort
// path: it closes the accepted tail in the D18 order, discards the header-only
// tail segment, then proves the materialized copy against the acknowledged WAL
// (rebuilding it from a full-history WAL, failing loud otherwise). The G2-A09
// batch showed that without this owner an abort/failed teardown left an open
// epoch behind a manifest that still described the previous empty epoch.

import Foundation
import XCTest
@testable import PhoneDSHLog
import PhoneDSHWire

final class AbortStopSealTests: XCTestCase {
    private static let chunkBytes = 1024 * 1024

    private func configuration(_ root: URL) -> WorkspaceLogConfiguration {
        LogTestSupport.configuration(root: root)
    }

    private func chunkData(_ index: Int) -> Data {
        Data(repeating: UInt8(0x41 + (index % 26)), count: Self.chunkBytes)
    }

    private func expected(_ chunks: Int) -> Data {
        var data = Data()
        for index in 0..<chunks { data.append(chunkData(index)) }
        return data
    }

    @discardableResult
    private func writeChunked(_ log: WorkspaceLog, path: String,
                              chunks: Int) async throws -> Data {
        var expected = Data()
        for index in 0..<chunks {
            let bytes = chunkData(index)
            if index == 0 {
                _ = try await log.append(VfsMutationBody(
                    op: .write, mode: 0o644, path: path, data: bytes))
            } else {
                _ = try await log.append(VfsMutationBody(
                    op: .write, mode: 0o644,
                    mflags: .appended, appendFrom: UInt64(expected.count),
                    path: path, data: bytes))
            }
            expected.append(bytes)
        }
        return expected
    }

    private func materializedURL(_ root: URL, _ vfsPath: String) -> URL {
        var url = WorkspacePaths(root: root).materializedDirectory
        for component in vfsPath.split(separator: "/").dropFirst(1) {
            url.appendPathComponent(String(component))
        }
        return url
    }

    private func readMaterialized(_ root: URL, _ vfsPath: String) throws -> Data {
        try Data(contentsOf: materializedURL(root, vfsPath))
    }

    private func assertManifestMatchesWAL(_ root: URL,
                                          file: StaticString = #filePath,
                                          line: UInt = #line) throws {
        let manifest = try XCTUnwrap(try ManifestStore(root: root).read(),
                                     file: file, line: line)
        let segments = try LogTestSupport.segments(in: root)
        let nonEmpty = segments.filter { !$0.records.isEmpty }
        let listed = Dictionary(uniqueKeysWithValues: manifest.segments.map { ($0.file, $0) })
        XCTAssertEqual(listed.keys.sorted(), nonEmpty.map(\.manifestFile).sorted(),
                       "manifest.segments must list every non-empty wal/ segment",
                       file: file, line: line)
        for segment in nonEmpty {
            guard let entry = listed[segment.manifestFile] else { continue }
            XCTAssertEqual(entry.firstMseq, segment.header.firstMseq,
                           file: file, line: line)
            XCTAssertEqual(entry.lastMseq, segment.lastMutationMseq,
                           file: file, line: line)
        }
    }

    /// The terminal stop seal closes the epoch, discards the header-only tail
    /// segment and verifies the copy; a later loss of a completed write is
    /// repaired from the WAL at the next seal.
    func testSealForStopIsTheSingleStopOwner() async throws {
        let root = LogTestSupport.root(for: self, name: "abort-seal")
        let log = try WorkspaceLog(configuration: configuration(root),
                                   bootID: LogTestSupport.bootID(0xD1))
        _ = try await log.append(LogTestSupport.write("/dsh/workspace/seed.txt",
                                                      data: "seed"))
        let early = try await writeChunked(log,
                                           path: "/dsh/workspace/early.bin",
                                           chunks: 3)
        let late = try await writeChunked(log,
                                          path: "/dsh/workspace/late.bin",
                                          chunks: 2)
        let ack = try await log.sealForStop()
        let positions = await log.positions()
        XCTAssertGreaterThanOrEqual(positions.durableMseq, positions.ackedMseq)
        XCTAssertGreaterThanOrEqual(ack.uptoMseq, positions.ackedMseq)
        try assertManifestMatchesWAL(root)
        // No orphan header-only tail segment survives a terminal seal.
        let segments = try LogTestSupport.segments(in: root)
        XCTAssertTrue(segments.allSatisfy { !$0.records.isEmpty },
                      "a stopped workspace must not keep a header-only orphan segment: \(segments.map(\.fileName))")
        XCTAssertEqual(try readMaterialized(root, "/dsh/workspace/early.bin"), early)
        XCTAssertEqual(try readMaterialized(root, "/dsh/workspace/late.bin"), late)

        // Whatever removed the completed write, the stop invariant repairs it
        // from the full acknowledged WAL (and the host would otherwise fail
        // loud with a machine-readable reason).
        try FileManager.default.removeItem(at: materializedURL(root,
                                                               "/dsh/workspace/early.bin"))
        _ = try await log.sealForStop()
        XCTAssertEqual(try readMaterialized(root, "/dsh/workspace/early.bin"), early)
        try assertManifestMatchesWAL(root)
    }

    /// When the retained history starts above mseq 1 a divergence cannot be
    /// rebuilt from the WAL. The stop seal must fail loud with a machine-
    /// readable reason (the host turns it into `Failed`), never silently keep
    /// the lossy copy.
    func testSealForStopFailsLoudWhenTruncatedHistoryCannotBeRebuilt() async throws {
        let root = LogTestSupport.root(for: self, name: "abort-seal-truncated")
        let log = try WorkspaceLog(configuration: configuration(root),
                                   bootID: LogTestSupport.bootID(0x51))
        // A durable first epoch with a seed file, then a second epoch whose
        // first mutation is above mseq 1.
        _ = try await log.append(LogTestSupport.write("/dsh/workspace/seed.txt",
                                                      data: "seed"))
        _ = try await log.closeEpoch()
        _ = try await writeChunked(log,
                                   path: "/dsh/workspace/early.bin",
                                   chunks: 2)
        _ = try await log.closeEpoch()
        let accepted = await log.positions().ackedMseq

        // A legal truncation: the durable, fully materialized epoch 1 segments
        // are unlinked after the shorter manifest is written.
        let manifest = try XCTUnwrap(try ManifestStore(root: root).read())
        let segments = try LogTestSupport.segments(in: root)
        let epochOne = segments.filter { $0.epoch == 1 }
        XCTAssertFalse(epochOne.isEmpty)
        for segment in epochOne {
            try FileManager.default.removeItem(at: segment.url)
        }
        let remaining = segments.filter { $0.epoch != 1 && !$0.records.isEmpty }
        let truncated = Manifest(bootID: manifest.bootID,
                                 materializedUptoMseq: manifest.materializedUptoMseq,
                                 lastMseq: manifest.lastMseq,
                                 lastDurableEpoch: manifest.lastDurableEpoch,
                                 segments: remaining.map(\.manifestSegment))
        try ManifestStore(root: root).write(truncated)
        XCTAssertGreaterThan(try XCTUnwrap(remaining.first).header.firstMseq, 1)

        // Now the completed early write is missing from the copy. The WAL
        // retains its base, but the retained history does not start at mseq 1,
        // so rebuilding would drop the truncated seed's files.
        XCTAssertGreaterThan(accepted, 1)
        try FileManager.default.removeItem(at: materializedURL(root,
                                                               "/dsh/workspace/early.bin"))
        var failure: Error?
        do {
            _ = try await log.sealForStop()
        } catch {
            failure = error
        }
        let message = failure.map { String(describing: $0) } ?? ""
        XCTAssertTrue(message.contains("materialized copy diverges"),
                      "the stop invariant must fail loud: \(message)")
        XCTAssertTrue(message.contains("/dsh/workspace/early.bin"),
                      "the failure reason must name the divergent path: \(message)")
        XCTAssertTrue(message.contains("missingFile"),
                      "the failure reason must carry a machine-readable kind: \(message)")
    }

}
