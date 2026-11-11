// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class MemoryInjectionRecallTests: XCTestCase {
    private var store: SQLiteDomainStore!
    private var root: URL!

    override func setUp() async throws {
        (store, root) = try makeMemoryTestStore()
    }

    override func tearDown() async throws {
        try? await store?.close()
        cleanupMemoryTestStore(root)
    }

    func testInjectionContainsOnlyTheTwoRootIndexes() async throws {
        let golden: MemoryInjectionGolden = try MemoryTestFixtures.decode(
            MemoryInjectionGolden.self, "memory-injection")
        _ = try await seedDocument(
            makeDocument(golden.indexes.user.path, golden.indexes.user.content,
                         version: golden.indexes.user.version,
                         author: BotMemoryAuthor(botID: "main", kind: .chat)),
            store: store, botID: "main")
        _ = try await seedDocument(
            makeDocument(golden.indexes.agent.path, golden.indexes.agent.content,
                         version: golden.indexes.agent.version,
                         author: BotMemoryAuthor(botID: "main", kind: .chat)),
            store: store, botID: "main")

        let memory = makeMemory(store: store, botID: "main")
        let injection = try await memory.injection()
        XCTAssertEqual(injection.text, golden.valid.text)
        XCTAssertEqual(injection.limits.index, 1500)
        XCTAssertEqual(injection.limits.total, 4000)
        XCTAssertEqual(injection.text.unicodeScalars.count, golden.valid.text.unicodeScalars.count)
        XCTAssertLessThanOrEqual(injection.text.unicodeScalars.count, 4000)
        XCTAssertEqual(injection.text.components(separatedBy: "INDEX.md").count - 1, 3)
    }

    func testEmptyIndexesRenderEmptyPlaceholders() async throws {
        let golden: MemoryInjectionGolden = try MemoryTestFixtures.decode(
            MemoryInjectionGolden.self, "memory-injection")
        _ = try await seedDocument(
            makeDocument("user/INDEX.md", "", version: 1,
                         author: BotMemoryAuthor(botID: "main", kind: .system)),
            store: store, botID: "main")
        _ = try await seedDocument(
            makeDocument("agent/INDEX.md", "", version: 1,
                         author: BotMemoryAuthor(botID: "main", kind: .system)),
            store: store, botID: "main")
        let memory = makeMemory(store: store, botID: "main")
        let injection = try await memory.injection()
        XCTAssertEqual(injection.text, golden.emptyIndex.text)
    }

    func testRecallUsesBM25AndCJKSnippetsWithoutImportance() async throws {
        let golden: MemoryRecallExpected = try MemoryTestFixtures.decode(
            MemoryRecallExpected.self, "memory-recall")
        for document in golden.documents {
            _ = try await seedDocument(document, store: store, botID: "main")
        }
        let memory = makeMemory(store: store, botID: "main")
        for query in golden.queries {
            let scope: BotMemoryScope?
            switch query.scope {
            case "agent": scope = .agent
            case "user": scope = .user
            default: scope = nil
            }
            let hits = try await memory.recall(query.query, limit: query.limit, scope: scope)
            XCTAssertEqual(Array(hits.map(\.path).prefix(query.expectedPaths.count)),
                           query.expectedPaths, query.name)
            for expected in query.snippetContains ?? [] {
                XCTAssertTrue(hits.contains { $0.snippet.contains(expected) },
                              "\(query.name) missing snippet \(expected)")
            }
            for hit in hits {
                XCTAssertLessThanOrEqual(hit.snippet.unicodeScalars.count, 500)
                XCTAssertGreaterThanOrEqual(hit.score, 0)
                XCTAssertLessThanOrEqual(hit.score, 1)
                XCTAssertFalse(hit.path.isEmpty)
            }
        }
    }

    func testRecallScopeDoesNotLeakAgentDocuments() async throws {
        _ = try await seedDocument(
            makeDocument("agent/private.md", "secret agent note"), store: store, botID: "main")
        _ = try await seedDocument(
            makeDocument("user/shared.md", "shared agent note"), store: store, botID: "main")
        let memory = makeMemory(store: store, botID: "main")
        let agentHits = try await memory.recall("agent note", limit: 10, scope: .agent)
        XCTAssertEqual(agentHits.map(\.path), ["agent/private.md"])
        let userHits = try await memory.recall("agent note", limit: 10, scope: .user)
        XCTAssertEqual(userHits.map(\.path), ["user/shared.md"])
    }

    func testRecallPageReportsTotal() async throws {
        for index in 0..<6 {
            _ = try await seedDocument(
                makeDocument("agent/notes/\(index).md", "重复 内容 \(index)"),
                store: store, botID: "main")
        }
        let memory = makeMemory(store: store, botID: "main")
        let page = try await memory.recallPage("重复", limit: 2, scope: .agent)
        XCTAssertEqual(page.hits.count, 2)
        XCTAssertEqual(page.total, 6)
    }
}
