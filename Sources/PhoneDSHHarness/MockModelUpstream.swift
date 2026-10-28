// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — macOS end-to-end smoke: the scripted model upstream.
//
// A minimal Network.framework HTTP/1.1 server that speaks the Messages wire
// format DSH's DeepSeek adapter uses (`POST <base>/v1/messages`, SSE). It is
// deliberately stateless: every reply is derived from the request's message
// history, so a resumed session after a planned restart continues the same
// deterministic script.
//
// Script: the first assistant turn calls the DSH `bash` tool with
// `echo hi > a.txt && cat a.txt`; every later turn (the transcript already has
// a tool result) answers with a final text message.
//
// No model and no credentials are involved. The host model gateway injects the
// only credential the upstream sees; the smoke test asserts that.

import Foundation
import Network

/// One request the mock received, kept for assertions and the smoke report.
public struct MockModelRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data
    public var receivedAt: Date

    /// The `x-api-key` the host gateway injected (nil when absent).
    public var apiKey: String? { headers["x-api-key"] }

    public init(method: String, path: String, headers: [String: String],
                body: Data, receivedAt: Date) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
        self.receivedAt = receivedAt
    }
}

/// A parsed HTTP/1.1 request (headers + complete Content-Length body).
private struct MockHTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
}

/// Script the mock follows. The smoke uses ``fileWrite``; the scenario runner
/// uses ``generic`` so every user prompt gets one fixed tool call followed by a
/// final text message, independent of the prompt text.
public enum MockModelScript: Sendable {
    /// The smoke script: the first assistant turn calls the `bash` tool with
    /// ``MockModelUpstream/toolCommand``; later turns answer with final text.
    case fileWrite
    /// One fixed tool call per user turn, then a fixed final message after the
    /// tool result. Works for any prompt, which is what a scenario mock needs.
    case generic(command: String, toolText: String, finalText: String)
}

/// The scripted model upstream. Call ``start()`` on any thread, then ``stop()``.
public final class MockModelUpstream: @unchecked Sendable {
    public init() {}

    /// Body text of the tool the scripted assistant calls.
    public static let toolCommand = "echo hi > a.txt && cat a.txt"

    private let queue = DispatchQueue(label: "xl.smoke.mock-model")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var recorded: [MockModelRequest] = []
    private var responseNumber = 0
    private var stopping = false
    private var scriptStorage: MockModelScript = .fileWrite
    private var requestBytesStorage = 0
    private var responseBytesStorage = 0
    private var responseBodiesStorage: [Data] = []

    /// Port the listener bound (valid after ``start()`` returns).
    public private(set) var port: UInt16 = 0

    /// Base URL the Worker's `DEEPSEEK_BASE_URL` should point at.
    public var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    /// Every complete `POST /v1/messages` this server answered, in order.
    public var requests: [MockModelRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    public var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recorded.count
    }

    /// Scripted replies; set before ``start()``. The default is the smoke
    /// script, so existing smoke tests are unchanged.
    public var script: MockModelScript {
        get {
            lock.lock()
            defer { lock.unlock() }
            return scriptStorage
        }
        set {
            lock.lock()
            scriptStorage = newValue
            lock.unlock()
        }
    }

