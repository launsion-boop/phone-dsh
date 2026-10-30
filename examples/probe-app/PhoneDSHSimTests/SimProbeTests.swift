// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS Simulator G0 probe suite (PLAN W3-SIM / W3-PROBES).
//
// Runs the *same* Phase 0 probe implementation the Probes page and the macOS
// `PhoneDSHProbeTests` target use: ``ProbeSuiteRunner`` from ProbeKit. This
// target adds no probe code. It only attaches the probe WebViews to a
// one-point visible window (a hostless XCTest has no App scene), writes
// `probe-report.json` into `SimEnvironment.reportsDirectory()`.
// ProbeKit labels each row with the actual execution environment. Simulator and
// physical-device reports remain separate evidence and are never interchanged.

import Foundation
import ProbeKit
import XCTest

@MainActor
final class PhoneDSHSimProbeTests: XCTestCase {
    func testPhase0ProbeSuite() async throws {
        let directory = try SimEnvironment.reportsDirectory()
        let report = ProbeReport(directory: directory,
                                 environment: SimEnvironment.label)
        let window = SimVisibleWindow()
        defer { window.shutdown() }
        guard window.isAttached else {
            throw SimError.assertion("the one-point probe window is not attached")
        }

        let runner = ProbeSuiteRunner(report: report)
        let clock = ContinuousClock()
        let started = clock.now
        await runner.runAll(anchor: window.anchor)
        let elapsed = started.duration(to: clock.now)
        let milliseconds = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000

        let rows = report.snapshot()
        let summary = report.summary()
        let gatingRows = rows.filter(\.gating)
        try Self.augmentProbeReport(at: report.fileURL,
                                    elapsedMilliseconds: milliseconds,
                                    summary: summary)
        print("sim-probe: \(rows.count) rows, pass=\(summary.pass) "
              + "fail=\(summary.fail) info=\(summary.info) "
              + "g0_passed=\(summary.g0Passed) elapsed_ms=\(Int(milliseconds))")
        for row in rows where row.gating {
            print("sim-probe: \(row.probe) \(row.status.rawValue) "
                  + "environment=\(row.environment)")
        }

        XCTAssertFalse(gatingRows.isEmpty,
                       "the G0 probe suite recorded no gating row")
        XCTAssertTrue(summary.g0Passed,
                      "G0 failed: " + summary.failedGatingProbes.joined(separator: ", "))
        XCTAssertEqual(report.document().environment, SimEnvironment.label,
                       "the report environment must match its execution target")
    }

    /// Adds the suite envelope and a no-bound threshold on rows that ProbeKit
    /// leaves without one, so every report row in `$OUT` carries a G0 bound
    /// (or an explicit `n/a` marker) and the shell table prints one shape.
    private static func augmentProbeReport(at url: URL,
                                           elapsedMilliseconds: Double,
                                           summary: ProbeSummary) throws {
        guard let data = try? Data(contentsOf: url),
              var document = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            throw SimError.artifact("cannot read \(url.lastPathComponent)")
        }
        document["suite"] = "probe"
        document["gate"] = "G0"
        document["ok"] = summary.g0Passed
        document["elapsed_ms"] = elapsedMilliseconds
        document["device"] = [
            "model": SimEnvironment.simulatorModel ?? DeviceReportStore.hardwareModel(),
            "system": SimEnvironment.systemVersion,
            "is_simulator": SimEnvironment.isSimulator,
        ]
        if var rows = document["rows"] as? [[String: Any]] {
            for index in rows.indices where rows[index]["threshold"] == nil {
                rows[index]["threshold"] = [
                    "name": "none",
                    "value": "n/a",
                    "unit": "",
                    "source": "no numeric G0 bound is defined for this probe",
                    "comparison": "n/a",
                    "measured": "n/a",
                    "gating": false,
                ] as [String: Any]
            }
            document["rows"] = rows
        }
        let encoded = try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try encoded.write(to: url, options: .atomic)
    }
}
