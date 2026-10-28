// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: the XCTest selection guard.
//
// G2-FIX-65 follow-up: the guard used to decide skip-vs-fail inline in the
// XCTest class, so the fail-loud branch of a *provisioned* batch with a broken
// input could only be checked by launching another batch. The decision now
// lives in `ScenarioSlotPlan.selectionGuard`, and these tests pin both
// branches deterministically:
//   * no launcher input at all = plain unit-test process -> a setup error is
//     an XCTSkip (the catalog/unit-test gates must keep running);
//   * any launcher input present = a real batch -> a setup error, an empty
//     selection or an over-capacity selection fails loud.
//
// These tests need no model, no WKWebView and no host.

import Foundation
import XCTest
@testable import PhoneDSHScenario

final class PhoneDSHScenarioTestsSelectionGuard: XCTestCase {
    private func scenario(id: String = "G2-SELECTION") -> Scenario {
        Scenario(
            id: id,
            category: "selftest",
            title: "selection guard",
            userStory: "a provisioned batch must not degrade into a skip",
            workspace: Scenario.Workspace(files: ["seed.txt": "seed\n"], fixture: nil),
            turns: [Scenario.Turn(prompt: "one")],
            assertions: [],
            rubric: nil,
            budget: Scenario.Budget(maxMinutes: 1, maxModelRequests: 1),
            perturbations: nil,
            mock: nil,
            network: nil,
            tags: ["selftest"],
            target: "macos")
    }

    private func plan(error: String? = nil,
                      scenarios: [Scenario]? = nil) -> ScenarioSlotPlan.Plan {
        ScenarioSlotPlan.Plan(environment: nil,
                              scenarios: scenarios ?? [scenario()],
                              error: error)
    }

    // MARK: Launcher detection

    func testPlainUnitTestProcessHasNoLauncherInput() {
        XCTAssertFalse(ScenarioSlotPlan.launcherEnvironmentIsProvisioned(environment: [:]))
        // Empty values are not inputs: scripts that export a variable empty
        // must not turn a plain unit-test run into a batch.
        XCTAssertFalse(ScenarioSlotPlan.launcherEnvironmentIsProvisioned(
            environment: Dictionary(uniqueKeysWithValues:
                ScenarioSlotPlan.launcherEnvironmentKeys.map { ($0, "") })))
    }

    func testEveryLauncherInputMarksABatch() {
        for key in ScenarioSlotPlan.launcherEnvironmentKeys {
            XCTAssertTrue(
                ScenarioSlotPlan.launcherEnvironmentIsProvisioned(
                    environment: [key: "set"]),
                "\(key) must mark the process as a provisioned scenario batch")
        }
    }

    // MARK: Build-cache adoption (GATE-SLOTS)

    /// A leftover `$TMPDIR/pdsh-scenarios-build/www` cache is not an
    /// authorization to run the catalog. Only a selection input that
    /// `scripts/ci/scenarios.sh` exports may adopt it; the bundle variables are
    /// themselves outputs and do not count.
    func testBuildCacheFallbackRequiresALauncherSelectionInput() {
        XCTAssertFalse(ScenarioSlotPlan.shouldAdoptBuildCache(environment: [:]))
        XCTAssertFalse(ScenarioSlotPlan.shouldAdoptBuildCache(
            environment: ["PDSH_DSH_WWW": "/tmp/pdsh/www",
                          "PDSH_DSH_IMAGE": "/tmp/pdsh/image.tar.gz",
                          "TMPDIR": "/tmp"]))
        XCTAssertFalse(ScenarioSlotPlan.shouldAdoptBuildCache(
            environment: Dictionary(uniqueKeysWithValues:
                ScenarioSlotPlan.launcherEnvironmentKeys.map { ($0, "") })))
        XCTAssertFalse(ScenarioSlotPlan.shouldAdoptBuildCache(
            environment: ["PDSH_DSH_WWW": "/tmp/pdsh/www",
                          "PDSH_DSH_IMAGE": "/tmp/pdsh/image.tar.gz",
                          "PDSH_SCENARIO_ONLY": ""]))

        for key in ScenarioSlotPlan.buildCacheSelectionKeys {
            XCTAssertTrue(ScenarioSlotPlan.shouldAdoptBuildCache(
                environment: [key: "set"]),
                "\(key) must authorize adopting the launcher build cache")
            XCTAssertTrue(ScenarioSlotPlan.launcherEnvironmentKeys.contains(key),
                          "\(key) must also count as a launcher input for the guard")
        }
        XCTAssertFalse(ScenarioSlotPlan.buildCacheSelectionKeys.contains("PDSH_DSH_WWW"))
        XCTAssertFalse(ScenarioSlotPlan.buildCacheSelectionKeys.contains("PDSH_DSH_IMAGE"))
    }

