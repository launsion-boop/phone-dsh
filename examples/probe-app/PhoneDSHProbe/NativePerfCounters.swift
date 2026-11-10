// SPDX-License-Identifier: MIT
// Lightweight render counters for device acceptance.
//
// Counting is always compiled, but reporting is gated to DEBUG builds or the
// explicit `chat.perfCounters` default in Release. The caller supplies the
// sink (the Chat page writes through `ChatModel.appendDiagnostic`), so this
// file stays free of UI/host dependencies and can compile in the test target.

import Foundation

final class NativePerfCounters {
    static let shared = NativePerfCounters()
    static let releaseSwitchKey = "chat.perfCounters"
    static let reportInterval: TimeInterval = 5

    private let lock = NSLock()
    private var bodyDelta = 0
    private var rowDelta = 0
    private var markdownDelta = 0
    private var mathDelta = 0
    private var lcsDelta = 0
    private var lastReport = Date.distantPast

    static var isEnabled: Bool {
        #if DEBUG
        return true
        #else
        return UserDefaults.standard.bool(forKey: releaseSwitchKey)
        #endif
    }

    func bodyRendered() {
        guard Self.isEnabled else { return }
        lock.lock(); bodyDelta += 1; lock.unlock()
    }

    func timelineRebuilt() {
        guard Self.isEnabled else { return }
        lock.lock(); rowDelta += 1; lock.unlock()
    }

    func markdownParsed() {
        guard Self.isEnabled else { return }
        lock.lock(); markdownDelta += 1; lock.unlock()
    }

    func mathRasterized() {
        guard Self.isEnabled else { return }
        lock.lock(); mathDelta += 1; lock.unlock()
    }

    func lcsComputed() {
        guard Self.isEnabled else { return }
        lock.lock(); lcsDelta += 1; lock.unlock()
    }

    /// Emits at most one delta line per five seconds, and only when something
    /// happened. The caller decides where the line goes.
    func reportIfDue(now: Date = Date(), sink: (String) -> Void) {
        guard Self.isEnabled else { return }
        lock.lock()
        guard now.timeIntervalSince(lastReport) >= Self.reportInterval else {
            lock.unlock(); return
        }
        let body = bodyDelta, rows = rowDelta, md = markdownDelta, math = mathDelta, lcs = lcsDelta
        guard body + rows + md + math + lcs > 0 else {
            lock.unlock(); return
        }
        bodyDelta = 0; rowDelta = 0; markdownDelta = 0; mathDelta = 0; lcsDelta = 0
        lastReport = now
        lock.unlock()
        sink("perf body=\(body) rows=\(rows) md=\(md) math=\(math) lcs=\(lcs)")
    }

    /// Test hook: clear deltas and the report clock.
    func resetForTesting() {
        lock.lock()
        bodyDelta = 0; rowDelta = 0; markdownDelta = 0; mathDelta = 0; lcsDelta = 0
        lastReport = Date.distantPast
        lock.unlock()
    }
}
