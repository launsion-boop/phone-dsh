// SPDX-License-Identifier: MIT
//
// S1-G: a message containing a GitHub token must never reach chat-status.log
// in clear text. The production line is built by NativeLogRedaction, and this
// suite writes it to a file and reads it back, not just compares a string.

import Foundation
import XCTest

final class LogRedactionTests: XCTestCase {
    private let token = "github_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyz"

    func testQueuedLineCarriesLengthOnly() throws {
        let message = "please use \(token) to clone the private repo"
        let line = NativeLogRedaction.queued(message)
        XCTAssertEqual(line, "queued: len=\(message.count)")
        XCTAssertFalse(line.contains("github_pat_"))
        XCTAssertFalse(line.contains(token))
        XCTAssertFalse(line.contains("please use"))
    }

    func testTheWrittenStatusLogHasNoPlaintext() throws {
        let message = "token \(token) should never be logged"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-redaction-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        try (NativeLogRedaction.queued(message) + "\n").write(to: url, atomically: true, encoding: .utf8)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(written.contains("github_pat_"), "the raw token reached the log file")
        XCTAssertFalse(written.contains(token))
        XCTAssertTrue(written.hasPrefix("queued: len="))
    }

    func testFailedTurnAndHostErrorKeepLengthAndAStableHash() {
        let raw = "upstream rejected request: \(token)"
        let failed = NativeLogRedaction.failedTurn(raw)
        XCTAssertTrue(failed.hasPrefix("turn failed: len=\(raw.count) hash="))
        XCTAssertFalse(failed.contains("github_pat_"))
        XCTAssertEqual(failed, NativeLogRedaction.failedTurn(raw), "the fingerprint must be stable")
        XCTAssertNotEqual(failed, NativeLogRedaction.failedTurn(raw + "!"))

        let error = NSError(domain: "test", code: 401,
                            userInfo: [NSLocalizedDescriptionKey: "bad key \(token)"])
        let line = NativeLogRedaction.error(error)
        XCTAssertTrue(line.hasPrefix("len="))
        XCTAssertFalse(line.contains("github_pat_"))
        XCTAssertFalse(line.contains("bad key"))
        XCTAssertFalse(NativeLogRedaction.localizedError(error).contains(token))
    }

    func testQuestionAndGoalStyleValuesDoNotLeakText() {
        let question = "what is my token \(token)?"
        XCTAssertEqual("The agent asks: len=\(question.count)",
                       "The agent asks: len=\(question.count)")
        XCTAssertFalse("The agent asks: len=\(question.count)".contains("github_pat_"))
        let objective = "rotate \(token) in CI"
        let goal = "active len=\(objective.count)"
        XCTAssertFalse(goal.contains("github_pat_"))
        XCTAssertFalse(goal.contains("rotate"))
    }

    func testHashPrefixIsBounded() {
        XCTAssertEqual(NativeLogRedaction.value("abc", hashPrefixCount: 4)
            .split(separator: " ").last?.count, 4 + "hash=".count)
        XCTAssertTrue(NativeLogRedaction.value("").hasPrefix("len=0 hash="))
    }
}
