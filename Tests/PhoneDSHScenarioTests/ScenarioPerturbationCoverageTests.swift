// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: perturbation coverage.
//
// Regression tests for the recovery-coverage rule. Before the fix the runner
// recorded a perturbation only when its point was reached on the success path,
// and `restart_recovered` treated "no perturbation report" as a pass. A run
// that timed out or errored before its declared point therefore produced an
// empty `perturbations` list plus a green `restart_recovered` assertion.
//
// The rule lives in `ScenarioPerturbationCoverage`, a pure mapping from the
// declared points and the reports the run produced. These tests are
// deterministic and need no model key and no WKWebView boot.

import XCTest
@testable import PhoneDSHScenario

final class PhoneDSHScenarioPerturbationCoverageTests: XCTestCase {
    private func declared(_ at: String,
                          _ kind: String) -> ScenarioPerturbationCoverage.Declared {
        ScenarioPerturbationCoverage.Declared(at: at, kind: kind)
    }

    private func report(_ at: String, _ kind: String, ok: Bool?,
                        recoveredMs: Int? = nil,
                        detail: String? = nil) -> ScenarioPerturbationReport {
        ScenarioPerturbationReport(at: at, kind: kind, recoveredMs: recoveredMs,
                                   ok: ok, detail: detail)
    }

    // MARK: Error exits before the declared point

    /// G2-A05 shape: `after_turn:1` + `worker_kill` declared, the run times out
    /// before turn 1 ends, so no perturbation report exists. The report must
    /// still carry the skipped entry and recovery must be reported as not
    /// proven.
    func testTimedOutRunRecordsSkippedEntryAndFailsRestartRecovered() {
        let result = ScenarioPerturbationCoverage.resolve(
            declared: [declared("after_turn:1", "worker_kill")],
            appliedReports: [],
            runStatus: "TIMEOUT")

        XCTAssertEqual(result.entries.count, 1)
        guard let entry = result.entries.first else {
            return XCTFail("the skipped perturbation is missing from the report")
        }
        XCTAssertEqual(entry.at, "after_turn:1")
        XCTAssertEqual(entry.kind, "worker_kill")
        XCTAssertNil(entry.ok, "a skipped perturbation has no applied result")
        let detail = entry.detail ?? ""
        XCTAssertTrue(detail.contains("skipped"), "detail must name the skipped state: \(detail)")
        XCTAssertTrue(detail.contains("after_turn:1"), "detail must name the point: \(detail)")
        XCTAssertTrue(detail.contains("TIMEOUT"), "detail must name the run status: \(detail)")

        XCTAssertFalse(result.restartRecovered.ok,
                       "zero declared perturbations exercised cannot count as recovered")
        XCTAssertTrue(result.restartRecovered.detail.contains("after_turn:1"),
                      "the verdict must list the unexercised point: "
                        + result.restartRecovered.detail)
    }

    /// The same coverage rule for a non-timeout error exit.
    func testErroredRunBeforePointAlsoFailsRestartRecovered() {
        let result = ScenarioPerturbationCoverage.resolve(
            declared: [declared("minute:2", "planned_restart")],
            appliedReports: [],
            runStatus: "ERROR")

        XCTAssertEqual(result.entries.count, 1)
        guard let entry = result.entries.first else {
            return XCTFail("the skipped perturbation is missing from the report")
        }
        XCTAssertNil(entry.ok)
        XCTAssertTrue((entry.detail ?? "").contains("ERROR"))
        XCTAssertFalse(result.restartRecovered.ok)
        XCTAssertTrue(result.restartRecovered.detail.contains("minute:2"))
    }

    // MARK: No declarations stay green

    /// A scenario that declares no perturbations has nothing to exercise; its
    /// `restart_recovered` assertion still passes.
    func testScenarioWithoutDeclarationsStillPassesRestartRecovered() {
        let result = ScenarioPerturbationCoverage.resolve(
            declared: [],
            appliedReports: [],
            runStatus: "completed")

        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertTrue(result.restartRecovered.ok,
                      "a scenario with no perturbations must stay ok:true")
    }

    // MARK: Uniform across points and kinds

