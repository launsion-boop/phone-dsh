// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: perturbation capability matrix
// and the runner-INFRA result.
//
// Regression for G2-FIX-65. Before the fix the runner attempted every
// perturbation kind from the catalog blindly and only discovered an
// unexecutable kind at verdict time: it wrote an `ok: null` perturbation
// report and the `restart_recovered` assertion failed, so a runner capability
// gap was reported as a product recovery failure. The scenario was never
// started and the product had no chance to fail.
//
// The fix has two halves, both pinned here:
//   * a capability matrix declared per execution target (macOS `swift test`,
//     iOS Simulator, iOS device) is validated before the run starts;
//   * an unsupported kind aborts that scenario as an explicit runner-INFRA
//     result: report status `INFRA`, the declarations visible in
//     `perturbations`, and no `restart_recovered` assertion evaluated at all.
//
// These tests need no model, no WKWebView and no host: they are deterministic
// and run in the plain `swift test` gate.

import Foundation
import XCTest
@testable import PhoneDSHScenario

final class PhoneDSHScenarioTestsPerturbationCapabilities: XCTestCase {
    // MARK: Fixtures

    private func scenario(id: String = "G2-INFRA-REGRESSION",
                          perturbations: [Scenario.Perturbation]) -> Scenario {
        Scenario(
            id: id,
            category: "selftest",
            title: "capability matrix regression",
            userStory: "the runner must never report its own gap as a product failure",
            workspace: Scenario.Workspace(files: ["notes.txt": "seed\n"], fixture: nil),
            turns: [Scenario.Turn(prompt: "one"), Scenario.Turn(prompt: "two")],
            assertions: [
                Scenario.Assertion(type: "restart_recovered", path: nil, value: nil,
                                   command: nil, max: nil),
            ],
            rubric: nil,
            budget: Scenario.Budget(maxMinutes: 1, maxModelRequests: 2),
            perturbations: perturbations,
            mock: nil,
            network: nil,
            tags: ["selftest"],
            target: "both")
    }

