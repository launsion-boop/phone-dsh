// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class MemoryDocumentTests: XCTestCase {
    private var store: SQLiteDomainStore!
    private var root: URL!

    override func setUp() async throws {
        (store, root) = try makeMemoryTestStore()
    }

    override func tearDown() async throws {
        try? await store?.close()
        cleanupMemoryTestStore(root)
    }

    private func context(
        kind: BotMemoryAuthorKind = .chat,
        session: String = "gb-main",
        source: BotMemorySourceKind = .userTurn,
        trust: BotRecordTrust? = .user
    ) -> BotMemoryWriteContext {
        BotMemoryWriteContext(
            botID: "bot-a",
            sessionID: session,
            authorKind: kind,
            source: BotMemorySource(kind: source, sessionID: session),
            trust: trust)
    }

    private func write(
        _ memory: BotMemory,
        _ action: BotMemoryAction,
        path: String,
        content: String? = nil,
        find: String? = nil,
        replace: String? = nil,
        to: String? = nil,
        expected: Int,
        restore: Int? = nil,
        context: BotMemoryWriteContext? = nil
    ) async throws -> BotMemoryWriteResult {
        try await memory.write(
            BotMemoryWriteRequest(
                action: action, path: path, content: content, find: find,
                replace: replace, to: to, expectedVersion: expected,
                restoreVersion: restore),
            context: context ?? self.context())
    }

    func testWriteReadModifyMoveDeleteRestore() async throws {
        let memory = makeMemory(store: store, botID: "bot-a")
        let created = try await write(
            memory, .write, path: "agent/notes/plan.md", content: "# Plan", expected: 0)
        XCTAssertTrue(created.ok)
        XCTAssertEqual(created.version, 1)
        XCTAssertEqual(created.scope, .agent)

        let appended = try await write(
            memory, .append, path: "agent/notes/plan.md", content: "\n- ship", expected: 1)
        XCTAssertEqual(appended.version, 2)

        let replaced = try await write(
            memory, .replace, path: "agent/notes/plan.md",
            find: "ship", replace: "review", expected: 2)
        XCTAssertTrue(replaced.ok)
        XCTAssertEqual(replaced.version, 3)
        XCTAssertEqual(replaced.replaced, 1)

        guard case let .document(document) = try await memory.read(path: "agent/notes/plan.md") else {
            return XCTFail("expected document")
        }
        XCTAssertEqual(document.content, "# Plan\n- review")
        XCTAssertEqual(document.version, 3)

        let moved = try await write(
            memory, .move, path: "agent/notes/plan.md",
            to: "agent/notes/plan-v2.md", expected: 3)
        XCTAssertTrue(moved.ok)
        XCTAssertEqual(moved.path, "agent/notes/plan-v2.md")
        XCTAssertEqual(moved.version, 1)

        guard case let .document(movedDocument) = try await memory.read(path: "agent/notes/plan-v2.md") else {
            return XCTFail("expected moved document")
        }
        XCTAssertEqual(movedDocument.content, "# Plan\n- review")

        let deleted = try await write(
            memory, .delete, path: "agent/notes/plan-v2.md", expected: 1)
        XCTAssertTrue(deleted.ok)
        XCTAssertEqual(deleted.version, 2)
        if case .failure = try await memory.read(path: "agent/notes/plan-v2.md") {
        } else {
            XCTFail("deleted document must not be live")
        }

        guard case let .document(deletedVersion) = try await memory.read(
            path: "agent/notes/plan-v2.md", version: 2) else {
            return XCTFail("deleted version must stay readable")
        }
        XCTAssertTrue(deletedVersion.deleted)

        let restored = try await write(
            memory, .restore, path: "agent/notes/plan-v2.md", expected: 0, restore: 1)
        XCTAssertTrue(restored.ok)
        XCTAssertEqual(restored.version, 3)
        guard case let .document(restoredDocument) = try await memory.read(path: "agent/notes/plan-v2.md") else {
            return XCTFail("expected restored document")
        }
        XCTAssertEqual(restoredDocument.content, "# Plan\n- review")
        let versions = try await memory.versions(path: "agent/notes/plan-v2.md")
        XCTAssertEqual(versions.map(\.version), [1, 2, 3])
    }

    func testVersionConflictAndIndexLimit() async throws {
        let memory = makeMemory(store: store, botID: "bot-a")
        _ = try await write(memory, .write, path: "agent/notes/a.md", content: "a", expected: 0)
        let conflict = try await write(
            memory, .write, path: "agent/notes/a.md", content: "b", expected: 0)
        XCTAssertFalse(conflict.ok)
        XCTAssertEqual(conflict.code, "memory-version-conflict")
        XCTAssertEqual(conflict.currentVersion, 1)

        let tooLong = String(repeating: "x", count: 1501)
        let rejected = try await write(
            memory, .write, path: "user/INDEX.md", content: tooLong, expected: 1,
            context: context())
        XCTAssertFalse(rejected.ok)
        XCTAssertEqual(rejected.code, "memory-index-too-long")
        XCTAssertEqual(rejected.limit, 1500)
        XCTAssertEqual(rejected.actual, 1501)
        let reader = SQLiteBotMemoryDocumentStore(eventLog: store, botID: "main", now: { 1_000 })
        let index = try await reader.document(path: "user/INDEX.md")
        XCTAssertNotEqual(index?.content, tooLong)
    }

    func testSingleAuthorInboxPolicy() async throws {
        let memory = makeMemory(store: store, botID: "bot-a")
        let task = context(kind: .task, session: "gb-task-1", source: .task, trust: .assistant)
        let denied = try await write(
            memory, .write, path: "agent/notes/a.md", content: "x", expected: 0, context: task)
        XCTAssertFalse(denied.ok)
        XCTAssertEqual(denied.code, "memory-scope-denied")

        let submitted = try await write(
            memory, .write, path: "agent/inbox/gb-task-1/report.md",
            content: "# Report", expected: 0, context: task)
        XCTAssertTrue(submitted.ok)

        let otherInbox = try await write(
            memory, .write, path: "agent/inbox/gb-task-2/report.md",
            content: "x", expected: 0, context: task)
        XCTAssertEqual(otherInbox.code, "memory-scope-denied")

        let routine = context(kind: .routine, session: "gb-routine-1",
                              source: .routine, trust: .assistant)
        let routineDenied = try await write(
            memory, .write, path: "agent/inbox/gb-task-1/x.md", content: "x",
            expected: 0, context: routine)
        XCTAssertEqual(routineDenied.code, "memory-scope-denied")
    }

    func testUserPathEvidenceBoundary() async throws {
        let memory = makeMemory(store: store, botID: "bot-a")
        let ok = try await write(
            memory, .write, path: "user/profile.md", content: "# Profile",
            expected: 0, context: context(trust: .user))
        XCTAssertTrue(ok.ok)

        let observed = try await write(
            memory, .write, path: "user/profile.md", content: "# Changed",
            expected: 1, context: context(trust: .observation))
        XCTAssertFalse(observed.ok)
        XCTAssertEqual(observed.code, "memory-evidence-required")

        let agentMessage = try await write(
            memory, .write, path: "user/notes/a.md", content: "x",
            expected: 0, context: context(source: .agentMessage, trust: .user))
        XCTAssertFalse(agentMessage.ok)
        XCTAssertEqual(agentMessage.code, "memory-source-boundary")
    }

    func testPathValidation() async throws {
        let memory = makeMemory(store: store, botID: "bot-a")
        for path in ["shared/x.md", "agent/../user/x.md", "/agent/x.md",
                     "agent//x.md", "agent", "agent/./x.md", "agent/x/"] {
            let result = try await write(
                memory, .write, path: path, content: "x", expected: 0)
            XCTAssertFalse(result.ok, path)
            XCTAssertEqual(result.code, "memory-path-invalid", path)
        }
    }

    func testMoveDestinationExists() async throws {
        let memory = makeMemory(store: store, botID: "bot-a")
        _ = try await write(memory, .write, path: "agent/a.md", content: "a", expected: 0)
        _ = try await write(memory, .write, path: "agent/b.md", content: "b", expected: 0)
        let result = try await write(
            memory, .move, path: "agent/a.md", to: "agent/b.md", expected: 1)
        XCTAssertEqual(result.code, "memory-path-exists")
    }

    func testDirectoryListing() async throws {
        let memory = makeMemory(store: store, botID: "bot-a")
        _ = try await write(memory, .write, path: "agent/index.md", content: "x", expected: 0)
        _ = try await write(memory, .write, path: "agent/notes/a.md", content: "a", expected: 0)
        _ = try await write(memory, .write, path: "agent/notes/b.md", content: "b", expected: 0)
        guard case let .directory(path, scope, entries) = try await memory.read(path: "agent") else {
            return XCTFail("expected directory")
        }
        XCTAssertEqual(path, "agent")
        XCTAssertEqual(scope, .agent)
        XCTAssertEqual(entries.map(\.path), ["agent/INDEX.md", "agent/index.md", "agent/notes"])
        guard case let .directory(_, _, notes) = try await memory.read(path: "agent/notes") else {
            return XCTFail("expected notes directory")
        }
        XCTAssertEqual(notes.map(\.path), ["agent/notes/a.md", "agent/notes/b.md"])
    }

    func testCrossBotIsolationAndErase() async throws {
        let main = makeMemory(store: store, botID: "main")
        let other = makeMemory(store: store, botID: "bot-b")
        _ = try await write(main, .write, path: "agent/private.md", content: "main", expected: 0)
        _ = try await write(other, .write, path: "agent/private.md", content: "b", expected: 0,
                            context: context(kind: .chat, session: "gb-b", trust: .assistant))
        guard case let .document(mainDocument) = try await main.read(path: "agent/private.md") else {
            return XCTFail("main document")
        }
        XCTAssertEqual(mainDocument.content, "main")
        guard case let .document(otherDocument) = try await other.read(path: "agent/private.md") else {
            return XCTFail("other document")
        }
        XCTAssertEqual(otherDocument.content, "b")

        let shared = try await write(
            main, .write, path: "user/profile.md", content: "# Profile", expected: 0,
            context: context(trust: .user))
        XCTAssertTrue(shared.ok)
        guard case let .document(sharedFromOther) = try await other.read(path: "user/profile.md") else {
            return XCTFail("shared document")
        }
        XCTAssertEqual(sharedFromOther.content, "# Profile")

        let erased = try await main.eraseAll(scope: .agent)
        XCTAssertGreaterThanOrEqual(erased.removed, 2)
        let mainReader = SQLiteBotMemoryDocumentStore(eventLog: store, botID: "main", now: { 1_000 })
        let erasedDocument = try await mainReader.document(path: "agent/private.md")
        let sharedDocument = try await mainReader.document(path: "user/profile.md")
        XCTAssertNil(erasedDocument)
        XCTAssertNotNil(sharedDocument)
        guard case let .document(otherStillThere) = try await other.read(path: "agent/private.md") else {
            return XCTFail("other Bot's document must survive")
        }
        XCTAssertEqual(otherStillThere.content, "b")
    }

    func testReplayIsIncrementalAndReopeningSeesDocuments() async throws {
        let memory = makeMemory(store: store, botID: "bot-a")
        _ = try await write(memory, .write, path: "agent/a.md", content: "a", expected: 0)
        let first = await memory.replayDiagnostics()
        _ = try await write(memory, .write, path: "agent/b.md", content: "b", expected: 0)
        let second = await memory.replayDiagnostics()
        XCTAssertGreaterThanOrEqual(second.processedMemoryEventCount, first.processedMemoryEventCount + 1)
        XCTAssertGreaterThanOrEqual(second.incrementalReplayCount, 1)
        XCTAssertTrue(second.skippedEventIDs.isEmpty)

        let reopened = makeMemory(store: store, botID: "bot-a")
        guard case let .document(document) = try await reopened.read(path: "agent/a.md") else {
            return XCTFail("reopened store must replay the document")
        }
        XCTAssertEqual(document.content, "a")
    }
}
