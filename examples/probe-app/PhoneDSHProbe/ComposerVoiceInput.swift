// SPDX-License-Identifier: MIT
import AVFoundation
import Observation
import ProbeKit
import Speech

/// On-device dictation. Only an explicit microphone tap requests permission.
@MainActor @Observable
final class ComposerVoiceInput: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var recording = false
    private(set) var recognizing = false
    private(set) var speaking = false
    private(set) var status = ""
    private var engine: AVAudioEngine?
    private var microphoneToken: PhoneAudioSessionLease.MicrophoneToken?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = UUID()
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.speaking = false }
    }

    func start(onText: @escaping (String) -> Void) {
        cancel()
        stopSpeaking()
        let id = UUID()
        generation = id
        recognizing = true
        status = "正在准备语音输入…"
        Task {
            let authorization = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            let microphone = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard generation == id else { return }
            guard authorization == .authorized, microphone else {
                cancel(); status = "请在系统设置中允许麦克风和语音识别。"; return
            }
            guard let recognizer = SFSpeechRecognizer(locale: .current),
                  recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
                cancel(); status = "当前语言的设备端语音识别暂不可用。"; return
            }
            do {
                microphoneToken = try PhoneAudioSessionLease.acquireMicrophoneUser()
                let engine = AVAudioEngine()
                self.engine = engine
                let request = SFSpeechAudioBufferRecognitionRequest()
                request.requiresOnDeviceRecognition = true
                request.shouldReportPartialResults = true
                self.request = request
                let input = engine.inputNode
                input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                    request.append(buffer)
                }
                task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    Task { @MainActor in
                        guard let self, self.generation == id else { return }
                        if let result, result.isFinal {
                            let text = result.bestTranscription.formattedString
                            self.cancel()
                            if !text.isEmpty { onText(text) }
                        } else if error != nil {
                            self.cancel(); self.status = "语音识别未完成，请重试。"
                        }
                    }
                }
                engine.prepare()
                try engine.start()
                recording = true
                status = "正在聆听，点麦克风结束"
            } catch {
                cancel(); status = "无法启动麦克风，请检查权限后重试。"
            }
        }
    }

    func finish() {
        stopCapture()
        request?.endAudio()
        status = "正在识别…"
    }

    func cancel() {
        generation = UUID()
        stopCapture()
        task?.cancel(); task = nil
        request = nil
        recognizing = false
        status = ""
    }

    private func stopCapture() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        recording = false
        if let token = microphoneToken {
            microphoneToken = nil
            PhoneAudioSessionLease.releaseMicrophoneUser(token)
        }
    }

    func speak(_ text: String) {
        cancel()
        stopSpeaking()
        let utterance = AVSpeechUtterance(string: text)
        synthesizer.speak(utterance)
        speaking = true
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        speaking = false
    }
}
