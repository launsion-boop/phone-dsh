// SPDX-License-Identifier: MIT
// W12-BIGFILE / ENG-08 regression: the single-file budget must be worth its
// own workspace bucket, and the WAL/materializer must converge after a large
// file is published as appended chunks and the process dies mid-write.
//
// These tests are component-level: they drive the landed BudgetTable,
// WorkspaceLog and Materializer directly, with no WebKit and no device.

import Darwin
import Foundation
import XCTest
import PhoneDSHController
import PhoneDSH
import PhoneDSHLog
import PhoneDSHWire

final class BigFileBudgetTests: XCTestCase {
    private let mib = 1024 * 1024

    private func temporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-bigfile-\(name)-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func materializedFile(_ root: URL, _ vfsPath: String) -> URL {
        let relative = String(vfsPath.dropFirst("/dsh/".count))
        return WorkspacePaths(root: root)
            .materializedDirectory
            .appendingPathComponent(relative)
    }

    // MARK: - Budget coherence

    /// The 8 GiB workspace bucket must be able to hold two files at the
    /// single-file cap plus session headroom; otherwise the advertised cap is
    /// unreachable no matter what the worker write path permits.
    func testEveryTierWorkspaceCanHoldTwoMaximumFiles() {
        for tier in DeviceTier.allCases {
            let table = BudgetTable.table(for: tier)
            XCTAssertGreaterThanOrEqual(
                table.workspaceBytes, table.singleFileBytes * 2,
                "\(tier): workspace bucket must hold two maximum files")
            XCTAssertGreaterThanOrEqual(
                table.vfsLogicalBytes,
                table.workspaceBytes + table.sessionBytes + table.tmpBytes,
                "\(tier): VFS logical cap must cover the three buckets")
            XCTAssertGreaterThanOrEqual(
                table.engineHeapBytes, table.vfsLogicalBytes,
                "\(tier): the VFS lives in the engine heap, so the heap cap must cover it")
        }
        XCTAssertEqual(BudgetTable.eightGB.singleFileBytes, 128 * mib)
        XCTAssertEqual(BudgetTable.sixGB.singleFileBytes, 48 * mib)
        XCTAssertEqual(BudgetTable.fourGB.singleFileBytes, 32 * mib)
        XCTAssertEqual(BudgetTable.threeGB.singleFileBytes, 16 * mib)
        XCTAssertGreaterThanOrEqual(BudgetTable.eightGB.workspaceBytes, 288 * mib)
    }

    /// The `a + k × MB` target must cover the larger file and workspace: one
    /// 128 MiB file costs 3 + 0.05 × 128 = 9.4 s; the 388 MB VFS cap costs
    /// 22.4 s.
    func testRecoveryTargetCoversTheLargerFileAndWorkspace() {
        let table = BudgetTable.eightGB
        XCTAssertEqual(table.recoveryTimeTargetSeconds(forMaterializedMegabytes: 128),
                       9.4, accuracy: 0.0001)
        XCTAssertEqual(table.recoveryTimeTargetSeconds(forMaterializedMegabytes: 388),
                       22.4, accuracy: 0.0001)
    }

    // MARK: - Configuration, tier gate and Worker exposure

    /// The host may raise the single-file budget; the workspace bucket, VFS
    /// logical cap and engine heap must grow with it so the advertised limit
    /// stays reachable. The default configuration is the 8 GiB row.
    func testConfigurationRaisesBudgetsToFitAConfiguredFileLimit() throws {
        let root = try temporaryRoot("config")
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = try XCTUnwrap(URL(string: "http://127.0.0.1:1"))

        let raised = PhoneDSHConfiguration(
            workspaceRoot: root,
            token: "token",
            origin: origin,
            deviceTier: .eightGB,
            singleFileLimitBytes: 128 * mib)
        XCTAssertEqual(raised.singleFileLimitBytes, 128 * mib)
        XCTAssertEqual(raised.budgets.singleFileBytes, 128 * mib)
        XCTAssertGreaterThanOrEqual(raised.budgets.workspaceBytes,
                                    raised.budgets.singleFileBytes * 2)
        XCTAssertGreaterThanOrEqual(raised.budgets.vfsLogicalBytes,
                                    raised.budgets.workspaceBytes
                                        + raised.budgets.sessionBytes
                                        + raised.budgets.tmpBytes)
        XCTAssertGreaterThanOrEqual(raised.budgets.engineHeapBytes,
                                    raised.budgets.vfsLogicalBytes)
        XCTAssertTrue(raised.budgets.isCoherent)
        XCTAssertEqual(raised.log.singleFileLimitBytes, 128 * mib)

        let defaulted = PhoneDSHConfiguration(
            workspaceRoot: root, token: "token", origin: origin,
            deviceTier: .eightGB)
        XCTAssertEqual(defaulted.singleFileLimitBytes, 128 * mib)
        XCTAssertEqual(defaulted.budgets, BudgetTable.eightGB)
    }

