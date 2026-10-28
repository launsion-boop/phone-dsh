// SPDX-License-Identifier: MIT
// PhoneDSHController: D10 side-effect ledger tests (exec + MCP).

import Foundation
import XCTest
@testable import PhoneDSHController

final class SideEffectLedgerTests: XCTestCase {
    private func makeLedger(_ test: XCTestCase, root: URL? = nil,
                            quotaBytes: Int = 64 * 1024 * 1024,
                            clock: ManualHostClock = ManualHostClock()) throws -> SideEffectLedger {
        try SideEffectLedger(root: root ?? ControllerTestSupport.root(for: test),
                             quotaBytes: quotaBytes, clock: clock)
    }

    func testLookupMissOnEmptyLedger() async throws {
        let ledger = try makeLedger(self)
        let key = ControllerTestSupport.idemKey(1)
        let result = try await ledger.replayExec(idemKey: key, argv: ["rg", "x"],
                                                 cwd: "/dsh/workspace")
        XCTAssertEqual(result, .miss)
    }

    func testPrepareExecPersistsIntentBeforeEvents() async throws {
        let ledger = try makeLedger(self)
        let key = ControllerTestSupport.idemKey(2)
        let result = try await ledger.prepareExec(
            idemKey: key, execID: "exec-1", argv: ["rg", "--json"],
            cwd: "/dsh/workspace", stepID: "1", turnID: "turn-1")
        guard case .started(let entry) = result else {
            return XCTFail("a new key must start an entry")
        }
        XCTAssertEqual(entry.kind, .exec)
        XCTAssertFalse(entry.terminal)
        XCTAssertTrue(entry.events.isEmpty)
        let stored = await ledger.entry(forKey: key)
        XCTAssertEqual(stored, entry)
        let files = try FileManager.default.contentsOfDirectory(
            atPath: ledger.root.appendingPathComponent("exec").path)
        XCTAssertEqual(files, [key + ".json"])
    }

    func testEventStreamIsReplayedInOrder() async throws {
        let ledger = try makeLedger(self)
        let key = ControllerTestSupport.idemKey(3)
        _ = try await ledger.prepareExec(idemKey: key, execID: "exec-2",
                                         argv: ["jaq", "."], cwd: "/dsh/workspace")
        _ = try await ledger.appendExecEvent(
            idemKey: key,
            event: ControllerTestSupport.execEvent(type: "start"))
        _ = try await ledger.appendExecEvent(
            idemKey: key,
            event: ControllerTestSupport.execEvent(type: "stdout",
                                                   extra: ["data": "aGk="]))
        _ = try await ledger.appendExecEvent(
            idemKey: key,
            event: ControllerTestSupport.execEvent(type: "exit",
                                                   extra: ["exit_code": 0]))
        let replay = try await ledger.replayExec(idemKey: key,
                                                 argv: ["jaq", "."],
                                                 cwd: "/dsh/workspace")
        guard case .replay(let entry) = replay else {
            return XCTFail("the recorded stream must replay")
        }
        XCTAssertTrue(entry.terminal)
        XCTAssertEqual(entry.events.count, 3)
        XCTAssertTrue(entry.events[0].contains("\"start\""))
        XCTAssertTrue(entry.events[2].contains("\"exit\""))
    }

    func testConflictComparesArgvOnly() async throws {
        let ledger = try makeLedger(self)
        let key = ControllerTestSupport.idemKey(4)
        _ = try await ledger.prepareExec(idemKey: key, execID: "exec-3",
                                         argv: ["rg", "a"], cwd: "/dsh/workspace")
        let replay = try await ledger.replayExec(idemKey: key,
                                                 argv: ["rg", "b"],
                                                 cwd: "/dsh/workspace")
        guard case .conflict = replay else {
            return XCTFail("different argv must conflict")
        }
        // Transport-only fields are not stored and do not participate: the
        // same argv/cwd is still a replay.
        _ = try await ledger.appendExecEvent(
            idemKey: key,
            event: ControllerTestSupport.execEvent(type: "exit"))
        let same = try await ledger.replayExec(idemKey: key,
                                               argv: ["rg", "a"],
                                               cwd: "/dsh/workspace")
        guard case .replay = same else {
            return XCTFail("transport fields never participate in the comparison")
        }
    }

    func testConflictComparesCwd() async throws {
        let ledger = try makeLedger(self)
        let key = ControllerTestSupport.idemKey(5)
        _ = try await ledger.prepareExec(idemKey: key, execID: "exec-4",
                                         argv: ["rg", "a"], cwd: "/dsh/workspace")
        let result = try await ledger.replayExec(idemKey: key,
                                                 argv: ["rg", "a"],
                                                 cwd: "/dsh/home")
        guard case .conflict = result else {
            return XCTFail("a different cwd must conflict")
        }
    }

