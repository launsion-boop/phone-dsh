// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: the XCTest slot plan.
//
// SwiftPM's `--filter` does not honour a dynamic `defaultTestSuite`, so the
// catalog selection is mapped onto a fixed bank of static XCTest slot methods:
// slot 0 is the selection guard, slots 1...N run the selected scenarios in
// order, and unused slots skip. This used to live in the macOS test target;
// it is in the regular library so the macOS and iOS Simulator suites share one
// implementation (W13-SIM-SCENARIOS).

import Foundation

/// The selection resolved once per test process.
public enum ScenarioSlotPlan {
    /// Number of scenario slots (the shipped catalog currently has 56;
    /// headroom for catalog growth is deliberate, unused slots skip).
    ///
    /// The macOS (`Tests/PhoneDSHScenarioTests`) and iOS Simulator
    /// (`examples/probe-app/PhoneDSHScenarioSimTests`) XCTest suites
    /// mirror this count with static `testScenarioSlotNN` methods and the shared
    /// `capacityError` check; change all three together.
    public static let slotCount = 64

    public struct Plan: Sendable {
        public var environment: ScenarioEnvironment?
        public var scenarios: [Scenario]
        public var error: String?
        /// Per-scenario runner-INFRA rejections computed when the catalog was
        /// loaded, before any slot executed (G2-FIX-65). A selected scenario in
        /// this map must abort as an INFRA report, never as a product verdict.
        public var infraRejections: [String: ScenarioInfraRejection]

        public init(environment: ScenarioEnvironment?,
                    scenarios: [Scenario],
                    error: String?,
                    infraRejections: [String: ScenarioInfraRejection] = [:]) {
            self.environment = environment
            self.scenarios = scenarios
            self.error = error
            self.infraRejections = infraRejections
        }

        /// The load-time rejection for one selected scenario, when any.
        public func infraRejection(for scenario: Scenario) -> ScenarioInfraRejection? {
            infraRejections[scenario.id]
        }
    }

    /// Capacity check shared by the macOS and iOS Simulator suites.
    ///
    /// Returns a failure description when the selection cannot be mapped onto
    /// the fixed slot bank, `nil` when it fits. Both suites evaluate this
    /// before executing any scenario, so an over-capacity selection rejects the
    /// whole batch instead of running the first `slotCount` scenarios and
    /// leaving the report check to notice the missing reports.
    public static func capacityError(selectionCount: Int) -> String? {
        guard selectionCount > slotCount else { return nil }
        return "the selection has \(selectionCount) scenarios but only "
            + "\(slotCount) test slots exist"
    }

    // MARK: Selection guard

    /// Inputs only the scenario launcher sets (`scripts/ci/scenarios.sh`).
    /// The plain catalog/unit-test gates run without any of them.
    public static let launcherEnvironmentKeys = [
        "PDSH_DSH_WWW", "PDSH_DSH_IMAGE",
        "PDSH_SCENARIO_ROOT", "PDSH_SCENARIO_CATALOG", "PDSH_SCENARIO_RESULTS",
        "PDSH_SCENARIO_ONLY", "PDSH_SCENARIO_TAG", "PDSH_SCENARIO_TARGET",
        "PDSH_SCENARIO_UPSTREAM", "PDSH_SCENARIO_FIXTURES",
    ]

    /// The launcher inputs that select a catalog run. The bundle locations
    /// (`PDSH_DSH_WWW`/`PDSH_DSH_IMAGE`) are deliberately absent: they are the
    /// build cache's outputs, not evidence that this process was launched for a
    /// scenario batch.
    public static let buildCacheSelectionKeys = [
        "PDSH_SCENARIO_ONLY", "PDSH_SCENARIO_TAG", "PDSH_SCENARIO_TARGET",
        "PDSH_SCENARIO_ROOT", "PDSH_SCENARIO_RESULTS", "PDSH_SCENARIO_CATALOG",
        "PDSH_SCENARIO_FIXTURES", "PDSH_SCENARIO_UPSTREAM",
    ]

