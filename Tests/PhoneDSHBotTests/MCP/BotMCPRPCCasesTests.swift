// SPDX-License-Identifier: MIT

import Foundation
import Network
import XCTest
@testable import PhoneDSHBot

/// D13 JSON-RPC contract: every case comes from
/// `spec/bot/v1/golden/mcp-rpc-cases.phone.json`; the real `BotMCPHandler`
/// and `BotMCPHTTPServer` execute it.
final class BotMCPRPCCasesTests: XCTestCase {
    private var fixture: BotMCPTestFixture!
    private var handler: BotMCPHandler!
    private var server: BotMCPHTTPServer!
    private var url: URL!
    private var vector: [String: Any] = [:]

    override func setUp() async throws {
        vector = try BotContractFixture.object("mcp-rpc-cases.phone")
        fixture = try makeBotMCPFixture()
        handler = BotMCPHandler(runtime: fixture.runtime)
        await handler.attachNativeMCP(ContractNativeForwarder())
        await fixture.runtime.setToolCatalogProvider { caller in
            var definitions = BotToolCatalog.allDefinitions
            if caller == "restricted" {
                definitions.removeAll { $0.name == BotToolCatalog.createTeammateName }
            }
            return definitions
        }
        server = BotMCPHTTPServer(handler: handler, token: "rpc-contract-token")
        url = try await server.start()
    }

    override func tearDownWithError() throws {
        server?.stop()
        fixture?.cleanup()
    }

    func testMCPContractFixtureMetadata() throws {
        XCTAssertEqual(vector["vector"] as? String, "mcp-rpc-cases.phone")
        XCTAssertEqual(vector["upstream"] as? [String], [])
        XCTAssertEqual(vector["maximumBodyBytes"] as? Int, BotMCPHTTPServer.maximumBodyBytes)
        XCTAssertEqual(vector["protocolVersions"] as? [String], BotMCPHandler.protocolVersions)
        let valid = try BotContractFixture.array(vector["valid"], "valid")
        let invalid = try BotContractFixture.array(vector["invalid"], "invalid")
        XCTAssertFalse(valid.isEmpty)
        XCTAssertFalse(invalid.isEmpty)
    }

    func testMCPRPCValidCasesDriveRealHandlerAndListener() async throws {
        let cases = try BotContractFixture.array(vector["valid"], "valid")
        for (index, object) in cases.enumerated() {
            let label = "valid[\(index)] " + ((object["name"] as? String) ?? "?")
            let transport = try BotContractFixture.string(object["transport"], "\(label).transport")
            switch transport {
            case "single":
                try await runSingle(object, label: label)
            case "batch":
                try await runBatch(object, label: label)
            case "notification":
                try await runNotification(object, label: label)
            default:
                XCTFail("\(label): unsupported transport \(transport)")
            }
        }
    }

    func testMCPRPCInvalidCasesDriveRealListener() async throws {
        let cases = try BotContractFixture.array(vector["invalid"], "invalid")
        for (index, object) in cases.enumerated() {
            let label = "invalid[\(index)] " + ((object["name"] as? String) ?? "?")
            let transport = try BotContractFixture.string(object["transport"], "\(label).transport")
            switch transport {
            case "single":
                let request = try BotContractFixture.object(object["request"], "\(label).request")
                let reply = await rpc(request)
                let expected = try BotContractFixture.object(object["expect"], "\(label).expect")
                if let error = expected["error"] {
                    BotContractFixture.assertError(reply, try BotContractFixture.json(error), label)
                } else {
                    XCTFail("\(label): single invalid case needs an error expectation")
                }
            case "batch":
                try await runBatch(object, label: label)
            case "http":
                do {
                    try await runHTTP(object, label: label)
                } catch {
                    XCTFail("\(label): \(error)")
                }
            default:
                XCTFail("\(label): unsupported transport \(transport)")
            }
        }
    }

    // MARK: - transports

