// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLoopback: streaming HTTP forwarding.
//
// `/v1/http` is served by the injected ``HTTPEgress`` (the model gateway in the
// full plan). The exec-bridge v1 routes and `/mcp*` are forwarded over a
// URLSession to their loopback owners without buffering the response: the
// first upstream chunk reaches the WebSocket/HTTP client immediately.
// Credentials of the loopback origin never leave it: the bearer token is
// stripped and the upstream owner's own token is injected.

import Foundation

/// Streams one HTTP response through ``HTTPEgressChunk``.
struct URLSessionForwarder: Sendable {
    private static let hopByHop: Set<String> = [
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "te", "trailer", "transfer-encoding", "upgrade",
    ]
    private static let loopbackAmbientHeaders: Set<String> = ["cookie", "cookie2", "referer", "referrer"]

    let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 120
        self.session = URLSession(configuration: configuration)
    }

    /// Forwarded request headers: hop-by-hop and loopback-origin headers are dropped.
    static func forwardedHeaders(_ headers: [String: String], drop: Set<String>) -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in headers {
            let lower = name.lowercased()
            if hopByHop.contains(lower) || loopbackAmbientHeaders.contains(lower) || drop.contains(lower) {
                continue
            }
            result[name] = value
        }
        return result
    }

    /// Starts the upstream request and yields status/headers followed by body
    /// chunks.
    ///
    /// W7 (§13): forwarded bytes are never accumulated to a 16 KiB batch. A
    /// complete NDJSON line or SSE line (`\n`) is written downstream as soon
    /// as it arrives, and a frame with no terminator flushes at most at the
    /// 4 KiB coalescing bound. Bytes are only coalesced inside one line/event
    /// frame, so an SSE event boundary is never crossed by a merge.
    func forward(method: String, url: URL, headers: [String: String],
                 body: Data) -> AsyncThrowingStream<HTTPEgressChunk, Error> {
        let session = self.session
        // A bounded downstream queue makes a stalled consumer apply
        // backpressure instead of growing the forwarding buffer without limit.
        // When the bound is hit the drop is loud (the stream fails), never a
        // silent gap in the response.
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: url)
                    request.httpMethod = method
                    if !body.isEmpty { request.httpBody = body }
                    for (name, value) in headers {
                        request.setValue(value, forHTTPHeaderField: name)
                    }
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw LoopbackError.upstreamFailed("the upstream answered without HTTP")
                    }
                    var responseHeaders: [String: String] = [:]
                    for (rawName, rawValue) in http.allHeaderFields {
                        let name = String(describing: rawName)
                        if Self.hopByHop.contains(name.lowercased()) { continue }
                        responseHeaders[name] = String(describing: rawValue)
                    }
                    try Self.emit(HTTPEgressChunk(status: http.statusCode,
                                                  headers: responseHeaders,
                                                  body: Data(),
                                                  isFinal: false),
                                  to: continuation)
                    var buffer = Data()
                    buffer.reserveCapacity(Self.coalesceMaxBytes)
                    for try await byte in bytes {
                        buffer.append(byte)
                        if byte == 0x0A || buffer.count >= Self.coalesceMaxBytes {
                            try Self.emit(HTTPEgressChunk(body: buffer), to: continuation)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty {
                        try Self.emit(HTTPEgressChunk(body: buffer, isFinal: true),
                                      to: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Maximum bytes coalesced without a line terminator (§13 fixes 4 KiB as
    /// the size half of the bound). A complete line is always written
    /// immediately, so no timer is needed to protect the first event; only a
    /// partial, unterminated frame waits for more bytes or the 4 KiB bound.
    static let coalesceMaxBytes = 4 * 1024

    private static func emit(_ chunk: HTTPEgressChunk,
                             to continuation: AsyncThrowingStream<HTTPEgressChunk, Error>.Continuation) throws {
        switch continuation.yield(chunk) {
        case .dropped(_):
            throw LoopbackError.upstreamFailed(
                "the downstream stopped consuming the forwarded response")
        default:
            return
        }
    }
}
