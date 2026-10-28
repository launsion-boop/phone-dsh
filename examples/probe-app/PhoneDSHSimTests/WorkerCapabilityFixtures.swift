// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS Simulator capability fixtures.
//
// Two local, loopback-only HTTP servers used by WorkerCapabilityTests.swift:
//
//   * CapabilityModelFixture speaks the Messages wire the DSH gateway already
//     uses. Only the model's tool choices are scripted; every tool_result in
//     the transcript came from the real Worker, child agent, shell and VFS.
//   * CapabilityMcpFixture speaks Streamable HTTP MCP JSON-RPC (the same
//     initialize / tools/list / tools/call sequence as
//     plugins/tests/fixtures/phone-mcp-fixture.ts). It accepts only the dummy
//     bearer injected by the host `/mcp` credential, rejects the different
//     env-only dummy and the model key, and never prints a token value.
//
// Both servers bind 127.0.0.1 on an ephemeral port. No external service, real
// key or real MCP endpoint is used. This file is test-only; it is compiled into
// PhoneDSHSimTests/PhoneDSHDeviceTests by the folder source in project.yml.

import Foundation
import Network

// MARK: - Small HTTP/1.1 server

/// One complete HTTP/1.1 request.
struct CapabilityHTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

/// One HTTP response; the server always closes the connection afterwards.
struct CapabilityHTTPResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data

    static func json(_ object: Any,
                     status: Int = 200,
                     extraHeaders: [String: String] = [:]) -> CapabilityHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.sortedKeys])) ?? Data()
        var headers = extraHeaders
        headers["Content-Type"] = headers["Content-Type"] ?? "application/json"
        return CapabilityHTTPResponse(status: status, headers: headers, body: data)
    }

    static func text(_ text: String, status: Int = 200,
                     extraHeaders: [String: String] = [:]) -> CapabilityHTTPResponse {
        var headers = extraHeaders
        headers["Content-Type"] = headers["Content-Type"] ?? "text/plain; charset=utf-8"
        return CapabilityHTTPResponse(status: status, headers: headers,
                                      body: Data(text.utf8))
    }
}

