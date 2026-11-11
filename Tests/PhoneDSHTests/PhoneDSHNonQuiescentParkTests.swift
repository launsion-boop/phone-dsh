// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — a background park whose open turn cannot settle.
//
// Field failure: running a shortcut sends the App to the background in the
// middle of a turn. iOS freezes (or kills) the WebContent, the drain's
// escalation stops the old Worker, and its connection never reaches a clean
// peer EOF. The escalation therefore refuses to repack the overlay or boot a
// replacement (correctly: the overlay could lag the WAL), and the host used to
// turn that into `fail()`: "Park failed: ... did not quiesce before the
// overlay repack; no replacement Worker was booted". The user then had to
// recover by hand.
//
// These regressions pin the replacement contract:
// - a background park in that state ends Parked, with the WAL sealed at its
//   tail and the fence covering it, without packing an overlay or booting a
//   replacement Worker;
// - the open turn is recorded as interrupted, never as completed;
// - `resume()` rebuilds the overlay from the sealed WAL on a fresh boot and
//   runs DSH's resume/repair for the interrupted session before admission
//   opens, so the journal ends on a terminal `turn/end` and the dangling tool
//   call gets a `tool/result`;
// - a teardown (`stop()`) keeps the old fail-loud contract.

import Foundation
import XCTest
@testable import PhoneDSH
import PhoneDSHAgentCore
import PhoneDSHLog
import PhoneDSHWire

final class PhoneDSHNonQuiescentParkTests: XCTestCase {
    private static let sessionID = "mock-session"
    private static let journalPath =
        "/dsh/home/sessions/--dsh-workspace--/mock-session/session.v4.jsonl"
    private static let materializedJournal =
        "home/sessions/--dsh-workspace--/mock-session/session.v4.jsonl"

    func testBackgroundParkSurvivesANonQuiescentEscalationAndResumeRepairsFromTheWAL()
        async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let configuration = try fixture.configuration(drainDeadline: 3)
        let host = PhoneDSHHost(configuration: configuration,
                                engineFactory: { _ in engine })
        try await host.start()

        // A turn that is mid tool call: the assistant asked for a tool, the
        // Harness recorded `tool/call`, and no `tool/result` exists. The
        // scripted Worker never closes it in response to `session/cancel`.
        let harness = try await host.harness()
        _ = try await harness.openSession(HarnessSessionRequest())
        let createdAt = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        let open = try Self.openJournal(createdAt: createdAt)
        let openMseq = try await engine.worker.writeFile(
            path: Self.journalPath, data: Data(open.utf8))
        try await engine.worker.waitForAck(openMseq)
        try await waitUntil {
            FileManager.default.fileExists(
                atPath: fixture.materializedFile(Self.materializedJournal).path)
        }
        // What DSH's own resume/repair writes on the fresh Worker.
        await engine.worker.setRecoveryResumeJournal(
            sessionID: Self.sessionID, path: Self.journalPath,
            data: Data((open + (try Self.repairClosers(createdAt: createdAt))).utf8))

        // iOS froze the WebContent: terminate returns, no peer FIN arrives.
        engine.setTerminateLeavesPeerOpen(true)
        try await host.park()

        // Parked, not Failed.
        let parkedState = await host.state
        XCTAssertEqual(parkedState, .stopped)
        let parked = await host.diagnostics()
        XCTAssertEqual(parked.hostState, .parked,
                       "a non-quiescent background drain must still park")
        XCTAssertNil(parked.lastError, "the park must not fail the host")
        // The escalation stopped the old Worker once and booted nothing.
        XCTAssertEqual(engine.terminateCount, 1)
        XCTAssertEqual(engine.bootCount, 1,
                       "no replacement Worker may be booted on a non-quiescent close")
        // D18: the WAL is sealed at its tail and the fence covers it.
        let walTail = try Self.walTail(fixture)
        XCTAssertGreaterThanOrEqual(walTail, openMseq)
        XCTAssertEqual(parked.fence?.walSeq, walTail,
                       "fence.wal_seq must equal the sealed WAL tail")
        // The overlay was not repacked inside the drain window.
        XCTAssertLessThan(try Self.overlayWatermark(fixture) ?? 0, openMseq,
                          "the park must not pack an overlay over the open turn")
        // The open turn is recorded as interrupted, not as completed.
        let interrupted = await host.sessionsInterruptedAtParkForTesting()
        XCTAssertEqual(interrupted, [Self.sessionID: [1]])
        let parkedJournal = try String(
            contentsOf: fixture.materializedFile(Self.materializedJournal),
            encoding: .utf8).replacingOccurrences(of: "\\/", with: "/")
        XCTAssertFalse(parkedJournal.contains("turn/end"),
                       "the host never writes a session record itself")

