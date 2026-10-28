// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS Phase 0 probe app (PLAN W3-APP / W6-BACKGROUND).
//
// Screen page: presents the landed pure-black low-brightness `TaskScreen`.
// The screen lowers `UIScreen.main.brightness` while visible and restores the
// previous value on disappear. Device brightness behaviour is NOT_VERIFIED.

import ProbeKit
import SwiftUI
import PhoneDSH

struct TaskScreenPage: View {
    @Environment(AppModel.self) private var model
    @State private var presenting = false
    @State private var minimumBrightness = 0.0
    @State private var statusLine = "phone DSH probe task screen"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    PageSection("Task screen") {
                        Text("Opens a pure-black, low-brightness screen from "
                             + "PhoneDSH.Background. It has no timer and "
                             + "no animation; only the status line changes when "
                             + "the caller rebuilds it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Status line", text: $statusLine)
                            .textFieldStyle(.roundedBorder)
                        VStack(alignment: .leading) {
                            Text("Minimum brightness: \(String(format: "%.2f", minimumBrightness))")
                                .font(.caption)
                            Slider(value: $minimumBrightness, in: 0...0.5)
                        }
                        Button {
                            presenting = true
                        } label: {
                            Label("Show black task screen", systemImage: "moon.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    PageSection("Report") {
                        KeyValueLine(
                            key: "presented",
                            value: model.store.taskScreenPresented ? "yes" : "no")
                        KeyValueLine(
                            key: "minimum brightness",
                            value: String(format: "%.2f",
                                          model.store.taskScreenMinimumBrightness))
                        Text("The screen brightness API is best effort and global; "
                             + "whether a device actually dims is NOT_VERIFIED.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Screen")
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $presenting) {
                ZStack(alignment: .topTrailing) {
                    TaskScreen(configuration: TaskScreenConfiguration(
                        title: "phone DSH probe",
                        status: statusLine,
                        dimsScreen: true,
                        minimumBrightness: minimumBrightness))
                    Button {
                        presenting = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Color(white: 0.35))
                            .padding()
                    }
                    .accessibilityLabel("Close task screen")
                }
                .onDisappear {
                    model.store.noteTaskScreenPresented(
                        minimumBrightness: minimumBrightness)
                }
            }
        }
    }
}
