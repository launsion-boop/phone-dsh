// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class MemoryMigrationTests: XCTestCase {
    private var store: SQLiteDomainStore!
    private var root: URL!

    override func setUp() async throws {
        (store, root) = try makeMemoryTestStore()
    }

    override func tearDown() async throws {
        try? await store?.close()
        cleanupMemoryTestStore(root)
    }

    private func loadGolden() throws -> MemoryMigrationGolden {
        try MemoryTestFixtures.decode(MemoryMigrationGolden.self, "memory-migration")
    }

    private func seed(_ golden: MemoryMigrationGolden, botID: String) async throws {
        for fact in golden.facts {
            guard fact.owner == botID || fact.owner == "shared" else { continue }
            let legacy = makeLegacyFact(
                fact.factID,
                fact.text,
                tier: fact.tier,
                scope: fact.scope,
                learnedAtMS: fact.learnedAtMS,
                key: fact.key,
                evidence: fact.evidence)
            try await appendLegacyFact(
                legacy,
                ownerBotID: fact.owner == "shared" ? nil : fact.owner,
                store: store,
                atMS: fact.learnedAtMS)
        }
    }

    func testMigrationRendersLegacyFactsPerScopeAndBot() async throws {
        let golden = try loadGolden()
        for botID in golden.bots {
            try await seed(golden, botID: botID)
            let memory = makeMemory(store: store, botID: botID)
            let documents = try await memory.documents(scope: nil)
            let contents = Dictionary(uniqueKeysWithValues: documents.map { ($0.path, $0.content) })
            XCTAssertEqual(contents, golden.expected[botID]?.documents, botID)
            let evidence = Dictionary(uniqueKeysWithValues: documents.map { ($0.path, $0.evidence) })
            for (path, expected) in golden.expected[botID]?.evidence ?? [:] {
                XCTAssertEqual(evidence[path], expected, "\(botID):\(path)")
            }
            for fact in golden.facts
            where fact.owner == botID || (fact.owner == "shared" && fact.scope == .user) {
                XCTAssertTrue(
                    documents.contains { $0.content.contains(fact.text) },
                    "\(botID) lost fact \(fact.factID)")
            }
        }
    }

    func testMigrationIsIdempotentAndReplayable() async throws {
        let golden = try loadGolden()
        try await seed(golden, botID: "main")
        let first = makeMemory(store: store, botID: "main")
        let firstDocuments = try await first.documents(scope: nil)
        let firstEvents = try await store.events(after: 0, limit: 1_000)
        XCTAssertFalse(firstEvents.isEmpty)

        let replayed = makeMemory(store: store, botID: "main")
        let replayedDocuments = try await replayed.documents(scope: nil)
        let secondEvents = try await store.events(after: 0, limit: 1_000)
        XCTAssertEqual(
            firstDocuments.map { "\($0.path)#\($0.version):\($0.content)" },
            replayedDocuments.map { "\($0.path)#\($0.version):\($0.content)" })
        XCTAssertEqual(firstEvents.count, secondEvents.count)
    }

    func testSharedUserDocumentsAreMigratedOnceAcrossBots() async throws {
        let golden = try loadGolden()
        try await seed(golden, botID: "main")
        try await seed(golden, botID: "bot-b")
        _ = try await makeMemory(store: store, botID: "main").documents(scope: nil)
        let afterMain = try await store.events(after: 0, limit: 1_000)
        _ = try await makeMemory(store: store, botID: "bot-b").documents(scope: nil)
        let afterOther = try await store.events(after: 0, limit: 1_000)
        let userWrites = afterOther.filter {
            $0.type == "memory.document_written"
                && $0.principal.botId == nil
        }
        XCTAssertGreaterThanOrEqual(afterOther.count, afterMain.count)
        XCTAssertLessThanOrEqual(userWrites.count, 3, "shared user docs must not be duplicated")
        let otherDocuments = try await makeMemory(store: store, botID: "bot-b").documents(scope: nil)
        let paths = Set(otherDocuments.map(\.path))
        XCTAssertTrue(paths.contains("user/profile.md"))
        XCTAssertTrue(paths.contains("agent/notes/deploy.md"))
        XCTAssertFalse(paths.contains("agent/notes/routine.md"))
    }
}
