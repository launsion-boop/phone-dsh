// SPDX-License-Identifier: MIT
// Main-thread hang detector.
//
// A background timer pings the main queue every 250 ms. When the queue has not
// answered for at least one second, the monitor writes a `main-hang start`
// line; the first answer after that writes `main-hang end ms=<duration>
// marker=<last marker>`. Both go through the shared off-main status log, so a
// blocked main actor can still leave evidence.
//
// `mark(_:)` is the hot path used by the chat pipeline: it copies one
// StaticString into a lock-protected slot. No formatting, no allocation.

import Foundation

public final class MainThreadHangMonitor {
    public typealias Sink = (String) -> Void

    public static let shared = MainThreadHangMonitor()

    private let queue = DispatchQueue(label: "dev.phone-dsh.main-thread-hang", qos: .utility)
    private let lock = NSLock()
    private let pingInterval: TimeInterval
    private let hangThreshold: TimeInterval

    private var timer: DispatchSourceTimer?
    private var sink: Sink?
    private var running = false
    private var lastMarker: StaticString = ""
    private var lastAnswer: TimeInterval = 0
    private var hangStart: TimeInterval?
    private var hangMarker: StaticString = ""

    /// - Parameters:
    ///   - pingInterval: how often the background timer asks the main queue.
    ///   - hangThreshold: how long without an answer before a hang is recorded.
    public init(pingInterval: TimeInterval = 0.25, hangThreshold: TimeInterval = 1.0) {
        self.pingInterval = max(0.01, pingInterval)
        self.hangThreshold = max(self.pingInterval, hangThreshold)
    }

    deinit {
        timer?.cancel()
    }

    /// Starts the single production monitor. Idempotent.
    public func start(sink: @escaping Sink) {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        self.sink = sink
        lastAnswer = Self.uptime()
        hangStart = nil

        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.milliseconds(max(1, Int(pingInterval * 1_000)))
        timer.schedule(deadline: .now() + interval, repeating: interval,
                       leeway: .milliseconds(max(1, min(50, Int(pingInterval * 100)))))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        self.timer = timer
        lock.unlock()
        timer.resume()
        pingMain()
    }

    public func stop() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        running = false
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        sink = nil
        hangStart = nil
        lock.unlock()
    }

    /// Records the phase the main thread is about to run. Allocation-free.
    public func mark(_ phase: StaticString) {
        lock.lock()
        lastMarker = phase
        lock.unlock()
    }

    /// Convenience for call sites that do not hold the instance.
    public static func mark(_ phase: StaticString) {
        shared.mark(phase)
    }

    private func pingMain() {
        DispatchQueue.main.async { [weak self] in
            self?.mainAnswered()
        }
    }

    private func tick() {
        let now = Self.uptime()
        var startLine: String?
        lock.lock()
        if running, hangStart == nil, now - lastAnswer >= hangThreshold {
            // The main queue has been silent since `lastAnswer`; record the
            // phase that was marked when it stopped answering.
            hangStart = lastAnswer
            hangMarker = lastMarker
            let elapsed = Int(max(0, now - lastAnswer) * 1_000)
            startLine = "main-hang start elapsed_ms=\(elapsed) marker=\(Self.describe(hangMarker))"
        }
        let sink = self.sink
        lock.unlock()
        if let startLine, let sink {
            queue.async { sink(startLine) }
        }
        pingMain()
    }

    private func mainAnswered() {
        let now = Self.uptime()
        var endLine: String?
        lock.lock()
        lastAnswer = max(lastAnswer, now)
        if let started = hangStart {
            hangStart = nil
            let duration = Int(max(0, now - started) * 1_000)
            endLine = "main-hang end ms=\(duration) marker=\(Self.describe(hangMarker))"
        }
        let sink = self.sink
        lock.unlock()
        if let endLine, let sink {
            queue.async { sink(endLine) }
        }
    }

    private static func uptime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private static func describe(_ phase: StaticString) -> String {
        let text = String(describing: phase)
        return text.isEmpty ? "-" : text
    }
}
