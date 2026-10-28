// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: the real webcontent_kill
// perturbation recovery regression.
//
// G2-FIX-65 (a): a `webcontent_kill` declaration must actually be applied on
// the macOS runner. The scenario below runs the real WKWebView engine with the
// packed Worker image and the scripted mock model (one tool call, one final
// reply per turn). After the first turn the perturbation kills the WebContent
// process; the D14 recovery edge (Running → Recovering → Running) must run and
// the same session must continue into the second turn. The test then confirms
// the mechanism in the evidence, not just a green assertion.
//
// The test needs the same inputs as the scenario gate (`scripts/ci/
// scenarios.sh` exports PDSH_DSH_WWW, PDSH_DSH_IMAGE and the results root). When
// the gate is invoked without them, or the Mac console is locked (a hidden
// WKWebView page cannot run), the test skips loudly: this is an environment
// precondition, never a product verdict. The deterministic capability/INFRA
// cases live in ScenarioPerturbationCapabilityTests and always run.

import Foundation
import XCTest
@testable import PhoneDSHScenario

final class PhoneDSHScenarioTestsWebContentKill: XCTestCase {
    // MARK: The simulator transport (deterministic, no simulator needed)

    /// The simulator test process cannot signal WebContent itself; it writes a
    /// request and the host watcher answers with the killed pid(s). This test
    /// pins the request/result contract without booting a simulator: a stand-in
    /// watcher answers exactly as `scripts/ci/webcontent-watch.sh` does.
    func testSimulatorHandshakeDeliversTheKilledPids() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-webcontent-watch-\(UUID().uuidString)",
                                    isDirectory: true)
        let directory = root.appendingPathComponent(
            ScenarioSimulatorWebContentWatcher.handshakeDirectoryName,
            isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let watcher = Task.detached { () -> Bool in
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                let names = (try? FileManager.default.contentsOfDirectory(
                    atPath: directory.path)) ?? []
                if let request = names.first(where: { $0.hasSuffix(".request") }) {
                    let result = directory.appendingPathComponent(
                        request.replacingOccurrences(of: ".request", with: ".result"))
                    try? Data("{\"status\":\"killed\",\"pids\":\"4242\"}".utf8)
                        .write(to: result)
                    return true
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return false
        }
        let pids = try await ScenarioSimulatorWebContentWatcher.killAndWait(
            scenarioID: "handshake", resultsRoot: root, timeout: 5)
        XCTAssertEqual(pids, [4242])
        let answered = await watcher.value
        XCTAssertTrue(answered, "the stand-in watcher never saw the request")
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: directory.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty,
                      "the request/result pair must be consumed: \(leftovers)")
    }

    /// An absent watcher is a runner-infra failure, never a product recovery
    /// failure: the report path converts this error to `INFRA`.
    func testSimulatorHandshakeWithoutTheWatcherIsRunnerInfra() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-webcontent-watch-\(UUID().uuidString)",
                                    isDirectory: true)
        do {
            _ = try await ScenarioSimulatorWebContentWatcher.killAndWait(
                scenarioID: "no-watcher", resultsRoot: root, timeout: 0.3)
            XCTFail("an absent watcher must not report a successful kill")
        } catch let error as ScenarioError {
            guard case .infra(let detail) = error else {
                return XCTFail("expected a runner-infra error, got \(error)")
            }
            XCTAssertTrue(detail.contains("watcher"), detail)
        }
    }

    // MARK: The real macOS kill and D14 recovery

    @MainActor
    func testWebContentKillAppliesRecoversAndTheSessionContinues() async throws {
        if let locked = ScenarioConsoleSession.lockedReason {
            throw XCTSkip("webcontent_kill end-to-end deferred: " + locked)
        }
        let environment: ScenarioEnvironment
        do {
            environment = try ScenarioEnvironment.resolve()
        } catch {
            throw XCTSkip("the scenario runner inputs are not provisioned "
                + "(PDSH_DSH_WWW / PDSH_DSH_IMAGE): \(error)")
        }
        let scenario = Self.webContentKillScenario()
        let run = ScenarioRun(scenario: scenario, environment: environment)
        let report = await run.execute()
        if report.status == "SKIP" {
            throw XCTSkip("the runner deferred the scenario: "
                + (report.deferred ?? "no deferred reason"))
        }

        XCTAssertEqual(report.status, "PASS",
                       "the product had a real chance to recover; status \(report.status), "
                       + "perturbations: \(report.perturbations.map { "\($0.at)/\($0.kind)" })")
        XCTAssertEqual(report.turns.count, 2, "both turns must be reported")
        XCTAssertTrue(report.turns.allSatisfy { $0.ended != nil },
                      "the session did not reach a terminal end after the kill")

        // (a) The perturbation was applied by the host-process mechanism.
        guard let perturbation = report.perturbations.first(
            where: { $0.kind == "webcontent_kill" }) else {
            return XCTFail("the applied webcontent_kill report is missing")
        }
        XCTAssertEqual(perturbation.at, "after_turn:1")
        XCTAssertEqual(perturbation.status, "applied")
        XCTAssertEqual(perturbation.ok, true, perturbation.detail ?? "no detail")
        XCTAssertEqual(perturbation.mechanism, "host-webcontent-sigkill",
                       "the macOS runner must SIGKILL the connected WebContent process")
        XCTAssertFalse(perturbation.killedPids?.isEmpty ?? true,
                       "the report must carry the WebContent pid it killed")
        XCTAssertNotNil(perturbation.recoveredMs)

        // The state machine took the documented D14 edge, not a Worker restart.
        XCTAssertTrue(report.hostStates.contains("controller:running->recovering"),
                      "missing Running -> Recovering; states: \(report.hostStates)")
        XCTAssertTrue(report.hostStates.contains("controller:recovering->running"),
                      "missing Recovering -> Running; states: \(report.hostStates)")
        XCTAssertGreaterThanOrEqual(report.webContentTerminations, 1,
                                    "the host did not observe a WebContent termination")

        // The session survived and the following turn ran on the same session.
        XCTAssertGreaterThan(report.turns[1].modelRequests, 0,
                             "the second turn never reached the model")
        XCTAssertTrue(report.assertions.contains {
            $0.type == "file_exists" && $0.ok
        }, "the scripted tool call did not produce its output file")

        // Recovery semantics are unchanged: every declaration applied+recovered.
        let restart = report.assertions.first { $0.type == "restart_recovered" }
        XCTAssertEqual(restart?.ok, true, restart?.detail ?? "no restart_recovered verdict")
    }

    private static func webContentKillScenario() -> Scenario {
        var mock = Scenario.Mock()
        mock.toolCallRounds = 1
        mock.toolCommand = "printf 'webcontent-kill-regression\\n' > kill-evidence.txt "
            + "&& cat kill-evidence.txt"
        mock.toolDescription = "Run the deterministic webcontent_kill tool call"
        mock.toolText = "Writing the marker file."
        mock.finalText = "Marker written."
        return Scenario(
            id: "WEB-CONTENT-KILL-REGRESSION",
            category: "selftest",
            title: "webcontent_kill applies, recovers and the session continues",
            userStory: "A killed WebContent process must recover through D14 and the "
                + "same session must run its next turn.",
            workspace: Scenario.Workspace(files: ["seed.txt": "seed\n"], fixture: nil),
            turns: [
                Scenario.Turn(prompt: "Write the marker file, then confirm it exists."),
                Scenario.Turn(prompt: "Reply with a one-line confirmation."),
            ],
            assertions: [
                Scenario.Assertion(type: "file_exists", path: "kill-evidence.txt",
                                   value: nil, command: nil, max: nil),
                Scenario.Assertion(type: "restart_recovered", path: nil, value: nil,
                                   command: nil, max: nil),
            ],
            rubric: nil,
            budget: Scenario.Budget(maxMinutes: 6, maxModelRequests: 20),
            perturbations: [
                Scenario.Perturbation(at: "after_turn:1", kind: "webcontent_kill"),
            ],
            mock: mock,
            network: nil,
            tags: ["selftest"],
            target: "macos")
    }
}
