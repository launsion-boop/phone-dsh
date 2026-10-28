// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2-FIX-127 host-level abort/failed-stop regression.
//
// The component-level tests in `PhoneDSHLogTests` pin the WAL segment
// lifecycle, the materialized-copy invariant and the stop seal. This test puts
// the same shape on the real `PhoneDSHHost` teardown path:
//
//   1. the host is Running and the scripted Worker has written a file;
//   2. the in-flight drain window is opened (the G2-FIX-17 seam) and a sink
//      mutation arrives after the controller already closed its epoch, which
//      opens a new epoch;
//   3. the teardown then fails before `closeRuntimeForPark` can run (an error
//      from the same window models a Worker that does not settle a turn);
//   4. `fail()`/`stop()` must run the terminal stop seal, so `wal/` and
//      `manifest.json` agree and the accepted content survives.
//
// Before the fix the failed teardown released the log with an open epoch behind
// a manifest that still described the earlier epoch: the exact inverted state
// the G2-A09 evidence shows, and the state a later recovery would have used to
// classify the real segments as stale.
//
// The class name is deliberate on three counts. It contains
// `PhoneDSH` because the task gates run
// `swift test --filter 'PhoneDSH'` (swift-facade) and
// `--filter 'PhoneDSH|PhoneDSHShell'` (sdk-all), which match the
// XCTest case name; a class named only `AbortStopDurabilityHostTests` compiles
// but never executes in either gate, so the regression that proves this repair
// would not run where the acceptance reads it. The leading `Z` follows
// `ZPhoneDSHToolResultAuditTests`: XCTest runs suites in name order
// and the gates keep only the tail of the log, so this regression runs last
// and stays visible in the acceptance log. The original spec's gate
// (`--filter 'PhoneDSHLog|PhoneDSHKill'`) still covers it through the
// target name.

import Foundation
import XCTest
import PhoneDSHHarness
import PhoneDSHLog
import PhoneDSHWire

@testable import PhoneDSH

private enum AbortStopError: Error, CustomStringConvertible {
    case drainWindowFailure
    var description: String { "the drain window teardown failure used by the regression" }
}

final class ZPhoneDSHAbortStopDurabilityHostTests: XCTestCase {
    /// One sink mutation written through the live `WorkspaceLog`, exactly the
    /// frame the Worker would send.
    private func mutation(path: String, data: Data) -> VfsMutationBody {
        VfsMutationBody(op: .write, mode: 0o644, mflags: [.entryChanged],
                        appendFrom: 0, path: path, data: data)
    }

    private func waitForHostState(_ host: PhoneDSHHost,
                                  _ state: PhoneDSHState,
                                  timeout: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await host.state != state {
            if Date() >= deadline {
                throw KillError.timeout("host state \(state.rawValue)")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func assertStoppedStopIsAuditable(_ root: URL,
                                              file: StaticString = #filePath,
                                              line: UInt = #line) throws {
        let manifest = try XCTUnwrap(try ManifestStore(root: root).read(),
                                     file: file, line: line)
        let segments = try WALReader.scan(directory: WorkspacePaths(root: root).walDirectory)
            .segments.filter { !$0.records.isEmpty }
        let listed = Dictionary(uniqueKeysWithValues: manifest.segments.map { ($0.file, $0) })
        XCTAssertEqual(listed.keys.sorted(), segments.map(\.manifestFile).sorted(),
                       "a failed host stop must leave manifest.segments equal to the real wal/ directory",
                       file: file, line: line)
        for segment in segments {
            guard let entry = listed[segment.manifestFile] else { continue }
            XCTAssertEqual(entry.firstMseq, segment.header.firstMseq,
                           file: file, line: line)
            XCTAssertEqual(entry.lastMseq, segment.lastMutationMseq,
                           file: file, line: line)
        }
        XCTAssertLessThanOrEqual(manifest.materializedUptoMseq, manifest.lastMseq,
                                 file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            manifest.lastMseq,
            segments.compactMap(\.lastMutationMseq).max() ?? 0,
            "manifest.last_mseq must cover the accepted WAL tail after a failed stop",
            file: file, line: line)
    }

    /// A teardown failure after the drain epoch close must still seal the open
    /// epoch and verify the materialized copy.
    func testFailedStopSealsTheOpenEpochAndKeepsTheAcceptedContent() async throws {
        let fixture = try KillFixture()
        defer { fixture.cleanup() }
        let worker = KillWorker()
        let engine = KillMockEngine(worker: worker)
        let configuration = try fixture.configuration()
        let host = PhoneDSHHost(configuration: configuration, engineFactory: { _ in engine })
        try await host.start()
        try await waitForHostState(host, .running)
        try await worker.waitForOpenFrames()

        let seed = Data("accepted-before-the-failed-stop".utf8)
        let seedMseq = try await worker.writeFile("/dsh/workspace/accepted.txt", data: seed)
        try await worker.waitForAck(seedMseq)

        // The drain-window mutation opens a new epoch after the controller's
        // close, and the same window then fails the teardown. This is the
        // abort/failed path with no `closeRuntimeForPark`.
        await host.setDrainWindowProbeForTesting { log in
            _ = try await log.append(VfsMutationBody(
                op: .write, mode: 0o644,
                mflags: [.entryChanged], appendFrom: 0,
                path: "/dsh/workspace/drain-window.txt",
                data: Data("written inside the drain window".utf8)))
            throw AbortStopError.drainWindowFailure
        }

        var stopError: Error?
        do {
            try await host.stop()
        } catch {
            stopError = error
        }
        XCTAssertNotNil(stopError,
                        "the scripted drain-window failure must reach the caller")
        let state = await host.state
        XCTAssertEqual(state, .stopped)

        try assertStoppedStopIsAuditable(fixture.workspace)
        let materialized = WorkspacePaths(root: fixture.workspace).materializedDirectory
        let accepted = try Data(contentsOf: materialized
            .appendingPathComponent("workspace/accepted.txt"))
        XCTAssertEqual(accepted, seed,
                       "an accepted write must survive the failed stop")
        let drainWindow = try Data(contentsOf: materialized
            .appendingPathComponent("workspace/drain-window.txt"))
        XCTAssertEqual(drainWindow, Data("written inside the drain window".utf8),
                       "the mutation that opened the unclosed epoch must survive too")
    }
}
