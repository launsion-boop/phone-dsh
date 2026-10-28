// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: scripted model upstream.
//
// The mock used by `--upstream mock` runs. It replays the *shape* the real
// Messages upstream produced during the catalog batch (15–95 KB SSE bodies
// with thinking deltas, an optional tool_use block, `message_delta` usage and
// `message_stop`) instead of the tiny fixed body of the smoke mock. That shape
// is what the delivery chain (gateway → loopback chunked egress → WebKit fetch
// → model client) has to carry; a bounded-completion scenario therefore
// exercises the same mechanism the real-model runs do.
//
// The server is deterministic: reply #n answers with a tool call while
// `n <= toolCallRounds` and with the final text afterwards, so a scenario can
// script several model round trips. No model and no credentials are involved.

import Foundation
import Network

/// One mock-side request worth reporting.
struct ScenarioMockRequest: Sendable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
    var receivedAt: Date
}

/// Script the mock follows for one scenario.
struct ScenarioMockScript: Sendable {
    /// How many replies call the fixed tool before the final text reply.
    var toolCallRounds: Int
    /// The `bash` command the scripted tool call runs.
    var toolCommand: String
    /// Description shown for the scripted tool call.
    var toolDescription: String
    /// Assistant text emitted before a tool call.
    var toolText: String
    /// Final assistant text; ends the turn.
    var finalText: String
    /// Target SSE body size per reply (the last value repeats). Empty means
    /// the built-in 15–95 KB shape taken from the real batch.
    var responseByteSizes: [Int]
    /// Largest TCP write used while streaming a body.
    var chunkBytes: Int
    /// Delay between streamed writes, in seconds.
    var chunkDelay: TimeInterval
    /// 1-based reply number from which every response stalls mid-body: after
    /// `stallAfterBytes` bytes the connection stays open with no terminating
    /// chunk. This is the delivery-stall shape observed in the real batch (the
    /// host received the full response while the Worker's fetch never saw the
    /// rest). `nil` streams every reply completely.
    var stallFromResponse: Int?
    /// Body bytes written to the Worker before a stalled reply goes silent.
    var stallAfterBytes: Int
    /// When set, a stalled reply is not held open forever: after this pause it
    /// continues with the remaining body and the terminating chunk. This is
    /// the shape of a consumer that stopped pulling for a while (a suspended
    /// WebKit page) while the host kept receiving the upstream body; the
    /// delivery layer must replenish its window from the host instead of
    /// abandoning the response. `nil` holds the socket open (the stall shape).
    var resumeAfterPause: TimeInterval?

    /// The generic one-tool-call script the scenario runner has always used.
    static let generic = ScenarioMockScript(
        toolCallRounds: 1,
        toolCommand: "echo scenario > a.txt && cat a.txt",
        toolDescription: "Run the scenario's fixed command",
        toolText: "Running the scenario's fixed command.",
        finalText: "Done.",
        responseByteSizes: [],
        chunkBytes: 2 * 1024,
        chunkDelay: 0,
        stallFromResponse: nil,
        stallAfterBytes: 8 * 1024,
        resumeAfterPause: nil)

    /// Sizes observed in the real-model batch (bytes per SSE body).
    static let capturedShapeByteSizes = [15_151, 37_153, 94_724, 46_469, 20_204, 77_106, 33_000]
}

/// A minimal Network.framework HTTP/1.1 server that answers `POST …/v1/messages`
/// with a streamed Messages SSE body. Call ``start()`` on any thread, then
/// ``stop()``.
final class ScenarioMockUpstream: @unchecked Sendable {
    private let queue = DispatchQueue(label: "xl.scenario.mock-model")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var recorded: [ScenarioMockRequest] = []
    private var responseBodiesStorage: [Data] = []
    private var stalledBodiesStorage: [Data] = []
    /// Request bodies whose 200 response was completely streamed. A gateway
    /// transport retry of the same logical model request re-sends the
    /// identical body (the conversation has not advanced), so this is the
    /// *logical* complete-response count the delivery invariant uses: the
    /// superseded attempt is a retry, not a delivery loss. Distinct bodies are
    /// distinct model requests and each one still needs a consumed response.
    private var completedRequestBodies: Set<Data> = []
    private var requestBytesStorage = 0
    private var responseBytesStorage = 0
    private var stalledBytesStorage = 0
    private var stopping = false
    private var scriptStorage: ScenarioMockScript = .generic

