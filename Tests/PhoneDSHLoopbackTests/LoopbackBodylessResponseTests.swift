// SPDX-License-Identifier: MIT
// PhoneDSHLoopback bodyless-response regression: a compliant MCP Streamable
// HTTP notification POST answers 204 with no body. The loopback egress writer
// used to add `Transfer-Encoding: chunked` and the terminating `0` chunk to
// every status, so WKWebView saw a 204 with a body and its fetch rejected it
// with "Response cannot have a body with the given status." These tests pin
// the wire contract (no body and no chunked framing for 204/205/304) and the
// HEAD rule (headers of the GET variant, no body), plus that a keep-alive
// connection still carries the next normal response.

import Foundation
import XCTest
import PhoneDSHLoopback

/// Answers by request path so one server covers bodyless statuses and a normal
/// chunked response on the same connection.
private final class StatusHTTPEgress: HTTPEgress, @unchecked Sendable {
    func handle(_ request: HTTPEgressRequest) -> AsyncThrowingStream<HTTPEgressChunk, Error> {
        let status: Int
        switch request.url.lastPathComponent {
        case "no-content": status = 204
        case "reset-content": status = 205
        case "not-modified": status = 304
        default: status = 200
        }
        let body = status == 200 ? Data("normal-body".utf8) : Data("must not be sent".utf8)
        return AsyncThrowingStream { continuation in
            continuation.yield(HTTPEgressChunk(status: status,
                                               headers: status == 200
                                                   ? ["Content-Type": "text/plain; charset=utf-8"]
                                                   : ["mcp-session-id": "session-\(status)"],
                                               body: body,
                                               isFinal: true))
            continuation.finish()
        }
    }
}

final class LoopbackBodylessResponseTests: XCTestCase {
    private func startServer(routes: LoopbackRoutes) async throws
        -> (server: LoopbackServer, client: TestHTTPClient) {
        let server = LoopbackServer(routes: routes)
        let endpoint = try await server.start()
        addTeardownBlock {
            await server.stop()
        }
        return (server, TestHTTPClient(endpoint: endpoint))
    }

    private func egressRequest(client: TestHTTPClient, target: String,
                               method: String = "POST") -> Data {
        var request = Data("POST /v1/http HTTP/1.1\r\n".utf8)
        request.append(Data("Host: 127.0.0.1\r\n".utf8))
        request.append(Data("Authorization: Bearer \(client.endpoint.token)\r\n".utf8))
        request.append(Data("X-PDSH-Target-URL: \(target)\r\n".utf8))
        request.append(Data("X-PDSH-Target-Method: \(method)\r\n".utf8))
        request.append(Data("Content-Length: 0\r\n\r\n".utf8))
        return request
    }

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

    private func headerValue(_ name: String, in head: String) -> String? {
        let prefix = name.lowercased() + ":"
        for line in head.components(separatedBy: "\r\n") {
            let text = String(line)
            if text.lowercased().hasPrefix(prefix) {
                return String(text.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// The real MCP notification shape: a 204 with no framing and no bytes,
    /// followed by a normal chunked response on the same connection.
    func testBodylessEgressStatusesSendOnlyTheHead() async throws {
        let (_, client) = try await startServer(
            routes: LoopbackRoutes(httpEgress: StatusHTTPEgress()))
        let tcp = RawTCPClient(port: UInt16(client.endpoint.baseURL.port ?? 0))
        addTeardownBlock { tcp.close() }
        try await tcp.connect()

        for (path, status) in [("no-content", 204),
                               ("reset-content", 205),
                               ("not-modified", 304)] {
            try await tcp.send(egressRequest(
                client: client, target: "https://mcp.example.test/\(path)"))
            let head = String(decoding: try await tcp.readUntil(Data("\r\n\r\n".utf8)),
                              as: UTF8.self)
            XCTAssertTrue(head.hasPrefix("HTTP/1.1 \(status)"),
                          "\(status) response head was: \(head)")
            XCTAssertNil(headerValue("transfer-encoding", in: head),
                         "\(status) must not use chunked framing")
            XCTAssertNil(headerValue("content-length", in: head),
                         "\(status) must not advertise a body length")
            XCTAssertEqual(headerValue("mcp-session-id", in: head), "session-\(status)")
            XCTAssertEqual(headerValue("cache-control", in: head), "no-store")
        }

        // A stray terminating chunk would be read as the next response head.
        try await tcp.send(egressRequest(
            client: client, target: "https://mcp.example.test/normal"))
        let normalHead = String(decoding: try await tcp.readUntil(Data("\r\n\r\n".utf8)),
                                as: UTF8.self)
        XCTAssertTrue(normalHead.hasPrefix("HTTP/1.1 200"),
                      "the next response must start at the status line, got: \(normalHead)")
        XCTAssertEqual(headerValue("transfer-encoding", in: normalHead), "chunked")
        let normalBody = try await readChunkedBody(tcp)
        XCTAssertEqual(String(decoding: normalBody, as: UTF8.self), "normal-body")
    }

    /// A HEAD response carries the GET headers (including Content-Length) but
    /// never the file bytes, so the next keep-alive request still parses.
    func testHeadStaticResponseHasNoBody() async throws {
        let root = try makeTemporaryDirectory()
        addTeardownBlock { removeTemporaryDirectory(root) }
        let staticDirectory = root.appendingPathComponent("static")
        try FileManager.default.createDirectory(at: staticDirectory,
                                                withIntermediateDirectories: true)
        let page = Data("<!doctype html><title>head-bodyless</title>\n".utf8)
        try page.write(to: staticDirectory.appendingPathComponent("index.html"))
        let (_, client) = try await startServer(routes: LoopbackRoutes(
            staticDirectory: staticDirectory))
        let tcp = RawTCPClient(port: UInt16(client.endpoint.baseURL.port ?? 0))
        addTeardownBlock { tcp.close() }
        try await tcp.connect()

        let headRequest = Data("HEAD / HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(client.endpoint.token)\r\n\r\n".utf8)
        try await tcp.send(headRequest)
        let head = String(decoding: try await tcp.readUntil(Data("\r\n\r\n".utf8)),
                          as: UTF8.self)
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200"), "HEAD response head was: \(head)")
        XCTAssertNil(headerValue("transfer-encoding", in: head))
        XCTAssertEqual(headerValue("content-length", in: head), String(page.count))

        let getRequest = Data("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(client.endpoint.token)\r\n\r\n".utf8)
        try await tcp.send(getRequest)
        let getHead = String(decoding: try await tcp.readUntil(Data("\r\n\r\n".utf8)),
                             as: UTF8.self)
        XCTAssertTrue(getHead.hasPrefix("HTTP/1.1 200"),
                      "HEAD must not leave body bytes before the next response, got: \(getHead)")
        let getBody = try await tcp.readExactly(page.count)
        XCTAssertEqual(getBody, page)
    }
}
