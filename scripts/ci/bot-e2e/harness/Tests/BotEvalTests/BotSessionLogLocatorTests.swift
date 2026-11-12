// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import BotEvalApp
import PhoneDSHBot

/// The final-2 BotE2E regression: the composition wrote its session log into a
/// temporary workspace while the locator walked the process-global Documents
/// root, so `latestFile` returned nil. The environment must use the root it was
/// built with.
final class BotSessionLogLocatorTests: XCTestCase {
    func testEnvironmentFindsTheLogInItsOwningWorkspaceOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bot-session-env-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let directory = workspace.appendingPathComponent(
            "materialized/home/sessions/--dsh-workspace--/gb-main", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("session.v4.jsonl")
        try Data("{\"type\":\"turn/end\",\"seq\":1,\"time\":1,\"data\":{}}\n".utf8).write(to: log)

        let store = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"))
        let environment = BotProductionEnvironment(
            domain: store, botID: "main", sessionID: "gb-main",
            routineMachine: RoutineMachine(store: SQLiteRoutineStore(domainStore: store)),
            memory: BotMemory(
                store: SQLiteBotMemoryDocumentStore(eventLog: store, botID: "main"),
                botID: "main"),
            grants: BotGrantStore(domainStore: store),
            workspaceRoot: workspace)
        let snapshot = await environment.sessionSnapshot()
        XCTAssertEqual(snapshot.sessionID, "gb-main")
        XCTAssertEqual(snapshot.logURL?.standardizedFileURL, log.standardizedFileURL,
                       "the locator did not search the composition's workspace")

        let unrelated = root.appendingPathComponent("unrelated", isDirectory: true)
        let other = BotProductionEnvironment(
            domain: store, botID: "main", sessionID: "gb-main",
            routineMachine: RoutineMachine(store: SQLiteRoutineStore(domainStore: store)),
            memory: BotMemory(
                store: SQLiteBotMemoryDocumentStore(eventLog: store, botID: "main"),
                botID: "main"),
            grants: BotGrantStore(domainStore: store),
            workspaceRoot: unrelated)
        let otherSnapshot = await other.sessionSnapshot()
        XCTAssertNil(otherSnapshot.logURL,
                     "a different workspace must not borrow the session log")
        try await store.close()
    }
}