    func testInterruptedEntryReplaysTerminalErrorInsteadOfExecuting() async throws {
        let ledger = try makeLedger(self)
        let key = ControllerTestSupport.idemKey(6)
        _ = try await ledger.prepareExec(idemKey: key, execID: "exec-5",
                                         argv: ["rg", "x"], cwd: "/dsh/workspace")
        _ = try await ledger.appendExecEvent(
            idemKey: key,
            event: ControllerTestSupport.execEvent(type: "start"))
        let result = try await ledger.replayExec(idemKey: key,
                                                 argv: ["rg", "x"],
                                                 cwd: "/dsh/workspace")
        guard case .replay(let entry) = result else {
            return XCTFail("an interrupted entry replays a terminal error")
        }
        XCTAssertTrue(entry.terminal)
        XCTAssertTrue(entry.events.last?.contains("interrupted") ?? false)

        let again = try await ledger.replayExec(idemKey: key,
                                                argv: ["rg", "x"],
                                                cwd: "/dsh/workspace")
        guard case .replay(let second) = again else {
            return XCTFail("the terminal error is recorded once")
        }
        XCTAssertEqual(second.events.count, entry.events.count)
    }

    func testMCPRecordAndReplay() async throws {
        let ledger = try makeLedger(self)
        let key = ControllerTestSupport.idemKey(7)
        let arguments = Data("{\"query\":\"needle\"}".utf8)
        let response = Data("{\"result\":42}".utf8)
        let recorded = try await ledger.recordMCP(idempotencyKey: key,
                                                  arguments: arguments,
                                                  cwd: "/dsh/workspace",
                                                  response: response, status: 200)
        guard case .started(let entry) = recorded else {
            return XCTFail("a new MCP key records a response")
        }
        XCTAssertEqual(entry.kind, .mcp)
        XCTAssertEqual(entry.response, response)
        XCTAssertEqual(entry.status, 200)

        let replay = try await ledger.replayMCP(idempotencyKey: key,
                                                arguments: arguments,
                                                cwd: "/dsh/workspace")
        guard case .replay(let replayed) = replay else {
            return XCTFail("the recorded MCP response replays")
        }
        XCTAssertEqual(replayed.response, response)
    }

    func testMCPConflictComparesArgumentsAndCwd() async throws {
        let ledger = try makeLedger(self)
        let key = ControllerTestSupport.idemKey(8)
        _ = try await ledger.recordMCP(idempotencyKey: key,
                                       arguments: Data("{\"a\":1}".utf8),
                                       cwd: "/dsh/workspace",
                                       response: Data("ok".utf8))
        let differentArguments = try await ledger.replayMCP(
            idempotencyKey: key,
            arguments: Data("{\"a\":2}".utf8),
            cwd: "/dsh/workspace")
        guard case .conflict = differentArguments else {
            return XCTFail("different MCP arguments must conflict")
        }
        let differentCwd = try await ledger.replayMCP(
            idempotencyKey: key,
            arguments: Data("{\"a\":1}".utf8),
            cwd: "/dsh/home")
        guard case .conflict = differentCwd else {
            return XCTFail("a different MCP cwd must conflict")
        }
    }

    func testQuotaEvictsLeastRecentlyUsedJournaledEntry() async throws {
        let clock = ManualHostClock()
        let scratch = try makeLedger(self, clock: clock)
        let keyA = ControllerTestSupport.idemKey(11)
        _ = try await scratch.prepareExec(idemKey: keyA, execID: "exec-a",
                                          argv: ["rg", "a"], cwd: "/dsh/workspace")
        let entryBytes = await scratch.totalBytes
        let quota = entryBytes * 2 + 16

        let ledger = try makeLedger(self, quotaBytes: quota, clock: clock)
        let keyB = ControllerTestSupport.idemKey(12)
        let keyC = ControllerTestSupport.idemKey(13)
        _ = try await ledger.prepareExec(idemKey: keyA, execID: "exec-a",
                                         argv: ["rg", "a"], cwd: "/dsh/workspace")
        try await ledger.markJournaled(key: keyA)
        clock.advance(by: 5)
        _ = try await ledger.prepareExec(idemKey: keyB, execID: "exec-b",
                                         argv: ["rg", "b"], cwd: "/dsh/workspace")
        try await ledger.markJournaled(key: keyB)
        clock.advance(by: 5)
        let result = try await ledger.prepareExec(idemKey: keyC, execID: "exec-c",
                                                  argv: ["rg", "c"],
                                                  cwd: "/dsh/workspace")
        guard case .started = result else {
            return XCTFail("the new entry must be admitted after eviction")
        }
        let keys = await ledger.keys()
        XCTAssertFalse(keys.contains(keyA), "the LRU journaled entry is evicted")
        XCTAssertTrue(keys.contains(keyB))
        XCTAssertTrue(keys.contains(keyC))
        let usedBytes = await ledger.totalBytes
        XCTAssertLessThanOrEqual(usedBytes, quota)
    }

