// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import BotE2EApp

/// The locator must read the workspace the composition was built with. The
/// final-2 regression put the workspace in a temporary directory while the
/// locator walked the App's global Documents root and returned nil.
final class BotSessionLogLocatorTests: XCTestCase {
    func testLocatorSearchesTheOwningWorkspaceOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bot-session-locator-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let session = "gb-main"
        let directory = workspace
            .appendingPathComponent("materialized/home/sessions/--dsh-workspace--/\(session)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("session.v4.jsonl")
        try Data("{\"type\":\"turn/end\",\"seq\":1,\"time\":1,\"data\":{}}\n".utf8).write(to: log)

        let found = try XCTUnwrap(
            BotSessionLogLocator.latestFile(sessionID: session, workspaceRoot: workspace),
            "the locator did not search the composition's workspace")
        XCTAssertEqual(found.standardizedFileURL, log.standardizedFileURL)

        let unrelated = root.appendingPathComponent("unrelated", isDirectory: true)
        XCTAssertNil(BotSessionLogLocator.latestFile(sessionID: session,
                                                     workspaceRoot: unrelated),
                     "the locator must not fall back to another workspace")
    }
}
