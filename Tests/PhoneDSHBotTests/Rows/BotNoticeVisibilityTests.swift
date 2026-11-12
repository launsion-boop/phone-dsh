// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotNoticeVisibilityTests: XCTestCase {
    func testInfoContinuationNoticeIsVisible() {
        XCTAssertTrue(BotNoticeVisibility.isVisible(
            tone: "info",
            text: "已抹除的内容已从旧会话日志移除；对话已接续到新会话，未抹除的内容仍然可用。"))
    }

    func testErrorAndDenialNoticesStayVisible() {
        XCTAssertTrue(BotNoticeVisibility.isVisible(tone: "error", text: "回合失败"))
        XCTAssertTrue(BotNoticeVisibility.isVisible(tone: "denial", text: "这次请求没有获得允许。"))
    }

    func testEmptyNoticeIsHidden() {
        XCTAssertFalse(BotNoticeVisibility.isVisible(tone: "info", text: "  \n"))
        XCTAssertFalse(BotNoticeVisibility.isVisible(tone: nil, text: ""))
    }
}