    private func runSingle(_ object: [String: Any], label: String) async throws {
        let request = try BotContractFixture.object(object["request"], "\(label).request")
        var headers: [String: String] = [:]
        if let caller = object["caller"] as? [String: Any] {
            let token = try await issue(caller, label: label)
            headers[BotMCPHandler.callerSessionHeader] =
                try BotContractFixture.string(caller["sessionId"], "\(label).caller.sessionId")
            if let registration = object["registration"] as? [String: Any] {
                try await register(registration, token: token, headers: headers, label: label)
            }
        }
        if let expectedHeaders = object["headers"] as? [String: Any] {
            for (key, value) in expectedHeaders {
                headers[key] = try BotContractFixture.string(value, "\(label).headers.\(key)")
            }
        }
        let reply = await rpc(request, headers: headers)
        let expect = try BotContractFixture.object(object["expect"], "\(label).expect")
        if let error = expect["error"] {
            BotContractFixture.assertError(reply, try BotContractFixture.json(error), label)
            return
        }
        if let toolList = expect["toolList"] {
            try assertToolList(reply, expectation: toolList, label: label)
        }
        if let result = expect["result"] {
            guard case .object(let fields) = reply, let actual = fields["result"] else {
                XCTFail("\(label): missing result: \(reply)")
                return
            }
            BotContractFixture.assertSubset(actual, try BotContractFixture.json(result), label)
            if let flags = expect["flags"] as? [String: Any] {
                if flags["isErrorAbsent"] as? Bool == true {
                    XCTAssertNil(actual["isError"], "\(label): success must omit isError")
                }
                if flags["contentTextJSON"] as? Bool == true {
                    let text = actual["content"]?.arrayValue?.first?["text"]?.stringValue
                    let parsed = text.flatMap { try? BotJSONValue.parse(Data($0.utf8)) }
                    XCTAssertEqual(parsed, actual["structuredContent"], "\(label): content text must be the canonical JSON of structuredContent")
                }
            }
        }
    }

    private func runBatch(_ object: [String: Any], label: String) async throws {
        let messages = object["messages"] as? [Any] ?? []
        let body = try JSONSerialization.data(withJSONObject: messages, options: [.sortedKeys])
        let response = try await send(url, method: "POST", body: body,
                                      token: server.token)
        let expect = try BotContractFixture.object(object["expect"], "\(label).expect")
        XCTAssertEqual(response.status,
                       try BotContractFixture.int(expect["status"], "\(label).expect.status"), label)
        if let error = expect["error"] as? String {
            XCTAssertEqual(response.json?["error"]?.stringValue, error, label)
            return
        }
        if expect["empty"] as? Bool == true {
            XCTAssertTrue(response.data.isEmpty, "\(label): expected an empty body")
            return
        }
        let replies = response.json?.arrayValue ?? []
        XCTAssertEqual(replies.count,
                       try BotContractFixture.int(expect["replyCount"], "\(label).expect.replyCount"), label)
        if let ids = expect["ids"] as? [Any] {
            XCTAssertEqual(replies.compactMap { $0["id"]?.numberValue.map(Int.init) },
                           ids.compactMap { ($0 as? NSNumber)?.intValue }, label)
        }
        if let first = expect["firstResult"] {
            BotContractFixture.assertSubset(replies[0]["result"] ?? .null,
                                            try BotContractFixture.json(first), "\(label).firstResult")
        }
    }

    private func runNotification(_ object: [String: Any], label: String) async throws {
        let message = try BotContractFixture.object(object["message"], "\(label).message")
        let body = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        let response = try await send(url, method: "POST", body: body, token: server.token)
        let expect = try BotContractFixture.object(object["expect"], "\(label).expect")
        XCTAssertEqual(response.status,
                       try BotContractFixture.int(expect["status"], "\(label).expect.status"), label)
        XCTAssertTrue(response.data.isEmpty, "\(label): notification-only must have an empty body")
    }

