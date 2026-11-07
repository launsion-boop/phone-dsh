// SPDX-License-Identifier: MIT

import Foundation
import Network

public enum BotMCPHTTPError: Error, Sendable, Equatable {
    case startFailed(String)
    case alreadyStarted
}

public final class BotMCPHTTPServer: @unchecked Sendable {
    public static let maximumBodyBytes = 1_048_576

    public let token: String
    public let handler: BotMCPHandler

    private let queue = DispatchQueue(label: "phone-dsh.bot.mcp.http")
    private let lock = NSLock()
    private var listener: NWListener?
    private var endpoint: URL?

    public init(handler: BotMCPHandler, token: String? = nil) {
        self.handler = handler
        self.token = token ?? Self.randomToken()
    }

    public var url: URL? {
        lock.withLock { endpoint }
    }

    public func start() async throws -> URL {
        guard lock.withLock({ self.listener == nil }) else { throw BotMCPHTTPError.alreadyStarted }
        // The Bot MCP surface is only ever reached through the host's
        // /v1/http egress, never from the LAN. Bind the IPv4 loopback
        // explicitly instead of `.any`.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            let finish: (Result<URL, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue, port != 0 else {
                        finish(.failure(BotMCPHTTPError.startFailed("listener bound no port")))
                        return
                    }
                    let url = URL(string: "http://127.0.0.1:\(port)/mcp")!
                    self.lock.withLock {
                        self.listener = listener
                        self.endpoint = url
                    }
                    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                    finish(.success(url))
                case .failed(let error):
                    finish(.failure(BotMCPHTTPError.startFailed(error.localizedDescription)))
                case .cancelled:
                    finish(.failure(BotMCPHTTPError.startFailed("listener cancelled")))
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        let current = lock.withLock { () -> NWListener? in
            let current = listener
            listener = nil
            endpoint = nil
            return current
        }
        current?.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumBodyBytes + 65_536) {
            [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if accumulated.count > Self.maximumBodyBytes + 65_536 {
                self.send(.text(413, #"{"error":"request too large"}"#), on: connection)
                return
            }
            if let response = awaitResponse(accumulated) {
                Task { await self.respond(response, on: connection) }
                return
            }
            if complete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: accumulated)
        }
    }

    private func awaitResponse(_ data: Data) -> BotHTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator),
              let head = String(data: data[..<range.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= Self.maximumBodyBytes else {
            return BotHTTPRequest(method: "ERROR", target: "", headers: [:], body: Data())
        }
        let body = Data(data[range.upperBound...])
        guard body.count >= length else { return nil }
        return BotHTTPRequest(
            method: String(parts[0]).uppercased(), target: String(parts[1]),
            headers: headers, body: Data(body.prefix(length)))
    }

    private func respond(_ request: BotHTTPRequest, on connection: NWConnection) async {
        if request.method == "ERROR" {
            send(.text(413, #"{"error":"request too large"}"#), on: connection)
            return
        }
        // A request that carries an Origin must carry exactly this server's
        // origin (LoopbackServer's rule). Requests from the host egress carry
        // none, so they stay accepted.
        if let origin = request.headers["origin"],
           origin.caseInsensitiveCompare(originString) != .orderedSame {
            send(.text(403, #"{"error":"origin mismatch"}"#), on: connection)
            return
        }
        guard Self.tokenMatches(request.headers["authorization"], expected: "Bearer \(token)") else {
            send(.text(401, #"{"error":"unauthorized"}"#), on: connection)
            return
        }
        guard request.method == "POST" else {
            send(.text(405, #"{"error":"method not allowed"}"#), on: connection)
            return
        }
        // Paths are exact. A query string, a trailing slash, a different case
        // or a `..` segment is not a route; DELETE cannot succeed anywhere.
        guard !request.target.isEmpty,
              !request.target.contains("?"),
              !request.target.contains("#"),
              !request.target.contains(".."),
              request.target.hasPrefix("/") else {
            send(.text(400, #"{"error":"invalid request target"}"#), on: connection)
            return
        }
        guard let value = try? BotJSONValue.parse(request.body) else {
            send(.text(400, #"{"error":"invalid JSON"}"#), on: connection)
            return
        }
        switch request.target {
        case "/identity/register":
            let reply = await handler.registerIdentity(value)
            send(.json(200, reply), on: connection)
        case "/identity/cancel":
            let reply = await handler.cancelIdentity(value)
            send(.json(200, reply), on: connection)
        case "/approval":
            let reply = await handler.approval(value)
            send(.json(200, reply), on: connection)
        case "/mcp":
            let messages = value.arrayValue ?? [value]
            var replies: [BotJSONValue] = []
            for message in messages {
                guard case .object(let object) = message,
                      case .string(let method)? = object["method"] else {
                    send(.text(400, #"{"error":"invalid JSON-RPC message"}"#), on: connection)
                    return
                }
                guard let id = object["id"] else { continue }
                let params = object["params"] ?? .object([:])
                replies.append(await handler.rpc(method: method, params: params, id: id,
                                                 headers: request.headers))
            }
            if replies.isEmpty {
                send(.text(202, "", session: true), on: connection)
            } else {
                let reply: BotJSONValue = value.arrayValue == nil ? replies[0] : .array(replies)
                send(.json(200, reply, session: true), on: connection)
            }
        default:
            send(.text(404, #"{"error":"not found"}"#), on: connection)
        }
    }

    private func send(_ response: BotHTTPResponse, on connection: NWConnection) {
        let body = response.body
        var head = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Status")\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        if response.session {
            head += "Mcp-Session-Id: \(handler.mcpSessionId)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private var originString: String {
        let current = lock.withLock { endpoint }
        guard let current,
              var components = URLComponents(url: current, resolvingAgainstBaseURL: false) else { return "" }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.string ?? ""
    }

    /// Constant-time comparison over UTF-8 bytes. Length is allowed to differ
    /// (it is not secret), but equal-length byte comparison does not exit on
    /// the first mismatch.
    static func tokenMatches(_ supplied: String?, expected: String) -> Bool {
        guard let supplied else { return false }
        let left = Array(supplied.utf8)
        let right = Array(expected.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    private static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<24).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }
}

private struct BotHTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
}

private struct BotHTTPResponse {
    let status: Int
    let body: Data
    let session: Bool

    static func text(_ status: Int, _ text: String, session: Bool = false) -> Self {
        Self(status: status, body: Data(text.utf8), session: session)
    }

    static func json(_ status: Int, _ value: BotJSONValue, session: Bool = false) -> Self {
        let data = (try? value.encoded()) ?? Data(#"{"error":"encoding failed"}"#.utf8)
        return Self(status: status, body: data, session: session)
    }

    private init(status: Int, body: Data, session: Bool) {
        self.status = status
        self.body = body
        self.session = session
    }
}
