// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — a background park must not abort a turn the App holds.
//
// Field report: two Bots were both working; switching Bot made the *other*
// Bot's turn end. The Bind path was one cause, but the background park had the
// same blast radius: `abortOpenSessionTurns` cancels every tracked session, so
// a park that won a race with the App's keep-alive decision silently cancelled
// the other Bot's turn. These regressions pin the host half of the fix:
//
// - a graceful park whose held session still has an open turn is refused with
//   `PhoneDSHParkHeld`; the host stays running, no Worker is torn down and no
//   turn is cancelled;
// - the hold is evidence-based: once the journal shows the turn closed (or the
//   session was never held), the same park proceeds normally;
// - a teardown (`stop()`) is not a background park and ignores the hold.

import Foundation
import XCTest
@testable import PhoneDSH
import PhoneDSHAgentCore
import PhoneDSHLog
import PhoneDSHWire

final class PhoneDSHParkHoldTests: XCTestCase {
    private static let sessionID = "mock-session"
    private static let journalPath =
        "/dsh/home/sessions/--dsh-workspace--/mock-session/session.v4.jsonl"
    private static let materializedJournal =
        "home/sessions/--dsh-workspace--/mock-session/session.v4.jsonl"

    func testAGracefulParkIsRefusedWhileTheAppHoldsAnOpenTurn() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = PhoneDSHHost(configuration: try fixture.configuration(drainDeadline: 3),
                                engineFactory: { _ in engine })
        try await host.start()
        _ = try await host.harness().openSession(HarnessSessionRequest())
        let createdAt = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        try await Self.writeJournal(fixture: fixture, engine: engine,
                                    text: try Self.openJournal(createdAt: createdAt))
        await host.setBackgroundTurnHoldProvider {
            PhoneDSHBackgroundTurnHold(sessionIDs: [Self.sessionID], reason: "bot_turn")
        }

        do {
            try await host.park()
            XCTFail("a park must not abort a turn the App's keep-alive path is holding")
        } catch let held as PhoneDSHParkHeld {
            XCTAssertEqual(held.sessionIDs, [Self.sessionID])
            XCTAssertEqual(held.reason, "bot_turn")
            XCTAssertTrue(held.localizedDescription.contains("没有暂停引擎"),
                          "the App reports this as a kept engine, not a park failure: \(held.localizedDescription)")
        }

        let state = await host.state
        XCTAssertEqual(state, .running,
                       "the refused park must leave the host running")
        XCTAssertEqual(engine.terminateCount, 0,
                       "a refused park must not tear the Worker down")
        XCTAssertEqual(engine.bootCount, 1)
        let interruptedAtPark = await host.sessionsInterruptedAtParkForTesting()
        XCTAssertTrue(interruptedAtPark.isEmpty,
                      "a refused park must not record an interruption")

        // The hold is scoped to what actually must stop: once the held turn is
        // closed, the same provider no longer protects it.
        try await Self.writeJournal(
            fixture: fixture, engine: engine,
            text: try Self.openJournal(createdAt: createdAt)
                + (try Self.endRecord(createdAt: createdAt)))
        try await host.park()
        let parkedState = await host.state
        XCTAssertEqual(parkedState, .stopped,
                       "a closed held turn must not block the park")
        let parked = await host.diagnostics()
        XCTAssertEqual(parked.hostState, .parked)
        XCTAssertNil(parked.lastError)
    }

    func testATeardownIgnoresTheHold() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = PhoneDSHHost(configuration: try fixture.configuration(drainDeadline: 3),
                                engineFactory: { _ in engine })
        try await host.start()
        _ = try await host.harness().openSession(HarnessSessionRequest())
        await host.setBackgroundTurnHoldProvider {
            PhoneDSHBackgroundTurnHold(sessionIDs: [Self.sessionID], reason: "bot_turn")
        }
        // No journal is written: the hold names a session with no open turn, so
        // it protects nothing. `stop()` must still ignore the provider entirely
        // (a teardown is not a background park).
        try await host.stop()
        let state = await host.state
        XCTAssertEqual(state, .stopped)
    }

    // MARK: - Fixtures

    private static func writeJournal(fixture: FacadeFixture, engine: MockEngine,
                                     text: String) async throws {
        let mseq = try await engine.worker.writeFile(
            path: journalPath, data: Data(text.utf8))
        try await engine.worker.waitForAck(mseq)
        try await waitUntil {
            FileManager.default.fileExists(
                atPath: fixture.materializedFile(materializedJournal).path)
        }
    }

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

    /// A DSH-shaped journal whose tail turn is open.
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
        return text
    }

    private static func endRecord(createdAt: Int64) throws -> String {
        try record("turn/end", time: createdAt + 3,
                   data: ["turn": 1, "reason": ["kind": "completed"]])
    }
}
