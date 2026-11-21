// SPDX-License-Identifier: MIT
// Physical-device measurement of the board's wake word through its microphones: the iPhone's own
// speaker says 你好小智 several times, and the board's `wake info` (read over the BLE console)
// says how many it accepted, which engine ran (single mic or the dual-mic AFE), and what that cost
// in memory and processing headroom. Run it on two firmwares to compare them on the same phone,
// in the same place. The phone's speaker sits right next to the board, so this measures the
// near-field wake path; separating speech from noise in another direction needs a second source.
import AVFoundation
import XCTest
@testable import PhoneDSHBLE
import ProbeKit
@testable import PhoneDSHProbe

/// The phone's built-in Mandarin voice, so the measurement needs no network and no cloud quota.
@MainActor
private final class LocalVoice: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var finished: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func say(_ text: String, volume: Float) async {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.45
        utterance.volume = volume
        await withCheckedContinuation { continuation in
            finished = continuation
            synthesizer.speak(utterance)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished?.resume(); self.finished = nil }
    }
}

@MainActor
final class TonoLinkWakeDeviceTests: XCTestCase {
    private func note(_ line: String) { print("PDSH-WAKE \(line)") }

    private func wakeInfo(_ debug: TonoLinkBLEDebug, reset: Bool) async throws -> [String] {
        let lines = try await debug.console("wake info")
        for line in lines { note("board: \(line)") }
        return lines
    }

    private static func value(_ key: String, in lines: [String]) -> Int? {
        for line in lines {
            guard let range = line.range(of: key + "=") else { continue }
            let digits = line[range.upperBound...].prefix { $0.isNumber || $0 == "-" }
            if let number = Int(digits) { return number }
        }
        return nil
    }

