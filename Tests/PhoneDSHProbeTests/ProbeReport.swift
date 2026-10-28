// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — Phase 0 probe report (PLAN W3-PROBES, G0).
//
// Every probe appends one row to $TMPDIR/pdsh-probes/probe-report.json. The row
// carries the metric, the G0 threshold that applies (when PLAN §2.5 / §3–§5 or
// a landed work package defines one) and PASS/FAIL/INFO. Rows are written
// after each probe so a later crash still leaves the measurements that ran.
//
// No absolute repository path is recorded: the output directory is the
// process temporary directory (or PDSH_PROBES_DIR), never a source checkout.

import Foundation

/// One threshold a probe is compared against.
struct ProbeThreshold: Sendable {
    enum Comparison: String, Sendable {
        case lessThanOrEqual = "<="
        case greaterThanOrEqual = ">="
        case equals = "=="
    }

    var name: String
    var value: Double
    var unit: String
    var source: String
    var comparison: Comparison
    var measured: Double
    /// False for informational thresholds (the PLAN names the value but a
    /// failure does not change the G0 pass/fail summary).
    var gating: Bool

    var met: Bool {
        switch comparison {
        case .lessThanOrEqual: return measured <= value
        case .greaterThanOrEqual: return measured >= value
        case .equals: return abs(measured - value) < 0.000_001
        }
    }

    var json: [String: Any] {
        [
            "name": name,
            "value": value,
            "unit": unit,
            "source": source,
            "comparison": comparison.rawValue,
            "measured": measured,
            "met": met,
            "gating": gating,
        ]
    }
}

/// Thread-safe writer for the probe report.
final class ProbeReport: @unchecked Sendable {
    static let shared = ProbeReport()

    private let lock = NSLock()
    private var rows: [[String: Any]] = []
    private let directory: URL
    let fileURL: URL

    private init() {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["PDSH_PROBES_DIR"], !configured.isEmpty {
            directory = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdsh-probes", isDirectory: true)
        }
        fileURL = directory.appendingPathComponent("probe-report.json")
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: fileURL)
        writeLocked()
    }

    /// Starts a fresh report. `XCTest` calls this once per test class.
    func reset() {
        lock.lock()
        rows.removeAll()
        lock.unlock()
        write()
    }

    /// Appends one row and rewrites the report atomically.
    func record(probe: String,
                kind: String,
                status: String,
                gating: Bool,
                metrics: [String: Any],
                threshold: ProbeThreshold? = nil,
                detail: String = "") {
        var row: [String: Any] = [
            "probe": probe,
            "kind": kind,
            "status": status,
            "gating": gating,
            "metrics": metrics,
            "detail": detail,
        ]
        if let threshold {
            row["threshold"] = threshold.json
        } else {
            row["threshold"] = [
                "name": "none",
                "unit": "",
                "source": "no numeric G0 bound in PLAN §2.5 / §3–§5",
                "gating": false,
                "comparison": "n/a",
                "measured": NSNull(),
                "met": NSNull(),
            ] as [String: Any]
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        row["recorded_at"] = stamp
        lock.lock()
        rows.append(row)
        lock.unlock()
        write()
    }

    /// The rows recorded so far (ordered by completion).
    func snapshot() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return rows
    }

    private func write() {
        lock.lock()
        writeLocked()
        lock.unlock()
    }

    private func writeLocked() {
        let counts = rows.reduce(into: (pass: 0, fail: 0, info: 0)) { counts, row in
            switch row["status"] as? String {
            case "PASS": counts.pass += 1
            case "FAIL": counts.fail += 1
            default: counts.info += 1
            }
        }
        let failedProbes = rows.compactMap { row -> String? in
            guard row["gating"] as? Bool == true,
                  row["status"] as? String == "FAIL" else { return nil }
            return row["probe"] as? String
        }
        let report: [String: Any] = [
            "schema": 1,
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "platform": "macOS",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "g0_thresholds": [
                [
                    "name": "loopback_round_trip_p95",
                    "value": 5.0,
                    "unit": "ms",
                    "source": "PLAN §2.5 and spec/v1/budgets.md §4",
                    "gating": true,
                ],
                [
                    "name": "checkpoint_100_files",
                    "value": 100.0,
                    "unit": "ms",
                    "source": "PLAN W1-LOG (informational materialization bound)",
                    "gating": false,
                ],
                [
                    "name": "recovery_time_target",
                    "value": "a + k*MB, a <= 3 s, k <= 0.05 s/MB",
                    "unit": "s",
                    "source": "PLAN §2.5 and spec/v1/budgets.md §4",
                    "gating": false,
                ],
            ],
            "summary": [
                "pass": counts.pass,
                "fail": counts.fail,
                "info": counts.info,
                "g0_passed": failedProbes.isEmpty,
                "failed_gating_probes": failedProbes,
            ],
            "rows": rows,
        ]
        guard JSONSerialization.isValidJSONObject(report),
              let data = try? JSONSerialization.data(
                withJSONObject: report,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Convenience: builds the row status from a correctness predicate and an
/// optional threshold. Correctness always gates; a non-gating (informational)
/// threshold never changes the status.
func probeStatus(correct: Bool,
                 threshold: ProbeThreshold? = nil) -> String {
    guard correct else { return "FAIL" }
    guard let threshold else { return "PASS" }
    guard threshold.gating else { return "INFO" }
    return threshold.met ? "PASS" : "FAIL"
}