    private func environment(id: String) -> ScenarioEnvironment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-scenario-infra-\(UUID().uuidString)",
                                    isDirectory: true)
        return ScenarioEnvironment(
            repoRoot: root,
            catalogURL: root.appendingPathComponent("catalog.json"),
            resultsRoot: root.appendingPathComponent("results", isDirectory: true),
            fixturesRoot: root.appendingPathComponent("fixtures", isDirectory: true),
            only: [id],
            tag: nil,
            target: "both",
            upstream: "mock",
            keepBodies: false,
            staticDirectory: root.appendingPathComponent("www", isDirectory: true),
            imageArchive: root.appendingPathComponent("image.tar.gz"),
            modelBaseURL: nil,
            modelName: nil,
            modelAPIKey: nil)
    }

    // MARK: Matrix

    func testMatrixDeclaresTheSameFourKindsForEveryTarget() {
        let all: Set<String> = ["planned_restart", "park_resume", "worker_kill",
                                "webcontent_kill"]
        for target in [ScenarioExecutionTarget.macOSSwiftTest, .iOSSimulator] {
            let matrix = ScenarioPerturbationCapabilities.capabilities(for: target,
                                                                       environment: [:])
            XCTAssertEqual(matrix.target, target)
            XCTAssertEqual(matrix.declaredKinds, all,
                           "the declared matrix for \(target.rawValue) must name every "
                           + "catalog kind; a missing declaration is the blind-attempt bug")
        }
        // The physical device has no watcher mechanism in this repository; the
        // kind is deliberately not declared, which makes it an INFRA rejection
        // instead of a run that discovers it could not kill anything.
        let device = ScenarioPerturbationCapabilities.capabilities(for: .iOSDevice,
                                                                   environment: [:])
        XCTAssertEqual(device.declaredKinds,
                       ["planned_restart", "park_resume", "worker_kill"])
    }

    func testMacOSRunnerCanExecuteEveryKindIncludingWebContentKill() {
        let matrix = ScenarioPerturbationCapabilities.capabilities(
            for: .macOSSwiftTest, environment: [:])
        for kind in ["planned_restart", "park_resume", "worker_kill", "webcontent_kill"] {
            XCTAssertTrue(matrix.supports(kind), "macOS must support \(kind)")
        }
        let capability = matrix.capability(for: "webcontent_kill")
        XCTAssertEqual(capability?.mechanism, .hostWebContentSIGKILL,
                       "the macOS webcontent kill must resolve and SIGKILL the "
                       + "WebContent process; no simulator fallback is acceptable")
        XCTAssertEqual(capability?.requiresExternalWatcher, false)
    }

    func testSimulatorWebContentKillRequiresTheArmedDeviceWatcher() {
        let unarmed = ScenarioPerturbationCapabilities.capabilities(
            for: .iOSSimulator, environment: [:])
        XCTAssertFalse(unarmed.supports("webcontent_kill"),
                       "the simulator test process cannot signal WebContent by itself")
        XCTAssertTrue(unarmed.supports("planned_restart"))
        XCTAssertTrue(unarmed.supports("park_resume"))
        XCTAssertTrue(unarmed.supports("worker_kill"))
        let declared = unarmed.declaredCapability(for: "webcontent_kill")
        XCTAssertEqual(declared?.mechanism, .simulatorWebContentWatcher,
                       "the declared simulator mechanism is the device-scoped watcher")
        XCTAssertEqual(declared?.requiresExternalWatcher, true)

        let armed = ScenarioPerturbationCapabilities.capabilities(
            for: .iOSSimulator,
            environment: ["PDSH_SCENARIO_WEBCONTENT_WATCH": "1"])
        XCTAssertTrue(armed.supports("webcontent_kill"),
                      "the batch driver arms the watcher; the runner must then accept "
                      + "the kind instead of reporting it unavailable")
    }

    func testDeviceRunnerDoesNotClaimTheSimulatorWatcherMechanism() {
        let matrix = ScenarioPerturbationCapabilities.capabilities(
            for: .iOSDevice,
            environment: ["PDSH_SCENARIO_WEBCONTENT_WATCH": "1"])
        XCTAssertFalse(matrix.supports("webcontent_kill"),
                       "a physical device cannot be signalled by the simulator watcher; "
                       + "claiming it would reintroduce the blind attempt")
    }

    // MARK: Pre-run validation

    func testPreflightRejectsUnsupportedKindWithTheRunnerInfraClassification() {
        let scenario = scenario(perturbations: [
            Scenario.Perturbation(at: "after_turn:3", kind: "webcontent_kill"),
        ])
        let matrix = ScenarioPerturbationCapabilities.capabilities(
            for: .iOSSimulator, environment: [:])
        guard let rejection = ScenarioPerturbationPreflight.rejection(
            for: scenario, capabilities: matrix) else {
            return XCTFail("the simulator without the watcher must reject webcontent_kill")
        }
        XCTAssertEqual(rejection.scenarioID, scenario.id)
        XCTAssertEqual(rejection.target, .iOSSimulator)
        XCTAssertEqual(rejection.perturbations.map(\.kind), ["webcontent_kill"])
        XCTAssertEqual(rejection.perturbations.map(\.at), ["after_turn:3"])
        XCTAssertTrue(rejection.detail.hasPrefix("runner-infra:"), rejection.detail)
        XCTAssertTrue(rejection.detail.contains("webcontent_kill"), rejection.detail)
        XCTAssertTrue(rejection.detail.contains("ios-simulator"), rejection.detail)
    }

    func testPreflightRejectsUnknownKindAndUnknownPointUniformly() {
        let unknownKind = scenario(id: "G2-INFRA-UNKNOWN-KIND", perturbations: [
            Scenario.Perturbation(at: "after_turn:1", kind: "host_meltdown"),
        ])
        let unknownPoint = scenario(id: "G2-INFRA-UNKNOWN-POINT", perturbations: [
            Scenario.Perturbation(at: "during_second_tool", kind: "planned_restart"),
        ])
        let matrix = ScenarioPerturbationCapabilities.capabilities(
            for: .macOSSwiftTest, environment: [:])
        for candidate in [unknownKind, unknownPoint] {
            let rejection = ScenarioPerturbationPreflight.rejection(
                for: candidate, capabilities: matrix)
            XCTAssertNotNil(rejection, "\(candidate.id) must be rejected at load")
            XCTAssertEqual(rejection?.scenarioID, candidate.id)
            XCTAssertEqual(rejection?.target, .macOSSwiftTest)
            XCTAssertTrue(rejection?.detail.hasPrefix("runner-infra:") ?? false,
                          rejection?.detail ?? "no detail")
            XCTAssertEqual(rejection?.perturbations.count, 1)
        }
    }

    func testPreflightRejectsOnlyTheDeclarationThatCannotRun() {
        let mixed = scenario(id: "G2-INFRA-PARTIAL", perturbations: [
            Scenario.Perturbation(at: "after_turn:1", kind: "planned_restart"),
            Scenario.Perturbation(at: "after_turn:2", kind: "webcontent_kill"),
        ])
        let matrix = ScenarioPerturbationCapabilities.capabilities(
            for: .iOSSimulator, environment: [:])
        let rejection = ScenarioPerturbationPreflight.rejection(
            for: mixed, capabilities: matrix)
        XCTAssertEqual(rejection?.perturbations.map(\.kind), ["webcontent_kill"],
                       "only the unexecutable declaration is named")
        XCTAssertEqual(rejection?.perturbations.map(\.at), ["after_turn:2"])
    }

    // MARK: INFRA report instead of a restart_recovered verdict

    @MainActor
    func testUnsupportedKindProducesAnInfraReportWithoutARestartRecoveredVerdict() async throws {
        let scenario = scenario(id: "G2-INFRA-REPORT", perturbations: [
            Scenario.Perturbation(at: "after_turn:3", kind: "webcontent_kill"),
            Scenario.Perturbation(at: "after_turn:1", kind: "planned_restart"),
        ])
        let matrix = ScenarioPerturbationCapabilities.capabilities(
            for: .iOSSimulator, environment: [:])
        let run = ScenarioRun(scenario: scenario,
                              environment: environment(id: scenario.id),
                              capabilities: matrix)
        let report = await run.execute()

        XCTAssertEqual(report.status, "INFRA",
                       "an unexecutable declaration is a runner-infra result, "
                       + "never PASS/FAIL/SKIP")
        XCTAssertNotNil(report.runnerInfra)
        XCTAssertTrue(report.assertions.isEmpty,
                      "the run never started: no assertion — least of all "
                      + "restart_recovered — may be evaluated")
        XCTAssertFalse(report.assertions.contains {
            $0.type == "restart_recovered" && !$0.ok
        }, "the infra gap must not be reported as a product recovery failure")
        XCTAssertEqual(report.perturbations.count, 2)
        for entry in report.perturbations {
            XCTAssertEqual(entry.status, "runner_infra", entry.detail ?? "")
            XCTAssertNil(entry.ok)
        }
        let webContent = report.perturbations.first { $0.kind == "webcontent_kill" }
        XCTAssertEqual(webContent?.at, "after_turn:3")
        XCTAssertTrue(webContent?.detail?.contains("ios-simulator") ?? false,
                      webContent?.detail ?? "no detail")
        XCTAssertFalse(report.runCompleted,
                       "an INFRA abort is not a completed run")

        // The schema the judge and the batch driver read: report status INFRA,
        // runner_infra present, every declaration visible with the infra status.
        let encoded = try JSONEncoder().encode(report)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "INFRA")
        XCTAssertNotNil(object["runner_infra"], "report.json must carry runner_infra")
        let perturbations = try XCTUnwrap(object["perturbations"] as? [[String: Any]])
        XCTAssertEqual(perturbations.count, 2)
        for entry in perturbations {
            XCTAssertEqual(entry["status"] as? String, "runner_infra")
            XCTAssertNil(entry["ok"], "an infra declaration has no applied result")
        }
    }

    // MARK: The shipped catalog

    func testPreflightAcceptsTheShippedCatalogWhenEveryKindIsSupported() throws {
        let root = scenarioRepositoryRoot(startingAt: URL(fileURLWithPath: #filePath))
        let catalog = try ScenarioCatalog.load(
            from: try XCTUnwrap(root,
                                "cannot locate the repository root from #filePath")
                .appendingPathComponent("scripts/ci/scenarios/catalog.json"))
        let matrix = ScenarioPerturbationCapabilities.capabilities(
            for: .macOSSwiftTest, environment: [:])
        let rejections = ScenarioPerturbationPreflight.rejections(
            in: catalog.scenarios, capabilities: matrix)
        XCTAssertTrue(rejections.isEmpty,
                      "the macOS runner declares every catalog kind: \(rejections.keys.sorted())")
    }

    /// The D06 class: every shipped scenario that declares `webcontent_kill`
    /// (not one hardcoded id) is rejected at load on an unarmed simulator,
    /// with the runner-INFRA classification. No scenario can reach the old
    /// "not available" verdict path.
    func testShippedWebContentKillScenariosAreRejectedAtLoadOnAnUnarmedSimulator() throws {
        let root = try XCTUnwrap(
            scenarioRepositoryRoot(startingAt: URL(fileURLWithPath: #filePath)),
            "cannot locate the repository root from #filePath")
        let catalog = try ScenarioCatalog.load(
            from: root.appendingPathComponent("scripts/ci/scenarios/catalog.json"))
        let matrix = ScenarioPerturbationCapabilities.capabilities(
            for: .iOSSimulator, environment: [:])
        let declaring = catalog.scenarios.filter { scenario in
            (scenario.perturbations ?? []).contains { $0.kind == "webcontent_kill" }
        }
        XCTAssertFalse(declaring.isEmpty,
                       "the shipped catalog must contain at least one webcontent_kill "
                       + "scenario for this regression to exercise")
        let rejections = ScenarioPerturbationPreflight.rejections(
            in: catalog.scenarios, capabilities: matrix)
        for scenario in declaring {
            guard let rejection = rejections[scenario.id] else {
                XCTFail("\(scenario.id) was not rejected before the run")
                continue
            }
            XCTAssertEqual(rejection.target, .iOSSimulator)
            XCTAssertTrue(rejection.perturbations.contains {
                $0.kind == "webcontent_kill"
            }, "\(scenario.id): the rejection must name the kill declaration")
            XCTAssertTrue(rejection.detail.hasPrefix("runner-infra:"),
                          "\(scenario.id): \(rejection.detail)")
        }
        // The armed watcher flips the same class to supported: the matrix is
        // the only switch, not a scenario id.
        let armed = ScenarioPerturbationCapabilities.capabilities(
            for: .iOSSimulator,
            environment: ["PDSH_SCENARIO_WEBCONTENT_WATCH": "1"])
        let armedRejections = ScenarioPerturbationPreflight.rejections(
            in: catalog.scenarios, capabilities: armed)
        for scenario in declaring {
            XCTAssertNil(armedRejections[scenario.id],
                         "\(scenario.id): the armed watcher must make the "
                         + "declaration executable")
        }
    }
}
