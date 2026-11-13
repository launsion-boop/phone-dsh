// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHGateway: buffered response-log writes.
//
// W7 (§13) allows the response log to buffer asynchronously as long as the
// recorded bytes and the replay semantics do not change and forwarding never
// waits for the log's disk I/O. This accumulator keeps the consumer's chunks
// in order, coalesces small writes into one `ResponseLog.append` and only ever
// hands a complete, contiguous byte range to the log. A partial stream is
// still discarded by `abort`, never committed.

import Foundation

/// One contiguous range of a response body, ready for `ResponseLog.append`.
struct ResponseLogBatch: Equatable, Sendable {
    /// Zero-based order inside the recording.
    var sequence: UInt64
    var body: Data
}

/// Accumulates a response body and emits it in large, ordered batches.
///
/// The gateway forwards each upstream chunk to the downstream consumer before
/// it hands the bytes here, so a slow log write cannot delay the response.
/// Bytes are copied once into the accumulator (instead of once per append call
/// into the log's file handle) and the sequence domain stays contiguous.
struct ResponseLogAccumulator: Sendable {
    /// Preferred flush size. Small enough to bound memory, large enough to
    /// remove the per-chunk write syscall.
    static let defaultFlushBytes = 64 * 1024

    private let flushBytes: Int
    private var buffer = Data()
    private var sequence: UInt64 = 0

    init(flushBytes: Int = ResponseLogAccumulator.defaultFlushBytes) {
        self.flushBytes = max(1, flushBytes)
        self.buffer.reserveCapacity(max(self.flushBytes, 1))
    }

    var bufferedBytes: Int { buffer.count }

    /// Adds one chunk and returns a batch when the flush bound is reached.
    mutating func append(_ data: Data) -> ResponseLogBatch? {
        guard !data.isEmpty else { return nil }
        buffer.append(data)
        guard buffer.count >= flushBytes else { return nil }
        return take()
    }

    /// Emits everything still buffered. Called on a successful stream end,
    /// after the last upstream chunk and before `ResponseLog.finish`.
    mutating func flush() -> ResponseLogBatch? {
        take()
    }

    private mutating func take() -> ResponseLogBatch? {
        guard !buffer.isEmpty else { return nil }
        let batch = ResponseLogBatch(sequence: sequence, body: buffer)
        sequence &+= 1
        buffer = Data()
        buffer.reserveCapacity(flushBytes)
        return batch
    }
}
