// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — the TonoLink voice turn (spec/device/v1/tonolink-board.md §4.1,
// spec/v1/cloud-voice.md): the board hears 你好小智 → the phone says 我在 → the board
// records → its Opus goes to the cloud ASR → the text is sent to the current chat →
// the reply is spoken. The board's microphone does all recording; the phone only plays.

import AVFoundation
import UIKit
import Foundation
import PhoneDSH
import PhoneDSHBLE
import ProbeKit

@MainActor final class TonoLinkVoiceHost {
    static let shared = TonoLinkVoiceHost()

    /// Shown by `GET /debug/voice`.
    private(set) var state = "off"
    private(set) var lastTurn: [String: Any] = [:]

    private var ctrl: TonoLinkCtrlBLE?
    private var supervisor: Task<Void, Never>?
    private var turn: Task<Void, Never>?
    private var turnID: UInt32 = UInt32.random(in: 1...1_000_000)
    private var audio: AsyncStream<Data>.Continuation?
    private var asr: CloudASRSession?
    private var tally = TonoLinkVoiceTally()
    private var seq: UInt16 = 40_000
    private var holdsKeepAlive = false
    private let player = VoicePCMPlayer()
    private let tts = CloudTTSClient()
    private var hereAudio: Data?
    private static let keepAliveOwner = "tonolink-voice"

    /// Keeps a ctrl link to the user's board and listens for its wake word.
    func start() {
        guard supervisor == nil else { return }
        supervisor = Task { [weak self] in await self?.supervise() }
    }

    private func supervise() async {
        while !Task.isCancelled {
            if ctrl?.isConnected != true {
                ctrl = nil
                setKeepAlive(false)
                let link = TonoLinkCtrlBLE(nameHint: "PhoneAgent")
                link.onAudio = { [weak self] data in self?.receiveAudio(data) }
                link.onLine = { [weak self] line in self?.receive(line) }
                do {
                    try await link.connect(timeout: .seconds(20))
                    ctrl = link
                    state = "等待「你好小智」（\(link.peripheralName ?? "board")）"
                    log("connected \(link.peripheralName ?? "?") audio=\(link.isAudioSubscribed)")
                    setKeepAlive(true)
                    await prefetchHere()
                } catch {
                    state = "没有连上板子：\(error.localizedDescription)"
                    log("connect failed: \(error.localizedDescription)")
                }
            }
            try? await Task.sleep(for: .seconds(ctrl?.isConnected == true ? 3 : 10))
        }
    }

    private func setKeepAlive(_ on: Bool) {
        guard on != holdsKeepAlive else { return }
        if on {
            do { try SilentAudioKeepAlive.shared.start(owner: Self.keepAliveOwner); holdsKeepAlive = true }
            catch { state += "（后台保活失败：\(error.localizedDescription)）" }
        } else {
            SilentAudioKeepAlive.shared.stop(owner: Self.keepAliveOwner)
            holdsKeepAlive = false
        }
    }

    // MARK: - Board events

    private func receive(_ line: TonoLinkCtrlLine) {
        guard case .other(let text) = line else { return }
        if text.hasPrefix("ev ") { log("line \(text) app=\(UIApplication.shared.applicationState.rawValue)") }
        guard let event = TonoLinkVoiceEvent.parse(text) else { return }
        switch event {
        case .wake(let n, _):
            beginTurn(wake: n, source: n == 0 ? "board (simulated)" : "board")
        case .listenEnd(let n, let frames, let reason):
            guard n == turnID else { return }
            lastTurn["listen_end"] = ["frames": Int(frames), "reason": reason.rawValue]
            endAudio()
        }
    }

    private func receiveAudio(_ data: Data) {
        guard audio != nil else { return }
        let packet = TonoLinkVoicePacket.parse(data, turnID: turnID)
        tally.record(packet)
        guard let packet else { return }
        if !packet.opus.isEmpty { audio?.yield(packet.opus) }
        if packet.last { endAudio() }
    }

    private func endAudio() {
        audio?.finish()
        audio = nil
    }

    // MARK: - The turn

