// SPDX-License-Identifier: MIT
// G2-FIX-80: byte fidelity of the park/resume persistence chain.
//
// A workspace file whose bytes are not pure ASCII must survive the whole
// sequence WAL append -> materialize -> overlay pack unchanged. The classes
// below cover the three shapes the real-model scenario exposed: a two-byte
// UTF-8 scalar ("García"), a four-byte UTF-8 scalar (an emoji) and arbitrary
// non-UTF-8 binary bytes. A byte mismatch at any boundary makes the resumed
// Worker serve silently corrupted content, so every boundary is asserted here.

import Foundation
import XCTest
@testable import PhoneDSHLog
import PhoneDSHWire

final class ByteFidelityParkResumeTests: XCTestCase {
    private struct Payload {
        let name: String
        let vfsPath: String
        let bytes: Data
    }

    /// The three payload classes of the G2-FIX-80 acceptance.
    private var payloads: [Payload] {
        [
            Payload(name: "two-byte UTF-8",
                    vfsPath: "/dsh/workspace/text/store.py",
                    bytes: Data("name = \"García\"\n".utf8)),
            Payload(name: "four-byte UTF-8",
                    vfsPath: "/dsh/workspace/text/emoji.txt",
                    // U+1F600 is f0 9f 98 80; the surrounding newline keeps the
                    // file a normal text file.
                    bytes: Data("face = \"\u{1F600}\"\n".utf8)),
            Payload(name: "non-UTF-8 binary",
                    vfsPath: "/dsh/workspace/text/blob.bin",
                    // 0x80 and 0xff alone are invalid UTF-8; the sequence
                    // ed a0 80 is a UTF-8 surrogate and must stay untouched.
                    bytes: Data([0x00, 0x01, 0xff, 0x80, 0xc3, 0x28, 0xed, 0xa0, 0x80, 0x0a])),
        ]
    }

    private func entryName(for payload: Payload) -> String {
        String(payload.vfsPath.dropFirst("/dsh/".count))
    }

    /// WAL append -> WAL scan/decode: the bytes the host durably recorded must be
    /// exactly the bytes the Worker published.
    func testWALRoundTripKeepsEveryByte() async throws {
        let root = LogTestSupport.root(for: self)
        let writer = try WALWriter(configuration: LogTestSupport.configuration(root: root),
                                   bootID: LogTestSupport.bootID())
        var mseqs: [UInt64] = []
        for payload in payloads {
            mseqs.append(try await writer.append(
                LogTestSupport.write(payload.vfsPath, bytes: payload.bytes)))
        }
        try await writer.flush()
        let records = try LogTestSupport.records(in: root)
        XCTAssertEqual(records.map(\.mseq), mseqs)
        for (record, payload) in zip(records, payloads) {
            let body = try record.mutationBody()
            XCTAssertEqual(body.path, payload.vfsPath)
            XCTAssertEqual([UInt8](body.data), [UInt8](payload.bytes),
                           "WAL round trip diverged for \(payload.name)")
        }
    }

    /// WAL append -> materialized file -> overlay pack -> gzip inflate -> tar
    /// parse. This is the exact chain a park/resume cycle rebuilds the Worker
    /// VFS from.
    func testMaterializeAndOverlayKeepEveryByte() async throws {
        let root = LogTestSupport.root(for: self)
        let config = LogTestSupport.configuration(root: root)
        let log = try WorkspaceLog(configuration: config, bootID: LogTestSupport.bootID())
        for payload in payloads {
            _ = try await log.append(LogTestSupport.write(payload.vfsPath, bytes: payload.bytes))
        }
        // The park path seals the epoch before the Worker is torn down.
        _ = try await log.closeEpoch()

        let paths = WorkspacePaths(root: root)
        for payload in payloads {
            let materialized = paths.materializedDirectory
                .appendingPathComponent(entryName(for: payload))
            let onDisk = try Data(contentsOf: materialized)
            XCTAssertEqual([UInt8](onDisk), [UInt8](payload.bytes),
                           "materialized bytes diverged for \(payload.name)")
        }

        let bootID = "00112233445566778899aabbccddeeff"
        let overlayURL = try await log.overlay(bootID: bootID)
        let archive = try Data(contentsOf: overlayURL)
        XCTAssertEqual([UInt8](archive.prefix(2)), [0x1f, 0x8b],
                       "D21: the boot overlay is one gzip member")
        let entries = try TarParser.parse(try GzipParser.decompress(archive))
        for payload in payloads {
            let entry = try XCTUnwrap(entries.first { $0.name == entryName(for: payload) },
                                      "overlay is missing \(entryName(for: payload))")
            XCTAssertEqual([UInt8](entry.data), [UInt8](payload.bytes),
                           "overlay bytes diverged for \(payload.name)")
        }
    }

    /// The cold-start side of a park/resume cycle: the epoch is closed, the
    /// process is gone, and a new boot opens the same workspace. Recovery must
    /// not touch a single byte, and the rebuilt overlay must still match.
    func testColdRecoveryKeepsEveryByte() async throws {
        let root = LogTestSupport.root(for: self)
        let config = LogTestSupport.configuration(root: root)
        do {
            let firstBoot = try WorkspaceLog(configuration: config,
                                             bootID: LogTestSupport.bootID(0x11))
            for payload in payloads {
                _ = try await firstBoot.append(
                    LogTestSupport.write(payload.vfsPath, bytes: payload.bytes))
            }
            _ = try await firstBoot.closeEpoch()
        }
        let resumed = try WorkspaceLog(configuration: config,
                                       bootID: LogTestSupport.bootID(0x22))
        let watermark = try await resumed.materialize()
        XCTAssertEqual(watermark, UInt64(payloads.count))
        let archive = try await resumed.packOverlay()
        let entries = try TarParser.parse(try GzipParser.decompress(archive))
        for payload in payloads {
            let entry = try XCTUnwrap(entries.first { $0.name == entryName(for: payload) })
            XCTAssertEqual([UInt8](entry.data), [UInt8](payload.bytes),
                           "recovered overlay bytes diverged for \(payload.name)")
        }
    }

    /// Large-file publication uses appended mutations; the suffix path must be
    /// byte-exact as well (this is what the sink emits for a chunked write).
    func testAppendedMutationsKeepEveryByte() async throws {
        let root = LogTestSupport.root(for: self)
        let config = LogTestSupport.configuration(root: root)
        let log = try WorkspaceLog(configuration: config, bootID: LogTestSupport.bootID())
        let binary = Data((0..<600).map { UInt8($0 & 0xff) })
        var offset = 0
        let chunk = 128
        while offset < binary.count {
            let end = min(offset + chunk, binary.count)
            let suffix = Data(binary[offset..<end])
            let mutation = offset == 0
                ? LogTestSupport.write("/dsh/workspace/large.bin", bytes: suffix)
                : VfsMutationBody(op: .write, mode: 0o644, mflags: .appended,
                                  appendFrom: UInt64(offset),
                                  path: "/dsh/workspace/large.bin", data: suffix)
            _ = try await log.append(mutation)
            offset = end
        }
        _ = try await log.closeEpoch()
        let paths = WorkspacePaths(root: root)
        let onDisk = try Data(contentsOf: paths.materializedDirectory
            .appendingPathComponent("workspace/large.bin"))
        XCTAssertEqual([UInt8](onDisk), [UInt8](binary))
    }
}
