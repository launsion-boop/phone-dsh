// SPDX-License-Identifier: MIT
// WorkspaceLog facade: append/materialize/acks/epochs/overlay/metrics/resync.

import Foundation
import XCTest
@testable import PhoneDSHLog
import PhoneDSHWire

final class WorkspaceLogFacadeTests: XCTestCase {
    private func materializedURL(_ root: URL, _ vfsPath: String) -> URL {
        let relative = String(vfsPath.dropFirst("/dsh/".count))
        return WorkspacePaths(root: root).materializedDirectory.appendingPathComponent(relative)
    }

    func testAppendMaterializesWritesAndUpdatesTheManifest() async throws {
        let root = LogTestSupport.root(for: self)
        let configuration = LogTestSupport.configuration(root: root)
        let log = try WorkspaceLog(configuration: configuration,
                                   bootID: LogTestSupport.bootID())
        let first = try await log.append(LogTestSupport.write(
            "/dsh/workspace/a.txt", data: "alpha", mode: 0o600))
        let second = try await log.append(LogTestSupport.mkdir("/dsh/workspace/dir"))
        let third = try await log.append(LogTestSupport.write(
            "/dsh/home/sessions/s.json", data: "{}"))
        XCTAssertEqual([first, second, third], [1, 2, 3])

        XCTAssertEqual(try String(contentsOf: materializedURL(root, "/dsh/workspace/a.txt"),
                                  encoding: .utf8), "alpha")
        XCTAssertEqual(try LogFile.fileMode(materializedURL(root, "/dsh/workspace/a.txt")),
                       0o600)
        let manifest = try XCTUnwrap(try ManifestStore(root: root).read())
        XCTAssertEqual(manifest.materializedUptoMseq, 3)
        XCTAssertEqual(manifest.lastMseq, 3)
        let watermark = try await log.materialize()
        XCTAssertEqual(watermark, 3)
    }

    func testLevelOneAckThenLevelTwoOnlyAtClose() async throws {
        let root = LogTestSupport.root(for: self)
        let log = try WorkspaceLog(configuration: LogTestSupport.configuration(root: root),
                                   bootID: LogTestSupport.bootID())
        let collector = AckCollector(log.acks())
        _ = try await log.append(LogTestSupport.write("/dsh/workspace/a", data: "a"))
        let levelOne = await collector.waitForCount(1)
        XCTAssertEqual(levelOne.first?.level, .write)
        XCTAssertEqual(levelOne.first?.uptoMseq, 1)
        XCTAssertFalse(collector.values.contains { $0.level == .epochFsync })

        let ack = try await log.closeEpoch()
        XCTAssertEqual(ack.level, .epochFsync)
        XCTAssertEqual(ack.uptoMseq, 1)
        let all = await collector.waitForCount(2)
        XCTAssertEqual(all.last?.level, .epochFsync)
        let manifest = try XCTUnwrap(try ManifestStore(root: root).read())
        XCTAssertEqual(manifest.lastDurableEpoch, 1)
    }

    func testLateWorkspaceAckSubscriberSeesTheCurrentWatermark() async throws {
        let root = LogTestSupport.root(for: self)
        let log = try WorkspaceLog(configuration: LogTestSupport.configuration(root: root),
                                   bootID: LogTestSupport.bootID())
        // The level-1 ack is emitted before acks() is called: the cumulative
        // stream must replay the current watermark instead of making the
        // channel wait for the next append (P0-1 regression).
        let mseq = try await log.append(LogTestSupport.write("/dsh/workspace/a", data: "a"))
        let collector = AckCollector(log.acks())
        let acks = await collector.waitForCount(1)
        XCTAssertEqual(acks.first?.level, .write)
        XCTAssertEqual(acks.first?.uptoMseq, mseq)
    }

