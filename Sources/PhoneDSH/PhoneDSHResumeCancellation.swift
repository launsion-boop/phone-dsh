// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — one foreground resume's cancellation token.
//
// The App can background while a resume is between engine phases. Waiting for
// the full resume budget is wrong: the WebKit page did not run, and the next
// foreground return should start a fresh resume instead of inheriting a
// half-booted Worker. The host cancels this token from `setForeground(false)`;
// every phase wait races it and the winner tears the new page down.

import Foundation

/// A one-shot, thread-safe cancellation signal with async waiters.
public final class PhoneDSHResumeCancellation: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var cancelled = false
    private var waiters: [Waiter] = []

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Cancels once and resumes every waiter. Idempotent.
    public func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let waiters = self.waiters
        self.waiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.continuation.resume() }
    }

    /// Suspends until ``cancel()`` is called, or returns immediately when it
    /// already was.
    public func wait() async {
        if isCancelled { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters.append(Waiter(id: waiterID, continuation: continuation))
                lock.unlock()
            }
        } onCancel: {
            // A group that already has a winning boot task cancels the losing
            // wait; remove its continuation instead of leaking it forever.
            self.removeWaiter(waiterID)
        }
    }

    private func removeWaiter(_ id: UUID) {
        lock.lock()
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        let waiter = waiters.remove(at: index)
        lock.unlock()
        waiter.continuation.resume()
    }

    /// Throws ``PhoneDSHError/resumeCancelled`` when the token was cancelled.
    public func throwIfCancelled() throws {
        if isCancelled { throw PhoneDSHError.resumeCancelled }
    }
}