/// Minimal HTTP/1.1 listener. It parses one request per connection, invokes a
/// synchronous responder and closes. The model gateway and MCP SDK both send
/// small `Content-Length` bodies; chunked bodies are decoded too so a streaming
/// client cannot silently wedge the fixture.
final class CapabilityHTTPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "pdsh.capability.http")
    private let lock = NSLock()
    private let handler: @Sendable (CapabilityHTTPRequest) -> CapabilityHTTPResponse
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var stopping = false
    private(set) var port: UInt16 = 0

    init(handler: @escaping @Sendable (CapabilityHTTPRequest) -> CapabilityHTTPResponse) {
        self.handler = handler
    }

    /// Bind an ephemeral 127.0.0.1-only port and return `http://127.0.0.1:<port>`.
    func start() throws -> URL {
        // `NWListener(using: .tcp, on: .any)` listens on every interface. The
        // fixtures are documented as loopback-only, so pin the local endpoint
        // to 127.0.0.1 instead of merely advertising that in a comment.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"),
                                                              port: .any)
        let listener = try NWListener(using: parameters)
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
            throw CapabilityFixtureError.startTimedOut("HTTP listener")
        }
        if let startError {
            listener.cancel()
            throw CapabilityFixtureError.listener(String(describing: startError))
        }
        guard let rawPort = listener.port?.rawValue, rawPort != 0 else {
            listener.cancel()
            throw CapabilityFixtureError.listener("HTTP listener bound no port")
        }
        lock.lock()
        self.listener = listener
        self.port = rawPort
        lock.unlock()
        guard let url = URL(string: "http://127.0.0.1:\(rawPort)") else {
            throw CapabilityFixtureError.listener("invalid loopback URL")
        }
        return url
    }

    func stop() {
        lock.lock()
        stopping = true
        let open = Array(connections.values)
        connections.removeAll()
        let current = listener
        listener = nil
        lock.unlock()
        for connection in open { connection.cancel() }
        current?.cancel()
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
                let response = self.handler(request)
                self.send(response, on: connection)
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

    private func send(_ response: CapabilityHTTPResponse, on connection: NWConnection) {
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        headers["Content-Type"] = headers["Content-Type"] ?? "application/json"
        // The MCP client runs inside the page's WebWorker and may connect to a
        // different loopback port. A preflight is therefore part of the real
        // browser path; answer it and expose the session header. CORS does not
        // weaken authentication: the Worker only knows the env-only dummy,
        // which the MCP fixture rejects; only host egress injects the accepted
        // credential.
        headers["Access-Control-Allow-Origin"] = "*"
        headers["Access-Control-Allow-Methods"] = "GET, POST, DELETE, OPTIONS"
        headers["Access-Control-Allow-Headers"] =
            "Authorization, Content-Type, Accept, Mcp-Session-Id, MCP-Protocol-Version, Last-Event-ID"
        headers["Access-Control-Expose-Headers"] = "Mcp-Session-Id"
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var message = Data(head.utf8)
        message.append(response.body)
        connection.send(content: message, completion: .contentProcessed { [weak self] _ in
            self?.forget(connection)
            connection.cancel()
        })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        default: return "Status"
        }
    }

    /// Parse one complete request; `nil` means "more bytes are needed".
    /// Shared with the Streamable HTTP SSE-response fixture so both loopback
    /// servers use the same Content-Length/chunked body parser instead of a
    /// second HTTP reader.
    static func parse(_ data: Data) -> CapabilityHTTPRequest? {
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
            guard !name.isEmpty else { continue }
            // Do not let a second Authorization silently overwrite the first:
            // the MCP egress proof must not pass when the Worker's env-only
            // header and the host credential are both present. Joining makes
            // the value differ from either single credential, so the fixture
            // rejects it instead of accepting whichever line came last.
            if let previous = headers[name], previous != value {
                headers[name] = "\(previous), \(value)"
            } else {
                headers[name] = value
            }
        }
        let bodyStart = headerEnd.upperBound
        if let transfer = headers["transfer-encoding"]?.lowercased(),
           transfer.contains("chunked") {
            guard let body = decodeChunked(data, from: bodyStart) else { return nil }
            return CapabilityHTTPRequest(method: String(parts[0]).uppercased(),
                                         path: String(parts[1]),
                                         headers: headers,
                                         body: body)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard data.count >= bodyStart + length else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + length))
        return CapabilityHTTPRequest(method: String(parts[0]).uppercased(),
                                     path: String(parts[1]),
                                     headers: headers,
                                     body: body)
    }

    private static func decodeChunked(_ data: Data, from start: Int) -> Data? {
        var cursor = start
        var output = Data()
        while cursor < data.count {
            guard let lineEnd = data.range(of: Data("\r\n".utf8),
                                           in: cursor..<data.count) else { return nil }
            let line = String(decoding: data[cursor..<lineEnd.lowerBound], as: UTF8.self)
            let sizeText = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else {
                return nil
            }
            let chunkStart = lineEnd.upperBound
            if size == 0 {
                // A trailer section ends with an empty line; ignore its content.
                return output
            }
            guard data.count >= chunkStart + size + 2 else { return nil }
            output.append(data.subdata(in: chunkStart..<(chunkStart + size)))
            cursor = chunkStart + size + 2
        }
        return nil
    }
}

enum CapabilityFixtureError: Error, CustomStringConvertible {
    case startTimedOut(String)
    case listener(String)
    case invalidResponse(String)

    var description: String {
        switch self {
        case .startTimedOut(let what): return "\(what) did not become ready in 10 s"
        case .listener(let detail): return "loopback listener failed: \(detail)"
        case .invalidResponse(let detail): return "fixture response: \(detail)"
        }
    }
}

// MARK: - Scripted Messages model

/// The two scripted model sequences used by WorkerCapabilityTests.
enum CapabilityModelMode: Sendable {
    /// Parent `workflow` tool → child `bash` tool → parent final text.
    /// `loop` scripts are terminated by the workflow deadline.
    case workflow(nonce: String)
    /// One dynamic MCP tool call followed by final text.
    case mcp(nonce: String, toolName: String, message: String)
}

/// One Messages request observation (the API key is the host-injected value).
struct CapabilityModelObservation: Sendable {
    let method: String
    let path: String
    let apiKey: String?
    let body: Data
}

/// Which scripted branch the request actually selected. The acceptance report
/// records these booleans so a green loop row cannot be satisfied by the
/// ordinary bash-probe branch (or by a child Agent reusing the parent branch).
struct CapabilityModelSelection: Sendable, Equatable {
    var parentLoop = 0
    var parentNormal = 0
    var childLoop = 0
    var childNormal = 0
    var mcp = 0
    var undecided = 0

    var sawParentLoop: Bool { parentLoop > 0 }
    var sawParentNormal: Bool { parentNormal > 0 }
    var sawChildLoop: Bool { childLoop > 0 }
    var sawChildNormal: Bool { childNormal > 0 }
    var sawMCP: Bool { mcp > 0 }
}

/// One scripted model decision, including the tool input that the Messages
/// wire would carry back as `tool_use.input`. The fixture-selection regression
/// uses the returned input verbatim to build the next request, so the result
/// stage is covered with the same `meta.name` + `script` shape as the wire.
struct CapabilityPlannedTurn {
    let text: String
    let toolName: String?
    let toolInput: [String: Any]?
}

