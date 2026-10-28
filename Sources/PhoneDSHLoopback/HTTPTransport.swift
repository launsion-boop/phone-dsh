// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLoopback: HTTP/1.1 over TCP.
//
// Network.framework listener bound to 127.0.0.1, a serialized connection
// wrapper, an incremental HTTP/1.1 request parser (Content-Length and chunked
// bodies, keep-alive, 64 MiB cap) and the response writer (fixed length,
// streamed chunked bodies and RFC 6455 upgrades). An egress stream that fails
// before its first chunk is answered with the structured
// ``HTTPEgressFailure`` envelope (distinct status/code/details and
// `X-PDSH-Proxy-Error`, plus one run-log line), never a generic 502
// (G2-FIX-32). TLS terminates elsewhere: the origin is loopback-only and
// authenticated by the per-start token.

import Foundation
import Network

// MARK: - Listener

/// Accepts TCP connections on 127.0.0.1 only. The listener itself performs no
/// request work; ``LoopbackServer`` owns every byte after `accept`.
final class LoopbackListener: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "phone-dsh.phone.loopback.listener")
    private let onConnection: @Sendable (NWConnection) -> Void
    private var listener: NWListener?
    private var startup: CheckedContinuation<UInt16, Error>?

    init(onConnection: @escaping @Sendable (NWConnection) -> Void) {
        self.onConnection = onConnection
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func start(host: String, port: UInt16) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: parameters)
        let alreadyRunning: Bool = withLock {
            if self.listener != nil { return true }
            self.listener = listener
            return false
        }
        if alreadyRunning { throw LoopbackError.alreadyRunning }
        let onConnection = self.onConnection
        return try await withCheckedThrowingContinuation { continuation in
            withLock { startup = continuation }
            listener.stateUpdateHandler = { [weak self] state in
                self?.stateChanged(state, listener: listener)
            }
            listener.newConnectionHandler = { connection in onConnection(connection) }
            listener.start(queue: queue)
        }
    }

    func stop() {
        let (listener, pending): (NWListener?, CheckedContinuation<UInt16, Error>?) = withLock {
            let listener = self.listener
            self.listener = nil
            let pending = startup
            startup = nil
            return (listener, pending)
        }
        listener?.cancel()
        pending?.resume(throwing: LoopbackError.notRunning)
    }

    private func stateChanged(_ state: NWListener.State, listener: NWListener) {
        switch state {
        case .ready:
            finishStart(.success(listener.port?.rawValue ?? 0))
        case .failed(let error):
            finishStart(.failure(LoopbackError.invalidEndpoint("\(error)")))
        case .cancelled:
            finishStart(.failure(LoopbackError.notRunning))
        default:
            break
        }
    }

    private func finishStart(_ result: Result<UInt16, Error>) {
        let continuation: CheckedContinuation<UInt16, Error>? = withLock {
            let continuation = startup
            startup = nil
            return continuation
        }
        guard let continuation else { return }
        switch result {
        case .success(let port): continuation.resume(returning: port)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}

// MARK: - Connection

enum HTTPTransportError: Error, Equatable {
    case connectionFailed(String)
    case ioError(String)
    case malformed(String)
    case headerTooLarge
    case bodyTooLarge
    case unsupportedTransferEncoding
    case eof

    var status: Int {
        switch self {
        case .headerTooLarge: return 431
        case .bodyTooLarge: return 413
        case .unsupportedTransferEncoding: return 501
        default: return 400
        }
    }

    var publicMessage: String {
        switch self {
        case .connectionFailed: return "the connection failed"
        case .ioError: return "the connection was lost"
        case .malformed(let detail): return detail
        case .headerTooLarge: return "request headers are too large"
        case .bodyTooLarge: return "request body is too large"
        case .unsupportedTransferEncoding: return "unsupported transfer encoding"
        case .eof: return "unexpected end of connection"
        }
    }
}

/// A TCP connection wrapped for `async` use. One reader task and any number of
/// senders may use it; Network.framework keeps sends ordered.
actor ConnectionChannel {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "phone-dsh.phone.loopback.connection")
    private var isReady = false
    private var isClosed = false
    private var startWaiters: [CheckedContinuation<Void, Error>] = []

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() async throws {
        if isReady { return }
        if isClosed { throw HTTPTransportError.eof }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startWaiters.append(continuation)
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { await self.stateChanged(state) }
            }
            connection.start(queue: queue)
        }
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isReady = true
            resumeStartWaiters(with: nil)
        case .failed(let error):
            isClosed = true
            resumeStartWaiters(with: HTTPTransportError.connectionFailed("\(error)"))
        case .cancelled:
            isClosed = true
            resumeStartWaiters(with: HTTPTransportError.eof)
        default:
            break
        }
    }

    private func resumeStartWaiters(with error: Error?) {
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume()
            }
        }
    }

    /// Reads bytes; `nil` means the peer closed the connection.
    func receive(maximumLength: Int = 64 * 1024) async throws -> Data? {
        if isClosed { return nil }
        let connection = self.connection
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1,
                               maximumLength: maximumLength) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: HTTPTransportError.ioError("\(error)"))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    func send(_ data: Data) async throws {
        guard !isClosed else { throw HTTPTransportError.eof }
        let connection = self.connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: HTTPTransportError.ioError("\(error)"))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func cancel() {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
    }
}

