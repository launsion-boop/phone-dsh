// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: the perturbation capability
// matrix, the pre-run validation that uses it, and the simulator WebContent
// kill transport.
//
// Root cause (G2-FIX-65): the perturbation executor attempted every kind a
// catalog scenario declared, blindly. A kind the current execution target
// cannot realize was discovered only after the run had started (or, worse, at
// verdict time): the runner wrote an `ok: null` perturbation report and
// `restart_recovered` failed, so a test-infrastructure gap was reported as a
// product recovery failure and the scenario had zero perturbation coverage.
//
// The fix declares, per execution target, which perturbation kinds the runner
// can execute and through which mechanism. ``ScenarioPerturbationPreflight``
// validates every declared perturbation at catalog load, before the run starts;
// an unexecutable declaration aborts that scenario as a runner-INFRA result
// (report status `INFRA`) and no assertion is evaluated.
//
// The `webcontent_kill` mechanism is target-specific:
//   * macOS `swift test`: the runner resolves the WKWebView's WebContent child
//     process (the one holding the loopback connection) and SIGKILLs it; the
//     engine's `webViewWebContentProcessDidTerminate` path then runs the real
//     D14 recovery.
//   * iOS Simulator: the sandboxed test process cannot signal a host process.
//     `scripts/ci/scenarios.sh --run-on sim` arms the same device-scoped
//     watcher `scripts/ci/sim.sh` uses; the runner writes a handshake
//     request and the host script SIGKILLs the selected simulator's WebContent.
//     Without the armed watcher the kind is not supported and validation
//     rejects it before the run.
//
// No scenario id, prompt or file name appears here.

import Foundation

// MARK: - Execution target

/// The target a scenario run actually executes on.
///
/// This is distinct from the catalog's `target` field, which only selects which
/// scenarios a batch operator wants (`macos` / `sim` / `both`). Capabilities are
/// decided by the physical target that executes the run.
public enum ScenarioExecutionTarget: String, CaseIterable, Sendable {
    /// The macOS XCTest process (`swift test --filter PhoneDSHScenario`).
    case macOSSwiftTest = "macos-swift-test"
    /// A hostless XCTest bundle inside the iOS Simulator.
    case iOSSimulator = "ios-simulator"
    /// A physical iPhone/iPad test runner (NOT_VERIFIED in this repository).
    case iOSDevice = "ios-device"

    /// The target this process executes on.
    public static var current: ScenarioExecutionTarget {
        #if os(macOS)
        return .macOSSwiftTest
        #elseif targetEnvironment(simulator)
        return .iOSSimulator
        #else
        return .iOSDevice
        #endif
    }

    /// The mechanism label written into a report.
    public var reportName: String { rawValue }
}

// MARK: - Mechanism

/// How a perturbation kind is realized on an execution target.
public enum ScenarioPerturbationMechanism: String, Sendable {
    /// A facade call (`plannedRestart` / `park`+`resume`) drives the host's own
    /// recovery path.
    case hostCall = "host-call"
    /// The page's Worker execution context is terminated and the host rebuilds
    /// the page through its standard restart path.
    case pageWorkerTerminate = "page-worker-terminate"
    /// Resolve the connected macOS WebContent process and SIGKILL it; the
    /// engine's termination callback drives D14 recovery.
    case hostWebContentSIGKILL = "host-webcontent-sigkill"
    /// The test process writes a handshake request; the host-side device-scoped
    /// watcher SIGKILLs the selected simulator's WebContent process.
    case simulatorWebContentWatcher = "simulator-webcontent-watcher"
}

// MARK: - Capabilities

/// One declared perturbation kind and its mechanism on one target.
public struct ScenarioPerturbationCapability: Equatable, Sendable {
    public var kind: String
    public var mechanism: ScenarioPerturbationMechanism
    /// The mechanism is an external watcher that must be armed by the batch
    /// driver; without it the kind cannot be executed.
    public var requiresExternalWatcher: Bool
    /// Why the mechanism is unavailable when it requires an unarmed watcher.
    public var unavailableReason: String?

    public init(kind: String,
                mechanism: ScenarioPerturbationMechanism,
                requiresExternalWatcher: Bool = false,
                unavailableReason: String? = nil) {
        self.kind = kind
        self.mechanism = mechanism
        self.requiresExternalWatcher = requiresExternalWatcher
        self.unavailableReason = unavailableReason
    }
}

/// The perturbation capability matrix for one execution target.
///
/// The declared matrix names every kind the runner knows how to execute on a
/// target. The effective matrix removes kinds whose external mechanism is not
/// armed for this run (`webcontent_kill` on the simulator without the watcher);
/// preflight uses the effective matrix, while the declared entries stay visible
/// in the rejection detail so an operator can tell "unknown kind" from
/// "known kind, watcher not armed".
public struct ScenarioPerturbationCapabilities: Equatable, Sendable {
    /// Environment variable set by `scripts/ci/scenarios.sh --run-on sim`
    /// after it starts the device-scoped WebContent watcher.
    public static let simulatorWatcherEnvironmentKey = "PDSH_SCENARIO_WEBCONTENT_WATCH"

