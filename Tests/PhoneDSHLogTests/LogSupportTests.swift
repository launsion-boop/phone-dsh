// SPDX-License-Identifier: MIT
// LogSupport: SHA-256 known answers, segment naming and configuration defaults.

import Foundation
import XCTest
@testable import PhoneDSHLog
import PhoneDSHWire

final class LogSupportTests: XCTestCase {
    func testSHA256KnownAnswers() {
        XCTAssertEqual(SHA256.hash(Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hash(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hash(Data("The quick brown fox jumps over the lazy dog".utf8)),
                       "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
    }

    func testSHA256StreamingHasherAndFileHashMatchTheOneShotDigest() throws {
        let payload = Data(repeating: 0x5A, count: 100_000) + Data("tail".utf8)
        let hasher = SHA256.Hasher()
        var offset = 0
        while offset < payload.count {
            let end = min(offset + 7_919, payload.count)
            hasher.update(payload.subdata(in: offset..<end))
            offset = end
        }
        XCTAssertEqual(hasher.hexDigest, SHA256.hash(payload))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-sha-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try payload.write(to: url)
        XCTAssertEqual(try SHA256.hashFile(url), SHA256.hash(payload))
    }

    func testGroupCommitDefaultsMatchTheContract() {
        let configuration = WorkspaceLogConfiguration(
            root: FileManager.default.temporaryDirectory)
        XCTAssertEqual(configuration.groupCommitDelay, 0.002)
        XCTAssertEqual(configuration.groupCommitBytes, 256 * 1024)
        XCTAssertEqual(WorkspaceLogConfiguration.defaultSegmentRollBytes, 8 * 1024 * 1024)
        XCTAssertEqual(WorkspaceLogConfiguration.defaultSingleFileLimitBytes,
                       WireLimits.defaultSingleFileLimitBytes)
        XCTAssertEqual(WorkspaceLogConfiguration.defaultSingleFileLimitBytes,
                       128 * WireLimits.mebibyte)
    }

    // MARK: - Resource refusal classification (channel.md §4.8, §8)

    func testLogErrorVFSRefusedCarriesTheWireResourceRefusal() {
        let error = LogError.vfsRefused(path: "/dsh/workspace/a",
                                        limit: 64, projected: 80)
        let refusal = error.vfsResourceRefusal
        XCTAssertEqual(refusal?.path, "/dsh/workspace/a")
        XCTAssertEqual(refusal?.limitBytes, 64)
        XCTAssertEqual(refusal?.projectedBytes, 80)
        XCTAssertEqual(refusal?.reason, .fileTooLarge)
        XCTAssertTrue(refusal?.message.contains("VFS_REFUSED") == true)
        XCTAssertTrue(refusal?.message.contains("file://") == false,
                      "diagnostics never leak a host URL")

        // The ordered channel catches the error through this existential
        // (ChannelServer has no Log dependency), so pin that cast here.
        let thrown: any Error = LogError.vfsRefused(path: "/dsh/workspace/a",
                                                    limit: 64, projected: 80)
        let routed = (thrown as? any VFSResourceRefusalProviding)?.vfsResourceRefusal
        XCTAssertEqual(routed, refusal)
    }

    func testOnlyTheSingleFileRefusalIsAResourceAnswer() {
        // WAL corruption, materialization I/O and a still-exceeded quota stay
        // host defects (wal.md §9/§10), so the channel must keep failing loud.
        XCTAssertNil(LogError.corrupt("crc").vfsResourceRefusal)
        XCTAssertNil(LogError.materializationFailed("io").vfsResourceRefusal)
        XCTAssertNil(LogError.quotaExceeded(resource: .wal, limit: 8, used: 9)
            .vfsResourceRefusal)
        XCTAssertNil(LogError.closed.vfsResourceRefusal)
    }

    func testSegmentNamesAreZeroPaddedAndParsed() throws {
        let name = try WALSegmentName(epoch: 7, segment: 3)
        XCTAssertEqual(name.fileName, "00000007.000003.xlwal")
        XCTAssertEqual(name.manifestFile, "wal/00000007.000003.xlwal")
        XCTAssertEqual(WALSegmentName(fileName: "00000007.000003.xlwal"), name)
        XCTAssertNil(WALSegmentName(fileName: "not-a-segment"))
        XCTAssertNil(WALSegmentName(fileName: "00000007.000003.xlwal.bak"))
    }

    func testManifestRoundTripsAndRejectsForeignFormats() throws {
        let manifest = Manifest(bootID: "00112233445566778899aabbccddeeff",
                                materializedUptoMseq: 4,
                                lastMseq: 5,
                                lastDurableEpoch: 2,
                                segments: [ManifestSegment(file: "wal/00000001.000000.xlwal",
                                                           epoch: 1, firstMseq: 1, lastMseq: 5)])
        let data = try manifest.encoded()
        XCTAssertEqual(try Manifest.decode(data), manifest)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"materialized_upto_mseq\":4"))
        XCTAssertTrue(text.contains("\"wal/00000001.000000.xlwal\""))
        var broken = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        broken["format"] = 2
        let brokenData = try JSONSerialization.data(withJSONObject: broken)
        XCTAssertThrowsError(try Manifest.decode(brokenData))
    }

    func testAckBroadcasterReplaysRetainedElementsToALateSubscriber() async throws {
        let broadcaster = AckBroadcaster<Int>(replayLimit: 2)
        // Yielded with no subscriber at all: a cumulative observer that starts
        // afterwards must still learn the current state (P0-1).
        broadcaster.yield(1)
        broadcaster.yield(2)
        broadcaster.yield(3)
        let collector = AckCollector(broadcaster.stream())
        let replayed = await collector.waitForCount(2)
        XCTAssertEqual(replayed, [2, 3])
        broadcaster.yield(4)
        let live = await collector.waitForCount(3)
        XCTAssertEqual(live, [2, 3, 4])
    }
}
