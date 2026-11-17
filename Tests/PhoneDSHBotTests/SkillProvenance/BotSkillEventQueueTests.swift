// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

private struct QueueTestRoots: BotSkillRootResolving {
    var user: URL
    var project: URL
    func root(for source: BotSkillSource, ownerBotID: String?) -> URL? {
        source == .userDsh ? user : project
    }
}

final class BotSkillEventQueueTests: XCTestCase {
    private var root: URL!
    private var user: URL!
    private var project: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-queue-\(UUID().uuidString)", isDirectory: true)
        user = root.appendingPathComponent("home/skills", isDirectory: true)
        project = root.appendingPathComponent("bot/.dsh/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func producer() -> BotSkillProvenanceProducer {
        BotSkillProvenanceProducer(
            botRoot: "/dsh/workspace/.dshbot/agents/bot-a",
            roots: QueueTestRoots(user: user, project: project),
            recorder: { _ in
                XCTFail("recorder must not run for a failed mutation")
                return BotDerivedRef(kind: .skill, id: "unused", version: 1)
            },
            latest: { _ in nil },
            now: { 1 })
    }

    private final class Order: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        func append(_ value: Int) { lock.lock(); values.append(value); lock.unlock() }
        func snapshot() -> [Int] { lock.lock(); defer { lock.unlock() }; return values }
    }

    func testFastWriteToDeleteEnqueueOrderIsFIFO() async {
        let queue = BotSkillEventQueue(producer: producer(), now: { 1 })
        let order = Order()
        for index in 0..<12 {
            queue.enqueue {
                if index == 0 { try? await Task.sleep(nanoseconds: 30_000_000) }
                order.append(index)
            }
        }
        // Let the serial chain finish.
        for _ in 0..<200 where order.snapshot().count < 12 {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(order.snapshot(), Array(0..<12))
        XCTAssertTrue(queue.diagnosticsSnapshot().isEmpty)
    }

    func testFailureDiagnosticsDistinguishMissingPreviousAndUnreadable() async {
        let queue = BotSkillEventQueue(producer: producer(), now: { 5 })
        await queue.userDelete("missing.md")
        await queue.runtimeWrite(
            vfs: "/dsh/workspace/.dshbot/agents/bot-a/.dsh/skills/missing.md",
            botID: "bot-a", sessionID: "gb-main")
        let diagnostics = queue.diagnosticsSnapshot()
        XCTAssertEqual(diagnostics.map(\.action), ["user-delete", "runtime-write"])
        XCTAssertTrue(diagnostics.allSatisfy { $0.outcome == .failed })
        XCTAssertEqual(diagnostics[0].detail, "missingPreviousVersion")
        XCTAssertEqual(diagnostics[1].detail, "unreadable")
        XCTAssertEqual(diagnostics[0].key, "missing.md")
        XCTAssertEqual(diagnostics[0].atMS, 5)
    }

    func testDiagnosticsRingIsBounded() async {
        let queue = BotSkillEventQueue(producer: producer(), now: { 1 })
        for _ in 0..<70 { await queue.userDelete("missing.md") }
        let diagnostics = queue.diagnosticsSnapshot()
        XCTAssertEqual(diagnostics.count, BotSkillEventQueue.diagnosticCapacity)
        XCTAssertTrue(diagnostics.allSatisfy { $0.outcome == .failed })
    }
}
