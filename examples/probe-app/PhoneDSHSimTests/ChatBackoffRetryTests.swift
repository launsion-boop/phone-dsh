// SPDX-License-Identifier: MIT

import Foundation
import ProbeKit
import XCTest

/// S1: a persisted D24 backoff window is a wait, not a failed engine. The
/// decision is pure so the App's scheduling rules are testable without a host.
final class ChatBackoffRetryTests: XCTestCase {
    func testNearDeadlineRetriesJustAfterTheDeadline() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let decision = ChatBackoffRetry.decision(
            deadline: now.addingTimeInterval(1.2), now: now, attempts: 0)

        guard case .retry(let delay, let attempt) = decision else {
            return XCTFail("a near deadline must retry: \(decision)")
        }
        XCTAssertEqual(delay, 1.5, accuracy: 0.000_001,
                       "the retry wakes at the deadline plus the 0.3 s margin")
        XCTAssertEqual(attempt, 1)
    }

    func testDeadlineAtTheAutomaticLimitStillRetries() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let decision = ChatBackoffRetry.decision(
            deadline: now.addingTimeInterval(ChatBackoffRetry.maximumAutomaticDelay),
            now: now, attempts: 2)

        guard case .retry(let delay, let attempt) = decision else {
            return XCTFail("exactly 60 s is still automatic: \(decision)")
        }
        XCTAssertEqual(delay, 60.3, accuracy: 0.000_001)
        XCTAssertEqual(attempt, 3)
    }

    func testFarDeadlineOnlyShowsTheHint() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let decision = ChatBackoffRetry.decision(
            deadline: now.addingTimeInterval(61), now: now, attempts: 0)

        guard case .waitForManualStart(let remaining) = decision else {
            return XCTFail("a far deadline must keep the manual start path: \(decision)")
        }
        XCTAssertEqual(remaining, 61, accuracy: 0.000_001)
    }

    func testRetryStopsAfterTheMaximumAttempts() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let decision = ChatBackoffRetry.decision(
            deadline: now.addingTimeInterval(1), now: now,
            attempts: ChatBackoffRetry.maximumAttempts)

        XCTAssertEqual(decision, .exhausted(attempts: ChatBackoffRetry.maximumAttempts))
    }

    func testEachRetryAdvancesTheAttemptCounter() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        for attempts in 0..<ChatBackoffRetry.maximumAttempts {
            let decision = ChatBackoffRetry.decision(
                deadline: now.addingTimeInterval(0.5), now: now, attempts: attempts)
            guard case .retry(_, let attempt) = decision else {
                return XCTFail("attempt \(attempts) must retry: \(decision)")
            }
            XCTAssertEqual(attempt, attempts + 1)
        }
    }
}
