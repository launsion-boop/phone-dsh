// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner on the iOS Simulator: XCTest glue.
//
// The same catalog, engine, assertions and evidence formats as the macOS
// `Tests/PhoneDSHScenarioTests` suite; the engine lives in the regular
// `PhoneDSHScenario` library. The host driver
// (`scripts/ci/scenarios.sh --run-on sim`) stages the catalog, fixtures
// and config in the probe app container, passes the model credentials only
// through the `xcodebuild` test-runner environment, then pulls
// `Documents/pdsh-scenarios/results/<id>/` back into `--results`.
//
// One static slot per possible selected scenario: SwiftPM's `--filter`
// limitation does not apply to xcodebuild, but the fixed slot bank keeps the
// macOS and iOS selection semantics identical. Unused slots skip.
//
// NOT_VERIFIED on an iPhone: no physical-device run exists.

import Foundation
import XCTest
import PhoneDSHScenario

final class PhoneDSHScenarioSimTests: XCTestCase {
    /// Selection guard: reports setup errors once and checks the slot capacity.
    @MainActor
    func testScenarioSelectionGuard() async throws {
        let plan = ScenarioSimSlotPlan.plan
        if let error = plan.error {
            XCTFail("scenario runner setup failed: \(error)")
            return
        }
        if plan.scenarios.isEmpty {
            XCTFail("no scenario matched the catalog selection "
                + "(only=\(plan.environment?.only ?? []), "
                + "tag=\(plan.environment?.tag ?? "-"), "
                + "target=\(plan.environment?.target ?? "-"))")
            return
        }
        if let capacityError = ScenarioSlotPlan.capacityError(
            selectionCount: plan.scenarios.count) {
            XCTFail(capacityError)
        }
    }

    /// Runs one slot's scenario, or skips when the slot is unused.
    @MainActor
    private func runSlot(_ index: Int) async throws {
        let plan = ScenarioSimSlotPlan.plan
        if let error = plan.error {
            throw XCTSkip("selection setup failed; testScenarioSelectionGuard reports it: \(error)")
        }
        guard let environment = plan.environment else {
            throw XCTSkip("selection environment is unavailable")
        }
        // An over-capacity selection is rejected when the plan is loaded: no
        // scenario executes, so the batch fails whole. The selection guard
        // reports the failure once; slots skip so the log names only one cause.
        if let capacityError = ScenarioSlotPlan.capacityError(
            selectionCount: plan.scenarios.count) {
            throw XCTSkip("scenario runner rejected the batch before execution: \(capacityError)")
        }
        guard index < plan.scenarios.count else {
            throw XCTSkip("scenario slot \(index) is unused")
        }
        let scenario = plan.scenarios[index]
        let run = ScenarioRun(scenario: scenario, environment: environment)
        let report = await run.execute()
        if report.status == "PENDING_HOST" {
            // A `workspace_command` assertion needs a host process, which this
            // simulator test process cannot spawn. The run is not a verdict
            // yet: `scenarios.sh --run-on sim` pulls the evidence and runs the
            // same shared evaluator on the Mac host, then computes the final
            // status. Failing here would fail the batch before that phase; a
            // pass here would hide a failing command. Skip provisionally — the
            // host phase rewrites report.json and report_check gates the run.
            throw XCTSkip("scenario \(scenario.id): workspace_command assertion(s) "
                + "pending host evaluation")
        }
        guard report.status == "PASS" else {
            let failed = report.assertions
                .filter { !$0.ok && $0.status != "pending_host" }
                .map { "\($0.type): \($0.detail)" }
                .joined(separator: "; ")
            let perturbations = report.perturbations
                .filter { $0.ok == false }
                .map { "\($0.at)/\($0.kind): \($0.detail ?? "failed")" }
                .joined(separator: "; ")
            let extra = [failed, perturbations].filter { !$0.isEmpty }.joined(separator: " | ")
            XCTFail("scenario \(scenario.id) \(report.status)"
                + (extra.isEmpty ? "" : ": \(extra)")
                + " (report: \(environment.resultsRoot.appendingPathComponent(scenario.id).path))")
            return
        }
    }

    // Slot methods. Keep these methods trivial: XCTest discovery only sees
    // static test methods.

