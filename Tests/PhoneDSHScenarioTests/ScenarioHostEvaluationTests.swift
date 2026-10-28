// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: host phase for a simulator run.
//
// `scripts/ci/scenarios.sh --run-on sim` invokes this XCTest case after
// pulling `Documents/pdsh-scenarios/results/` back to `--results`:
//
//   PDSH_SCENARIO_HOST_EVAL_RESULTS  absolute results root
//   PDSH_SCENARIO_HOST_EVAL_IDS      this run's selected scenario ids
//
// The case is a thin shim: the evaluation itself lives in the regular
// `PhoneDSHScenario` library (`ScenarioWorkspaceCommand` /
// `ScenarioHostEvaluation`), the same code the macOS runner calls while the
// scenario runs. The class name deliberately has no `PhoneDSH` /
// `PhoneDSHScenario` prefix, so the unit-test gates and the macOS scenario
// filter do not accidentally execute it; the host driver passes `--filter
// ScenarioHostEvaluationTests`.
//
// The iOS Simulator test bundle never runs this file (it links the library,
// not this SwiftPM test target), and the library spawns no process there.

import Foundation
import XCTest
@testable import PhoneDSHScenario

final class ScenarioHostEvaluationTests: XCTestCase {
    private static func environmentValue(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name],
              !value.isEmpty else { return nil }
        return value
    }

    /// Fills every pulled `pending_host` assertion with its real host verdict.
    func testEvaluatePulledWorkspaceCommands() throws {
        guard let rootPath = Self.environmentValue("PDSH_SCENARIO_HOST_EVAL_RESULTS") else {
            throw XCTSkip("PDSH_SCENARIO_HOST_EVAL_RESULTS is not set; "
                + "this test is the simulator host phase entry point, invoked by "
                + "scripts/ci/scenarios.sh --run-on sim")
        }
        let ids = (Self.environmentValue("PDSH_SCENARIO_HOST_EVAL_IDS") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let resultsRoot = URL(fileURLWithPath: rootPath, isDirectory: true)
        let summary = try ScenarioHostEvaluation.finalizeReports(in: resultsRoot, ids: ids)
        print("scenario host evaluation: \(summary.assertionsEvaluated) "
            + "workspace_command assertion(s) in \(summary.reports) report(s); "
            + "\(summary.remainingPending) report(s) still pending")
        XCTAssertEqual(summary.remainingPending, 0,
                       "a pulled report still carries pending_host assertions")

        // A final report must not carry the simulator's old typed host-process
        // failure or a provisional assertion status.
        for id in ids {
            let reportURL = resultsRoot
                .appendingPathComponent(id, isDirectory: true)
                .appendingPathComponent("report.json")
            guard FileManager.default.fileExists(atPath: reportURL.path) else { continue }
            let text = try String(contentsOf: reportURL, encoding: .utf8)
            XCTAssertFalse(text.contains("host process execution is not available"),
                           "\(id): a pulled report still says workspace_command "
                           + "could not be evaluated")
            XCTAssertFalse(text.contains("\"pending_host\""),
                           "\(id): a pulled report still has a pending_host assertion")
        }
    }
}
