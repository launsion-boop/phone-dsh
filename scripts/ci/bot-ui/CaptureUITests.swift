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
        option.doubleTap()
        usleep(300_000)
        assertCount("cardAnswer", 1)
        let settled = app.descendants(matching: .any)["bot.card.settled"]
        XCTAssertTrue(settled.waitForExistence(timeout: 2))
        XCTAssertTrue(settled.label.hasPrefix("已选择"), settled.label)
        XCTAssertFalse(app.textFields["bot.choice.custom"].exists)
        XCTAssertFalse(app.buttons["bot.choice.custom.send"].exists)
    }

    func testChecklistToggleAndSendBack() throws {
        launch("checklist")
        app.buttons["bot.checklist.item.c2"].tap()
        app.buttons["bot.checklist.send"].tap()
        usleep(300_000)
        assertCount("chat", 1)
        // #132 collapses a handled interactive card into one settled line, so
        // the whole checklist form (including its send button) is gone. Query
        // the settled line and the absent button explicitly: reading
        // `isEnabled` on a non-existent element raises a snapshot error.
        let settled = app.descendants(matching: .any)["bot.card.settled"]
        XCTAssertTrue(settled.waitForExistence(timeout: 2))
        XCTAssertTrue(settled.label.hasPrefix("已发送勾选结果"), settled.label)
        XCTAssertFalse(app.buttons["bot.checklist.send"].exists)
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

    func testSendAfterCollapseKeepsMessageAboveComposer() throws {
        launch("sendCollapse")
        let input = app.textFields["bot.composer.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 3))
        input.tap()
        input.typeText("继续")
        app.buttons["bot.composer.send"].tap()
        usleep(1_500_000)

        // The send skips the unanswered question/steps cards and auto-denies
        // the pending approval, so at least one settled line must exist.
        let settled = app.descendants(matching: .any)
            .matching(identifier: "bot.card.settled")
        XCTAssertTrue(settled.firstMatch.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(settled.count, 1)

        // After the collapse shrinks the transcript, the newest user message
        // must still sit just above the composer instead of being pushed up
        // with a large blank area underneath.
        let bubble = app.staticTexts["继续"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(bubble.frame.maxY, input.frame.minY,
                                 "user bubble must stay above the composer")
        XCTAssertLessThanOrEqual(input.frame.minY - bubble.frame.maxY, 160,
                                 "no large blank gap below the newest message")
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
        let cancellationReason = app.staticTexts["原因：App 重启时取消"]
        scrollTo(cancellationReason)
        XCTAssertTrue(cancellationReason.exists)

        launch("infoMemoryDocument")
        // The document detail's navigation title is the file name; the full
        // path stays visible in the body footer.
        XCTAssertTrue(app.navigationBars["acceptance.md"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["路径：agent/notes/acceptance.md"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "验收记录")
        ).firstMatch.exists)
    }

    /// F5: a memory row is a `NavigationLink(value: BotMemoryDocumentInfo)`.
    /// The info page must use a type-erased path so the second value type is
    /// pushed; a typed `[BotInfoSection]` path only highlights the row.
    /// P09 bot-info §在场状态: the read-only connection line is human copy with
    /// a time; the host's internal failure code stays in the diagnostic log.
    func testInfoPresenceBridgeStatusIsHuman() throws {
        launch("infoPresence")
        let bridge = app.descendants(matching: .any)["bot.info.presence.bridge"]
        XCTAssertTrue(bridge.waitForExistence(timeout: 3))
        let label = bridge.label
        XCTAssertTrue(label.contains("最近一次与 App 的连接校验失败"), "bridge label: \(label)")
        for internalWord in ["unauthorized", "identity-bridge", "身份登记", "unknown_session"] {
            XCTAssertFalse(label.localizedCaseInsensitiveContains(internalWord),
                           "bridge label leaks \(internalWord): \(label)")
        }
        XCTAssertTrue(label.contains("月") && label.contains(":"), "bridge label has no local time: \(label)")
    }

    func testInfoMemoryDocumentRowPushesTheDetailPage() throws {
        launch("infoMemory")
        let row = app.descendants(matching: .any)["bot.memory.document.agent/profile.md"]
        scrollToAndTap(row)
        XCTAssertTrue(app.navigationBars["profile.md"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["路径：agent/profile.md"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "验收报告必须区分模拟器与真机证据")
        ).firstMatch.exists)
    }

    // MARK: - Unauthorized tool turn

    /// The incident's two rejected same-name calls after #126: the transcript
    /// has no process/tool rows at all, so the replayed call must not leak the
    /// wire error through a resurrected tool row. The live answer is shown
    /// once (the reattached observer replays the same seqs), in human words.
    func testUnauthorizedToolRowsAreHumanAndUnique() throws {
        launch("runningToolReplay")
        let answer = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "两次都没有连上 App")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 5), "human failure answer missing")
        XCTAssertEqual(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "两次都没有连上 App")).count, 1,
            "the replayed call must not create a second answer")
        // #126 removed transcript process rows; a replayed tool call must not
        // bring one back, and no wire-visible error may appear anywhere.
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: "bot.tool.row").firstMatch.exists,
            "a transcript tool row reappeared after #126")
        for leaked in ["unauthorized", "identity-bridge"] {
            XCTAssertFalse(app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", leaked)).firstMatch.exists,
                "wire error leaked into the transcript: \(leaked)")
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

    /// The F2/F3 incident history: long expandable headings, a checklist, a
    /// document and an attachment next to a progress card whose cardKey is
    /// updated in place. The fixture hands the model new ids for those
    /// updates; the transcript must keep the first id, and XCUITest must still
    /// resolve cards after the dense history has settled.
    func testDenseCardsAndInPlaceProgressKeepSnapshotsAvailable() throws {
        launch("chatLayoutStress")
        let ids = app.descendants(matching: .any)["bot.fixture.ids"]
        XCTAssertTrue(ids.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 8) {
            let label = ids.label
            return label.contains("layout-progress")
                && !label.contains("layout-progress-update")
                && !label.contains("layout-progress-final")
        }, "progress card id changed: \(ids.label)")
        let more = app.buttons["bot.progress.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "布局回归记录")
        ).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "bot.composer.input").firstMatch.exists)
    }

    /// P0 (2026-11-12): a keyboard-open turn with a question card, an
    /// approval card, a checklist, a progress card and long text. The field
    /// failure was the main thread looping in
    /// `LazySubviewPlacements.updateValue/placeSubviews`: XCUITest could read
    /// the element tree but the question option and approval button were
    /// `Not hittable`, while `bot.composer.input` timed out resolving
    /// snapshots. The cards must stay tappable and the composer must keep
    /// answering snapshots before and after each tap, with the keyboard up.
    func testKeyboardOpenDenseCardsStayHittableAndTappable() throws {
        launch("chatLayoutKeyboard")
        let input = app.textFields["bot.composer.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))

        // Type without sending so the composer keeps focus and the software
        // keyboard stays on screen for the whole interaction.
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3),
                      "software keyboard did not open; the layout precondition is missing")
        input.typeText("layout")

        // The progress card updates in place while the keyboard is open. It
        // lives below the fold here; the id row is how the test observes the
        // fixture's update without dismissing the keyboard.
        let ids = app.descendants(matching: .any)["bot.fixture.ids"]
        XCTAssertTrue(ids.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 8) {
            let label = ids.label
            return label.contains("interactive-progress")
                && !label.contains("interactive-progress-update")
                && !label.contains("interactive-progress-final")
        }, "progress card id changed: \(ids.label)")

        // Composer snapshot before the taps.
        XCTAssertTrue(input.exists, "composer is not resolvable before the taps")

        // The question card is first: option A must be hittable while the
        // keyboard covers the bottom of the transcript.
        let option = app.buttons["bot.choice.option.o0"]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        XCTAssertTrue(option.isHittable,
                      "question option is visible but not hittable: \(option.frame)")
        option.tap()
        XCTAssertTrue(waitUntil(timeout: 3) {
            (app.descendants(matching: .any)["bot.fixture.actions"].label).contains("cardAnswer")
        }, "tapping the option did not send the answer")

        // The answer starts the next step: the fixture appends the approval
        // card while the keyboard stays up. The page must follow that new row
        // and keep its buttons above the keyboard without a manual transcript
        // scroll. This is the P0 field failure.
        XCTAssertTrue(input.exists, "composer is not resolvable after the question tap")
        let always = app.buttons["bot.approval.always"]
        XCTAssertTrue(always.waitForExistence(timeout: 5))
        if !app.keyboards.firstMatch.exists {
            // Tapping a card may hand focus back; refocus is not a scroll.
            input.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        }
        XCTAssertTrue(waitUntil(timeout: 5) { always.isHittable },
                      "approval always button was not brought above the keyboard: \(always.frame)")
        XCTAssertTrue(always.isHittable,
                      "approval always button is visible but not hittable: \(always.frame)")
        XCTAssertTrue(input.exists, "composer is not resolvable before the approval tap")
        always.tap()
        XCTAssertTrue(waitUntil(timeout: 3) {
            (app.descendants(matching: .any)["bot.fixture.actions"].label)
                .contains("approval:always")
        }, "tapping 本次对话都允许 did not send the approval")
        XCTAssertFalse(app.buttons["bot.approval.always"].exists)

        // Composer snapshot after both taps, still with the keyboard up.
        XCTAssertTrue(input.exists, "composer is not resolvable after the taps")
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        input.typeText("ok")
        XCTAssertTrue(input.exists)
    }

    /// A lost live `turn/end` must not pin the live turn forever. The 800ms
    /// durable watch is authoritative; once it carries the answer the stop
    /// control, the activity line and the live text all give way to the
    /// durable answer. #126 keeps no process/tool row in between.
    func testLostTurnEndSettlesToDurableRows() throws {
        launch("runningToolUnauthorized")
        let runtime = app.descendants(matching: .any)["bot.fixture.runtime"]
        XCTAssertTrue(runtime.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 8) { runtime.label.contains("running=none") },
                      "live turn did not settle: \(runtime.label)")
        XCTAssertFalse(app.buttons["bot.composer.stop"].exists)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "两次都没有连上 App")).firstMatch
            .waitForExistence(timeout: 4), "durable answer did not take over")
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: "bot.activity.line").firstMatch.exists,
            "the running activity line stayed after the durable turn settled")
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: "bot.tool.row").firstMatch.exists,
            "a process/tool row reappeared after #126")
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "已完成")).firstMatch.exists,
            "the removed finished-process row is still rendered")
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

    /// Every erasure confirmation (single document, this Bot's memory, shared
    /// user/ memory — including its final confirmation) must say that the
    /// App's tool operation log is outside the erasure scope and may still
    /// keep the original text. The fixture opens each real dialog.
    func testErasureConfirmationsNameTheToolLogBoundary() throws {
        for fixture in ["infoEraseMemory", "infoEraseShared",
                        "infoEraseSharedFinal", "infoEraseDocument"] {
            launch(fixture)
            let clause = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "App 内部的操作日志可能仍保留原文")
            ).firstMatch
            XCTAssertTrue(clause.waitForExistence(timeout: 6), fixture)
        }
    }

    func testBotManageShowsHiddenBot() throws {
        launch("drawerManage")
        let hidden = app.staticTexts["夜航"]
        XCTAssertTrue(hidden.waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["已隐藏"].exists)
    }
}
