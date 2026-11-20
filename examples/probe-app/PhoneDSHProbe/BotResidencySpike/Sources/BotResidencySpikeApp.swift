// SPDX-License-Identifier: MIT
#if BOT_RESIDENCY_SPIKE

import SwiftUI
import ProbeKit

@main
struct BotResidencySpikeApp: App {
    // The delegate receives the background push and registers the BGProcessing
    // task for both spike modes. It is inert unless the engine-wake mode is
    // selected by arguments or by the armed configuration of a relaunch.
    @UIApplicationDelegateAdaptor(EngineWakeAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            if EngineWakeMode.isEnabled {
                EngineWakeRootView()
            } else {
                BotResidencyRootView()
            }
        }
    }
}

/// The original WP1 residency UI, unchanged.
private struct BotResidencyRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = BotResidencyRunner()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("WP1 WebContent residency")
                    .font(.title2.weight(.semibold))
                Text(model.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LabeledContent("Phase", value: model.phase)
                LabeledContent("Injected", value: "\(model.injectedCount)")
                LabeledContent("Delivered", value: "\(model.deliveredCount)")
                LabeledContent("WebContent terminations", value: "\(model.terminationCount)")
                Text("The host script decides PASS, FAIL, or NOT_RUN from this app's evidence, devicectl SIGKILL results, and lock-state samples. A scripted loopback model is used; no real-model claim is made.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(BotResidencyAnchorView(anchor: model.anchor)
                .frame(width: 2, height: 2)
                .opacity(0.01), alignment: .topLeading)
            .navigationTitle("Bot residency spike")
        }
        .task {
            await model.startIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            Task { @MainActor in
                await model.scenePhaseChanged(newPhase)
            }
        }
    }
}

/// Engine-first-launch UI. It is deliberately read-only: the measurement is
/// driven by the OS triggers and the host command, not by tapping buttons.
private struct EngineWakeRootView: View {
    @ObservedObject private var runner = EngineWakeRunner.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Engine-first-launch wake")
                    .font(.title2.weight(.semibold))
                Text(runner.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LabeledContent("Phase", value: runner.phase)
                LabeledContent("Scenario", value: runner.currentScenario ?? "—")
                LabeledContent("Attempts", value: "\(runner.attemptsRecorded)")
                LabeledContent("Device token", value: runner.deviceToken == nil ? "pending" : "received")
                Text("This screen is not a verdict. The host command performs the LAN probes and analyze.py decides PASS, FAIL, or NOT_RUN. Simulator runs are NOT_RUN.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(EngineWakeAnchorContainer(container: runner.visibleContainer)
                .frame(width: 2, height: 2)
                .opacity(0.01), alignment: .topLeading)
            .navigationTitle("Engine wake spike")
        }
        .task {
            runner.visibleContainerDidAppear()
        }
        .onChange(of: scenePhase) { _, newPhase in
            Task { @MainActor in
                await runner.scenePhaseChanged(newPhase)
            }
        }
    }
}

private struct BotResidencyAnchorView: UIViewRepresentable {
    let anchor: VisibleEngineAnchor

    func makeUIView(context: Context) -> UIView {
        anchor.view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

private struct EngineWakeAnchorContainer: UIViewRepresentable {
    let container: UIView

    func makeUIView(context: Context) -> UIView {
        container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
