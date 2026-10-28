// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS Phase 0 probe app (PLAN W3-APP).
//
// Probes page: runs the W3-PROBES suite on the device UI actor and lists every
// PASS/FAIL/INFO row with the G0 bound it was compared against.
//
// The rows are measurements of this process. A row that has not run is absent;
// the page never shows a placeholder number. Device readings are NOT_VERIFIED
// until the operator runs this page on a device and exports the report.

import ProbeKit
import SwiftUI
import PhoneDSH

struct ProbesPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    LockdownBadge(lockdown: model.lockdown)
                    actions
                    if model.probeRows.isEmpty {
                        emptyState
                    } else {
                        rows
                    }
                    thresholds
                }
                .padding(16)
            }
            .background(VisibleAnchorView(anchor: model.probeAnchor)
                .frame(width: 2, height: 2)
                .opacity(0.01),
                alignment: .topLeading)
            .navigationTitle("Probes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reset", systemImage: "arrow.counterclockwise") {
                        model.resetProbes()
                    }
                    .disabled(model.probeRunning)
                }
            }
        }
    }

    private var header: some View {
        PageSection("Environment") {
            KeyValueLine(key: "Environment", value: ProbeEnvironment.current)
            KeyValueLine(key: "OS", value: ProcessInfo.processInfo.operatingSystemVersionString)
            KeyValueLine(key: "Bundle", value: Bundle.main.bundleIdentifier ?? "unknown")
            Text("Every row below is produced by the same probe implementations as "
                 + "the macOS PhoneDSHProbeTests suite, ported to the iOS UI actor in ProbeKit. "
                 + "G0 bounds come from PLAN §2.5 and spec/v1/budgets.md §4.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                model.runAllProbes()
            } label: {
                Label("Run all probes", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.probeRunning)

            Menu {
                ForEach(ProbeGroup.allCases) { group in
                    Button(group.title) { model.runProbe(group) }
                }
            } label: {
                Label("Run one group", systemImage: "list.bullet")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.probeRunning)

            if model.probeRunning {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
            Text(model.probeStatusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if model.probeRunning == false && model.probeSummary.g0Passed == false {
                Text("G0 failed: \(model.probeSummary.failedGatingProbes.joined(separator: ", "))")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.red)
            }
        }
    }

    private var emptyState: some View {
        PageSection("Rows") {
            Text("No probe has run in this launch. Rows appear only after a run; "
                 + "device-only numbers stay empty until then.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var rows: some View {
        PageSection("Rows (\(model.probeRows.count))") {
            KeyValueLine(key: "PASS / FAIL / INFO",
                         value: "\(model.probeSummary.pass) / \(model.probeSummary.fail) / \(model.probeSummary.info)")
            KeyValueLine(key: "G0", value: model.probeSummary.g0Passed ? "PASS" : "FAIL")
            ForEach(Array(model.probeRows.enumerated()), id: \.offset) { _, row in
                Divider()
                rowView(row)
            }
        }
    }

    private func rowView(_ row: ProbeRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.probe)
                    .font(.caption.weight(.semibold))
                    .monospaced()
                Spacer()
                ProbeStatusChip(status: row.status)
            }
            ForEach(row.metrics.keys.sorted(), id: \.self) { key in
                KeyValueLine(key: key,
                             value: row.metrics[key]?.displayText ?? "—")
            }
            if let threshold = row.threshold {
                Text("G0 \(threshold.name): \(threshold.comparison.rawValue) "
                     + "\(threshold.value.displayText) \(threshold.unit)"
                     + (threshold.met.map { " · met=\($0)" } ?? ""))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if row.gating == false {
                Text("non-gating")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if row.detail.isEmpty == false {
                Text(row.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("\(row.environment) · \(row.recordedAt)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var thresholds: some View {
        PageSection("G0 thresholds") {
            ForEach(Array(ProbeReport.g0Thresholds.enumerated()), id: \.offset) { _, bound in
                VStack(alignment: .leading, spacing: 2) {
                    Text(bound.name)
                        .font(.caption.weight(.semibold))
                        .monospaced()
                    KeyValueLine(key: "bound",
                                 value: "\(bound.value.displayText) \(bound.unit)")
                    KeyValueLine(key: "gating", value: bound.gating ? "yes" : "no")
                    Text(bound.source)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if bound.name != ProbeReport.g0Thresholds.last?.name {
                    Divider()
                }
            }
        }
    }
}