private enum ScriptedPhase {
    case loop
    case normal
    case mcp
}

private struct ScriptedTurnPoint {
    let phase: ScriptedPhase
    let index: Int
    let text: String
}

private struct ScriptedTranscript {
    struct Use {
        let index: Int
        let id: String
        let name: String
        let input: [String: Any]
    }

    struct UserText {
        let index: Int
        let text: String
    }

    /// Every user text block in wire order. The last text alone is not the
    /// actual turn: DSH appends agent instructions, runtime context and the
    /// time context as later user text blocks.
    var userTextBlocks: [UserText] = []
    var uses: [Use] = []
    var results: [String: (text: String, isError: Bool)] = [:]
}

fileprivate struct ScriptedTurn {
    let text: String
    let toolName: String?
    let toolInput: [String: Any]?

    static func text(_ text: String) -> ScriptedTurn {
        ScriptedTurn(text: text, toolName: nil, toolInput: nil)
    }

    static func tool(_ name: String, _ input: [String: Any], text: String) -> ScriptedTurn {
        ScriptedTurn(text: text, toolName: name, toolInput: input)
    }
}

/// Scripted model upstream. It must be started before the host; `stop()` closes
/// the listener and every open connection.
final class CapabilityModelFixture: @unchecked Sendable {
    private let responder: ScriptedMessagesResponder
    private let server: CapabilityHTTPServer
    private(set) var baseURL: URL?

    init(mode: CapabilityModelMode) {
        let responder = ScriptedMessagesResponder(mode: mode)
        self.responder = responder
        self.server = CapabilityHTTPServer { request in responder.handle(request) }
    }

    @discardableResult
    func start() throws -> URL {
        let url = try server.start()
        baseURL = url
        return url
    }

    func stop() {
        server.stop()
    }

    var requestCount: Int { responder.requestCount }
    var observations: [CapabilityModelObservation] { responder.observations }
    /// Branches selected by the actual request bodies, for the acceptance
    /// report. Counts are per request (a turn issues more than one request).
    var selection: CapabilityModelSelection { responder.selection }
    /// Pure selection regression seam: runs the same transcript parser and
    /// branch decision as the HTTP handler against a real Messages body.
    func plannedToolName(for body: [String: Any]) -> String? {
        plannedTurn(for: body).toolName
    }

    /// Pure decision seam for both the tool-choice and result stages. The
    /// returned `toolInput` is the exact input the HTTP handler would emit, so
    /// a regression can feed it back as the next `tool_use` block.
    func plannedTurn(for body: [String: Any]) -> CapabilityPlannedTurn {
        let turn = responder.plannedTurn(for: body)
        return CapabilityPlannedTurn(text: turn.text, toolName: turn.toolName,
                                     toolInput: turn.toolInput)
    }
}

private final class ScriptedMessagesResponder: @unchecked Sendable {
    private let mode: CapabilityModelMode
    private let lock = NSLock()
    private var count = 0
    private var recorded: [CapabilityModelObservation] = []
    private var selectionStorage = CapabilityModelSelection()

