// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — scenario evidence artifacts.

import Foundation
import XCTest
import PhoneDSHAgentCore
@testable import PhoneDSHScenario

final class ScenarioEvidenceArtifactTests: XCTestCase {
    func testScenarioDefinitionArtifactWritesResolvedObjectAndPreservesUnknownFields() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-scenario-definition-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalogURL = root.appendingPathComponent("catalog.json")
        let source = #"{"version":1,"scenarios":[{"id":"EVIDENCE-UNIT","category":"unit","title":"size {{budgets.singleFileBytes}}","user_story":"story {{budgets.singleFileBytes}}","workspace":{"files":{},"future_workspace":{"keep":true}},"turns":[{"prompt":"prompt {{budgets.singleFileBytes}}","future_turn":"keep"},{"prompt":"second prompt"}],"assertions":[{"type":"no_console_error"}],"rubric":["rubric {{budgets.singleFileBytes}}"],"budget":{"max_minutes":3,"max_model_requests":7},"budgets":{"singleFileBytes":16777216},"future_catalog":{"keep":"yes","future_note":"catalog-secret-value"}}]}"#
        try Data(source.utf8).write(to: catalogURL)

        var rawCatalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any])
        var rawScenarios = try XCTUnwrap(rawCatalog["scenarios"] as? [[String: Any]])
        rawScenarios[0]["future_headers"] = ["X-Api-Key": "opaque-catalog-key",
                                             "Authorization": "opaque-auth-value",
                                             "accept": "application/json"]
        rawCatalog["scenarios"] = rawScenarios
        try JSONSerialization.data(withJSONObject: rawCatalog).write(to: catalogURL)

        let catalog = try ScenarioCatalog.load(from: catalogURL)
        let scenario = try XCTUnwrap(catalog.scenarios.first)
        let url = root.appendingPathComponent("results/EVIDENCE-UNIT/scenario.json")
        try ScenarioDefinitionArtifact.write(
            scenario, to: url, redactor: ScenarioRedactor(secrets: ["catalog-secret-value"]))

        let written = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(written["title"] as? String, "size 16777216")
        XCTAssertEqual(written["user_story"] as? String, "story 16777216")
        XCTAssertEqual(written["rubric"] as? [String], ["rubric 16777216"])
        XCTAssertEqual(written["future_catalog"] as? [String: String],
                       ["keep": "yes", "future_note": "<redacted>"])
        XCTAssertEqual(written["future_headers"] as? [String: String],
                       ["X-Api-Key": "<redacted>", "Authorization": "<redacted>",
                        "accept": "application/json"])
        let workspace = try XCTUnwrap(written["workspace"] as? [String: Any])
        XCTAssertEqual(workspace["future_workspace"] as? [String: Bool], ["keep": true])
        let turns = try XCTUnwrap(written["turns"] as? [[String: Any]])
        XCTAssertEqual(turns.map { $0["prompt"] as? String },
                       ["prompt 16777216", "second prompt"])
        XCTAssertEqual(turns[0]["future_turn"] as? String, "keep")
        let assertions = try XCTUnwrap(written["assertions"] as? [[String: Any]])
        XCTAssertEqual(assertions[0]["type"] as? String, "no_console_error")
        XCTAssertEqual(written["budget"] as? [String: Int],
                       ["max_minutes": 3, "max_model_requests": 7])
    }

    func testUsageReportNamesRunAndSessionClocksAndKeepsLegacyAlias() throws {
        let usage = ScenarioUsageReport(modelRequests: 2,
                                        upstreamBytesIn: 100,
                                        upstreamBytesOut: 200,
                                        wallS: 310,
                                        runWallS: 12.5,
                                        sessionWallS: 8.25)
        let assertion = ScenarioAssertionReport(type: "no_console_error",
                                                ok: true,
                                                detail: "no console errors")
        let report = ScenarioReport(id: "EVIDENCE-UNIT",
                                    status: "PASS",
                                    assertions: [assertion],
                                    turns: [],
                                    perturbations: [],
                                    usage: usage,
                                    pageVisibility: nil,
                                    deferred: nil,
                                    runnerInfra: nil,
                                    webContentTerminations: 0,
                                    hostEvaluated: nil,
                                    consoleErrors: [],
                                    runnerErrors: [],
                                    hostStates: [],
                                    runCompleted: true,
                                    runIncompleteReason: nil)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-report-usage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reportURL = root.appendingPathComponent("report.json")
        try ScenarioReportArtifact.write(report, to: reportURL)
        let writtenReport = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: reportURL)) as? [String: Any])
        let object = try XCTUnwrap(writtenReport["usage"] as? [String: Any])
        XCTAssertEqual(object["wall_s"] as? Double, 12.5,
                       "legacy wall_s remains the runner-lifetime alias")
        XCTAssertEqual(object["run_wall_s"] as? Double, 12.5)
        XCTAssertEqual(object["session_wall_s"] as? Double, 8.25)

        let withoutSession = ScenarioUsageReport(modelRequests: 0,
                                                 upstreamBytesIn: 0,
                                                 upstreamBytesOut: 0,
                                                 wallS: 0)
        let absent = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(withoutSession)) as? [String: Any])
        XCTAssertNil(absent["session_wall_s"],
                     "runs that never open a harness session have no session clock")
    }

    func testTranscriptKeepsLargeToolEvidenceAsValidRoundTrippableJSONL() throws {
        let largeArgument = String(repeating: "x\"\\\n", count: 900)
        let call = HarnessEvent(
            seq: 1, time: Date(timeIntervalSince1970: 1),
            kind: .toolCall(callID: "call-large", name: "bash",
                            arguments: .object(["command": .string(largeArgument)])))
        let fullToolResult = String(repeating: "trace line\n", count: 7_000)
        XCTAssertGreaterThan(fullToolResult.utf8.count, DSHEventMapper.defaultAuditTextLimit)
        let mappedResult = DSHEventMapper.map(
            .object([
                "type": .string("tool/result"),
                "seq": .number(2),
                "time": .number(2_000),
                "data": .object([
                    "message": .object([
                        "toolCallId": .string("call-large"),
                        "isError": .bool(true),
                        "content": .array([.object([
                            "type": .string("text"),
                            "text": .string(fullToolResult),
                        ])]),
                    ]),
                ]),
            ]),
            sessionID: "session-1")
        let result = try XCTUnwrap(mappedResult.first)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-transcript-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("transcript.jsonl")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bytes = try ScenarioTranscript.encode(
            records: [ScenarioHarnessRecord(event: call), ScenarioHarnessRecord(event: result)],
            encoder: encoder, redactor: ScenarioRedactor())
        try scenarioWrite(bytes, to: url)

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try lines.map { line -> HarnessEvent in
            let data = Data(line.utf8)
            _ = try JSONSerialization.jsonObject(with: data)
            return try decoder.decode(HarnessEvent.self, from: data)
        }
        XCTAssertEqual(decoded, [call, result])
        guard case .toolCall(_, _, .object(let arguments)) = decoded[0].kind else {
            return XCTFail("large tool call must remain a structured event")
        }
        XCTAssertEqual(arguments["command"], .string(largeArgument))
        XCTAssertEqual(decoded[1].toolResultDetail?.truncated, true)
        XCTAssertEqual(decoded[1].seq, 16,
                       "the harness sequence keeps the DSH event position")
        XCTAssertEqual(decoded[1].toolResultDetail?.eventSeq, 2,
                       "the spill pointer names the source DSH journal sequence")
        XCTAssertTrue(try XCTUnwrap(decoded[1].toolResultDetail?.text)
            .contains("complete record: /dsh/home/sessions/*/session-1/session.*.jsonl"))
        XCTAssertEqual(decoded[1].toolResultDetail?.sessionLogPath,
                       "/dsh/home/sessions/*/session-1/session.*.jsonl")
    }
}
