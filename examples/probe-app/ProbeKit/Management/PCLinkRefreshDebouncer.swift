// SPDX-License-Identifier: MIT
// Event-driven `session/list` refresh coalescing.
//
// Opening the drawer, switching a Session and an online transition can each
// ask for a full management read. On this PC that read is ~5.5 MB, so firing
// several in a row is user-visible. The debouncer keeps the last request in a
// short window; the model's in-flight `refreshPending` loop additionally turns
// callers that arrive during a read into one follow-up pass.

import Foundation

@MainActor
public final class PCLinkRefreshDebouncer {
    /// Number of `schedule` calls, including ones cancelled by a later call.
    public private(set) var requestedCount = 0
    /// Number of operations that actually started.
    public private(set) var runCount = 0

    private let delay: Duration
    private var task: Task<Void, Never>?

    public init(delay: Duration = .milliseconds(250)) {
        self.delay = delay
    }

    /// Replace the pending request; only the last one in the window runs.
    public func schedule(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        requestedCount += 1
        task?.cancel()
        task = Task { [weak self, delay] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.runCount += 1
            await operation()
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }
}