    /// The 12 GiB row accepts 256 MiB files; the 8 GiB row stays capped at
    /// its 128 MiB maximum even when the host asks for more.
    func testTwelveGiBTierAcceptsThe256MiBLimitAndTheEightGiBRowDoesNot() throws {
        let root = try temporaryRoot("twelve")
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = try XCTUnwrap(URL(string: "http://127.0.0.1:1"))

        let twelve = PhoneDSHConfiguration(
            workspaceRoot: root, token: "token", origin: origin,
            deviceTier: .twelveGB, singleFileLimitBytes: 256 * mib)
        XCTAssertEqual(twelve.singleFileLimitBytes, 256 * mib)
        XCTAssertEqual(twelve.budgets.singleFileBytes, 256 * mib)
        XCTAssertTrue(twelve.budgets.isCoherent)
        XCTAssertEqual(twelve.budgets.workspaceBytes, 576 * mib)

        let eight = PhoneDSHConfiguration(
            workspaceRoot: root, token: "token", origin: origin,
            deviceTier: .eightGB, singleFileLimitBytes: 256 * mib)
        XCTAssertEqual(eight.singleFileLimitBytes, 128 * mib)
    }

    /// The 4 GiB and ≤3 GiB tiers must gate a larger host request instead of
    /// accepting a bucket the device cannot hold.
    func testSmallDeviceTiersGateTheSingleFileLimit() throws {
        let root = try temporaryRoot("gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = try XCTUnwrap(URL(string: "http://127.0.0.1:1"))

        let four = PhoneDSHConfiguration(
            workspaceRoot: root, token: "token", origin: origin,
            deviceTier: .fourGB, singleFileLimitBytes: 128 * mib)
        XCTAssertEqual(four.singleFileLimitBytes, 32 * mib)
        XCTAssertGreaterThanOrEqual(four.budgets.workspaceBytes, 64 * mib)

        let three = PhoneDSHConfiguration(
            workspaceRoot: root, token: "token", origin: origin,
            deviceTier: .threeGB, singleFileLimitBytes: 128 * mib)
        XCTAssertEqual(three.singleFileLimitBytes, 16 * mib)
        XCTAssertGreaterThanOrEqual(three.budgets.workspaceBytes, 32 * mib)

        let clampedLow = PhoneDSHConfiguration(
            workspaceRoot: root, token: "token", origin: origin,
            deviceTier: .sixGB, singleFileLimitBytes: 1)
        XCTAssertEqual(clampedLow.singleFileLimitBytes,
                       BudgetTable.minimumSingleFileLimitBytes)
    }

    // MARK: - Heap proxy drives the same actions

    /// Append-amplification pressure can exceed the engine heap while the VFS
    /// bytes stay within budget; the heap sample must drive the same
    /// clear-tmp -> planned-restart -> handoff sequence and fail loud.
    func testEngineHeapProxyTriggersTheBudgetActions() async {
        let table = BudgetTable.eightGB
        let monitor = BudgetMonitor(table: table)
        let over = MemoryProxySample(
            vfsBytesByPrefix: ["/dsh/workspace": 1 * mib],
            sessionBytes: 0,
            webContentTerminations: 0,
            engineHeapBytes: table.engineHeapBytes + 1)

        let first = await monitor.evaluate(over)
        XCTAssertEqual(first.action, .clearTmp)
        XCTAssertEqual(first.engineHeapBytes, table.engineHeapBytes + 1)
        XCTAssertEqual(first.engineHeapLimitBytes, table.engineHeapBytes)
        let second = await monitor.evaluate(over)
        XCTAssertEqual(second.action, .plannedRestart)
        let third = await monitor.evaluate(over)
        XCTAssertEqual(third.action, .handoff)
        let fourth = await monitor.evaluate(over)
        XCTAssertTrue(fourth.hardFail)
        XCTAssertNil(fourth.action)

        await monitor.reset()
        let clear = await monitor.evaluate(MemoryProxySample(
            vfsBytesByPrefix: ["/dsh/workspace": 1 * mib],
            sessionBytes: 0,
            webContentTerminations: 0,
            engineHeapBytes: 1 * mib))
        XCTAssertNil(clear.action)
        XCTAssertEqual(clear.engineHeapBytes, 1 * mib)
        XCTAssertEqual(clear.engineHeapLimitBytes, table.engineHeapBytes)
    }

    /// `preview` is the read-only form of an evaluation: repeated reads stay on
    /// the same pending action, and only `evaluate` consumes the episode. The
    /// App polls diagnostics from its UI refresh loop; that poll must not turn
    /// one heap spike into plannedRestart -> handoff -> hardFail on its own.
    func testBudgetPreviewDoesNotConsumeThePressureEpisode() async {
        let table = BudgetTable.eightGB
        let monitor = BudgetMonitor(table: table)
        let over = MemoryProxySample(
            vfsBytesByPrefix: ["/dsh/workspace": 1 * mib],
            sessionBytes: 0,
            webContentTerminations: 0,
            engineHeapBytes: table.engineHeapBytes + 1)

        let preview = await monitor.preview(over)
        XCTAssertEqual(preview.action, .clearTmp)
        let secondPreview = await monitor.preview(over)
        XCTAssertEqual(secondPreview.action, .clearTmp,
                       "preview must not advance the pressure episode")

        let first = await monitor.evaluate(over)
        XCTAssertEqual(first.action, .clearTmp)
        let nextPreview = await monitor.preview(over)
        XCTAssertEqual(nextPreview.action, .plannedRestart)
        let secondPreviewAgain = await monitor.preview(over)
        XCTAssertEqual(secondPreviewAgain.action, .plannedRestart)
        let second = await monitor.evaluate(over)
        XCTAssertEqual(second.action, .plannedRestart)
    }

    // MARK: - Facade seam: limit, Worker environment and heap sample

    /// The resolved limit reaches the budget snapshot and the Worker
    /// environment, and a reported engine heap sample reaches the budget
    /// monitor through the same facade.
    func testFacadeExposesTheSingleFileLimitAndHeapSample() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let origin = try XCTUnwrap(URL(string: "http://127.0.0.1:1"))
        let limit = 96 * mib
        let configuration = PhoneDSHConfiguration(
            workspaceRoot: fixture.workspace,
            token: "test-token",
            origin: origin,
            bundle: fixture.bundle,
            helloTimeout: 10,
            singleFileLimitBytes: limit)
        let engine = MockEngine(worker: MockWorker())
        let host = PhoneDSHHost(configuration: configuration,
                                engineFactory: { _ in engine })
        try await host.start()

        let initial = await host.diagnostics()
        let budget = try XCTUnwrap(initial.budget)
        XCTAssertEqual(budget.singleFileLimitBytes, limit)
        XCTAssertEqual(budget.table.singleFileBytes, limit)
        XCTAssertGreaterThanOrEqual(budget.table.workspaceBytes, 2 * limit)
        XCTAssertEqual(
            engine.lastConfiguration?.environment[
                PhoneDSHWorkerEnvironment.singleFileLimit],
            String(limit))

        let heap = budget.table.engineHeapBytes + 1
        await host.reportEngineHeapBytes(heap)
        let pressured = await host.diagnostics()
        let pressuredBudget = try XCTUnwrap(pressured.budget)
        XCTAssertEqual(pressuredBudget.engineHeapBytesUsed, heap)
        XCTAssertFalse(pressuredBudget.isWithinEngineHeapLimit)
        // The report evaluated the first action (clearTmp). diagnostics is a
        // read-only snapshot: it must preview the next action without
        // consuming it, otherwise an App that refreshes the screen would
        // escalate to handoff/hardFail with no action taken.
        XCTAssertEqual(pressuredBudget.lastAction, .plannedRestart)
        let polledAgain = await host.diagnostics()
        XCTAssertEqual(polledAgain.budget?.lastAction, .plannedRestart,
                       "polling diagnostics must not advance the pressure episode")
        let polledThird = await host.diagnostics()
        XCTAssertEqual(polledThird.budget?.lastAction, .plannedRestart,
                       "repeated diagnostics reads stay on the same pending action")

        await host.reportEngineHeapBytes(nil)
        let cleared = await host.diagnostics()
        XCTAssertNil(cleared.budget?.engineHeapBytesUsed)
        XCTAssertNil(cleared.budget?.lastAction)
        try await host.stop()
    }

