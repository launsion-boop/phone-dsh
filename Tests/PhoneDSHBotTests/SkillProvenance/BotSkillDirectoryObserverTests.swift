// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class BotSkillDirectoryObserverTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-observer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testReconcilerTreatsMissingAsDeleteButUnreadableAsNoChange() {
        let stamp = BotSkillFileStamp(name: "a.md", size: 2, modifiedAtMS: 1)
        let previous = ["a.md": stamp]
        XCTAssertEqual(
            BotSkillDirectoryReconciler.changes(previous: previous, current: .missing),
            [.deleted("a.md")])
        XCTAssertEqual(
            BotSkillDirectoryReconciler.changes(previous: previous, current: .unreadable),
            [])
        XCTAssertEqual(
            BotSkillDirectoryReconciler.changes(previous: previous, current: .present([:])),
            [.deleted("a.md")])
        XCTAssertEqual(
            BotSkillDirectoryReconciler.changes(
                previous: nil, current: .missing),
            [])
    }

    func testReconcilerEmitsWrittenAndDeletedFromRealDirectory() throws {
        try Data("a".utf8).write(to: root.appendingPathComponent("a.md"))
        guard case .present(let first) = BotSkillDirectoryReconciler.snapshot(root) else {
            return XCTFail("expected present snapshot")
        }
        XCTAssertNotNil(first["a.md"])
        try Data("bb".utf8).write(to: root.appendingPathComponent("b.md"))
        guard case .present(let second) = BotSkillDirectoryReconciler.snapshot(root) else {
            return XCTFail("expected present snapshot")
        }
        XCTAssertEqual(
            BotSkillDirectoryReconciler.changes(previous: first, current: .present(second)),
            [.written("b.md")])
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.md"))
        guard case .present(let third) = BotSkillDirectoryReconciler.snapshot(root) else {
            return XCTFail("expected present snapshot")
        }
        XCTAssertEqual(
            BotSkillDirectoryReconciler.changes(previous: second, current: .present(third)),
            [.deleted("a.md")])
    }

    func testObserverReportsRealFileWriteAndDelete() async throws {
        let written = expectation(description: "written")
        let deleted = expectation(description: "deleted")
        final class Seen: @unchecked Sendable {
            let lock = NSLock()
            var names: [String] = []
            func add(_ name: String) -> Int { lock.withLock { names.append(name); return names.count } }
        }
        let seen = Seen()
        let observer = BotSkillDirectoryObserver(
            root: root,
            onWritten: { name in
                if seen.add("w:" + name) > 0 { written.fulfill() }
            },
            onDeleted: { name in
                if seen.add("d:" + name) > 0 { deleted.fulfill() }
            })
        XCTAssertTrue(observer.start())
        try Data("skill".utf8).write(to: root.appendingPathComponent("live.md"))
        await fulfillment(of: [written], timeout: 3)
        try FileManager.default.removeItem(at: root.appendingPathComponent("live.md"))
        await fulfillment(of: [deleted], timeout: 3)
        observer.stop()
    }
}
