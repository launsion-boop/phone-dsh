// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: the macOS XCTest glue.
//
// `swift test --filter PhoneDSHScenario` runs one XCTest case per selected
// scenario. Everything that is not XCTest glue — catalog decoding, workspace
// seeding, perturbations, assertions, report/transcript writers, the mock
// upstream adapter, the budget guard and the slot plan itself — lives in the
// regular `PhoneDSHScenario` library so the same engine runs inside the
// iOS Simulator (examples/probe-app, `PhoneDSHScenarioSimTests`).
//
// Each run writes `<results>/<id>/report.json`, `transcript.jsonl` and
// `workspace.tar`; the XCTest failure carries only a summary.

import Foundation
import XCTest
import PhoneDSHScenario

/// The scenario test class: one static slot per possible selected scenario.
final class PhoneDSHScenarioTests: XCTestCase {
    /// A launcher-started batch may reuse the standard `$TMPDIR` build cache
    /// when the bundle variables were not exported. A plain
    /// `swift test --filter PhoneDSHScenarioTests` on a Mac that has run
    /// `scenarios.sh` before must not: adopting that cache turns the unit gate
    /// into a full catalog run (and, on a locked console, into a nested
    /// simulator build). `ScenarioSlotPlan.shouldAdoptBuildCache` is the one
    /// decision, so both halves are deterministic unit tests and a leftover
    /// cache never authorizes a run by itself.
    override class func setUp() {
        super.setUp()
        let environment = ProcessInfo.processInfo.environment
        guard ScenarioSlotPlan.shouldAdoptBuildCache(environment: environment) else {
            return
        }
        let cache = URL(fileURLWithPath: environment["TMPDIR"] ?? "/tmp", isDirectory: true)
            .appendingPathComponent("pdsh-scenarios-build/www", isDirectory: true)
        let image = cache.appendingPathComponent("image.tar.gz")
        let fileManager = FileManager.default
        if environment["PDSH_DSH_WWW"] == nil,
           fileManager.fileExists(atPath: cache.appendingPathComponent("worker-entry.js").path) {
            setenv("PDSH_DSH_WWW", cache.path, 1)
        }
        if environment["PDSH_DSH_IMAGE"] == nil,
           fileManager.fileExists(atPath: image.path) {
            setenv("PDSH_DSH_IMAGE", image.path, 1)
        }
    }

    /// Selection guard: reports setup errors once and checks the slot capacity.
    ///
    /// The decision lives in `ScenarioSlotPlan.selectionGuard` so both
    /// branches are unit-tested: a plain unit-test process (no launcher input)
    /// skips a setup error, while a provisioned batch with a broken input
    /// fails loud. The catalog/scenario unit tests are part of the plain
    /// unit-test gates, which run without the launcher (no manifest, image or
    /// results root); there is nothing to select there, so skipping keeps that
    /// gate honest instead of failing it for a run it cannot perform.
    @MainActor
    func testScenarioSelectionGuard() async throws {
        let plan = ScenarioSlotPlan.plan
        switch ScenarioSlotPlan.selectionGuard(for: plan) {
        case .proceed:
            return
        case .skip(let reason):
            throw XCTSkip(reason)
        case .fail(let reason):
            XCTFail(reason)
        }
    }

    /// Runs one slot's scenario, or skips when the slot is unused.
    @MainActor
    private func runSlot(_ index: Int) async throws {
        let plan = ScenarioSlotPlan.plan
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
        // The capability matrix was validated when the catalog was loaded
        // (G2-FIX-65). The rejection is threaded through so this run writes an
        // explicit INFRA report instead of starting the product.
        let run = ScenarioRun(scenario: scenario, environment: environment,
                              preflight: plan.infraRejection(for: scenario))
        let report = await run.execute()
        if report.status == "INFRA" {
            // A runner capability gap is not a product verdict. Fail loudly so
            // the batch sees it, but name it as runner-infrastructure and never
            // surface a restart_recovered failure (none was evaluated).
            XCTFail("scenario \(scenario.id) RUNNER-INFRA: "
                + (report.runnerInfra ?? "no runner-infra detail")
                + " (report: \(environment.resultsRoot.appendingPathComponent(scenario.id).path))")
            return
        }
        if report.status == "SKIP" {
            // The environment cannot host a WKWebView page (a locked Mac
            // console); the runner recorded the reason in report.json and the
            // batch's report check still sees a report. This is an XCTSkip, not
            // a pass: the reporter still prints SKIP in the batch summary.
            throw XCTSkip("scenario \(scenario.id) deferred: "
                + (report.deferred ?? report.runnerErrors.first
                    ?? "the environment cannot host a visible WKWebView page"))
        }
        guard report.status == "PASS" else {
            let failed = report.assertions.filter { !$0.ok }
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

    // Slot methods. Keep these methods trivial: XCTest's discovery (and
    // SwiftPM's --filter) only sees static test methods.

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
