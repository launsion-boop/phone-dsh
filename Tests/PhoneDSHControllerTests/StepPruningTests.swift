// SPDX-License-Identifier: MIT
// W2 journal/step pruning: only terminal, durable records may be dropped.

import Foundation
import XCTest
@testable import PhoneDSHController
import PhoneDSHWire

final class StepPruningTests: XCTestCase {
    private let keyOpen = "xl1-11111111111111111111111111111111"
    private let keyClosed = "xl1-22222222222222222222222222222222"

    private func root() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-step-prune-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func body(_ jseq: UInt64, _ type: String, key: String) -> JournalBody {
        let record = "{\"v\":1,\"type\":\"\(type)\",\"key\":\"\(key)\","
            + "\"call_id\":\"call-\(key)\",\"tool\":\"bash\"}"
        return JournalBody(jseq: jseq, sessionID: "s", record: Data(record.utf8))
    }

    private func stepsFile(_ root: URL) -> URL {
        root.appendingPathComponent("steps").appendingPathComponent("s.ndjson")
    }

    private func snapshot(_ root: URL, key: String) -> URL {
        root.appendingPathComponent("steps").appendingPathComponent("s")
            .appendingPathComponent(key + ".json")
    }

    func testPruneDropsOnlyDurableJournaledStepsAndTheirFiles() async throws {
        let root = root()
        let machine = try StepMachine(root: root)
        _ = try await machine.observeJournal(body(1, "dispatched", key: keyOpen))
        _ = try await machine.observeJournal(body(2, "dispatched", key: keyClosed))
        _ = try await machine.observeJournal(body(3, "completed", key: keyClosed))

        // Level 2 has not covered jseq 3 yet.
        let before = try await machine.pruneTerminalSteps(
            journalDurableJseq: ["s": 2])
        XCTAssertTrue(before.isEmpty)
        let closedBefore = await machine.record(sessionID: "s", stepKey: keyClosed)
        XCTAssertNotNil(closedBefore)

        let removed = try await machine.pruneTerminalSteps(
            journalDurableJseq: ["s": 3])
        XCTAssertEqual(removed.map(\.stepKey), [keyClosed])
        let closedAfter = await machine.record(sessionID: "s", stepKey: keyClosed)
        XCTAssertNil(closedAfter)
        let openAfter = await machine.record(sessionID: "s", stepKey: keyOpen)
        XCTAssertNotNil(openAfter)

        let text = try String(contentsOf: stepsFile(root), encoding: .utf8)
        XCTAssertTrue(text.contains(keyOpen))
        XCTAssertFalse(text.contains(keyClosed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot(root, key: keyClosed).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot(root, key: keyOpen).path))

        // A fresh process reconstructs only the surviving step.
        let reopened = try StepMachine(root: root)
        let reopenedKeys = await reopened.allRecords().map(\.stepKey)
        XCTAssertEqual(reopenedKeys, [keyOpen])
    }

    func testAbandonedStepIsPrunedOnceItsOwnLineIsDurable() async throws {
        let root = root()
        let machine = try StepMachine(root: root)
        _ = try await machine.observeJournal(body(1, "dispatched", key: keyOpen))
        _ = try await machine.settleOrphans(reason: "test")
        let removed = try await machine.pruneTerminalSteps(journalDurableJseq: [:])
        XCTAssertEqual(removed.map(\.stepKey), [keyOpen])
        let remaining = await machine.allRecords()
        XCTAssertTrue(remaining.isEmpty)
        let reopened = try StepMachine(root: root)
        let reopenedRecords = await reopened.allRecords()
        XCTAssertTrue(reopenedRecords.isEmpty)
    }

    func testReferencedTerminalStepIsKept() async throws {
        let root = root()
        let machine = try StepMachine(root: root)
        _ = try await machine.observeJournal(body(1, "dispatched", key: keyClosed))
        _ = try await machine.observeJournal(body(2, "completed", key: keyClosed))
        let removed = try await machine.pruneTerminalSteps(
            journalDurableJseq: ["s": 2],
            referencedStepKeys: [keyClosed])
        XCTAssertTrue(removed.isEmpty)
        let kept = await machine.record(sessionID: "s", stepKey: keyClosed)
        XCTAssertNotNil(kept)
    }

    func testRewriteRemovesATornFinalLineAndKeepsOpenSteps() async throws {
        let root = root()
        let machine = try StepMachine(root: root)
        _ = try await machine.observeJournal(body(1, "dispatched", key: keyOpen))
        _ = try await machine.observeJournal(body(2, "dispatched", key: keyClosed))
        _ = try await machine.observeJournal(body(3, "completed", key: keyClosed))
        let url = stepsFile(root)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"v\":1,\"step_id\":\"torn".utf8))
        try handle.close()

        let removed = try await machine.pruneTerminalSteps(
            journalDurableJseq: ["s": 3])
        XCTAssertEqual(removed.map(\.stepKey), [keyClosed])
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("torn"))
        XCTAssertTrue(text.contains(keyOpen))
        // A reload ignores nothing and still sees exactly the open step.
        let reopened = try StepMachine(root: root)
        let reopenedKeys = await reopened.allRecords().map(\.stepKey)
        XCTAssertEqual(reopenedKeys, [keyOpen])
    }
}
