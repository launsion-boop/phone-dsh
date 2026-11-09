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
import ProbeKit

@MainActor
final class SilentAudioKeepAlive {
    /// The app's single keep-alive (ios-audio-session.md §1). Callers name themselves; rendering
    /// starts with the first owner and stops when the last one leaves.
    static let shared = SilentAudioKeepAlive()
    private var owners: Set<String> = []
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?
    private var interruptionObserver: NSObjectProtocol?
    private var configurationObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var watchdog: Task<Void, Never>?
    /// Times rendering was restarted after the engine stopped on its own.
    private(set) var restarts = 0
    var isRendering: Bool { isActive && engine.isRunning && player.isPlaying }
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

    /// Activates the session and starts rendering silence. Registers the lease
    /// before activation so a failed start rolls it back. Idempotent.
    func start(owner: String = "chat") throws {
        let added = owners.insert(owner).inserted
        guard !isActive else { return }
        do { try startRendering() } catch { if added { owners.remove(owner) }; throw error }
    }

    private func startRendering() throws {
        PhoneAudioSessionLease.beginKeepAlive { [weak self] in
            self?.reclaimSilentRendering()
        }
        do {
            try PhoneAudioSessionLease.activateKeepAliveSession()
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
            onEvent?("keep-alive audio session active")
        } catch {
            player.stop()
            if engine.isRunning { engine.stop() }
            PhoneAudioSessionLease.endKeepAlive()
            throw error
        }
    }

    /// Re-applies the lease's current mixable profile: playback for a plain
    /// keep-alive, playAndRecord while its sticky microphone profile is held.
    /// WebKit sets its own category when page media starts; a session that
    /// mixes with others is not eligible to be the system's Now Playing app,
    /// so nothing is shown in the Dynamic Island, Control Center or the lock
    /// screen. A healthy mixable session is left alone, so the heartbeat does
    /// not reconfigure the shared session on every tick.
    func reassertCategory() {
        guard PhoneAudioSessionLease.isKeepAliveHeld else { return }
        guard !PhoneAudioSessionLease.isMicrophoneHeld else {
            onEvent?("audio session re-assert deferred: microphone is active")
            return
        }
        let session = AVAudioSession.sharedInstance()
        let mixing = session.categoryOptions.contains(.mixWithOthers)
        let expectedCategory: AVAudioSession.Category =
            PhoneAudioSessionLease.isMicrophoneProfileSticky ? .playAndRecord : .playback
        if session.category == expectedCategory && mixing { return }
        let previousCategory = session.category.rawValue
        do {
            try PhoneAudioSessionLease.activateKeepAliveSession()
            onEvent?("audio session re-asserted: \(session.category.rawValue) + mixWithOthers (was \(previousCategory), mixing=\(mixing))")
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

    /// Stops rendering and releases the keep-alive claim. The lease deactivates
    /// only when no microphone owner remains. Idempotent.
    func stop(owner: String = "chat") {
        owners.remove(owner)
        guard owners.isEmpty, isActive else { return }
        player.stop()
        engine.stop()
        isActive = false
        PhoneAudioSessionLease.endKeepAlive()
        unobserveSession()
        onEvent?("keep-alive audio rendering released")
    }

    /// Restarts silent rendering after the lease commits a microphone or
    /// playback profile. A healthy player is left alone.
    private func reclaimSilentRendering() {
        guard isActive else { return }
        let engineWasRunning = engine.isRunning
        let playerWasPlaying = player.isPlaying
        if engineWasRunning && playerWasPlaying {
            return
        }
        do {
            if !engine.isRunning {
                engine.mainMixerNode.outputVolume = 1.0
                try engine.start()
            }
            if !player.isPlaying, let buffer {
                player.scheduleBuffer(buffer, at: nil, options: [.loops])
                player.play()
            }
            onEvent?("keep-alive audio rendering reclaimed (engine=\(engineWasRunning), player=\(playerWasPlaying))")
        } catch {
            onEvent?("keep-alive audio reclaim failed: \(error)")
        }
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
        // The engine stops itself when the output route or hardware format changes, e.g. when
        // screen mirroring to an AirPlay receiver starts or ends. Silence that is no longer
        // rendered lets iOS suspend the app, so these and a 5 s watchdog restart rendering.
        configurationObserver = center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                   object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resumeRendering(reason: "engine configuration changed") }
        }
        routeObserver = center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                           object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).map { "route change \($0)" } ?? "route change"
            Task { @MainActor in self?.resumeRendering(reason: reason) }
        }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.isActive else { return }
                if !self.engine.isRunning || !self.player.isPlaying { self.resumeRendering(reason: "watchdog: engine stopped") }
            }
        }
    }

    /// Restarts the engine and the silent loop if either stopped. The keep-alive profile is
    /// re-activated only while no microphone owner holds the session (ios-audio-session.md §2).
    private func resumeRendering(reason: String) {
        guard isActive, PhoneAudioSessionLease.isKeepAliveHeld, !engine.isRunning || !player.isPlaying else { return }
        do {
            if !PhoneAudioSessionLease.isMicrophoneHeld { try PhoneAudioSessionLease.activateKeepAliveSession() }
            if !engine.isRunning {
                // After a configuration change the player is disconnected from the new output format.
                engine.connect(player, to: engine.mainMixerNode, format: buffer?.format)
                engine.mainMixerNode.outputVolume = 1.0
                try engine.start()
            }
            if let buffer { player.scheduleBuffer(buffer, at: nil, options: [.loops]) }
            player.play()
            restarts += 1
            onEvent?("keep-alive audio restarted (\(reason))")
        } catch {
            onEvent?("keep-alive audio could not restart (\(reason)): \(error)")
        }
    }

    private func unobserveSession() {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let resetObserver { NotificationCenter.default.removeObserver(resetObserver) }
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        watchdog?.cancel()
        interruptionObserver = nil
        resetObserver = nil
        configurationObserver = nil
        routeObserver = nil
        watchdog = nil
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
                try PhoneAudioSessionLease.activateKeepAliveSession()
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
        PhoneAudioSessionLease.endKeepAlive()
        do {
            try start()
            onEvent?("keep-alive audio restarted after a media-services reset")
        } catch {
            onEvent?("keep-alive audio could not restart after a media-services reset: \(error)")
        }
    }
}