// MARK: - Request parsing

/// One parsed HTTP/1.1 request.
struct HTTPRequest: Sendable {
    var method: String
    var target: String
    var version: String
    /// Header names lowercased; repeated headers joined with `, `.
    var headers: [String: String]
    var body: Data
    var keepAlive: Bool
    var path: String
    var query: [String: String]

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// Incremental HTTP/1.1 request reader. A single instance keeps the bytes of
/// the next pipelined request between calls.
struct HTTPRequestReader {
    static let maxHeaderBytes = 64 * 1024
    private static let headerSeparator = Data([13, 10, 13, 10])
    private static let crlf = Data([13, 10])

    let channel: ConnectionChannel
    let maxBodyBytes: Int
    private var buffer = Data()
    private var reachedEOF = false

    init(channel: ConnectionChannel, maxBodyBytes: Int) {
        self.channel = channel
        self.maxBodyBytes = maxBodyBytes
    }

    /// Bytes already read past the last request (handed to a WebSocket).
    var bufferedBytes: Data {
        get { buffer }
        set { buffer = newValue }
    }

    /// Returns the next request, or `nil` when the peer closed cleanly between
    /// requests.
    mutating func nextRequest() async throws -> HTTPRequest? {
        guard try await ensureHeaderEnd() != nil else { return nil }
        guard let separator = buffer.range(of: Self.headerSeparator) else {
            throw HTTPTransportError.malformed("malformed request headers")
        }
        guard let headText = String(data: Data(buffer[buffer.startIndex..<separator.lowerBound]),
                                    encoding: .utf8) else {
            throw HTTPTransportError.malformed("request headers are not UTF-8")
        }
        buffer.removeSubrange(buffer.startIndex..<separator.upperBound)

        var lines = headText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            throw HTTPTransportError.malformed("empty request")
        }
        let requestLine = lines.removeFirst().split(separator: " ", maxSplits: 2,
                                                    omittingEmptySubsequences: false)
        guard requestLine.count == 3 else {
            throw HTTPTransportError.malformed("malformed request line")
        }
        let method = String(requestLine[0]).uppercased()
        let target = String(requestLine[1])
        let version = String(requestLine[2])
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else {
            throw HTTPTransportError.malformed("unsupported HTTP version")
        }
        guard let parsedTarget = HTTPURL.parse(target) else {
            throw HTTPTransportError.malformed("invalid request target")
        }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw HTTPTransportError.malformed("malformed header line")
            }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ Self.isHeaderToken($0) }) else {
                throw HTTPTransportError.malformed("invalid header name")
            }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        let body = try await readBody(headers: headers)
        let connectionHeader = headers["connection"]?.lowercased()
        let keepAlive: Bool
        if version == "HTTP/1.1" {
            keepAlive = connectionHeader != "close"
        } else {
            keepAlive = connectionHeader == "keep-alive"
        }
        return HTTPRequest(method: method, target: target, version: version,
                           headers: headers, body: body, keepAlive: keepAlive,
                           path: parsedTarget.path, query: parsedTarget.query)
    }

    private static func isHeaderToken(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x21, 0x23...0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x30...0x39,
             0x41...0x5A, 0x5E...0x7A, 0x7C, 0x7E:
            return true
        default:
            return false
        }
    }

    private mutating func ensureHeaderEnd() async throws -> Range<Data.Index>? {
        while true {
            if let range = buffer.range(of: Self.headerSeparator) { return range }
            if buffer.count > Self.maxHeaderBytes { throw HTTPTransportError.headerTooLarge }
            guard try await readMore() else {
                if buffer.isEmpty { return nil }
                throw HTTPTransportError.eof
            }
        }
    }

    private mutating func readBody(headers: [String: String]) async throws -> Data {
        let transferEncoding = headers["transfer-encoding"]?.lowercased()
        let contentLengthValue = headers["content-length"]
        if transferEncoding != nil && contentLengthValue != nil {
            throw HTTPTransportError.malformed("both Content-Length and Transfer-Encoding")
        }
        if let transferEncoding {
            let codings = transferEncoding.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard codings.last == "chunked" else {
                throw HTTPTransportError.unsupportedTransferEncoding
            }
            return try await readChunkedBody()
        }
        guard let contentLengthValue else { return Data() }
        guard let length = Int(contentLengthValue), length >= 0 else {
            throw HTTPTransportError.malformed("invalid Content-Length")
        }
        guard length <= maxBodyBytes else { throw HTTPTransportError.bodyTooLarge }
        while buffer.count < length {
            guard try await readMore() else {
                throw HTTPTransportError.malformed("truncated request body")
            }
        }
        let body = Data(buffer.prefix(length))
        buffer.removeFirst(length)
        return body
    }

    private mutating func readChunkedBody() async throws -> Data {
        var body = Data()
        while true {
            guard let line = try await readLine() else {
                throw HTTPTransportError.malformed("truncated chunked body")
            }
            let sizeText = line.split(separator: ";", maxSplits: 1,
                                      omittingEmptySubsequences: false).first ?? ""
            let trimmed = sizeText.trimmingCharacters(in: .whitespaces)
            guard let size = Int(trimmed, radix: 16), size >= 0 else {
                throw HTTPTransportError.malformed("invalid chunk size")
            }
            if size == 0 {
                // Consume the trailer section up to the empty line.
                while true {
                    guard let trailer = try await readLine() else { return body }
                    if trailer.isEmpty { return body }
                }
            }
            guard body.count + size <= maxBodyBytes else { throw HTTPTransportError.bodyTooLarge }
            while buffer.count < size + 2 {
                guard try await readMore() else {
                    throw HTTPTransportError.malformed("truncated chunk")
                }
            }
            body.append(contentsOf: buffer.prefix(size))
            let terminatorStart = buffer.index(buffer.startIndex, offsetBy: size)
            let terminator = buffer[terminatorStart..<(terminatorStart + 2)]
            guard terminator == Self.crlf else {
                throw HTTPTransportError.malformed("chunk is not CRLF terminated")
            }
            buffer.removeFirst(size + 2)
        }
    }

    /// Reads one line, consumes it and its CRLF from the buffer and returns the
    /// line text without the separator.
    private mutating func readLine() async throws -> String? {
        while true {
            if let crlf = buffer.range(of: Self.crlf) {
                let lineData = Data(buffer[buffer.startIndex..<crlf.lowerBound])
                buffer.removeSubrange(buffer.startIndex..<crlf.upperBound)
                return String(decoding: lineData, as: UTF8.self)
            }
            guard try await readMore() else { return nil }
            if buffer.count > Self.maxHeaderBytes { throw HTTPTransportError.headerTooLarge }
        }
    }

    private mutating func readMore() async throws -> Bool {
        if reachedEOF { return false }
        let chunk = try await channel.receive()
        guard let chunk else {
            reachedEOF = true
            return false
        }
        if chunk.isEmpty { return true }
        buffer.append(chunk)
        return true
    }
}