    func testJournalAcksCoverEveryRecordBeforeTheBridgeConsumesThem() async throws {
        let root = LogTestSupport.root(for: self)
        let log = try WorkspaceLog(configuration: LogTestSupport.configuration(root: root),
                                   bootID: LogTestSupport.bootID())
        for jseq in UInt64(1)...16 {
            _ = try await log.journalAppend(JournalBody(jseq: jseq, sessionID: "session",
                                                        record: Data("tool-\(jseq)".utf8)))
        }
        // Enumerate after the writes happened; none of the level-1 journal
        // acknowledgements may have been dropped by the writer/bridge startup
        // race (P0-1 regression).
        let collector = AckCollector(log.journalAcks())
        let acks = await collector.waitForCount(16)
        XCTAssertEqual(Set(acks.map(\.uptoJseq)), Set((1...16).map(UInt64.init)))
    }

    func testManifestIsRewrittenOnlyAfterMaterializedChangesAreDurable() async throws {
        let root = LogTestSupport.root(for: self)
        let log = try WorkspaceLog(configuration: LogTestSupport.configuration(root: root),
                                   bootID: LogTestSupport.bootID())
        let observed = LockedValues<UInt64>()
        await log.setMaterializerFsyncObserverForTesting {
            let manifest = try? ManifestStore(root: root).read()
            observed.append(manifest?.materializedUptoMseq ?? 0)
        }
        _ = try await log.append(LogTestSupport.write("/dsh/workspace/a", data: "a"))
        _ = try await log.append(LogTestSupport.write("/dsh/workspace/b", data: "b"))
        // At each D18 step-1 fsync the manifest still names the previous
        // watermark; the rewrite happens afterwards (P0-2 regression).
        XCTAssertEqual(observed.values, [0, 1])
        let manifest = try XCTUnwrap(try ManifestStore(root: root).read())
        XCTAssertEqual(manifest.materializedUptoMseq, 2)
    }

    func testBarrierLevelOneAndLevelTwo() async throws {
        let root = LogTestSupport.root(for: self)
        let log = try WorkspaceLog(configuration: LogTestSupport.configuration(root: root),
                                   bootID: LogTestSupport.bootID())
        let mseq = try await log.append(LogTestSupport.write("/dsh/workspace/a", data: "a"))
        let levelOne = try await log.barrier(level: .write, upto: mseq)
        XCTAssertEqual(levelOne.level, .write)
        XCTAssertGreaterThanOrEqual(levelOne.uptoMseq, mseq)
        let levelTwo = try await log.barrier(level: .epochFsync, upto: mseq)
        XCTAssertEqual(levelTwo.level, .epochFsync)
        XCTAssertEqual(levelTwo.uptoMseq, mseq)
    }