    public var target: ScenarioExecutionTarget
    /// `true` when the device-scoped watcher handshake is available for this
    /// simulator run. Ignored by the other targets.
    public var simulatorWatcherArmed: Bool

    private var declared: [String: ScenarioPerturbationCapability]
    private var effective: [String: ScenarioPerturbationCapability]

    private init(target: ScenarioExecutionTarget,
                 simulatorWatcherArmed: Bool,
                 declared: [String: ScenarioPerturbationCapability],
                 effective: [String: ScenarioPerturbationCapability]) {
        self.target = target
        self.simulatorWatcherArmed = simulatorWatcherArmed
        self.declared = declared
        self.effective = effective
    }

    /// Every kind the runner declares for this target, regardless of the
    /// current run's arming.
    public var declaredKinds: Set<String> { Set(declared.keys) }

    /// Kinds executable on this target in this run.
    public var supportedKinds: Set<String> { Set(effective.keys) }

    /// The effective capability, or `nil` when the kind cannot run now.
    public func capability(for kind: String) -> ScenarioPerturbationCapability? {
        effective[kind]
    }

    /// The declared capability, even when an external mechanism is unarmed.
    public func declaredCapability(for kind: String) -> ScenarioPerturbationCapability? {
        declared[kind]
    }

    public func supports(_ kind: String) -> Bool {
        effective[kind] != nil
    }

    /// Resolves the matrix for a target and process environment.
    ///
    /// `environment` is injectable so the selection is unit-testable.
    public static func capabilities(
        for target: ScenarioExecutionTarget,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ScenarioPerturbationCapabilities {
        let armed = watcherArmed(environment)
        var declared: [String: ScenarioPerturbationCapability] = [
            "planned_restart": ScenarioPerturbationCapability(
                kind: "planned_restart", mechanism: .hostCall),
            "park_resume": ScenarioPerturbationCapability(
                kind: "park_resume", mechanism: .hostCall),
            "worker_kill": ScenarioPerturbationCapability(
                kind: "worker_kill", mechanism: .pageWorkerTerminate),
        ]
        switch target {
        case .macOSSwiftTest:
            declared["webcontent_kill"] = ScenarioPerturbationCapability(
                kind: "webcontent_kill", mechanism: .hostWebContentSIGKILL)
        case .iOSSimulator:
            declared["webcontent_kill"] = ScenarioPerturbationCapability(
                kind: "webcontent_kill",
                mechanism: .simulatorWebContentWatcher,
                requiresExternalWatcher: true,
                unavailableReason: "the simulator test process cannot signal the "
                    + "host WebContent process; run scripts/ci/scenarios.sh "
                    + "--run-on sim to arm the device-scoped watcher")
        case .iOSDevice:
            // No device watcher exists in this repository. Declaring the kind
            // would reintroduce the blind attempt the capability matrix removes.
            break
        }
        let effective = declared.filter { _, capability in
            if target == .iOSSimulator,
               capability.mechanism == .simulatorWebContentWatcher {
                return armed
            }
            return true
        }
        return ScenarioPerturbationCapabilities(
            target: target,
            simulatorWatcherArmed: armed,
            declared: declared,
            effective: effective)
    }

    /// The matrix of the process that is executing right now.
    public static var current: ScenarioPerturbationCapabilities {
        capabilities(for: .current)
    }

    /// `true` when the batch driver exported the watcher arming flag. The
    /// xcodebuild runner receives the bare name, the simctl-spawn fallback
    /// receives it through `SIMCTL_CHILD_`; both spellings are accepted so the
    /// same watcher handshake is recognized on either launch path.
    static func watcherArmed(_ environment: [String: String]) -> Bool {
        let keys = ["PDSH_SCENARIO_WEBCONTENT_WATCH",
                    "TEST_RUNNER_PDSH_SCENARIO_WEBCONTENT_WATCH",
                    "SIMCTL_CHILD_PDSH_SCENARIO_WEBCONTENT_WATCH"]
        return keys.contains { environment[$0] == "1" }
    }
}

// MARK: - Perturbation point

/// One catalog perturbation point (`after_turn:<n>`, `during_first_tool`,
/// `minute:<n>`). An unrecognized spelling is preserved rather than dropped so
/// the coverage/preflight paths can report it as runner-infra instead of
/// silently losing a declaration.
public enum ScenarioPerturbationPoint: Equatable, Sendable {
    case afterTurn(Int)
    case duringFirstTool
    case minute(Int)
    case unrecognized(String)

