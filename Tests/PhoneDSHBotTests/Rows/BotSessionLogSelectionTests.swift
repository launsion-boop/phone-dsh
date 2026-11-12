// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// F3: the row projection must follow the current main-session epoch. The App
/// caches a log URL for the connected session; after `switchMainSessionForErasure`
/// that cache belongs to the archived epoch and must not win over the current
/// session's own newest log.
final class BotSessionLogSelectionTests: XCTestCase {
    private func url(_ sessionID: String) -> URL {
        URL(fileURLWithPath: "/tmp/materialized/home/sessions/\(sessionID)/session.v4.jsonl")
    }

    func testAStaleEpochCacheDoesNotWinOverTheCurrentSessionLog() {
        let selected = BotSessionLogSelection.logURL(
            sessionID: "gb-main-new",
            explicit: url("gb-main-old"),
            latest: { sessionID in sessionID == "gb-main-new" ? self.url("gb-main-new") : self.url("gb-main-old") })
        XCTAssertEqual(selected, url("gb-main-new"))
    }

    func testMatchingExplicitLogStillWins() {
        let selected = BotSessionLogSelection.logURL(
            sessionID: "gb-main-new",
            explicit: url("gb-main-new"),
            latest: { _ in self.url("gb-main-new-later") })
        XCTAssertEqual(selected, url("gb-main-new"))
    }

    func testMissingExplicitLogFallsBackToTheCurrentSession() {
        let selected = BotSessionLogSelection.logURL(
            sessionID: "gb-main-new", explicit: nil,
            latest: { sessionID in sessionID == "gb-main-new" ? self.url("gb-main-new") : nil })
        XCTAssertEqual(selected, url("gb-main-new"))
    }

    func testAStagingExplicitLogOutsideSessionsIsKept() {
        let staged = URL(fileURLWithPath: "/tmp/staged/session.v4.jsonl")
        let selected = BotSessionLogSelection.logURL(
            sessionID: "main", explicit: staged,
            latest: { _ in self.url("unused") })
        XCTAssertEqual(selected, staged)
    }
}