    // MARK: - Chunked publication replays without resync

    /// A file larger than one mutation is published as one complete write plus
    /// appended suffixes. After a kill before materialization, cold recovery
    /// replays the chunked records from the WAL with no base mismatch.
    func testChunkedLargeFileReplaysFromTheWALWithoutResync() async throws {
        let root = try temporaryRoot("chunked-replay")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = WorkspaceLogConfiguration(
            root: root,
            segmentRollBytes: 1 * mib,
            singleFileLimitBytes: 4 * mib,
            groupCommitDelay: 0,
            groupCommitBytes: 1 * mib)
        let path = "/dsh/workspace/chunked.bin"
        let chunk = 1 * mib

        let writer = try WALWriter.open(
            configuration: configuration,
            bootID: Data(repeating: 0x71, count: 16))
        try await writer.append(VfsMutationBody(
            op: .write, mode: 0o644, path: path,
            data: Data(repeating: 0x10, count: chunk)))
        for index in 1..<4 {
            try await writer.append(VfsMutationBody(
                op: .write, mode: 0o644, mflags: [.appended],
                appendFrom: UInt64(index * chunk), path: path,
                data: Data(repeating: UInt8(0x10 + index), count: chunk)))
        }
        try await writer.flush()

        // Drop the writer without an epoch close: the next boot replays the
        // durable WAL tail into the materialized copy.
        let recovered = try WorkspaceLog(
            configuration: configuration,
            bootID: Data(repeating: 0x72, count: 16))
        let report = try await recovered.recover()
        XCTAssertTrue(report.needsResync.isEmpty,
                      "chunked appended writes must replay without a resync")
        XCTAssertEqual(report.replayedRecords, 4)
        XCTAssertEqual(report.nextMseq, 5)

        let target = materializedFile(root, path)
        let bytes = try Data(contentsOf: target)
        XCTAssertEqual(bytes.count, 4 * chunk)
        for index in 0..<4 {
            let range = (index * chunk)..<((index + 1) * chunk)
            XCTAssertEqual(Data(bytes[range]),
                           Data(repeating: UInt8(0x10 + index), count: chunk))
        }
        _ = try await recovered.closeEpoch()
    }

