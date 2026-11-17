// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class BotSkillDirectoryObserverRescanTests: XCTestCase {
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
        func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
    }

    func testPeriodicRescanReconcilesCreateThenDeleteWithoutFSEvents() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-rescan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = Seen()
        let observer = BotSkillDirectoryObserver(
            root: root, rescanInterval: nil,
            onWritten: { seen.add("w:" + $0) },
            onDeleted: { seen.add("d:" + $0) })
        XCTAssertTrue(observer.start())
        // Simulates a coalesced create+delete that FSEvents never delivered:
        // the timer/fallback scan must still see both stamps in order.
        try Data("x".utf8).write(to: root.appendingPathComponent("weekly.md"))
        await observer.scanForTesting()
        try FileManager.default.removeItem(at: root.appendingPathComponent("weekly.md"))
        await observer.scanForTesting()
        observer.stop()
        XCTAssertEqual(seen.snapshot(), ["w:weekly.md", "d:weekly.md"])
    }

    func testTimerFallbackSuppliesCreateAndDeleteWithoutFSEvents() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-timer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let written = expectation(description: "timer-written")
        let deleted = expectation(description: "timer-deleted")
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var written = false, deleted = false
            func write() -> Bool { lock.lock(); defer { lock.unlock() }
                if written { return false }; written = true; return true }
            func delete() -> Bool { lock.lock(); defer { lock.unlock() }
                if deleted { return false }; deleted = true; return true }
        }
        let once = Once()
        let observer = BotSkillDirectoryObserver(
            root: root, rescanInterval: 0.05, useFileSystemSource: false,
            onWritten: { _ in if once.write() { written.fulfill() } },
            onDeleted: { _ in if once.delete() { deleted.fulfill() } })
        XCTAssertTrue(observer.start())
        try Data("x".utf8).write(to: root.appendingPathComponent("timer.md"))
        await fulfillment(of: [written], timeout: 2)
        try FileManager.default.removeItem(at: root.appendingPathComponent("timer.md"))
        await fulfillment(of: [deleted], timeout: 2)
        observer.stop()
    }

    func testUnreadableRootEmitsOneTransition() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-unreadable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let observer = BotSkillDirectoryObserver(
            root: root, rescanInterval: 0.05, useFileSystemSource: false,
            onWritten: nil, onDeleted: nil)
        XCTAssertTrue(observer.start())
        try FileManager.default.removeItem(at: root)
        try Data("not-a-directory".utf8).write(to: root)
        for _ in 0..<100 where await observer.unreadableTransitionsForTesting() == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let transitions = await observer.unreadableTransitionsForTesting()
        observer.stop()
        XCTAssertEqual(transitions, 1)
    }

}
