// SPDX-License-Identifier: MIT
#if BOT_RESIDENCY_SPIKE

import SwiftUI
import ProbeKit

@main
struct BotResidencySpikeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = BotResidencyRunner()

    var body: some Scene {
        WindowGroup {
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
}

private struct BotResidencyAnchorView: UIViewRepresentable {
    let anchor: VisibleEngineAnchor

    func makeUIView(context: Context) -> UIView {
        anchor.view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
