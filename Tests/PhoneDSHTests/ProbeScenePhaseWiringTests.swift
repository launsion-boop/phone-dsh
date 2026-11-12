// SPDX-License-Identifier: MIT
// The probe app lost its only call into ChatModel.scenePhaseChanged when
// WebHostModel was removed. These tests read the app sources so the chat
// keep-alive hook cannot go unwired again, and so microphone code cannot
// deactivate the shared audio session behind the keep-alive's back.

import Foundation
import XCTest

final class ProbeScenePhaseWiringTests: XCTestCase {
    func testScenePhaseOnChangeLivesOnlyInAppEntries() throws {
        let hits = try swiftFiles(under: probeRoot()).compactMap { url, text -> String? in
            text.contains("onChange(of: scenePhase)") ? url.lastPathComponent : nil
        }
        XCTAssertEqual(hits.sorted(), ["BotResidencySpikeApp.swift", "PhoneDSHProbeApp.swift"])
    }

    func testChatScenePhaseHasASingleCallSite() throws {
        let needle = "ChatModel.shared.scenePhaseChanged"
        var hits: [String] = []
        for (url, text) in try swiftFiles(under: probeRoot()) {
            let count = text.components(separatedBy: needle).count - 1
            hits.append(contentsOf: Array(repeating: url.lastPathComponent, count: count))
        }
        XCTAssertEqual(hits, ["PhoneDSHProbeApp.swift"])
    }

    func testViewsDoNotObserveScenePhase() throws {
        let root = probeRoot()
        // PCPairingPage needs to show its "keep this page open" interruption
        // notice, but it reads AppModel.isSceneActive (the app entry's derived
        // projection), never SwiftUI's scenePhase itself.
        for name in ["RootView.swift", "ChatPage.swift", "PCPairingPage.swift"] {
            let text = try contents(root.appendingPathComponent(name))
            XCTAssertFalse(text.contains("scenePhase"), "\(name) must leave scene phase to PhoneDSHProbeApp")
        }
    }

    func testBackgroundMatrixForwardingDoesNotCallChat() throws {
        let text = try contents(probeRoot().appendingPathComponent("AppModel.swift"))
        XCTAssertFalse(text.contains("ChatModel"))
        XCTAssertTrue(text.contains("background.scenePhaseChanged"))
    }

    func testMicrophoneUsersReleaseThroughTheKeepAliveLease() throws {
        let root = repoRoot()
        let voice = try contents(root.appendingPathComponent(
            "examples/probe-app/PhoneDSHProbe/ComposerVoiceInput.swift"))
        XCTAssertFalse(voice.contains("setActive("))
        XCTAssertFalse(voice.contains("setCategory("))
        XCTAssertTrue(voice.contains("PhoneAudioSessionLease.acquireMicrophoneUser()"))
        XCTAssertEqual(occurrences(of: "PhoneAudioSessionLease.releaseMicrophoneUser(", in: voice), 1)

        let media = try contents(root.appendingPathComponent(
            "examples/probe-app/ProbeKit/Capabilities/PhoneMediaTools.swift"))
        XCTAssertFalse(media.contains("setActive("))
        XCTAssertFalse(media.contains("setCategory("))
        XCTAssertTrue(media.contains("PhoneAudioSessionLease.acquireMicrophoneUser()"))
        XCTAssertEqual(occurrences(of: "PhoneAudioSessionLease.releaseMicrophoneUser(", in: media), 1)

        let keepAlive = try contents(root.appendingPathComponent(
            "examples/probe-app/PhoneDSHProbe/BackgroundKeepAlive.swift"))
        XCTAssertEqual(occurrences(of: "PhoneAudioSessionLease.beginKeepAlive", in: keepAlive), 1)
        XCTAssertTrue(keepAlive.contains("PhoneAudioSessionLease.endKeepAlive()"))
        XCTAssertFalse(keepAlive.contains("setCategory("))
        XCTAssertFalse(keepAlive.contains("setActive("))
    }

    private func probeRoot() -> URL {
        repoRoot().appendingPathComponent("examples/probe-app/PhoneDSHProbe")
    }

    private func contents(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func swiftFiles(under root: URL) throws -> [(URL, String)] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            XCTFail("cannot list \(root.path)")
            return []
        }
        var files: [(URL, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append((url, try contents(url)))
        }
        return files.sorted { $0.0.path < $1.0.path }
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }
}
