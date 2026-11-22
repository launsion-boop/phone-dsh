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

/// The chat page and Settings label 「待配置模型服务」 (spec/v1/tono-account.md §4). Regression for the
/// real-device case where a phone signed in to Tono on the 「Tono 云端」 profile, with no stored key,
/// kept showing 「待配置模型服务」 although the cloud route uses the account token.
final class ModelProviderReadinessTests: XCTestCase {
    private let cloud = "https://pdsh.tonoai.cn/v1/llm/anthropic"
    private let other = "https://api.deepseek.com/anthropic"

    func testSignedInCloudProfileWithoutKeyIsReady() {
        XCTAssertFalse(ModelProviderReadiness.needsSetup(profileBaseURL: cloud, keyStatus: .missing, signedIn: true))
        XCTAssertFalse(ModelProviderReadiness.needsSetup(profileBaseURL: cloud, keyStatus: nil, signedIn: true))
    }

    func testSignedOutCloudProfileWithoutKeyNeedsSetup() {
        XCTAssertTrue(ModelProviderReadiness.needsSetup(profileBaseURL: cloud, keyStatus: .missing, signedIn: false))
    }

    func testAStoredKeyIsEnoughAnywhere() {
        XCTAssertFalse(ModelProviderReadiness.needsSetup(profileBaseURL: cloud, keyStatus: .present, signedIn: false))
        XCTAssertFalse(ModelProviderReadiness.needsSetup(profileBaseURL: other, keyStatus: .present, signedIn: false))
    }

    func testTheTonoSessionNeverStandsInForAnotherProvidersKey() {
        XCTAssertTrue(ModelProviderReadiness.needsSetup(profileBaseURL: other, keyStatus: .missing, signedIn: true))
        XCTAssertTrue(ModelProviderReadiness.needsSetup(profileBaseURL: other, keyStatus: .unreadable, signedIn: true))
        // Same host, another port or scheme is not the cloud origin.
        XCTAssertTrue(ModelProviderReadiness.needsSetup(profileBaseURL: "http://pdsh.tonoai.cn/v1/llm/anthropic",
                                                        keyStatus: .missing, signedIn: true))
    }

    func testNoSelectedProfileNeedsSetup() {
        XCTAssertTrue(ModelProviderReadiness.needsSetup(profileBaseURL: nil, keyStatus: nil, signedIn: true))
    }

    func testTheAccountStateMapsToSignedIn() {
        XCTAssertFalse(TonoAccountState.signedOut(notice: nil).isSignedIn)
        XCTAssertFalse(TonoAccountState.signedOut(notice: .sessionEnded).isSignedIn)
    }
}
