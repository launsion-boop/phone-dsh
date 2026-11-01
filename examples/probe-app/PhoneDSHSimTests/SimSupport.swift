// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS Simulator gate support (PLAN W3-SIM).
//
// Shared by the simulator and hosted physical-device test twins:
//
//   * report directory discovery: the installed probe app's
//     `Documents/pdsh-reports/` container, so `scripts/ci/sim.sh` pulls the
//     reports with `xcrun simctl get_app_container`;
//   * Worker bundle discovery: the same `Bundle/worker/` the app serves on a
//     device, filled by `examples/probe-app/scripts/copy-bundle-assets.sh`;
//   * a one-point visible window for the real WKWebView engine (the engine's
//     attachment precondition);
//   * one PASS/FAIL/INFO row shape for the smoke and kill reports, built on
//     ProbeKit's ``ProbeRow`` so every suite is printed by one table.
//
// Every row is labelled with its actual execution environment. A simulator
// report is never device evidence; a physical run writes a separate report.

import Foundation
import ProbeKit
import UIKit
import PhoneDSH

/// Environment labels shared by the simulator suites.
enum SimEnvironment {
    /// Row/report environment label. `ios-simulator` on the simulator.
    static let label = ProbeEnvironment.current
    /// Human-readable platform name.
    static let platform = ProbeEnvironment.platform
    /// Bundle identifier of the probe app whose container receives reports.
    static let appBundleID = "dev.phone-dsh.probe"
    /// Folder name `scripts/copy-bundle-assets.sh` fills.
    static let workerDirectoryName = "worker"

    /// Process environment of the test runner.
    static var variables: [String: String] { ProcessInfo.processInfo.environment }

    /// `true` when this process is running on the iOS Simulator.
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// Whole-file simulator model identifier when the runtime exports one.
    /// This is a simulator name, never a claim about a physical device.
    static var simulatorModel: String? {
        variables["SIMULATOR_MODEL_IDENTIFIER"]
    }