    // MARK: - The single-file cap is a pre-WAL resource refusal

    /// A chunk that would grow one file past the configured limit is refused
    /// before the WAL append; it consumes no mseq and the accepted prefix can
    /// still be extended to exactly the limit.
    func testWorkspaceLogRefusesAChunkPastTheSingleFileLimitWithoutConsumingMseq()
        async throws {
        let root = try temporaryRoot("refuse")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = WorkspaceLogConfiguration(
            root: root, singleFileLimitBytes: 1_000, groupCommitDelay: 0)
        let log = try WorkspaceLog(
            configuration: configuration,
            bootID: Data(repeating: 0x81, count: 16))
        let path = "/dsh/workspace/cap.bin"
        let first = try await log.append(VfsMutationBody(
            op: .write, mode: 0o644, path: path,
            data: Data(repeating: 0x21, count: 600)))
        XCTAssertEqual(first, 1)

        do {
            _ = try await log.append(VfsMutationBody(
                op: .write, mode: 0o644, mflags: [.appended],
                appendFrom: 600, path: path,
                data: Data(repeating: 0x22, count: 600)))
            XCTFail("an append past the single-file limit must be refused")
        } catch LogError.vfsRefused(let refusedPath, let limit, let projected) {
            XCTAssertEqual(refusedPath, path)
            XCTAssertEqual(limit, 1_000)
            XCTAssertEqual(projected, 1_200)
        }
        let positions = await log.positions()
        XCTAssertEqual(positions.nextMseq, 2,
                       "a refused mutation must not consume an mseq")
        XCTAssertEqual(positions.ackedMseq, 1)

        let second = try await log.append(VfsMutationBody(
            op: .write, mode: 0o644, mflags: [.appended],
            appendFrom: 600, path: path,
            data: Data(repeating: 0x23, count: 400)))
        XCTAssertEqual(second, 2)
        let target = materializedFile(root, path)
        XCTAssertEqual(try Data(contentsOf: target),
                       Data(repeating: 0x21, count: 600)
                           + Data(repeating: 0x23, count: 400))
        _ = try await log.closeEpoch()
    }

