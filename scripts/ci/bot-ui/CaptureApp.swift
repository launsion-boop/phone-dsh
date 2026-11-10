// SPDX-License-Identifier: MIT

import SwiftUI
import UIKit

@main
struct PhoneDSHBotUICaptureApp: App {
    /// Evidence-only: keep the process runnable for ~30s after backgrounding
    /// so the performance run can prove the fish timeline is parked instead
    /// of being suspended by iOS. This does not ship in the probe app.
    @State private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private let fixture: BotUIFixtureCase
    private let gallery: Bool
    private let dynamic: Bool
    private let appearanceGallery: Bool
    private let diagnostics: Bool
    private let benchmark: Bool
    private let appearance: String

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let fixtureName = Self.value(named: "-BotUIFixture", in: arguments)
            ?? BotUIFixtureCase.chat.rawValue
        gallery = fixtureName == "gallery"
        dynamic = fixtureName == "dynamic"
        appearanceGallery = fixtureName == "appearanceGrid"
        fixture = BotUIFixtureCase(rawValue: fixtureName) ?? .chat
        diagnostics = arguments.contains("-BotUIDiagnostics")
        benchmark = arguments.contains("-BotFishBench")
        appearance = Self.value(named: "-BotUIAppearance", in: arguments) ?? "light"
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if benchmark {
                    #if DEBUG
                    BotFishBenchmarkView()
                    #else
                    Text("benchmark is only available in DEBUG")
                    #endif
                } else if gallery {
                    #if DEBUG
                    BotFishGalleryView()
                    #else
                    Text("gallery is only available in DEBUG")
                    #endif
                } else if dynamic {
                    #if DEBUG
                    BotFishDynamicGalleryView()
                    #else
                    Text("dynamic gallery is only available in DEBUG")
                    #endif
                } else if appearanceGallery {
                    #if DEBUG
                    BotFishAppearanceGalleryView()
                    #else
                    Text("appearance gallery is only available in DEBUG")
                    #endif
                } else {
                    BotUIFixtureRootView(fixture: fixture, diagnostics: diagnostics)
                }
            }
            .preferredColorScheme(appearance == "dark" ? .dark : .light)
            .task { await runConformanceChecks() }
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.didEnterBackgroundNotification)) { _ in
                beginEvidenceBackgroundTask()
            }
        }
    }

    private func beginEvidenceBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "BotFishCaptureEvidence") {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func runConformanceChecks() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let cardPath = Self.value(named: "-BotUICardGolden", in: arguments),
              let rowPath = Self.value(named: "-BotUIRowGolden", in: arguments) else { return }
        let result: [String: Any]
        do {
            let checks = try await BotUIFixtureChecks.run(
                cardPayloadURL: URL(fileURLWithPath: cardPath),
                rowProtocolURL: URL(fileURLWithPath: rowPath)
            )
            result = ["status": "PASS", "checks": checks]
        } catch {
            result = ["status": "FAIL", "error": String(describing: error)]
        }
        let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("bot-ui-checks.json")
        try? data?.write(to: url)
        if let data, let text = String(data: data, encoding: .utf8) {
            print("BOT_UI_CHECKS \(text.replacingOccurrences(of: "\n", with: " "))")
        }
    }

    private static func value(named name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