    public init(rawValue: String) {
        if rawValue == "during_first_tool" {
            self = .duringFirstTool
            return
        }
        if rawValue.hasPrefix("after_turn:"),
           let value = Int(rawValue.dropFirst("after_turn:".count)), value >= 0 {
            self = .afterTurn(value)
            return
        }
        if rawValue.hasPrefix("minute:"),
           let value = Int(rawValue.dropFirst("minute:".count)), value >= 0 {
            self = .minute(value)
            return
        }
        self = .unrecognized(rawValue)
    }

    /// The catalog spelling of the point.
    public var raw: String {
        switch self {
        case .afterTurn(let value): return "after_turn:\(value)"
        case .duringFirstTool: return "during_first_tool"
        case .minute(let value): return "minute:\(value)"
        case .unrecognized(let value): return value
        }
    }

    /// `false` for a spelling the runner does not know; preflight rejects it.
    public var isRecognized: Bool {
        if case .unrecognized = self { return false }
        return true
    }
}

// MARK: - Runner-INFRA result

/// One declared perturbation the execution target cannot execute, with the
/// reason. Carried in the report and in the batch's INFRA summary.
public struct ScenarioInfraPerturbation: Equatable, Sendable {
    public var at: String
    public var kind: String
    public var reason: String

    public init(at: String, kind: String, reason: String) {
        self.at = at
        self.kind = kind
        self.reason = reason
    }
}

/// The explicit runner-infrastructure result of one scenario.
///
/// This is not a product verdict: the scenario was aborted before the product
/// got a chance to run (load-time validation or a mechanism the target cannot
/// realize), so no assertion — in particular no `restart_recovered` — is
/// evaluated. The report status is `INFRA` and the batch driver reports it with
/// its own exit code.
public struct ScenarioInfraRejection: Equatable, Sendable {
    /// The stable report/batch classification prefix.
    public static let classification = "runner-infra"

    public var scenarioID: String
    public var target: ScenarioExecutionTarget
    public var perturbations: [ScenarioInfraPerturbation]
    /// The short reason (also used per perturbation when a declaration has no
    /// more specific reason).
    public var reason: String

    public init(scenarioID: String,
                target: ScenarioExecutionTarget,
                perturbations: [ScenarioInfraPerturbation],
                reason: String) {
        self.scenarioID = scenarioID
        self.target = target
        self.perturbations = perturbations
        self.reason = reason
    }

    /// The single-line detail written to the report and printed by the batch
    /// driver. Always starts with ``classification`` so a consumer can
    /// distinguish a runner gap from a product failure without parsing prose.
    public var detail: String {
        "\(Self.classification): scenario \(scenarioID) cannot execute its declared "
            + "perturbation(s) on \(target.rawValue): \(reason)"
    }
}

// MARK: - Pre-run validation

/// Validates a scenario's declared perturbations against the execution target's
/// capability matrix.
///
/// Runs when the catalog is loaded (and again when a `ScenarioRun` is created
/// for defense in depth), before any product code starts. Both halves of a
/// declaration are validated: the point spelling and the kind's effective
/// mechanism. An unsupported declaration is a ``ScenarioInfraRejection``, never
/// a perturbation report that fails `restart_recovered`.
public enum ScenarioPerturbationPreflight {
    /// The rejection for one scenario, or `nil` when every declaration can run.
    public static func rejection(
        for scenario: Scenario,
        capabilities: ScenarioPerturbationCapabilities
    ) -> ScenarioInfraRejection? {
        let declarations = scenario.perturbations ?? []
        guard !declarations.isEmpty else { return nil }
        var rejected: [ScenarioInfraPerturbation] = []
        var reasons: [String] = []
        for spec in declarations {
            let point = ScenarioPerturbationPoint(rawValue: spec.at)
            let reason: String
            if !point.isRecognized {
                reason = "unknown perturbation point \"\(spec.at)\"; supported "
                    + "points are after_turn:<n>, during_first_tool and minute:<n>"
            } else if capabilities.supports(spec.kind) {
                continue
            } else if let declared = capabilities.declaredCapability(for: spec.kind) {
                reason = "perturbation kind \"\(spec.kind)\" is declared for "
                    + "\(capabilities.target.rawValue) but not executable now: "
                    + (declared.unavailableReason
                        ?? "mechanism \(declared.mechanism.rawValue) is not armed")
            } else {
                reason = "unknown perturbation kind \"\(spec.kind)\"; declared "
                    + "kinds on \(capabilities.target.rawValue) are "
                    + capabilities.declaredKinds.sorted().joined(separator: ", ")
            }
            rejected.append(ScenarioInfraPerturbation(
                at: spec.at, kind: spec.kind, reason: reason))
            reasons.append("\(spec.at) (\(spec.kind)): \(reason)")
        }
        guard !rejected.isEmpty else { return nil }
        return ScenarioInfraRejection(
            scenarioID: scenario.id,
            target: capabilities.target,
            perturbations: rejected,
            reason: reasons.joined(separator: "; "))
    }

