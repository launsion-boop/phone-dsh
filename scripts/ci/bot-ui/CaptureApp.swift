// SPDX-License-Identifier: MIT

import SwiftUI

@main
struct PhoneDSHBotUICaptureApp: App {
    private let fixture: BotUIFixtureCase
    private let gallery: Bool
    private let diagnostics: Bool
    private let appearance: String

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let fixtureName = Self.value(named: "-BotUIFixture", in: arguments)
            ?? BotUIFixtureCase.chat.rawValue
        gallery = fixtureName == "gallery"
        fixture = BotUIFixtureCase(rawValue: fixtureName) ?? .chat
        diagnostics = arguments.contains("-BotUIDiagnostics")
        appearance = Self.value(named: "-BotUIAppearance", in: arguments) ?? "light"
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if gallery {
                    #if DEBUG
                    BotFishGalleryView()
                    #else
                    Text("gallery is only available in DEBUG")
                    #endif
                } else {
                    BotUIFixtureRootView(fixture: fixture, diagnostics: diagnostics)
                }
            }
            .preferredColorScheme(appearance == "dark" ? .dark : .light)
            .task { await runConformanceChecks() }
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
