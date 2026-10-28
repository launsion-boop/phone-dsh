// SPDX-License-Identifier: MIT
// Test-only HTTP/1.1 upstream for the model gateway tests.
//
// Network.framework `NWListener` on 127.0.0.1 only. It speaks just enough
// HTTP/1.1 for the gateway: one `Content-Length` request per connection,
// `Connection: close` responses, full bodies, chunked bodies with delays (SSE
// pass-through) and abrupt resets. It is deliberately small: no TLS, no
// keep-alive and no HTTP/2.

import Foundation
import Network

struct MockHTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

enum MockHTTPResponse: Sendable {
    case full(status: Int, headers: [String: String], body: Data)
    /// `Transfer-Encoding: chunked`; `delay` is applied between chunks.
    case chunked(status: Int, headers: [String: String], chunks: [Data], delay: TimeInterval)
    /// Sends `partial` (possibly empty) then resets the connection.
    case abort(partial: Data)
}

final class MockUpstreamServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "phone-dsh.mock-upstream")
    private let listener: NWListener
    private let handler: @Sendable (MockHTTPRequest) -> MockHTTPResponse
    private let stateLock = NSLock()
    private var storedRequests: [MockHTTPRequest] = []

    private(set) var port: UInt16 = 0

    init(handler: @escaping @Sendable (MockHTTPRequest) -> MockHTTPResponse) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1",
                                                              port: .any)
        self.listener = try NWListener(using: parameters)
    }

    var requests: [MockHTTPRequest] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedRequests
    }

    var requestCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedRequests.count
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let once = MockOnceFlag()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let port = self.listener.port?.rawValue ?? 0
                    self.port = port
                    if once.claim() {
                        continuation.resume(returning: port)
                    }
                case .failed(let error):
                    if once.claim() {
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    if once.claim() {
                        continuation.resume(throwing: MockServerError.cancelled)
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHead(on: connection, buffer: Data())
    }

    private func receiveHead(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.parse(connection: connection, buffer: buffer, headerEnd: headerEnd)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receiveHead(on: connection, buffer: buffer)
            }
        }
    }

    private func parse(connection: NWConnection, buffer: Data, headerEnd: Range<Data.Index>) {
        let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let text = String(data: headerData, encoding: .utf8) else {
            connection.cancel()
            return
        }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            connection.cancel()
            return
        }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else {
            connection.cancel()
            return
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            headers[name] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let body = Data(buffer[headerEnd.upperBound...])
        if body.count >= contentLength {
            deliver(connection: connection,
                    request: MockHTTPRequest(method: String(requestLine[0]),
                                             path: String(requestLine[1]),
                                             headers: headers,
                                             body: Data(body.prefix(contentLength))))
        } else {
            receiveBody(on: connection,
                        method: String(requestLine[0]),
                        path: String(requestLine[1]),
                        headers: headers,
                        body: body,
                        contentLength: contentLength)
        }
    }

    private func receiveBody(on connection: NWConnection,
                             method: String,
                             path: String,
                             headers: [String: String],
                             body: Data,
                             contentLength: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var body = body
            if let data {
                body.append(data)
            }
            if body.count >= contentLength || isComplete || error != nil {
                self.deliver(connection: connection,
                             request: MockHTTPRequest(method: method,
                                                      path: path,
                                                      headers: headers,
                                                      body: body))
            } else {
                self.receiveBody(on: connection,
                                 method: method,
                                 path: path,
                                 headers: headers,
                                 body: body,
                                 contentLength: contentLength)
            }
        }
    }

    private func deliver(connection: NWConnection, request: MockHTTPRequest) {
        stateLock.lock()
        storedRequests.append(request)
        stateLock.unlock()
        respond(connection: connection, response: handler(request))
    }

    private func respond(connection: NWConnection, response: MockHTTPResponse) {
        switch response {
        case .full(let status, var headers, let body):
            headers["connection"] = "close"
            headers["content-length"] = String(body.count)
            let head = Self.head(status: status, headers: headers)
            connection.send(content: head + body, completion: .contentProcessed { _ in
                connection.cancel()
            })
        case .chunked(let status, var headers, let chunks, let delay):
            headers["connection"] = "close"
            headers["transfer-encoding"] = "chunked"
            let head = Self.head(status: status, headers: headers)
            connection.send(content: head, completion: .contentProcessed { [weak self] error in
                guard error == nil, let self else {
                    connection.cancel()
                    return
                }
                self.sendChunk(on: connection, chunks: chunks, delay: delay, index: 0)
            })
        case .abort(let partial):
            guard !partial.isEmpty else {
                connection.forceCancel()
                return
            }
            connection.send(content: partial, completion: .contentProcessed { [weak self] _ in
                // Give the partial bytes a moment to reach the client, then
                // close gracefully so the truncated body is observable.
                self?.queue.asyncAfter(deadline: .now() + 0.1) {
                    connection.cancel()
                }
            })
        }
    }

    private func sendChunk(on connection: NWConnection,
                           chunks: [Data],
                           delay: TimeInterval,
                           index: Int) {
        guard index < chunks.count else {
            connection.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }
        var frame = Data("\(String(chunks[index].count, radix: 16))\r\n".utf8)
        frame.append(chunks[index])
        frame.append(Data("\r\n".utf8))
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else {
                connection.cancel()
                return
            }
            let next = index + 1
            if delay > 0 {
                self.queue.asyncAfter(deadline: .now() + delay) {
                    self.sendChunk(on: connection, chunks: chunks, delay: delay, index: next)
                }
            } else {
                self.sendChunk(on: connection, chunks: chunks, delay: delay, index: next)
            }
        })
    }

    private static func head(status: Int, headers: [String: String]) -> Data {
        var text = "HTTP/1.1 \(status) \(reason(status))\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8)
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

enum MockServerError: Error {
    case cancelled
}

final class MockOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
