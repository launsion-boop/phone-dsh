// SPDX-License-Identifier: MIT

import XCTest

final class BotCaptureUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ fixture: String, dynamicType: Bool = false) {
        app.terminate()
        app.launchArguments = [
            "-BotUIFixture", fixture,
            "-BotUIAppearance", "light",
            "-BotUIDiagnostics",
        ]
        if dynamicType {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
    }

    private var actionLog: String {
        let element = app.descendants(matching: .any)["bot.fixture.actions"]
        XCTAssertTrue(element.waitForExistence(timeout: 3))
        return element.label
    }

    private func assertCount(_ token: String, _ expected: Int, file: StaticString = #filePath, line: UInt = #line) {
        let count = actionLog.components(separatedBy: token).count - 1
        XCTAssertEqual(count, expected, "action log: \(actionLog)", file: file, line: line)
    }

    /// Scrolls a lazy `List` until `element` exists and is tappable. The info
    /// page shows 外观 above 数据, so 数据 rows start below the fold on the
    /// capture device; reaching them by scrolling is part of the interaction,
    /// not a relaxed assertion.
    private func scrollTo(_ element: XCUIElement, maxSwipes: Int = 6) {
        for _ in 0..<maxSwipes {
            if element.exists && element.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 3))
    }

    private func scrollToAndTap(_ element: XCUIElement, maxSwipes: Int = 6) {
        scrollTo(element, maxSwipes: maxSwipes)
        element.tap()
    }

    func testQuestionAnswerLocksAndHasNoCustomInput() throws {
        launch("question")
        let option = app.buttons["bot.choice.option.library"]
        XCTAssertTrue(option.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(option.frame.height, 44 - 0.01)
        option.tap()
        option.tap()
        usleep(300_000)
        assertCount("cardAnswer", 1)
        XCTAssertTrue(app.staticTexts["已送出"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.textFields["bot.choice.custom"].exists)
        XCTAssertFalse(app.buttons["bot.choice.custom.send"].exists)
    }

    func testChecklistToggleAndSendBack() throws {
        launch("checklist")
        app.buttons["bot.checklist.item.c2"].tap()
        app.buttons["bot.checklist.send"].tap()
        usleep(300_000)
        assertCount("chat", 1)
        XCTAssertFalse(app.buttons["bot.checklist.send"].isEnabled)
    }

    func testApprovalDecisionAndAlwaysScopeNone() throws {
        launch("approval")
        let once = app.buttons["bot.approval.once"]
        XCTAssertTrue(once.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(once.frame.height, 44 - 0.01)
        XCTAssertTrue(app.buttons["bot.approval.always"].exists)
        XCTAssertTrue(app.buttons["bot.approval.deny"].exists)
        once.tap()
        usleep(300_000)
        assertCount("approval:allowOnce", 1)
        XCTAssertFalse(app.buttons["bot.approval.once"].exists)

        launch("overflow")
        let always = app.buttons["bot.approval.always"]
        XCTAssertFalse(always.exists)
        XCTAssertTrue(app.buttons["bot.approval.deny"].waitForExistence(timeout: 3))
    }

    func testSteeringAndStopRemainIndependent() throws {
        launch("chat")
        let input = app.textFields["bot.composer.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 3))
        input.tap()
        input.typeText("第一条 steering")
        app.buttons["bot.composer.send"].tap()
        input.tap()
        input.typeText("第二条 steering")
        app.buttons["bot.composer.send"].tap()
        usleep(300_000)
        assertCount("chat", 2)
        app.buttons["bot.composer.stop"].tap()
        usleep(200_000)
        assertCount("stop:fixture-turn", 1)
        XCTAssertFalse(app.buttons["bot.composer.stop"].exists)
    }

    func testDocumentAndSafeLinkActions() throws {
        launch("document")
        app.buttons["bot.document.open"].tap()
        XCTAssertTrue(app.navigationBars["文档"].waitForExistence(timeout: 2))

        launch("link")
        app.buttons["bot.link.open.docs"].tap()
        usleep(200_000)
        assertCount("url:https://example.test/docs/cards", 1)
    }

    func testFailClosedAndNoSessionManagement() throws {
        launch("failClosed")
        let visible = app.descendants(matching: .any)["bot.fixture.visible"]
        XCTAssertTrue(visible.waitForExistence(timeout: 3))
        XCTAssertEqual(visible.label, "visible=0;attention=0")
        XCTAssertFalse(app.staticTexts["不应显示"].exists)
        XCTAssertFalse(app.buttons["新建对话"].exists)
        XCTAssertFalse(app.buttons["对话列表"].exists)
    }

    func testOverflowAtAccessibilityDynamicType() throws {
        launch("overflow", dynamicType: true)
        let title = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "故意很长")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        let headingExpand = app.buttons.matching(identifier: "bot.card.heading.expand").firstMatch
        XCTAssertTrue(headingExpand.waitForExistence(timeout: 3))
        headingExpand.tap()
        XCTAssertTrue(app.buttons["bot.progress.more"].exists)
        app.buttons["bot.progress.more"].tap()
        XCTAssertTrue(app.buttons["bot.progress.more"].exists)
        app.swipeUp()
        XCTAssertTrue(app.buttons["bot.approval.deny"].waitForExistence(timeout: 2))
    }

    func testTaskAttachmentAndLongPressSource() throws {
        launch("task")
        let toggle = app.buttons["bot.task.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(toggle.frame.height, 44 - 0.01)
        toggle.tap()
        XCTAssertTrue(app.staticTexts["收集来源"].waitForExistence(timeout: 2))

        launch("attachment")
        let open = app.buttons["bot.attachment.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(open.frame.height, 44 - 0.01)
        open.tap()
        usleep(200_000)
        assertCount("path:/tmp/phone-dsh-report.pdf", 1)

        launch("question")
        let message = app.staticTexts["Fixture：question"]
        XCTAssertTrue(message.waitForExistence(timeout: 3))
        message.press(forDuration: 1.2)
        app.buttons["查看来源"].tap()
        XCTAssertTrue(app.navigationBars["消息来源"].waitForExistence(timeout: 2))
    }

    func testInfoEmptyAndFailureAreDistinct() throws {
        launch("infoEmpty")
        // The fixture opens the real memory subpage so the empty state is on
        // screen, not the unchanged info-page top.
        XCTAssertTrue(app.staticTexts["还没有已保存的记忆。"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["读取失败"].exists)

        launch("infoError")
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "这不代表没有记忆")
        ).firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["bot.retry"].exists)
    }

    func testInfoApprovalsAndMemoryDocumentEvidence() throws {
        launch("infoApprovals")
        XCTAssertTrue(app.navigationBars["审批记录"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["已超时（视为拒绝）"].exists)
        XCTAssertTrue(app.staticTexts["本次会话允许"].exists)

        launch("infoMemoryDocument")
        // The document detail's navigation title is the file name; the full
        // path stays visible in the body footer.
        XCTAssertTrue(app.navigationBars["acceptance.md"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["路径：agent/notes/acceptance.md"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "验收记录")
        ).firstMatch.exists)
    }

    // MARK: - Unauthorized tool turn

    /// The incident's two rejected same-name calls. The collapsed rows must
    /// carry the human failure + action, not the wire error, and both rows
    /// must be unique (``ForEach`` ids).
    func testUnauthorizedToolRowsAreHumanAndUnique() throws {
        launch("runningToolReplay")
        let rows = app.descendants(matching: .any).matching(identifier: "bot.tool.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 2, "the replayed call must not create a third row")
        for index in 0..<rows.count {
            let label = rows.element(boundBy: index).label
            XCTAssertTrue(label.contains("处理失败"), "row label: \(label)")
            XCTAssertTrue(label.contains("与 App 的连接已失效"), "row label: \(label)")
            XCTAssertFalse(label.contains("unauthorized"), "wire error leaked: \(label)")
            XCTAssertFalse(label.contains("identity-bridge"), "wire error leaked: \(label)")
        }
    }

    /// A progress card is shown while the turn (and its header/activity
    /// motion) is still running. XCUITest must be able to query and tap it;
    /// otherwise the page is stuck in layout or never idles.
    func testProgressCardDuringRunningTurnKeepsSnapshotsAvailable() throws {
        launch("runningProgress")
        let more = app.buttons["bot.progress.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        let title = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "生成发布验收材料")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        more.tap()
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["约 2 分钟"].exists
                      || app.staticTexts.matching(
                        NSPredicate(format: "label CONTAINS %@", "约 2 分钟")).firstMatch.exists)
    }

    /// A lost live `turn/end` must not pin the live tool group forever. The
    /// 800ms durable watch is authoritative; once it carries the answer the
    /// stop control and tool-running activity go away.
    func testLostTurnEndSettlesToDurableRows() throws {
        launch("runningToolUnauthorized")
        let runtime = app.descendants(matching: .any)["bot.fixture.runtime"]
        XCTAssertTrue(runtime.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 8) { runtime.label.contains("running=none") },
                      "live turn did not settle: \(runtime.label)")
        XCTAssertFalse(app.buttons["bot.composer.stop"].exists)
        let process = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "已完成")).firstMatch
        XCTAssertTrue(process.waitForExistence(timeout: 4))
        process.tap()
        let rows = app.descendants(matching: .any).matching(identifier: "bot.tool.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(rows.count, 2)
    }

    // MARK: - Bot drawer

    private func drawerRow(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }

    /// The SwiftUI panel is exposed as a ScrollView, not an Other element, so
    /// match the identifier across element types.
    private func drawerPanel() -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "bot.drawer.panel").firstMatch
    }

    /// A closed drawer keeps its elements in the tree, offset offscreen. The
    /// real closed condition is therefore "not hittable" (and, when it still
    /// exists, a frame wholly left of the screen), never "does not exist".
    private func assertDrawerClosed(_ element: XCUIElement, timeout: TimeInterval = 2,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let closed = waitUntil(timeout: timeout) {
            !element.exists || !element.isHittable || element.frame.maxX <= 0.01
        }
        XCTAssertTrue(closed, "drawer element is still open: \(element)", file: file, line: line)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    func testBotDrawerOpenSelectAndClose() throws {
        launch("drawer")
        let panel = drawerPanel()
        XCTAssertTrue(panel.waitForExistence(timeout: 4))
        panel.swipeLeft()
        assertDrawerClosed(drawerRow("大肥鱼"))
        assertDrawerClosed(panel)

        let open = app.buttons["bot.drawer.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 2))
        open.tap()
        let second = drawerRow("小海")
        XCTAssertTrue(second.waitForExistence(timeout: 2))
        second.tap()
        assertDrawerClosed(second)
        assertDrawerClosed(panel)
        XCTAssertTrue(app.staticTexts["小海"].waitForExistence(timeout: 2))
    }

    func testBotAddValidatesAndCreates() throws {
        launch("drawerAdd")
        let field = app.textFields["bot.add.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        let create = app.buttons["bot.add.create"]

        // The dialog opens empty: 创建 is disabled and no validation/count text
        // is rendered below the field.
        XCTAssertFalse(create.isEnabled)
        XCTAssertFalse(app.staticTexts["bot.add.name.hint"].exists)
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "不能为空", "最多")
        ).firstMatch.exists)

        // Typing past the limit is capped in the field binding: 61 UTF-16
        // units become 60, so 创建 stays enabled and no hint appears.
        let capped = String(repeating: "长", count: 60)
        field.tap()
        field.typeText(String(repeating: "长", count: 61))
        XCTAssertTrue(waitUntil(timeout: 3) { (field.value as? String) == capped })
        XCTAssertTrue(waitUntil(timeout: 2) { create.isEnabled })
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "最多")
        ).firstMatch.exists)

        // Clear, enter a real name, create, and confirm the header switched.
        let clear = app.buttons["bot.add.name.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 2))
        clear.tap()
        XCTAssertTrue(waitUntil(timeout: 2) { !create.isEnabled })
        field.tap()
        field.typeText("小舟")
        XCTAssertTrue(waitUntil(timeout: 2) { create.isEnabled })
        create.tap()

        XCTAssertTrue(app.staticTexts["小舟"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["bot.drawer.add"].waitForExistence(timeout: 1))
    }

    func testBotManageShowsHiddenBot() throws {
        launch("drawerManage")
        let hidden = app.staticTexts["夜航"]
        XCTAssertTrue(hidden.waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["已隐藏"].exists)
    }
}
