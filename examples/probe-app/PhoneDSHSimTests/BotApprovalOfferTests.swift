// SPDX-License-Identifier: MIT

import XCTest

/// The approval card must only offer a standing answer when the durable row
/// says a standing grant is possible, and the settled receipt must describe
/// the grant the user really received.
///
/// Regression for the real-device card that still offered「总是允许」/
/// 「本次对话都允许」 for a destructive or unclassified approval: since
/// `b2dadbcb9` the coordinator can only create a consumed once grant for those
/// (`BotApprovalCoordinator.resolve`), and `alwaysScope = "none"` says so.
/// `BotWorkCardView` renders from these rules and `BotChatModel.decide` sends
/// their decision, so the pure rules carry the contract.
final class BotApprovalOfferTests: XCTestCase {
    // MARK: - What the pending card may offer

    func testNoneScopeOffersNoStandingControl() {
        XCTAssertNil(BotApprovalOffer.standingScope("none"),
                     "alwaysScope=none must not render a standing control")
    }

    func testAbsentScopeOffersNoStandingControl() {
        // The projection does not guarantee `alwaysScope` on every approval
        // row (DSH tool/call rows carry only RequestApproval arguments, legacy
        // payloads predate the field), so absence must never invent a scope.
        XCTAssertNil(BotApprovalOffer.standingScope(nil),
                     "an absent alwaysScope must behave exactly like none")
        XCTAssertNil(BotApprovalOffer.standingScope(""))
        XCTAssertNil(BotApprovalOffer.standingScope("   "))
        XCTAssertNil(BotApprovalOffer.standingScope("once"))
        XCTAssertNil(BotApprovalOffer.standingScope("forever"),
                     "an unknown scope must not become a standing control")
    }

    func testSessionAndUntilOfferTheMatchingStandingControl() {
        let session = BotApprovalOffer.standingScope("session")
        XCTAssertEqual(session, BotApprovalOffer.Standing.session)
        XCTAssertEqual(session?.buttonTitle, "本次对话都允许")

        let until = BotApprovalOffer.standingScope("until")
        XCTAssertEqual(until, BotApprovalOffer.Standing.until)
        XCTAssertEqual(until?.buttonTitle, "总是允许")

        // The projection always writes lower-case values; normalising is a
        // defensive property, not a second vocabulary.
        XCTAssertEqual(BotApprovalOffer.standingScope(" SESSION "),
                       BotApprovalOffer.Standing.session)
    }

    func testOneShotCardExplainsWhyThereIsNoStandingAnswer() {
        XCTAssertFalse(BotApprovalOffer.onceOnlyNote.isEmpty)
        XCTAssertEqual(BotApprovalOffer.onceOnlyNote, "此类操作只能允许一次，下次会重新询问")
    }

    // MARK: - A stale `.always` request degrades to once

    func testAlwaysRequestOnNoneRowDegradesToAllowOnce() {
        XCTAssertEqual(BotApprovalOffer.effectiveDecision("always", alwaysScope: "none"),
                       "allowOnce")
        XCTAssertEqual(BotApprovalOffer.effectiveDecision("always", alwaysScope: nil),
                       "allowOnce")
        XCTAssertEqual(BotApprovalOffer.effectiveDecision("always", alwaysScope: "forever"),
                       "allowOnce")
    }

    func testAlwaysRequestOnStandingRowIsKept() {
        XCTAssertEqual(BotApprovalOffer.effectiveDecision("always", alwaysScope: "session"),
                       "always")
        XCTAssertEqual(BotApprovalOffer.effectiveDecision("always", alwaysScope: "until"),
                       "always")
    }

    func testNonAlwaysDecisionsAreNeverRewritten() {
        XCTAssertEqual(BotApprovalOffer.effectiveDecision("allowOnce", alwaysScope: "none"),
                       "allowOnce")
        XCTAssertEqual(BotApprovalOffer.effectiveDecision("deny", alwaysScope: "none"), "deny")
    }

    // MARK: - The settled receipt matches the grant