    func testQuotaNeverEvictsUnjournaledStepAndFailsLoud() async throws {
        let clock = ManualHostClock()
        let scratch = try makeLedger(self, clock: clock)
        let keyA = ControllerTestSupport.idemKey(21)
        _ = try await scratch.prepareExec(idemKey: keyA, execID: "exec-a",
                                          argv: ["rg", "a"], cwd: "/dsh/workspace")
        let quota = await scratch.totalBytes + 8

        let ledger = try makeLedger(self, quotaBytes: quota, clock: clock)
        _ = try await ledger.prepareExec(idemKey: keyA, execID: "exec-a",
                                         argv: ["rg", "a"], cwd: "/dsh/workspace")
        do {
            _ = try await ledger.prepareExec(idemKey: ControllerTestSupport.idemKey(22),
                                             execID: "exec-b", argv: ["rg", "b"],
                                             cwd: "/dsh/workspace")
            XCTFail("an un-journaled step must never be evicted")
        } catch {
            guard case .quotaExceeded = error as? LedgerError else {
                return XCTFail("expected quotaExceeded, got \(error)")
            }
            let keys = await ledger.keys()
            XCTAssertEqual(keys, [keyA])
        }
    }

    func testMarkJournaledMakesTheEntryEvictable() async throws {
        let clock = ManualHostClock()
        let scratch = try makeLedger(self, clock: clock)
        let keyA = ControllerTestSupport.idemKey(31)
        _ = try await scratch.prepareExec(idemKey: keyA, execID: "exec-a",
                                          argv: ["rg", "a"], cwd: "/dsh/workspace")
        let quota = await scratch.totalBytes + 64

        let ledger = try makeLedger(self, quotaBytes: quota, clock: clock)
        _ = try await ledger.prepareExec(idemKey: keyA, execID: "exec-a",
                                         argv: ["rg", "a"], cwd: "/dsh/workspace")
        try await ledger.markJournaled(key: keyA)
        let keyB = ControllerTestSupport.idemKey(32)
        _ = try await ledger.prepareExec(idemKey: keyB, execID: "exec-b",
                                         argv: ["rg", "b"], cwd: "/dsh/workspace")
        let keys = await ledger.keys()
        XCTAssertEqual(keys, [keyB])
    }

    func testLedgerPersistsAcrossBoot() async throws {
        let root = ControllerTestSupport.root(for: self)
        let ledger = try makeLedger(self, root: root)
        let key = ControllerTestSupport.idemKey(41)
        _ = try await ledger.prepareExec(idemKey: key, execID: "exec-1",
                                         argv: ["rg", "x"], cwd: "/dsh/workspace",
                                         stepID: "2", turnID: "turn-9")
        _ = try await ledger.appendExecEvent(
            idemKey: key,
            event: ControllerTestSupport.execEvent(
                type: "exit", extra: ["exit_code": 1]))
        let before = await ledger.entry(forKey: key)
        let bytes = await ledger.totalBytes

        let reloaded = try makeLedger(self, root: root)
        let after = await reloaded.entry(forKey: key)
        XCTAssertEqual(after, before)
        let reloadedBytes = await reloaded.totalBytes
        XCTAssertEqual(reloadedBytes, bytes)
        let replay = try await reloaded.replayExec(idemKey: key,
                                                   argv: ["rg", "x"],
                                                   cwd: "/dsh/workspace")
        guard case .replay = replay else {
            return XCTFail("the replayed entry survives a boot")
        }
    }

    func testInvalidKeyIsRejected() async throws {
        let ledger = try makeLedger(self)
        do {
            _ = try await ledger.prepareExec(idemKey: "../escape", execID: "exec-1",
                                             argv: ["rg"], cwd: "/dsh/workspace")
            XCTFail("a key is never used as a path before validation")
        } catch {
            XCTAssertEqual(error as? LedgerError, .invalidKey("../escape"))
        }
    }

    func testExecIDIsValidated() async throws {
        let ledger = try makeLedger(self)
        do {
            _ = try await ledger.prepareExec(idemKey: ControllerTestSupport.idemKey(51),
                                             execID: "bad/exec",
                                             argv: ["rg"], cwd: "/dsh/workspace")
            XCTFail("invalid exec_id must be rejected")
        } catch {
            XCTAssertEqual(error as? LedgerError, .invalidKey("bad/exec"))
        }
    }

    func testAppendEventRequiresARecordedEntry() async throws {
        let ledger = try makeLedger(self)
        do {
            _ = try await ledger.appendExecEvent(
                idemKey: ControllerTestSupport.idemKey(61),
                event: ControllerTestSupport.execEvent(type: "exit"))
            XCTFail("events are recorded before they are emitted")
        } catch {
            guard case .missingEntry = error as? LedgerError else {
                return XCTFail("expected missingEntry, got \(error)")
            }
        }
    }
}