    @MainActor func testScenarioSlot00() async throws { try await runSlot(0) }
    @MainActor func testScenarioSlot01() async throws { try await runSlot(1) }
    @MainActor func testScenarioSlot02() async throws { try await runSlot(2) }
    @MainActor func testScenarioSlot03() async throws { try await runSlot(3) }
    @MainActor func testScenarioSlot04() async throws { try await runSlot(4) }
    @MainActor func testScenarioSlot05() async throws { try await runSlot(5) }
    @MainActor func testScenarioSlot06() async throws { try await runSlot(6) }
    @MainActor func testScenarioSlot07() async throws { try await runSlot(7) }
    @MainActor func testScenarioSlot08() async throws { try await runSlot(8) }
    @MainActor func testScenarioSlot09() async throws { try await runSlot(9) }
    @MainActor func testScenarioSlot10() async throws { try await runSlot(10) }
    @MainActor func testScenarioSlot11() async throws { try await runSlot(11) }
    @MainActor func testScenarioSlot12() async throws { try await runSlot(12) }
    @MainActor func testScenarioSlot13() async throws { try await runSlot(13) }
    @MainActor func testScenarioSlot14() async throws { try await runSlot(14) }
    @MainActor func testScenarioSlot15() async throws { try await runSlot(15) }
    @MainActor func testScenarioSlot16() async throws { try await runSlot(16) }
    @MainActor func testScenarioSlot17() async throws { try await runSlot(17) }
    @MainActor func testScenarioSlot18() async throws { try await runSlot(18) }
    @MainActor func testScenarioSlot19() async throws { try await runSlot(19) }
    @MainActor func testScenarioSlot20() async throws { try await runSlot(20) }
    @MainActor func testScenarioSlot21() async throws { try await runSlot(21) }
    @MainActor func testScenarioSlot22() async throws { try await runSlot(22) }
    @MainActor func testScenarioSlot23() async throws { try await runSlot(23) }
    @MainActor func testScenarioSlot24() async throws { try await runSlot(24) }
    @MainActor func testScenarioSlot25() async throws { try await runSlot(25) }
    @MainActor func testScenarioSlot26() async throws { try await runSlot(26) }
    @MainActor func testScenarioSlot27() async throws { try await runSlot(27) }
    @MainActor func testScenarioSlot28() async throws { try await runSlot(28) }
    @MainActor func testScenarioSlot29() async throws { try await runSlot(29) }
    @MainActor func testScenarioSlot30() async throws { try await runSlot(30) }
    @MainActor func testScenarioSlot31() async throws { try await runSlot(31) }
    @MainActor func testScenarioSlot32() async throws { try await runSlot(32) }
    @MainActor func testScenarioSlot33() async throws { try await runSlot(33) }
    @MainActor func testScenarioSlot34() async throws { try await runSlot(34) }
    @MainActor func testScenarioSlot35() async throws { try await runSlot(35) }
    @MainActor func testScenarioSlot36() async throws { try await runSlot(36) }
    @MainActor func testScenarioSlot37() async throws { try await runSlot(37) }
    @MainActor func testScenarioSlot38() async throws { try await runSlot(38) }
    @MainActor func testScenarioSlot39() async throws { try await runSlot(39) }
    @MainActor func testScenarioSlot40() async throws { try await runSlot(40) }
    @MainActor func testScenarioSlot41() async throws { try await runSlot(41) }
    @MainActor func testScenarioSlot42() async throws { try await runSlot(42) }
    @MainActor func testScenarioSlot43() async throws { try await runSlot(43) }
    @MainActor func testScenarioSlot44() async throws { try await runSlot(44) }
    @MainActor func testScenarioSlot45() async throws { try await runSlot(45) }
    @MainActor func testScenarioSlot46() async throws { try await runSlot(46) }
    @MainActor func testScenarioSlot47() async throws { try await runSlot(47) }
    @MainActor func testScenarioSlot48() async throws { try await runSlot(48) }
    @MainActor func testScenarioSlot49() async throws { try await runSlot(49) }
    @MainActor func testScenarioSlot50() async throws { try await runSlot(50) }
    @MainActor func testScenarioSlot51() async throws { try await runSlot(51) }
    @MainActor func testScenarioSlot52() async throws { try await runSlot(52) }
    @MainActor func testScenarioSlot53() async throws { try await runSlot(53) }
    @MainActor func testScenarioSlot54() async throws { try await runSlot(54) }
    @MainActor func testScenarioSlot55() async throws { try await runSlot(55) }
    @MainActor func testScenarioSlot56() async throws { try await runSlot(56) }
    @MainActor func testScenarioSlot57() async throws { try await runSlot(57) }
    @MainActor func testScenarioSlot58() async throws { try await runSlot(58) }
    @MainActor func testScenarioSlot59() async throws { try await runSlot(59) }
    @MainActor func testScenarioSlot60() async throws { try await runSlot(60) }
    @MainActor func testScenarioSlot61() async throws { try await runSlot(61) }
    @MainActor func testScenarioSlot62() async throws { try await runSlot(62) }
    @MainActor func testScenarioSlot63() async throws { try await runSlot(63) }
}