    /// The XCTest glue must route its cache fallback through the same pure
    /// predicate. This is the source-level half of the regression: on the
    /// baseline, `setUp` only checked that `$TMPDIR/.../www` existed and then
    /// exported the bundle variables, so a plain `swift test` on a Mac that had
    /// run `scenarios.sh` executed the catalog.
    func testScenarioSuiteSetUpUsesTheBuildCachePredicate() throws {
        guard let root = scenarioRepositoryRoot(
            startingAt: URL(fileURLWithPath: #filePath)) else {
            return XCTFail("cannot locate the repository root from #filePath")
        }
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Tests/PhoneDSHScenarioTests/PhoneDSHScenarioTests.swift"),
            encoding: .utf8)
        XCTAssertTrue(
            source.contains("ScenarioSlotPlan.shouldAdoptBuildCache(environment: environment)"),
            "PhoneDSHScenarioTests.setUp must authorize the cache fallback")
    }

    /// The plan a plain `swift test` gets has no launcher selection and no
    /// bundle. It must be a skip with zero selected scenarios, never a catalog
    /// run of every slot.
    func testPlainSwiftTestPlanSelectsNoScenariosAndSkips() {
        let plainEnvironment = ["TMPDIR": "/tmp"]
        XCTAssertFalse(ScenarioSlotPlan.shouldAdoptBuildCache(
            environment: plainEnvironment))
        XCTAssertThrowsError(try ScenarioEnvironment.resolve(
            environment: plainEnvironment)) { error in
                XCTAssertTrue(String(describing: error).contains("PDSH_DSH_WWW"),
                              String(describing: error))
            }
        let plain = ScenarioSlotPlan.resolve {
            throw ScenarioError.environment(
                "PDSH_DSH_WWW is not exported; run scenarios.sh")
        }
        XCTAssertTrue(plain.scenarios.isEmpty,
                      "a plain unit-test plan must not select the catalog")
        guard case .skip(let reason) = ScenarioSlotPlan.selectionGuard(
            for: plain, environment: ["TMPDIR": "/tmp"]) else {
            return XCTFail("a plain unit-test plan must skip, got "
                + "\(ScenarioSlotPlan.selectionGuard(for: plain, environment: [:]))")
        }
        XCTAssertTrue(reason.contains("scenario launcher environment is not provisioned"),
                      reason)
    }

    // MARK: Guard decision

    func testPlainUnitTestSetupErrorSkips() {
        let decision = ScenarioSlotPlan.selectionGuard(
            for: plan(error: "PDSH_DSH_IMAGE is not exported"),
            environment: [:])
        guard case .skip(let reason) = decision else {
            return XCTFail("a plain unit-test process must skip, got \(decision)")
        }
        XCTAssertTrue(reason.contains("PDSH_DSH_IMAGE is not exported"), reason)
    }

    /// The fail-loud branch: a real batch (any launcher input present) missing
    /// another input must never be read as "nothing to select".
    func testProvisionedBatchSetupErrorFailsLoud() {
        for present in [
            ["PDSH_SCENARIO_RESULTS": "/tmp/pdsh-scenarios"],
            ["PDSH_SCENARIO_ROOT": "/tmp/repo"],
            ["PDSH_SCENARIO_ONLY": "G2-SELFTEST"],
            ["PDSH_DSH_WWW": "/tmp/www"],
        ] {
            let decision = ScenarioSlotPlan.selectionGuard(
                for: plan(error: "PDSH_DSH_IMAGE is not exported"),
                environment: present)
            XCTAssertEqual(decision, .fail("scenario runner setup failed: "
                + "PDSH_DSH_IMAGE is not exported"),
                "a provisioned batch must keep the setup error loud: \(present)")
        }
    }

    func testUsableSelectionProceeds() {
        XCTAssertEqual(
            ScenarioSlotPlan.selectionGuard(for: plan(), environment: [:]),
            .proceed)
    }

    func testEmptySelectionFailsLoudEvenWithoutLauncherInput() {
        let decision = ScenarioSlotPlan.selectionGuard(
            for: plan(scenarios: []), environment: [:])
        guard case .fail(let reason) = decision else {
            return XCTFail("an empty selection must fail, got \(decision)")
        }
        XCTAssertTrue(reason.contains("no scenario matched"), reason)
    }

    func testOverCapacitySelectionFailsBeforeAnyRun() {
        let scenarios = (0...ScenarioSlotPlan.slotCount).map { scenario(id: "G2-SLOT-\($0)") }
        let decision = ScenarioSlotPlan.selectionGuard(
            for: plan(scenarios: scenarios), environment: [:])
        guard case .fail(let reason) = decision else {
            return XCTFail("an over-capacity selection must fail, got \(decision)")
        }
        XCTAssertTrue(reason.contains("test slots exist"), reason)
        XCTAssertNotNil(ScenarioSlotPlan.capacityError(selectionCount: scenarios.count))
        XCTAssertNil(ScenarioSlotPlan.capacityError(selectionCount: ScenarioSlotPlan.slotCount))
    }
}
