// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Q1 D07 / C task: a shared `user/` document written by one Bot must be
/// readable and recallable by every Bot, and its provenance view must not be
/// narrowed to the writer. L's provenance is process-wide; this test proves the
/// read/provenance side against the real SQLite memory store.
final class BotProvenanceCrossBotTests: XCTestCase {
    func testSharedUserDocumentIsVisibleToSecondBotAndProvenance() async throws {
        let (store, root) = try makeMemoryTestStore()
        defer { cleanupMemoryTestStore(root) }
        let writer = makeMemory(store: store, botID: "main")
        let reader = makeMemory(store: store, botID: "bot-b")
        let source = try await store.append(ProvenanceTest.event(
            type: "conversation.user_message", eventId: "shared-user-source",
            data: .object(["text": .string("remember the shared profile")])))
        let context = BotMemoryWriteContext(
            botID: "main", sessionID: "gb-main", authorKind: .chat,
            source: BotMemorySource(kind: .userTurn, sessionID: "gb-main"),
            trust: .user, isMainBot: true)
        let written = try await writer.write(
            BotMemoryWriteRequest(
                path: "user/profile.md",
                content: "shared profile from the main Bot",
                expectedVersion: 0,
                evidence: ["record://event/\(source)"]),
            context: context)
        XCTAssertTrue(written.ok, "\(String(describing: written.code))")
        let version = try XCTUnwrap(written.version)

        // Second Bot reads the shared document and recalls it (D07).
        let read = try await reader.read(path: "user/profile.md")
        guard case let .document(document) = read else {
            return XCTFail("second Bot cannot read shared user document: \(read)")
        }
        XCTAssertEqual(document.content, "shared profile from the main Bot")
        let hits = try await reader.recall("shared profile", limit: 10, scope: .user)
        XCTAssertTrue(hits.contains { $0.path == "user/profile.md" },
                      "second Bot recall misses shared user document")

        // The process-wide provenance view must be available to the second Bot
        // and must not be filtered by who reads it.
        let artifact = BotDerivedRef(kind: .memory, id: "user/profile.md", version: version)
        let service = BotProvenanceService(eventLog: store)
        let state = try await service.currentState(for: artifact)
        XCTAssertEqual(state.state, .current)
        XCTAssertEqual(state.sources.first?.status.resolved, true)
        XCTAssertEqual(state.sources.first?.status.ref, "record://event/\(source)")
        let reverse = try await service.reverseTrace(derivedRef: artifact)
        XCTAssertEqual(reverse.first?.sources.first?.record, "record://event/\(source)")
        try? await store.close()
    }
}