    /// Port the listener bound (valid after ``start()`` returns).
    private(set) var port: UInt16 = 0

    /// Base URL the Worker's `DEEPSEEK_BASE_URL` should point at.
    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    var script: ScenarioMockScript {
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

    /// Every complete `POST /v1/messages` this server answered, in order.
    var requests: [ScenarioMockRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recorded.count
    }

    /// Total bytes of request bodies received.
    var requestBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestBytesStorage
    }

    /// Total bytes of response bodies sent.
    var responseBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return responseBytesStorage
    }

    /// Complete 200 response bodies in answer order.
    var responseBodies: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return responseBodiesStorage
    }

    /// Number of distinct model requests whose 200 response was completely
    /// streamed. Two transport attempts of the same request body count once:
    /// the retried response supersedes the abandoned one instead of being a
    /// second logical delivery. This is the count the `mock_delivery`
    /// invariant compares against the Worker's usage events.
    var distinctCompleteResponseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return completedRequestBodies.count
    }

    /// Full intended bodies of the replies the script held open mid-stream.
    var stalledBodies: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return stalledBodiesStorage
    }

    /// Bytes actually written before each stalled reply went silent.
    var stalledBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return stalledBytesStorage
    }

    // MARK: - Lifecycle

    @discardableResult
    func start() throws -> URL {
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
            throw ScenarioMockError.startTimedOut
        }
        if let startError {
            listener.cancel()
            throw ScenarioMockError.listenerFailed(String(describing: startError))
        }
        guard let rawPort = listener.port?.rawValue, rawPort != 0 else {
            listener.cancel()
            throw ScenarioMockError.listenerFailed("the listener bound no port")
        }
        self.listener = listener
        self.port = rawPort
        return baseURL
    }

    func stop() {
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
            if let parsed = Self.parse(accumulated) {
                self.answer(connection, request: parsed.request)
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
    private static func parse(_ data: Data) -> (request: MockHTTPRequest, consumed: Int)? {
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
        let request = MockHTTPRequest(method: String(parts[0]).uppercased(),
                                      path: String(parts[1]),
                                      headers: headers,
                                      body: body)
        return (request, bodyStart + length)
    }

    private func answer(_ connection: NWConnection, request: MockHTTPRequest) {
        guard request.method == "POST",
              request.path.hasSuffix("/v1/messages") else {
            sendHead(connection, status: 404, contentType: "application/json")
            let body = Data(#"{"type":"error","error":{"type":"not_found_error","message":"no route"}}"#.utf8)
            sendAll(connection, body: body, chunkBytes: body.count, delay: 0)
            return
        }
        lock.lock()
        recorded.append(ScenarioMockRequest(method: request.method,
                                            path: request.path,
                                            headers: request.headers,
                                            body: request.body,
                                            receivedAt: Date()))
        requestBytesStorage += request.body.count
        let index = recorded.count
        let script = scriptStorage
        lock.unlock()

        let toolCall = index <= max(0, script.toolCallRounds)
        let sizes = script.responseByteSizes.isEmpty
            ? ScenarioMockScript.capturedShapeByteSizes
            : script.responseByteSizes
        let target = sizes[min(max(0, index - 1), sizes.count - 1)]
        let body = Self.sseBody(model: model(of: request.body),
                                sequence: index,
                                toolCall: toolCall,
                                script: script,
                                targetBytes: target)
        let stalls = script.stallFromResponse.map { index >= $0 } ?? false
        if stalls {
            let written = min(body.count, max(0, script.stallAfterBytes))
            lock.lock()
            if script.resumeAfterPause == nil {
                stalledBodiesStorage.append(body)
                responseBytesStorage += written
                stalledBytesStorage += written
            } else {
                // The host received the complete body; only the downstream
                // consumer paused. It counts as a complete streamed response,
                // so `mock_delivery` fails if the Worker does not consume it.
                responseBodiesStorage.append(body)
                completedRequestBodies.insert(request.body)
                responseBytesStorage += body.count
            }
            lock.unlock()
            sendHead(connection, status: 200, contentType: "text/event-stream")
            sendAll(connection, body: Data(body.prefix(written)),
                    chunkBytes: max(1, script.chunkBytes),
                    delay: max(0, script.chunkDelay),
                    holdOpen: true)
            if let pause = script.resumeAfterPause {
                // The upstream body is already complete in the host gateway's
                // response log; only the downstream consumer stopped pulling.
                // Deliver the remainder after the pause, exactly as a resumed
                // consumer would need it.
                let remainder = Data(body.dropFirst(written))
                let chunkBytes = max(1, script.chunkBytes)
                let delay = max(0, script.chunkDelay)
                queue.asyncAfter(deadline: .now() + max(0, pause)) { [weak self] in
                    guard let self else { return }
                    self.sendAll(connection, body: remainder,
                                 chunkBytes: chunkBytes, delay: delay)
                }
            }
            return
        }
        lock.lock()
        responseBodiesStorage.append(body)
        completedRequestBodies.insert(request.body)
        responseBytesStorage += body.count
        lock.unlock()

        sendHead(connection, status: 200, contentType: "text/event-stream")
        sendAll(connection, body: body,
                chunkBytes: max(1, script.chunkBytes),
                delay: max(0, script.chunkDelay))
    }

    private func model(of body: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let name = object["model"] as? String {
            return name
        }
        return "deepseek-flash"
    }

    private struct MockHTTPRequest {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    /// Writes the response head. The body is always chunked: this is the
    /// framing a streamed SSE response uses through the host gateway.
    private func sendHead(_ connection: NWConnection, status: Int, contentType: String) {
        let reason = status == 200 ? "OK" : "Not Found"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Cache-Control: no-cache\r\n"
        head += "Transfer-Encoding: chunked\r\n"
        head += "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8),
                        contentContext: .defaultMessage,
                        isComplete: false,
                        completion: .contentProcessed { _ in })
    }

    /// Streams `body` as RFC 7230 chunks. The last write carries FIN, unless
    /// `holdOpen` keeps the connection open with no terminating chunk (the
    /// delivery-stall shape).
    private func sendAll(_ connection: NWConnection, body: Data,
                         chunkBytes: Int, delay: TimeInterval,
                         holdOpen: Bool = false) {
        let chunks = stride(from: 0, to: body.count, by: chunkBytes).map { start in
            body.subdata(in: start..<min(body.count, start + chunkBytes))
        }
        writeChunks(connection, chunks: chunks, index: 0, delay: delay, holdOpen: holdOpen)
    }

    private func writeChunks(_ connection: NWConnection, chunks: [Data],
                             index: Int, delay: TimeInterval, holdOpen: Bool = false) {
        if index >= chunks.count {
            // A mid-stream stall never writes the zero-length chunk: the Worker
            // is left waiting for body bytes while the server holds the socket.
            if holdOpen { return }
            // The zero-length chunk ends the HTTP body. Marking the content
            // complete makes Network.framework send FIN after it; the
            // connection is cancelled a moment later so a URLSession client
            // observes a clean end of response rather than a reset.
            connection.send(content: Data("0\r\n\r\n".utf8),
                            contentContext: .defaultMessage,
                            isComplete: true,
                            completion: .contentProcessed { [weak self] _ in
                                self?.forget(connection)
                                self?.queue.asyncAfter(deadline: .now() + 0.2) {
                                    connection.cancel()
                                }
                            })
            return
        }
        var frame = Data("\(String(chunks[index].count, radix: 16))\r\n".utf8)
        frame.append(chunks[index])
        frame.append(Data("\r\n".utf8))
        connection.send(content: frame, contentContext: .defaultMessage, isComplete: false,
                        completion: .contentProcessed { [weak self] error in
            guard error == nil else {
                self?.forget(connection)
                connection.cancel()
                return
            }
            if delay > 0 {
                self?.queue.asyncAfter(deadline: .now() + delay) {
                    self?.writeChunks(connection, chunks: chunks, index: index + 1,
                                      delay: delay, holdOpen: holdOpen)
                }
            } else {
                self?.writeChunks(connection, chunks: chunks, index: index + 1,
                                  delay: delay, holdOpen: holdOpen)
            }
        })
    }

    // MARK: - SSE body

    /// Builds the same-shape SSE body the real upstream produced: a thinking
    /// block padded to `targetBytes`, an optional `tool_use` block, a
    /// `message_delta` with usage and a `message_stop`.
    static func sseBody(model: String,
                        sequence: Int,
                        toolCall: Bool,
                        script: ScenarioMockScript,
                        targetBytes: Int) -> Data {
        var text = ""
        func emit(_ event: String, _ payload: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                         options: [.sortedKeys]) else { return }
            text += "event: \(event)\n"
            text += "data: \(String(decoding: data, as: UTF8.self))\n\n"
        }
        let identifier = "msg_mock_\(sequence)"
        emit("message_start", [
            "type": "message_start",
            "message": [
                "id": identifier,
                "type": "message",
                "role": "assistant",
                "model": model,
                "content": [],
                "stop_reason": NSNull(),
                "stop_sequence": NSNull(),
                "usage": [
                    "input_tokens": 128 + sequence * 37,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 2048,
                    "output_tokens": 0,
                    "service_tier": "standard",
                ],
            ],
        ])
        emit("content_block_start", [
            "type": "content_block_start",
            "index": 0,
            "content_block": ["type": "thinking", "thinking": "", "signature": ""],
        ])
        emit("ping", ["type": "ping"])
        let words = ["Plan", " the", " fixed", " command", ",", " then", " verify",
                     " the", " workspace", " entry", ".", " The", " result", " must",
                     " stay", " inside", " the", " workspace", "."]
        var produced = 0
        // Leave room for the tail (tool block, message_delta, message_stop).
        let paddingTarget = max(512, targetBytes - 1_400)
        while text.utf8.count < paddingTarget {
            let word = words[produced % words.count]
            emit("content_block_delta", [
                "type": "content_block_delta",
                "index": 0,
                "delta": ["type": "thinking_delta", "thinking": word],
            ])
            produced += 1
        }
        emit("content_block_delta", [
            "type": "content_block_delta",
            "index": 0,
            "delta": ["type": "signature_delta", "signature": identifier],
        ])
        emit("content_block_stop", ["type": "content_block_stop", "index": 0])
        if toolCall {
            emit("content_block_start", [
                "type": "content_block_start",
                "index": 1,
                "content_block": [
                    "type": "tool_use",
                    "id": "toolu_mock_\(sequence)",
                    "name": "bash",
                    "input": [:],
                ],
            ])
            let input: [String: Any] = [
                "command": script.toolCommand,
                "description": script.toolDescription,
            ]
            let inputJSON = (try? JSONSerialization.data(withJSONObject: input,
                                                         options: [.sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            emit("content_block_delta", [
                "type": "content_block_delta",
                "index": 1,
                "delta": ["type": "input_json_delta", "partial_json": inputJSON],
            ])
            emit("content_block_stop", ["type": "content_block_stop", "index": 1])
        } else {
            emit("content_block_start", [
                "type": "content_block_start",
                "index": 1,
                "content_block": ["type": "text", "text": ""],
            ])
            emit("content_block_delta", [
                "type": "content_block_delta",
                "index": 1,
                "delta": ["type": "text_delta", "text": script.finalText],
            ])
            emit("content_block_stop", ["type": "content_block_stop", "index": 1])
        }
        emit("message_delta", [
            "type": "message_delta",
            "delta": [
                "stop_reason": toolCall ? "tool_use" : "end_turn",
                "stop_sequence": NSNull(),
            ],
            "usage": [
                "input_tokens": 128 + sequence * 37,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 2048,
                "output_tokens": 96 + (toolCall ? 24 : 4),
                "service_tier": "standard",
            ],
        ])
        emit("message_stop", ["type": "message_stop"])
        return Data(text.utf8)
    }
}

/// Failures of the scenario mock upstream itself.
enum ScenarioMockError: Error, CustomStringConvertible {
    case startTimedOut
    case listenerFailed(String)

    var description: String {
        switch self {
        case .startTimedOut:
            return "scenario mock upstream did not become ready in 10 s"
        case .listenerFailed(let detail):
            return "scenario mock upstream failed: \(detail)"
        }
    }
}
