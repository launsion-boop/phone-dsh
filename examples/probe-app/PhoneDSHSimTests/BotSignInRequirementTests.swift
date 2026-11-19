// SPDX-License-Identifier: MIT

import PhoneDSH
import XCTest

/// The Bot chat asks for a Tono sign-in only when the cloud profile really has no credential:
/// signed out and no stored key. Regression for the real-device case where a signed-out phone
/// let the user send and every turn ended as 「回合失败：no credential is configured…」.
final class BotSignInRequirementTests: XCTestCase {
    private let cloud = "https://pdsh.tonoai.cn/v1/llm/anthropic"

    func testSignedOutCloudWithoutKeyAsksToSignIn() {
        XCTAssertEqual(BotSignInRequirement.resolve(account: .signedOut(notice: nil), profileBaseURL: cloud, hasStoredKey: false),
                       .signIn(nil))
        XCTAssertEqual(BotSignInRequirement.resolve(account: .signedOut(notice: .sessionEnded), profileBaseURL: cloud, hasStoredKey: false),
                       .signIn(.sessionEnded))
        XCTAssertEqual(BotSignInRequirement.resolve(account: .signedOut(notice: .reverifyRequired), profileBaseURL: cloud, hasStoredKey: false),
                       .signIn(.reverifyRequired))
    }

    func testAnyWorkingCredentialHidesTheBanner() {
        XCTAssertEqual(BotSignInRequirement.resolve(signedIn: true, notice: nil, profileBaseURL: cloud, hasStoredKey: false), .none)
        XCTAssertEqual(BotSignInRequirement.resolve(account: .signedOut(notice: nil), profileBaseURL: cloud, hasStoredKey: true), .none)
    }

    func testOtherEndpointsNeverAskForTono() {
        for url in ["https://api.deepseek.com/anthropic", "http://pdsh.tonoai.cn/v1/llm/anthropic",
                    "https://pdsh.tonoai.cn:8443/v1/llm/anthropic", "not a url"] {
            XCTAssertEqual(BotSignInRequirement.resolve(account: .signedOut(notice: nil), profileBaseURL: url, hasStoredKey: false), .none, url)
        }
        XCTAssertEqual(BotSignInRequirement.resolve(account: .signedOut(notice: nil), profileBaseURL: nil, hasStoredKey: false), .none)
    }

    func testEveryBannerStateHasUserFacingText() {
        for notice in [nil, TonoAccountNotice.sessionEnded, .reverifyRequired] {
            let requirement = BotSignInRequirement.signIn(notice)
            XCTAssertFalse(requirement.title.isEmpty)
            XCTAssertFalse(requirement.detail.isEmpty)
            XCTAssertFalse(requirement.title.contains("credential"))
        }
    }
}