    // MARK: - Materializer: a torn append converges from the WAL

    /// A kill in the middle of an appended write leaves the materialized file
    /// one byte-range short of the accepted WAL record. Replaying the record
    /// must append only the missing suffix, not declare a base mismatch.
    func testTornAppendIsCompletedFromTheWALOnReplay() throws {
        let root = try temporaryRoot("torn-append")
        defer { try? FileManager.default.removeItem(at: root) }

        let materializer = try Materializer(root: root, materializedUptoMseq: 0)
        let path = "/dsh/workspace/big.bin"
        let firstChunk = Data(repeating: 0x41, count: 64)
        let secondChunk = Data(repeating: 0x42, count: 64)

        let first = try WALRecord(mseq: 1, mutation: VfsMutationBody(
            op: .write, mode: 0o644, path: path, data: firstChunk))
        XCTAssertEqual(try materializer.apply(first), .applied)

        // Simulate a process kill after 20 of the 64 appended bytes reached
        // the materialized file. The WAL already has the complete record.
        let target = materializedFile(root, path)
        let handle = try FileHandle(forWritingTo: target)
        try handle.seekToEnd()
        try handle.write(contentsOf: secondChunk.prefix(20))
        try handle.close()

        let append = try WALRecord(mseq: 2, mutation: VfsMutationBody(
            op: .write, mode: 0o644, mflags: [.appended],
            appendFrom: 64, path: path, data: secondChunk))
        XCTAssertEqual(try materializer.apply(append), .applied,
                       "a torn suffix must be completed, not treated as a missing base")
        XCTAssertEqual(try Data(contentsOf: target), firstChunk + secondChunk)
        XCTAssertEqual(materializer.materializedUptoMseq, 2)
    }

    // MARK: - WAL quota: repeated rewrites of one large file

    /// Rewriting the same large file several times inside one epoch must not
    /// exhaust the WAL quota before materialization is durable: the host
    /// closes the epoch and compacts droppable segments before failing loud.
    func testRepeatedLargeFileRewritesCompactTheWALInsteadOfFailing() async throws {
        let root = try temporaryRoot("wal-quota")
        defer { try? FileManager.default.removeItem(at: root) }

        let configuration = WorkspaceLogConfiguration(
            root: root,
            walQuotaBytes: 120_000,
            segmentRollBytes: 16_384,
            groupCommitDelay: 0,
            groupCommitBytes: 4_096)
        let log = try WorkspaceLog(configuration: configuration,
                                   bootID: Data(repeating: 0x33, count: 16))

        let chunkBytes = 20_000
        let rewrites = 5
        var mseq: UInt64 = 0
        for iteration in 0..<rewrites {
            let fill = UInt8(0x40 + iteration)
            let chunk = Data(repeating: fill, count: chunkBytes)
            mseq = try await log.append(VfsMutationBody(
                op: .write, mode: 0o644, path: "/dsh/workspace/rewrite.bin",
                data: chunk))
            for offset in 1..<4 {
                mseq = try await log.append(VfsMutationBody(
                    op: .write, mode: 0o644, mflags: [.appended],
                    appendFrom: UInt64(offset * chunkBytes),
                    path: "/dsh/workspace/rewrite.bin", data: chunk))
            }
        }
        XCTAssertEqual(mseq, UInt64(rewrites * 4))

        let metrics = try await log.metrics()
        XCTAssertLessThanOrEqual(metrics.walBytes, configuration.walQuotaBytes,
                                 "compaction must keep the WAL inside its quota")
        XCTAssertEqual(metrics.workspaceBytes, chunkBytes * 4)

        let target = materializedFile(root, "/dsh/workspace/rewrite.bin")
        XCTAssertEqual(try Data(contentsOf: target),
                       Data(repeating: 0x44, count: chunkBytes * 4))

        _ = try await log.closeEpoch()
    }