    /// The rule is not allowed to special-case a point or a kind: every
    /// declared `after_turn` / `during_first_tool` / `minute` point and every
    /// perturbation kind becomes a skipped entry and appears in the verdict.
    func testEveryPointAndKindGetsASkippedEntryAndIsNamed() {
        let points = ["after_turn:1", "during_first_tool", "minute:2"]
        let kinds = ["planned_restart", "park_resume", "worker_kill", "webcontent_kill"]
        var declarations: [ScenarioPerturbationCoverage.Declared] = []
        for point in points {
            for kind in kinds {
                declarations.append(declared(point, kind))
            }
        }

        let result = ScenarioPerturbationCoverage.resolve(
            declared: declarations,
            appliedReports: [],
            runStatus: "BUDGET")

        XCTAssertEqual(result.entries.count, declarations.count)
        for (entry, declaration) in zip(result.entries, declarations) {
            XCTAssertEqual(entry.at, declaration.at)
            XCTAssertEqual(entry.kind, declaration.kind)
            XCTAssertNil(entry.ok)
            let detail = entry.detail ?? ""
            XCTAssertTrue(detail.contains("skipped"))
            XCTAssertTrue(detail.contains(declaration.at))
            XCTAssertTrue(detail.contains("BUDGET"))
        }
        XCTAssertFalse(result.restartRecovered.ok)
        for declaration in declarations {
            XCTAssertTrue(result.restartRecovered.detail.contains(declaration.at),
                          "verdict misses \(declaration.at): \(result.restartRecovered.detail)")
            XCTAssertTrue(result.restartRecovered.detail.contains(declaration.kind),
                          "verdict misses \(declaration.kind): \(result.restartRecovered.detail)")
        }
    }

    // MARK: Applied results are preserved, partial coverage fails

    func testPartiallyExercisedDeclarationsFailAndNameTheMiss() {
        let result = ScenarioPerturbationCoverage.resolve(
            declared: [
                declared("after_turn:1", "planned_restart"),
                declared("after_turn:2", "worker_kill"),
            ],
            appliedReports: [
                report("after_turn:1", "planned_restart", ok: true, recoveredMs: 120),
            ],
            runStatus: "TIMEOUT")

        XCTAssertEqual(result.entries.count, 2)
        guard result.entries.count == 2 else { return }
        XCTAssertEqual(result.entries[0].at, "after_turn:1")
        XCTAssertEqual(result.entries[0].ok, true, "an applied result must be kept")
        XCTAssertEqual(result.entries[0].recoveredMs, 120)
        XCTAssertEqual(result.entries[1].at, "after_turn:2")
        XCTAssertNil(result.entries[1].ok)

        XCTAssertFalse(result.restartRecovered.ok)
        XCTAssertTrue(result.restartRecovered.detail.contains("after_turn:2"),
                      "the unexercised point must be named: \(result.restartRecovered.detail)")
        XCTAssertFalse(result.restartRecovered.detail.contains("unexercised perturbation point(s): after_turn:1"),
                       "an exercised point must not be listed as a miss")
    }

    func testAppliedButUnrecoveredPointFailsAndKeepsTheResult() {
        let result = ScenarioPerturbationCoverage.resolve(
            declared: [declared("during_first_tool", "planned_restart")],
            appliedReports: [
                report("during_first_tool", "planned_restart", ok: false,
                       detail: "the host did not return to Running"),
            ],
            runStatus: "completed")

        XCTAssertEqual(result.entries.count, 1)
        guard let entry = result.entries.first else {
            return XCTFail("the applied perturbation report was dropped")
        }
        XCTAssertEqual(entry.ok, false)
        XCTAssertEqual(entry.detail, "the host did not return to Running")
        XCTAssertFalse(result.restartRecovered.ok)
        XCTAssertTrue(result.restartRecovered.detail.contains("during_first_tool"))
        XCTAssertTrue(result.restartRecovered.detail.contains("unrecovered"))
    }

    func testAllDeclaredPerturbationsAppliedAndRecoveredPasses() {
        let result = ScenarioPerturbationCoverage.resolve(
            declared: [
                declared("after_turn:1", "park_resume"),
                declared("minute:9", "webcontent_kill"),
            ],
            appliedReports: [
                report("after_turn:1", "park_resume", ok: true, recoveredMs: 287),
                report("minute:9", "webcontent_kill", ok: true, recoveredMs: 20400),
            ],
            runStatus: "completed")

        XCTAssertEqual(result.entries.count, 2)
        XCTAssertTrue(result.entries.allSatisfy { $0.ok == true })
        XCTAssertTrue(result.restartRecovered.ok)
        XCTAssertFalse(result.restartRecovered.detail.contains("unexercised"))
    }

    // MARK: Unavailable perturbations are a distinct terminal category

