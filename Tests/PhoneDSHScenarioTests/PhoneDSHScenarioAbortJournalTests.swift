// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 fix regression: an aborted turn is journaled.
//
// G2-A08 exposed the abort class: the scenario runner sent `harness.send(.cancel)`
// as a fire-and-forget task and immediately tore the host down, while the host
// drain only waited for in-flight `0x40` API exchanges. A wall-budget timeout,
// request-budget abort, user cancel or background park could therefore end a
// run with an open DSH turn: `session.v4.jsonl` stopped at `step/start` and the
// transcript stopped at `progress`, so the model-visible turn and the logged
// turn diverged.
//
// The regression uses the real catalog-driven runner against a model upstream
// that hangs mid-SSE after the response headers (budget.max_minutes = 1). It
// asserts the artifact-level facts the fix owns, not an internal call:
//
//   * the run really took the wall-budget abort path (report status TIMEOUT),
//   * the DSH session journal opened the turn (so the hang reached DSH), and
//   * the journal ends on a terminal `turn/end` record,
//   * the transcript contains the terminal `turnEnded` event before teardown.
//
// The Worker bundle/image come only from the scenario launcher's explicit
// environment (`PDSH_DSH_WWW` / `PDSH_DSH_IMAGE`). The old
// `$TMPDIR/pdsh-scenarios-build` cache fallback is gone (G2-FIX-GATE-SLOTS): a
// plain unit gate must not turn a leftover build cache into an in-process
// integration run. Without the exported pair the test skips; a real batch
// still exports both.
//
// Gate selection: the class name starts with `PhoneDSH` so both
// Swift gates select it (`--filter 'PhoneDSH'` and
// `--filter 'PhoneDSH|PhoneDSHShell'`). A plain unit gate without the explicit
// bundle exports skips; a locked Mac console also defers: the window server
// then marks every window occlusion-hidden, `ScenarioRun` records `SKIP`
// before booting WebKit, and the pipeline's visibility-dependent gates use the
// same deferral (`pipeline/screen_locked.sh`). The cross-boundary DSH half of
// the assertion still runs in every `npm test` gate through
// `plugins/worker-entry/src/abort-journal.test.ts`, which boots the pinned
// DSH image and proves the cancel journals `turn/end` while the model stream is
// pending; the host half runs through
// `PhoneDSHScenarioAbortHostTests` on the real host + loopback.
//
// On a locked Mac the test can execute the exact same catalog document inside
// the iOS Simulator, whose UIKit scene visibility does not depend on the Mac
// console: it invokes the documented launcher
// `scripts/ci/scenarios.sh --run-on sim --catalog <file> --only
// G2-FIX-9-ABORT` and asserts the pulled artifacts. With the hung mock upstream
// the simulator run writes a `report.json` with status TIMEOUT, a
// `session.v4.jsonl` whose last record is
// `turn/end {reason:{kind:'aborted', ...}}` and a `transcript.jsonl` with a
// terminal `turnEnded` event. Both execution paths assert the same artifact
// facts; the simulator run is not a substitute for a weak assertion, it is the
// only way to obtain a real WKWebView run while the console is locked.
//
// G2-FIX-GATE-SLOTS: that simulator rerun is an integration entry and used to
// start `scenarios.sh` -> `smoke.sh` -> a nested `swift test` from a plain
// `phone-sdk` unit gate, which deadlocks on the outer SwiftPM workspace lock
// (and could reuse another session's booted simulator). It now requires an
// explicit integration authorization (the `PDSH_SCENARIO_SIM_FALLBACK=1`
// opt-in, a launcher selection, or an exported bundle pair) *and* a
// `PDSH_SIM_DEVICE` name; without both the test skips instead of selecting or
// booting a simulator. The authorization is checked before the cross-process
// lock is opened, so an unauthorized unit test never waits on a lock held by
// another session. The fallback still serialises authorized runs with that
// lock.

import Foundation
import XCTest
import PhoneDSHAgentCore
import PhoneDSH
import PhoneDSHScenario
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(Darwin)
import Darwin
#endif

/// A missing/unreadable report after a run that was expected to write one.
private struct MissingScenarioReport: Error, CustomStringConvertible {
    var description: String
}

final class PhoneDSHScenarioAbortJournalTests: XCTestCase {
    // MARK: - Fixtures

    /// G2-FIX-Q3: the 80 s wall-budget wait is the widest window in the suite
    /// for a batch/tooling cleanup to send SIGTERM/SIGINT/SIGHUP. The guard
    /// records it; the runner turns it into a reportable runner-INFRA failure
    /// instead of the XCTest process ending without a summary.
    override class func setUp() {
        super.setUp()
        ScenarioProcessSignals.install()
    }

    private static let scenarioID = "G2-FIX-9-ABORT"
    /// The checked-in report-schema self-test: the smallest wall budget and a
    /// stalled mock SSE body, so the runner takes the TIMEOUT path.
    private static let reportSchemaScenarioID = "G2-SELFTEST-REPORT-SCHEMA"

    private struct Bundle {
        var staticDirectory: URL
        var imageArchive: URL
    }

