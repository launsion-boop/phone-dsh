// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner on the iOS Simulator: support.
//
// Discovers the installed probe app container (`Documents/pdsh-scenarios`) and
// the app's bundled Worker assets (`Bundle/worker`), then resolves the same
// `ScenarioEnvironment` the macOS `swift test` launcher exports. The scenario
// engine itself lives in the regular SwiftPM target
// `PhoneDSHScenario`; this file is suite glue only.
//
// The host driver (`scripts/ci/scenarios.sh --run-on sim`) passes
// `TEST_RUNNER_PDSH_SCENARIO_ROOT` / `TEST_RUNNER_PDSH_SIM_APP_BUNDLE`; both are
// locations, never credentials. The model credentials come only from the
// test-runner environment (`TEST_RUNNER_PDSH_MODEL_*`), never from a staged file.
//
// NOT_VERIFIED on an iPhone: no physical-device run exists.

import Foundation
import PhoneDSH
import PhoneDSHScenario

/// Environment/container discovery for the simulator scenario suite.
enum ScenarioSimSupport {
    /// Bundle identifier of the probe app whose container holds the staged
    /// catalog and receives the per-scenario evidence.
    static let appBundleID = "dev.phone-dsh.probe"
    /// Folder the host driver stages under `Documents/`.
    static let stagingDirectoryName = "pdsh-scenarios"
    /// Worker folder the probe app carries (`examples/.../Bundle/worker`).
    static let workerDirectoryName = "worker"

    /// Process environment of the hostless test runner.
    static var variables: [String: String] { ProcessInfo.processInfo.environment }

    /// Reads an environment variable with or without the `TEST_RUNNER_` prefix.
    static func variable(_ name: String) -> String? {
        for key in ["TEST_RUNNER_\(name)", name] {
            if let value = variables[key], !value.isEmpty { return value }
        }
        return nil
    }

    /// The staged input root: `TEST_RUNNER_PDSH_SCENARIO_ROOT` when the host
    /// driver passed one, otherwise the probe app's
    /// `Documents/pdsh-scenarios/`.
    static func stagingRoot() throws -> URL {
        if let override = variable("PDSH_SCENARIO_ROOT") {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        guard let container = appDataContainer() else {
            throw ScenarioError.environment(
                "the probe app container is not installed; run "
                + "scripts/ci/scenarios.sh --run-on sim (it installs the app)")
        }
        return container.appendingPathComponent("Documents/\(stagingDirectoryName)",
                                                isDirectory: true)
    }

    /// The installed probe app bundle, when the app is installed.
    static func appBundle() -> URL? {
        if let override = variable("PDSH_SIM_APP_BUNDLE") {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        if Bundle.main.bundleIdentifier == appBundleID {
            return Bundle.main.bundleURL
        }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let containers = home.appendingPathComponent("Containers/Bundle/Application",
                                                     isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: containers, includingPropertiesForKeys: nil) else {
            return nil
        }
        for entry in entries {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: entry, includingPropertiesForKeys: nil) else { continue }
            for candidate in contents where candidate.pathExtension == "app" {
                let info = candidate.appendingPathComponent("Info.plist")
                guard let data = try? Data(contentsOf: info),
                      let object = try? PropertyListSerialization.propertyList(
                        from: data, options: [], format: nil),
                      let dictionary = object as? [String: Any],
                      dictionary["CFBundleIdentifier"] as? String == appBundleID else {
                    continue
                }
                return candidate
            }
        }
        return nil
    }

    /// The installed probe app data container, when the app is installed.
    static func appDataContainer() -> URL? {
        if let override = variable("PDSH_SIM_APP_DATA") {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        if home.path.contains("/Containers/Data/Application/") {
            return home
        }
        let containers = home.appendingPathComponent("Containers/Data/Application",
                                                     isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: containers, includingPropertiesForKeys: nil) else {
            return nil
        }
        for entry in entries {
            let metadata = entry.appendingPathComponent(
                ".com.apple.mobile_container_manager.metadata.plist")
            guard let data = try? Data(contentsOf: metadata),
                  let object = try? PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil),
                  let dictionary = object as? [String: Any],
                  dictionary["MCMMetadataIdentifier"] as? String == appBundleID else {
                continue
            }
            return entry
        }
        return nil
    }

    /// The Worker assets the installed app carries: the same `Bundle/worker`
    /// layout the app serves on a device.
    static func workerBundle() throws -> PhoneDSHBundleLocation {
        if let app = appBundle() {
            let worker = app.appendingPathComponent(workerDirectoryName,
                                                    isDirectory: true)
            let bundle = PhoneDSHBundleLocation(staticDirectory: worker)
            if bundle.exists() { return bundle }
        }
        throw ScenarioError.environment(
            "the probe app's Bundle/worker is missing; install the app built by "
            + "scripts/ci/scenarios.sh --run-on sim")
    }
}

/// The selection resolved once per simulator test process.
enum ScenarioSimSlotPlan {
    static let plan: ScenarioSlotPlan.Plan = ScenarioSlotPlan.resolve {
        let root = try ScenarioSimSupport.stagingRoot()
        let bundle = try ScenarioSimSupport.workerBundle()
        return try ScenarioEnvironment.resolveStaged(root: root, workerBundle: bundle)
    }
}
