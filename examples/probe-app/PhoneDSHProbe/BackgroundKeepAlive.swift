// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS probe app: background keep-alive.
//
// iOS suspends an app shortly after it leaves the foreground, and with it the
// WKWebView Worker that runs the agent. An active playback audio session is
// one of the sanctioned background modes: while it renders audio the process
// stays scheduled. This object holds such a session and renders silence:
// `.mixWithOthers` leaves other apps' audio untouched (no ducking, no
// interruption), no Now Playing information is published, so the lock screen
// shows no transport bar. Requires `UIBackgroundModes: audio`.
//
// Whether WebKit also keeps the WebContent process scheduled under this
// assertion is exactly what the Chat page's background heartbeat measures.

import AVFoundation
import Foundation
import MediaPlayer

@MainActor
final class SilentAudioKeepAlive {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?
    private var interruptionObserver: NSObjectProtocol?
    private var resetObserver: NSObjectProtocol?
    private(set) var isActive = false
    /// Diagnostics the owner appends to its status log.
    var onEvent: (@MainActor (String) -> Void)?

    enum KeepAliveError: Error, CustomStringConvertible {
        case noFormat
        case noBuffer
        var description: String {
            switch self {
            case .noFormat: return "no PCM format for the silent track"
            case .noBuffer: return "no PCM buffer for the silent track"
            }
        }
    }

    /// Activates the session and starts rendering silence. Idempotent.
    func start() throws {
        guard !isActive else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true, options: [])
        if !engine.attachedNodes.contains(player) {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else {
                throw KeepAliveError.noFormat
            }
            // One second of silence, scheduled in a loop.
            let frames = AVAudioFrameCount(format.sampleRate)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                throw KeepAliveError.noBuffer
            }
            pcm.frameLength = frames
            buffer = pcm
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
        engine.mainMixerNode.outputVolume = 1.0
        try engine.start()
        if let buffer {
            player.scheduleBuffer(buffer, at: nil, options: [.loops])
        }
        player.play()
        isActive = true
        observeSession()
        onEvent?("keep-alive audio session active (playback, mixWithOthers)")
    }

    /// Re-applies `.playback` + `.mixWithOthers` on the shared session. WebKit
    /// sets its own category when page media starts; a session that mixes with
    /// others is not eligible to be the system's Now Playing app, so nothing is
    /// shown in the Dynamic Island, Control Center or the lock screen.
    func reassertCategory() {
        let session = AVAudioSession.sharedInstance()
        let mixing = session.categoryOptions.contains(.mixWithOthers)
        if session.category == .playback && mixing { return }
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])
            onEvent?("audio session re-asserted: playback + mixWithOthers (was \(session.category.rawValue), mixing=\(mixing))")
        } catch {
            onEvent?("audio session re-assert failed: \(error)")
        }
    }

    /// Whether the shared session currently mixes with other apps.
    var isMixingWithOthers: Bool {
        AVAudioSession.sharedInstance().categoryOptions.contains(.mixWithOthers)
    }

    /// WebKit registers playing page media as this app's Now Playing item
    /// (title in Control Center, the Dynamic Island, the lock screen) through
    /// the same system service MPNowPlayingInfoCenter speaks to. Clearing the
    /// item and declaring the playback stopped from the app overrides that
    /// registration; WebKit re-registers only on a playback state change, so
    /// the caller repeats this after the media starts and on every heartbeat.
    func hideNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        let hadInfo = center.nowPlayingInfo != nil
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        let commands = MPRemoteCommandCenter.shared()
        for command in [commands.playCommand, commands.pauseCommand, commands.stopCommand,
                        commands.togglePlayPauseCommand, commands.nextTrackCommand,
                        commands.previousTrackCommand] {
            command.isEnabled = false
        }
        if hadInfo { onEvent?("now-playing item cleared (WebKit had registered one)") }
    }

    /// Stops rendering and releases the session. Idempotent.
    func stop() {
        guard isActive else { return }
        player.stop()
        engine.stop()
        isActive = false
        unobserveSession()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        onEvent?("keep-alive audio session released")
    }

    // MARK: - Interruptions

    private func observeSession() {
        guard interruptionObserver == nil else { return }
        let center = NotificationCenter.default
        interruptionObserver = center.addObserver(forName: AVAudioSession.interruptionNotification,
                                                  object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }
        resetObserver = center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restartAfterReset() }
        }
    }

    private func unobserveSession() {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let resetObserver { NotificationCenter.default.removeObserver(resetObserver) }
        interruptionObserver = nil
        resetObserver = nil
    }

    private func handleInterruption(_ note: Notification) {
        guard isActive,
              let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            onEvent?("keep-alive audio interrupted (another app took the output)")
        case .ended:
            // A phone call or another exclusive session ended: render again so the
            // background assertion comes back.
            do {
                try AVAudioSession.sharedInstance().setActive(true, options: [])
                if !engine.isRunning { try engine.start() }
                if let buffer { player.scheduleBuffer(buffer, at: nil, options: [.loops]) }
                player.play()
                onEvent?("keep-alive audio resumed after the interruption")
            } catch {
                onEvent?("keep-alive audio could not resume: \(error)")
            }
        @unknown default:
            break
        }
    }

    private func restartAfterReset() {
        guard isActive else { return }
        isActive = false
        do {
            try start()
            onEvent?("keep-alive audio restarted after a media-services reset")
        } catch {
            onEvent?("keep-alive audio could not restart after a media-services reset: \(error)")
        }
    }
}