    /// The Worker static directory and image the scenario launcher explicitly
    /// exported. A leftover `$TMPDIR` cache is not an authorization to run this
    /// integration regression from a plain unit gate.
    private func scenarioBundle() throws -> Bundle {
        let environment = ProcessInfo.processInfo.environment
        guard let www = environment["PDSH_DSH_WWW"], !www.isEmpty,
              let image = environment["PDSH_DSH_IMAGE"], !image.isEmpty else {
            throw XCTSkip("no explicit Worker bundle/image are exported; run "
                + "scripts/ci/scenarios.sh or export PDSH_DSH_WWW/PDSH_DSH_IMAGE")
        }
        let fileManager = FileManager.default
        let staticDirectory = URL(fileURLWithPath: www, isDirectory: true)
        let imageArchive = URL(fileURLWithPath: image)
        let snapshot = staticDirectory.appendingPathComponent("boot.js")
        guard fileManager.fileExists(atPath: snapshot.path),
              fileManager.fileExists(atPath: staticDirectory
                .appendingPathComponent("worker-entry.js").path),
              fileManager.fileExists(atPath: staticDirectory
                .appendingPathComponent("index.html").path),
              fileManager.fileExists(atPath: imageArchive.path) else {
            throw XCTSkip("the exported Worker bundle/image are incomplete; run "
                + "scripts/ci/scenarios.sh")
        }
        return Bundle(staticDirectory: staticDirectory, imageArchive: imageArchive)
    }

