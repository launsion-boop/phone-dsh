// SPDX-License-Identifier: MIT
// G2-FIX-17 regression: park/stop must close every WAL epoch that a VFS sink
// frame opened in the drain window, so `fence.wal_seq` always equals
// `manifest.last_mseq` and the tail epoch is closed in the D18 order.
//
// The scenario G2-B08 wrote the abort tail (mseq 115) at 10:17:38.2, after the
// D14 drain's epoch close (~10:17:38.0) and before the loopback teardown. The
// sink append opened epoch 4, the old code never closed it, and fence.json kept
// `wal_seq` 114 while manifest.json had `last_mseq` 115. These tests use the
// host's drain-window probe to reproduce exactly that ordering against the real
// ordered-channel assembly: the probe appends to the live `WorkspaceLog`
// (the sink path) after the controller closed the epoch and before the
// loopback is stopped.

import Foundation
import XCTest
@testable import PhoneDSH
import PhoneDSHEngine
import PhoneDSHLog
import PhoneDSHWire

final class EpochSealTests: XCTestCase {
    private static func drainWindowMutation() -> VfsMutationBody {
        VfsMutationBody(op: .write, mode: 0o644,
                        path: "/dsh/workspace/abort-tail.txt",
                        data: Data("abort tail".utf8))
    }

    private func makeHost(_ fixture: FacadeFixture,
                          _ engine: MockEngine) throws -> PhoneDSHHost {
        PhoneDSHHost(configuration: try fixture.configuration(),
                     engineFactory: { _ in engine })
    }

    private func readManifest(_ fixture: FacadeFixture) throws -> Manifest {
        let manifest = try XCTUnwrap(try ManifestStore(root: fixture.workspace).read())
        return manifest
    }

    /// Reads `fence.json` without depending on the controller's internal model.
    private func readFenceWalSeq(_ fixture: FacadeFixture) throws -> UInt64 {
        let url = fixture.workspace.appendingPathComponent("fence.json")
        let data = try Data(contentsOf: url)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let fence = try XCTUnwrap(object["fence"] as? [String: Any])
        return try XCTUnwrap((fence["wal_seq"] as? NSNumber)?.uint64Value)
    }

    private func walScan(_ fixture: FacadeFixture) throws -> WALScan {
        try WALReader.scan(directory: fixture.workspace.appendingPathComponent("wal"))
    }

    /// Installs a probe that appends the abort-tail mutation in the drain
    /// window: after `finishDrain` closed the epoch and before `park()` stops
    /// the loopback. This is the exact G2-B08 ordering.
    private func installDrainWindowSinkAppend(_ host: PhoneDSHHost) async {
        await host.setDrainWindowProbeForTesting { log in
            _ = try await log.append(Self.drainWindowMutation())
        }
    }

