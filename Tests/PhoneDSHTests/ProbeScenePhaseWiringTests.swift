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

    /// A transcript adoption parked while the App was hidden must never be
    /// committed over rows the event pump delivered afterwards: the App can
    /// still execute in the background (Bot keep-alive, a recovering stream),
    /// and those rows land on the old transcript, making the parked snapshot
    /// older than the screen. `ChatModel` is App target code, so this guard
    /// scans its source for both halves of the wiring: every handled event
    /// reports the row change, and the commit decision replaces a superseded
    /// snapshot with a foreground re-read instead of painting it.
    func testParkedTranscriptAdoptionCannotOverwriteRowsDeliveredWhileHidden() throws {
        let chat = try contents(probeRoot().appendingPathComponent("ChatModel.swift"))

        let handle = try functionBody(of: "private func handle(_ event", in: chat)
        XCTAssertTrue(handle.contains("noteRowsMayHaveChanged()"),
                      "the pump's row mutations must reach the background gate")
        let reported = try XCTUnwrap(handle.range(of: "noteRowsMayHaveChanged()"))
        let viewed = try XCTUnwrap(handle.range(of: "handle(eventWhileViewingAnotherSession:"))
        XCTAssertLessThan(viewed.upperBound, reported.lowerBound,
                          "events consumed for another session's projection do not touch the viewed rows")

        let adopt = try functionBody(of: "func adoptDeferredTranscriptIfForeground()", in: chat)
        XCTAssertTrue(adopt.contains("beginParkedAdoptionCommit()"),
                      "the commit must consult the gate's staleness verdict")
        let decision = try XCTUnwrap(adopt.range(of: "beginParkedAdoptionCommit()"))
        let applied = try XCTUnwrap(adopt.range(of: "applyAdoptedTranscript(rows: pending.items"))
        let resync = try XCTUnwrap(adopt.range(of: "resyncTranscriptAfterStaleParkedAdoption"))
        XCTAssertLessThan(decision.upperBound, applied.lowerBound,
                          "the snapshot is only applied after the gate allows the commit")
        XCTAssertLessThan(decision.upperBound, resync.lowerBound,
                          "a superseded snapshot is replaced by a foreground re-read, not painted")
    }

    private func probeRoot() -> URL {
        repoRoot().appendingPathComponent("examples/probe-app/PhoneDSHProbe")
    }

    /// Extracts a function body by brace balance; the first `{` after the
    /// signature opens it, and nested closures/`if` bodies stay inside.
    private func functionBody(of signature: String, in source: String) throws -> String {
        guard let start = source.range(of: signature) else {
            throw NSError(domain: "scene-phase-wiring", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "missing \(signature)",
            ])
        }
        guard let open = source[start.upperBound...].firstIndex(of: "{") else {
            throw NSError(domain: "scene-phase-wiring", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(signature) has no body",
            ])
        }
        var depth = 0
        var index = open
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[open...index])
                }
            }
            index = source.index(after: index)
        }
        throw NSError(domain: "scene-phase-wiring", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "\(signature) body is not balanced",
        ])
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