    private func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileManager = FileManager.default
        while directory.pathComponents.count > 1 {
            if fileManager.fileExists(atPath: directory.appendingPathComponent("spec").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw XCTSkip("the scenario repository root (spec/) was not found above the test file")
    }

    /// The catalog document: one scenario whose only reply hangs after the
    /// response headers, so the turn stays open until the wall budget aborts it.
    private func scenarioDocument() -> [String: Any] {
        [
            "version": 1,
            "scenarios": [[
                "id": Self.scenarioID,
                "category": "regression",
                "title": "aborted turn journals a terminal event",
                "user_story": "A budget abort must leave a terminal turn record "
                    + "in the DSH session journal.",
                "workspace": ["files": [:] as [String: String]],
                "turns": [["prompt": "Write one short status line."]],
                // The report-schema half of the abort regression: the timed-out
                // run must keep `console_errors` clean of its own runner timeout.
                "assertions": [["type": "no_console_error"]] as [Any],
                "budget": ["max_minutes": 1, "max_model_requests": 50],
                "perturbations": [] as [Any],
                "network": "none",
                "mock": [
                    "chunk_bytes": 512,
                    "chunk_delay_ms": 0,
                    "stall_from_response": 1,
                    "stall_after_bytes": 4096,
                ] as [String: Any],
                "target": "macos",
            ] as [String: Any]],
        ]
    }

    private func sessionJournals(resultsDirectory: URL) -> [URL] {
        let sessions = resultsDirectory
            .appendingPathComponent("host", isDirectory: true)
            .appendingPathComponent("materialized", isDirectory: true)
            .appendingPathComponent("home", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sessions, includingPropertiesForKeys: [.isRegularFileKey], options: []) else {
            return []
        }
        var journals: [URL] = []
        for case let url as URL in enumerator
        where PhoneDSHSessionLog.isSessionLogFile(url.lastPathComponent) {
            journals.append(url)
        }
        return journals.sorted { $0.path < $1.path }
    }

    private func transcript(result: URL) -> String {
        let transcript = result.appendingPathComponent("transcript.jsonl")
        return (try? String(decoding: Data(contentsOf: transcript), as: UTF8.self)) ?? ""
    }

    // MARK: - Locked-console fallback

    /// `true` while the macOS graphical login session is locked.
    ///
    /// The runner's pre-turn visibility assertion deliberately fails when the
    /// page is hidden; on a locked console WebKit marks every AppKit window
    /// occlusion-hidden, so the macOS path cannot execute the scenario. The
    /// simulator path below runs the identical catalog where scene visibility
    /// is owned by the simulator, not the Mac console.
    private var consoleIsLocked: Bool {
        #if os(macOS) && canImport(CoreGraphics)
        guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return (dictionary["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
        #else
        return false
        #endif
    }

    /// The optional manual authorization key for the simulator integration
    /// fallback.
    ///
    /// A normal `phone-sdk` unit gate must never start this path: the nested
    /// `scenarios.sh` -> `smoke.sh` -> `swift test` chain waits on the outer
    /// SwiftPM workspace lock. The launcher does not set this key; a provisioned
    /// run is authorized by its launcher inputs instead (see below).
    static let simulatorFallbackAuthorizationKey = "PDSH_SCENARIO_SIM_FALLBACK"

    /// The explicitly requested device name, or `nil` when it is absent or
    /// blank. This is only the device half of the decision.
    static func requestedSimulatorDevice(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let raw = environment["PDSH_SIM_DEVICE"] else { return nil }
        let device = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !device.isEmpty else { return nil }
        return device
    }

    /// `true` when the process was explicitly started as an integration run.
    ///
    /// Three explicit forms authorize the fallback: the manual
    /// `PDSH_SCENARIO_SIM_FALLBACK=1` opt-in, a launcher selection
    /// (`PDSH_SCENARIO_*`, the same predicate the scenario suite uses), or a
    /// fully exported `PDSH_DSH_WWW`/`PDSH_DSH_IMAGE` pair. A plain unit-test
    /// environment has none of them. The launcher's `--run-on macos` path
    /// exports the selection and the bundle pair, so a locked-console batch is
    /// not skipped solely because the manual key is absent.
    static func simulatorFallbackIsAuthorized(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment[simulatorFallbackAuthorizationKey] == "1" { return true }
        if ScenarioSlotPlan.shouldAdoptBuildCache(environment: environment) { return true }
        let www = (environment["PDSH_DSH_WWW"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let image = (environment["PDSH_DSH_IMAGE"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !www.isEmpty && !image.isEmpty
    }

    /// The authorized simulator name, or `nil` when the fallback must not run.
    /// Both halves are required: an explicit integration authorization *and* a
    /// concrete device name. There is no candidate list and no "first
    /// available" default, so a plain unit test can never pick another
    /// session's booted simulator.
    static func authorizedSimulatorDevice(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard simulatorFallbackIsAuthorized(environment: environment) else { return nil }
        return requestedSimulatorDevice(environment: environment)
    }

    /// Acquires the cross-process lock only after the authorization check.
    ///
    /// `nil` means the fallback is not authorized: the acquire closure must not
    /// be called, so a plain unit test on a locked Mac never blocks on a lock
    /// held by another session. The closure is injectable so the ordering is a
    /// deterministic regression instead of a source-reading assertion.
    static func acquireSimulatorRunLockIfAuthorized(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        acquire: () async throws -> Int32
    ) async throws -> Int32? {
        guard authorizedSimulatorDevice(environment: environment) != nil else {
            return nil
        }
        return try await acquire()
    }

    /// The authorized simulator name, verified against `simctl`, or `nil`.
    private func simulatorDeviceName() -> String? {
        #if os(macOS)
        guard let preferred = Self.authorizedSimulatorDevice() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "available", "-j"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = object["devices"] as? [String: [[String: Any]]] else {
            return nil
        }
        for (runtime, entries) in devices where runtime.contains("iOS") {
            for entry in entries {
                guard (entry["name"] as? String) == preferred,
                      (entry["isAvailable"] as? Bool) == true else {
                    continue
                }
                return preferred
            }
        }
        return nil
        #else
        return nil
        #endif
    }

    /// A plain unit-test process must not select a simulator or start the
    /// nested build; only an explicit integration authorization plus a device
    /// authorizes it. This is a pure decision, so the gate can be checked
    /// without `simctl`, a simulator or a build.
    func testSimulatorFallbackRequiresExplicitAuthorizationAndDevice() {
        let device = "iPhone 17 Pro Max"
        XCTAssertNil(Self.authorizedSimulatorDevice(environment: [:]))
        XCTAssertNil(Self.authorizedSimulatorDevice(
            environment: ["PDSH_SIM_DEVICE": device]))
        XCTAssertNil(Self.authorizedSimulatorDevice(
            environment: [Self.simulatorFallbackAuthorizationKey: "1"]))
        XCTAssertNil(Self.authorizedSimulatorDevice(
            environment: [Self.simulatorFallbackAuthorizationKey: "1",
                          "PDSH_SIM_DEVICE": "   "]))
        XCTAssertNil(Self.authorizedSimulatorDevice(
            environment: ["PDSH_DSH_WWW": "/tmp/www",
                          "PDSH_DSH_IMAGE": "/tmp/image.tar.gz"]))
        XCTAssertEqual(
            Self.authorizedSimulatorDevice(
                environment: [Self.simulatorFallbackAuthorizationKey: "1",
                              "PDSH_SIM_DEVICE": device]),
            device)
    }

    /// A launcher-started batch is already an explicit integration invocation.
    /// `scenarios.sh --run-on macos` exports the selection and the provisioned
    /// bundle pair but not the manual opt-in key, so it must not be skipped
    /// solely for the missing key. It still needs a concrete device.
    func testProvisionedLauncherRunAuthorizesTheFallbackWithoutTheManualKey() {
        let device = "iPhone 17 Pro Max"
        let selection = [
            "PDSH_SCENARIO_ONLY": "G2-FIX-9-ABORT",
            "PDSH_SCENARIO_RESULTS": "/tmp/results",
            "PDSH_SIM_DEVICE": device,
        ]
        XCTAssertEqual(Self.authorizedSimulatorDevice(environment: selection), device)
        let bundle = [
            "PDSH_DSH_WWW": "/tmp/www",
            "PDSH_DSH_IMAGE": "/tmp/image.tar.gz",
            "PDSH_SIM_DEVICE": device,
        ]
        XCTAssertEqual(Self.authorizedSimulatorDevice(environment: bundle), device)
        XCTAssertNil(Self.authorizedSimulatorDevice(environment: [
            "PDSH_SCENARIO_ONLY": "G2-FIX-9-ABORT",
        ]), "a provisioned run without a device must still skip; there is no default")
        XCTAssertNil(Self.authorizedSimulatorDevice(environment: [
            "PDSH_SCENARIO_SIM_DIR": "/tmp/sim",
            "PDSH_SIM_DEVICE": device,
        ]), "a non-selection simulator directory is not an integration authorization")
    }

    /// The locked-console branch must check authorization *before* the
    /// cross-process lock. On a locked Mac a plain `phone-sdk` unit test with
    /// no authorization must not wait on a lock held by another session; here
    /// the acquire closure records whether it was reached at all.
    func testUnauthorizedFallbackNeverTouchesTheSimulatorRunLock() async throws {
        final class AcquireCounter {
            var calls = 0
        }
        let counter = AcquireCounter()
        let unauthorized = try await Self.acquireSimulatorRunLockIfAuthorized(
            environment: [:]) {
                counter.calls += 1
                return 42
            }
        XCTAssertNil(unauthorized)
        XCTAssertEqual(counter.calls, 0,
                       "an unauthorized unit test must not open or wait on the lock")

        let authorized = try await Self.acquireSimulatorRunLockIfAuthorized(
            environment: [Self.simulatorFallbackAuthorizationKey: "1",
                          "PDSH_SIM_DEVICE": "iPhone 17 Pro Max"]) {
                counter.calls += 1
                return 42
            }
        XCTAssertEqual(authorized, 42)
        XCTAssertEqual(counter.calls, 1)
    }

    /// Serialises the simulator runs of the two Swift gates (`swift-facade` and
    /// `sdk-all` both select this class). The lock file lives in the temporary
    /// directory, never in the repository.
    private static func acquireSimulatorRunLock() async throws -> Int32 {
        #if canImport(Darwin)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-g2fix9-simulator.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            throw XCTSkip("cannot open the simulator run lock at \(path)")
        }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        return descriptor
        #else
        return -1
        #endif
    }

    private static func releaseSimulatorRunLock(_ descriptor: Int32) {
        #if canImport(Darwin)
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
        #endif
    }

    /// Runs the exact catalog document through the documented simulator
    /// launcher and returns the pulled results root.
    ///
    /// The launcher's report check exits non-zero for `TIMEOUT` (its generic
    /// simulator slot only grades `PASS`), so the exit code is deliberately not
    /// interpreted as a verdict: the pulled artifacts are. A run that wrote no
    /// report at all is a real failure and carries the launcher log tail.
    ///
    /// `catalogURL` runs a checked-in catalog (the report-schema self-test)
    /// instead of writing the local abort document; `scenarioID` selects the
    /// one scenario the launcher stages.
    private func runScenarioOnSimulator(root: URL,
                                        bundle: Bundle?,
                                        catalogURL: URL? = nil,
                                        scenarioID: String? = nil) async throws
        -> (status: Int32, output: String, results: URL) {
        let selectedID = scenarioID ?? Self.scenarioID
        guard let device = simulatorDeviceName() else {
            throw XCTSkip("the Mac console is locked and the simulator fallback is not "
                + "authorized (provide a launcher selection or bundle pair, or set "
                + "PDSH_SCENARIO_SIM_FALLBACK=1, plus PDSH_SIM_DEVICE=<name>); "
                + "the budget-abort regression needs a visible WebKit page")
        }
        let script = root.appendingPathComponent("scripts/ci/scenarios.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw XCTSkip("the simulator scenario launcher is missing: \(script.path)")
        }
        let temporaries = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-abort-journal-sim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaries, withIntermediateDirectories: true)
        let results = temporaries.appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        let catalog: URL
        if let catalogURL {
            catalog = catalogURL
        } else {
            catalog = temporaries.appendingPathComponent("catalog.json")
            try JSONSerialization.data(withJSONObject: scenarioDocument(), options: [.sortedKeys])
                .write(to: catalog)
        }
        let log = temporaries.appendingPathComponent("scenarios.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)

        var environment = ProcessInfo.processInfo.environment
        let home = environment["HOME"] ?? NSHomeDirectory()
        environment["PATH"] = "\(home)/.cargo/bin:\(home)/.local/bin:"
            + "/opt/homebrew/bin:/usr/local/bin:"
            + (environment["PATH"] ?? "/usr/bin:/bin")
        if environment["PDSH_DSH_CHECKOUT"] == nil {
            // The launcher resolves the same per-machine file; reading it here
            // keeps the checkout path out of the repository and out of argv.
            let config = URL(fileURLWithPath: home)
                .appendingPathComponent(".config/phone-dsh/dsh-checkout")
            if let text = try? String(contentsOf: config, encoding: .utf8),
               let line = text.split(separator: "\n").first {
                let path = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty {
                    environment["PDSH_DSH_CHECKOUT"] = path
                }
            }
        }
        if let bundle {
            environment["PDSH_DSH_WWW"] = bundle.staticDirectory.path
            environment["PDSH_DSH_IMAGE"] = bundle.imageArchive.path
        }
        environment["PDSH_SCENARIO_SIM_DIR"] = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-scenarios-sim").path
        environment["PDSH_SCENARIO_SIM_TIMEOUT"] = "1800"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            script.path, "--run-on", "sim",
            "--catalog", catalog.path,
            "--results", results.path,
            "--only", selectedID,
            "--upstream", "mock",
            "--destination", "platform=iOS Simulator,name=\(device)",
        ]
        process.environment = environment
        process.standardOutput = logHandle
        process.standardError = logHandle
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        try? logHandle.close()
        let output = String(decoding: (try? Data(contentsOf: log)) ?? Data(), as: UTF8.self)
        return (status, output, results)
    }

    /// The artifact-level contract every abort path must satisfy, shared by the
    /// macOS runner and the simulator fallback:
    ///
    /// * the run took the wall-budget path (status TIMEOUT and the runner's
    ///   `budget.max_minutes` error in the report),
    /// * every session journal that opened a turn ends on `turn/end` with
    ///   reason `aborted`,
    /// * the transcript carries a terminal `turnEnded` event after a
    ///   `turnStarted`, with an abort reason, so the ending is reconstructable
    ///   from `transcript.jsonl` alone.
    private func assertAbortArtifacts(in resultsRoot: URL) throws {
        let result = resultsRoot.appendingPathComponent(Self.scenarioID, isDirectory: true)
        let reportURL = result.appendingPathComponent("report.json")
        guard let reportData = try? Data(contentsOf: reportURL),
              let report = (try? JSONSerialization.jsonObject(with: reportData))
                as? [String: Any] else {
            XCTFail("the abort scenario wrote no decodable report at \(reportURL.path)")
            return
        }
        XCTAssertNil(report["deferred"], "the run was deferred: \(report["deferred"] ?? "-")")
        XCTAssertEqual(report["status"] as? String, "TIMEOUT",
                       "the regression must exercise the wall-budget abort path; report=\(report)")
        // The wall-budget timeout is a runner lifecycle diagnostic: it belongs
        // to `runner_errors`. `console_errors` is reserved for the
        // Worker/session stream `no_console_error` evaluates (G2-A01/A02).
        assertReportDiagnosticsSchema(report, expectingRunnerError: "budget.max_minutes=1")

        let journals = sessionJournals(resultsDirectory: result)
        XCTAssertFalse(journals.isEmpty,
                       "the aborted run wrote no DSH session journal below "
                           + result.appendingPathComponent("host").path)

        var sawStartedTurn = false
        var terminalJournals = 0
        for journal in journals {
            let data = try Data(contentsOf: journal)
            let state = PhoneDSHSessionLog.state(of: data)
            guard state.sawTurnStart else { continue }
            sawStartedTurn = true
            if state.hasTerminalTurn,
               state.lastRecordType == "turn/end",
               state.lastTurnEndReason != nil {
                terminalJournals += 1
            } else {
                XCTFail("the aborted DSH session journal \(journal.lastPathComponent) "
                    + "does not end on a terminal turn/end record: "
                    + "last=\(state.lastRecordType ?? "none") "
                    + "openTurn=\(state.openTurn.map(String.init) ?? "none") "
                    + "reason=\(state.lastTurnEndReason ?? "none")")
            }
        }
        XCTAssertTrue(sawStartedTurn,
                      "the hung model response never opened a DSH turn; the run did not "
                          + "exercise the abort path")
        XCTAssertGreaterThanOrEqual(terminalJournals, 1,
                                    "no aborted session journal recorded a terminal turn/end")
        for journal in journals {
            let data = try Data(contentsOf: journal)
            let state = PhoneDSHSessionLog.state(of: data)
            guard state.sawTurnStart else { continue }
            XCTAssertEqual(state.lastTurnEndReason, "aborted",
                           "the cancellation must journal the turn/end reason as aborted")
        }

        let transcript = transcript(result: result)
        var started = false
        var terminal: [String: Any]?
        for line in transcript.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any],
                  let kind = object["kind"] as? [String: Any] else {
                continue
            }
            if kind["turnStarted"] != nil {
                started = true
            }
            if started, let ended = kind["turnEnded"] as? [String: Any] {
                terminal = ended
            }
        }
        guard let terminal else {
            XCTFail("the transcript does not carry a terminal turnEnded event after the "
                + "turnStarted; its tail is:\n" + String(transcript.suffix(2000)))
            return
        }
        guard let reason = terminal["reason"] as? [String: Any], !reason.isEmpty else {
            XCTFail("the transcript turnEnded carries no abort reason: \(terminal)")
            return
        }
        XCTAssertTrue(reason["cancelled"] != nil || reason["failed"] != nil
                        || reason["budgetExhausted"] != nil,
                      "the transcript turnEnded does not name the abort reason: \(terminal)")
        print("abort-journal regression: status=TIMEOUT journals=\(journals.count) "
            + "terminal=\(terminalJournals) transcript=turnEnded "
            + "reason=\(reason.keys.sorted())")
    }

    /// The report-schema invariant the real-model batch exposed: the
    /// `no_console_error` assertion evaluates the Worker/session console-error
    /// stream that `console_errors` carries, while runner lifecycle diagnostics
    /// (the wall-budget timeout here) belong to the separate `runner_errors`
    /// field. A report is contradictory when the assertion says `ok: true` and
    /// the same `console_errors` field lists the runner's timeout.
    private func assertReportDiagnosticsSchema(_ report: [String: Any],
                                               expectingRunnerError needle: String,
                                               file: StaticString = #filePath,
                                               line: UInt = #line) {
        guard let consoleErrors = report["console_errors"] as? [String] else {
            XCTFail("report.json has no console_errors array: \(report)", file: file, line: line)
            return
        }
        guard let runnerErrors = report["runner_errors"] as? [String] else {
            XCTFail("report.json has no runner_errors array; runner diagnostics are "
                + "missing or still mixed into console_errors: \(report)",
                file: file, line: line)
            return
        }
        XCTAssertTrue(consoleErrors.isEmpty,
                      "console_errors must carry only Worker/session console errors; got "
                        + "\(consoleErrors)", file: file, line: line)
        XCTAssertTrue(runnerErrors.contains { $0.contains(needle) },
                      "runner_errors does not carry \"\(needle)\": \(runnerErrors)",
                      file: file, line: line)
        print("report-schema regression: status=\(report["status"] ?? "-") "
            + "console_errors=\(consoleErrors.count) "
            + "runner_errors=\(runnerErrors.count) "
            + "first_runner_error=\(runnerErrors.first ?? "-")")
        XCTAssertFalse(runnerErrors.contains {
            $0.hasPrefix("console.") || $0.hasPrefix("session:")
                || $0.hasPrefix("host error:")
        }, "runner_errors must not carry Worker/session console errors: \(runnerErrors)",
           file: file, line: line)
        let assertions = report["assertions"] as? [[String: Any]] ?? []
        guard let noConsole = assertions.first(where: {
            $0["type"] as? String == "no_console_error"
        }) else {
            XCTFail("the report has no no_console_error assertion to cross-check",
                    file: file, line: line)
            return
        }
        XCTAssertEqual(noConsole["ok"] as? Bool, consoleErrors.isEmpty,
                       "no_console_error must be evaluated on exactly the array "
                        + "console_errors writes; ok=\(noConsole["ok"] ?? "nil") "
                        + "consoleErrors=\(consoleErrors)", file: file, line: line)
        if consoleErrors.isEmpty {
            XCTAssertEqual(noConsole["detail"] as? String, "no console errors",
                           "a clean console must read as \"no console errors\"",
                           file: file, line: line)
        } else {
            XCTAssertTrue((noConsole["detail"] as? String ?? "").contains("console_errors"),
                          "the failure detail must reference the array it evaluated: "
                            + "\(noConsole["detail"] ?? "nil")", file: file, line: line)
        }
    }

    private func reportObject(in resultsRoot: URL,
                              scenarioID: String,
                              launcherStatus: Int32? = nil,
                              launcherOutput: String? = nil) throws -> [String: Any] {
        let url = resultsRoot.appendingPathComponent(scenarioID, isDirectory: true)
            .appendingPathComponent("report.json")
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            var message = "the run wrote no decodable report at \(url.path)"
            if let launcherStatus { message += " (launcher exit \(launcherStatus))" }
            if let launcherOutput { message += "; log tail:\n" + String(launcherOutput.suffix(4000)) }
            XCTFail(message)
            throw MissingScenarioReport(description: message)
        }
        return object
    }

    // MARK: - The regression

    @MainActor
    func testBudgetAbortLeavesATerminalSessionJournal() async throws {
        let root = try repositoryRoot()

        // A locked macOS console makes every AppKit window occlusion-hidden, so
        // the macOS runner cannot execute the scenario (it records a SKIP
        // before booting WebKit). Run the identical catalog document on the
        // iOS Simulator, where UIKit owns scene visibility, and assert the same
        // pulled artifacts. The cross-process lock serialises the two Swift
        // gates that select this class.
        if consoleIsLocked {
            // Authorization is checked before the cross-process lock: a plain
            // unit test with no integration input must not wait on a lock held
            // by another session.
            guard let lock = try await Self.acquireSimulatorRunLockIfAuthorized(
                acquire: { try await Self.acquireSimulatorRunLock() }) else {
                throw XCTSkip("the Mac console is locked and the simulator fallback is "
                    + "not authorized (provide a launcher selection or bundle pair, or set "
                    + "PDSH_SCENARIO_SIM_FALLBACK=1, plus PDSH_SIM_DEVICE=<name>); "
                    + "the budget-abort regression needs a visible WebKit page")
            }
            defer { Self.releaseSimulatorRunLock(lock) }
            let bundle = try? scenarioBundle()
            let sim = try await runScenarioOnSimulator(root: root, bundle: bundle)
            let report = sim.results.appendingPathComponent(Self.scenarioID, isDirectory: true)
                .appendingPathComponent("report.json")
            guard FileManager.default.fileExists(atPath: report.path) else {
                XCTFail("the simulator scenario run wrote no report "
                    + "(launcher exit \(sim.status)); log tail:\n"
                    + String(sim.output.suffix(4000)))
                return
            }
            print("abort-journal regression: simulator results at \(sim.results.path)")
            try assertAbortArtifacts(in: sim.results)
            return
        }

        let bundle = try scenarioBundle()
        let temporaries = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-abort-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaries, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaries) }

        let catalogURL = temporaries.appendingPathComponent("catalog.json")
        let document = scenarioDocument()
        let catalogData = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try catalogData.write(to: catalogURL)
        let catalog = try ScenarioCatalog.load(from: catalogURL)
        let scenario = try XCTUnwrap(catalog.scenarios.first)
        XCTAssertEqual(scenario.id, Self.scenarioID)

        let results = temporaries.appendingPathComponent("results", isDirectory: true)
        let environment = try ScenarioEnvironment.resolve(environment: [
            "PDSH_SCENARIO_ROOT": root.path,
            "PDSH_SCENARIO_CATALOG": catalogURL.path,
            "PDSH_SCENARIO_RESULTS": results.path,
            "PDSH_SCENARIO_FIXTURES": root.appendingPathComponent(
                "scripts/ci/scenarios/fixtures", isDirectory: true).path,
            "PDSH_SCENARIO_ONLY": Self.scenarioID,
            "PDSH_SCENARIO_TARGET": "macos",
            "PDSH_SCENARIO_UPSTREAM": "mock",
            "PDSH_DSH_WWW": bundle.staticDirectory.path,
            "PDSH_DSH_IMAGE": bundle.imageArchive.path,
        ])

        let run = ScenarioRun(scenario: scenario, environment: environment)
        let report = await run.execute()

        if report.status == "SKIP" {
            // The only SKIP reason on macOS is the locked console, handled
            // above; a sighted environment must not silently defer this
            // regression.
            throw XCTSkip("scenario deferred by the environment: "
                + (report.deferred ?? "the environment cannot host a visible WKWebView page"))
        }
        XCTAssertEqual(report.status, "TIMEOUT",
                       "the regression must exercise the wall-budget abort path; "
                           + "report=\(report.status) errors=\(report.consoleErrors)")
        try assertAbortArtifacts(in: results)
    }