    /// Fails before the fix: the drain closed epoch 1, the probe appended mseq 1
    /// into a fresh epoch 2 that nobody sealed, so `fence.wal_seq` stayed 0
    /// while `manifest.last_mseq` was 1 (the G2-B08 `114 < 115` shape).
    func testParkSealsEpochOpenedBySinkAppendAfterTheDrainClose() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine)
        try await host.start()
        await installDrainWindowSinkAppend(host)

        try await host.park()

        let manifest = try readManifest(fixture)
        let fenceWalSeq = try readFenceWalSeq(fixture)
        XCTAssertEqual(manifest.lastMseq, 1,
                       "the drain-window sink append must be in the WAL tail")
        XCTAssertEqual(fenceWalSeq, manifest.lastMseq,
                       "fence.wal_seq must equal the on-disk WAL tail after park")
        XCTAssertGreaterThan(manifest.lastDurableEpoch, 1,
                             "the epoch opened after the drain close must be closed")
        XCTAssertTrue(manifest.segments.contains {
            $0.epoch == manifest.lastDurableEpoch
                && $0.lastMseq == manifest.lastMseq
        }, "the manifest must list the closed tail epoch")

        // D18: the tail epoch is durable, not merely listed.
        let scan = try walScan(fixture)
        XCTAssertEqual(scan.durableMseq, manifest.lastMseq,
                       "the tail epoch close must cover every on-disk mutation")
        XCTAssertEqual(scan.lastDurableEpoch, manifest.lastDurableEpoch)
        XCTAssertEqual(manifest.materializedUptoMseq, manifest.lastMseq)

        // A follow-up handoff source sees the same sealed tail: the snapshot
        // carries the aborted turn's file and no segment extends past wal_seq.
        let scratch = fixture.root.appendingPathComponent("handoff-scratch",
                                                          isDirectory: true)
        let upload = try await HandoffWorkspaceSnapshotter(
            root: fixture.workspace,
            configuration: WorkspaceLogConfiguration(root: fixture.workspace),
            scratchDirectory: scratch).prepareHandoff()
        XCTAssertEqual(upload.walSeq, manifest.lastMseq,
                       "the handoff fence target must be the sealed tail")
        XCTAssertEqual(upload.baseMseq, manifest.materializedUptoMseq)
        XCTAssertGreaterThanOrEqual(upload.walSeq, upload.baseMseq)
        let entries = try HandoffTar.read(from: upload.snapshotURL)
        XCTAssertTrue(entries.map(\.name).contains("workspace/abort-tail.txt"),
                      "the handoff snapshot must contain the drain-window mutation")

        try await host.stop()
    }

    /// The drain criterion of PLAN §2.5 ("wait for in-flight") must include
    /// write-direction frames, not only `0x40` API exchanges. Before the fix a
    /// `0x10`/`0x12`/`0x30` handler could still be appending while the
    /// controller closed the epoch.
    func testDrainCriterionWaitsForWriteDirectionFrames() async throws {
        let coordinator = PhoneDSHChannelCoordinator(eventBus: PhoneDSHEventBus())

        await coordinator.inboundWriteStarted()
        let timedOut = await coordinator.waitForDrainQuiescence(timeout: 0.05)
        XCTAssertFalse(timedOut,
                       "a drain must not report quiescence while a sink frame is in flight")

        let waiter = Task { await coordinator.waitForDrainQuiescence(timeout: 1) }
        try await Task.sleep(nanoseconds: 20_000_000)
        await coordinator.inboundWriteFinished()
        let drained = await waiter.value
        XCTAssertTrue(drained, "the drain must resume when the sink frame finishes")
    }

    /// Short-request churn can keep changing `drainGeneration` while the
    /// channel is quiescent, which used to skip the deadline check in the
    /// quiescent branch. The wait must still return at its deadline.
    ///
    /// Standing-receive tokens change the generation without entering the
    /// non-standing in-flight count, so the channel stays quiescent while the
    /// churn is active.
    func testDrainQuiescenceDeadlineBoundsQuiescentGenerationChurn() async throws {
        let coordinator = PhoneDSHChannelCoordinator(eventBus: PhoneDSHEventBus())
        let stop = ChurnStop()
        let churn = Task {
            while !(await stop.isStopped) {
                var tokens: [UUID] = []
                for _ in 0..<4 {
                    tokens.append(await coordinator.apiRequestStarted(kind: .standingReceive))
                }
                for token in tokens {
                    await coordinator.apiRequestFinished(token)
                }
                await Task.yield()
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        let started = Date()
        let waiter = Task { await coordinator.waitForDrainQuiescence(timeout: 0.05) }
        // Let a broken implementation terminate even if it skips the deadline.
        let release = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await stop.stop()
        }
        let drained = await waiter.value
        let elapsed = Date().timeIntervalSince(started)
        await stop.stop()
        release.cancel()
        _ = await release.value
        _ = await churn.value

        XCTAssertTrue(drained)
        XCTAssertLessThan(elapsed, 0.30,
                          "the drain deadline must bound the quiescent branch under generation churn")
    }

    /// G2-FIX-Q4-CHANNEL classification: only the D23 long-lived mux receive
    /// is standing; a mux send/close and every ordinary API call are finite
    /// exchanges that the drain must still wait for.
    func testOnlyMuxReceiveIsClassifiedAsStanding() {
        func head(path: String, operation: String?, contentType: String) -> ApiRequestHead {
            var headers = [PhoneDSHMuxProtocol.contentTypeHeader: contentType]
            if let operation {
                headers[PhoneDSHMuxProtocol.operationHeader] = operation
            }
            return ApiRequestHead(method: "POST", path: path, headers: headers)
        }
        XCTAssertEqual(PhoneDSHAPIRequestKind.classify(head(
            path: PhoneDSHMuxProtocol.path,
            operation: PhoneDSHMuxProtocol.receiveOperation,
            contentType: PhoneDSHMuxProtocol.ndjsonContentType)), .standingReceive)
        XCTAssertEqual(PhoneDSHAPIRequestKind.classify(head(
            path: PhoneDSHMuxProtocol.path,
            operation: PhoneDSHMuxProtocol.sendOperation,
            contentType: PhoneDSHMuxProtocol.jsonContentType)), .exchange)
        XCTAssertEqual(PhoneDSHAPIRequestKind.classify(head(
            path: PhoneDSHMuxProtocol.path,
            operation: PhoneDSHMuxProtocol.closeOperation,
            contentType: PhoneDSHMuxProtocol.jsonContentType)), .exchange)
        XCTAssertEqual(PhoneDSHAPIRequestKind.classify(head(
            path: "/api/session/create",
            operation: nil,
            contentType: PhoneDSHMuxProtocol.jsonContentType)), .exchange)
        XCTAssertEqual(PhoneDSHAPIRequestKind.classify(head(
            path: PhoneDSHMuxProtocol.path,
            operation: PhoneDSHMuxProtocol.receiveOperation,
            contentType: PhoneDSHMuxProtocol.jsonContentType)), .exchange,
            "only the ndjson receive stream is standing")
    }

    /// G2-FIX-Q4-CHANNEL: a standing token is tracked but does not keep the
    /// drain open; a unary exchange does, and a tokenized finish only retires
    /// its own request.
    func testDrainQuiescenceIgnoresStandingReceiveAndKeepsTokenIdentity() async throws {
        let coordinator = PhoneDSHChannelCoordinator(eventBus: PhoneDSHEventBus())

        let standing = await coordinator.apiRequestStarted(kind: .standingReceive)
        let standingIdle = await coordinator.waitForDrainQuiescence(timeout: 0.05)
        XCTAssertTrue(standingIdle,
                      "the standing mux receive must not hold the drain open")
        let standingCount = await coordinator.standingAPIRequestCount()
        XCTAssertEqual(standingCount, 1)
        await coordinator.apiRequestFinished(standing)
        let standingAfter = await coordinator.standingAPIRequestCount()
        XCTAssertEqual(standingAfter, 0)

        let unary = await coordinator.apiRequestStarted()
        let busy = await coordinator.waitForDrainQuiescence(timeout: 0.05)
        XCTAssertFalse(busy, "a unary API exchange must still hold the drain open")
        let waiter = Task { await coordinator.waitForDrainQuiescence(timeout: 1) }
        try await Task.sleep(nanoseconds: 20_000_000)
        await coordinator.apiRequestFinished(unary)
        let drained = await waiter.value
        XCTAssertTrue(drained, "the drain must resume when the unary exchange ends")

        // A duplicate or stale finish is idempotent and cannot retire a newer
        // request that reused the accounting slot.
        await coordinator.apiRequestFinished(unary)
        let afterDuplicate = await coordinator.inFlightAPIRequestCount()
        XCTAssertEqual(afterDuplicate, 0)
        let second = await coordinator.apiRequestStarted()
        await coordinator.apiRequestFinished(unary)
        let afterStale = await coordinator.inFlightAPIRequestCount()
        XCTAssertEqual(afterStale, 1,
                       "an old stream ending must not decrement the new request")
        await coordinator.apiRequestFinished(second)
        let final = await coordinator.inFlightAPIRequestCount()
        XCTAssertEqual(final, 0)
    }

    /// The D24 planned restart closes an epoch while the old Worker channel can
    /// still be live; the host must seal the tail and record `fence.wal_seq`
    /// before rebuilding the overlay and the Worker.
    func testPlannedRestartRecordsTheFenceAtTheDurableTail() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine)
        try await host.start()

        let mseq = try await engine.worker.writeFile(
            path: "/dsh/workspace/persist.txt", data: Data("kept".utf8))
        try await engine.worker.waitForAck(mseq)

        try await host.plannedRestart(reason: "g2-fix-17")

        let manifest = try readManifest(fixture)
        XCTAssertEqual(manifest.lastMseq, mseq)
        XCTAssertEqual(try readFenceWalSeq(fixture), manifest.lastMseq,
                       "a planned restart must leave the fence at the durable tail")
        XCTAssertGreaterThanOrEqual(manifest.lastDurableEpoch, 1)
        XCTAssertEqual(try walScan(fixture).durableMseq, manifest.lastMseq)
        try await host.stop()
    }

    /// The stop path must enforce the same invariant: `stop()` parks a running
    /// host first, and a swallowed park failure used to hide the tail gap.
    func testStopSealsEpochOpenedBySinkAppendAfterTheDrainClose() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine)
        try await host.start()
        await installDrainWindowSinkAppend(host)

        try await host.stop()

        let manifest = try readManifest(fixture)
        XCTAssertEqual(manifest.lastMseq, 1)
        XCTAssertEqual(try readFenceWalSeq(fixture), manifest.lastMseq,
                       "stop() must leave fence.wal_seq at the WAL tail")
        XCTAssertEqual(try walScan(fixture).durableMseq, manifest.lastMseq)
    }

    /// An epoch close that cannot complete must fail loud: park() throws, the
    /// host enters Failed with a diagnostic, and no fence above the durable
    /// watermark is written.
    func testParkFailsLoudWhenTheTailEpochCannotBeClosed() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = try makeHost(fixture, engine)
        try await host.start()
        await host.setDrainWindowProbeForTesting { log in
            _ = try await log.append(Self.drainWindowMutation())
            // Delete the segment the append just opened. The D18 close writes
            // its close record through the open fd but F_FULLFSYNC reopens the
            // file by path, which now fails; the host must not report a
            // successful park with a stale fence.
            let paths = await log.paths
            let files = try FileManager.default
                .contentsOfDirectory(atPath: paths.walDirectory.path)
                .filter { $0.hasSuffix(".xlwal") }
                .sorted()
            let newest = try XCTUnwrap(files.last)
            try FileManager.default.removeItem(
                at: paths.walDirectory.appendingPathComponent(newest))
        }

        do {
            try await host.park()
            XCTFail("park() must throw when the tail epoch cannot be closed")
        } catch let error as PhoneDSHError {
            guard case .invalidState(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("epoch close") || message.contains("WAL"),
                          "the failure must name the epoch/WAL close: \(message)")
        }

        let state = await host.state
        XCTAssertEqual(state, .failed, "an epoch close failure is fail loud")
        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.hostState, .failed)
        XCTAssertNotNil(diagnostics.lastError)
        XCTAssertEqual(try readFenceWalSeq(fixture), 0,
                       "a failed seal must not advertise a fence above the durable tail")
        try? await host.stop()
    }
}

/// Thread-safe stop flag for the drain-generation churn regression.
private actor ChurnStop {
    private var stopped = false

    var isStopped: Bool { stopped }

    func stop() {
        stopped = true
    }
}
