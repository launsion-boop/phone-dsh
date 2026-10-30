// SPDX-License-Identifier: MIT

import PhoneDSHHarness
import XCTest

@MainActor
final class PhoneDSHDeviceUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.phone-dsh.probe")
    }

    override func tearDownWithError() throws {
        attachScreenshot(named: String(name.split(separator: " ").last ?? "device-ui"))
        app.terminate()
    }

    func testDailyBriefEntryIsNotExposed() throws {
        app.launch()
        let open = app.buttons["打开会话列表"]
        XCTAssertTrue(open.waitForExistence(timeout: 60))
        open.tap()
        XCTAssertTrue(app.buttons["定时任务"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["每日简报"].exists)
        XCTAssertFalse(app.staticTexts["每日简报"].exists)
    }

    func testSubagentActivityEntryOpensSessionActivity() throws {
        app.launchEnvironment["PDSH_OFFICE_WORKSPACE_NAME"] = "activity-entry"
        app.launch()
        createNewSession()
        let more = app.buttons["更多操作"]
        XCTAssertTrue(more.waitForExistence(timeout: 30))
        more.tap()
        let entry = app.buttons["子 Agent 与后台活动"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        XCTAssertTrue(app.navigationBars["会话活动"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["子智能体"].exists)
    }

    func testScriptedSessionTaskFromComposer() throws {
        let mock = MockModelUpstream()
        mock.script = .generic(
            command: "printf 'PDSH_DEVICE_OK\\n' > pdsh-device-acceptance.txt && test \"$(cat pdsh-device-acceptance.txt)\" = PDSH_DEVICE_OK && printf '{\"fileWrite\":\"PASS\",\"readBack\":\"PASS\",\"model\":\"scripted\"}\\n' > pdsh-session-acceptance.json && cat pdsh-session-acceptance.json",
            toolText: "Running the device file acceptance task.",
            finalText: "PDSH_SESSION_OK")
        let mockURL = try mock.start()
        defer { mock.stop() }
        app.launchEnvironment = [
            "PDSH_SEED_PROVIDER_KEY": "device-scripted-key",
            "PDSH_SEED_PROVIDER_BASE": mockURL.absoluteString,
            "PDSH_SEED_PROVIDER_MODEL": "deepseek-flash",
            "PDSH_SEED_PROVIDER_NAME": "Device Scripted Model",
        ]
        app.launch()
        createNewSession()
        runSessionTask()
        XCTAssertGreaterThanOrEqual(mock.requestCount, 2)
        XCTAssertTrue(mock.requests.dropFirst().contains {
            MockModelUpstream.transcriptHasToolResult($0.body)
        })
    }

    func testHistoryRestoreThenSendKeepsLatestMessageVisible() throws {
        let mock = MockModelUpstream()
        mock.script = .generic(
            command: "printf 'PDSH_HISTORY_OK\\n'",
            toolText: "Preparing transcript history.",
            finalText: String(repeating: "历史消息用于验证恢复后的滚动位置。\n", count: 70)
                + "PDSH_HISTORY_SEED")
        let mockURL = try mock.start()
        defer { mock.stop() }
        app.launchEnvironment = [
            "PDSH_SEED_PROVIDER_KEY": "device-scripted-key",
            "PDSH_SEED_PROVIDER_BASE": mockURL.absoluteString,
            "PDSH_SEED_PROVIDER_MODEL": "deepseek-flash",
            "PDSH_SEED_PROVIDER_NAME": "Device Scripted Model",
            "PDSH_OFFICE_WORKSPACE_NAME": "history-scroll",
        ]
        app.launch()
        createNewSession()
        let send: (String) -> Void = { prompt in
            let editor = self.app.textViews["消息输入"]
            XCTAssertTrue(editor.waitForExistence(timeout: 60))
            XCTAssertTrue(self.waitUntil(timeout: 60) { editor.isEnabled })
            editor.tap()
            editor.typeText(prompt)
            let button = self.app.buttons["发送消息"]
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            button.tap()
        }
        send("生成第一轮历史")
        XCTAssertTrue(waitForElement(matching: "label ENDSWITH 'PDSH_HISTORY_SEED'", timeout: 90))
        XCTAssertTrue(waitUntil(timeout: 30) { !self.app.buttons["停止执行"].exists })

        mock.script = .generic(
            command: "printf 'PDSH_LATEST_AFTER_RESTORE\\n'",
            toolText: "Checking the restored transcript.",
            finalText: String(repeating: "恢复后继续输出，应自动跟随最新内容。\n", count: 70)
                + "PDSH_LATEST_AFTER_RESTORE")
        app.terminate()
        app.launch()
        send("恢复历史后再发送")
        let latest = app.staticTexts.matching(
            NSPredicate(format: "label ENDSWITH %@", "PDSH_LATEST_AFTER_RESTORE")).firstMatch
        XCTAssertTrue(latest.waitForExistence(timeout: 90))
        XCTAssertTrue(waitUntil(timeout: 30) { !self.app.buttons["停止执行"].exists })
        let latestVisible = {
            latest.frame.maxY <= self.app.frame.maxY && latest.frame.maxY >= self.app.frame.maxY * 0.65
        }
        XCTAssertTrue(waitUntil(timeout: 10, condition: latestVisible),
                      "the latest long response is outside the viewport: \(latest.frame) / \(self.app.frame)")
        XCTAssertFalse(app.buttons["回到最新"].exists)

        app.swipeDown()
        let returnToLatest = app.buttons["回到最新"]
        XCTAssertTrue(returnToLatest.waitForExistence(timeout: 10))
        returnToLatest.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !returnToLatest.exists })
        XCTAssertTrue(latestVisible())
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertGreaterThanOrEqual(mock.requestCount, 4)
    }

    func testComposerSendDismissesSoftwareKeyboard() throws {
        let mock = MockModelUpstream()
        mock.script = .generic(
            command: "printf 'PDSH_KEYBOARD_OK\\n'",
            toolText: "Checking keyboard dismissal.",
            finalText: "PDSH_SESSION_OK")
        let mockURL = try mock.start()
        defer { mock.stop() }
        app.launchEnvironment = [
            "PDSH_SEED_PROVIDER_KEY": "device-scripted-key",
            "PDSH_SEED_PROVIDER_BASE": mockURL.absoluteString,
            "PDSH_SEED_PROVIDER_MODEL": "deepseek-flash",
            "PDSH_SEED_PROVIDER_NAME": "Device Scripted Model",
            "PDSH_OFFICE_WORKSPACE_NAME": "keyboard-dismiss",
        ]
        app.launch()
        createNewSession()
        let editor = app.textViews["消息输入"]
        XCTAssertTrue(editor.waitForExistence(timeout: 60))
        XCTAssertTrue(waitUntil(timeout: 60) { editor.isEnabled })
        editor.tap()
        guard app.keyboards.firstMatch.waitForExistence(timeout: 8) else {
            throw XCTSkip("the simulator did not present a software keyboard")
        }
        editor.typeText("验证发送后键盘收起")
        let send = app.buttons["发送消息"]
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        send.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.app.keyboards.firstMatch.exists },
                      "sending did not dismiss the software keyboard")
        XCTAssertTrue(waitForElement(matching: "label == 'PDSH_SESSION_OK'", timeout: 90))
        XCTAssertFalse(app.keyboards.firstMatch.exists,
                       "the keyboard reappeared when the turn completed")
        XCTAssertGreaterThanOrEqual(mock.requestCount, 2)
    }

    func testRealSessionTaskFromComposer() throws {
        app.launch()
        createNewSession()
        runSessionTask()
    }

    func testOfficeBaseline() throws {
        app.launch()
        createNewSession()
        runSessionTask(
            prompt: "这是办公能力的红色基线诊断，不要做任何临时替代。请依次实际调用 phone pdf.text {}、phone docx.read {}、phone csv.analyze {}、phone doc.preview {}，把每次调用的真实退出码和返回内容整理到 office-baseline.json。不要用 Python 模拟这些工具，不要编造结果。完成后只回复 OFFICE_BASELINE_DONE。",
            marker: "OFFICE_BASELINE_DONE")
    }

    func testRealOfficePDF() throws {
        try launchOfficeSession()
        runSessionTask(
            prompt: "执行 PDF 办公验收，不能用 Python 临时替代工具。先调用 phone files.list，找到 invoice-electronic.pdf 和 receipt-scan.pdf 的 fileId。对电子发票调用 phone pdf.text，按真实文本生成 invoice-summary.json，包含 amount=120.50、每页文本引用和 missingClause=未找到。对扫描回执调用 phone pdf.render_pages（pageRange=1），把返回的 base64 用 base64 -d 写入 /dsh/tmp/receipt-scan.png，必须实际调用 read_image。只有模型真的看到图才能写 usedImage=true；若模型不支持图片，scan-summary.json 必须写 usedImage=false、visualStatus=BLOCKED、observedText=未找到和真实 error，不能用 OCR 或预期文字冒充看图。amount=42.00。最后只回复 OFFICE_PDF_DONE。",
            marker: "OFFICE_PDF_DONE")
    }

    func testRealOfficeRead() throws {
        try launchOfficeSession()
        runSessionTask(
            prompt: "执行合同与费用只读验收。先 phone files.list 获取 fileId。必须实际调用 phone docx.read 读取 service-contract.docx，写 contract-summary.json：noticeDays=30、fee=120.50、每段/表格行的真实 locator 引用，缺失信息写未找到。必须调用 phone xlsx.read 读取 expense-report.xlsx，再调用 phone csv.analyze 分析 expenses.csv（groupBy=category、expectedTotal=116.50）。不能用 Python 解析文档或心算/自算金额；合计必须由 csv.analyze 返回。写 expense-summary.json：total=116.50、负数所在真实 CSV 行号、每个分组、xlsx 中 B4 的真实公式与缓存值，并注明缓存值不是重新计算。最后只回复 OFFICE_READ_DONE。",
            marker: "OFFICE_READ_DONE")
    }

    func testRealOfficeGeneration() throws {
        try launchOfficeSession()
        runSessionTask(
            prompt: "执行新文件生成验收，不编辑任何原件。实际调用 phone doc.write 生成 meeting-notes.docx（标题 会议纪要，含总费用 116.50 和两行费用表）；调用 phone sheet.write 生成 expense-summary.xlsx（文本与数字单元格，含 120.50、-4.00、116.50）；调用 phone slides.write 生成 weekly-review.pptx；调用 phone chart.render 生成 expense-chart.png。模型不得输出 OOXML，只传结构化 JSON IR。必须对生成的 docx/xlsx 分别调用 docx.read/xlsx.read 读回，调用 office.convert 并原样记录其状态。把四个真实 fileId、读回数字、conversionStatus 写 generation-result.json。调用 phone doc.preview 预览 meeting-notes.docx，返回后继续。不要调用 share.export。最后只回复 OFFICE_GENERATION_DONE。",
            marker: "OFFICE_GENERATION_DONE")
    }

    func testRealOfficeSystem() throws {
        try launchOfficeSession()
        runSessionTask(
            prompt: "按顺序执行系统办公验收，所有结果写 system-result.json。任何失败都记录真实错误并继续下一步，不调用 jobs，不搜索工具实现，不寻找替代工具。先 phone files.list 找到 receipt-scan.png 并调用 phone ocr.image（languages=[en-US]），记录真实行 locator、文本和金额。调用 phone mail.compose_draft 创建发给 office@example.test 的草稿，主题 Weekly、正文 Total 116.50，记录 fileId，绝不能自动发送。调用 phone contacts.search 查询 PDSH，按系统权限结果记录，空结果也合法。调用 phone calendar.create_event：title=PDSH 办公验收，start=2026-10-30T10:00:00+08:00，end=2026-10-30T11:00:00+08:00，confirmed=true，idempotencyKey=pdsh-office-acceptance-v1；成功后用完全相同的参数再调用一次，第二次必须 already_created/idempotent=true，不得重复创建。调用 phone text.translate 将 Good morning 翻译到 zh-Hans；取消、缺语言资源或系统不可用则记录 BLOCKED 和真实错误，不自行翻译冒充。最后只回复 OFFICE_SYSTEM_DONE。",
            marker: "OFFICE_SYSTEM_DONE")
    }

    func testRealOfficeShareAndPick() throws {
        try launchOfficeSession()
        runSessionTask(
            prompt: "执行文件导出与选择验收，不调用 jobs，不搜索实现，不找替代工具。先 phone files.list 找到 invoice-electronic.pdf 的 fileId。调用 phone doc.preview，返回后调用 phone share.export 导出该文件，系统分享面板由测试驱动选择保存。分享返回后调用 phone files.pick，由测试驱动选择导出的 invoice-electronic.pdf。把分享返回状态和新导入的 fileId 写 share-pick-result.json；任何失败都记录真实错误并继续，不得编造 fileId。不要做其它文档解析或转换，最后只回复 OFFICE_SHARE_PICK_DONE。",
            marker: "OFFICE_SHARE_PICK_DONE",
            saveAndPick: "invoice-electronic.pdf")
    }

    private func launchOfficeSession() throws {
        app.launchEnvironment["PDSH_OFFICE_FIXTURE_DIR"] = try XCTUnwrap(
            ProcessInfo.processInfo.environment["PDSH_OFFICE_FIXTURE_DIR"])
        let runID = ProcessInfo.processInfo.environment["PDSH_OFFICE_RUN_ID"] ?? "default"
        app.launchEnvironment["PDSH_OFFICE_WORKSPACE_NAME"] = runID
        app.launchEnvironment["PDSH_OFFICE_ARTIFACT_NAMESPACE"] = "\(runID)-\(name)"
        app.launch()
        createNewSession()
    }

    private func createNewSession() {
        let open = app.buttons["打开会话列表"]
        XCTAssertTrue(open.waitForExistence(timeout: 240))
        open.tap()
        let create = app.buttons["新建会话"]
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(timeout: 240) { create.isEnabled }, "new session did not become available")
        create.tap()
        XCTAssertTrue(app.textViews["消息输入"].waitForExistence(timeout: 60))
    }

    private func runSessionTask(prompt: String? = nil, marker: String = "PDSH_SESSION_OK",
                                saveAndPick: String? = nil) {
        let editor = app.textViews["消息输入"]
        XCTAssertTrue(editor.waitForExistence(timeout: 240))
        XCTAssertTrue(waitUntil(timeout: 120) { editor.isEnabled }, "session composer did not become ready")
        editor.tap()
        editor.typeText(prompt ?? "在当前工作区执行验收任务：创建 pdsh-device-acceptance.txt，内容只能是 PDSH_DEVICE_OK（末尾可有换行）。然后读取文件确认并写入 pdsh-session-acceptance.json。完成后只回复 PDSH_SESSION_OK。")
        let send = app.buttons["发送消息"]
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        XCTAssertTrue(send.isEnabled)
        send.tap()

        let recordDriverEvent: (String) -> Void = { event in
            guard saveAndPick != nil,
                  let fixture = ProcessInfo.processInfo.environment["PDSH_OFFICE_FIXTURE_DIR"] else { return }
            let url = URL(fileURLWithPath: fixture).appendingPathComponent("driver-events.jsonl")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let data = "\(Date().timeIntervalSince1970) \(event)\n".data(using: .utf8),
                  let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }

        var savedForPicker = false
        var translationWaitingSince: Date?
        var lastFilesRetry: Date?
        let completed = waitUntil(timeout: 300) { [weak self] in
            guard let self else { return false }
            recordDriverEvent("loop savedForPicker=\(savedForPicker)")
            if self.app.staticTexts.matching(NSPredicate(format: "label == %@", marker)).firstMatch.exists {
                return true
            }
            let latest = self.app.buttons["回到最新"]
            if latest.exists && latest.isHittable { latest.tap() }
            let shareSurfaces: [XCUIApplication] = [self.app]
            for candidate in shareSurfaces where candidate.exists {
                for label in (saveAndPick == nil ? ["Copy", "拷贝", "Save to Files", "保存到\u{201C}文件\u{201D}", "保存到‘文件’"] : ["保存到\u{201C}文件\u{201D}", "Save to Files", "保存到‘文件’"]) as [String] {
                    let button = candidate.buttons[label]
                    let text = candidate.staticTexts[label]
                    if button.exists || text.exists {
                        recordDriverEvent("share \(label) buttonHit=\(button.isHittable) textHit=\(text.isHittable)")
                    }
                    if let action = [button, text].first(where: { $0.exists && $0.isHittable }) {
                        self.attachScreenshot(named: "office-share-sheet")
                        action.tap()
                        return false
                    }
                }
            }
            for label in (savedForPicker ? ["替换", "Replace"] : ["保存", "Save", "替换", "Replace", "存储"]) {
                for candidate in shareSurfaces where candidate.exists {
                    let button = candidate.buttons[label]
                    let text = candidate.staticTexts[label]
                    recordDriverEvent("save candidate \(label) button=\(button.exists) hit=\(button.isHittable) text=\(text.exists) textHit=\(text.isHittable)")
                    if let save = [button, text].first(where: { $0.exists && $0.isHittable }) {
                        recordDriverEvent("save \(label) hittable=\(save.isHittable)")
                        save.tap()
                        savedForPicker = saveAndPick != nil
                        return false
                    }
                }
            }
            let documentApplications: [XCUIApplication] = [self.app]
            for candidate in documentApplications where candidate.exists {
                for label in ["浏览", "Browse", "重试", "Retry"] {
                    let button = candidate.buttons[label]
                    let text = candidate.staticTexts[label]
                    let retry = button.exists ? button : text
                    if retry.exists && retry.isHittable,
                       lastFilesRetry == nil || Date().timeIntervalSince(lastFilesRetry ?? Date()) > 5 {
                        self.attachScreenshot(named: "office-files-retry")
                        retry.tap()
                        lastFilesRetry = Date()
                        return false
                    }
                }
            }
            if savedForPicker, let fileName = saveAndPick {
                let saveVisible = documentApplications.contains { candidate in
                    candidate.exists && ["Replace", "替换", "Save", "存储", "保存"].contains {
                        candidate.buttons[$0].isHittable || candidate.staticTexts[$0].isHittable
                    }
                }
                recordDriverEvent("picker gate saveVisible=\(saveVisible)")
                if saveVisible { return false }
                let baseName = fileName.replacingOccurrences(of: ".pdf", with: "")
                for candidate in documentApplications where candidate.exists {
                    let pickerVisible = ["最近项目", "Recents", "浏览", "Browse", "我的 iPhone", "On My iPhone"].contains {
                        candidate.buttons[$0].exists || candidate.staticTexts[$0].exists
                            || candidate.navigationBars[$0].exists
                    }
                    if !pickerVisible { continue }
                    let rows = candidate.descendants(matching: .any)
                        .matching(NSPredicate(format: "label BEGINSWITH %@", baseName))
                    recordDriverEvent("picker app=\(candidate.label) rows=\(rows.count) saved=\(savedForPicker)")
                    for index in 0..<min(rows.count, 12) {
                        let row = rows.element(boundBy: index)
                        if row.exists && row.isHittable {
                            recordDriverEvent("pick \(row.label)")
                            self.attachScreenshot(named: "office-document-picker")
                            row.tap()
                            savedForPicker = false
                            for label in ["Open", "打开"] {
                                let open = candidate.buttons[label]
                                if open.exists && open.isHittable { open.tap(); break }
                            }
                            return false
                        }
                    }
                    let locations = candidate.descendants(matching: .any)
                        .matching(NSPredicate(format: "label == %@ OR label == %@", "我的 iPhone", "On My iPhone"))
                    for index in 0..<min(locations.count, 4) {
                        let location = locations.element(boundBy: index)
                        if location.exists && location.isHittable {
                            location.tap()
                            return false
                        }
                    }
                }
            }
            let allow = self.app.buttons["允许一次"]
            if allow.exists && allow.isHittable {
                allow.tap()
            }
            let systemApplications: [XCUIApplication] = [self.app,
                XCUIApplication(bundleIdentifier: "com.apple.springboard")]
            for candidate in systemApplications {
                let shareContacts = candidate.buttons.matching(NSPredicate(
                    format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "共享所有", "Share All")).firstMatch
                if shareContacts.exists && shareContacts.isHittable {
                    shareContacts.tap()
                    break
                }
                for label in ["创建日程", "允许完整访问", "允许全部日程", "允许", "好", "OK", "Allow Full Access", "Allow"] {
                    let button = candidate.buttons[label]
                    let text = candidate.staticTexts[label]
                    if let action = [button, text].first(where: { $0.exists && $0.isHittable }) {
                        action.tap()
                        break
                    }
                }
            }
            if self.app.staticTexts["正在准备系统翻译…"].exists {
                if translationWaitingSince == nil { translationWaitingSince = Date() }
                if Date().timeIntervalSince(translationWaitingSince ?? Date()) > 20 {
                    let cancel = self.app.buttons["取消翻译"]
                    if cancel.exists && cancel.isHittable {
                        self.attachScreenshot(named: "office-translation-cancelled")
                        cancel.tap()
                        translationWaitingSince = nil
                    }
                }
            } else {
                translationWaitingSince = nil
            }
            if self.app.staticTexts["添加标签"].exists {
                let close = self.app.navigationBars["添加标签"].buttons.firstMatch
                if close.exists {
                    recordDriverEvent("close tag editor")
                    close.tap()
                    return false
                }
            }
            if self.app.staticTexts["No file to preview"].exists {
                self.attachScreenshot(named: "quick-look-empty")
            }
            let previewVisible = ["No file to preview", "Save to Files", "Print"].contains {
                self.app.buttons[$0].exists || self.app.staticTexts[$0].exists
            }
            let quickLookDocument = self.app.staticTexts
                .matching(NSPredicate(format: "label BEGINSWITH %@", "meeting-notes")).firstMatch.exists
            let previewRequested = prompt?.contains("doc.preview") == true && quickLookDocument
            if saveAndPick == nil && (previewVisible || previewRequested) {
                self.attachScreenshot(named: "office-quick-look")
                self.app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.095)).tap()
                return false
            }
            if saveAndPick == nil {
                for label in ["关闭预览", "关闭", "完成", "Close", "Done"] {
                    let button = self.app.buttons[label]
                    if button.exists && button.isHittable { button.tap(); break }
                }
            } else {
                let saveVisible = ["Replace", "替换", "Save", "存储", "保存"].contains {
                    self.app.buttons[$0].isHittable || self.app.staticTexts[$0].isHittable
                }
                let pickerVisible = ["最近项目", "Recents", "浏览", "Browse", "我的 iPhone", "On My iPhone"].contains {
                    self.app.staticTexts[$0].exists
                }
                if !saveVisible && !pickerVisible {
                    let close = self.app.buttons["关闭预览"]
                    if close.exists && close.isHittable { close.tap() }
                }
            }
            let quickLookClose = self.app.navigationBars.buttons.firstMatch
            if saveAndPick == nil && quickLookClose.exists && quickLookClose.isHittable {
                self.attachScreenshot(named: "office-quick-look")
                quickLookClose.tap()
                return false
            }
            return false
        }
        attachScreenshot(named: "session-task")
        XCTAssertTrue(completed, "session did not finish the requested file task; inspect the attached screenshot")
    }

    private func waitForElement(matching predicate: String, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) { [weak self] in
            self?.app.descendants(matching: .any)
                .matching(NSPredicate(format: predicate)).firstMatch.exists == true
        }
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return condition()
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
