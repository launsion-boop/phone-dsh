// SPDX-License-Identifier: MIT

import CryptoKit
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

    func testSharedObserverAndRuntimeLanesUseOneTail() async {
        let queue = BotSkillEventQueue(producer: producer(), now: { 1 })
        let order = Order()
        // Simulates the observer callback (sync enqueue) followed by the
        // runtime write (awaiting enqueue) on the same shared queue.
        queue.enqueue {
            try? await Task.sleep(nanoseconds: 20_000_000)
            order.append(1)
        }
        await queue.enqueueAndWait { order.append(2) }
        XCTAssertEqual(order.snapshot(), [1, 2])
    }

    func testRuntimeWriteAwaitsMutationCompletionBeforeReturning() async throws {
        final class Store: @unchecked Sendable {
            private let lock = NSLock()
            private var value: BotSkillChangeSnapshot?
            func set(_ value: BotSkillChangeSnapshot) { lock.lock(); self.value = value; lock.unlock() }
            func get() -> BotSkillChangeSnapshot? { lock.lock(); defer { lock.unlock() }; return value }
        }
        let store = Store()
        let file = project.appendingPathComponent("immediate.md")
        try Data("hello".utf8).write(to: file)
        let producer = BotSkillProvenanceProducer(
            botRoot: "/dsh/workspace/.dshbot/agents/bot-a",
            roots: QueueTestRoots(user: user, project: project),
            recorder: { request in
                store.set(BotSkillChangeSnapshot(
                    name: request.name, file: request.file,
                    revision: request.revision, action: request.action.rawValue,
                    source: request.source, ownerBotID: request.ownerBotID,
                    contentSHA256: request.contentSHA256,
                    previousSHA256: request.previousSHA256,
                    bytes: request.bytes,
                    carrier: "record://event/1", atMS: request.atMS))
                return BotDerivedRef(kind: .skill, id: request.name,
                                     version: request.revision)
            },
            latest: { _ in store.get() },
            now: { 1 })
        let queue = BotSkillEventQueue(producer: producer, now: { 1 })
        await queue.runtimeWrite(
            vfs: "/dsh/workspace/.dshbot/agents/bot-a/.dsh/skills/immediate.md",
            botID: "bot-a", sessionID: "gb-main")
        // The mutation carrier is visible immediately after await returns.
        XCTAssertEqual(store.get()?.revision, 1)
        XCTAssertEqual(store.get()?.contentSHA256,
                       "sha256:" + SHA256.hash(data: Data("hello".utf8))
                        .map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(queue.diagnosticsSnapshot().last?.action, "runtime-write")
        XCTAssertEqual(queue.diagnosticsSnapshot().last?.outcome, .recorded)
    }


    func testSelectionRouterDoesNotDropUserWriteDuringSwitch() async {
        let q1 = BotSkillEventQueue(producer: producer(), now: { 1 })
        let q2 = BotSkillEventQueue(producer: producer(), now: { 2 })
        let router = BotSkillQueueRouter()
        router.set(q1)
        router.userDelete("missing.md")
        // Simulate the selection switch. The observer is still alive; the
        // callback after this point must go to q2, never disappear.
        router.set(q2)
        router.userDelete("missing.md")
        // Drain both serial tails without depending on a UI thread.
        for _ in 0..<200 where q1.diagnosticsSnapshot().isEmpty
            || q2.diagnosticsSnapshot().isEmpty {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(q1.diagnosticsSnapshot().count, 1)
        XCTAssertEqual(q2.diagnosticsSnapshot().count, 1)
        XCTAssertEqual(q1.diagnosticsSnapshot().first?.key, "missing.md")
        XCTAssertEqual(q2.diagnosticsSnapshot().first?.key, "missing.md")
    }

}