    /// A wake stops whatever turn is recording, recognising or speaking and starts a new one (§4.1).
    func beginTurn(wake: UInt32, source: String) {
        turn?.cancel()
        player.stop()
        endAudio()
        if let asr { Task { await asr.cancel() } }
        asr = nil
        turnID = turnID &+ 1
        if turnID == 0 { turnID = 1 }
        tally = TonoLinkVoiceTally()
        let id = turnID
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(700))
        audio = continuation
        lastTurn = ["id": Int(id), "wake": Int(wake), "source": source, "at": ISO8601DateFormatter().string(from: Date())]
        turn = Task { [weak self] in
            await self?.runTurn(id: id, audio: stream)
            self?.turnEnded(id)
        }
    }

    private func note(_ key: String, _ value: Any) {
        lastTurn[key] = value
        log("turn \(turnID) \(key)=\(value)")
    }

    /// One line per event in `Documents/tonolink-voice.log` (DEBUG), readable over USB without Wi-Fi.
    func log(_ line: String) {
        #if DEBUG
        guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let file = folder.appendingPathComponent("tonolink-voice.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: file) { handle.seekToEndOfFile(); handle.write(data); try? handle.close() }
        else { try? data.write(to: file) }
        #endif
    }

    private func turnEnded(_ id: UInt32) {
        guard id == turnID else { return }
        turn = nil
        asr = nil
        endAudio()
    }

    private func runTurn(id: UInt32, audio: AsyncStream<Data>) async {
        let start = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(start) * 1000) }
        guard var credential = await credential() else {
            note("error", "语音需要登录 Tono 账号，或在「模型服务」里使用云端（pdsh.tonoai.cn）密钥")
            return
        }
        // Recognition connects while 我在 plays; recording starts only once it is ready.
        var session = CloudASRSession(credential: credential, turnID: id)
        asr = session
        await session.open()
        do { try await speakHere(credential: credential, timing: { self.note("here_fetch_ms", ms()) }) }
        catch { note("here_error", error.localizedDescription) }
        note("here_ms", ms())
        if !(await session.ready()), await session.handshakeStatus == 401,
           let renewed = await renewedCredential(after: credential) {
            credential = renewed
            session = CloudASRSession(credential: credential, turnID: id)
            asr = session
            await session.open()
        }
        let up = await session.ready()
        note("asr_connect", ["connect_ms": await session.connectMs ?? -1, "started_ms": await session.startedMs ?? -1,
                             "handshake": await session.handshakeStatus ?? 0])
        guard up, !Task.isCancelled else {
            let why = await session.outcome()
            note("error", "语音识别没有连上（\(why)）")
            return
        }
        note("asr_ready_ms", ms())
        guard let ctrl, ctrl.isConnected else { await session.cancel(); note("error", "板子已断开"); return }
        do {
            seq = seq &+ 1
            let ack = try await ctrl.command(TonoLinkVoiceCommand.listen(seq: seq, id: id), seq: seq, timeout: .seconds(3))
            guard ack.ok else { await session.cancel(); note("error", "板子拒绝录音：\(ack.error ?? "?")"); return }
        } catch {
            await session.cancel(); note("error", "listen 失败：\(error.localizedDescription)"); return
        }
        let forward = Task {
            for await opus in audio { await session.send(opus) }
            await session.finish()
        }
        let outcome = await withTaskCancellationHandler {
            await session.outcome()
        } onCancel: {
            Task { await session.cancel() }
        }
        forward.cancel()
        note("asr_ms", ms())
        note("packets", ["forwarded": await session.sentPackets, "received": tally.packets, "gaps": tally.gaps, "dropped": tally.dropped])
        guard !Task.isCancelled else { return }
        switch outcome {
        case .text(let text):
            note("heard", text)
            await answer(text, credential: credential, start: start)
        case .silent:
            note("heard", "")
        case .failed(let why):
            note("error", "语音识别失败：\(why)")
        case .pending:
            break
        }
    }

    /// Sends the heard text to the current chat and speaks the turn's last assistant text (§4).
    private func answer(_ text: String, credential: String, start: Date) async {
        let chat = ChatModel.shared
        guard await chat.send(text) else { note("error", "当前对话没有接受这条消息"); return }
        var waited = 0
        while !chat.turnRunning && waited < 50 { try? await Task.sleep(for: .milliseconds(100)); waited += 1 }
        while chat.turnRunning {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard let userIndex = chat.items.lastIndex(where: { $0.kind == .user && $0.text.contains(text) }),
              let reply = chat.items[(userIndex + 1)...].last(where: { $0.kind == .assistant && !$0.text.isEmpty }) else {
            note("reply", ""); return
        }
        note("reply", String(reply.text.prefix(500)))
        note("reply_ms", Int(Date().timeIntervalSince(start) * 1000))
        do { try await speak(reply.text, credential: credential) } catch { note("speak_error", error.localizedDescription) }
    }

    // MARK: - Speech

    /// Fetches 我在 once so the first wake answers without waiting for TTS.
    private func prefetchHere() async {
        guard hereAudio == nil, let credential = await credential() else { return }
        var pcm = Data()
        do { for try await chunk in tts.stream("我在", credential: credential) { pcm.append(chunk) } } catch { return }
        if hereAudio == nil { hereAudio = pcm }
    }

    private func speakHere(credential: String, timing: () -> Void) async throws {
        if hereAudio == nil {
            var pcm = Data()
            for try await chunk in tts.stream("我在", credential: credential) { pcm.append(chunk) }
            hereAudio = pcm
        }
        timing()
        try player.play(hereAudio ?? Data())
        await player.waitUntilDrained()
    }

    /// Reads `text` aloud, chunk by chunk, playing each as it streams (cloud-voice.md §3).
    func speak(_ text: String, credential: String) async throws {
        for chunk in CloudVoiceSpeech.chunks(CloudVoiceSpeech.speakable(text)) {
            try Task.checkCancellation()
            var current = credential
            do {
                for try await pcm in tts.stream(chunk, credential: current) { try player.play(pcm) }
            } catch let error as CloudVoiceError where error.isCredentialExpired {
                guard let renewed = await renewedCredential(after: current) else { throw error }
                current = renewed
                for try await pcm in tts.stream(chunk, credential: current) { try player.play(pcm) }
            }
        }
        await player.waitUntilDrained()
    }

    func stopSpeaking() {
        turn?.cancel()
        player.stop()
    }

    // MARK: - Credential (cloud-voice.md §1)

    func credential() async -> String? {
        let account: CloudVoiceCredential.Account
        do { account = try await TonoAccountSession.shared.accessToken().map { .token($0) } ?? .signedOut }
        catch { account = .unavailable }
        let settings = PhoneModelProviderSettings()
        let profile = (try? settings.load())?.selected
        let key = profile.flatMap { (try? settings.apiKey(for: $0.id)) ?? nil }
        return CloudVoiceCredential.resolve(account: account, profileBaseURL: profile?.baseURL, profileKey: key)
    }

    /// tono-account §5: invalidate an expired token once; use the new value only if it differs.
    private func renewedCredential(after old: String) async -> String? {
        await TonoAccountSession.shared.invalidate(accessToken: old)
        guard let fresh = await credential(), fresh != old else { return nil }
        return fresh
    }

    #if DEBUG
    // MARK: - DEBUG relay hooks

    var debugSnapshot: [String: Any] {
        ["state": state, "connected": ctrl?.isConnected == true, "audio_subscribed": ctrl?.isAudioSubscribed == true,
         "keep_alive": holdsKeepAlive, "turn_active": turn != nil, "last_turn": lastTurn]
    }

    /// Runs the ASR → chat → speech part on Opus packets the developer supplies
    /// (`[len u16 LE][Opus]…`), exactly as if the board had sent them.
    func debugRecognize(_ body: Data, chat: Bool) async -> [String: Any] {
        guard let credential = await credential() else { return ["error": "no cloud credential"] }
        var packets: [Data] = []
        var bytes = [UInt8](body)[...]
        while bytes.count >= 2 {
            let length = Int(bytes[bytes.startIndex]) | Int(bytes[bytes.startIndex + 1]) << 8
            bytes = bytes.dropFirst(2)
            guard length > 0, bytes.count >= length else { break }
            packets.append(Data(bytes.prefix(length)))
            bytes = bytes.dropFirst(length)
        }
        turnID = turnID &+ 1
        let session = CloudASRSession(credential: credential, turnID: turnID)
        await session.open()
        guard await session.ready() else {
            let why = await session.outcome()
            return ["error": "asr not ready: \(why)", "packets": packets.count]
        }
        for packet in packets {
            await session.send(packet)
            try? await Task.sleep(for: .milliseconds(20))   // real time, as the board sends them
        }
        await session.finish()
        let outcome = await session.outcome()
        var result: [String: Any] = ["packets": packets.count, "outcome": "\(outcome)"]
        if chat, case .text(let text) = outcome {
            lastTurn = ["id": Int(turnID), "source": "debug opus", "heard": text]
            await answer(text, credential: credential, start: Date())
            result["turn"] = lastTurn
        }
        return result
    }
    #endif
}