    init(mode: CapabilityModelMode) {
        self.mode = mode
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    var observations: [CapabilityModelObservation] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var selection: CapabilityModelSelection {
        lock.lock()
        defer { lock.unlock() }
        return selectionStorage
    }

    /// Parses the same Messages body the HTTP handler receives and returns the
    /// scripted decision. Used only by the fixture-selection regression; it does
    /// not touch the network or the Worker.
    fileprivate func plannedTurn(for body: [String: Any]) -> ScriptedTurn {
        decide(Self.transcript(body))
    }

    private func record(_ phase: ScriptedPhase) {
        lock.lock()
        defer { lock.unlock() }
        switch phase {
        case .loop: selectionStorage.parentLoop += 1
        case .normal: selectionStorage.parentNormal += 1
        case .mcp: selectionStorage.mcp += 1
        }
    }

    private func recordChild(_ phase: ScriptedPhase) {
        lock.lock()
        defer { lock.unlock() }
        switch phase {
        case .loop: selectionStorage.childLoop += 1
        case .normal: selectionStorage.childNormal += 1
        case .mcp: break
        }
    }

    private func recordUndecided() {
        lock.lock()
        defer { lock.unlock() }
        selectionStorage.undecided += 1
    }

    func handle(_ request: CapabilityHTTPRequest) -> CapabilityHTTPResponse {
        guard request.method == "POST", request.path.hasSuffix("/v1/messages") else {
            return .json(["error": ["type": "not_found_error", "message": "no route"]],
                         status: 404)
        }
        guard let object = try? JSONSerialization.jsonObject(with: request.body),
              let body = object as? [String: Any] else {
            return .json(["error": ["type": "invalid_request_error", "message": "invalid JSON"]],
                         status: 400)
        }
        lock.lock()
        count += 1
        let number = count
        recorded.append(CapabilityModelObservation(
            method: request.method,
            path: request.path,
            apiKey: request.headers["x-api-key"],
            body: request.body))
        lock.unlock()

        let model = body["model"] as? String ?? "deepseek-flash"
        let transcript = Self.transcript(body)
        let turn = decide(transcript)
        let sse = sseBody(turn: turn, model: model, number: number)
        return CapabilityHTTPResponse(status: 200,
                                      headers: ["Content-Type": "text/event-stream",
                                                "Cache-Control": "no-cache"],
                                      body: sse)
    }

    // MARK: Script

    private func decide(_ transcript: ScriptedTranscript) -> ScriptedTurn {
        switch mode {
        case .workflow(let nonce):
            return decideWorkflow(transcript, nonce: nonce)
        case .mcp(let nonce, let toolName, let message):
            return decideMCP(transcript, nonce: nonce, toolName: toolName, message: message)
        }
    }

    private func decideWorkflow(_ transcript: ScriptedTranscript,
                                nonce: String) -> ScriptedTurn {
        // A child Agent request carries its own unique child marker. Check it
        // before the parent phase markers so a child can never inherit the
        // parent's loop choice from the surrounding history.
        if let child = childTurn(transcript, nonce: nonce) {
            recordChild(child.phase)
            let isLoopChild = child.phase == .loop
            let prompt = child.text
            let active = transcript.uses.filter { $0.index > child.index }
            let last = active.last
            let result = last.flatMap { transcript.results[$0.id] }
            let file = isLoopChild ? "loop-start-\(nonce).txt" : "workflow-\(nonce).txt"
            let fileText = isLoopChild ? "LOOP_STARTED_\(nonce)" : "WORKFLOW_FILE_OK_\(nonce)"
            if last?.name == "bash", result != nil {
                let checks = Self.escapeChecks(in: prompt)
                let finalText = isLoopChild ? "LOOP_CHILD_OK_\(nonce)" : "WORKFLOW_BASH_OK_\(nonce)"
                return .text("\(finalText) ESCAPE[\(checks)]")
            }
            let command = "printf '\(fileText)\\n' > \(file) && cat \(file)"
            return .tool("bash", [
                "command": command,
                "description": "Write and read \(file) through the real Worker shell",
            ], text: "I will write and read \(file) with the real bash tool.")
        }

        // The actual user turn is the message that carries this run's explicit
        // phase marker. Agent instructions may mention "loop", and the time
        // context is the last user text; neither is the user instruction.
        guard let turn = parentTurn(transcript, nonce: nonce),
              turn.phase == .loop || turn.phase == .normal else {
            recordUndecided()
            return .text("Waiting for the current user instruction.")
        }
        record(turn.phase)
        let active = transcript.uses.filter { $0.index > turn.index }
        let last = active.last
        let result = last.flatMap { transcript.results[$0.id] }

        if last == nil {
            if turn.phase == .loop {
                let name = "worker-loop-\(nonce)"
                let loopFile = "loop-start-\(nonce).txt"
                let loopChildMarker = "WORKFLOW_CHILD_LOOP_\(nonce)"
                let loopScript = """
                const started = await agent('\(loopChildMarker): write \(loopFile) with the real bash tool', { label: 'loop-child-\(nonce)' });
                while (true) {}
                """
                return .tool("workflow", [
                    "meta": [
                        "name": name,
                        "description": "Synchronous loop that the workflow deadline must terminate",
                    ],
                    "run_in_background": false,
                    "script": loopScript,
                ], text: "I will run the synchronous loop workflow.")
            }
            let name = "worker-bash-probe-\(nonce)"
            let normalChildMarker = "WORKFLOW_CHILD_NORMAL_\(nonce)"
            let file = "workflow-\(nonce).txt"
            let script = """
            const g = ({}).constructor.constructor('return globalThis')();
            const parentEnvSentinel = (typeof g.process === 'object' && g.process !== null && g.process.env)
              ? (g.process.env.PDSH_PARENT_SENTINEL === 'dummy-parent-sentinel-\(nonce)' ? 'visible' : 'missing')
              : 'undefined';
            const escapeChecks = [
              'globalObject=' + (g.Object === Object && g.Math === Math),
              'parentEnvSentinel=' + parentEnvSentinel,
              'parentToken=' + typeof g.__PDSH_CHANNEL__,
              'moduleLoader=' + typeof g.__PDSH_MODULE_LOADER__,
              'vfs=' + typeof g.__PDSH_VFS_FLUSH__,
              'process=' + typeof g.process,
              'fetch=' + typeof g.fetch,
              'worker=' + typeof g.Worker,
            ].join(',');
            const child = await agent('\(normalChildMarker): write and read \(file) with the real bash tool. ESCAPE[' + escapeChecks + ']', { label: 'bash-child-\(nonce)' });
            return 'ESCAPE[' + escapeChecks + ']CHILD[' + child + ']';
            """
            return .tool("workflow", [
                "meta": [
                    "name": name,
                    "description": "Run a child agent that uses the real Worker bash and VFS",
                ],
                "run_in_background": false,
                "script": script,
            ], text: "I will run a workflow whose child uses the real bash tool.")
        }

        if last?.name == "workflow", result != nil {
            // The workflow name is carried in `tool_use.input.meta.name`; the
            // script body itself contains only the child marker. Do not look
            // for the workflow name inside `script`: it was never there, so
            // every result used to fall through to "Waiting" (the loop only
            // appeared settled because of `hasTurnEnded`, while the normal run
            // never produced WORKFLOW_DONE).
            let meta = last?.input["meta"] as? [String: Any]
            let name = meta?["name"] as? String ?? ""
            let script = last?.input["script"] as? String ?? ""
            let isLoop = name == "worker-loop-\(nonce)"
                || script.contains("WORKFLOW_CHILD_LOOP_\(nonce)")
            let isNormal = name == "worker-bash-probe-\(nonce)"
                || script.contains("WORKFLOW_CHILD_NORMAL_\(nonce)")
            if isLoop {
                return .text("LOOP_TERMINATED_\(nonce)")
            }
            if isNormal {
                return .text("WORKFLOW_DONE_\(nonce)")
            }
        }
        return .text("Waiting for the workflow tool result.")
    }

    private func decideMCP(_ transcript: ScriptedTranscript, nonce: String,
                           toolName: String, message: String) -> ScriptedTurn {
        guard let turn = parentTurn(transcript, nonce: nonce),
              turn.phase == .mcp else {
            recordUndecided()
            return .text("Waiting for the current MCP user instruction.")
        }
        record(.mcp)
        let active = transcript.uses.filter { $0.index > turn.index }
        let last = active.last
        let result = last.flatMap { transcript.results[$0.id] }
        if last == nil {
            return .tool(toolName, ["message": message],
                         text: "I will call the registered MCP echo tool.")
        }
        if last?.name == toolName, result != nil {
            return .text("MCP_DONE_\(nonce)")
        }
        return .text("Waiting for the MCP tool result.")
    }

    /// The parent turn is the last user text carrying one of this run's
    /// explicit phase markers. This ignores agent instructions, runtime
    /// context and the trailing time context even when they mention `loop`.
    private func parentTurn(_ transcript: ScriptedTranscript,
                            nonce: String) -> ScriptedTurnPoint? {
        let markers: [(String, ScriptedPhase)] = [
            ("PDSH_PHASE_LOOP_\(nonce)", .loop),
            ("PDSH_PHASE_NORMAL_\(nonce)", .normal),
            ("PDSH_PHASE_MCP_\(nonce)", .mcp),
        ]
        var selected: ScriptedTurnPoint?
        for block in transcript.userTextBlocks {
            for (marker, phase) in markers where block.text.contains(marker) {
                selected = ScriptedTurnPoint(phase: phase, index: block.index, text: block.text)
            }
        }
        return selected
    }

    /// Child requests carry a distinct marker for each branch, so a normal
    /// child cannot be mistaken for the loop child (or for the parent loop).
    private func childTurn(_ transcript: ScriptedTranscript,
                           nonce: String) -> ScriptedTurnPoint? {
        let loopMarker = "WORKFLOW_CHILD_LOOP_\(nonce)"
        let normalMarker = "WORKFLOW_CHILD_NORMAL_\(nonce)"
        var selected: ScriptedTurnPoint?
        for block in transcript.userTextBlocks {
            if block.text.contains(loopMarker) {
                selected = ScriptedTurnPoint(phase: .loop, index: block.index, text: block.text)
            } else if block.text.contains(normalMarker) {
                selected = ScriptedTurnPoint(phase: .normal, index: block.index, text: block.text)
            }
        }
        return selected
    }

    // MARK: Transcript

    private static func transcript(_ body: [String: Any]) -> ScriptedTranscript {
        var value = ScriptedTranscript()
        guard let messages = body["messages"] as? [[String: Any]] else { return value }
        for (index, message) in messages.enumerated() {
            let role = message["role"] as? String ?? ""
            if let content = message["content"] as? String {
                if role == "user", !content.isEmpty {
                    value.userTextBlocks.append(.init(index: index, text: content))
                }
                continue
            }
            guard let blocks = message["content"] as? [[String: Any]] else { continue }
            for block in blocks {
                switch block["type"] as? String ?? "" {
                case "text":
                    guard role == "user", let text = block["text"] as? String,
                          !text.isEmpty else { continue }
                    value.userTextBlocks.append(.init(index: index, text: text))
                case "tool_use":
                    guard let id = block["id"] as? String,
                          let name = block["name"] as? String else { continue }
                    let input = block["input"] as? [String: Any] ?? [:]
                    value.uses.append(ScriptedTranscript.Use(index: index, id: id,
                                                            name: name, input: input))
                case "tool_result":
                    guard let id = block["tool_use_id"] as? String else { continue }
                    value.results[id] = (
                        text: contentText(block["content"]),
                        isError: block["is_error"] as? Bool ?? false)
                default:
                    break
                }
            }
        }
        return value
    }

    private static func escapeChecks(in text: String) -> String {
        guard let start = text.range(of: "ESCAPE[") else { return "" }
        guard let end = text.range(of: "]", range: start.upperBound..<text.endIndex) else {
            return ""
        }
        return String(text[start.upperBound..<end.lowerBound])
    }

    private static func contentText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined()
    }

