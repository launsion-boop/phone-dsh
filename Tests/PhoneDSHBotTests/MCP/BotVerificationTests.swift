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

    func testVerifierPromptNamesOnlyTheFrozenReadOnlyForensics() throws {
        let value = try fixture()
        let policy = try XCTUnwrap(value["policy"] as? [String: Any])
        let bash = try XCTUnwrap(policy["bash"] as? [String: Any])
        let allowed = try XCTUnwrap(bash["allowed"] as? [String])
        let prompt = BotVerifierPrompt.build(
            subjectKind: "task", subjectId: "task-1",
            completion: "REPORT.md exists", purpose: nil, constraints: [],
            refs: ["record://session/gb-task#1"], subjectSessionId: "gb-task")
        XCTAssertTrue(prompt.contains("`phone record search`"))
        XCTAssertTrue(prompt.contains("`phone record read <ref>`"))
        XCTAssertTrue(prompt.contains("`od`"))
        XCTAssertTrue(allowed.contains { $0.hasPrefix("phone record search ") })
        XCTAssertTrue(allowed.contains { $0.hasPrefix("phone record read ") })
        XCTAssertTrue(allowed.contains { $0.hasPrefix("od ") })
        // The prompt must not teach a command the read-only policy would deny.
        for forbidden in ["`find ", "`sed ", "`curl ", "`python3 "]
        where prompt.contains(forbidden) {
            XCTFail("verifier prompt teaches a denied command: \(forbidden)")
        }
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

    func testVerifierPrincipalCannotWriteMemoryEvenThroughTheMCPRuntime() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-verifier-memory", kind: .verifier)
        let result = try await registerAndExecute(
            fixture.runtime, name: "UpdateMemory",
            arguments: .object([
                "action": .string("write"),
                "path": .string("agent/leak.md"),
                "content": .string("verifier wrote this"),
                "expected_version": .number(0),
            ]),
            sessionId: "gb-verifier-memory")
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.structuredContent?["error"]?["code"], .string("permission_denied"))
        let events = try await botEvents(fixture.store)
        XCTAssertFalse(events.contains {
            $0.type == "memory.document_written" || $0.type == "memory.written"
        })
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
        XCTAssertTrue(wake.contains("如实告诉用户"))
        XCTAssertTrue(wake.contains("不要把它说成已完成"))

        let passed = BotVerification(
            verdict: .passed, summary: "All checks passed.", refs: ["record://event/1"],
            unverified: [], budget: budget, output: "valid")
        let passedWake = BotDSHRemoteRuntime.verificationWakeBody(
            passed, title: "Write REPORT.md", status: "completed", taskID: "task-1")
        XCTAssertTrue(passedWake.contains("[verification] passed"))
        XCTAssertTrue(passedWake.contains("不需要再发消息"))
        XCTAssertFalse(passedWake.contains("如实告诉用户"))
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
