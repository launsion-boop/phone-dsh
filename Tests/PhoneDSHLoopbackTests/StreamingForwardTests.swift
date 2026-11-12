// SPDX-License-Identifier: MIT
// W7 (§13): forwarded bytes reach the client as they arrive. A complete line
// is never held until 16 KiB accumulates or the upstream ends.

import Foundation
import Network
import XCTest
@testable import PhoneDSHLoopback

final class StreamingForwardTests: XCTestCase {
    /// A minimal chunked upstream that sends each line with a configurable gap.
    private final class StreamingLineUpstream: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "phone-dsh.tests.streaming-upstream")
        private let lines: [Data]
        private let gap: TimeInterval
        private(set) var port: UInt16 = 0

        private init(listener: NWListener, lines: [Data], gap: TimeInterval) {
            self.listener = listener
            self.lines = lines
            self.gap = gap
        }

        static func start(lines: [Data], gap: TimeInterval) async throws -> StreamingLineUpstream {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: .any)
            let upstream = StreamingLineUpstream(listener: listener, lines: lines, gap: gap)
            listener.newConnectionHandler = { [weak upstream] connection in
                upstream?.accept(connection)
            }
            upstream.port = try await upstream.listen()
            return upstream
        }

        var url: URL { URL(string: "http://127.0.0.1:\(port)/stream")! }

        func stop() { listener.cancel() }

        private func listen() async throws -> UInt16 {
            try await withCheckedThrowingContinuation { continuation in
                let lock = NSLock()
                var resumed = false
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        lock.lock()
                        let claim = !resumed
                        resumed = true
                        lock.unlock()
                        if claim {
                            self.listener.stateUpdateHandler = nil
                            continuation.resume(returning: self.listener.port?.rawValue ?? 0)
                        }
                    case .failed(let error):
                        lock.lock()
                        let claim = !resumed
                        resumed = true
                        lock.unlock()
                        if claim { continuation.resume(throwing: error) }
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
            }
        }

        private func accept(_ connection: NWConnection) {
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, _ in
                var head = Data("HTTP/1.1 200 OK\r\n".utf8)
                head.append(Data("Content-Type: text/event-stream\r\n".utf8))
                head.append(Data("Transfer-Encoding: chunked\r\n".utf8))
                head.append(Data("Connection: close\r\n\r\n".utf8))
                connection.send(content: head, completion: .contentProcessed { _ in
                    self.send(0, on: connection)
                })
            }
        }

        private func send(_ index: Int, on connection: NWConnection) {
            guard index < lines.count else {
                connection.send(content: Data("0\r\n\r\n".utf8),
                                completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            let body = lines[index]
            var frame = Data("\(String(body.count, radix: 16))\r\n".utf8)
            frame.append(body)
            frame.append(Data("\r\n".utf8))
            connection.send(content: frame, completion: .contentProcessed { _ in
                if self.gap > 0 {
                    self.queue.asyncAfter(deadline: .now() + self.gap) {
                        self.send(index + 1, on: connection)
                    }
                } else {
                    self.send(index + 1, on: connection)
                }
            })
        }
    }

    func testFirstEventIsForwardedBeforeTheRestArrives() async throws {
        let first = Data("data: one\n\n".utf8)
        let second = Data("data: two\n\n".utf8)
        let upstream = try await StreamingLineUpstream.start(lines: [first, second], gap: 0.4)
        addTeardownBlock { upstream.stop() }

        let stream = URLSessionForwarder().forward(method: "GET", url: upstream.url,
                                                   headers: [:], body: Data())
        var iterator = stream.makeAsyncIterator()
        let head = try await iterator.next()
        XCTAssertEqual(head?.status, 200)
        let headAt = Date()
        let firstChunk = try await iterator.next()
        let elapsed = Date().timeIntervalSince(headAt)
        XCTAssertEqual(firstChunk?.body, first,
                       "the first SSE line must be forwarded whole and in order")
        XCTAssertLessThan(elapsed, 0.25,
                          "the first event was held for the next upstream gap instead of being forwarded on arrival")
        let secondChunk = try await iterator.next()
        XCTAssertEqual(secondChunk?.body, second)
    }

    func testAnUnterminatedFrameFlushesAtTheCoalescingBound() async throws {
        let body = Data(repeating: 0x61, count: 10_000)
        let upstream = try await StreamingLineUpstream.start(lines: [body], gap: 0)
        addTeardownBlock { upstream.stop() }

        let stream = URLSessionForwarder().forward(method: "GET", url: upstream.url,
                                                   headers: [:], body: Data())
        var received = Data()
        var largest = 0
        for try await chunk in stream where !chunk.body.isEmpty {
            largest = max(largest, chunk.body.count)
            received.append(chunk.body)
        }
        XCTAssertEqual(received, body)
        XCTAssertLessThanOrEqual(largest, URLSessionForwarder.coalesceMaxBytes,
                                 "a frame without a terminator must flush at the 4 KiB bound")
    }
}