    /// The load-time rejection map for a whole catalog. Keyed by scenario id;
    /// a scenario absent from the map runs normally.
    public static func rejections(
        in scenarios: [Scenario],
        capabilities: ScenarioPerturbationCapabilities
    ) -> [String: ScenarioInfraRejection] {
        var rejections: [String: ScenarioInfraRejection] = [:]
        for scenario in scenarios {
            if let rejection = rejection(for: scenario, capabilities: capabilities) {
                rejections[scenario.id] = rejection
            }
        }
        return rejections
    }
}

// MARK: - Simulator WebContent kill transport

/// The simulator side of the device-scoped WebContent kill.
///
/// The sandboxed test process cannot enumerate or signal host processes, so it
/// writes a handshake request into the app container's results tree. The host
/// watcher (`scripts/ci/webcontent-watch.sh`, armed by
/// `scripts/ci/scenarios.sh --run-on sim`) SIGKILLs the selected
/// simulator's newly appeared WebContent pid(s) and writes the result back.
/// This is the same watcher implementation `sim.sh` uses for its smoke INFO
/// row; no second killer exists.
public enum ScenarioSimulatorWebContentWatcher {
    /// The handshake directory under the results root, matching the host
    /// watcher's `--directory` argument.
    public static let handshakeDirectoryName = ".webcontent-kill"

    /// How long the runner waits for the host watcher to answer. The watcher
    /// polls every 250 ms; the generous bound covers a busy simulator without
    /// turning a stuck watcher into an unbounded hang.
    public static let defaultTimeout: TimeInterval = 60

    public struct Result: Equatable, Sendable {
        public var status: String
        public var pids: [pid_t]
    }

    /// Writes one request and waits for its result, returning the killed pids.
    /// A watcher that is absent or cannot signal is a runner-INFRA failure, not
    /// a product recovery failure.
    public static func killAndWait(
        scenarioID: String,
        resultsRoot: URL,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> [pid_t] {
        let fileManager = FileManager.default
        let directory = resultsRoot.appendingPathComponent(handshakeDirectoryName,
                                                           isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
        } catch {
            throw ScenarioError.infra(
                "cannot create the WebContent kill handshake directory at "
                + "\(directory.path): \(error)")
        }
        let token = "\(safeToken(scenarioID))-\(UUID().uuidString)"
        let request = directory.appendingPathComponent("\(token).request")
        let result = directory.appendingPathComponent("\(token).result")
        defer {
            try? fileManager.removeItem(at: request)
            try? fileManager.removeItem(at: result)
        }
        let payload: [String: Any] = [
            "scenario": scenarioID,
            "pid": Int(getpid()),
            "requested_at": ISO8601DateFormatter().string(from: Date()),
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload,
                                                  options: [.sortedKeys])
            try data.write(to: request, options: .atomic)
        } catch {
            throw ScenarioError.infra(
                "cannot write the WebContent kill request at \(request.path): \(error)")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: result),
               let parsed = try? JSONDecoder().decode(ResultDocument.self, from: data) {
                if parsed.status == "killed" {
                    let pids = parsed.pids.map { pid_t($0) }
                    guard !pids.isEmpty else {
                        throw ScenarioError.infra(
                            "the WebContent watcher reported \"killed\" without a pid")
                    }
                    return pids
                }
                throw ScenarioError.infra(
                    "the WebContent watcher did not kill a process: "
                    + "\(parsed.status)\(parsed.pids.isEmpty ? "" : " (pids \(parsed.pids))")")
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        throw ScenarioError.infra(
            "no device-scoped WebContent watcher answered the kill request within "
            + "\(Int(timeout)) s; arm it with scripts/ci/scenarios.sh --run-on sim")
    }

    /// The line-oriented JSON the shell watcher writes. `pids` is a
    /// space-separated string in the contract; an integer array is accepted too
    /// so the transport does not depend on the shell's spelling.
    private struct ResultDocument: Decodable {
        var status: String
        var pids: [Int]

        private enum CodingKeys: String, CodingKey {
            case status, pids
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
            if let array = try? container.decode([Int].self, forKey: .pids) {
                pids = array
            } else if let text = try? container.decode(String.self, forKey: .pids) {
                pids = text.split(separator: " ").compactMap { Int($0) }
            } else {
                pids = []
            }
        }
    }

    private static func safeToken(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = value.unicodeScalars.map {
            allowed.contains($0) ? Character(String($0)) : "_"
        }
        let token = String(scalars)
        return token.isEmpty ? "scenario" : token
    }
}
