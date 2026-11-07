// SPDX-License-Identifier: MIT

import Foundation
import XCTest

/// R7: the production Bot page must never fall back to fixture data. The
/// fixture fixtures themselves are only compiled in `#if DEBUG` builds and are
/// reachable from previews or the `scripts/ci/bot-ui` capture target, never
/// from the App's Bot page.
final class BotFixtureIsolationTests: XCTestCase {
    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Rows
            .deletingLastPathComponent()   // PhoneDSHBotTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot().appendingPathComponent(relativePath),
                   encoding: .utf8)
    }

    func testProductionBotPageHasNoFixtureFallback() throws {
        for path in [
            "examples/probe-app/PhoneDSHProbe/Bot/BotProductionPage.swift",
            "examples/probe-app/PhoneDSHProbe/Bot/BotProductionUIAdapters.swift",
            "examples/probe-app/PhoneDSHProbe/ChatModel.swift",
        ] {
            let text = try source(path)
            XCTAssertFalse(text.contains("BotUIFixture"), "\(path) must not reach fixture data")
            XCTAssertFalse(text.contains("BotFixtures"), "\(path) must not reach fixture data")
            XCTAssertFalse(text.contains("fixtureActions: true"), "\(path) must not fabricate actions")
        }

        let page = try source("examples/probe-app/PhoneDSHProbe/Bot/BotProductionPage.swift")
        // Runtime unavailable is a visible error with a retry, nothing else.
        XCTAssertTrue(page.contains("Button(\"重试\")"))
        XCTAssertTrue(page.contains("BotFailureRow"))
        XCTAssertFalse(page.contains("BotProductionHub.fixture"))
    }

    func testFixturesAreDebugOnly() throws {
        let path = "examples/probe-app/PhoneDSHProbe/Bot/BotFixtures.swift"
        let text = try source(path)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
        XCTAssertEqual(lines.first, "#if DEBUG", "\(path) must be compiled only in DEBUG")
        XCTAssertEqual(lines.last, "#endif")
        // The capture target still needs the fixture types; it builds Debug.
        XCTAssertTrue(text.contains("struct BotUIFixtureRootView"))
        XCTAssertTrue(text.contains("enum BotUIFixtureChecks"))
    }
}
