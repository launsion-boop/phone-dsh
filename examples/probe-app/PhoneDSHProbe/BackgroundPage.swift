// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS Phase 0 probe app (PLAN W3-APP).
//
// Background page: the background / lock × 10 minutes × with/without
// BGContinuedProcessingTask matrix. The operator starts a cell, then presses
// Home or locks the phone. The runner parks the host, samples what the
// platform allows, records every transition, and resumes on return to the
// foreground.
//
// NOT_VERIFIED on an iPhone: BGContinuedProcessingTask scheduling, background
// suspension, lock detection on devices without protected data and the actual
// 10-minute survival are all measured facts, never assumptions.

import ProbeKit
import SwiftUI
import PhoneDSH

struct BackgroundPage: View {
    @Environment(AppModel.self) private var model

    private var runner: BackgroundProbeRunner { model.background }

    var body: some View {
        @Bindable var runner = model.background
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    PageSection("Matrix cell") {
                        Picker("Scenario", selection: $runner.scenario) {
                            ForEach(BackgroundProbeRunner.Scenario.allCases, id: \.self) {
                                Text($0.title).tag($0)
                            }
                        }
                        .pickerStyle(.segmented)
                        Toggle("BGContinuedProcessingTask window",
                               isOn: $runner.continuedProcessing)
                        Text("On iOS 26 the SDK submits a BGContinuedProcessingTask "
                             + "drain window; on older systems or when scheduling is "
                             + "refused it falls back to beginBackgroundTask. "
                             + "NOT_VERIFIED until a device run records the arm.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Picker("Required window", selection: $runner.requiredSeconds) {
                            Text("10 minutes (PLAN)").tag(600.0)
                            Text("60 seconds (UI check)").tag(60.0)
                        }
                        .pickerStyle(.segmented)
                        Text("Only the 10-minute cell satisfies the PLAN matrix; the "
                             + "60-second run is a UI smoke and exports as PARTIAL.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    PageSection("Run") {
                        HStack {
                            Button {
                                runner.start()
                            } label: {
                                Label("Start cell", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(runner.isRunning || runner.bundleInstalled == false)
                            Button("Cancel", role: .destructive) {
                                runner.cancel()
                            }
                            .buttonStyle(.bordered)
                            .disabled(runner.isRunning == false)
                        }
                        if runner.isRunning == false && runner.bundleInstalled == false {
                            Text(runner.bundleDetail)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                        Text(instruction)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        KeyValueLine(key: "phase", value: runner.phase.rawValue)
                        Text(runner.statusText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    PageSection("Observation") {
                        KeyValueLine(key: "OS window", value: runner.openedArm ?? "—")
                        KeyValueLine(key: "lock observed",
                                     value: runner.lockObserved ? "yes" : "no")
                        KeyValueLine(key: "background interval",
                                     value: runner.observedBackgroundSeconds
                                        .map { String(format: "%.1f s", $0) } ?? "—")
                        KeyValueLine(key: "recovered",
                                     value: runner.recovered.map { $0 ? "yes" : "no" } ?? "—")
                        KeyValueLine(key: "recovery",
                                     value: runner.recoverySeconds
                                        .map { String(format: "%.2f s", $0) } ?? "—")
                        KeyValueLine(key: "host state", value: runner.hostStateText)
                        if let lastError = runner.lastError {
                            Text(lastError)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                        LockdownBadge(lockdown: model.lockdown)
                    }

                    PageSection("Matrix results") {
                        ForEach(Array(model.store.background.cells.enumerated()),
                                id: \.offset) { _, cell in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(cell.scenario)
                                        .font(.caption.weight(.semibold))
                                    Text(cell.continuedProcessing
                                         ? "continued processing" : "no continued processing")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(cell.status)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(cell.status == "MEASURED"
                                                         ? .green : .secondary)
                                }
                                KeyValueLine(key: "arm", value: cell.arm ?? "—")
                                KeyValueLine(key: "observed",
                                             value: cell.observedBackgroundSeconds
                                                .map { String(format: "%.1f s", $0) } ?? "—")
                                KeyValueLine(key: "held window",
                                             value: cell.heldFullWindow.map { $0 ? "yes" : "no" } ?? "—")
                                KeyValueLine(key: "recovered",
                                             value: cell.recovered.map { $0 ? "yes" : "no" } ?? "—")
                                if let detail = cell.detail {
                                    Text(detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if cell.scenario != model.store.background.cells.last?.scenario {
                                Divider()
                            }
                        }
                        Text("A simulator run is recorded with environment=ios-simulator; "
                             + "it is not device evidence.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    PageSection("Transitions") {
                        if runner.transitions.isEmpty {
                            Text("No transition recorded yet.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(runner.transitions.suffix(14).enumerated()),
                                    id: \.offset) { _, transition in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(transition.kind)
                                        .font(.caption2.weight(.semibold))
                                        .monospaced()
                                    Text(transitionText(transition))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(VisibleAnchorView(anchor: runner.anchor)
                .frame(width: 2, height: 2)
                .opacity(0.01),
                alignment: .topLeading)
            .navigationTitle("Background")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var instruction: String {
        switch runner.scenario {
        case .background:
            return "Press Home (or swipe up) after starting. Keep the App in the "
                + "background for the required window, then reopen it. The runner "
                + "parks the host on the way out and resumes it on return."
        case .lock:
            return "Lock the phone with the side button after starting. Keep it "
                + "locked for the required window, then unlock it. The runner "
                + "records protected-data notifications as the lock signal; a "
                + "device without protected data may not emit them."
        }
    }

    private func transitionText(_ transition: BackgroundTransition) -> String {
        var parts: [String] = []
        if let from = transition.from, let to = transition.to {
            parts.append("\(from) -> \(to)")
        }
        if let detail = transition.detail, detail.isEmpty == false {
            parts.append(detail)
        }
        parts.append(transition.at)
        return parts.joined(separator: " · ")
    }
}