// MARK: - Response writing

/// What the router returns for one request.
enum LoopbackReply: Sendable {
    case full(status: Int, headers: [String: String], body: Data)
    case file(url: URL, contentType: String, headers: [String: String])
    /// Streamed upstream response. `target` is the upstream URL for the
    /// run-log diagnostic of an egress failure (never sent to the client).
    case egress(AsyncThrowingStream<HTTPEgressChunk, Error>, target: String?)
    /// RFC 6455 upgrade headers (including `Sec-WebSocket-Accept`).
    case upgrade(headers: [String: String])

    static func json(_ status: Int, code: String, message: String) -> LoopbackReply {
        .full(status: status,
              headers: ["Content-Type": "application/json; charset=utf-8"],
              body: LoopbackJSON.error(code: code, message: message))
    }

    static func json(_ status: Int, value: CanonicalJSONValue) -> LoopbackReply {
        .full(status: status,
              headers: ["Content-Type": "application/json; charset=utf-8"],
              body: value.encoded())
    }
}

/// Writes one response. Every response carries `Cache-Control: no-store`; the
/// caller owns the connection lifetime.
struct HTTPResponseWriter {
    let channel: ConnectionChannel

    /// HTTP statuses whose response never has a message body (RFC 9110 §6.4.1
    /// plus the informational range). A WebKit fetch rejects a `204`, `205` or
    /// `304` that arrives with chunked framing or body bytes with "Response
    /// cannot have a body with the given status."; the loopback must therefore
    /// emit only the head for these statuses, exactly like the desktop
    /// `node:http` transport does.
    static func isBodyless(_ status: Int) -> Bool {
        status < 200 || status == 204 || status == 205 || status == 304
    }