    /// G2-A01/A02 exposed the same report twice: `no_console_error` evaluated
    /// the runtime `recorder.consoleErrors`, then `buildReport` appended the
    /// runner's own timeout to the same `console_errors` array. The report said
    /// `ok: true` and carried "runner: timeout: budget.max_minutes=1 elapsed"
    /// in the field the assertion had just declared clean.
    ///
    /// The checked-in selftest scenario takes the real wall-budget timeout path
    /// (smallest budget, stalled mock SSE body) and the report is checked as
    /// data: `console_errors` must stay empty, the timeout must be in
    /// `runner_errors`, and no_console_error must agree with `console_errors`.
    @MainActor
    func testTimedOutRunKeepsRunnerDiagnosticsOutOfConsoleErrors() async throws {
        let root = try repositoryRoot()
        let catalogURL = root.appendingPathComponent(
            "scripts/ci/scenarios/selftest.json")
        let catalog = try ScenarioCatalog.load(from: catalogURL)
        let scenario = try XCTUnwrap(
            catalog.scenarios.first { $0.id == Self.reportSchemaScenarioID },
            "selftest.json has no \(Self.reportSchemaScenarioID) fixture")
        XCTAssertEqual(scenario.budget.maxMinutes, 1,
                       "the fixture must use the smallest wall budget so the run times out")
        XCTAssertTrue(scenario.assertions.contains { $0.type == "no_console_error" },
                      "the fixture must assert no_console_error")

        if consoleIsLocked {
            // Same ordering as the abort regression: no authorized integration
            // input means no cross-process lock wait.
            guard let lock = try await Self.acquireSimulatorRunLockIfAuthorized(
                acquire: { try await Self.acquireSimulatorRunLock() }) else {
                throw XCTSkip("the Mac console is locked and the simulator fallback is "
                    + "not authorized (provide a launcher selection or bundle pair, or set "
                    + "PDSH_SCENARIO_SIM_FALLBACK=1, plus PDSH_SIM_DEVICE=<name>); "
                    + "the report-schema regression needs a visible WebKit page")
            }
            defer { Self.releaseSimulatorRunLock(lock) }
            let bundle = try? scenarioBundle()
            let sim = try await runScenarioOnSimulator(root: root, bundle: bundle,
                                                       catalogURL: catalogURL,
                                                       scenarioID: scenario.id)
            let report = try reportObject(in: sim.results, scenarioID: scenario.id,
                                          launcherStatus: sim.status,
                                          launcherOutput: sim.output)
            XCTAssertEqual(report["status"] as? String, "TIMEOUT",
                           "the fixture must exercise the wall-budget timeout path; "
                            + "report=\(report)")
            assertReportDiagnosticsSchema(report, expectingRunnerError: "budget.max_minutes=1")
            return
        }

        let bundle = try scenarioBundle()
        let temporaries = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-report-schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaries, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaries) }

        let results = temporaries.appendingPathComponent("results", isDirectory: true)
        let environment = try ScenarioEnvironment.resolve(environment: [
            "PDSH_SCENARIO_ROOT": root.path,
            "PDSH_SCENARIO_CATALOG": catalogURL.path,
            "PDSH_SCENARIO_RESULTS": results.path,
            "PDSH_SCENARIO_FIXTURES": root.appendingPathComponent(
                "scripts/ci/scenarios/fixtures", isDirectory: true).path,
            "PDSH_SCENARIO_ONLY": scenario.id,
            "PDSH_SCENARIO_TARGET": "macos",
            "PDSH_SCENARIO_UPSTREAM": "mock",
            "PDSH_DSH_WWW": bundle.staticDirectory.path,
            "PDSH_DSH_IMAGE": bundle.imageArchive.path,
        ])

        let run = ScenarioRun(scenario: scenario, environment: environment)
        let report = await run.execute()
        if report.status == "SKIP" {
            throw XCTSkip("scenario deferred by the environment: "
                + (report.deferred ?? "the environment cannot host a visible WKWebView page"))
        }
        XCTAssertEqual(report.status, "TIMEOUT",
                       "the fixture must exercise the wall-budget timeout path; "
                        + "report=\(report.status) console_errors=\(report.consoleErrors) "
                        + "runner_errors=\(report.runnerErrors)")
        let object = try reportObject(in: results, scenarioID: scenario.id)
        assertReportDiagnosticsSchema(object, expectingRunnerError: "budget.max_minutes=1")
    }
}

