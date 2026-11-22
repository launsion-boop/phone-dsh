// SPDX-License-Identifier: MIT

import PhoneDSHAgentCore
import XCTest

/// Real-device regression: the phone remembered a DSH session the engine no longer had, so every
/// boot failed with 「会话打开失败：invalidRequest("session_not_found")」 and Bot sends stayed
/// 「待发送，引擎就绪后自动发出」 forever. Only that exact case falls back to a fresh session.
final class ChatSessionBootTests: XCTestCase {
    func testMissingRememberedSessionFallsBack() {
        XCTAssertTrue(ChatSessionBoot.isMissingRememberedSession(
            ProviderError.invalidRequest("session_not_found"), requested: "s-1"))
    }

    func testTheRealRemoteNotFoundCodesMapToTheFallback() {
        let error = DSHRemoteError(code: "session/not-found", message: "no such session").providerError
        XCTAssertTrue(ChatSessionBoot.isMissingRememberedSession(error, requested: "s-1"))
    }

    func testAFreshSessionRequestNeverFallsBack() {
        XCTAssertFalse(ChatSessionBoot.isMissingRememberedSession(
            ProviderError.invalidRequest("session_not_found"), requested: nil))
    }

    func testOtherFailuresKeepTheBootError() {
        for error: Error in [ProviderError.unavailable(retryAfter: nil),
                             ProviderError.invalidRequest("session/conflict: busy"),
                             DSHRemoteError(code: "gateway/internal", message: "x").providerError,
                             CancellationError()] {
            XCTAssertFalse(ChatSessionBoot.isMissingRememberedSession(error, requested: "s-1"), "\(error)")
        }
    }
}
