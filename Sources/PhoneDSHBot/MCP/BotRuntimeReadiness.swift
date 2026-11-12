// SPDX-License-Identifier: MIT

import Foundation

/// One bounded wait for the App runtime to finish reattaching a Worker.
/// `BotMCPRuntime` calls the composition's probe before a Bot/team tool runs;
/// the Worker MCP client otherwise keeps its request open until its 130 s
/// `toolCallTimeoutMs`. The wait polls a small shared state (the composition is
/// `@MainActor`), returns as soon as it is ready, and gives up at the deadline.
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
}
