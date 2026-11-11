// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotVerificationTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        try BotGoldenFixture.rawObject("verification.phone")
    }

    func testSharedPolicyAndBudgetVectors() throws {
        let value = try fixture()
        let policy = try XCTUnwrap(value["policy"] as? [String: Any])
        XCTAssertEqual(policy["presetId"] as? String, "pdsh-verifier")
        XCTAssertEqual(policy["principalKind"] as? String, "verifier")
        XCTAssertEqual(policy["budgetRatio"] as? Double, 0.30)
        XCTAssertEqual(policy["tools"] as? [String], ["read", "grep", "glob", "bash"])
        XCTAssertEqual(BotVerificationPolicy.budgetRatio, 0.30)
        XCTAssertEqual(BotVerificationPolicy.verifierLimitMs(subjectBudgetMs: 180_000), 54_000)
        XCTAssertEqual(BotVerificationPolicy.verifierLimitMs(subjectBudgetMs: 1_000), 300)

        let budgets = try XCTUnwrap(value["budgets"] as? [String: Any])
        for caseValue in try XCTUnwrap(budgets["valid"] as? [[String: Any]]) {
            let budget = try XCTUnwrap(caseValue["budgetMs"] as? Int)
            let limit = try XCTUnwrap(caseValue["limitMs"] as? Int)
            XCTAssertEqual(BotVerificationPolicy.verifierLimitMs(subjectBudgetMs: budget), limit)
            if let used = caseValue["usedMs"] as? Int {
                let derived = BotVerificationPolicy.budget(subjectBudgetMs: budget, usedMs: used)
                XCTAssertEqual(derived.exceeded, caseValue["exceeded"] as? Bool)
            }
        }
        for caseValue in try XCTUnwrap(budgets["invalid"] as? [[String: Any]]) {
            let budget = try XCTUnwrap(caseValue["budgetMs"] as? Int)
            let limit = try XCTUnwrap(caseValue["limitMs"] as? Int)
            XCTAssertNotEqual(BotVerificationPolicy.verifierLimitMs(subjectBudgetMs: budget), limit)
        }
    }

    func testValidOutputsParseExactly() throws {
        let value = try fixture()
        let cases = try XCTUnwrap(value["valid"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for caseValue in cases {
            let output = try XCTUnwrap(caseValue["output"] as? [String: Any])
            let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
            let text = String(decoding: data, as: UTF8.self)
            let parsed = try BotVerifierOutputParser.parse(text)
            XCTAssertEqual(parsed.verdict.rawValue, output["verdict"] as? String)
            XCTAssertEqual(parsed.refs, output["refs"] as? [String])
            XCTAssertEqual(parsed.unverified, output["unverified"] as? [String])
        }
    }

    func testInvalidOutputsAreRejectedOrDowngraded() throws {
        let value = try fixture()
        let cases = try XCTUnwrap(value["invalid"] as? [[String: Any]])
        for caseValue in cases {
            let output = try XCTUnwrap(caseValue["output"] as? [String: Any])
            let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertThrowsError(try BotVerifierOutputParser.parse(text),
                                 "invalid output unexpectedly parsed: \(caseValue["name"] ?? "?")")
        }
        XCTAssertThrowsError(try BotVerifierOutputParser.parse("```json\n{}\n```"))
        XCTAssertThrowsError(try BotVerifierOutputParser.parse("""
        {"verdict":"passed","summary":"x","refs":["record://session/a#1"],"unverified":[]} trailing
        """))
    }

    func testTaskToolSurfaceFreezesTheCompletionContract() throws {
        let task = try XCTUnwrap(BotToolCatalog.allDefinitions.first { $0.name == "Task" })
        let properties = try XCTUnwrap(task.inputSchema["properties"]?.objectValue)
        XCTAssertEqual(properties["completion"]?["maxLength"]?.intValue, 4_000)
        XCTAssertEqual(properties["purpose"]?["maxLength"]?.intValue, 2_000)
        XCTAssertEqual(properties["constraints"]?["maxItems"]?.intValue, 8)
        XCTAssertEqual(properties["constraints"]?["items"]?["maxLength"]?.intValue, 500)
        XCTAssertEqual(properties["budget"]?["properties"]?["max_duration_ms"]?["minimum"]?.intValue, 1_000)
        XCTAssertEqual(properties["budget"]?["properties"]?["max_duration_ms"]?["maximum"]?.intValue, 300_000)
        XCTAssertTrue(task.description.contains("verified"))
    }

    func testWakeBodyCarriesEvidenceAndHonestyInstruction() {
        let budget = BotVerificationBudget(limitMs: 3_000, usedMs: 900, exceeded: false)
        let failed = BotVerification(
            verdict: .failed, summary: "REPORT.md is missing.",
            refs: ["record://session/gb-task#2"], unverified: [],
            budget: budget, output: "valid")
        let wake = BotDSHRemoteRuntime.verificationWakeBody(
            failed, title: "Write REPORT.md", status: "completed", taskID: "task-1")
        XCTAssertTrue(wake.contains("[verification] failed"))
        XCTAssertTrue(wake.contains("REPORT.md is missing."))
        XCTAssertTrue(wake.contains("record://session/gb-task#2"))
        XCTAssertTrue(wake.contains("Tell the user honestly"))
        XCTAssertTrue(wake.contains("Do not present it as done"))

        let passed = BotVerification(
            verdict: .passed, summary: "All checks passed.", refs: ["record://event/1"],
            unverified: [], budget: budget, output: "valid")
        let passedWake = BotDSHRemoteRuntime.verificationWakeBody(
            passed, title: "Write REPORT.md", status: "completed", taskID: "task-1")
        XCTAssertTrue(passedWake.contains("[verification] passed"))
        XCTAssertTrue(passedWake.contains("No message is required"))
        XCTAssertFalse(passedWake.contains("Tell the user honestly"))
    }

    func testReportShapeMatchesTheDurableContract() throws {
        let value = try fixture()
        let reports = try XCTUnwrap(value["reports"] as? [String: Any])
        let valid = try XCTUnwrap(reports["valid"] as? [[String: Any]])
        for caseValue in valid {
            let report = try XCTUnwrap(caseValue["report"] as? [String: Any])
            let subjectKind = try XCTUnwrap(report["subjectKind"] as? String)
            let subjectId = try XCTUnwrap(report["subjectId"] as? String)
            let verification = try XCTUnwrap(report["verification"] as? [String: Any])
            let budget = try XCTUnwrap(verification["budget"] as? [String: Any])
            XCTAssertEqual(budget["ratio"] as? Double, 0.30)
            if subjectKind == "task" {
                XCTAssertEqual(report["task_id"] as? String, subjectId)
            } else {
                XCTAssertEqual(report["routine_id"] as? String, subjectId)
                XCTAssertNotNil(report["runId"] as? String)
            }
            XCTAssertTrue(["passed", "failed", "uncertain"].contains(
                try XCTUnwrap(verification["verdict"] as? String)))
            XCTAssertTrue(["valid", "invalid", "budget_exceeded", "unavailable"].contains(
                try XCTUnwrap(verification["output"] as? String)))
        }
    }
}
