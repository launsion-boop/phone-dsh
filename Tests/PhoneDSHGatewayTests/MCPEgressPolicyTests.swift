// SPDX-License-Identifier: MIT
// Gateway seam for the host-side MCP exact-URL policy: a request is admitted
// only when the dynamic authorizer names the exact URL, the Worker's
// host-managed placeholder is dropped, and the scoped header credential is the
// only authentication the upstream sees.

import Foundation
import XCTest
import PhoneDSHGateway
import PhoneDSHAgentCore

final class MCPEgressPolicyTests: XCTestCase {
    private final class MutableExactAuthorizer: EgressHostAuthorizing, @unchecked Sendable {
        private let lock = NSLock()
        private var url: URL?

        init(url: URL) {
            self.url = url
        }

        func set(_ url: URL?) {
            lock.lock()
            self.url = url
            lock.unlock()
        }

        func allowsEgressHost(_ candidate: URL) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return url == candidate
        }
    }

    private struct HeaderCredentialProvider: CredentialProvider {
        let headers: [String: String]

        func credential(for scope: CredentialScope) async throws -> Credential {
            Credential(kind: .headers(headers), value: "")
        }

        func invalidate(_ credential: Credential, for scope: CredentialScope) async {}
    }

    private final class SetAuthorizer: EgressHostAuthorizing, @unchecked Sendable {
        let urls: Set<URL>

        init(urls: Set<URL>) {
            self.urls = urls
        }

        func allowsEgressHost(_ candidate: URL) -> Bool {
            urls.contains(candidate)
        }
    }

    private func makeGateway(authorizer: any EgressHostAuthorizing,
                             responseLog: (any ResponseLogging)? = nil,
                             credentialHeaders: [String: String] = [
                                "authorization": "Bearer mcp-token",
                                "x-mcp-token": "mcp-value",
                             ]) -> ModelGateway {
        let configuration = ModelGatewayConfiguration(
            allowedUpstreamHosts: [],
            responseLogQuotaBytes: 1_000_000,
            backoff: ModelGatewayBackoffPolicy(initialDelay: 0,
                                               multiplier: 2,
                                               maximumDelay: 60,
                                               jitterFraction: 0,
                                               maximumAttempts: 1),
            upstreamRequestTimeout: 10)
        let gateway = ModelGateway(
            configuration: configuration,
            credentialProvider: HeaderCredentialProvider(headers: credentialHeaders),
            responseLog: responseLog,
            egressAuthorizer: authorizer)
        addTeardownBlock {
            await gateway.shutdown()
        }
        return gateway
    }

    func testExactURLAccessDropsTheWorkerPlaceholderAndInjectsScopedHeaders() async throws {
        let server = try MockUpstreamServer { _ in
            .full(status: 200,
                  headers: ["content-type": "text/plain"],
                  body: Data("ok".utf8))
        }
        let port = try await server.start()
        addTeardownBlock { server.stop() }
        let target = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let authorizer = MutableExactAuthorizer(url: target)
        let gateway = makeGateway(authorizer: authorizer)

        let response = try await collectGatewayResponse(
            gateway.handle(GatewayRequest(
                method: "POST",
                url: target,
                headers: [
                    "authorization": "Bearer worker-placeholder",
                    "x-mcp-token": ModelGateway.hostManagedHeaderPlaceholder,
                    "x-other": "kept",
                ],
                body: Data("{}".utf8))))
        XCTAssertEqual(response.status, 200)
        let seen = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(seen.headers["authorization"], "Bearer mcp-token",
                       "the host credential replaces the Worker Authorization")
        XCTAssertEqual(seen.headers["x-mcp-token"], "mcp-value",
                       "the host-managed placeholder never reaches the server")
        XCTAssertEqual(seen.headers["x-other"], "kept")
        XCTAssertEqual(seen.headers["x-api-key"], nil,
                       "the MCP route must not carry a model key")
    }

    func testRedirectToAnotherMCPPathOnTheSameHostDoesNotCarryTheInjectedHeaders() async throws {
        let server = try MockUpstreamServer { request in
            if request.path == "/mcp" {
                return .full(status: 302,
                             headers: ["location": "/other"],
                             body: Data())
            }
            return .full(status: 200,
                         headers: ["content-type": "text/plain"],
                         body: Data("redirect followed".utf8))
        }
        let port = try await server.start()
        addTeardownBlock { server.stop() }
        let mcp = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let other = URL(string: "http://127.0.0.1:\(port)/other")!
        // Both paths are admitted by the test authorizer; the redirect must
        // still not reuse the /mcp header credential for /other.
        let gateway = makeGateway(authorizer: SetAuthorizer(urls: [mcp, other]))

        let response = try await collectGatewayResponse(
            gateway.handle(GatewayRequest(method: "POST", url: mcp, body: Data("{}".utf8))))
        XCTAssertEqual(response.status, 302)
        XCTAssertEqual(server.requestCount, 1,
                       "a different path must not receive the original MCP credential")
        XCTAssertEqual(server.requests.first?.path, "/mcp")
        XCTAssertEqual(server.requests.first?.headers["x-mcp-token"], "mcp-value")
    }

    func testRedirectToTheSameMCPURLKeepsTheInjectedHeaders() async throws {
        let counter = LockedCounter()
        let server = try MockUpstreamServer { _ in
            if counter.next() == 1 {
                return .full(status: 307,
                             headers: ["location": "/mcp"],
                             body: Data())
            }
            return .full(status: 200,
                         headers: ["content-type": "text/plain"],
                         body: Data("ok".utf8))
        }
        let port = try await server.start()
        addTeardownBlock { server.stop() }
        let mcp = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let gateway = makeGateway(authorizer: SetAuthorizer(urls: [mcp]))

        let response = try await collectGatewayResponse(
            gateway.handle(GatewayRequest(method: "POST", url: mcp, body: Data("{}".utf8))))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(server.requestCount, 2)
        XCTAssertEqual(server.requests.map { $0.headers["authorization"] },
                       ["Bearer mcp-token", "Bearer mcp-token"],
                       "URLSession drops Authorization on redirect; the same scope must get it back")
        XCTAssertEqual(server.requests.map { $0.headers["x-mcp-token"] },
                       ["mcp-value", "mcp-value"],
                       "a header-map credential is credential-bearing even with an empty scalar value")
    }

    func testHostManagedResponseEchoIsNotWrittenToTheResponseLog() async throws {
        let token = "Bearer mcp-token"
        let server = try MockUpstreamServer { _ in
            .full(status: 401,
                  headers: ["content-type": "text/plain",
                            "x-echo": "server saw \(token)"],
                  body: Data("rejected \(token)".utf8))
        }
        let port = try await server.start()
        addTeardownBlock { server.stop() }
        let target = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let root = try makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let log = try ResponseLog(root: root, quotaBytes: 1_000_000)
        let gateway = makeGateway(authorizer: SetAuthorizer(urls: [target]),
                                  responseLog: log)
        let headers = [
            "authorization": "Bearer worker-placeholder",
            "x-mcp-token": ModelGateway.hostManagedHeaderPlaceholder,
        ]
        let body = Data("{}".utf8)

        let response = try await collectGatewayResponse(
            gateway.handle(GatewayRequest(method: "POST",
                                          url: target,
                                          headers: headers,
                                          body: body)))
        XCTAssertEqual(response.status, 401)
        let liveBody = String(decoding: response.body, as: UTF8.self)
        XCTAssertFalse(liveBody.contains(token),
                       "the live MCP client must never receive the injected value")
        XCTAssertFalse(liveBody.contains("rejected"),
                       "the upstream error body is replaced, not passed through")
        XCTAssertTrue(liveBody.contains("withheld"),
                      "the MCP client receives a controlled status diagnostic")
        XCTAssertEqual(response.headers["content-type"], "application/json; charset=utf-8")
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: response.body),
                        "the controlled diagnostic is valid JSON")
        let echoedHeader = try XCTUnwrap(response.headers["x-echo"])
        XCTAssertTrue(echoedHeader.contains("[redacted]"),
                      "response headers are redacted before forwarding")
        XCTAssertFalse(echoedHeader.contains(token))
        let key = ResponseLog.cacheKey(method: "POST",
                                       url: target,
                                       headers: headers,
                                       body: body,
                                       headerAllowList: ["accept", "content-type"])
        let replayed = await log.replay(key: key)
        XCTAssertNil(replayed, "a host-managed MCP response is not replayable from disk")
        XCTAssertEqual(try filesContaining(token, under: root), [],
                       "an upstream echo of the injected header never reaches the response log")
    }

    func testHostManagedJSONRPCErrorBodyRedactsInjectedValuesAndKeepsID() async throws {
        let token = "Bearer mcp-token"
        let secondary = "mcp-value"
        let upstream = "{\"jsonrpc\":\"2.0\",\"id\":42,\"result\":{\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"rejected \(token) / \(secondary)\"}]}}"
        let server = try MockUpstreamServer { _ in
            .full(status: 200,
                  headers: ["content-type": "application/json",
                            "x-echo": "server saw \(token)"],
                  body: Data(upstream.utf8))
        }
        let port = try await server.start()
        addTeardownBlock { server.stop() }
        let target = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let (gateway, log, root) = try makeLoggedGateway(url: target)
        let headers = ["authorization": "Bearer worker-placeholder",
                       "x-mcp-token": ModelGateway.hostManagedHeaderPlaceholder]

        let response = try await collectGatewayResponse(
            gateway.handle(GatewayRequest(method: "POST",
                                          url: target,
                                          headers: headers,
                                          body: Data("{}".utf8))))
        XCTAssertEqual(response.status, 200)
        let text = String(decoding: response.body, as: UTF8.self)
        XCTAssertFalse(text.contains(token), "the injected Authorization must not reach the Worker")
        XCTAssertFalse(text.contains(secondary), "every injected header value is redacted")
        XCTAssertTrue(text.contains("[redacted]"))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(object["id"] as? Int, 42, "the JSON-RPC id survives the rewrite")
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let message = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(message.contains("[redacted]"))
        let echoedHeader = try XCTUnwrap(response.headers["x-echo"])
        XCTAssertFalse(echoedHeader.contains(token))
        XCTAssertTrue(echoedHeader.contains("[redacted]"))

        let key = ResponseLog.cacheKey(method: "POST",
                                       url: target,
                                       headers: headers,
                                       body: Data("{}".utf8),
                                       headerAllowList: ["accept", "content-type"])
        let replayed = await log.replay(key: key)
        XCTAssertNil(replayed)
        XCTAssertEqual(try filesContaining(token, under: root), [])
        XCTAssertEqual(try filesContaining(secondary, under: root), [])
    }

    func testHostManagedJSONRedactionKeepsStructureForEscapedShortValue() async throws {
        let secret = "a\"b"
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 3,
            "result": [
                "isError": true,
                "content": [["type": "text", "text": "echo \(secret)"]],
            ],
        ]
        let upstream = try JSONSerialization.data(withJSONObject: payload)
        let server = try MockUpstreamServer { _ in
            .full(status: 200,
                  headers: ["content-type": "application/json"],
                  body: upstream)
        }
        let port = try await server.start()
        addTeardownBlock { server.stop() }
        let target = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let gateway = makeGateway(authorizer: SetAuthorizer(urls: [target]),
                                  credentialHeaders: ["authorization": secret])

        let response = try await collectGatewayResponse(
            gateway.handle(GatewayRequest(
                method: "POST",
                url: target,
                headers: ["x-mcp-token": ModelGateway.hostManagedHeaderPlaceholder],
                body: Data("{}".utf8))))
        XCTAssertEqual(response.status, 200)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(object["id"] as? Int, 3,
                       "a short/escaped injected value must not destroy the JSON-RPC id")
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let message = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertFalse(message.contains(secret),
                       "the decoded JSON string is redacted, not the escaped byte sequence")
        let text = String(decoding: response.body, as: UTF8.self)
        XCTAssertFalse(text.contains("a\\\"b"),
                       "the escaped form of the injected value is not forwarded")
    }

    func testHostManagedJSONKeyEchoIsRedacted() async throws {
        let token = "Bearer mcp-token"
        let upstream = "{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"key echo\"}],\"\(token)\":\"leak\"}}"
        let server = try MockUpstreamServer { _ in
            .full(status: 200,
                  headers: ["content-type": "application/json"],
                  body: Data(upstream.utf8))
        }
        let port = try await server.start()
        addTeardownBlock { server.stop() }
        let target = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let gateway = makeGateway(authorizer: SetAuthorizer(urls: [target]))

        let response = try await collectGatewayResponse(
            gateway.handle(GatewayRequest(
                method: "POST",
                url: target,
                headers: ["x-mcp-token": ModelGateway.hostManagedHeaderPlaceholder],
                body: Data("{}".utf8))))
        XCTAssertEqual(response.status, 200)
        let text = String(decoding: response.body, as: UTF8.self)
        XCTAssertFalse(text.contains(token),
                       "an injected value echoed as a JSON key is redacted too")
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(object["id"] as? Int, 5)
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    func testHostManagedNonUTF8BodyReplacesShortExactValueWithoutRestarting() async throws {
        // A one-byte injected value exercises the raw byte replacement used
        // when the body is not UTF-8. The value also occurs inside
        // "[redacted]", so a replacement that restarted its search from the
        // beginning would either loop or re-redact its own output.
        let secret = "a"
        let server = try MockUpstreamServer { _ in
            .full(status: 200,
                  headers: ["content-type": "application/octet-stream"],
                  body: Data([0xFF, 0x61, 0xFE, 0x61]))
        }
        let port = try await server.start()
        addTeardownBlock { server.stop() }
        let target = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let gateway = makeGateway(authorizer: SetAuthorizer(urls: [target]),
                                  credentialHeaders: ["authorization": secret])

        let response = try await collectGatewayResponse(
            gateway.handle(GatewayRequest(
                method: "POST",
                url: target,
                headers: ["x-mcp-token": ModelGateway.hostManagedHeaderPlaceholder],
                body: Data("{}".utf8))))
        XCTAssertEqual(response.status, 200)
        var expected = Data([0xFF])
        expected.append(Data("[redacted]".utf8))
        expected.append(Data([0xFE]))
        expected.append(Data("[redacted]".utf8))
        XCTAssertEqual(response.body, expected,
                       "each exact injected byte sequence is replaced once, without rescanning the replacement")
    }

    func testHostManagedBearerTokenEchoedWithoutSchemeIsRedactedInJSONRPCError() async throws {
        let token = "mcp-token"
        let upstream = "{\"jsonrpc\":\"2.0\",\"id\":11,\"result\":{\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"rejected \(token)\"}]}}"
        let server = try MockUpstreamServer { _ in
            .full(status: 200,
                  headers: ["content-type": "application/json"],
                  body: Data(upstream.utf8))
        }
        let port = try await server.start()
        addTeardownBlock { server.stop() }
        let target = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let gateway = makeGateway(authorizer: SetAuthorizer(urls: [target]),
                                  credentialHeaders: ["authorization": "Bearer \(token)"])

        let response = try await collectGatewayResponse(
            gateway.handle(GatewayRequest(
                method: "POST",
                url: target,
                headers: ["x-mcp-token": ModelGateway.hostManagedHeaderPlaceholder],
                body: Data("{}".utf8))))
        XCTAssertEqual(response.status, 200)
        let text = String(decoding: response.body, as: UTF8.self)
        XCTAssertFalse(text.contains(token),
                       "a server echoing only the token part of Authorization must not leak it")
        XCTAssertTrue(text.contains("[redacted]"))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(object["id"] as? Int, 11)
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    func testHostManagedBearerTokenEchoedWithoutSchemeIsRedactedInSSE() async throws {
        let token = "mcp-token"
        let event = "data: {\"jsonrpc\":\"2.0\",\"id\":12,\"result\":{\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"rejected \(token)\"}]}}\n\n"
        let server = try MockUpstreamServer { _ in
            .full(status: 200,
                  headers: ["content-type": "text/event-stream"],
                  body: Data(event.utf8))
        }
        let port = try await server.start()
        addTeardownBlock { server.stop() }
        let target = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let gateway = makeGateway(authorizer: SetAuthorizer(urls: [target]),
                                  credentialHeaders: ["authorization": "Bearer \(token)"])

        let response = try await collectGatewayResponse(
            gateway.handle(GatewayRequest(
                method: "POST",
                url: target,
                headers: ["x-mcp-token": ModelGateway.hostManagedHeaderPlaceholder],
                body: Data("{}".utf8))))
        XCTAssertEqual(response.status, 200)
        let text = String(decoding: response.body, as: UTF8.self)
        XCTAssertFalse(text.contains(token),
                       "an SSE payload echoing only the Authorization token must not leak it")
        XCTAssertTrue(text.contains("[redacted]"))
        let payload = try XCTUnwrap(sseDataPayloads(from: response.body).first)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        XCTAssertEqual(object["id"] as? Int, 12)
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    func testHostManagedNumericCredentialEchoIsRedactedInJSONRPCError() async throws {
        let numeric = "12345"
        let upstream = "{\"jsonrpc\":\"2.0\",\"id\":13,\"result\":{\"isError\":true,\"code\":12345,\"content\":[{\"type\":\"text\",\"text\":\"numeric echo\"}]}}"
        let server = try MockUpstreamServer { _ in
            .full(status: 200,
                  headers: ["content-type": "application/json"],
                  body: Data(upstream.utf8))
        }
        let port = try await server.start()
        addTeardownBlock { server.stop() }
        let target = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let gateway = makeGateway(authorizer: SetAuthorizer(urls: [target]),
                                  credentialHeaders: ["x-api-key": numeric])

        let response = try await collectGatewayResponse(
            gateway.handle(GatewayRequest(
                method: "POST",
                url: target,
                headers: ["x-mcp-token": ModelGateway.hostManagedHeaderPlaceholder],
                body: Data("{}".utf8))))
        XCTAssertEqual(response.status, 200)
        let text = String(decoding: response.body, as: UTF8.self)
        XCTAssertFalse(text.contains(numeric),
                       "a numeric credential echoed as a JSON number must be redacted")
        XCTAssertTrue(text.contains("[redacted]"))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(object["id"] as? Int, 13)
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true,
                       "a numeric credential does not rewrite unrelated booleans")
        XCTAssertEqual(result["code"] as? String, "[redacted]",
                       "the replaced number is a valid JSON string, not broken syntax")
    }

    func testHostManagedNumericCredentialEchoIsRedactedInSSE() async throws {
        let numeric = "12345"
        let event = "data: {\"jsonrpc\":\"2.0\",\"id\":14,\"result\":{\"isError\":true,\"code\":12345}}\n\n"
        let server = try MockUpstreamServer { _ in
            .full(status: 200,
                  headers: ["content-type": "text/event-stream"],
                  body: Data(event.utf8))
        }
        let port = try await server.start()
        addTeardownBlock { server.stop() }
        let target = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let gateway = makeGateway(authorizer: SetAuthorizer(urls: [target]),
                                  credentialHeaders: ["x-api-key": numeric])

        let response = try await collectGatewayResponse(
            gateway.handle(GatewayRequest(
                method: "POST",
                url: target,
                headers: ["x-mcp-token": ModelGateway.hostManagedHeaderPlaceholder],
                body: Data("{}".utf8))))
        XCTAssertEqual(response.status, 200)
        let text = String(decoding: response.body, as: UTF8.self)
        XCTAssertFalse(text.contains(numeric),
                       "a numeric credential echoed in an SSE payload must be redacted")
        XCTAssertTrue(text.contains("[redacted]"))
        let payload = try XCTUnwrap(sseDataPayloads(from: response.body).first)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        XCTAssertEqual(object["id"] as? Int, 14)
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["code"] as? String, "[redacted]")
    }

    func testHostManagedSSEInvalidUTF8EventStillRedactsInjectedBytes() async throws {
        let token = "Bearer mcp-token"
        let normal = "data: {\"jsonrpc\":\"2.0\",\"id\":15,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}}\n\n"
        var body = Data(normal.utf8)
        body.append(Data("data: {\"jsonrpc\":\"2.0\",\"id\":16,\"result\":{\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"rejected \(token)".utf8))
        body.append(0xFF)
        body.append(Data("\"}]}}\n\n".utf8))
        let server = try MockUpstreamServer { _ in
            .full(status: 200,
                  headers: ["content-type": "text/event-stream"],
                  body: body)
        }
        let port = try await server.start()
        addTeardownBlock { server.stop() }
        let target = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let gateway = makeGateway(authorizer: SetAuthorizer(urls: [target]))

        let response = try await collectGatewayResponse(
            gateway.handle(GatewayRequest(
                method: "POST",
                url: target,
                headers: ["x-mcp-token": ModelGateway.hostManagedHeaderPlaceholder],
                body: Data("{}".utf8))))
        XCTAssertEqual(response.status, 200)
        XCTAssertNil(response.body.range(of: Data(token.utf8)),
                     "an invalid UTF-8 byte in an SSE event must not bypass exact-value redaction")
        XCTAssertNotNil(response.body.range(of: Data("[redacted]".utf8)))
        XCTAssertNotNil(response.body.range(of: Data(normal.utf8)),
                        "the normal event is still forwarded byte-for-byte")
    }

    func testHostManagedOversizedBufferedBodyFailsClosed() async throws {
        let token = "Bearer mcp-token"
        var upstream = Data(repeating: 0x20, count: 5 * 1024 * 1024)
        upstream.append(Data(token.utf8))
        let server = try MockUpstreamServer { _ in
            .full(status: 200,
                  headers: ["content-type": "application/json"],
                  body: upstream)
        }
        let port = try await server.start()
        addTeardownBlock { server.stop() }
        let target = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let gateway = makeGateway(authorizer: SetAuthorizer(urls: [target]))

        let response = try await collectGatewayResponse(
            gateway.handle(GatewayRequest(
                method: "POST",
                url: target,
                headers: ["x-mcp-token": ModelGateway.hostManagedHeaderPlaceholder],
                body: Data("{}".utf8))))
        XCTAssertEqual(response.status, 200)
        XCTAssertLessThan(response.body.count, 1024,
                          "an oversized 2xx body is replaced, not accumulated and forwarded")
        XCTAssertNil(response.body.range(of: Data(token.utf8)))
        let text = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(text.contains("withheld"))
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: response.body),
                        "the oversize diagnostic is valid JSON")
    }

    func testHostManagedUnterminatedSSEEventFailsClosedAtTheEventBound() async throws {
        let normal = "data: {\"jsonrpc\":\"2.0\",\"id\":20,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}}\n\n"
        // No blank line ever follows this `data:` event. Without an event
        // bound the sanitizer would keep appending until URLSession's
        // resource timeout and grow the App's memory without limit.
        let hugeEvent = Data(("data: {\"jsonrpc\":\"2.0\",\"id\":21,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\""
            + String(repeating: "x", count: 5 * 1024 * 1024)).utf8)
        let chunkSize = 256 * 1024
        var chunks: [Data] = [Data(normal.utf8)]
        for start in stride(from: 0, to: hugeEvent.count, by: chunkSize) {
            let end = min(start + chunkSize, hugeEvent.count)
            chunks.append(hugeEvent.subdata(in: start..<end))
        }
        let upstreamChunks = chunks
        let server = try MockUpstreamServer { _ in
            .chunked(status: 200,
                     headers: ["content-type": "text/event-stream"],
                     chunks: upstreamChunks,
                     delay: 0.01)
        }
        let port = try await server.start()
        addTeardownBlock { server.stop() }
        let target = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let gateway = makeGateway(authorizer: SetAuthorizer(urls: [target]))

        let response = try await collectGatewayResponse(
            gateway.handle(GatewayRequest(
                method: "POST",
                url: target,
                headers: ["x-mcp-token": ModelGateway.hostManagedHeaderPlaceholder],
                body: Data("{}".utf8))),
            timeout: 15)
        XCTAssertEqual(response.status, 200)
        XCTAssertLessThan(response.body.count, 64 * 1024,
                          "an unterminated oversize SSE event is not accumulated or forwarded")
        let text = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(text.contains(normal),
                      "events completed before the oversize event are still delivered")
        XCTAssertTrue(text.contains("host-managed event limit"))
        XCTAssertTrue(text.contains("withheld"))
        let payloads = sseDataPayloads(from: response.body)
        let diagnostic = try XCTUnwrap(payloads.first { $0.contains("host-managed event limit") })
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(diagnostic.utf8)) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32000)
        XCTAssertEqual(object["jsonrpc"] as? String, "2.0")
    }

    func testHostManagedCROnlySSEEventsKeepTheirBlankLineTerminator() async throws {
        let token = "Bearer mcp-token"
        let normalPayload = "data: {\"jsonrpc\":\"2.0\",\"id\":31,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}}"
        let errorPayload = "data: {\"jsonrpc\":\"2.0\",\"id\":32,\"result\":{\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"rejected \(token)\"}]}}"
        let body = Data((normalPayload + "\r\r" + errorPayload + "\r\r").utf8)
        let server = try MockUpstreamServer { _ in
            .full(status: 200,
                  headers: ["content-type": "text/event-stream"],
                  body: body)
        }
        let port = try await server.start()
        addTeardownBlock { server.stop() }
        let target = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let gateway = makeGateway(authorizer: SetAuthorizer(urls: [target]))

        let response = try await collectGatewayResponse(
            gateway.handle(GatewayRequest(
                method: "POST",
                url: target,
                headers: ["x-mcp-token": ModelGateway.hostManagedHeaderPlaceholder],
                body: Data("{}".utf8))))
        XCTAssertEqual(response.status, 200)
        let text = String(decoding: response.body, as: UTF8.self)
        let events = text.components(separatedBy: "\r\r")
        XCTAssertEqual(events.count, 3,
                       "CR-only events keep their real blank-line terminator instead of merging")
        XCTAssertTrue(events[2].isEmpty)
        XCTAssertEqual(events[0], normalPayload,
                       "an unchanged CR-only event is forwarded byte-for-byte")
        XCTAssertFalse(text.contains(token))
        XCTAssertTrue(events[1].contains("[redacted]"))
        let sanitizedPayload = String(events[1].dropFirst("data: ".count))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(sanitizedPayload.utf8)) as? [String: Any])
        XCTAssertEqual(object["id"] as? Int, 32)
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    func testHostManagedShortCredentialKeepsStructuralResponseHeadersIntact() async throws {
        // "a" is a deliberately short injected value. It occurs inside normal
        // protocol header values such as "application/json" and
        // "text/event-stream"; blind substitution would corrupt them even
        // though the body itself is valid and sanitized.
        let cases: [(contentType: String, body: Data)] = [
            ("application/json",
             Data("{\"jsonrpc\":\"2.0\",\"id\":41,\"result\":{\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"rejected a\"}]}}".utf8)),
            ("text/event-stream",
             Data("data: {\"jsonrpc\":\"2.0\",\"id\":42,\"result\":{\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"rejected a\"}]}}\n\n".utf8)),
        ]
        for testCase in cases {
            let server = try MockUpstreamServer { _ in
                .full(status: 200,
                      headers: ["content-type": testCase.contentType,
                                "mcp-session-id": "session-xyz",
                                "x-echo": "server saw a"],
                      body: testCase.body)
            }
            let port = try await server.start()
            addTeardownBlock { server.stop() }
            let target = URL(string: "http://127.0.0.1:\(port)/mcp")!
            let gateway = makeGateway(authorizer: SetAuthorizer(urls: [target]),
                                      credentialHeaders: ["authorization": "Bearer a"])

            let response = try await collectGatewayResponse(
                gateway.handle(GatewayRequest(
                    method: "POST",
                    url: target,
                    headers: ["x-mcp-token": ModelGateway.hostManagedHeaderPlaceholder],
                    body: Data("{}".utf8))))
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(response.headers["content-type"], testCase.contentType,
                           "a short injected value must not corrupt the structural content-type")
            XCTAssertEqual(response.headers["mcp-session-id"], "session-xyz",
                           "a secret-free MCP session transport header stays intact")
            let echo = try XCTUnwrap(response.headers["x-echo"])
            XCTAssertTrue(echo.contains("[redacted]"),
                          "an arbitrary diagnostic header echo is still redacted")
            XCTAssertFalse(echo.contains("server saw a"))
            let text = String(decoding: response.body, as: UTF8.self)
            XCTAssertTrue(text.contains("[redacted]"))
            if testCase.contentType == "application/json" {
                let object = try XCTUnwrap(
                    try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
                XCTAssertEqual(object["id"] as? Int, 41)
            } else {
                let payload = try XCTUnwrap(sseDataPayloads(from: response.body).first)
                let object = try XCTUnwrap(
                    try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
                XCTAssertEqual(object["id"] as? Int, 42)
            }
        }
    }

    func testHostManagedSSEErrorRedactsAcrossSplitChunksAndKeepsStreaming() async throws {
        let token = "Bearer mcp-token"
        let secondary = "mcp-value"
        let first = "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"first\"}]}}\n\n"
        let error = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"rejected \(token) / \(secondary)\"}]}}\n\n"
        let last = "data: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"last\"}]}}\n\n"
        let errorData = Data(error.utf8)
        let split = errorData.count / 2
        let chunks = [
            Data(first.utf8),
            Data(errorData.prefix(split)),
            Data(errorData.dropFirst(split)),
            Data(last.utf8),
        ]
        let server = try MockUpstreamServer { _ in
            .chunked(status: 200,
                     headers: ["content-type": "text/event-stream"],
                     chunks: chunks,
                     delay: 0.1)
        }
        let port = try await server.start()
        addTeardownBlock { server.stop() }
        let target = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let (gateway, log, root) = try makeLoggedGateway(url: target)
        let headers = ["authorization": "Bearer worker-placeholder",
                       "x-mcp-token": ModelGateway.hostManagedHeaderPlaceholder]

        var status: Int?
        var body = Data()
        var arrivals: [Date] = []
        for try await chunk in gateway.handle(GatewayRequest(method: "POST",
                                                             url: target,
                                                             headers: headers,
                                                             body: Data("{}".utf8))) {
            if let chunkStatus = chunk.status { status = chunkStatus }
            if !chunk.body.isEmpty {
                arrivals.append(Date())
                body.append(chunk.body)
            }
        }
        XCTAssertEqual(status, 200)
        XCTAssertGreaterThanOrEqual(arrivals.count, 3,
                                    "normal events and the split error event are delivered as separate increments")
        let firstArrival = try XCTUnwrap(arrivals.first)
        let lastArrival = try XCTUnwrap(arrivals.last)
        XCTAssertGreaterThanOrEqual(lastArrival.timeIntervalSince(firstArrival), 0.15,
                                    "the gateway must not buffer the whole SSE stream until close")

        let text = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(text.contains(token))
        XCTAssertFalse(text.contains(secondary))
        XCTAssertTrue(text.contains("[redacted]"))
        let payloads = sseDataPayloads(from: body)
        XCTAssertTrue(payloads.contains(#"{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"first"}]}}"#),
                      "a normal event is forwarded byte-for-byte")
        XCTAssertTrue(payloads.contains(#"{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"last"}]}}"#))
        let errorPayload = try XCTUnwrap(payloads.first { $0.contains("\"id\":7") })
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(errorPayload.utf8)) as? [String: Any])
        XCTAssertEqual(object["id"] as? Int, 7, "the SSE JSON-RPC id survives the split/rewrite")
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)

        let key = ResponseLog.cacheKey(method: "POST",
                                       url: target,
                                       headers: headers,
                                       body: Data("{}".utf8),
                                       headerAllowList: ["accept", "content-type"])
        let replayed = await log.replay(key: key)
        XCTAssertNil(replayed)
        XCTAssertEqual(try filesContaining(token, under: root), [])
    }

    func testHostManagedNormalJSONBodyIsForwardedUnchanged() async throws {
        let original = Data(#"{"jsonrpc":"2.0","id":9,"result":{"content":[{"type":"text","text":"hello"}]}}"#.utf8)
        let server = try MockUpstreamServer { _ in
            .full(status: 200,
                  headers: ["content-type": "application/json"],
                  body: original)
        }
        let port = try await server.start()
        addTeardownBlock { server.stop() }
        let target = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let gateway = makeGateway(authorizer: SetAuthorizer(urls: [target]))

        let response = try await collectGatewayResponse(
            gateway.handle(GatewayRequest(
                method: "POST",
                url: target,
                headers: ["x-mcp-token": ModelGateway.hostManagedHeaderPlaceholder],
                body: Data("{}".utf8))))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body, original,
                       "a normal host-managed JSON result is not rewritten")
    }

    func testHostManagedNullBodyStatusesPreserveNoBody() async throws {
        for status in [204, 205, 304] {
            let server = try MockUpstreamServer { _ in
                .full(status: status,
                      headers: ["content-type": "text/plain"],
                      body: Data("upstream body Bearer mcp-token".utf8))
            }
            let port = try await server.start()
            addTeardownBlock { server.stop() }
            let target = URL(string: "http://127.0.0.1:\(port)/mcp")!
            let gateway = makeGateway(authorizer: SetAuthorizer(urls: [target]))

            let response = try await collectGatewayResponse(
                gateway.handle(GatewayRequest(
                    method: "POST",
                    url: target,
                    headers: ["x-mcp-token": ModelGateway.hostManagedHeaderPlaceholder],
                    body: Data("{}".utf8))))
            XCTAssertEqual(response.status, status)
            XCTAssertTrue(response.body.isEmpty,
                          "HTTP \(status) keeps its no-body semantics on a host-managed route")
        }
    }

    func testHostManagedCRLFSSEErrorRedactsAndKeepsBothEventsIndependentlyParseable() async throws {
        let token = "Bearer mcp-token"
        let errorPayload = "data: {\"jsonrpc\":\"2.0\",\"id\":51,\"result\":{\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"rejected \(token)\"}]}}"
        let normalPayload = "data: {\"jsonrpc\":\"2.0\",\"id\":52,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"after\"}]}}"
        let errorEvent = Data((errorPayload + "\r\n\r\n").utf8)
        let normalEvent = Data((normalPayload + "\r\n\r\n").utf8)
        // Split inside the error event and across its CRLF data-line
        // terminator so the sanitizer must reassemble it before redacting,
        // then split the following normal event too.
        let firstCut = errorEvent.count - 3
        let secondCut = 11
        let chunks = [
            Data(errorEvent.prefix(firstCut)),
            Data(errorEvent.dropFirst(firstCut)) + Data(normalEvent.prefix(secondCut)),
            Data(normalEvent.dropFirst(secondCut)),
        ]
        let server = try MockUpstreamServer { _ in
            .chunked(status: 200,
                     headers: ["content-type": "text/event-stream"],
                     chunks: chunks,
                     delay: 0.01)
        }
        let port = try await server.start()
        addTeardownBlock { server.stop() }
        let target = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let gateway = makeGateway(authorizer: SetAuthorizer(urls: [target]))

        let response = try await collectGatewayResponse(
            gateway.handle(GatewayRequest(
                method: "POST",
                url: target,
                headers: ["x-mcp-token": ModelGateway.hostManagedHeaderPlaceholder],
                body: Data("{}".utf8))))
        XCTAssertEqual(response.status, 200)
        let text = String(decoding: response.body, as: UTF8.self)
        XCTAssertFalse(text.contains(token))
        XCTAssertTrue(text.contains("[redacted]"))
        let events = text.components(separatedBy: "\r\n\r\n")
        XCTAssertEqual(events.count, 3,
                       "each CRLF event keeps its blank-line terminator instead of merging")
        XCTAssertEqual(events[2], "")
        XCTAssertEqual(events[1], normalPayload,
                       "the normal CRLF event is forwarded byte-for-byte")
        let errorJSON = String(events[0].dropFirst("data: ".count))
        let errorObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(errorJSON.utf8)) as? [String: Any])
        XCTAssertEqual(errorObject["id"] as? Int, 51)
        let errorResult = try XCTUnwrap(errorObject["result"] as? [String: Any])
        XCTAssertEqual(errorResult["isError"] as? Bool, true)
        let normalJSON = String(events[1].dropFirst("data: ".count))
        let normalObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(normalJSON.utf8)) as? [String: Any])
        XCTAssertEqual(normalObject["id"] as? Int, 52,
                       "the following normal event still parses independently")
    }

    func testHostManagedMixedLineEndingSSEEventsRemainIndependent() async throws {
        let token = "Bearer mcp-token"
        let crlfError = "data: {\"jsonrpc\":\"2.0\",\"id\":61,\"result\":{\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"rejected \(token)\"}]}}\r\n\r\n"
        let lfNormal = "data: {\"jsonrpc\":\"2.0\",\"id\":62,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"lf\"}]}}\n\n"
        let crNormal = "data: {\"jsonrpc\":\"2.0\",\"id\":63,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"cr\"}]}}\r\r"
        let body = Data((crlfError + lfNormal + crNormal).utf8)
        let chunks = [Data(body.prefix(body.count / 2)), Data(body.dropFirst(body.count / 2))]
        let server = try MockUpstreamServer { _ in
            .chunked(status: 200,
                     headers: ["content-type": "text/event-stream"],
                     chunks: chunks,
                     delay: 0.01)
        }
        let port = try await server.start()
        addTeardownBlock { server.stop() }
        let target = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let gateway = makeGateway(authorizer: SetAuthorizer(urls: [target]))

        let response = try await collectGatewayResponse(
            gateway.handle(GatewayRequest(
                method: "POST",
                url: target,
                headers: ["x-mcp-token": ModelGateway.hostManagedHeaderPlaceholder],
                body: Data("{}".utf8))))
        XCTAssertEqual(response.status, 200)
        let text = String(decoding: response.body, as: UTF8.self)
        XCTAssertFalse(text.contains(token))
        XCTAssertNotNil(response.body.range(of: Data(lfNormal.utf8)),
                        "the LF event keeps its original terminator")
        XCTAssertNotNil(response.body.range(of: Data(crNormal.utf8)),
                        "the CR event keeps its original terminator")
        XCTAssertNotNil(response.body.range(of: Data("\r\n\r\n".utf8)),
                        "the CRLF event keeps its original blank line")
        let payloads = sseDataPayloadsAnyLineEnding(from: response.body)
        XCTAssertEqual(payloads.count, 3, "mixed LF/CRLF/CR events are not merged")
        let ids = payloads.compactMap { payload -> Int? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8))
                    as? [String: Any] else { return nil }
            return object["id"] as? Int
        }.sorted()
        XCTAssertEqual(ids, [61, 62, 63])
    }

    func testHostManagedDiagnosticHeadersAreRedactedAndProtocolHeadersFailClosed() async throws {
        let token = "Bearer mcp-token"
        let body = Data("{\"jsonrpc\":\"2.0\",\"id\":71,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}}".utf8)
        let server = try MockUpstreamServer { _ in
            .full(status: 200,
                  headers: [
                    "content-type": "application/json; charset=utf-8; echo=\"\(token)\"",
                    // "mcp-value" is the exact value of the injected x-mcp-token
                    // credential. A protocol header must not echo it.
                    "mcp-session-id": "mcp-value",
                    "mcp-protocol-version": "2024-11-05",
                    "etag": "\"\(token)\"",
                    "last-modified": token,
                    "x-echo": token,
                  ],
                  body: body)
        }
        let port = try await server.start()
        addTeardownBlock { server.stop() }
        let target = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let gateway = makeGateway(authorizer: SetAuthorizer(urls: [target]))

        let response = try await collectGatewayResponse(
            gateway.handle(GatewayRequest(
                method: "POST",
                url: target,
                headers: ["x-mcp-token": ModelGateway.hostManagedHeaderPlaceholder],
                body: Data("{}".utf8))))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["content-type"], "application/json; charset=utf-8",
                       "the valid media type and normal charset survive; the echoed parameter is dropped")
        XCTAssertEqual(response.headers["mcp-protocol-version"], "2024-11-05")
        XCTAssertNil(response.headers["mcp-session-id"],
                     "a protocol header exactly equal to the injected credential is withheld")
        let etag = try XCTUnwrap(response.headers["etag"])
        XCTAssertTrue(etag.contains("[redacted]"))
        XCTAssertFalse(etag.contains(token),
                       "ETag is diagnostic metadata and must not echo the credential")
        let lastModified = try XCTUnwrap(response.headers["last-modified"])
        XCTAssertTrue(lastModified.contains("[redacted]"))
        XCTAssertFalse(lastModified.contains(token),
                       "Last-Modified is diagnostic metadata and must not echo the credential")
        XCTAssertEqual(response.body, body)
    }

    func testHostManagedStructuralHeadersWithEmbeddedSecretAreWithheldAndUnknownMediaTypeFailsClosed() async throws {
        let token = "Bearer mcp-token"
        let secondary = "mcp-value"
        let body = Data("{\"jsonrpc\":\"2.0\",\"id\":72,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}}".utf8)
        let server = try MockUpstreamServer { _ in
            .full(status: 200,
                  headers: [
                    // A legal but unknown media type is still untrusted text.
                    "content-type": "application/vnd.\(secondary)+json; charset=utf-8",
                    // Prefix/suffix wrappers around the real injected value
                    // must not slip a secret through the protocol headers.
                    "mcp-session-id": "session-\(secondary)-tail",
                    "mcp-protocol-version": "prefix-\(secondary)-suffix",
                    "x-echo": "server saw \(token)",
                  ],
                  body: body)
        }
        let port = try await server.start()
        addTeardownBlock { server.stop() }
        let target = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let gateway = makeGateway(authorizer: SetAuthorizer(urls: [target]))

        let response = try await collectGatewayResponse(
            gateway.handle(GatewayRequest(
                method: "POST",
                url: target,
                headers: ["x-mcp-token": ModelGateway.hostManagedHeaderPlaceholder],
                body: Data("{}".utf8))))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["content-type"], "application/octet-stream",
                       "an unknown media type embedding an injected value is not forwarded")
        XCTAssertNil(response.headers["mcp-session-id"],
                     "a prefixed/suffixed injected value withholds the session header")
        XCTAssertNil(response.headers["mcp-protocol-version"],
                     "a prefixed/suffixed injected value withholds the protocol header")
        let echo = try XCTUnwrap(response.headers["x-echo"])
        XCTAssertFalse(echo.contains(token))
        XCTAssertTrue(echo.contains("[redacted]"))
        XCTAssertEqual(response.body, body)
    }

    private func makeLoggedGateway(url: URL) throws -> (ModelGateway, ResponseLog, URL) {
        let root = try makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let log = try ResponseLog(root: root, quotaBytes: 1_000_000)
        let gateway = makeGateway(authorizer: SetAuthorizer(urls: [url]),
                                  responseLog: log)
        return (gateway, log, root)
    }

    private func sseDataPayloads(from body: Data) -> [String] {
        let text = String(decoding: body, as: UTF8.self)
        return text.components(separatedBy: "\n\n").compactMap { event in
            let payload = event.components(separatedBy: "\n").compactMap { line -> String? in
                guard line.hasPrefix("data:") else { return nil }
                var value = String(line.dropFirst(5))
                if value.hasPrefix(" ") { value.removeFirst() }
                return value
            }.joined(separator: "\n")
            return payload.isEmpty ? nil : payload
        }
    }

    /// Parses data payloads independently of the event's line ending. The
    /// bytes themselves are asserted separately so this normalisation only
    /// helps decode mixed LF/CRLF/CR streams in the test.
    private func sseDataPayloadsAnyLineEnding(from body: Data) -> [String] {
        let text = String(decoding: body, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return text.components(separatedBy: "\n\n").compactMap { event in
            let payload = event.components(separatedBy: "\n").compactMap { line -> String? in
                guard line.hasPrefix("data:") else { return nil }
                var value = String(line.dropFirst(5))
                if value.hasPrefix(" ") { value.removeFirst() }
                return value
            }.joined(separator: "\n")
            return payload.isEmpty ? nil : payload
        }
    }

    func testSiblingPathAndRevokedGrantAreHostNotAllowedWithoutContactingTheServer() async throws {
        let server = try MockUpstreamServer { _ in
            .full(status: 200, headers: [:], body: Data("should not run".utf8))
        }
        let port = try await server.start()
        addTeardownBlock { server.stop() }
        let target = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let authorizer = MutableExactAuthorizer(url: target)
        let gateway = makeGateway(authorizer: authorizer)

        let sibling = try await expectGatewayFailure(
            gateway.handle(GatewayRequest(method: "GET",
                                          url: URL(string: "http://127.0.0.1:\(port)/other")!)))
        guard case .hostNotAllowed? = sibling as? ModelGatewayError else {
            XCTFail("expected hostNotAllowed for a sibling path, got \(sibling)")
            return
        }
        XCTAssertEqual(server.requestCount, 0)

        authorizer.set(nil)
        let revoked = try await expectGatewayFailure(
            gateway.handle(GatewayRequest(method: "POST", url: target)))
        guard case .hostNotAllowed? = revoked as? ModelGatewayError else {
            XCTFail("expected hostNotAllowed after revoke, got \(revoked)")
            return
        }
        XCTAssertEqual(server.requestCount, 0)
    }
}