    /// Total bytes of request bodies received (all routed requests).
    public var requestBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestBytesStorage
    }

    /// Total bytes of response bodies sent (all routed requests).
    public var responseBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return responseBytesStorage
    }

    /// Complete 200 response bodies in answer order (for `PDSH_SCENARIO_KEEP_BODIES`).
    public var responseBodies: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return responseBodiesStorage
    }

    // MARK: - Lifecycle

    /// Binds an ephemeral loopback port and starts accepting.
    @discardableResult
    public func start() throws -> URL {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        var startError: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                startError = error
                ready.signal()
            case .cancelled:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success else {
            listener.cancel()
            throw MockModelError.startTimedOut
        }
        if let startError {
            listener.cancel()
            throw MockModelError.listenerFailed(String(describing: startError))
        }
        guard let rawPort = listener.port?.rawValue, rawPort != 0 else {
            listener.cancel()
            throw MockModelError.listenerFailed("the listener bound no port")
        }
        self.listener = listener
        self.port = rawPort
        return baseURL
    }

    /// Stops the listener and closes every open connection.
    public func stop() {
        lock.lock()
        stopping = true
        let open = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        for connection in open { connection.cancel() }
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        if stopping {
            lock.unlock()
            connection.cancel()
            return
        }
        connections[ObjectIdentifier(connection)] = connection
        lock.unlock()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.forget(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func forget(_ connection: NWConnection) {
        lock.lock()
        connections[ObjectIdentifier(connection)] = nil
        lock.unlock()
    }

    // MARK: - HTTP

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if let request = Self.parse(accumulated) {
                self.answer(connection, request: request)
                return
            }
            if error != nil || isComplete {
                self.forget(connection)
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: accumulated)
        }
    }

    /// Parses one complete request; `nil` means "more bytes are needed".
    private static func parse(_ data: Data) -> MockHTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else { return nil }
        let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            if name.isEmpty == false { headers[name] = value }
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.count >= bodyStart + length else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + length))
        return MockHTTPRequest(method: String(parts[0]).uppercased(),
                               path: String(parts[1]),
                               headers: headers,
                               body: body)
    }

    private func answer(_ connection: NWConnection, request: MockHTTPRequest) {
        guard request.method == "POST",
              request.path.hasSuffix("/v1/messages") else {
            send(connection, status: 404, contentType: "application/json",
                 body: Data(#"{"type":"error","error":{"type":"not_found_error","message":"no route"}}"#.utf8))
            return
        }
        lock.lock()
        recorded.append(MockModelRequest(method: request.method,
                                         path: request.path,
                                         headers: request.headers,
                                         body: request.body,
                                         receivedAt: Date()))
        requestBytesStorage += request.body.count
        lock.unlock()
        let events = events(for: request.body)
        send(connection, status: 200, contentType: "text/event-stream", body: events)
    }

    private func send(_ connection: NWConnection, status: Int, contentType: String,
                      body: Data) {
        lock.lock()
        responseBytesStorage += body.count
        if status == 200 { responseBodiesStorage.append(body) }
        lock.unlock()
        let reason = status == 200 ? "OK" : "Not Found"
        let head = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var message = Data(head.utf8)
        message.append(body)
        connection.send(content: message, completion: .contentProcessed { [weak self] _ in
            self?.forget(connection)
            connection.cancel()
        })
    }

    // MARK: - Script

    /// Whether the transcript already contains a tool result for our tool call.
    public static func transcriptHasToolResult(_ body: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = object["messages"] as? [[String: Any]] else {
            return false
        }
        for message in messages {
            guard let content = message["content"] as? [[String: Any]] else { continue }
            for block in content where block["type"] as? String == "tool_result" {
                return true
            }
        }
        return false
    }

    /// Whether the last message of the transcript is a tool result. The
    /// ``MockModelScript/generic`` script issues a tool call on every user
    /// turn and final text after the tool result, so it must look at the tail
    /// rather than anywhere in the history.
    public static func lastMessageHasToolResult(_ body: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = object["messages"] as? [[String: Any]],
              let last = messages.last,
              let content = last["content"] as? [[String: Any]] else {
            return false
        }
        return content.contains { $0["type"] as? String == "tool_result" }
    }

    /// Builds the SSE body for one request from the transcript shape.
    private func events(for body: Data) -> Data {
        let model: String
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let name = object["model"] as? String {
            model = name
        } else {
            model = "deepseek-flash"
        }
        let helper = SSECounter.next()
        let script = script
        let respondWithTool: Bool
        let toolCommand: String
        let toolDescription: String
        let pendingText: String
        let finalText: String
        switch script {
        case .fileWrite:
            respondWithTool = Self.transcriptHasToolResult(body) == false
            toolCommand = Self.toolCommand
            toolDescription = "Write hi to a.txt and print it"
            pendingText = "I will write hi into a.txt and print it."
            finalText = "Done: a.txt contains hi."
        case .generic(let command, let toolText, let reply):
            respondWithTool = Self.lastMessageHasToolResult(body) == false
            toolCommand = command
            toolDescription = "Run the scenario's fixed command"
            pendingText = toolText
            finalText = reply
        }
        var text = pendingText
        var sse = ""
        func emit(_ event: String, _ payload: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                         options: [.sortedKeys]) else { return }
            sse += "event: \(event)\n"
            sse += "data: \(String(decoding: data, as: UTF8.self))\n\n"
        }
        if respondWithTool == false {
            text = finalText
        }
        emit("message_start", [
            "type": "message_start",
            "message": [
                "id": "msg_smoke_\(helper)",
                "type": "message",
                "role": "assistant",
                "model": model,
                "content": [],
                "usage": ["input_tokens": 64, "output_tokens": 0],
            ],
        ])
        emit("content_block_start", [
            "type": "content_block_start",
            "index": 0,
            "content_block": ["type": "text", "text": ""],
        ])
        emit("content_block_delta", [
            "type": "content_block_delta",
            "index": 0,
            "delta": ["type": "text_delta", "text": text],
        ])
        emit("content_block_stop", ["type": "content_block_stop", "index": 0])
        if respondWithTool {
            let input: [String: Any] = [
                "command": toolCommand,
                "description": toolDescription,
            ]
            let inputJSON = (try? JSONSerialization.data(withJSONObject: input,
                                                         options: [.sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            emit("content_block_start", [
                "type": "content_block_start",
                "index": 1,
                "content_block": [
                    "type": "tool_use",
                    "id": "toolu_smoke_\(helper)",
                    "name": "bash",
                    "input": [:],
                ],
            ])
            emit("content_block_delta", [
                "type": "content_block_delta",
                "index": 1,
                "delta": ["type": "input_json_delta", "partial_json": inputJSON],
            ])
            emit("content_block_stop", ["type": "content_block_stop", "index": 1])
        }
        emit("message_delta", [
            "type": "message_delta",
            "delta": ["stop_reason": respondWithTool ? "tool_use" : "end_turn"],
            "usage": ["output_tokens": 24],
        ])
        emit("message_stop", ["type": "message_stop"])
        return Data(sse.utf8)
    }

    private enum SSECounter {
        private static let lock = NSLock()
        private static var value = 0
        static func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }
}

/// Failures of the mock upstream itself.
public enum MockModelError: Error, CustomStringConvertible {
    case startTimedOut
    case listenerFailed(String)

    public var description: String {
        switch self {
        case .startTimedOut:
            return "mock model upstream did not become ready in 10 s"
        case .listenerFailed(let detail):
            return "mock model upstream failed: \(detail)"
        }
    }
}