/// Plays 16 kHz mono s16le PCM through its own engine. It never sets the audio-session
/// category or activates it (spec/platform/ios-audio-session.md): the keep-alive owns that.
@MainActor final class VoicePCMPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var attached = false
    private var scheduled = 0
    private var generation = 0
    private var drained: [CheckedContinuation<Void, Never>] = []

    func play(_ pcm: Data) throws {
        let samples = pcm.count / 2
        guard samples > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples)
        let out = buffer.floatChannelData![0]
        pcm.withUnsafeBytes { raw in
            let input = raw.bindMemory(to: Int16.self)
            for i in 0..<samples { out[i] = Float(Int16(littleEndian: input[i])) / 32768 }
        }
        if !attached {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            attached = true
        }
        if !engine.isRunning { try engine.start() }
        scheduled += 1
        let mine = generation
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.finished(generation: mine) }
        }
        if !node.isPlaying { node.play() }
    }

    func waitUntilDrained() async {
        if scheduled == 0 { return }
        await withCheckedContinuation { drained.append($0) }
    }

    func stop() {
        generation += 1
        node.stop()
        scheduled = 0
        release()
    }

    private func finished(generation: Int) {
        guard generation == self.generation else { return }
        scheduled = max(0, scheduled - 1)
        if scheduled == 0 { release() }
    }

    private func release() {
        let waiters = drained; drained = []
        waiters.forEach { $0.resume() }
    }
}