    /// - Parameter headRequest: the request method was HEAD, so the response
    ///   carries the headers of the GET variant but no body.
    func write(_ reply: LoopbackReply, keepAlive: Bool,
               headRequest: Bool = false) async throws {
        switch reply {
        case .full(let status, var headers, let body):
            headers = sanitized(headers)
            headers["Cache-Control"] = "no-store"
            headers["Content-Length"] = String(body.count)
            headers["Connection"] = keepAlive ? "keep-alive" : "close"
            try await channel.send(head(status: status, headers: headers))
            if !headRequest && !body.isEmpty { try await channel.send(body) }

        case .file(let url, let contentType, var headers):
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            headers = sanitized(headers)
            headers["Content-Type"] = contentType
            headers["Content-Length"] = String(size)
            headers["Cache-Control"] = "no-store"
            headers["Connection"] = keepAlive ? "keep-alive" : "close"
            try await channel.send(head(status: 200, headers: headers))
            guard !headRequest else { return }
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                throw HTTPTransportError.ioError("cannot read the requested file")
            }
            defer { try? handle.close() }
            while true {
                let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
                if chunk.isEmpty { break }
                try await channel.send(chunk)
            }

        case .egress(let stream, let target):
            var iterator = stream.makeAsyncIterator()
            let first: HTTPEgressChunk?
            do {
                first = try await iterator.next()
            } catch {
                try await writeEgressFailure(HTTPEgressFailure(error: error, target: target),
                                            target: target, keepAlive: keepAlive)
                return
            }
            guard let first, let status = first.status else {
                try await writeEgressFailure(.noResponse, target: target, keepAlive: keepAlive)
                return
            }
            let bodyless = Self.isBodyless(status) || headRequest
            var headers = sanitized(first.headers)
            // Egress responses are served from the authenticated loopback
            // origin. A browser processes their cookie/connection-control
            // headers against that origin, so an upstream `Set-Cookie`,
            // `Set-Cookie2`, `Clear-Site-Data` or `Alt-Svc` could overwrite
            // the launch cookie, clear site data or register an alternative
            // service for the control routes. The Python shim filters headers
            // only after WebKit has applied them; this writer is the boundary
            // that prevents the side effect.
            headers = headers.filter {
                !Self.droppedEgressResponseHeaders.contains($0.key.lowercased())
            }
            // Redirect policy belongs to the upstream egress implementation.
            // Never reinterpret its Location at this authenticated origin:
            // browser clients could follow it into /v1/exec or other control
            // routes, carrying the launch cookie/bearer and a 307/308 body.
            if (300..<400).contains(status) {
                headers = headers.filter { $0.key.lowercased() != "location" }
            }
            headers["Cache-Control"] = "no-store"
            if !bodyless { headers["Transfer-Encoding"] = "chunked" }
            headers["Connection"] = keepAlive ? "keep-alive" : "close"
            try await channel.send(head(status: status, headers: headers))
            // A 204/205/304 cannot carry a body, and a HEAD response must not
            // either. Returning here also keeps the terminating `0` chunk off a
            // null-body status, which is what WebKit rejects.
            guard !bodyless else { return }
            if !first.body.isEmpty { try await sendChunk(first.body) }
            if !first.isFinal {
                do {
                    while let chunk = try await iterator.next() {
                        if !chunk.body.isEmpty { try await sendChunk(chunk.body) }
                        if chunk.isFinal { break }
                    }
                } catch {
                    // The status line and headers are already on the wire, so a
                    // second response would corrupt the stream. Dropping the
                    // connection before the terminating chunk is the only
                    // honest signal left; record the cause for the run log so
                    // the truncation is attributable.
                    LoopbackEgressDiagnostics.record(HTTPEgressFailure(error: error,
                                                                       target: target),
                                                     target: target)
                    throw error
                }
            }
            try await channel.send(Data("0\r\n\r\n".utf8))

        case .upgrade(var headers):
            headers = sanitized(headers)
            headers["Cache-Control"] = "no-store"
            headers["Connection"] = "Upgrade"
            headers["Upgrade"] = "websocket"
            try await channel.send(head(status: 101, headers: headers))
        }
    }

    private func sendChunk(_ data: Data) async throws {
        var frame = Data("\(String(data.count, radix: 16))\r\n".utf8)
        frame.append(data)
        frame.append(Data("\r\n".utf8))
        try await channel.send(frame)
    }

    /// Answers a pre-head egress failure with the structured proxy error and
    /// records the same cause in the run log (G2-FIX-32).
    ///
    /// This is the single `EgressFailure → HTTP` mapping point (ENG-04): the
    /// attributed host, the seven-class taxonomy, the status and the
    /// `xl_error` body all come from ``HTTPEgressFailure``.
    private func writeEgressFailure(_ failure: HTTPEgressFailure,
                                    target: String?,
                                    keepAlive: Bool) async throws {
        let mapped = failure.attachingHost(HTTPEgressFailure.host(fromTarget: target))
        LoopbackEgressDiagnostics.record(mapped, target: target)
        var headers: [String: String] = [
            "Content-Type": "application/json; charset=utf-8",
        ]
        // spec/exec-bridge-v1 §6: a proxy-side failure also carries the code
        // in this header so clients that only inspect headers can classify it.
        headers["X-PDSH-Proxy-Error"] = mapped.code
        try await write(.full(status: mapped.status,
                              headers: headers,
                              body: mapped.encodedBody()),
                        keepAlive: keepAlive)
    }

    private func head(status: Int, headers: [String: String]) -> Data {
        var text = "HTTP/1.1 \(status) \(HTTPStatus.reason(status))\r\n"
        for (name, value) in headers.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            let safeName = name
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")
            let safeValue = value
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")
            text += "\(safeName): \(safeValue)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8)
    }

    private func sanitized(_ headers: [String: String]) -> [String: String] {
        let hopByHop: Set<String> = [
            "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
            "te", "trailer", "transfer-encoding", "upgrade", "content-length",
        ]
        var result: [String: String] = [:]
        for (name, value) in headers where !hopByHop.contains(name.lowercased()) {
            result[name] = value
        }
        return result
    }

    /// Upstream headers that would act on the loopback origin in a browser.
    /// Applied to `.egress` only: `.full`/`.file` responses are the loopback
    /// page itself and may legitimately seed its launch cookie.
    private static let droppedEgressResponseHeaders: Set<String> = [
        "set-cookie", "set-cookie2", "clear-site-data", "alt-svc", "alt-used",
    ]
}