        // Foreground: a fresh boot from the WAL, then DSH's own repair.
        engine.setTerminateLeavesPeerOpen(false)
        try await host.resume()
        let resumedState = await host.state
        XCTAssertEqual(resumedState, .running)
        XCTAssertEqual(engine.bootCount, 2)
        XCTAssertEqual(try Self.overlayWatermark(fixture), walTail,
                       "resume must mount an overlay packed at the sealed WAL tail")
        let repairs = await engine.worker.recoveryResumeRequests()
        XCTAssertEqual(repairs, [Self.sessionID],
                       "resume must run DSH's resume/repair for the interrupted session")
        // JSONSerialization escapes `/` in record types.
        let repaired = try String(
            contentsOf: fixture.materializedFile(Self.materializedJournal),
            encoding: .utf8).replacingOccurrences(of: "\\/", with: "/")
        XCTAssertTrue(repaired.contains("\"kind\":\"interrupted\""),
                      "the journal must end on an interrupted turn/end")
        XCTAssertTrue(repaired.contains("tool/result"),
                      "the dangling tool call must get a tool/result")
        let afterResume = await host.sessionsInterruptedAtParkForTesting()
        XCTAssertTrue(afterResume.isEmpty)
        try await host.stop()
    }

    /// The interrupted exit is a background-park decision only. A teardown
    /// still fails loud on the same escalation outcome.
    func testStopKeepsFailingLoudOnANonQuiescentEscalation() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let configuration = try fixture.configuration(drainDeadline: 3)
        let host = PhoneDSHHost(configuration: configuration,
                                engineFactory: { _ in engine })
        try await host.start()
        let harness = try await host.harness()
        _ = try await harness.openSession(HarnessSessionRequest())
        let createdAt = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        let mseq = try await engine.worker.writeFile(
            path: Self.journalPath,
            data: Data(try Self.openJournal(createdAt: createdAt).utf8))
        try await engine.worker.waitForAck(mseq)
        try await waitUntil {
            FileManager.default.fileExists(
                atPath: fixture.materializedFile(Self.materializedJournal).path)
        }
        engine.setTerminateLeavesPeerOpen(true)
        do {
            try await host.stop()
            XCTFail("a teardown must keep failing loud on a non-quiescent escalation")
        } catch {
            XCTAssertTrue(String(describing: error).contains("did not quiesce"),
                          "\(error)")
        }
        XCTAssertEqual(engine.bootCount, 1)
        let interrupted = await host.sessionsInterruptedAtParkForTesting()
        XCTAssertTrue(interrupted.isEmpty)
    }

    // MARK: - Fixtures

    private static func record(_ type: String, time: Int64,
                               fields: [String: Any] = [:],
                               data: [String: Any]? = nil) throws -> String {
        var object = fields
        object["type"] = type
        object["time"] = time
        if let data { object["data"] = data }
        let encoded = try JSONSerialization.data(withJSONObject: object,
                                                 options: [.sortedKeys])
        return String(decoding: encoded, as: UTF8.self) + "\n"
    }

    /// A DSH-shaped journal whose tail turn is open on an unanswered call.
    private static func openJournal(createdAt: Int64) throws -> String {
        var text = try record("session", time: createdAt, fields: [
            "id": sessionID,
            "createdAt": createdAt,
            "cwd": "/dsh/workspace",
            "version": 4,
        ])
        text += try record("turn/start", time: createdAt + 1, data: ["turn": 1])
        text += try record("step/start", time: createdAt + 2,
                           data: ["turn": 1, "step": 1])
        text += try record("assistant/message", time: createdAt + 3, data: [
            "turn": 1, "step": 1,
            "message": ["content": [[
                "type": "tool-call", "id": "call-1", "name": "shortcuts.run",
            ]]],
        ])
        text += try record("tool/call", time: createdAt + 4,
                           data: ["callId": "call-1"])
        return text
    }

    /// The closers the pinned session layer's `interruptedTurnClosers` appends.
    private static func repairClosers(createdAt: Int64) throws -> String {
        var text = try record("tool/result", time: createdAt + 4, fields: [
            "surfaceOp": "append",
        ], data: [
            "message": [
                "source": ["callId": "call-1"],
                "isError": true,
                "code": "TOOL_OUTCOME_UNKNOWN",
            ],
        ])
        text += try record("step/end", time: createdAt + 4,
                           data: ["turn": 1, "step": 1])
        text += try record("turn/end", time: createdAt + 4,
                           data: ["turn": 1, "reason": ["kind": "interrupted"]])
        return text
    }

    private static func walTail(_ fixture: FacadeFixture) throws -> UInt64 {
        let directory = fixture.workspace.appendingPathComponent("wal", isDirectory: true)
        return try WALReader.records(directory: directory, fromMseq: 1)
            .map(\.mseq).max() ?? 0
    }

    /// The materialized watermark the current overlay cache was packed at.
    private static func overlayWatermark(_ fixture: FacadeFixture) throws -> UInt64? {
        guard let enumerator = FileManager.default.enumerator(
            at: fixture.root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == "overlay-cache.json" {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            guard let sidecar = object as? [String: Any],
                  let watermark = sidecar["watermark"] as? NSNumber else { return nil }
            return watermark.uint64Value
        }
        return nil
    }
}
