// SPDX-License-Identifier: MIT
// The "引擎停了" top line is the empty state's duplicate: hide it while the
// no-engine card already explains the same thing, keep it once a conversation
// is on screen, and never swallow a different failure.

import XCTest

final class ChatEngineStoppedNoticePolicyTests: XCTestCase {
    func testEngineStoppedLineIsHiddenBehindTheNoEngineEmptyState() {
        XCTAssertFalse(ChatEngineStoppedNoticePolicy.shouldShow(
            message: "引擎停了", engineEmptyStateVisible: true))
        XCTAssertFalse(ChatEngineStoppedNoticePolicy.shouldShow(
            message: "引擎停了：host start failed", engineEmptyStateVisible: true))
    }

    func testEngineStoppedLineSurvivesMidSessionOrWithoutTheEmptyState() {
        XCTAssertTrue(ChatEngineStoppedNoticePolicy.shouldShow(
            message: "引擎停了", engineEmptyStateVisible: false))
        XCTAssertTrue(ChatEngineStoppedNoticePolicy.shouldShow(
            message: "引擎停了：timeout", engineEmptyStateVisible: false))
    }

    func testOtherFailuresKeepTheirBanner() {
        XCTAssertTrue(ChatEngineStoppedNoticePolicy.shouldShow(
            message: "没发出去", engineEmptyStateVisible: true))
        XCTAssertFalse(ChatEngineStoppedNoticePolicy.isEngineStoppedMessage("无法打开会话"))
        XCTAssertFalse(ChatEngineStoppedNoticePolicy.isEngineStoppedMessage("引擎启动失败"))
    }
}