    // MARK: SSE

    private func sseBody(turn: ScriptedTurn, model: String, number: Int) -> Data {
        var output = ""
        func emit(_ event: String, _ payload: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                         options: [.sortedKeys]) else { return }
            output += "event: \(event)\n"
            output += "data: \(String(decoding: data, as: UTF8.self))\n\n"
        }
        let messageID = "msg_capability_\(number)"
        emit("message_start", [
            "type": "message_start",
            "message": [
                "id": messageID,
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
            "delta": ["type": "text_delta", "text": turn.text],
        ])
        emit("content_block_stop", ["type": "content_block_stop", "index": 0])
        if let name = turn.toolName, let input = turn.toolInput {
            let inputJSON = (try? JSONSerialization.data(withJSONObject: input,
                                                         options: [.sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            emit("content_block_start", [
                "type": "content_block_start",
                "index": 1,
                "content_block": [
                    "type": "tool_use",
                    "id": "toolu_capability_\(number)",
                    "name": name,
                    "input": [:] as [String: Any],
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
            "delta": ["stop_reason": turn.toolName == nil ? "end_turn" : "tool_use"],
            "usage": ["output_tokens": 24],
        ])
        emit("message_stop", ["type": "message_stop"])
        return Data(output.utf8)
    }
}

// MARK: - Streamable HTTP MCP fixture

/// One observed MCP JSON-RPC request (headers stay internal; the bearer value
/// is never exposed by this type).
private struct McpRequestObservation {
    let method: String
    let params: Any?
}

/// Local Streamable HTTP MCP fixture with two *different* dummy bearers:
/// one only in the Worker environment (`headersFromEnv`) and one only in the
/// host `/mcp` credential. Every method except the CORS `OPTIONS` preflight
/// (POST, GET/SSE and DELETE) accepts only the host value; an Authorization
/// carrying the env-only value or the model-gateway key is recorded as
/// forbidden and rejected with 401. A Worker that bypassed host `/v1/http`
/// egress could therefore not authenticate, and a session DELETE cannot bypass
/// the same gate.
final class CapabilityMcpFixture: @unchecked Sendable {
    private let responder: McpResponder
    private let server: CapabilityHTTPServer
    private(set) var url: URL?

    init(nonce: String, forbiddenAuthorization: String? = nil) {
        let responder = McpResponder(hostToken: "pdsh-host-\(nonce)",
                                     envToken: "pdsh-env-\(nonce)",
                                     sessionID: "mcp-session-\(nonce)",
                                     forbiddenAuthorization: forbiddenAuthorization)
        self.responder = responder
        self.server = CapabilityHTTPServer { request in responder.handle(request) }
    }

    @discardableResult
    func start() throws -> URL {
        let base = try server.start()
        let endpoint = base.appendingPathComponent("mcp")
        url = endpoint
        return endpoint
    }

    func stop() {
        server.stop()
    }

    /// Host-free regression seam: routes one request through the same responder
    /// the loopback listener uses, without starting a socket or a Worker.
    func handle(_ request: CapabilityHTTPRequest) -> CapabilityHTTPResponse {
        responder.handle(request)
    }

    /// Dummy value written into the Worker's process environment for the
    /// `headersFromEnv` row. It is a test token, not a real credential, and is
    /// never added to a report. It deliberately differs from the host `/mcp`
    /// credential so a direct Worker fetch cannot authenticate.
    var authorizationValue: String { "Bearer \(responder.envTokenValue)" }
    /// Bare env-only dummy, used by the test's redactor and forbidden check.
    var environmentTokenValue: String { responder.envTokenValue }
    /// Bare host `/mcp` credential value; `Credential.apply` sends it as
    /// `Bearer <value>`.
    var tokenValue: String { responder.hostTokenValue }
    /// Authorization header the host egress path must inject.
    var hostAuthorizationValue: String { "Bearer \(responder.hostTokenValue)" }

    var requestMethods: [String] { responder.requestMethods }
    var toolCalls: [(name: String, message: String)] { responder.toolCalls }
    var authenticatedRequestCount: Int { responder.authenticatedRequestCount }
    /// Authenticated HTTP `DELETE` requests. A remote Streamable HTTP session
    /// is only proven terminated when this count is greater than zero; the
    /// remove row records that fact explicitly instead of inferring it from the
    /// local registry.
    var authenticatedDeleteCount: Int { responder.authenticatedDeleteCount }
    /// Every HTTP DELETE that reached the fixture, authenticated or not.
    var deleteRequestCount: Int { responder.deleteRequestCount }
    var sawUnauthenticatedDelete: Bool { responder.sawUnauthenticatedDelete }
    var sawUnauthenticatedGet: Bool { responder.sawUnauthenticatedGet }
    var sawForbiddenAuthorization: Bool { responder.sawForbiddenAuthorization }
    var sawEnvOnlyAuthorization: Bool { responder.sawEnvOnlyAuthorization }
}

private enum UnauthorizedCredential {
    case forbidden
    case envOnly
    case missing
}

private final class McpResponder: @unchecked Sendable {
    private let hostTokenValueStorage: String
    private let envTokenValueStorage: String
    private let expectedAuthorization: String
    private let sessionID: String
    private let forbiddenAuthorization: String?
    private let lock = NSLock()
    private var methods: [String] = []
    private var calls: [(name: String, message: String)] = []
    private var authenticated = 0
    private var authenticatedDeletes = 0
    private var deleteRequests = 0
    private var unauthenticatedDeleteSeen = false
    private var unauthenticatedGetSeen = false
    private var forbiddenSeen = false
    private var envOnlySeen = false

    init(hostToken: String, envToken: String, sessionID: String,
         forbiddenAuthorization: String?) {
        self.hostTokenValueStorage = hostToken
        self.envTokenValueStorage = envToken
        self.expectedAuthorization = "Bearer \(hostToken)"
        self.sessionID = sessionID
        self.forbiddenAuthorization = forbiddenAuthorization
    }

    var hostTokenValue: String { hostTokenValueStorage }
    var envTokenValue: String { envTokenValueStorage }

    var requestMethods: [String] {
        lock.lock()
        defer { lock.unlock() }
        return methods
    }

    var toolCalls: [(name: String, message: String)] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var authenticatedRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return authenticated
    }

    var authenticatedDeleteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return authenticatedDeletes
    }

    var deleteRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return deleteRequests
    }

    var sawUnauthenticatedDelete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return unauthenticatedDeleteSeen
    }

    var sawUnauthenticatedGet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return unauthenticatedGetSeen
    }