    func testBarrierRejectsAnUnallocatedMseq() async throws {
        let root = LogTestSupport.root(for: self)
        let log = try WorkspaceLog(configuration: LogTestSupport.configuration(root: root),
                                   bootID: LogTestSupport.bootID())
        do {
            _ = try await log.barrier(level: .write, upto: 9)
            XCTFail("expected invalidBarrier")
        } catch let error as LogError {
            guard case .invalidBarrier = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testJournalIsEpochSyncedWithTheWAL() async throws {
        let root = LogTestSupport.root(for: self)
        let log = try WorkspaceLog(configuration: LogTestSupport.configuration(root: root),
                                   bootID: LogTestSupport.bootID())
        let collector = AckCollector(log.journalAcks())
        _ = try await log.journalAppend(JournalBody(jseq: 1, sessionID: "session",
                                                    record: Data("tool".utf8)))
        _ = try await log.append(LogTestSupport.write("/dsh/workspace/a", data: "a"))
        let acks = await collector.waitForCount(1)
        XCTAssertEqual(acks.first?.level, .write)
        _ = try await log.closeEpoch()
        let all = await collector.waitForCount(2)
        XCTAssertEqual(all.last?.level, .epochFsync)
        XCTAssertEqual(all.last?.uptoJseq, 1)
        let jseq = await log.journalLastJseq(sessionID: "session")
        XCTAssertEqual(jseq, 1)
    }

    func testOverlayWritesATarFileForTheBoot() async throws {
        let root = LogTestSupport.root(for: self)
        let log = try WorkspaceLog(configuration: LogTestSupport.configuration(root: root),
                                   bootID: LogTestSupport.bootID())
        _ = try await log.append(LogTestSupport.write("/dsh/workspace/a.txt", data: "alpha"))
        _ = try await log.append(LogTestSupport.write("/dsh/home/note.txt", data: "note"))
        let bootID = "00112233445566778899aabbccddeeff"
        let url = try await log.overlay(bootID: bootID)
        XCTAssertEqual(url.lastPathComponent, "overlay-\(bootID).tar")
        let archive = try Data(contentsOf: url)
        XCTAssertEqual([UInt8](archive.prefix(2)), [0x1f, 0x8b],
                       "D21: the boot overlay is a gzip member")
        let entries = try TarParser.parse(try GzipParser.decompress(archive))
        let names = entries.map(\.name)
        XCTAssertTrue(names.contains("workspace/a.txt"))
        XCTAssertTrue(names.contains("home/note.txt"))
        let data = try await log.packOverlay()
        XCTAssertEqual(data, try Data(contentsOf: url))

        do {
            _ = try await log.overlay(bootID: "not-a-boot-id")
            XCTFail("expected a rejected overlay name")
        } catch let error as LogError {
            guard case .corrupt = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testMetricsGroupBytesByTheMemoryProxyPrefixes() async throws {
        let root = LogTestSupport.root(for: self)
        let log = try WorkspaceLog(configuration: LogTestSupport.configuration(root: root),
                                   bootID: LogTestSupport.bootID())
        _ = try await log.append(LogTestSupport.write(
            "/dsh/workspace/a.bin", bytes: Data(repeating: 0x41, count: 10)))
        _ = try await log.append(LogTestSupport.write(
            "/dsh/home/sessions/s.bin", bytes: Data(repeating: 0x42, count: 5)))
        _ = try await log.append(LogTestSupport.write(
            "/dsh/home/other.bin", bytes: Data(repeating: 0x43, count: 7)))
        let metrics = try await log.metrics()
        XCTAssertEqual(metrics.workspaceBytes, 10)
        XCTAssertEqual(metrics.homeSessionsBytes, 5)
        XCTAssertEqual(metrics.otherBytes, 7)
        XCTAssertEqual(metrics.tmpBytes, 0)
        XCTAssertEqual(metrics.totalVFSBytes, 22)
        XCTAssertEqual(metrics.bytes(forPrefix: "/dsh/workspace"), 10)
        XCTAssertEqual(metrics.bytes(forPrefix: "/dsh/home/sessions"), 5)
        XCTAssertGreaterThan(metrics.walBytes, 0)
        XCTAssertGreaterThan(metrics.journalBytes, 0)
    }

    func testRecoverReturnsTheHelloPositions() async throws {
        let root = LogTestSupport.root(for: self)
        let configuration = LogTestSupport.configuration(root: root)
        let log = try WorkspaceLog(configuration: configuration,
                                   bootID: LogTestSupport.bootID())
        _ = try await log.append(LogTestSupport.write("/dsh/workspace/a", data: "a"))
        _ = try await log.append(LogTestSupport.write("/dsh/workspace/b", data: "b"))
        let report = try await log.recover()
        XCTAssertEqual(report.materializedUptoMseq, 2)
        XCTAssertEqual(report.nextMseq, 3)
        XCTAssertEqual(report.ackedMseq, 2)
        let positions = await log.positions()
        XCTAssertEqual(positions.nextMseq, 3)
        XCTAssertEqual(positions.ackedMseq, 2)
    }

    func testBaseMismatchRequestsResyncAndRepairSettlesIt() async throws {
        let root = LogTestSupport.root(for: self)
        let log = try WorkspaceLog(configuration: LogTestSupport.configuration(root: root),
                                   bootID: LogTestSupport.bootID())
        let resyncCollector = AckCollector(log.resyncRequests())

        _ = try await log.append(LogTestSupport.write("/dsh/workspace/log.txt", data: "hello"))
        let mismatchMseq = try await log.append(
            LogTestSupport.append("/dsh/workspace/log.txt", from: 6, data: "world"))
        XCTAssertEqual(mismatchMseq, 2)
        let stalled = try await log.materialize()
        XCTAssertEqual(stalled, 1)
        let pending = await log.pendingResyncPaths()
        XCTAssertEqual(pending, ["/dsh/workspace/log.txt"])
        let resync = await resyncCollector.waitForCount(1)
        XCTAssertEqual(resync.first, "/dsh/workspace/log.txt")

        let repairMseq = try await log.append(LogTestSupport.write(
            "/dsh/workspace/log.txt", data: "hello world"))
        XCTAssertEqual(repairMseq, 3)
        let watermark = try await log.materialize()
        XCTAssertEqual(watermark, 3)
        XCTAssertEqual(try String(contentsOf: materializedURL(root, "/dsh/workspace/log.txt"),
                                  encoding: .utf8), "hello world")
    }

    func testReopeningTheWorkspaceLogContinuesMseqAndMaterializedTree() async throws {
        let root = LogTestSupport.root(for: self)
        let configuration = LogTestSupport.configuration(root: root)
        do {
            let first = try WorkspaceLog(configuration: configuration,
                                         bootID: LogTestSupport.bootID(0x01))
            _ = try await first.append(LogTestSupport.write(
                "/dsh/workspace/keep.txt", data: "kept"))
            _ = try await first.append(LogTestSupport.write(
                "/dsh/workspace/gone.txt", data: "gone"))
            _ = try await first.closeEpoch()
        }
        let second = try WorkspaceLog(configuration: configuration,
                                      bootID: LogTestSupport.bootID(0x02))
        let report = try await second.recover()
        XCTAssertTrue(report.coldRecovery)
        XCTAssertEqual(report.materializedUptoMseq, 2)
        XCTAssertEqual(report.nextMseq, 3)
        XCTAssertEqual(try String(contentsOf: materializedURL(root, "/dsh/workspace/keep.txt"),
                                  encoding: .utf8), "kept")
        let mseq = try await second.append(LogTestSupport.write(
            "/dsh/workspace/next.txt", data: "next"))
        XCTAssertEqual(mseq, 3)
        let again = try await second.recover()
        XCTAssertEqual(again.materializedUptoMseq, 3)
        XCTAssertEqual(again.nextMseq, 4)
        let third = try await second.recover()
        XCTAssertEqual(third.materializedUptoMseq, 3, "recover() is idempotent")
    }

    /// The swap's crash window: `materialized/` was renamed to
    /// `.materialized.previous` but the new tree was not renamed into place.
    /// Opening the facade must restore the old tree before it creates an empty
    /// `materialized/`, never delete the only copy.
    func testReopeningRestoresPreviousTreeBeforeMaterializedIsCreated() async throws {
        let root = LogTestSupport.root(for: self)
        let configuration = LogTestSupport.configuration(root: root)
        do {
            let first = try WorkspaceLog(configuration: configuration,
                                         bootID: LogTestSupport.bootID(0x31))
            _ = try await first.append(LogTestSupport.write(
                "/dsh/workspace/restored.txt", data: "restored"))
            _ = try await first.closeEpoch()
        }
        let paths = WorkspacePaths(root: root)
        let previous = root.appendingPathComponent(".materialized.previous", isDirectory: true)
        try FileManager.default.moveItem(at: paths.materializedDirectory, to: previous)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.materializedDirectory.path),
                       "the fixture must start with the crash-window shape")

        let second = try WorkspaceLog(configuration: configuration,
                                      bootID: LogTestSupport.bootID(0x32))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.materializedDirectory.path),
                      "the previous tree must be restored as materialized/")
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path),
                       "the restored previous tree must be cleared")
        XCTAssertEqual(try String(contentsOf: materializedURL(
            root, "/dsh/workspace/restored.txt"), encoding: .utf8), "restored")
        let report = try await second.recover()
        XCTAssertEqual(report.materializedUptoMseq, 1)
    }

    func testConcurrentAppendsAreNumberedAndMaterializedInOrder() async throws {
        let root = LogTestSupport.root(for: self)
        let log = try WorkspaceLog(configuration: LogTestSupport.configuration(root: root),
                                   bootID: LogTestSupport.bootID())
        let mseqs = try await withThrowingTaskGroup(of: UInt64.self) { group in
            for index in 0..<6 {
                group.addTask {
                    try await log.append(LogTestSupport.write(
                        "/dsh/workspace/concurrent-\(index).txt",
                        data: "value-\(index)"))
                }
            }
            var values: [UInt64] = []
            for try await mseq in group {
                values.append(mseq)
            }
            return values.sorted()
        }
        XCTAssertEqual(mseqs, [1, 2, 3, 4, 5, 6])
        let watermark = try await log.materialize()
        XCTAssertEqual(watermark, 6)
        for index in 0..<6 {
            let text = try String(contentsOf: materializedURL(
                root, "/dsh/workspace/concurrent-\(index).txt"), encoding: .utf8)
            XCTAssertEqual(text, "value-\(index)")
        }
    }

    // MARK: - Single-file budget refusal (channel.md §6, §8)

    /// A refused mutation appends nothing and consumes no mseq: the WAL bytes
    /// and the manifest stay byte-identical, and the next accepted mutation
    /// reuses the refused mseq and lands in the WAL and the materialized copy.
    func testSingleFileRefusalLeavesTheWALAndManifestUnchangedAndReusesTheMseq()
        async throws {
        let root = LogTestSupport.root(for: self)
        let configuration = LogTestSupport.configuration(root: root,
                                                         singleFileLimitBytes: 8)
        let log = try WorkspaceLog(configuration: configuration,
                                   bootID: LogTestSupport.bootID())
        let path = "/dsh/workspace/cap.bin"
        let first = try await log.append(LogTestSupport.write(path, data: "abc"))
        XCTAssertEqual(first, 1)

        let paths = WorkspacePaths(root: root)
        let walBefore = try walSnapshot(paths.walDirectory)
        let manifestBefore = try? Data(contentsOf: paths.manifestURL)

        do {
            _ = try await log.append(LogTestSupport.write(path, data: "0123456789"))
            XCTFail("a mutation past the single-file limit must be refused")
        } catch LogError.vfsRefused(let refusedPath, let limit, let projected) {
            XCTAssertEqual(refusedPath, path)
            XCTAssertEqual(limit, 8)
            XCTAssertEqual(projected, 10)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(try walSnapshot(paths.walDirectory), walBefore,
                       "a refused mutation must not touch the WAL")
        XCTAssertEqual(try? Data(contentsOf: paths.manifestURL), manifestBefore,
                       "a refused mutation must not touch the manifest")
        let refusedPositions = await log.positions()
        XCTAssertEqual(refusedPositions.nextMseq, 2,
                       "the refused mseq was not consumed")
        XCTAssertEqual(refusedPositions.ackedMseq, 1)

        // The worker shrinks to the budget and resends at the same mseq.
        let second = try await log.append(LogTestSupport.write(path, data: "01234567"))
        XCTAssertEqual(second, 2)
        XCTAssertEqual(try String(contentsOf: materializedURL(root, path),
                                  encoding: .utf8), "01234567")
        let records = try LogTestSupport.records(in: root)
        XCTAssertEqual(records.map(\.mseq), [1, 2])
        XCTAssertEqual(try records[1].mutationBody().data, Data("01234567".utf8))
    }

    private func walSnapshot(_ directory: URL) throws -> [String: Data] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .sorted()
        var snapshot: [String: Data] = [:]
        for name in names {
            let url = directory.appendingPathComponent(name)
            snapshot[name] = try Data(contentsOf: url)
        }
        return snapshot
    }
}
