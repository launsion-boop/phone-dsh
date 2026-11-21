// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// The pure P09 values a tapped question/steps card renders from. The page owns
/// the rows and the action state; these rules are shared by the card view, the
/// chat model and this test, so the pending copy, the refusal copy and the
/// optimistic-row rollback cannot fork.
final class BotChoiceCardUITests: XCTestCase {
    func testPendingTapShowsAVisibleStatus() {
        XCTAssertEqual(BotChoiceCardUI.statusLine(for: .pending), BotChoiceCardUI.pendingStatus)
        XCTAssertEqual(BotChoiceCardUI.pendingStatus, "正在送出…")
        XCTAssertNil(BotChoiceCardUI.statusLine(for: .idle),
                     "an untouched card shows no extra line")
        XCTAssertNil(BotChoiceCardUI.statusLine(for: .accepted),
                     "the durable answer's own settlement describes an accepted tap")
    }

    func testTappedChoiceProducesTheOptimisticLocalRow() throws {
        let echo = try XCTUnwrap(BotChoiceCardUI.echo(
            nonce: "6d1f0c9a7b3e", value: "library", label: "保存到文档库"))
        XCTAssertEqual(echo.rowID, "local-6d1f0c9a7b3e")
        XCTAssertEqual(echo.eventID, "local:6d1f0c9a7b3e")
        XCTAssertEqual(echo.text, "library",
                       "the echo reads like the durable user row, which carries the option value")
    }

    func testEchoFallsBackToTheLabelAndRejectsEmptyInput() throws {
        let labelled = try XCTUnwrap(BotChoiceCardUI.echo(nonce: "n1", value: " ", label: "稍后再说"))
        XCTAssertEqual(labelled.text, "稍后再说")
        XCTAssertNil(BotChoiceCardUI.echo(nonce: "", value: "library", label: "保存到文档库"))
        XCTAssertNil(BotChoiceCardUI.echo(nonce: "n2", value: "", label: ""))
    }

    func testFailureRollsTheOptimisticEchoBack() {
        XCTAssertEqual(BotChoiceCardUI.echoDisposition(for: .pending), .keep)
        XCTAssertEqual(BotChoiceCardUI.echoDisposition(for: .accepted), .keep,
                       "an accepted echo is retired by the durable user row, not by the view")
        XCTAssertEqual(BotChoiceCardUI.echoDisposition(for: .failed("card_expired")), .remove)
        XCTAssertEqual(BotChoiceCardUI.echoDisposition(for: .failed("turn_not_completed")), .remove)
        XCTAssertEqual(BotChoiceCardUI.echoDisposition(for: .idle), .keep)
    }

    func testRefusalReasonsMapToHumanCopy() {
        let expected = [
            "card_expired": "这张卡片已经过期，用最新那张",
            "already_answered": "已经选过了",
            "answer_in_flight": "正在送出，稍等",
            "unknown_card": "这张卡片已失效",
            "unknown_option": "这张卡片已失效",
        ]
        for (reason, copy) in expected {
            XCTAssertEqual(BotChoiceCardUI.refusalText(reason), copy, reason)
            XCTAssertEqual(BotChoiceCardUI.failureText(reason), copy,
                           "a refusal is shown as its human sentence, not as 未能送出")
            XCTAssertFalse(BotChoiceCardUI.failureText(reason).contains(reason),
                           "\(reason): the raw code must never reach the screen")
        }
    }

    func testNonRefusalFailureKeepsTheSendFailureForm() {
        XCTAssertNil(BotChoiceCardUI.refusalText("turn_not_completed"))
        XCTAssertEqual(BotChoiceCardUI.failureText("turn_not_completed"), "未能送出：turn_not_completed")
        XCTAssertEqual(BotChoiceCardUI.statusLine(for: .failed("card_expired")),
                       "这张卡片已经过期，用最新那张")
    }

    func testRefusalLookupTrimsTheReason() {
        XCTAssertEqual(BotChoiceCardUI.refusalText(" card_expired\n"), "这张卡片已经过期，用最新那张")
    }

    func testSupersededSettlementCopy() {
        XCTAssertEqual(BotChoiceCardUI.supersededTitle, "已过期，用最新那张")
        XCTAssertTrue(BotChoiceCardUI.refusalText("card_expired")?.contains("过期") == true,
                      "the settled line and a refused tap both name the staleness")
    }
}