    /// `true` when the process carries at least one input that only the
    /// scenario launcher sets. An empty process is a plain unit-test
    /// invocation: the catalog/scenario unit tests run there, so a setup error
    /// is an explicit XCTSkip. As soon as any launcher input is present the
    /// setup error must fail loud: a real batch with a missing input must
    /// never silently degrade into a skip. Injectable so this branch is
    /// testable without spawning a second `swift test`.
    public static func launcherEnvironmentIsProvisioned(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        launcherEnvironmentKeys.contains { key in
            !(environment[key] ?? "").isEmpty
        }
    }

    /// `true` only for a launcher-started batch, when the standard
    /// `$TMPDIR/pdsh-scenarios-build` cache may safely stand in for an
    /// unexported `PDSH_DSH_WWW`/`PDSH_DSH_IMAGE`.
    ///
    /// A plain `swift test` on a Mac that has run `scenarios.sh` before still
    /// sees that cache. Adopting it there would turn the unit gate into a full
    /// catalog run (and, on a locked console, into a nested simulator build),
    /// so only the launcher's own selection inputs authorize the fallback. An
    /// empty value is not an input; `PDSH_DSH_WWW`/`PDSH_DSH_IMAGE` alone do
    /// not authorize it either.
    public static func shouldAdoptBuildCache(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        buildCacheSelectionKeys.contains { key in
            !(environment[key] ?? "").isEmpty
        }
    }

    /// How the XCTest guard must treat a resolved plan.
    public enum SelectionGuard: Equatable, Sendable {
        /// The selection is usable; the slots run (or skip when unused).
        case proceed
        /// A plain unit-test process with no launcher input: no scenario can
        /// run here, so a setup error is not a batch failure.
        case skip(String)
        /// A provisioned batch whose setup/selection is broken: fail loud.
        case fail(String)
    }

    /// The guard decision for a plan, separated from the XCTest glue so both
    /// the skip and the fail-loud branch are deterministic unit tests.
    ///
    /// A setup error is only a skip when no launcher input is present; any
    /// launcher input marks a real batch and keeps the failure loud. An empty
    /// selection and an over-capacity selection always fail.
    public static func selectionGuard(
        for plan: Plan,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SelectionGuard {
        if let error = plan.error {
            guard launcherEnvironmentIsProvisioned(environment: environment) else {
                return .skip("the scenario launcher environment is not provisioned "
                    + "(PDSH_DSH_WWW / PDSH_DSH_IMAGE / PDSH_SCENARIO_*); run "
                    + "scripts/ci/scenarios.sh for a scenario run: \(error)")
            }
            return .fail("scenario runner setup failed: \(error)")
        }
        if plan.scenarios.isEmpty {
            return .fail("no scenario matched the catalog selection "
                + "(only=\(plan.environment?.only ?? []), "
                + "tag=\(plan.environment?.tag ?? "-"), "
                + "target=\(plan.environment?.target ?? "-"))")
        }
        if let capacityError = capacityError(selectionCount: plan.scenarios.count) {
            return .fail(capacityError)
        }
        return .proceed
    }

    /// Resolves the environment, loads the catalog and applies the selection.
    /// A setup error is carried in the plan so the guard test reports it once.
    public static func resolve(
        with resolver: () throws -> ScenarioEnvironment
    ) -> Plan {
        do {
            let environment = try resolver()
            let catalog = try ScenarioCatalog.load(from: environment.catalogURL)
            // G2-FIX-65: validate every declaration before a slot can run. The
            // capability matrix is fixed by the execution target (and, on the
            // simulator, by the armed watcher), so this classification is final
            // at load: no run can discover "not available" at verdict time.
            let rejections = catalog.perturbationRejections(
                capabilities: environment.perturbationCapabilities)
            let scenarios = environment.select(from: catalog)
            return Plan(environment: environment,
                        scenarios: scenarios,
                        error: nil,
                        infraRejections: rejections)
        } catch {
            return Plan(environment: nil, scenarios: [], error: String(describing: error))
        }
    }

    /// The macOS `swift test` plan: environment from the launcher.
    public static let plan: Plan = resolve { try ScenarioEnvironment.resolve() }
}