    static var deviceModel: String {
        if let simulatorModel { return simulatorModel }
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    /// OS version string of the simulator runtime.
    static var systemVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    /// The installed probe app's data container, when the app is installed.
    static func appDataContainer() -> URL? {
        if let override = variables["PDSH_SIM_APP_DATA"], override.isEmpty == false {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        // A hosted run executes inside the app container itself.
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

    /// The installed probe app bundle, when the app is installed.
    static func appBundle() -> URL? {
        if let override = variables["PDSH_SIM_APP_BUNDLE"], override.isEmpty == false {
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

    /// Directory the simulator suites write their JSON reports to.
    ///
    /// Precedence: explicit `PDSH_SIM_REPORTS_DIR`, the probe app's
    /// `Documents/pdsh-reports` container, then the test process's own
    /// `Documents/pdsh-reports`. `scripts/ci/sim.sh` installs the app
    /// before the run and pulls the first path with `get_app_container`.
    static func reportsDirectory() throws -> URL {
        let directory: URL
        if let override = variables["PDSH_SIM_REPORTS_DIR"], override.isEmpty == false {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else if let container = appDataContainer() {
            directory = container.appendingPathComponent("Documents/pdsh-reports",
                                                          isDirectory: true)
        } else {
            let documents = FileManager.default.urls(for: .documentDirectory,
                                                     in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            directory = documents.appendingPathComponent("pdsh-reports", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        return directory
    }

    /// Workspace root handed to ``PhoneDSHHost`` (`Library/xl/<name>`).
    static func workspaceRoot(name: String) -> URL {
        let base: URL
        if let container = appDataContainer() {
            base = container.appendingPathComponent("Library/xl", isDirectory: true)
        } else {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdsh-sim-workspaces", isDirectory: true)
        }
        return base.appendingPathComponent(name, isDirectory: true)
    }

    /// The Worker assets the app bundle carries (or the smoke-script exports).
    ///
    /// The app bundle path is the production layout: the same folder the app
    /// serves on a device. This target carries no copy of its own, so the
    /// suites always exercise the installed app's assets; `sim.sh` installs
    /// the app before running them. `PDSH_DSH_WWW` / `PDSH_DSH_IMAGE` are the
    /// fallback the shell scripts export.
    static func workerBundle() throws -> PhoneDSHBundleLocation {
        if let app = appBundle() {
            let worker = app.appendingPathComponent(workerDirectoryName,
                                                    isDirectory: true)
            let bundle = PhoneDSHBundleLocation(staticDirectory: worker)
            if bundle.exists() { return bundle }
        }
        if let www = variables["PDSH_DSH_WWW"], www.isEmpty == false,
           let image = variables["PDSH_DSH_IMAGE"], image.isEmpty == false {
            let bundle = PhoneDSHBundleLocation(
                staticDirectory: URL(fileURLWithPath: www, isDirectory: true),
                imageArchive: URL(fileURLWithPath: image))
            if bundle.exists() { return bundle }
            throw SimError.environment(
                "PDSH_DSH_WWW / PDSH_DSH_IMAGE were exported but are incomplete")
        }
        let container = appDataContainer()?.path ?? "the probe app is not installed"
        throw SimError.environment(
            "the Worker bundle is missing (\(container)); install the probe app "
            + "and run examples/probe-app/scripts/copy-bundle-assets.sh "
            + "through scripts/ci/sim.sh")
    }
}

/// Fail-loud errors of the simulator suites.
enum SimError: Error, CustomStringConvertible {
    case environment(String)
    case timeout(String)
    case assertion(String)
    case artifact(String)

    var description: String {
        switch self {
        case .environment(let detail): return "simulator environment: \(detail)"
        case .timeout(let detail): return "timeout: \(detail)"
        case .assertion(let detail): return "assertion failed: \(detail)"
        case .artifact(let detail): return "cannot read evidence: \(detail)"
        }
    }
}

/// Converts an untyped metric to ``ProbeValue``.
func simValue(_ value: Any?) -> ProbeValue {
    switch value {
    case let value as Bool: return .bool(value)
    case let value as Int: return .int(value)
    case let value as Int64: return .int(Int(clamping: value))
    case let value as UInt64: return .int(Int(clamping: value))
    case let value as Double: return .double(value)
    case let value as String: return .text(value)
    default: return .null
    }
}

/// G1 gate row: 1 == the acceptance check passed.
func simG1Threshold(_ name: String,
                    measured: Int,
                    gating: Bool = true,
                    source: String = "PLAN §5 G1 and PLAN W3-SIM simulator gate")
    -> ProbeThreshold {
    ProbeThreshold(name: name, value: .int(1), unit: "pass",
                   source: source, comparison: .equals,
                   measured: .int(measured), gating: gating)
}

/// Informational bound: no numeric gate applies, the row never fails a gate.
func simInfoThreshold(_ name: String,
                      source: String = "PLAN W3-SIM: no numeric bound; informational row")
    -> ProbeThreshold {
    ProbeThreshold(name: name, value: .text("n/a"), unit: "",
                   source: source, comparison: .notApplicable,
                   measured: .text("n/a"), gating: false)
}

/// One suite report (smoke or kill) in the same row shape as ProbeKit.
final class SimSuiteReport: @unchecked Sendable {
    let suite: String
    let gate: String
    let directory: URL
    let fileURL: URL

    private let lock = NSLock()
    private var rows: [ProbeRow] = []
    private var phases: [[String: Any]] = []
    private var details: [String: Any] = [:]
    private var console: [String] = []
    private var failure: String?
    private var ok = false

    init(suite: String, gate: String, directory: URL, fileName: String) {
        self.suite = suite
        self.gate = gate
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(fileName)
    }

    // MARK: - Recording

    func record(_ probe: String,
                status: ProbeStatus,
                gating: Bool,
                metrics: [String: ProbeValue] = [:],
                threshold: ProbeThreshold?,
                detail: String = "") {
        let row = ProbeRow.suiteRow(probe: probe, kind: suite, status: status,
                                    gating: gating, metrics: metrics,
                                    threshold: threshold, detail: detail,
                                    environment: SimEnvironment.label)
        lock.lock()
        rows.append(row)
        lock.unlock()
        writeQuietly()
    }

    /// Untyped-metrics overload used by the suites.
    func record(_ probe: String,
                status: ProbeStatus,
                gating: Bool,
                metrics: [String: Any],
                threshold: ProbeThreshold?,
                detail: String = "") {
        var converted: [String: ProbeValue] = [:]
        for (key, value) in metrics { converted[key] = simValue(value) }
        record(probe, status: status, gating: gating, metrics: converted,
               threshold: threshold, detail: detail)
    }

    func addPhase(_ name: String, milliseconds: Double, ok: Bool = true) {
        lock.lock()
        phases.append(["name": name, "duration_ms": milliseconds, "ok": ok])
        lock.unlock()
    }

    func set(_ key: String, _ value: Any) {
        lock.lock()
        details[key] = value
        lock.unlock()
    }

    func addConsole(_ line: String) {
        lock.lock()
        console.append(line)
        lock.unlock()
    }

    func addConsole(lines: [String]) {
        lock.lock()
        console.append(contentsOf: lines)
        lock.unlock()
    }

    func finish(ok: Bool, failure: String? = nil) {
        lock.lock()
        self.ok = ok
        self.failure = failure
        lock.unlock()
    }

    // MARK: - Summary

    var gatingFailedProbes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return rows.filter { $0.gating && $0.status == .fail }.map(\.probe)
    }

    var passCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return rows.filter { $0.status == .pass }.count
    }

    var failCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return rows.filter { $0.status == .fail }.count
    }

    var infoCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return rows.filter { $0.status == .info }.count
    }

    var consoleTail: [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(console.suffix(50))
    }

    // MARK: - Writing

    /// Writes the report atomically and returns its URL.
    @discardableResult
    func write() throws -> URL {
        lock.lock()
        let snapshotRows = rows
        let snapshotPhases = phases
        let snapshotDetails = details
        let snapshotConsole = console
        let snapshotFailure = failure
        let snapshotOK = ok
        lock.unlock()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let rowObjects: [[String: Any]]
        do {
            let data = try encoder.encode(snapshotRows)
            rowObjects = (try JSONSerialization.jsonObject(with: data)
                          as? [[String: Any]]) ?? []
        } catch {
            throw SimError.artifact("the \(suite) rows are not JSON: \(error)")
        }
        let pass = snapshotRows.filter { $0.status == .pass }.count
        let fail = snapshotRows.filter { $0.status == .fail }.count
        let info = snapshotRows.filter { $0.status == .info }.count
        let gatingFailed = snapshotRows.filter { $0.gating && $0.status == .fail }
            .map(\.probe)
        var document: [String: Any] = [
            "schema": 1,
            "suite": suite,
            "gate": gate,
            "environment": SimEnvironment.label,
            "platform": SimEnvironment.platform,
            "os_version": SimEnvironment.systemVersion,
            "generated_at": ProbeReport.timestamp(),
            "ok": snapshotOK && gatingFailed.isEmpty,
            "device": [
                "model": SimEnvironment.deviceModel,
                "system": SimEnvironment.systemVersion,
                "is_simulator": SimEnvironment.isSimulator,
            ],
            "summary": [
                "pass": pass, "fail": fail, "info": info,
                "gating_failed": gatingFailed,
                "gate_passed": gatingFailed.isEmpty,
            ],
            "rows": rowObjects,
            "phases": snapshotPhases,
            "console_count": snapshotConsole.count,
            "console_last_50": Array(snapshotConsole.suffix(50)),
        ]
        if let snapshotFailure { document["failure"] = snapshotFailure }
        for (key, value) in snapshotDetails { document[key] = value }
        guard JSONSerialization.isValidJSONObject(document) else {
            throw SimError.artifact("the \(suite) report is not a JSON object")
        }
        let data = try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    /// Best-effort write after every row so a crash still leaves evidence.
    private func writeQuietly() {
        _ = try? write()
    }
}

/// Polls `condition` until it is true or `timeout` elapses.
func simWait(timeout: TimeInterval,
             label: String,
             interval: TimeInterval = 0.05,
             _ condition: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if try await condition() { return }
        if Date() >= deadline {
            throw SimError.timeout("\(label) did not complete within \(Int(timeout)) s")
        }
        try await Task.sleep(nanoseconds: UInt64(max(0.01, interval) * 1_000_000_000))
    }
}

/// A one-point visible host view inside a real ``UIWindow``.
///
/// The WebEngine refuses to boot unless its view is attached to a window with
/// at least one visible point (PLAN §2.5). A hostless simulator test has no
/// App scene, so the suite builds the smallest window that satisfies that
/// precondition. NOT_VERIFIED on a physical iPhone.
@MainActor
final class SimVisibleWindow {
    let window: UIWindow
    let rootController: UIViewController
    /// The one-point anchor the host/probe engine attaches to.
    let anchor: UIView

    init(size: CGSize = CGSize(width: 360, height: 320)) {
        window = UIWindow(frame: CGRect(origin: .zero, size: size))
        rootController = UIViewController()
        anchor = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        window.rootViewController = rootController
        window.makeKeyAndVisible()
        rootController.view.frame = window.bounds
        rootController.view.backgroundColor = .white
        anchor.backgroundColor = .clear
        anchor.isUserInteractionEnabled = false
        anchor.isAccessibilityElement = false
        rootController.view.addSubview(anchor)
        window.layoutIfNeeded()
    }

    /// Whether the anchor is attached to a window (the engine precondition).
    var isAttached: Bool { anchor.window != nil }

    func shutdown() {
        anchor.subviews.forEach { $0.removeFromSuperview() }
        anchor.removeFromSuperview()
        window.isHidden = true
        window.rootViewController = nil
    }
}
