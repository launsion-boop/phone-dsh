// SPDX-License-Identifier: MIT
//
// SIM / A04 feature-admin entry. This drives the shipped DSH Web settings sheet
// through the real UI (Settings -> phone-capabilities -> Skills), not a service
// call or eval action. It creates a user skill with Save and deletes it with
// Delete; E then collects model/DB/observer evidence.
//
// Environment:
//   PDSH_SIM_FEATURE_TAB   optional tab label (default 手机能力)
//   PDSH_SIM_TASK          unused; present so SIM lane shares env setup
// The SIM lane must own a dedicated simulator.

import XCTest

final class SimFeatureAdminSkillsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.phone-dsh.probe")
        app.launch()
        XCTAssertTrue(app.buttons["Bot"].waitForExistence(timeout: 60),
                      "App tab bar did not appear")
    }

    func testSkillsEditorSaveThenDelete() throws {
        let featureTab = ProcessInfo.processInfo.environment["PDSH_SIM_FEATURE_TAB"]
            ?? "手机能力"
        app.buttons["DSH"].tap()
        let open = app.buttons["打开会话列表"]
        XCTAssertTrue(open.waitForExistence(timeout: 60), "DSH page did not appear")
        open.tap()
        let settings = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "设置")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "DSH settings entry missing")
        settings.tap()

        let tab = app.buttons[featureTab].firstMatch
        if !tab.waitForExistence(timeout: 20) {
            // Web settings may expose tabs as static text.
            XCTAssertTrue(app.staticTexts[featureTab].firstMatch.waitForExistence(timeout: 10),
                          "phone-capabilities tab '\(featureTab)' missing")
            app.staticTexts[featureTab].firstMatch.tap()
        } else {
            tab.tap()
        }

        let newSkill = app.buttons["新建 skill"].firstMatch
        if newSkill.waitForExistence(timeout: 10) {
            newSkill.tap()
        }
        let name = app.textFields["my-skill.md"].firstMatch.exists
            ? app.textFields["my-skill.md"].firstMatch
            : app.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 10), "skill file-name field missing")
        let stamp = Int(Date().timeIntervalSince1970)
        let skill = "sim-skill-\(stamp).md"
        name.tap()
        name.typeText(skill)

        let content = app.textViews.firstMatch
        XCTAssertTrue(content.exists, "skill Markdown editor missing")
        content.tap()
        content.typeText("---\nname: sim-skill-\(stamp)\ndescription: SIM feature-admin check\n---\n\nReply with the injected marker.\n")

        let save = app.buttons["保存 skill"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10), "Save skill missing")
        save.tap()
        let saved = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "已保存")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 15), "skill save receipt missing")

        let delete = app.buttons["删除 skill"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 10), "Delete skill missing")
        delete.tap()
        let deleted = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "已删除")).firstMatch
        XCTAssertTrue(deleted.waitForExistence(timeout: 15), "skill delete receipt missing")
    }
}