final class PhoneDSHScenarioJournalTests: XCTestCase {
    private func state(_ lines: [String]) -> PhoneDSHSessionTurnState {
        PhoneDSHSessionLog.state(of: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    func testOpenTurnIsNotTerminal() {
        let parsed = state([
            #"{"type":"session","version":4,"id":"session-a","cwd":"/dsh/workspace"}"#,
            #"{"type":"turn/start","seq":0,"time":1000,"data":{"turn":1}}"#,
            #"{"type":"step/start","seq":1,"time":1001,"data":{"turn":1,"step":1}}"#,
        ])
        XCTAssertEqual(parsed.sessionID, "session-a")
        XCTAssertTrue(parsed.isTurnOpen)
        XCTAssertFalse(parsed.hasTerminalTurn)
        XCTAssertEqual(parsed.openTurn, 1)
    }

    func testTurnEndAfterStartIsTerminal() {
        let parsed = state([
            #"{"type":"session","version":4,"id":"session-b","cwd":"/dsh/workspace"}"#,
            #"{"type":"turn/start","seq":0,"time":1000,"data":{"turn":1}}"#,
            #"{"type":"step/start","seq":1,"time":1001,"data":{"turn":1,"step":1}}"#,
            #"{"type":"step/end","seq":2,"time":1002,"data":{"turn":1,"step":1}}"#,
            #"{"type":"turn/end","seq":3,"time":1003,"data":{"turn":1,"reason":{"kind":"aborted"}}}"#,
        ])
        XCTAssertTrue(parsed.hasTerminalTurn)
        XCTAssertEqual(parsed.lastRecordType, "turn/end")
        XCTAssertEqual(parsed.lastTurnEndReason, "aborted")
        XCTAssertEqual(parsed.lastTurnEndTimeMillis, 1003)
    }

    func testSessionWithoutATurnHasNoOpenTurn() {
        let parsed = state([
            #"{"type":"session","version":4,"id":"session-c","cwd":"/dsh/workspace"}"#,
        ])
        XCTAssertNil(parsed.openTurn)
        XCTAssertFalse(parsed.sawTurnStart)
        XCTAssertEqual(parsed.sessionID, "session-c")
    }

    func testSecondTurnReopensAfterACompletedOne() {
        let parsed = state([
            #"{"type":"turn/start","seq":0,"time":1000,"data":{"turn":1}}"#,
            #"{"type":"turn/end","seq":1,"time":1001,"data":{"turn":1,"reason":{"kind":"completed"}}}"#,
            #"{"type":"turn/start","seq":2,"time":1002,"data":{"turn":2}}"#,
        ])
        XCTAssertEqual(parsed.openTurn, 2)
        XCTAssertEqual(parsed.lastTurnEndTimeMillis, 1001)
        XCTAssertFalse(parsed.hasTerminalTurn)
    }

    func testMalformedTornTailIsIgnored() {
        let parsed = state([
            #"{"type":"turn/start","seq":0,"time":1000,"data":{"turn":1}}"#,
            #"{"type":"turn/end","seq":1,"time":1001,"data":{"turn":1,"reason":{"kind":"completed"}}}"#,
            #"{"type":"turn/start","seq":2,"ti"#,
        ])
        XCTAssertTrue(parsed.hasTerminalTurn,
                      "a torn, unparsable tail line must not hide the last durable turn/end")
    }

    /// The abort drain polls every 50 ms; the cache must never hide a journal
    /// append while an open turn is being cancelled, must advance from the
    /// appended bytes only, and must hold a torn line until it is complete.
    func testJournalStateCacheReReadsWhenTheJournalChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-journal-cache-\(UUID().uuidString)", isDirectory: true)
        let sessionDirectory = root
            .appendingPathComponent("--dsh-workspace--", isDirectory: true)
            .appendingPathComponent("session-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = sessionDirectory.appendingPathComponent("session.v4.jsonl")
        let header = #"{"type":"session","version":4,"id":"session-cache","cwd":"/dsh/workspace"}"#
        let start = #"{"type":"turn/start","seq":0,"time":1000,"data":{"turn":1}}"#
        try Data((header + "\n" + start + "\n").utf8).write(to: journal)

        func append(_ text: String) throws {
            let handle = try FileHandle(forWritingTo: journal)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        }
        func state() throws -> PhoneDSHSessionTurnState {
            try XCTUnwrap(
                PhoneDSHSessionLog.states(inSessionsDirectory: root,
                                          including: ["session-cache"],
                                          cache: cache)["session-cache"])
        }

        let cache = PhoneDSHJournalStateCache()
        let first = try state()
        XCTAssertTrue(first.isTurnOpen)
        // An unchanged journal returns the cached parse.
        let second = try state()
        XCTAssertEqual(first, second)

        // The Worker appends the terminal record; the cache must observe it.
        let end = #"{"type":"turn/end","seq":1,"time":1001,"data":{"turn":1,"reason":{"kind":"aborted"}}}"#
        try append(end + "\n")

        let third = try state()
        XCTAssertTrue(third.hasTerminalTurn)
        XCTAssertEqual(third.lastRecordType, "turn/end")
        XCTAssertEqual(third.lastTurnEndReason, "aborted")

        // A later turn reopens the journal; the cache must advance the previous
        // state rather than restart from the beginning.
        let nextStart = #"{"type":"turn/start","seq":2,"time":1002,"data":{"turn":2}}"#
        try append(nextStart + "\n")
        let fourth = try state()
        XCTAssertEqual(fourth.openTurn, 2)
        XCTAssertTrue(fourth.isTurnOpen)
        XCTAssertFalse(fourth.hasTerminalTurn)

        // A torn tail is held (not fabricated as a turn/end) until the rest of
        // the line and its newline arrive.
        let nextEnd = #"{"type":"turn/end","seq":3,"time":1003,"data":{"turn":2,"reason":{"kind":"aborted"}}}"#
        let split = nextEnd.index(nextEnd.startIndex, offsetBy: 30)
        try append(String(nextEnd[..<split]))
        let torn = try state()
        XCTAssertEqual(torn.openTurn, 2)
        XCTAssertFalse(torn.hasTerminalTurn)
        try append(String(nextEnd[split...]) + "\n")
        let fifth = try state()
        XCTAssertTrue(fifth.hasTerminalTurn)
        XCTAssertEqual(fifth.lastTurnEndReason, "aborted")

        // A truncation/rewrite is not append-only, so the cache must re-read
        // the whole journal instead of trusting its byte offset.
        let rewritten = header + "\n" + start + "\n"
        try Data(rewritten.utf8).write(to: journal)
        let sixth = try state()
        XCTAssertEqual(sixth.openTurn, 1)
        XCTAssertTrue(sixth.isTurnOpen)
        XCTAssertFalse(sixth.sawTurnEnd)
    }

    /// The scenario transcript is the JSONL encoding of the harness stream
    /// (`ScenarioRun.writeTranscript`). The abort contract needs the terminal
    /// `turnEnded` event to survive that encoding so a reader can reconstruct
    /// the ending from `transcript.jsonl` alone.
    func testTranscriptEncodingCarriesTheTerminalTurnEndedEvent() throws {
        let event = HarnessEvent(seq: 7,
                                 time: Date(timeIntervalSince1970: 1_000),
                                 kind: .turnEnded(turnID: "1", reason: .cancelled))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let line = String(decoding: try encoder.encode(event), as: UTF8.self)
        XCTAssertTrue(line.contains("\"turnEnded\""), line)
        XCTAssertTrue(line.contains("\"cancelled\""), line)
        XCTAssertTrue(line.contains("\"seq\":7"), line)
    }
}