    private func runHTTP(_ object: [String: Any], label: String) async throws {
        let http = try BotContractFixture.object(object["http"], "\(label).http")
        let path = (http["path"] as? String) ?? "/mcp"
        let base = "\(url.scheme!)://\(url.host!):\(url.port!)"
        let url = try XCTUnwrap(URL(string: base + path))
        let method = (http["method"] as? String) ?? "POST"
        var token: String? = server.token
        if let raw = http["bearer"] {
            token = raw is NSNull ? nil : (raw as? String)
        }
        let origin = http["origin"] as? String
        if let declaredLength = http["contentLength"] as? Int {
            let raw = try await rawExchange(
                port: UInt16(url.port ?? 0), declaredLength: declaredLength,
                path: path, token: token, origin: origin)
            let response = HTTPResult(status: raw.status, data: raw.body)
            let expect = try BotContractFixture.object(object["expect"], "\(label).expect")
            XCTAssertEqual(response.status,
                           try BotContractFixture.int(expect["status"], "\(label).expect.status"), label)
            if let error = expect["error"] as? String {
                XCTAssertEqual(response.json?["error"]?.stringValue, error, label)
            }
            return
        }
        var body: Data?
        if let raw = http["rawBody"] as? String {
            body = Data(raw.utf8)
        } else if method == "POST" {
            body = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        }
        let response = try await send(url, method: method, body: body, token: token, origin: origin)
        let expect = try BotContractFixture.object(object["expect"], "\(label).expect")
        XCTAssertEqual(response.status,
                       try BotContractFixture.int(expect["status"], "\(label).expect.status"), label)
        if let error = expect["error"] as? String {
            XCTAssertEqual(response.json?["error"]?.stringValue, error, label)
        }
    }

    // MARK: - helpers

    private func rpc(_ request: [String: Any], headers: [String: String] = [:]) async -> BotJSONValue {
        let id = try? BotContractFixture.json(request["id"] ?? NSNull())
        let params = (try? BotContractFixture.json(request["params"] ?? [:])) ?? .object([:])
        return await handler.rpc(
            method: (request["method"] as? String) ?? "",
            params: params, id: id ?? .null, headers: headers)
    }

    private func issue(_ caller: [String: Any], label: String) async throws -> String {
        let kindRaw = (caller["kind"] as? String) ?? "chat"
        let kind = BotSessionKind(rawValue: kindRaw) ?? .chat
        let issued = try await fixture.runtime.issueSessionToken(
            botId: try BotContractFixture.string(caller["botId"], "\(label).caller.botId"),
            sessionId: try BotContractFixture.string(caller["sessionId"], "\(label).caller.sessionId"),
            kind: kind)
        return issued.token
    }

    private func register(_ registration: [String: Any], token: String,
                          headers: [String: String], label: String) async throws {
        let arguments = try BotContractFixture.json(registration["arguments"] ?? [:])
        let body: [String: Any] = [
            "runtimeId": BotMCPRuntime.defaultRuntimeID,
            "sessionId": headers[BotMCPHandler.callerSessionHeader]!,
            "callId": registration["callId"] as? String ?? "call",
            "name": registration["tool"] as? String ?? "",
            "arguments": registration["arguments"] ?? [:],
            "argsDigest": try BotContractFixture.digest(arguments),
            "sessionToken": token,
        ]
        let reply = await handler.registerIdentity(try BotContractFixture.json(body))
        XCTAssertEqual(reply["ok"], .bool(true), "\(label): registration failed: \(reply)")
    }