    func testOneShotDecisionNeverDisplaysAStandingReceipt() {
        // A forced once grant arrives as decision=always with scope=once.
        XCTAssertEqual(BotApprovalOffer.receiptLabel(status: "always", alwaysScope: "none",
                                                     effectiveScope: "once"),
                       "已允许一次")
        // A durable decided row may only carry alwaysScope; none means the
        // same thing as a consumed once grant.
        XCTAssertEqual(BotApprovalOffer.receiptLabel(status: "always", alwaysScope: "none",
                                                     effectiveScope: nil),
                       "已允许一次")
        // The effective scope from the tool result wins over the offer.
        XCTAssertEqual(BotApprovalOffer.receiptLabel(status: "always", alwaysScope: "until",
                                                     effectiveScope: "once"),
                       "已允许一次")
        XCTAssertEqual(BotApprovalOffer.receiptLabel(status: "always", alwaysScope: nil,
                                                     effectiveScope: "once"),
                       "已允许一次")
        // The row's own decision is authoritative: a `decision` that is not a
        // proven standing decision is the once grant it really was.
        XCTAssertEqual(BotApprovalOffer.receiptLabel(status: "always", alwaysScope: nil,
                                                     effectiveScope: nil, decision: "always"),
                       "已允许一次")
        XCTAssertEqual(BotApprovalOffer.receiptLabel(status: "always", alwaysScope: nil,
                                                     effectiveScope: nil, decision: "allowOnce"),
                       "已允许一次")
    }

    func testToolCallReceiptKeepsTheProjectsOwnAlwaysStatus() {
        // A DSH tool/call receipt row never carries `alwaysScope` (the
        // RequestApproval arguments have no such field) and its scope may only
        // exist in the tool result text. The projected `always` status is the
        // only standing evidence there, so it stays a standing receipt instead
        // of inventing a once grant.
        XCTAssertEqual(BotApprovalOffer.receiptLabel(status: "always", alwaysScope: nil,
                                                     effectiveScope: nil),
                       "已总是允许")
    }

    func testStandingReceiptsKeepTheirLabel() {
        XCTAssertEqual(BotApprovalOffer.receiptLabel(status: "always", alwaysScope: "until",
                                                     effectiveScope: nil),
                       "已总是允许")
        XCTAssertEqual(BotApprovalOffer.receiptLabel(status: "always", alwaysScope: "session",
                                                     effectiveScope: nil),
                       "本次对话都允许")
        XCTAssertEqual(BotApprovalOffer.receiptLabel(status: "always", alwaysScope: nil,
                                                     effectiveScope: "session"),
                       "本次对话都允许")
        XCTAssertEqual(BotApprovalOffer.receiptLabel(status: "allowed-session", alwaysScope: nil,
                                                     effectiveScope: "session"),
                       "本次对话都允许")
        XCTAssertEqual(BotApprovalOffer.receiptLabel(status: "allowed", alwaysScope: "until",
                                                     effectiveScope: "once"),
                       "已允许一次")
        XCTAssertEqual(BotApprovalOffer.receiptLabel(status: "denied", alwaysScope: "none",
                                                     effectiveScope: nil),
                       "已拒绝")
    }

    func testDurableDecidedRowKeepsTheDecisionItRecorded() {
        // `approval.decided` keeps status "allowed" and carries its own
        // `decision`; only a real standing decision may read as standing.
        XCTAssertEqual(BotApprovalOffer.receiptLabel(status: "allowed", alwaysScope: "session",
                                                     effectiveScope: nil, decision: "always"),
                       "本次对话都允许")
        XCTAssertEqual(BotApprovalOffer.receiptLabel(status: "allowed", alwaysScope: "until",
                                                     effectiveScope: nil, decision: "always"),
                       "已总是允许")
        // The forced once grant of a none-scope always decision.
        XCTAssertEqual(BotApprovalOffer.receiptLabel(status: "allowed", alwaysScope: "none",
                                                     effectiveScope: nil, decision: "always"),
                       "已允许一次")
        // allowOnce keeps its once receipt even when the card offered more.
        XCTAssertEqual(BotApprovalOffer.receiptLabel(status: "allowed", alwaysScope: "until",
                                                     effectiveScope: nil, decision: "allowOnce"),
                       "已允许一次")
    }
}
