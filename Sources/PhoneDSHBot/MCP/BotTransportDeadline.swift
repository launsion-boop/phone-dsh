// SPDX-License-Identifier: MIT

import Foundation

/// A hard wall-clock bound for one await on a live Worker transport.
///
/// A WebSocket that died without an EOF leaves every request on it suspended
/// forever; neither `URLSession` nor `DSHMuxConnection` promises to honour task
/// cancellation. `transportIsAttached` is an object flag, so it can only say a
/// transport was attached, never that it still answers. Racing the operation
/// against a deadline is the only way to turn that into a bounded, retryable
/// failure.
///
/// The race is deliberately unstructured: `withThrowingTaskGroup` would wait
/// for a non-cooperative child on scope exit, recreating the hang. The first
/// result (operation or deadline) wins; on either outcome the losing side is
/// cancelled, so a fast call leaves no sleeping timer behind. Expiry returns
/// without awaiting the abandoned operation, which may stay suspended until
/// the process drops the dead connection.
enum BotTransportDeadline {
    // The protocol doc froze these operation budgets. A healthy Worker answers
    // well inside each one; a model turn is never bounded by them because only
    // a single request is raced, never the collector.

    /// `openMux` (WebSocket establishment) budget.
    static let openMuxMilliseconds = 10_000
    /// Waiting for the `session/follow` snapshot after opening the stream.
    static let snapshotMilliseconds = 15_000
    /// Submitting `session/prompt`.
    static let promptMilliseconds = 20_000
    /// Handshake/control unary calls: claim, cancel, archive, list, mux send.
    static let controlMilliseconds = 10_000
    /// Main-session recovery calls: `session/create` and `session/page`.
    static let recoveryMilliseconds = 30_000
    /// How long `collectTurn` may sit on an idle `session/follow` stream
    /// between frames. A running model step can legitimately think for a long
    /// time, so this covers only a stream that produced no frame at all.
    static let defaultIdleMilliseconds = 300_000

    /// `attachTransport`'s bounded wait for interrupted attempts to settle on
    /// their own before they are cancelled and dropped.
    static let adoptSettleMilliseconds = 2_000

    /// The stable, human-safe text the App shows when the connection stops
    /// answering. It is retryable: rebinding a live transport is the recovery.
    static let unresponsiveMessage = "与 App 的连接没有响应，请稍后重试。"

    struct Expired: Error, Sendable {}

    /// Runs `operation` with at most `milliseconds` of wall-clock time.
    ///
    /// - Throws: the operation's own error, `Expired` when the budget ran out,
    ///   or `CancellationError` when the calling task was cancelled.
    static func run<T: Sendable>(
        milliseconds: Int,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let (stream, continuation) = AsyncStream<Result<T, Error>>.makeStream(
            bufferingPolicy: .bufferingOldest(1))
        let work = Task {
            do {
                continuation.yield(.success(try await operation()))
            } catch {
                continuation.yield(.failure(error))
            }
            continuation.finish()
        }
        let timer = Task {
            do {
                try await Task.sleep(for: .milliseconds(max(1, milliseconds)))
            } catch {
                return
            }
            continuation.yield(.failure(Expired()))
            continuation.finish()
        }
        var iterator = stream.makeAsyncIterator()
        let result = await withTaskCancellationHandler {
            await iterator.next()
        } onCancel: {
            // The operation may ignore cancellation; resolve the race here so
            // the caller does not wait for it. A late yield is dropped because
            // the stream is already finished.
            work.cancel()
            timer.cancel()
            continuation.yield(.failure(CancellationError()))
            continuation.finish()
        }
        work.cancel()
        timer.cancel()
        guard let result else { throw CancellationError() }
        return try result.get()
    }
}
