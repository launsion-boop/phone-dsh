// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — resume diagnostics and the visibility wait clock.
//
// The background park is normal on a phone; the foreground resume is the path
// that hung on the device. Cold starts are already measured in
// `boot-timings.log`, but a resume produced no line at all: `Host parked` was
// the last record and neither `Host resumed` nor `Resume failed` followed.
// This recorder writes one comparable line per resume (`resume <ts> ok|failed|
// timeout overlay=… loopback=… webview=… visible=… navigation=… boot-ready=…
// hello=… running=…`, with `stopped=<phase>` on a failure).
//
// The visibility wait uses an injectable clock so its two cases (becomes
// visible before the budget, never visible) are testable without real time.

import Foundation

/// A monotonic-ish wall clock plus a sleep. Production uses `Date`/`Task.sleep`;
/// a test can advance a virtual time and flip the fake engine's visibility from
/// its sleep closure (so the wait observes the change at the expected tick).
struct PhoneDSHResumeVisibilityClock: Sendable {
    var now: @Sendable () -> Date
    var sleep: @Sendable (TimeInterval) async -> Void
    /// Poll interval while waiting for the WebView to become visible.
    var pollInterval: TimeInterval

    static let system = PhoneDSHResumeVisibilityClock(
        now: { Date() },
        sleep: { seconds in
            guard seconds > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        pollInterval: 0.1)
}

/// One resume's phase marks, in order. Values are milliseconds since the
/// resume started (the same cumulative style as `boot-timings.log`).
struct PhoneDSHResumeTiming {
    let startedAt: Date
    private(set) var phases: [(name: String, milliseconds: Double)] = []

    init(startedAt: Date = Date()) {
        self.startedAt = startedAt
    }

    func elapsedMilliseconds(at date: Date = Date()) -> Double {
        max(0, date.timeIntervalSince(startedAt) * 1_000)
    }

    mutating func mark(_ name: String, at date: Date = Date()) {
        mark(name, milliseconds: elapsedMilliseconds(at: date))
    }

    mutating func mark(_ name: String, milliseconds: Double) {
        // Keep a phase's first mark: a retried boot attempt must not move an
        // earlier phase later in the line.
        guard phases.contains(where: { $0.name == name }) == false else { return }
        phases.append((name, max(0, milliseconds)))
    }

    /// One line in the `boot-timings.log` style. `stoppedAt` is the phase the
    /// resume was inside when it failed or timed out. `note` carries an enum
    /// only (for example `visible-timeout`), never a path or user content.
    func line(outcome: String, stoppedAt: String?, note: String? = nil) -> String {
        var fields = phases.map { "\($0.name)=\(Int($0.milliseconds.rounded()))ms" }
        if outcome != "ok", let stoppedAt, stoppedAt.isEmpty == false {
            fields.append("stopped=\(stoppedAt)")
        }
        if let note, note.isEmpty == false {
            fields.append("note=\(note)")
        }
        let stamp = ISO8601DateFormatter().string(from: startedAt)
        return "resume \(stamp) \(outcome) "
            + fields.joined(separator: " ") + "\n"
    }
}
