// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS Phase 0 probe app (PLAN W3-APP).
//
// Memory page: boots PhoneDSHHost with the packed Worker image and a synthetic
// 20/50/100 MB overlay, runs a scripted long host session and records the
// WebContent termination count plus process proxy metrics over time.
//
// The overlay fixtures live under the workspace log's materialized tree; the
// host packs them into the boot overlay (gzip tar, D21) and the Worker loads
// them. The first boot of a level creates the workspace manifest, so a level
// run may boot twice. NOT_VERIFIED on an iPhone: jetsam behaviour and the real
// memory ceiling are device facts this page only observes.

import ProbeKit
import SwiftUI
import PhoneDSH

struct MemoryPage: View {
    @Environment(AppModel.self) private var model

    private var runner: MemoryProbeRunner { model.memory }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    bundleCard
                    controls
                    progressCard
                    liveCard
                    resultsCard
                    sessionCard
                }
                .padding(16)
            }
            .background(VisibleAnchorView(anchor: runner.anchor)
                .frame(width: 2, height: 2)
                .opacity(0.01),
                alignment: .topLeading)
            .navigationTitle("Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel", role: .destructive) {
                        runner.cancel()
                    }
                    .disabled(runner.isRunning == false)
                }
            }
        }
    }

    private var bundleCard: some View {
        PageSection("Worker bundle") {
            if runner.bundleInstalled {
                KeyValueLine(key: "Bundle/worker", value: "installed")
                Text("Run scripts/copy-bundle-assets.sh to refresh it from "
                     + "plugins/scripts/pack-image.mjs output.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(runner.bundleDetail)
                    .font(.caption)
                    .foregroundStyle(.red)
                Text("The Memory and Background pages need the packed Worker image. "
                     + "The Probes page does not; it runs with the probe fixtures only.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            LockdownBadge(lockdown: model.lockdown)
        }
    }

    private var controls: some View {
        PageSection("Overlay levels") {
            ForEach(SyntheticOverlay.levelsMB, id: \.self) { level in
                Button {
                    runner.run(levelMB: level)
                } label: {
                    HStack {
                        Text("Run \(level) MB overlay")
                        Spacer()
                        if runner.runningLevelMB == level && runner.isRunning {
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(runner.isRunning || runner.bundleInstalled == false)
            }
            Button {
                runner.runLongSession()
            } label: {
                Label("Run long scripted session (no overlay)",
                      systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(runner.isRunning || runner.bundleInstalled == false)
            Text("One level boots the host twice: the first boot creates the "
                 + "workspace manifest, then the synthetic overlay is seeded and "
                 + "the host boots again. Keep this page open while it runs.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var progressCard: some View {
        PageSection("Progress") {
            KeyValueLine(key: "phase", value: runner.phase.rawValue)
            Text(runner.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let lastRunAt = runner.lastRunAt {
                KeyValueLine(key: "last run", value: lastRunAt)
            }
        }
    }

    private var liveCard: some View {
        PageSection("Live samples") {
            if runner.liveSamples.isEmpty {
                Text("No sample yet. A run records one sample at the start and "
                     + "one per scripted stage.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(runner.liveSamples.suffix(8).enumerated()),
                        id: \.offset) { _, sample in
                    KeyValueLine(
                        key: "t+\(String(format: "%.0f", sample.offsetSeconds))s",
                        value: "\(Self.bytes(sample.footprintBytes)) · avail "
                            + "\(Self.bytes(sample.availableBytes)) · "
                            + "\(sample.hostState ?? "—")")
                }
                Text("Proxy metrics only: the App-process phys_footprint and "
                     + "os_proc_available_memory; WebContent is a separate process.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var resultsCard: some View {
        PageSection("Measured levels") {
            ForEach(model.store.memory.levels, id: \.overlayMB) { level in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("\(level.overlayMB) MB")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(level.status)
                            .font(.caption2.monospaced())
                            .foregroundStyle(level.status == "MEASURED"
                                             ? .green : .secondary)
                    }
                    if level.status == "MEASURED" || level.status == "FAILED" {
                        KeyValueLine(key: "boot", value: Self.seconds(level.bootSeconds))
                        KeyValueLine(key: "duration", value: Self.seconds(level.durationSeconds))
                        KeyValueLine(key: "WebContent terminations",
                                     value: level.webContentTerminations.map(String.init) ?? "—")
                        KeyValueLine(key: "peak footprint",
                                     value: Self.bytes(level.peakFootprintBytes))
                        KeyValueLine(key: "min available",
                                     value: Self.bytes(level.minAvailableBytes))
                        KeyValueLine(key: "samples", value: "\(level.samples.count)")
                    }
                    if let detail = level.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if level.overlayMB != model.store.memory.levels.last?.overlayMB {
                    Divider()
                }
            }
        }
    }

    private var sessionCard: some View {
        PageSection("Session") {
            let session = model.store.memory.session
            KeyValueLine(key: "status", value: session.status)
            if session.status != "NOT_VERIFIED" {
                KeyValueLine(key: "planned restarts",
                             value: session.plannedRestarts.map(String.init) ?? "—")
                KeyValueLine(key: "WebContent terminations",
                             value: session.webContentTerminations.map(String.init) ?? "—")
                KeyValueLine(key: "peak footprint",
                             value: Self.bytes(session.peakFootprintBytes))
                KeyValueLine(key: "samples",
                             value: "\(session.samples.count)")
            } else {
                Text("Empty until a Memory run records the scripted session. "
                     + "The probe App ships no model upstream, so this session "
                     + "exercises lifecycle and overlay reloads, not model turns.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let detail = session.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }

    private static func seconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f s", value)
    }
}
