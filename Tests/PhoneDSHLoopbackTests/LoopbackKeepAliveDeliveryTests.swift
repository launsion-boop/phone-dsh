// SPDX-License-Identifier: MIT
// Loopback /v1/http delivery regression (G2-FIX-20): several 30 KiB streamed
// responses must keep flowing over one keep-alive connection. This pins the
// host-side write leg that the 128 KiB model-delivery stall was attributed to.

import Foundation
import XCTest
import PhoneDSHWire
import PhoneDSHLoopback

/// Streams a fixed-size body in 16 KiB chunks.
final class BurstHTTPEgress: HTTPEgress, @unchecked Sendable {
    let bodyBytes: Int
    let chunkBytes: Int

    init(bodyBytes: Int = 30 * 1024, chunkBytes: Int = 16 * 1024) {
        self.bodyBytes = bodyBytes
        self.chunkBytes = chunkBytes
    }

    func handle(_ request: HTTPEgressRequest) -> AsyncThrowingStream<HTTPEgressChunk, Error> {
        let body = Data(repeating: 0x41, count: bodyBytes)
        return AsyncThrowingStream { continuation in
            continuation.yield(HTTPEgressChunk(status: 200,
                                               headers: ["Content-Type": "text/event-stream"],
                                               body: Data()))
            var offset = 0
            while offset < body.count {
                let end = min(body.count, offset + chunkBytes)
                continuation.yield(HTTPEgressChunk(body: body.subdata(in: offset..<end)))
                offset = end
            }
            continuation.yield(HTTPEgressChunk(isFinal: true))
            continuation.finish()
        }
    }
}

final class LoopbackKeepAliveDeliveryTests: XCTestCase {
    private func startServer(routes: LoopbackRoutes) async throws -> (LoopbackServer, TestHTTPClient) {
        let server = LoopbackServer(routes: routes)
        let endpoint = try await server.start()
        addTeardownBlock { await server.stop() }
        return (server, TestHTTPClient(endpoint: endpoint))
    }

    /// Reads one chunked body from a raw connection (and its terminating CRLF).
    private func readChunkedBody(_ tcp: RawTCPClient) async throws -> Data {
        var body = Data()
        while true {
            let line = try await tcp.readUntil(Data("\r\n".utf8))
            var text = String(decoding: line, as: UTF8.self)
            text = text.replacingOccurrences(of: "\r\n", with: "")
            let size = Int(text, radix: 16) ?? -1
            XCTAssertGreaterThanOrEqual(size, 0, "invalid chunk size line: \(text)")
            if size == 0 {
                _ = try await tcp.readExactly(2)
                break
            }
            let chunk = try await tcp.readExactly(size + 2)
            body.append(chunk.prefix(size))
        }
        return body
    }

    func testFiveThirtyKResponsesOnOneKeepAliveConnection() async throws {
        let (_, client) = try await startServer(routes: LoopbackRoutes(httpEgress: BurstHTTPEgress()))
        let tcp = RawTCPClient(port: UInt16(client.endpoint.baseURL.port ?? 0))
        addTeardownBlock { tcp.close() }
        try await tcp.connect()
        let token = client.endpoint.token
        for index in 0..<5 {
            var request = Data("POST /v1/http HTTP/1.1\r\n".utf8)
            request.append(Data("Host: 127.0.0.1\r\n".utf8))
            request.append(Data("Authorization: Bearer \(token)\r\n".utf8))
            request.append(Data("X-PDSH-Target-URL: http://example.test/sse\r\n".utf8))
            request.append(Data("X-PDSH-Target-Method: POST\r\n".utf8))
            request.append(Data("Content-Length: 0\r\n\r\n".utf8))
            try await tcp.send(request)
            let head = try await tcp.readUntil(Data("\r\n\r\n".utf8))
            let headText = String(decoding: head, as: UTF8.self)
            XCTAssertTrue(headText.hasPrefix("HTTP/1.1 200"), "response \(index): \(headText)")
            let body = try await readChunkedBody(tcp)
            XCTAssertEqual(body.count, 30 * 1024, "response \(index)")
        }
    }
}
