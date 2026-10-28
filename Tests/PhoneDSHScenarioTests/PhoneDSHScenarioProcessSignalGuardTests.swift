// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2-FIX-Q3 regression: an external termination
// request must not delete the test process mid-suite.
//
// The full `swift test` suite used to end with the XCTest process gone and no
// summary: no crash report, no assertion, no `fatalError`, and no SwiftPM
// "unexpected signal" line, at test positions that varied from 1.5 s into the
// run to the 80 s abort scenario. `kill -TERM`/`kill -9` of the runner
// reproduces that log shape exactly; `kill -PIPE` does not (SwiftPM prints
// "exited with unexpected signal code 13" for it). The catchable subset of that
// class is repaired here: the harness records SIGTERM/SIGINT/SIGHUP, keeps the
// process alive, and the long waits fail loud with the signal name.
//
// The red run for this file (guard install made a no-op) is the historical
// failure mode: the test process dies inside this test and the XCTest log ends
// after the "started" line.

import Darwin
import XCTest
@testable import PhoneDSHScenario

final class PhoneDSHScenarioProcessSignalGuardTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        ScenarioProcessSignals.install()
    }

    override func setUp() {
        super.setUp()
        ScenarioProcessSignals.install()
        ScenarioProcessSignals.resetForTesting()
    }

    override func tearDown() {
        ScenarioProcessSignals.resetForTesting()
        super.tearDown()
    }

    /// Sends `signal` to this process and waits for the handler to publish it.
    /// Signal delivery is asynchronous, so the flag can become visible a few
    /// microseconds after `kill()` returns.
    @discardableResult
    private func deliver(_ signal: Int32) -> Int32? {
        _ = kill(getpid(), signal)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let seen = ScenarioProcessSignals.lastSignal { return seen }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return nil
    }

    /// The signal is recorded and the process survives it. Before the guard,
    /// this test is the end of the XCTest process.
    func testTerminationSignalIsRecordedAndTheProcessSurvives() throws {
        XCTAssertNil(ScenarioProcessSignals.lastSignal)
        XCTAssertEqual(deliver(SIGTERM), SIGTERM,
                       "the handler must record SIGTERM instead of letting the default action kill the runner")
        // Running this assertion at all is the survival proof.
        XCTAssertEqual(ScenarioProcessSignals.name(of: SIGTERM), "SIGTERM")
    }

    /// The signal is turned into a reportable error that names the mechanism,
    /// not into a silent process exit.
    func testTerminationRequestFailsLoudWithTheSignalName() throws {
        XCTAssertEqual(deliver(SIGHUP), SIGHUP)
        var thrown: Error?
        do {
            try ScenarioProcessSignals.throwIfTerminationRequested()
        } catch {
            thrown = error
        }
        let message = thrown.map { String(describing: $0) } ?? "<no error>"
        XCTAssertTrue(message.contains("SIGHUP"),
                      "the fail-loud error must name the signal: \(message)")
        XCTAssertTrue(message.contains("instead of letting the process terminate silently"),
                      "the fail-loud error must explain why the process did not die: \(message)")
    }

    /// A long wait aborts when the termination request arrives; it must not
    /// keep polling as if the run were healthy (the runner's turn wait is the
    /// exact path that ran while the 80 s scenario was killed).
    func testScenarioWaitStopsOnTerminationRequest() async throws {
        XCTAssertEqual(deliver(SIGINT), SIGINT)
        let started = Date()
        var thrown: Error?
        do {
            try await scenarioWait(timeout: 30, label: "external stop probe") { false }
        } catch {
            thrown = error
        }
        let elapsed = Date().timeIntervalSince(started)
        let message = thrown.map { String(describing: $0) } ?? "<no error>"
        XCTAssertTrue(message.contains("SIGINT"),
                      "the wait must fail with the signal name, not a timeout: \(message)")
        XCTAssertLessThan(elapsed, 5,
                          "the wait must observe the termination request on its first poll")
    }

    /// Consuming the signal clears it, so one request fails one test rather
    /// than every later test in the suite.
    func testSignalIsConsumedOnce() throws {
        XCTAssertEqual(deliver(SIGTERM), SIGTERM)
        XCTAssertEqual(ScenarioProcessSignals.takeSignal(), SIGTERM)
        XCTAssertNil(ScenarioProcessSignals.lastSignal)
        // A second request is a new event.
        XCTAssertEqual(deliver(SIGTERM), SIGTERM)
    }
}
