// SPDX-License-Identifier: MIT

import Foundation

/// Stable callback target for the shared user-dsh observer. Selection swaps the
/// queue under the lock; the observer itself never stops, so a write that
/// arrives during a Bot switch is enqueued on the queue that was current when
/// the callback ran rather than falling into a stop→start gap.
public final class BotSkillQueueRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: BotSkillEventQueue?

    public init() {}

    public func set(_ queue: BotSkillEventQueue) {
        lock.lock(); self.queue = queue; lock.unlock()
    }

    public func userWrite(_ name: String) {
        let queue = current()
        queue?.enqueue { [weak queue] in
            guard let queue else { return }
            await queue.userWrite(name)
        }
    }

    /// Observer path: the current queue consumes one operation-scoped
    /// suppression (feature-admin) or falls through to the normal record.
    public func observeUserWrite(_ name: String) {
        let queue = current()
        queue?.enqueue { [weak queue] in
            guard let queue else { return }
            await queue.observeUserWrite(name)
        }
    }

    public func observeUserDelete(_ name: String) {
        let queue = current()
        queue?.enqueue { [weak queue] in
            guard let queue else { return }
            await queue.observeUserDelete(name)
        }
    }

    public func userDelete(_ name: String) {
        let queue = current()
        queue?.enqueue { [weak queue] in
            guard let queue else { return }
            await queue.userDelete(name)
        }
    }

    private func current() -> BotSkillEventQueue? {
        lock.lock(); defer { lock.unlock() }
        return queue
    }
}
