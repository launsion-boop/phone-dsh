// SPDX-License-Identifier: MIT
// phone-dsh — cloud speech clients for the TonoLink voice turn (spec/v1/cloud-voice.md §2, §3).

import Foundation

/// One pdsh-asr.v1 recognition session (§2). One connection per turn; never reused or replayed.
public actor CloudASRSession {
    private let task: URLSessionWebSocketTask
    private let turnID: UInt32
    private var transcript = CloudASRTranscript()
    private var started = false
    private var queued: [Data] = []
    private var finishSent = false
    private var finishTimeoutMs = CloudVoice.finishTimeoutDefaultMs
    private var waiters: [CheckedContinuation<CloudASRTranscript.Outcome, Never>] = []
    private var readyWaiters: [CheckedContinuation<Bool, Never>] = []
    private var deadline: Task<Void, Never>?
    /// What the handshake answered when the upgrade failed (401 → tono-account §5).
    public private(set) var handshakeStatus: Int?
    public private(set) var sentPackets = 0

    public init(credential: String, turnID: UInt32, session: URLSession = .shared, url: URL = CloudVoice.asrURL) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue(CloudVoice.asrSubprotocol, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024
        self.turnID = turnID
    }

    /// Connects, sends `start` and starts reading; `started` must arrive within 5 s.
    public func open() {
        task.resume()
        task.send(.string(String(decoding: CloudVoice.startMessage(turnID: turnID), as: UTF8.self))) { _ in }
        arm(after: CloudVoice.startedTimeoutMs, reason: "no started within 5 s")
        Task { await self.receiveLoop() }
    }

    /// Queues one Opus body; sent at once after `started`, in arrival order.
    public func send(_ opus: Data) {
        guard transcript.outcome == .pending, !finishSent, !opus.isEmpty else { return }
        guard started else {
            if queued.count >= CloudVoice.preStartQueueMax { cancel(); return }
            queued.append(opus); return
        }
        write(opus)
    }

    /// The board's audio ended (§4.1).
    public func finish() {
        guard transcript.outcome == .pending, !finishSent else { return }
        finishSent = true
        if started { sendFinish() }
    }

    public func cancel() {
        guard transcript.outcome == .pending else { return }
        task.send(.string(String(decoding: CloudVoice.cancelMessage, as: UTF8.self))) { _ in }
        conclude("cancelled")
    }

    /// True once `started` arrived; false when the session ended first (handshake refused, deadline).
    public func ready() async -> Bool {
        if started { return true }
        if transcript.outcome != .pending { return false }
        return await withCheckedContinuation { readyWaiters.append($0) }
    }

    public func outcome() async -> CloudASRTranscript.Outcome {
        if transcript.outcome != .pending { return transcript.outcome }
        return await withCheckedContinuation { waiters.append($0) }
    }

    // MARK: -

    private func write(_ opus: Data) {
        sentPackets += 1
        task.send(.data(opus)) { _ in }
    }

    private func sendFinish() {
        task.send(.string(String(decoding: CloudVoice.finishMessage, as: UTF8.self))) { _ in }
        arm(after: finishTimeoutMs + CloudVoice.finishGraceMs, reason: "no result in time")
    }

    private func arm(after ms: Int, reason: String) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(ms))
            guard !Task.isCancelled else { return }
            await self?.expire(reason)
        }
    }

    private func expire(_ reason: String) {
        guard transcript.outcome == .pending else { return }
        task.send(.string(String(decoding: CloudVoice.cancelMessage, as: UTF8.self))) { _ in }
        conclude(reason)
    }

    private func receiveLoop() async {
        while transcript.outcome == .pending {
            let message: URLSessionWebSocketTask.Message
            do { message = try await task.receive() } catch {
                handshakeStatus = (task.response as? HTTPURLResponse)?.statusCode
                transcript.closed()
                conclude(nil)
                return
            }
            guard case .string(let text) = message else { continue }
            let decoded = CloudASRMessage.decode(text)
            if case .started(let timeout) = decoded, !started {
                started = true
                finishTimeoutMs = timeout
                deadline?.cancel()
                queued.forEach(write); queued = []
                if finishSent { sendFinish() }
                let ready = readyWaiters; readyWaiters = []
                ready.forEach { $0.resume(returning: true) }
            }
            transcript.apply(decoded)
        }
        conclude(nil)
    }

    private func conclude(_ localFailure: String?) {
        // A local end (cancel, missed deadline) is the session's failure.
        if let reason = localFailure { transcript.fail(reason) }
        guard transcript.outcome != .pending else { return }
        deadline?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
        let result = transcript.outcome
        let pending = waiters; waiters = []
        pending.forEach { $0.resume(returning: result) }
        let ready = readyWaiters; readyWaiters = []
        ready.forEach { $0.resume(returning: started) }
    }
}

/// `/v1/tts/speech` with `pcm` (§3): 16 kHz mono s16le, delivered as it streams.
public struct CloudTTSClient: Sendable {
    public var session: URLSession
    public var url: URL

    public init(session: URLSession = .shared, url: URL = CloudVoice.ttsURL) {
        self.session = session
        self.url = url
    }

    /// Whole-sample PCM chunks (~100 ms). Throws `CloudVoiceError` for a non-200 answer;
    /// a stream that ends with an error after audio started is incomplete (§3).
    public func stream(_ text: String, credential: String) -> AsyncThrowingStream<Data, Error> {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = CloudVoice.speechRequest(text)
        request.timeoutInterval = 30
        let session = self.session
        return AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var body = Data()
                        for try await byte in bytes { body.append(byte); if body.count >= 16_384 { break } }
                        throw Self.error(status: status, body: body)
                    }
                    var buffer = Data()
                    buffer.reserveCapacity(3200)
                    for try await byte in bytes {
                        buffer.append(byte)
                        if buffer.count >= 3200 { continuation.yield(buffer); buffer = Data(); buffer.reserveCapacity(3200) }
                    }
                    if buffer.count > 1 { continuation.yield(buffer.prefix(buffer.count & ~1)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    static func error(status: Int, body: Data) -> CloudVoiceError {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        let code = (error?["code"] as? String) ?? (error?["type"] as? String)
        return CloudVoiceError(status: status, code: code, "语音合成失败（HTTP \(status)\(code.map { " \($0)" } ?? "")）")
    }
}