    /// A matched report with `ok: null` is the terminal state W13 records when
    /// a perturbation kind cannot run on this host (the iOS Simulator test
    /// process has no host WebContent process to kill). The entry must be
    /// preserved, but the verdict names it as unavailable instead of folding
    /// it into the "applied but unrecovered" list, and it still fails loud:
    /// recovery was not proven.
    func testUnavailableMatchKeepsEntryAndGetsItsOwnVerdictCategory() {
        let unavailableDetail = "not available on this runner: no host WebContent process"
        let result = ScenarioPerturbationCoverage.resolve(
            declared: [
                declared("after_turn:1", "park_resume"),
                declared("after_turn:2", "webcontent_kill"),
            ],
            appliedReports: [
                report("after_turn:1", "park_resume", ok: true, recoveredMs: 120),
                report("after_turn:2", "webcontent_kill", ok: nil,
                       detail: unavailableDetail),
            ],
            runStatus: "completed")

        XCTAssertEqual(result.entries.count, 2)
        guard result.entries.count == 2 else { return }
        XCTAssertEqual(result.entries[0].at, "after_turn:1")
        XCTAssertEqual(result.entries[0].ok, true)
        XCTAssertEqual(result.entries[1].at, "after_turn:2")
        XCTAssertEqual(result.entries[1].kind, "webcontent_kill")
        XCTAssertNil(result.entries[1].ok, "unavailable keeps the ok:null result")
        XCTAssertEqual(result.entries[1].detail, unavailableDetail,
                       "the runner's detail must be preserved")
        XCTAssertFalse(result.restartRecovered.ok)
        let verdict = result.restartRecovered.detail
        XCTAssertTrue(verdict.contains("unavailable perturbation point(s)"), verdict)
        XCTAssertTrue(verdict.contains("after_turn:2 (webcontent_kill)"), verdict)
        XCTAssertFalse(verdict.contains("unrecovered"), verdict)
        XCTAssertFalse(verdict.contains("unexercised"), verdict)
    }

    /// A run whose only declared perturbation is unavailable on this host must
    /// still fail `restart_recovered`; "nothing was applied" is not a pass.
    func testAllUnavailableDeclarationsFailLoud() {
        let result = ScenarioPerturbationCoverage.resolve(
            declared: [declared("minute:2", "webcontent_kill")],
            appliedReports: [
                report("minute:2", "webcontent_kill", ok: nil,
                       detail: "not available on this runner"),
            ],
            runStatus: "TIMEOUT")

        XCTAssertEqual(result.entries.count, 1)
        XCTAssertNil(result.entries.first?.ok)
        XCTAssertFalse(result.restartRecovered.ok,
                       "an unavailable point cannot prove recovery")
        let verdict = result.restartRecovered.detail
        XCTAssertTrue(verdict.contains(
            "unavailable perturbation point(s): minute:2 (webcontent_kill)"), verdict)
        XCTAssertTrue(verdict.contains("run status TIMEOUT"), verdict)
    }

    /// The verdict keeps the three coverage categories separate so an operator
    /// can tell "never reached", "cannot run here" and "ran but did not
    /// recover" apart; all of them fail the assertion.
    func testVerdictListsEveryCoverageCategorySeparately() {
        let result = ScenarioPerturbationCoverage.resolve(
            declared: [
                declared("after_turn:1", "planned_restart"),
                declared("after_turn:2", "worker_kill"),
                declared("during_first_tool", "webcontent_kill"),
                declared("after_turn:4", "planned_restart"),
            ],
            appliedReports: [
                report("after_turn:1", "planned_restart", ok: true, recoveredMs: 100),
                report("after_turn:2", "worker_kill", ok: false,
                       detail: "the host did not return to Running"),
                report("during_first_tool", "webcontent_kill", ok: nil,
                       detail: "not available on this runner"),
            ],
            runStatus: "completed")

        XCTAssertEqual(result.entries.count, 4)
        XCTAssertFalse(result.restartRecovered.ok)
        let verdict = result.restartRecovered.detail
        XCTAssertTrue(verdict.contains(
            "unexercised perturbation point(s): after_turn:4 (planned_restart)"), verdict)
        XCTAssertTrue(verdict.contains(
            "unavailable perturbation point(s): during_first_tool (webcontent_kill)"), verdict)
        XCTAssertTrue(verdict.contains(
            "unrecovered perturbation point(s): after_turn:2 (worker_kill)"), verdict)
    }

    // MARK: Unrecognized points stay covered

    /// A point the runner does not recognize is preserved instead of being
    /// dropped from the pending list, so it cannot disappear from the report
    /// or from the verdict.
    func testUnrecognizedPointIsPreservedInTheCoverageReport() {
        XCTAssertEqual(ScenarioRun.pointLabel(for: "after_turn:1"), "after_turn:1")
        XCTAssertEqual(ScenarioRun.pointLabel(for: "during_first_tool"),
                       "during_first_tool")
        let label = ScenarioRun.pointLabel(for: "during_second_tool")
        XCTAssertEqual(label, "during_second_tool",
                       "an unknown point keeps its catalog spelling")

        let result = ScenarioPerturbationCoverage.resolve(
            declared: [declared(label, "park_resume")],
            appliedReports: [],
            runStatus: "TIMEOUT")

        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries.first?.at, "during_second_tool")
        XCTAssertNil(result.entries.first?.ok)
        XCTAssertFalse(result.restartRecovered.ok)
        XCTAssertTrue(result.restartRecovered.detail.contains("during_second_tool"),
                      result.restartRecovered.detail)
    }
}
