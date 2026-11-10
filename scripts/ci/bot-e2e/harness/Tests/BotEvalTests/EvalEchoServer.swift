// SPDX-License-Identifier: MIT
// phone-dsh Bot eval runner — loopback echo fixture for egress assertions.
//
// The server binds 127.0.0.1 only. Scenarios that need it put the reserved
// entry `echo` in `network.allow`; the runner replaces that entry with the
// actual loopback host:port and substitutes `${ECHO_URL}` / `${ECHO_HOST}` in
// scenario strings. The recorded requests feed the `echo_requests` assertion,
// so a scenario can prove an allowed egress request arrived (or that none did).

import Foundation
import Network
import PhoneDSHAgentCore

/// One request the loopback echo fixture accepted.
struct EvalEchoRequest: Sendable, Equatable {
    var method: String
    var path: String
}

/// Minimal loopback HTTP/1.1 server used as an outbound-egress target.
final class EvalEchoServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "pdsh.bot-eval.echo")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var recorded: [EvalEchoRequest] = []
    private var stopping = false
    private(set) var port: UInt16 = 0

    /// `http://127.0.0.1:<port>` (no trailing slash) for scenario placeholders.
    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    /// Requests accepted so far, in arrival order.
    var requests: [EvalEchoRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Starts on an ephemeral port bound to the IPv4 loopback address only.
    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
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
            throw EvalEchoError.startTimedOut
        }
        if let startError {
            listener.cancel()
            throw EvalEchoError.listenerFailed(String(describing: startError))
        }
        guard let rawPort = listener.port?.rawValue, rawPort != 0 else {
            listener.cancel()
            throw EvalEchoError.listenerFailed("the listener bound no port")
        }
        self.listener = listener
        self.port = rawPort
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

    // MARK: - HTTP

    private struct Request {
        var method: String
        var path: String
        var body: Data
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
                self.record(request)
                self.send(connection, status: 200,
                          body: Data(#"{"ok":true}"#.utf8))
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

    private func record(_ request: Request) {
        lock.lock()
        recorded.append(EvalEchoRequest(method: request.method, path: request.path))
        lock.unlock()
    }

    private func send(_ connection: NWConnection, status: Int, body: Data) {
        let reason = status == 200 ? "OK" : "Not Found"
        let head = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var message = Data(head.utf8)
        message.append(body)
        connection.send(content: message, completion: .contentProcessed { [weak self] _ in
            self?.forget(connection)
            connection.cancel()
        })
    }

    /// Parses one complete request; `nil` means "more bytes are needed".
    private static func parse(_ data: Data) -> Request? {
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
            if !name.isEmpty { headers[name] = value }
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.count >= bodyStart + length else { return nil }
        return Request(
            method: String(parts[0]).uppercased(),
            path: String(parts[1]),
            body: data.subdata(in: bodyStart..<(bodyStart + length)))
    }
}

enum EvalEchoError: LocalizedError {
    case startTimedOut
    case listenerFailed(String)

    var errorDescription: String? {
        switch self {
        case .startTimedOut: return "loopback echo fixture did not become ready"
        case .listenerFailed(let detail): return "loopback echo fixture failed: \(detail)"
        }
    }
}

// MARK: - Scenario placeholder substitution

extension EvalScenario {
    /// Resolves the reserved `echo` allow-list entry and `${ECHO_URL}` /
    /// `${ECHO_HOST}` placeholders against this repeat's echo fixture.
    func resolvingEchoFixture(_ echo: EvalEchoServer) -> EvalScenario {
        let url = echo.baseURL.absoluteString
        let host = "127.0.0.1:\(echo.port)"
        func resolve(_ text: String) -> String {
            text
                .replacingOccurrences(of: "${ECHO_URL}", with: url)
                .replacingOccurrences(of: "${ECHO_HOST}", with: host)
        }
        func resolveMock(_ mock: EvalMock?) -> EvalMock? {
            guard var mock else { return nil }
            if var tool = mock.tool {
                tool.name = resolve(tool.name)
                tool.arguments = tool.arguments.substitutingEchoPlaceholders(resolve)
                mock.tool = tool
            }
            if let tools = mock.tools {
                mock.tools = tools.map { tool in
                    var tool = tool
                    tool.name = resolve(tool.name)
                    tool.arguments = tool.arguments.substitutingEchoPlaceholders(resolve)
                    return tool
                }
            }
            if let rules = mock.promptRules {
                mock.promptRules = rules.map { rule in
                    var rule = rule
                    rule.contains = resolve(rule.contains)
                    rule.finalText = resolve(rule.finalText)
                    return rule
                }
            }
            mock.finalText = mock.finalText.map(resolve)
            return mock
        }

        var scenario = self
        scenario.workspace.files = scenario.workspace.files.mapValues(resolve)
        scenario.network.allow = scenario.network.allow.map { entry in
            entry == "echo" ? host : resolve(entry)
        }
        scenario.mock = resolveMock(scenario.mock)
        scenario.actions = scenario.actions.map { action in
            var action = action
            action.text = action.text.map(resolve)
            action.name = action.name.map(resolve)
            action.description = action.description.map(resolve)
            action.alias = action.alias.map(resolve)
            action.kind = action.kind.map(resolve)
            action.card = action.card.map(resolve)
            action.cardID = action.cardID.map(resolve)
            action.optionID = action.optionID.map(resolve)
            action.approval = action.approval.map(resolve)
            action.approvalID = action.approvalID.map(resolve)
            action.decision = action.decision.map(resolve)
            action.digest = action.digest.map(resolve)
            action.factContains = action.factContains.map(resolve)
            action.factID = action.factID.map(resolve)
            action.taskID = action.taskID.map(resolve)
            action.threadID = action.threadID.map(resolve)
            action.title = action.title.map(resolve)
            action.fromAgentID = action.fromAgentID.map(resolve)
            action.fromAgentName = action.fromAgentName.map(resolve)
            action.requestID = action.requestID.map(resolve)
            action.mode = action.mode.map(resolve)
            action.perturbation = action.perturbation.map(resolve)
            action.degraded = action.degraded.map(resolve)
            action.mock = resolveMock(action.mock)
            return action
        }
        scenario.assertions = scenario.assertions.map { assertion in
            var assertion = assertion
            assertion.value = assertion.value.map(resolve)
            assertion.path = assertion.path.map(resolve)
            assertion.command = assertion.command.map(resolve)
            assertion.event = assertion.event.map(resolve)
            assertion.name = assertion.name.map(resolve)
            assertion.argumentsContains = assertion.argumentsContains.map(resolve)
            assertion.payloadContains = assertion.payloadContains.map(resolve)
            assertion.scope = assertion.scope.map(resolve)
            assertion.tier = assertion.tier.map(resolve)
            assertion.source = assertion.source.map(resolve)
            assertion.method = assertion.method.map(resolve)
            return assertion
        }
        return scenario
    }
}

extension JSONValue {
    func substitutingEchoPlaceholders(_ resolve: (String) -> String) -> JSONValue {
        switch self {
        case .string(let value): return .string(resolve(value))
        case .array(let values): return .array(values.map { $0.substitutingEchoPlaceholders(resolve) })
        case .object(let values):
            return .object(values.mapValues { $0.substitutingEchoPlaceholders(resolve) })
        case .null, .bool, .number:
            return self
        }
    }
}
