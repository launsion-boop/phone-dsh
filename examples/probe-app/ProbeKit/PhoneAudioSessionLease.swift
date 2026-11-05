// SPDX-License-Identifier: MIT
// The silent keep-alive, dictation, and the phone record tool share one
// AVAudioSession. A pure keep-alive run uses playback + mixWithOthers; while a
// microphone caller holds a token the session keeps the same mixable
// playAndRecord profile until the last owner releases it. The last owner
// deactivates the session.

import AVFoundation
import Foundation

@MainActor
public enum PhoneAudioSessionLease {
    public struct MicrophoneToken: Hashable, Sendable {
        let id: UUID
        init() { id = UUID() }
    }

    @MainActor
    final class State {
        private let configurePlayback: @MainActor () throws -> Void
        private let configureMicrophone: @MainActor () throws -> Void
        private let activate: @MainActor () throws -> Void
        private let deactivate: @MainActor () -> Void
        private var reclaim: (@MainActor () -> Void)?
        private var microphoneToken: MicrophoneToken?
        /// Once a microphone configures the session, keep its mixable
        /// playAndRecord profile until no owners remain.
        private var microphoneProfile = false

        init(configurePlayback: @escaping @MainActor () throws -> Void,
             configureMicrophone: @escaping @MainActor () throws -> Void,
             activate: @escaping @MainActor () throws -> Void,
             deactivate: @escaping @MainActor () -> Void) {
            self.configurePlayback = configurePlayback
            self.configureMicrophone = configureMicrophone
            self.activate = activate
            self.deactivate = deactivate
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
            guard !hasMicrophoneOwner else { return }
            deactivate()
            microphoneProfile = false
        }

        func acquireMicrophoneUser() throws -> MicrophoneToken {
            guard !hasMicrophoneOwner else {
                throw PhoneToolError.unavailable(.microphone, "麦克风正被另一个录音使用")
            }
            do {
                try configureMicrophone()
            } catch {
                if isKeepAliveHeld {
                    if microphoneProfile {
                        try? configureMicrophone()
                    } else {
                        try? configurePlayback()
                    }
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
            if isKeepAliveHeld {
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
}
