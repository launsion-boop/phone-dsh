// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLoopback: bounded request timing diagnostics.
//
// The loopback origin is where a background/resume stall becomes visible: a
// page fetch that never completes stalls the Worker right after the image and
// overlay were served. These lines deliberately carry only the method, the
// query-free path, the status and milliseconds. Headers, cookies, query strings
// and bodies never enter the sink, so the diagnostic file can be attached to a
// report without redaction.
//
// The file is written by the host's boot-timings recorder; tests inject a
// sink and a monotonic clock.

import Foundation

/// Emits `slow-request`/`inflight` lines for one loopback server.
public struct LoopbackRequestDiagnostics: Sendable {
    /// Receives one complete line (without the trailing newline).
    public typealias Sink = @Sendable (String) -> Void

    /// A request that takes at least this long emits one `slow-request` line.
    public let slowRequestMilliseconds: Double
    /// An in-flight request emits one `inflight` line per interval.
    public let inflightReportMilliseconds: Double

    private let sink: Sink
    private let now: @Sendable () -> TimeInterval

    public init(sink: @escaping Sink,
                now: @escaping @Sendable () -> TimeInterval = {
                    ProcessInfo.processInfo.systemUptime
                },
                slowRequestMilliseconds: Double = 2_000,
                inflightReportMilliseconds: Double = 10_000) {
        self.sink = sink
        self.now = now
        self.slowRequestMilliseconds = max(0, slowRequestMilliseconds)
        self.inflightReportMilliseconds = max(0.001, inflightReportMilliseconds)
    }

    /// Starts timing one request. `path` is reduced to its path component
    /// (query and fragment removed) before it can reach the sink.
    public func begin(method: String, path: String) -> Observation {
        Observation(method: Self.methodToken(method),
                    path: Self.queryFreePath(path),
                    startedAt: now(),
                    sink: sink,
                    now: now,
                    slowRequestMilliseconds: slowRequestMilliseconds,
                    inflightReportMilliseconds: inflightReportMilliseconds)
    }

    /// One request's timer. The ticker is a weak capture, so a dropped
    /// observation (server shut down mid-request) stops logging as well.
    public final class Observation: @unchecked Sendable {
        private let method: String
        private let path: String
        private let startedAt: TimeInterval
        private let sink: Sink
        private let now: @Sendable () -> TimeInterval
        private let slowRequestMilliseconds: Double
        private let inflightReportMilliseconds: Double
        private let lock = NSLock()
        private var finished = false
        private var ticker: Task<Void, Never>?

        init(method: String,
             path: String,
             startedAt: TimeInterval,
             sink: @escaping Sink,
             now: @escaping @Sendable () -> TimeInterval,
             slowRequestMilliseconds: Double,
             inflightReportMilliseconds: Double) {
            self.method = method
            self.path = path
            self.startedAt = startedAt
            self.sink = sink
            self.now = now
            self.slowRequestMilliseconds = slowRequestMilliseconds
            self.inflightReportMilliseconds = inflightReportMilliseconds
            let interval = inflightReportMilliseconds
            self.ticker = Task { [weak self] in
                while !Task.isCancelled {
                    // `interval` is milliseconds, not seconds.
                    let nanoseconds = UInt64(max(0.001, interval) * 1_000_000)
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    guard !Task.isCancelled, let self else { return }
                    if self.reportInflightIfDue() == false { return }
                }
            }
        }

        deinit {
            ticker?.cancel()
        }

        /// Marks the response complete and emits the one slow line when due.
        /// Idempotent: a second call (connection teardown) changes nothing.
        public func finish(status: Int) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            let ticker = self.ticker
            self.ticker = nil
            lock.unlock()
            ticker?.cancel()
            let elapsed = max(0, (now() - startedAt) * 1_000)
            guard elapsed >= slowRequestMilliseconds else { return }
            sink("slow-request method=\(method) path=\(path) "
                + "status=\(status) elapsed_ms=\(Int(elapsed.rounded()))")
        }

        /// Emits one in-flight line when the interval threshold is due.
        /// Internal so a test can drive the same predicate the ticker uses.
        @discardableResult
        func reportInflightIfDue() -> Bool {
            lock.lock()
            let isFinished = finished
            lock.unlock()
            guard isFinished == false else { return false }
            let elapsed = max(0, (now() - startedAt) * 1_000)
            guard elapsed >= inflightReportMilliseconds else { return true }
            sink("inflight method=\(method) path=\(path) "
                + "elapsed_ms=\(Int(elapsed.rounded()))")
            return true
        }

        /// Test seam: whether the observation already completed.
        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }
    }

    /// A route method is bounded to the token shape the reader already emits.
    static func methodToken(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let token = raw.uppercased().unicodeScalars
            .filter { allowed.contains($0) }
            .prefix(16)
        return token.isEmpty ? "-" : String(String.UnicodeScalarView(token))
    }

    /// Keeps only the path component. The diagnostic never carries a query or
    /// fragment even if a caller passes a full target.
    static func queryFreePath(_ raw: String) -> String {
        var path = raw
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            path = String(path[..<cut])
        }
        // A path cannot contain whitespace or controls. Collapse anything that
        // could break the one-line format instead of writing it verbatim.
        let filtered = path.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.controlCharacters.contains($0)
        }
        path = String(String.UnicodeScalarView(filtered))
        if path.isEmpty { return "/" }
        if path.count > 200 { path = String(path.prefix(200)) }
        return path
    }
}
