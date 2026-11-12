// SPDX-License-Identifier: MIT
// Per-turn persistence counters: fsync calls and bytes written
// (spec/v1/budgets.md §7).
//
// This file is observation only. `LogSupport` increments the counters at the
// existing `write()` / `fsync` / `F_FULLFSYNC` sites, so no write order, sync
// point, CRC or file format changes. The counters cover the stores this module
// owns: WAL segments, journal, materialized copy, blob store, overlay and
// manifest. Steps, the exec ledger and the response log live in other modules
// and are not counted here.

import Foundation

/// The two persistence metrics `spec/v1/budgets.md` §7 collects for one user
/// turn: `fsync_calls_per_turn` and `bytes_written_per_turn`.
///
/// The counters are process-wide and include every `PhoneDSHLog` store. The
/// host resets them at turn start and settles them at turn end; an epoch close
/// may settle too, because it is where D18's fsync pass happens.
public struct WorkspaceLogIOCounters: Equatable, Sendable {
    /// `fsync` and `fcntl(F_FULLFSYNC)` calls issued by this process.
    public var fsyncCalls: Int
    /// Bytes accepted by `write()` for a `PhoneDSHLog` store.
    public var bytesWritten: Int

    public init(fsyncCalls: Int = 0, bytesWritten: Int = 0) {
        self.fsyncCalls = fsyncCalls
        self.bytesWritten = bytesWritten
    }

    /// True when no persistence work was counted in the current window.
    public var isEmpty: Bool { fsyncCalls == 0 && bytesWritten == 0 }

    /// Counters accumulated since the last ``settle()`` or ``reset()``.
    public static func current() -> WorkspaceLogIOCounters {
        WorkspaceLogIOCounterStorage.shared.snapshot()
    }

    /// Settles one turn (or one epoch boundary): returns the counters
    /// accumulated since the previous settlement and resets them. The caller
    /// reports the returned value as the per-turn budget input.
    @discardableResult
    public static func settle() -> WorkspaceLogIOCounters {
        WorkspaceLogIOCounterStorage.shared.settle()
    }

    /// Starts a new measurement window, discarding the counters. Called at
    /// turn start when the accounting window must begin before any write.
    public static func reset() {
        WorkspaceLogIOCounterStorage.shared.reset()
    }

    /// Records `count` issued `fsync` / `F_FULLFSYNC` calls. Called only from
    /// the `LogSupport` syscall helpers.
    static func recordFsyncCalls(_ count: Int = 1) {
        guard count > 0 else { return }
        WorkspaceLogIOCounterStorage.shared.add(fsyncCalls: count, bytesWritten: 0)
    }

    /// Records `count` bytes accepted by `write()`. Called only from the
    /// `LogSupport` syscall helper, so retried partial writes count exactly
    /// the bytes the kernel accepted.
    static func recordBytesWritten(_ count: Int) {
        guard count > 0 else { return }
        WorkspaceLogIOCounterStorage.shared.add(fsyncCalls: 0, bytesWritten: count)
    }
}

/// Lock-protected storage behind ``WorkspaceLogIOCounters``. Counting is one
/// `Int` add under a lock; every counted operation is a filesystem syscall
/// that costs orders of magnitude more.
private final class WorkspaceLogIOCounterStorage: @unchecked Sendable {
    static let shared = WorkspaceLogIOCounterStorage()

    private let lock = NSLock()
    private var fsyncCalls = 0
    private var bytesWritten = 0

    func snapshot() -> WorkspaceLogIOCounters {
        lock.lock()
        defer { lock.unlock() }
        return WorkspaceLogIOCounters(fsyncCalls: fsyncCalls,
                                      bytesWritten: bytesWritten)
    }

    func settle() -> WorkspaceLogIOCounters {
        lock.lock()
        defer { lock.unlock() }
        let settled = WorkspaceLogIOCounters(fsyncCalls: fsyncCalls,
                                             bytesWritten: bytesWritten)
        fsyncCalls = 0
        bytesWritten = 0
        return settled
    }

    func reset() {
        lock.lock()
        fsyncCalls = 0
        bytesWritten = 0
        lock.unlock()
    }

    func add(fsyncCalls count: Int, bytesWritten bytes: Int) {
        lock.lock()
        fsyncCalls += count
        bytesWritten += bytes
        lock.unlock()
    }
}
