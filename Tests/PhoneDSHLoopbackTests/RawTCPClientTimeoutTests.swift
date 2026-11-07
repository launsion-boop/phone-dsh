// SPDX-License-Identifier: MIT
import Foundation
import XCTest

final class RawTCPClientTimeoutTests: XCTestCase {
    func testConnectedClientRemainsUsableAfterConnectDeadline() async throws {
        let server = try await TinyHTTPServer.start(responseBody: Data("alive".utf8))
        addTeardownBlock { server.stop() }
        let client = RawTCPClient(port: server.port)
        addTeardownBlock { client.close() }

        try await client.connect(timeout: 1)
        // Cross the original connection deadline before exercising the socket.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try await client.send(Data("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8))
        let head = try await client.readUntil(Data("\r\n\r\n".utf8))
        XCTAssertTrue(String(decoding: head, as: UTF8.self).hasPrefix("HTTP/1.1 200"))
        let body = try await client.readExactly(5)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "alive")
    }
}
