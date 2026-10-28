// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2-FIX-127: a failed terminal host.stop() must fail
// the scenario report instead of being swallowed after the event bus ended.
//
// `PhoneDSHHost.stop()` performs its WAL stop seal after it finishes the event
// stream, so the only signal is the thrown error. The runner used to call
// `try? await host.stop()`; a seal failure therefore left a report that could
// be PASS. `ScenarioStopFailure` is the pure merge the runner applies, and
// these tests pin both directions: a stop-only failure becomes the terminal
// diagnostic, and an earlier terminal cause is preserved with the stop detail
// appended rather than overwritten.

import XCTest
@testable import PhoneDSHScenario

final class PhoneDSHScenarioStopFailureTests: XCTestCase {
    private struct StopSealError: Error, CustomStringConvertible {
        var description: String { "the WAL stop seal failed" }
    }

    private func diagnostics(_ failure: ScenarioStopFailure) -> ScenarioReportDiagnostics {
        ScenarioReportDiagnostics(
            consoleErrors: [],
            runnerDiagnostics: ScenarioReportDiagnostics.runnerDiagnostics(
                deferred: nil,
                runnerInfra: nil,
                terminalError: failure.terminalError.map { String(describing: $0) },
                otherError: failure.otherError))
    }

    /// A stop failure with no earlier cause is itself the terminal failure: the
    /// report has no PASS path left and the runner channel names the seal.
    func testStopFailureAloneBecomesTheTerminalDiagnostic() {
        let merged = ScenarioStopFailure.merge(error: StopSealError(),
                                               terminalError: nil,
                                               otherError: nil)
        XCTAssertNil(merged.terminalError)
        XCTAssertEqual(merged.otherError,
                       "host.stop() failed: the WAL stop seal failed")
        XCTAssertEqual(merged.detail,
                       "host.stop() failed: the WAL stop seal failed")
        XCTAssertEqual(diagnostics(merged).runnerErrors,
                       ["runner: host.stop() failed: the WAL stop seal failed"])
        XCTAssertEqual(diagnostics(merged).consoleErrors, [],
                       "a runner stop failure is not Worker console output")
    }

    /// An earlier terminal cause (here a wall-budget timeout) is not
    /// overwritten; the stop detail is appended beside it.
    func testEarlierTerminalErrorIsPreservedAndStopDetailAppended() {
        let earlier = ScenarioError.timeout("budget.max_minutes=1 elapsed")
        let merged = ScenarioStopFailure.merge(error: StopSealError(),
                                               terminalError: earlier,
                                               otherError: nil)
        guard case .timeout(let detail)? = merged.terminalError else {
            return XCTFail("the earlier terminal timeout was overwritten")
        }
        XCTAssertEqual(detail, "budget.max_minutes=1 elapsed")
        XCTAssertEqual(merged.otherError,
                       "host.stop() failed: the WAL stop seal failed")
        XCTAssertEqual(diagnostics(merged).runnerErrors.count, 2,
                       "the report must carry both the first cause and the stop detail")
        XCTAssertTrue(diagnostics(merged).runnerErrors[0].contains("budget.max_minutes=1"))
        XCTAssertTrue(diagnostics(merged).runnerErrors[1].contains("host.stop() failed"))
    }

    /// An existing non-terminal error is appended to, never replaced.
    func testExistingOtherErrorIsAppendedNotReplaced() {
        let merged = ScenarioStopFailure.merge(error: StopSealError(),
                                               terminalError: nil,
                                               otherError: "artifact: report.json is unwritable")
        XCTAssertNil(merged.terminalError)
        XCTAssertEqual(merged.otherError,
                       "artifact: report.json is unwritable; "
                           + "host.stop() failed: the WAL stop seal failed")
        XCTAssertEqual(diagnostics(merged).runnerErrors,
                       ["runner: artifact: report.json is unwritable; "
                           + "host.stop() failed: the WAL stop seal failed"])
    }
}