    // MARK: - Memory peak probe

    /// Simulator-approximation memory probe for the largest host-side path a
    /// 64 MiB single file takes: WAL tail replay into the materialized copy.
    /// The resident-size high-water mark is sampled while recovery runs, so
    /// the recorded number is measured here, not assumed. The WebContent heap
    /// itself is not reachable without WKWebView; the budget monitor's heap
    /// branch is covered by the proxy test above.
    func testHostReplayMemoryPeakForSixtyFourMiBFileIsBounded() async throws {
        let root = try temporaryRoot("memory")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = WorkspaceLogConfiguration(root: root,
                                                      groupCommitDelay: 0)
        let bootA = Data(repeating: 0x61, count: 16)
        let writer = try WALWriter.open(configuration: configuration, bootID: bootA)
        let path = "/dsh/workspace/peak.bin"
        let chunkSizes = [13 * mib, 13 * mib, 13 * mib, 13 * mib, 12 * mib]
        var offset = 0
        for (index, size) in chunkSizes.enumerated() {
            let chunk = Data(repeating: UInt8(0x60 + index), count: size)
            let body: VfsMutationBody
            if index == 0 {
                body = VfsMutationBody(op: .write, mode: 0o644,
                                       path: path, data: chunk)
            } else {
                body = VfsMutationBody(op: .write, mode: 0o644,
                                       mflags: [.appended],
                                       appendFrom: UInt64(offset),
                                       path: path, data: chunk)
            }
            try await writer.append(body)
            offset += size
        }
        try await writer.flush()
        XCTAssertEqual(offset, 64 * mib)

        let baseline = Self.residentBytes()
        let sampler = Task { () -> Int in
            var peak = Self.residentBytes()
            while !Task.isCancelled {
                peak = max(peak, Self.residentBytes())
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return peak
        }
        let bootB = Data(repeating: 0x62, count: 16)
        // The recovery target is `a + k × MB`, not a formula-only assertion:
        // measure the real cold recovery (WAL replay into the materialized
        // copy) plus the overlay repack the boot path performs after it.
        let recoveryStarted = Date()
        let recovered = try WorkspaceLog(configuration: configuration, bootID: bootB)
        let report = try await recovered.recover()
        sampler.cancel()
        let peak = await sampler.value
        // The boot path packs the overlay after recovery; the target covers
        // that repack too, so measure it in the same window but outside the
        // replay-only resident-size probe above (kept comparable to before).
        let overlayBytes = try await recovered.packOverlay()
        let recoverySeconds = Date().timeIntervalSince(recoveryStarted)
        XCTAssertTrue(report.needsResync.isEmpty)
        XCTAssertGreaterThan(overlayBytes.count, 0)

        let attributes = try FileManager.default.attributesOfItem(atPath:
            materializedFile(root, path).path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.intValue, 64 * mib)

        let delta = max(0, peak - baseline)
        let record = "ENG-08 memory probe (host replay, simulator approximation): "
            + "baseline=\(baseline) peak=\(peak) delta=\(delta) bytes for a 64 MiB file"
        print(record)
        let recoveryTarget = BudgetTable.eightGB
            .recoveryTimeTargetSeconds(forMaterializedMegabytes: 64)
        let recoveryRecord =
            "ENG-08 recovery probe (64 MiB, host measurement; NOT_VERIFIED on an iPhone): "
            + String(format: "measured=%.3f s target=%.1f s overlay=%d bytes",
                     recoverySeconds, recoveryTarget, overlayBytes.count)
        print(recoveryRecord)
        XCTAssertLessThanOrEqual(
            recoverySeconds, recoveryTarget,
            "measured 64 MiB recovery incl. overlay repack must meet a + k·MB (budgets.md §4)")
        let attachment = XCTAttachment(string: record + "\n" + recoveryRecord)
        attachment.name = "ENG-08-memory-peak"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThan(delta, 192 * mib,
                          "replaying a 64 MiB file must not duplicate the whole file")
    }

    // MARK: - Seeded large-file kill matrix

    /// 20 seeded publication kills across different chunk boundaries. The
    /// writer stops with the records only in the WAL (no epoch close), which is
    /// what a process kill leaves behind; the next boot must replay the accepted
    /// prefix without a resync and the surviving log must finish the file. This
    /// is the large-file dimension of the kill matrix at the component layer,
    /// driven by a deterministic seed so the kills are reproducible; the
    /// end-to-end matrix lives in the probe target.
    func testSeededLargeFilePublicationKillsConvergeOnReplay() async throws {
        let chunk = 64 * 1024
        let totalChunks = 12
        // A seeded permutation of the kill points: all 12 chunk boundaries are
        // exercised before any repeat, and the seed decides the order. 20
        // kills therefore cover the whole interruption matrix plus 8 repeats.
        let killPoints: [Int] = {
            var boundaries = Array(1...totalChunks)
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            for index in stride(from: boundaries.count - 1, through: 1, by: -1) {
                state = state &* 6_364_136_223_846_793_005
                    &+ 1_442_695_040_888_963_407
                boundaries.swapAt(index, Int((state >> 33) % UInt64(index + 1)))
            }
            return boundaries + boundaries.prefix(8)
        }()
        XCTAssertEqual(Set(killPoints.prefix(totalChunks)), Set(1...totalChunks))
        for iteration in 0..<20 {
            let published = killPoints[iteration]
            let root = try temporaryRoot("seeded-kill-\(iteration)")
            defer { try? FileManager.default.removeItem(at: root) }
            let configuration = WorkspaceLogConfiguration(
                root: root,
                segmentRollBytes: 128 * 1024,
                singleFileLimitBytes: totalChunks * chunk,
                groupCommitDelay: 0,
                groupCommitBytes: chunk)
            let path = "/dsh/workspace/killed.bin"

            func chunkBytes(_ index: Int) -> Data {
                Data(repeating: UInt8(iteration & 0xFF) &+ UInt8(index & 0xFF),
                     count: chunk)
            }

            var expected = Data()
            let writer = try WALWriter.open(
                configuration: configuration,
                bootID: Data(repeating: 0xA0 &+ UInt8(iteration % 16), count: 16))
            for index in 0..<published {
                let bytes = chunkBytes(index)
                expected.append(bytes)
                if index == 0 {
                    try await writer.append(VfsMutationBody(
                        op: .write, mode: 0o644, path: path, data: bytes))
                } else {
                    try await writer.append(VfsMutationBody(
                        op: .write, mode: 0o644, mflags: [.appended],
                        appendFrom: UInt64(index * chunk), path: path, data: bytes))
                }
            }
            try await writer.flush()

            // Drop the writer without an epoch close: a kill leaves only the
            // level-1 records behind.
            let recovered = try WorkspaceLog(
                configuration: configuration,
                bootID: Data(repeating: 0xB0 &+ UInt8(iteration % 16), count: 16))
            let report = try await recovered.recover()
            XCTAssertTrue(report.needsResync.isEmpty,
                          "iteration \(iteration): a kill after \(published) chunks "
                              + "must replay without a resync")
            XCTAssertEqual(report.replayedRecords, published,
                           "iteration \(iteration): every accepted level-1 record replays")
            XCTAssertEqual(report.nextMseq, UInt64(published + 1),
                           "iteration \(iteration): no mseq is reused or skipped")
            let target = materializedFile(root, path)
            XCTAssertEqual(try Data(contentsOf: target), expected,
                           "iteration \(iteration): the accepted prefix is intact")

            // Finish the publication on the recovered log; the appended chain
            // continues at the next mseq and preserves the prefix.
            for index in published..<totalChunks {
                let bytes = chunkBytes(index)
                expected.append(bytes)
                let mseq = try await recovered.append(VfsMutationBody(
                    op: .write, mode: 0o644, mflags: [.appended],
                    appendFrom: UInt64(index * chunk), path: path, data: bytes))
                XCTAssertEqual(mseq, UInt64(index + 1))
            }
            XCTAssertEqual(try Data(contentsOf: target), expected)
            XCTAssertEqual(try Data(contentsOf: target).count, totalChunks * chunk)
            _ = try await recovered.closeEpoch()
        }
    }

    private static func residentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size)
    }
}
