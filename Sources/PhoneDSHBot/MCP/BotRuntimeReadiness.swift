// SPDX-License-Identifier: MIT

import Foundation

/// Thread-safe readiness snapshot shared by the App composition and the Bot
/// MCP runtime.
///
/// The composition is main-actor isolated, but a `tools/call` must not hop
/// onto the main actor merely to read its readiness. A blocked main thread
/// (for example the SwiftUI layout loop fixed by `chat-loop2`) would otherwise
/// hold every Bot tool until the Worker's 130 s client deadline. The
/// composition writes this snapshot whenever its state changes; the probe
/// reads it synchronously from any executor.
public final class BotRuntimeReadinessState: @unchecked Sendable {
    private let lock = NSLock()
    private var ready: Bool
    private var terminal: Bool

    public init(ready: Bool = false, terminal: Bool = false) {
        self.ready = ready
        self.terminal = terminal
    }

    public func update(ready: Bool, terminal: Bool) {
        lock.lock()
        self.ready = ready
        self.terminal = terminal
        lock.unlock()
    }

    public var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }

    public var isTerminal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminal
    }
}

/// One bounded wait for the App runtime to finish reattaching a Worker.
/// `BotMCPRuntime` calls the composition's probe before a Bot/team tool runs;
/// the Worker MCP client otherwise keeps its request open until its 130 s
/// `toolCallTimeoutMs`.
///
/// The `isReady` closure form is kept for callers that genuinely have an async
/// readiness source. The App composition uses the snapshot form below so that
/// a blocked main actor can never extend the wait past its budget.
public enum BotRuntimeReadiness {
    /// - Parameters:
    ///   - timeoutMilliseconds: Upper bound for the whole wait.
    ///   - pollMilliseconds: Poll cadence; production uses 100 ms.
    ///   - isReady: True once the runtime can execute a tool.
    ///   - isTerminal: True for a stopped/failed runtime; stops the wait early.
    public static func wait(
        timeoutMilliseconds: Int,
        pollMilliseconds: Int = 100,
        isReady: @Sendable () async -> Bool,
        isTerminal: @Sendable () async -> Bool = { false }
    ) async -> Bool {
        if await isReady() { return true }
        if await isTerminal() { return false }
        let deadline = Date().addingTimeInterval(
            Double(max(0, timeoutMilliseconds)) / 1_000)
        let poll = max(10, pollMilliseconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(poll) * 1_000_000)
            if await isReady() { return true }
            if await isTerminal() { return false }
        }
        return await isReady()
    }

    /// Snapshot-based bounded wait. It never calls into the main actor, so the
    /// deadline is observable even while the UI thread is blocked.
    public static func wait(
        timeoutMilliseconds: Int,
        pollMilliseconds: Int = 100,
        state: BotRuntimeReadinessState
    ) async -> Bool {
        if state.isReady { return true }
        if state.isTerminal { return false }
        let deadline = Date().addingTimeInterval(
            Double(max(0, timeoutMilliseconds)) / 1_000)
        let poll = max(10, pollMilliseconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(poll) * 1_000_000)
            if state.isReady { return true }
            if state.isTerminal { return false }
        }
        return state.isReady
    }
}