    var sawForbiddenAuthorization: Bool {
        lock.lock()
        defer { lock.unlock() }
        return forbiddenSeen
    }

    var sawEnvOnlyAuthorization: Bool {
        lock.lock()
        defer { lock.unlock() }
        return envOnlySeen
    }

    func handle(_ request: CapabilityHTTPRequest) -> CapabilityHTTPResponse {
        // A CORS preflight carries no credential by design; every other method
        // (including the Streamable HTTP GET/SSE and DELETE session operations)
        // goes through the same credential gate as POST. OPTIONS is the only
        // method allowed to skip it.
        if request.method == "OPTIONS" {
            return CapabilityHTTPResponse(status: 204, headers: [:], body: Data())
        }
        guard request.method == "POST" || request.method == "GET"
                || request.method == "DELETE" else {
            return .text("", status: 405, extraHeaders: ["Allow": "POST, GET, DELETE"])
        }
        if request.method == "DELETE" {
            lock.lock()
            deleteRequests += 1
            lock.unlock()
        }
        let authorization = request.headers["authorization"] ?? ""
        // Duplicate Authorization lines are joined by the HTTP parser with
        // ", ". Evaluate every value: a request that carries the host value
        // *and* the Worker-known env value must still be rejected, and the env
        // value must be recorded rather than hidden by the host value.
        let authorizationValues = authorization
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        func bare(_ value: String) -> String {
            value.hasPrefix("Bearer ") ? String(value.dropFirst("Bearer ".count)) : value
        }
        func reject(_ kind: UnauthorizedCredential) -> CapabilityHTTPResponse {
            lock.lock()
            switch kind {
            case .forbidden: forbiddenSeen = true
            case .envOnly: envOnlySeen = true
            case .missing: break
            }
            if request.method == "DELETE" { unauthenticatedDeleteSeen = true }
            if request.method == "GET" { unauthenticatedGetSeen = true }
            lock.unlock()
            return .text("", status: 401)
        }
        if let forbiddenAuthorization {
            let bareKey = bare(forbiddenAuthorization)
            if authorizationValues.contains(where: { value in
                value == forbiddenAuthorization || bare(value) == bareKey
            }) || request.headers["x-api-key"] == bareKey {
                return reject(.forbidden)
            }
        }
        // The env-only token is the value the Worker *does* know. It is a
        // forbidden credential: seeing it here means the request bypassed the
        // host `/v1/http` egress credential injection (or the injected header
        // was overwritten), so record it and reject instead of accepting it.
        if authorizationValues.contains(where: { value in
            value == "Bearer \(envTokenValueStorage)" || bare(value) == envTokenValueStorage
        }) || request.headers["x-api-key"] == envTokenValueStorage {
            return reject(.envOnly)
        }
        guard !authorizationValues.isEmpty,
              authorizationValues.allSatisfy({ $0 == expectedAuthorization }) else {
            return reject(.missing)
        }
        lock.lock()
        authenticated += 1
        let isDelete = request.method == "DELETE"
        if isDelete { authenticatedDeletes += 1 }
        lock.unlock()

        if request.method == "GET" {
            // An authenticated GET reached the server but this fixture has no
            // SSE stream. It is still an authenticated method: the count above
            // proves it carried the host credential. Unauthenticated GET is
            // rejected by the gate before this branch.
            return .text("", status: 405, extraHeaders: ["Allow": "POST, DELETE"])
        }
        if isDelete {
            return .text("", status: 200, extraHeaders: ["mcp-session-id": sessionID])
        }

        guard let parsed = try? JSONSerialization.jsonObject(with: request.body) else {
            return .json(["error": "invalid JSON"], status: 400,
                         extraHeaders: ["mcp-session-id": sessionID])
        }
        let batch = parsed as? [Any]
        let messages = batch ?? [parsed]
        var replies: [Any] = []
        for case let message as [String: Any] in messages {
            let method = message["method"] as? String
            if let method {
                lock.lock()
                methods.append(method)
                lock.unlock()
            }
            if let reply = answer(message) {
                replies.append(reply)
            }
        }
        let headers = ["mcp-session-id": sessionID]
        if replies.isEmpty {
            return .text("", status: 202, extraHeaders: headers)
        }
        if batch != nil {
            return .json(replies, extraHeaders: headers)
        }
        return .json(replies[0], extraHeaders: headers)
    }

