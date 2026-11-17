// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// D07: a second Bot must read and recall the shared `user/` documents, not
/// only the user INDEX. Real store, two Bot authorities.
final class MemorySharedUserScopeTests: XCTestCase {
    private var store: SQLiteDomainStore!
    private var root: URL!

    override func setUp() async throws {
        (store, root) = try makeMemoryTestStore()
    }

    override func tearDown() async throws {
        try? await store?.close()
        cleanupMemoryTestStore(root)
    }

    func testSecondBotReadsSharedUserDocumentAndRecallsIt() async throws {
        let main = makeMemory(store: store, botID: "main")
        let secondary = makeMemory(store: store, botID: "bot-b")
        let context = BotMemoryWriteContext(
            botID: "main", sessionID: "gb-main", authorKind: .chat,
            source: BotMemorySource(kind: .userTurn, sessionID: "gb-main"),
            trust: .user, isMainBot: true)
        let written = try await main.write(
            BotMemoryWriteRequest(
                action: .write, path: "user/profile.md",
                content: "# Profile\n- Americano", expectedVersion: 0),
            context: context)
        XCTAssertTrue(written.ok, "\(String(describing: written.code))")

        guard case let .document(document) = try await secondary.read(path: "user/profile.md") else {
            return XCTFail("the second Bot must read the shared user document")
        }
        XCTAssertEqual(document.content, "# Profile\n- Americano")
        let hits = try await secondary.recall("Americano", limit: 10, scope: .user)
        XCTAssertEqual(hits.map(\.path), ["user/profile.md"],
                       "the second Bot must recall shared user content")
        // D07 repeat-2 shape: the second Bot asked for `ReadMemory user/`
        // before reading the document. The root directory listing must work.
        guard case let .directory(path, _, entries) = try await secondary.read(path: "user/") else {
            return XCTFail("ReadMemory user/ must return the shared user directory")
        }
        XCTAssertEqual(path, "user")
        XCTAssertTrue(entries.contains { $0.path == "user/profile.md" },
                      "directory listing must expose the shared document: \(entries.map(\.path))")
    }
}
