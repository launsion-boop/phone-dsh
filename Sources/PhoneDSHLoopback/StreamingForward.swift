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
    /// chunks of at most 16 KiB.
    func forward(method: String, url: URL, headers: [String: String],
                 body: Data) -> AsyncThrowingStream<HTTPEgressChunk, Error> {
        let session = self.session
        return AsyncThrowingStream { continuation in
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
                    continuation.yield(HTTPEgressChunk(status: http.statusCode,
                                                       headers: responseHeaders,
                                                       body: Data(),
                                                       isFinal: false))
                    var buffer = Data()
                    buffer.reserveCapacity(16 * 1024)
                    for try await byte in bytes {
                        buffer.append(byte)
                        if buffer.count >= 16 * 1024 {
                            continuation.yield(HTTPEgressChunk(body: buffer))
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(HTTPEgressChunk(body: buffer, isFinal: true))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