    private func answer(_ message: [String: Any]) -> Any? {
        guard let id = message["id"] else { return nil }
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let versions = ["2025-11-25", "2025-06-18", "2025-03-26"]
            let requested = params["protocolVersion"] as? String ?? ""
            let chosen = versions.contains(requested) ? requested : versions[0]
            return reply(id: id, result: [
                "protocolVersion": chosen,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "phone-mcp-fixture", "version": "0.1.0"],
            ])
        case "ping":
            return reply(id: id, result: [String: Any]())
        case "tools/list":
            return reply(id: id, result: ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let text = arguments["message"] as? String ?? ""
            lock.lock()
            calls.append((name: name, message: text))
            lock.unlock()
            if name == "ping" {
                return reply(id: id, result: [
                    "content": [["type": "text", "text": "pong"]],
                ])
            }
            if name == "echo" {
                return reply(id: id, result: [
                    "content": [["type": "text", "text": "echo:\(text)"]],
                ])
            }
            return failure(id: id, code: -32602, message: "unknown tool: \(name)")
        default:
            return failure(id: id, code: -32601,
                           message: "method not found: \(method)")
        }
    }

    private func reply(id: Any, result: Any) -> Any {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func failure(id: Any, code: Int, message: String) -> Any {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static let tools: [[String: Any]] = [
        [
            "name": "ping",
            "description": "Return a fixed pong value.",
            "inputSchema": [
                "type": "object",
                "properties": [:] as [String: Any],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "echo",
            "description": "Echo a caller-provided message.",
            "inputSchema": [
                "type": "object",
                "properties": ["message": ["type": "string"]],
                "required": ["message"],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": true],
        ],
    ]
}