    private func assertToolList(_ reply: BotJSONValue, expectation: Any, label: String) throws {
        let expected = try BotContractFixture.object(expectation, "\(label).expect.toolList")
        let tools = reply["result"]?["tools"]?.arrayValue ?? []
        let names = tools.compactMap { $0["name"]?.stringValue }
        if let names = expected["names"] as? [String] {
            XCTAssertEqual(names, tools.compactMap { $0["name"]?.stringValue }, label)
        }
        if let count = expected["count"] as? Int {
            XCTAssertEqual(tools.count, count, label)
        }
        if let last = expected["last"] as? String {
            XCTAssertEqual(names.last, last, label)
        }
        if let contains = expected["contains"] as? [String] {
            for name in contains { XCTAssertTrue(names.contains(name), "\(label): missing \(name)") }
        }
        if let excludes = expected["notContains"] as? [String] {
            for name in excludes { XCTAssertFalse(names.contains(name), "\(label): must not contain \(name)") }
        }
        // Native collision: the Bot description must win over the native one.
        if let ask = tools.first(where: { $0["name"]?.stringValue == "ask_user" }) {
            XCTAssertFalse(ask["description"]?.stringValue?.contains("COLLIDING") == true, label)
        }
    }

    private struct HTTPResult {
        let status: Int
        let data: Data
        var json: BotJSONValue? { try? BotJSONValue.parse(data) }
    }

    private func send(_ url: URL, method: String, body: Data?, token: String?,
                      origin: String? = nil) async throws -> HTTPResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        // A fresh ephemeral session per request: the listener closes every
        // connection, and a shared URLSession pool can race the close after the
        // 413 path cancels mid-upload.
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        return HTTPResult(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
    }
}

/// One raw TCP exchange. The over-limit body is exercised with a declared
/// `Content-Length` and no body so the 413 is decided from the header, with no
/// upload race against the listener closing the socket.
private func rawExchange(port: UInt16, declaredLength: Int, path: String, token: String?,
                         origin: String?) async throws -> (status: Int, body: Data) {
    let connection = NWConnection(host: .ipv4(.loopback),
                                  port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    return try await withCheckedThrowingContinuation { continuation in
        let box = RawExchangeBox(continuation: continuation)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                var head = "POST \(path) HTTP/1.1\r\n"
                head += "Host: 127.0.0.1:\(port)\r\n"
                if let token { head += "Authorization: Bearer \(token)\r\n" }
                if let origin { head += "Origin: \(origin)\r\n" }
                head += "Content-Type: application/json\r\n"
                head += "Content-Length: \(declaredLength)\r\n\r\n"
                connection.send(content: Data(head.utf8), completion: .contentProcessed { error in
                    if let error { box.finish(.failure(error)); return }
                    box.receive(connection)
                })
            case .failed(let error):
                box.finish(.failure(error))
            default:
                break
            }
        }
        connection.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            box.finish(.failure(BotContractFixture.FixtureError(description: "raw exchange timed out")))
        }
    }
}

private final class RawExchangeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(status: Int, body: Data), Error>?
    private var data = Data()

    init(continuation: CheckedContinuation<(status: Int, body: Data), Error>) {
        self.continuation = continuation
    }

    func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] chunk, _, complete, error in
            guard let self else { return }
            if let chunk { self.lock.withLock { self.data.append(chunk) } }
            if let error { self.finish(.failure(error)); return }
            if complete { self.finish(.success(self.lock.withLock { self.data })); return }
            self.receive(connection)
        }
    }

    func finish(_ result: Result<Data, Error>) {
        let next: CheckedContinuation<(status: Int, body: Data), Error>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        guard let next else { return }
        switch result {
        case .failure(let error):
            next.resume(throwing: error)
        case .success(let data):
            let separator = Data("\r\n\r\n".utf8)
            guard let range = data.range(of: separator),
                  let head = String(data: data[..<range.lowerBound], encoding: .utf8),
                  let statusLine = head.components(separatedBy: "\r\n").first else {
                next.resume(throwing: BotContractFixture.FixtureError(description: "malformed raw response"))
                return
            }
            let parts = statusLine.split(separator: " ")
            let status = parts.count >= 2 ? (Int(parts[1]) ?? 0) : 0
            next.resume(returning: (status, Data(data[range.upperBound...])))
        }
    }
}

private extension BotJSONValue {
    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}