    func testWakeWordFromThePhoneSpeaker() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard (environment["TEST_RUNNER_PDSH_TONOLINK_WAKE_TEST"] ?? environment["PDSH_TONOLINK_WAKE_TEST"]) == "1" else {
            throw XCTSkip("pass TEST_RUNNER_PDSH_TONOLINK_WAKE_TEST=1 with the board next to the phone")
        }
        let plays = Int(environment["TEST_RUNNER_PDSH_WAKE_PLAYS"] ?? environment["PDSH_WAKE_PLAYS"] ?? "") ?? 5
        // Quieter speech stands in for a speaker further away; the same sweep on two firmwares
        // compares them. Volume is AVSpeechUtterance's, relative to the phone's media volume.
        let volumes = (environment["TEST_RUNNER_PDSH_WAKE_VOLUMES"] ?? environment["PDSH_WAKE_VOLUMES"] ?? "1.0,0.3,0.1,0.04")
            .split(separator: ",").compactMap { Float($0) }
        // The phone's own speaker, as the app's 「我在」 does: while the screen is mirrored over
        // AirPlay, plain playback goes to the receiver (the board) and the mics hear nothing.
        let speaker = try PhoneAudioSessionLease.acquireSpeakerOutput()
        defer { PhoneAudioSessionLease.releaseSpeakerOutput(speaker) }
        note("speaker outputs=\(PhoneAudioSessionLease.outputPorts)")
        let voice = LocalVoice()
        let debug = TonoLinkBLEDebug(link: TonoLinkCtrlBLE(nameHint: "PhoneAgent"))
        let first = try await wakeInfo(debug, reset: true)
        var last = try XCTUnwrap(Self.value("detected", in: first))
        var summary: [String] = []
        var total = 0
        var info: [String] = []
        for volume in volumes {
            for play in 1...plays {
                await voice.say("你好小智", volume: volume)
                note("volume \(volume) play \(play)/\(plays)")
                // A wake starts a voice turn on this phone (我在, then up to 5 s of listening);
                // let it finish before the next play.
                try await Task.sleep(for: .seconds(14))
            }
            info = try await wakeInfo(debug, reset: false)
            let now = try XCTUnwrap(Self.value("detected", in: info))
            summary.append("v\(volume)=\(now - last)/\(plays)")
            total += now - last
            last = now
        }
        let engine = info.first { $0.contains("engine=") }?.trimmingCharacters(in: .whitespaces) ?? "engine=single-mic(old firmware)"
        note("RESULT \(engine) \(summary.joined(separator: " ")) "
             + "int_free=\(Self.value("int_free", in: info) ?? -1) int_min=\(Self.value("int_min", in: info) ?? -1) "
             + "infer_max_us=\(Self.value("infer_max_us", in: info) ?? -1) busy_max=\(Self.value("busy_max", in: info) ?? -1)")
        let detected = total
        XCTAssertGreaterThan(detected, 0, "the board heard none of the wake words")
    }

    /// Read-only diagnosis: the board's `info` and its log since boot (reset reason, panics).
    func testBoardInfoAndLog() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard (environment["TEST_RUNNER_PDSH_TONOLINK_WAKE_TEST"] ?? environment["PDSH_TONOLINK_WAKE_TEST"]) == "1" else {
            throw XCTSkip("pass TEST_RUNNER_PDSH_TONOLINK_WAKE_TEST=1")
        }
        let debug = TonoLinkBLEDebug(link: TonoLinkCtrlBLE(nameHint: "PhoneAgent"))
        for line in try await debug.console("info") { note("info: \(line)") }
        for line in try await debug.console("diag") { note("diag: \(line)") }
        for line in try await debug.console("wake info") { note("wake: \(line)") }
        var since: UInt32 = 0
        for _ in 0..<12 {
            let page = try await debug.log(since: since)
            for line in page.lines { note("log \(line.index): \(line.text)") }
            if page.last == since || page.lines.isEmpty { break }
            since = page.last
        }
    }

    /// End to end through the app: wake, then a command after 「我在」; the app's voice log
    /// (`Documents/tonolink-voice.log`, `heard=`) says what the cloud ASR recognised.
    func testWakeThenCommand() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard (environment["TEST_RUNNER_PDSH_TONOLINK_WAKE_TEST"] ?? environment["PDSH_TONOLINK_WAKE_TEST"]) == "1" else {
            throw XCTSkip("pass TEST_RUNNER_PDSH_TONOLINK_WAKE_TEST=1")
        }
        // The phone's own speaker, as the app's 「我在」 does: while the screen is mirrored over
        // AirPlay, plain playback goes to the receiver (the board) and the mics hear nothing.
        let speaker = try PhoneAudioSessionLease.acquireSpeakerOutput()
        defer { PhoneAudioSessionLease.releaseSpeakerOutput(speaker) }
        note("speaker outputs=\(PhoneAudioSessionLease.outputPorts)")
        let voice = LocalVoice()
        let command = environment["TEST_RUNNER_PDSH_WAKE_COMMAND"] ?? environment["PDSH_WAKE_COMMAND"] ?? "打开设置"
        let plays = Int(environment["TEST_RUNNER_PDSH_WAKE_PLAYS"] ?? environment["PDSH_WAKE_PLAYS"] ?? "") ?? 5
        let after = Int(environment["TEST_RUNNER_PDSH_WAKE_AFTER_S"] ?? environment["PDSH_WAKE_AFTER_S"] ?? "") ?? 12
        for play in 1...plays {
            await voice.say("你好小智", volume: 1.0)
            try await Task.sleep(for: .milliseconds(1800))   // 「我在」 then listen
            await voice.say(command, volume: 1.0)
            note("command play \(play)/\(plays): \(command)")
            try await Task.sleep(for: .seconds(after))       // long enough for the agent's whole task
        }
    }

    /// Diagnosis for "Could not connect to the server": is the board's USB HTTP reachable, and does
    /// the BLE `usb_net` step (what OTA does first) bring it back? Reads state only; flashes nothing.
    func testUSBLinkReachability() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard (environment["TEST_RUNNER_PDSH_TONOLINK_WAKE_TEST"] ?? environment["PDSH_TONOLINK_WAKE_TEST"]) == "1" else {
            throw XCTSkip("pass TEST_RUNNER_PDSH_TONOLINK_WAKE_TEST=1")
        }
        let hands = IPhoneAgentHost.shared.hands
        let before = try? await hands.call("GET", "/v1/phone/status", timeout: 5)
        note("usb before: \(before == nil ? "unreachable" : "ok")")
        let flow = TonoLinkUSBOTA(ctrl: TonoLinkCtrlBLE(nameHint: "PhoneAgent"), network: TonoLinkUSBSocketNetwork(),
                                  http: TonoLinkURLSessionHTTP())
        flow.onEvent = { [weak self] event in if case .step(let text) = event { self?.note("usb_net: \(text)") } }
        do { note("ota state: \(try await flow.readStateOverUSB())") } catch { note("usb_net failed: \(error)") }
        let after = try? await hands.call("GET", "/v1/phone/status", timeout: 5)
        note("usb after: \(after.map { "ok \($0["hid"] ?? "")" } ?? "unreachable")")
    }
}
