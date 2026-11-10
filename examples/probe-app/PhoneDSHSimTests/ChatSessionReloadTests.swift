// SPDX-License-Identifier: MIT

import Foundation
import ProbeKit
import XCTest

/// S1: after a park interrupted the first history load, the App re-opens the
/// session instead of leaving it "open but empty" until a manual switch.
/// These are the pure trigger rules behind `ChatModel`'s reload task.
final class ChatSessionReloadTests: XCTestCase {
    func testResumeNeedsReloadOnlyForAnOpenSessionWithoutTranscript() {
        XCTAssertTrue(ChatSessionReload.needsReloadAfterResume(
            sessionID: "session-1",
            transcriptReady: false,
            parked: false,
            hostLifecycleTransition: false))

        XCTAssertFalse(ChatSessionReload.needsReloadAfterResume(
            sessionID: nil,
            transcriptReady: false,
            parked: false,
            hostLifecycleTransition: false),
            "no session was adopted; there is nothing to re-open")
        XCTAssertFalse(ChatSessionReload.needsReloadAfterResume(
            sessionID: "session-1",
            transcriptReady: true,
            parked: false,
            hostLifecycleTransition: false),
            "a transcript that is already loaded must not be reloaded")
    }

    func testResumeDoesNotReloadDuringAParkOrHostTransition() {
        XCTAssertFalse(ChatSessionReload.needsReloadAfterResume(
            sessionID: "session-1",
            transcriptReady: false,
            parked: true,
            hostLifecycleTransition: false))
        XCTAssertFalse(ChatSessionReload.needsReloadAfterResume(
            sessionID: "session-1",
            transcriptReady: false,
            parked: false,
            hostLifecycleTransition: true),
            "the resume trigger runs after the transition flag is released")
    }

    func testRetryStopsAtTheAutomaticRetryLimit() {
        for retriesUsed in 0..<ChatSessionReload.maximumAutomaticRetries {
            XCTAssertTrue(ChatSessionReload.canRetryAfterFailure(
                retriesUsed: retriesUsed,
                appIsActive: true,
                sessionID: "session-1",
                transcriptReady: false,
                parked: false,
                hostLifecycleTransition: false),
                "retry \(retriesUsed + 1) of \(ChatSessionReload.maximumAutomaticRetries) is allowed")
        }
        XCTAssertFalse(ChatSessionReload.canRetryAfterFailure(
            retriesUsed: ChatSessionReload.maximumAutomaticRetries,
            appIsActive: true,
            sessionID: "session-1",
            transcriptReady: false,
            parked: false,
            hostLifecycleTransition: false),
            "the initial attempt plus the two automatic retries is the cap")
        XCTAssertEqual(ChatSessionReload.maximumAutomaticRetries, 2)
    }

    func testRetryRequiresForegroundAndAnIdleLifecycle() {
        XCTAssertFalse(ChatSessionReload.canRetryAfterFailure(
            retriesUsed: 0,
            appIsActive: false,
            sessionID: "session-1",
            transcriptReady: false,
            parked: false,
            hostLifecycleTransition: false),
            "a backgrounded App leaves the next attempt to the resume trigger")
        XCTAssertFalse(ChatSessionReload.canRetryAfterFailure(
            retriesUsed: 0,
            appIsActive: true,
            sessionID: "session-1",
            transcriptReady: false,
            parked: true,
            hostLifecycleTransition: false))
        XCTAssertFalse(ChatSessionReload.canRetryAfterFailure(
            retriesUsed: 0,
            appIsActive: true,
            sessionID: "session-1",
            transcriptReady: false,
            parked: false,
            hostLifecycleTransition: true))
        XCTAssertFalse(ChatSessionReload.canRetryAfterFailure(
            retriesUsed: 0,
            appIsActive: true,
            sessionID: "session-1",
            transcriptReady: true,
            parked: false,
            hostLifecycleTransition: false),
            "another path already restored the transcript")
    }

    func testReloadAbandonsWhenTheSessionChanged() {
        XCTAssertFalse(ChatSessionReload.shouldAbandonReload(
            initiatingSessionID: "session-1", currentSessionID: "session-1"))
        XCTAssertTrue(ChatSessionReload.shouldAbandonReload(
            initiatingSessionID: "session-1", currentSessionID: "session-2"),
            "a manual switch during the reload wins")
        XCTAssertTrue(ChatSessionReload.shouldAbandonReload(
            initiatingSessionID: "session-1", currentSessionID: nil),
            "a stopped/detached session has no reload target")
        XCTAssertTrue(ChatSessionReload.shouldAbandonReload(
            initiatingSessionID: nil, currentSessionID: "session-1"),
            "a reload without a captured session is never valid")
    }

    func testRetryDelayIsShortEnoughForForegroundRecovery() {
        XCTAssertEqual(ChatSessionReload.retryDelay, 1.5, accuracy: 0.000_001)
    }
}
