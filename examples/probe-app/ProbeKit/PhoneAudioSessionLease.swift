// SPDX-License-Identifier: MIT
// The silent keep-alive, dictation, and the phone record tool share one
// AVAudioSession. A pure keep-alive run uses playback + mixWithOthers; while a
// microphone caller holds a token the session keeps the same mixable
// playAndRecord profile until the last owner releases it. The last owner
// deactivates the session. A speaker-output claim (the TonoLink voice turn)
// uses that same profile and, while the output is an AirPlay receiver (the
// board mirrors the screen and drops AirPlay audio), forces the built-in
// speaker so the phone's speech is heard (xiaozhi-link VoiceAssistant).

import AVFoundation
import Foundation

@MainActor
public enum PhoneAudioSessionLease {
    public struct MicrophoneToken: Hashable, Sendable {
        let id: UUID
        init() { id = UUID() }
    }

    public struct SpeakerToken: Hashable, Sendable {
        let id: UUID
        init() { id = UUID() }
    }

    @MainActor
    final class State {
        private let configurePlayback: @MainActor () throws -> Void
        private let configureMicrophone: @MainActor () throws -> Void
        private let activate: @MainActor () throws -> Void
        private let deactivate: @MainActor () -> Void
        private let outputIsAirPlay: @MainActor () -> Bool
        private let overrideToSpeaker: @MainActor (Bool) -> Void
        private var speakerTokens: Set<SpeakerToken> = []
        private var speakerOverridden = false
        private var reclaim: (@MainActor () -> Void)?
        private var microphoneToken: MicrophoneToken?
        /// Once a microphone configures the session, keep its mixable
        /// playAndRecord profile until no owners remain.
        private var microphoneProfile = false

        init(configurePlayback: @escaping @MainActor () throws -> Void,
             configureMicrophone: @escaping @MainActor () throws -> Void,
             activate: @escaping @MainActor () throws -> Void,
             deactivate: @escaping @MainActor () -> Void,
             outputIsAirPlay: @escaping @MainActor () -> Bool = { false },
             overrideToSpeaker: @escaping @MainActor (Bool) -> Void = { _ in }) {
            self.configurePlayback = configurePlayback
            self.configureMicrophone = configureMicrophone
            self.activate = activate
            self.deactivate = deactivate
            self.outputIsAirPlay = outputIsAirPlay
            self.overrideToSpeaker = overrideToSpeaker
        }

        var hasSpeakerOwner: Bool { !speakerTokens.isEmpty }
        var isSpeakerOverridden: Bool { speakerOverridden }

        /// Phone speech that must be heard on the phone: the mixable playAndRecord profile
        /// (sticky like a microphone's) and, while the output is AirPlay, the built-in speaker.
        func acquireSpeakerOutput() throws -> SpeakerToken {
            if !microphoneProfile {
                do { try configureMicrophone() } catch {
                    if isKeepAliveHeld { try? configurePlayback(); reclaim?() }
                    else if !hasMicrophoneOwner && speakerTokens.isEmpty { deactivate() }
                    throw error
                }
                microphoneProfile = true
            } else {
                try activate()
            }
            if !speakerOverridden, outputIsAirPlay() {
                overrideToSpeaker(true)
                speakerOverridden = true
            }
            let token = SpeakerToken()
            speakerTokens.insert(token)
            reclaim?()
            return token
        }

        func releaseSpeakerOutput(_ token: SpeakerToken) {
            guard speakerTokens.remove(token) != nil, speakerTokens.isEmpty else { return }
            if speakerOverridden { overrideToSpeaker(false); speakerOverridden = false }
            if isKeepAliveHeld || hasMicrophoneOwner { reclaim?(); return }
            deactivate()
            microphoneProfile = false
        }

        /// True between ``beginKeepAlive(reclaim:)`` and ``endKeepAlive()``.
        var isKeepAliveHeld: Bool { reclaim != nil }

        var hasMicrophoneOwner: Bool { microphoneToken != nil }

        var isMicrophoneProfileSticky: Bool { microphoneProfile }

        func beginKeepAlive(reclaim: @escaping @MainActor () -> Void) {
            self.reclaim = reclaim
        }

        func activateKeepAliveSession() throws {
            if hasMicrophoneOwner {
                try activate()
                return
            }
            if microphoneProfile {
                try configureMicrophone()
            } else {
                try configurePlayback()
            }
        }

        func endKeepAlive() {
            guard isKeepAliveHeld else { return }
            reclaim = nil
            guard !hasMicrophoneOwner, !hasSpeakerOwner else { return }
            deactivate()
            microphoneProfile = false
        }

        func acquireMicrophoneUser() throws -> MicrophoneToken {
            guard !hasMicrophoneOwner else {
                throw PhoneToolError.unavailable(.microphone, "麦克风正被另一个录音使用")
            }
            do {
                // Reapplying this category under lock can fail and clear mixWithOthers.
                // Reuse the profile until its last owner releases it.
                if !microphoneProfile {
                    try configureMicrophone()
                }
            } catch {
                if isKeepAliveHeld {
                    try? configurePlayback()
                    reclaim?()
                } else {
                    deactivate()
                    microphoneProfile = false
                }
                throw error
            }
            microphoneProfile = true
            let token = MicrophoneToken()
            microphoneToken = token
            reclaim?()
            return token
        }

        func releaseMicrophoneUser(_ token: MicrophoneToken) {
            guard microphoneToken == token else { return }
            microphoneToken = nil
            if isKeepAliveHeld || hasSpeakerOwner {
                reclaim?()
                return
            }
            deactivate()
            microphoneProfile = false
        }
    }

    private static let state = State(
        configurePlayback: {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        },
        configureMicrophone: {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        },
        activate: {
            try AVAudioSession.sharedInstance().setActive(true)
        },
        deactivate: {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        },
        outputIsAirPlay: {
            AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
        },
        overrideToSpeaker: { on in
            try? AVAudioSession.sharedInstance().overrideOutputAudioPort(on ? .speaker : .none)
        })

    public static var isKeepAliveHeld: Bool { state.isKeepAliveHeld }
    public static var isMicrophoneHeld: Bool { state.hasMicrophoneOwner }
    public static var isMicrophoneProfileSticky: Bool { state.isMicrophoneProfileSticky }

    public static func beginKeepAlive(reclaim: @escaping @MainActor () -> Void) {
        state.beginKeepAlive(reclaim: reclaim)
    }

    public static func activateKeepAliveSession() throws {
        try state.activateKeepAliveSession()
    }

    public static func endKeepAlive() {
        state.endKeepAlive()
    }

    public static func acquireMicrophoneUser() throws -> MicrophoneToken {
        try state.acquireMicrophoneUser()
    }

    public static func releaseMicrophoneUser(_ token: MicrophoneToken) {
        state.releaseMicrophoneUser(token)
    }

    public static func acquireSpeakerOutput() throws -> SpeakerToken {
        try state.acquireSpeakerOutput()
    }

    public static func releaseSpeakerOutput(_ token: SpeakerToken) {
        state.releaseSpeakerOutput(token)
    }

    /// The current output ports, for diagnostics (`Speaker`, `AirPlay`, …).
    public static var outputPorts: [String] {
        AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue }
    }
}
