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

    func testPeriodicRescanReconcilesCreateThenDeleteWithoutFSEvents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-rescan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = Seen()
        let observer = BotSkillDirectoryObserver(
            root: root,
            onWritten: { seen.add("w:" + $0) },
            onDeleted: { seen.add("d:" + $0) })
        XCTAssertTrue(observer.start())
        // Simulates a coalesced create+delete that FSEvents never delivered:
        // the timer/fallback scan must still see both stamps in order.
        try Data("x".utf8).write(to: root.appendingPathComponent("weekly.md"))
        observer.scan()
        try FileManager.default.removeItem(at: root.appendingPathComponent("weekly.md"))
        observer.scan()
        observer.stop()
        XCTAssertEqual(seen.snapshot(), ["w:weekly.md", "d:weekly.md"])
    }
}
