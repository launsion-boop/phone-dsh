// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotMCPHTTPTests: XCTestCase {
    func testVolatileContextUsesPhoneAppMCPNameAndRealDomainBlocks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteDomainStore(fileURL: directory.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        let memory = BotMemory(
            store: SQLiteBotMemoryDocumentStore(eventLog: store, now: { 1_000 }),
            botID: "main", now: { 1_000 })
        let machine = RoutineMachine(store: SQLiteRoutineStore(domainStore: store))
        _ = try await machine.create(
            botId: "main", title: "Morning", prompt: "report", schedule: .interval(everyMinutes: 60), now: 1_000)
        let provider = BotDomainVolatileContextProvider(memory: memory, routines: machine, now: { 1_000 })
        let fixture = try makeBotMCPFixture(volatileProvider: provider)
        defer { fixture.cleanup() }
        let issued = try await fixture.runtime.issueSessionToken(botId: "main", sessionId: "gb-main", kind: .chat)
        let server = BotMCPHTTPServer(handler: BotMCPHandler(runtime: fixture.runtime), token: "test-token-1234567890")
        let url = try await server.start()
        defer { server.stop() }
        let arguments = BotJSONValue.object(["sessionId": .string("gb-main")])
        _ = try await request(url.deletingLastPathComponent().appendingPathComponent("identity/register"), body: .object([
            "runtimeId": .string(BotMCPRuntime.defaultRuntimeID), "sessionId": .string("gb-main"),
            "callId": .string("volatile-http"), "name": .string("BotVolatileContext"),
            "argsDigest": .string(try BotArgumentsDigest.string(for: arguments)),
            "sessionToken": .string(issued.token),
        ]), token: server.token)
        let response = try await request(url, body: .object([
            "jsonrpc": .string("2.0"), "id": .string("volatile-http"), "method": .string("tools/call"),
            "params": .object(["name": .string("BotVolatileContext"), "arguments": arguments]),
        ]), token: server.token)
        let blocks = try XCTUnwrap(response["result"]?["structuredContent"]?["blocks"])
        XCTAssertTrue(blocks["persona"]?.stringValue?.contains("大肥鱼") == true)
        XCTAssertTrue(blocks["automation"]?.stringValue?.contains("Morning") == true)
        XCTAssertTrue(blocks["memory"]?.stringValue?.contains("记忆") == true)
        XCTAssertEqual(response["result"]?["structuredContent"]?["sessionId"], .string("gb-main"))
        XCTAssertTrue(response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?
            .contains("\"sessionId\":\"gb-main\"") == true)
    }

    func testRealStreamableHTTPDiscoversOnlyP0AndExecutesClaimedCard() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let issued = try await fixture.runtime.issueSessionToken(botId: "main", sessionId: "gb-main", kind: .chat)
        let handler = BotMCPHandler(runtime: fixture.runtime)
        let server = BotMCPHTTPServer(handler: handler, token: "test-token-1234567890")
        let url = try await server.start()
        defer { server.stop() }

        let initialized = try await request(url, body: .object([
            "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("initialize"),
            "params": .object(["protocolVersion": .string("2025-06-18")]),
        ]), token: server.token)
        XCTAssertEqual(initialized["result"]?["protocolVersion"], .string("2025-06-18"))

        let listed = try await request(url, body: .object([
            "jsonrpc": .string("2.0"), "id": .number(2), "method": .string("tools/list"),
        ]), token: server.token)
        let tools = try XCTUnwrap(listed["result"]?["tools"]?.arrayValue)
        XCTAssertEqual(tools.count, BotToolCatalog.allDefinitions.count)
        XCTAssertTrue(tools.contains { $0["name"]?.stringValue == "SendToAgent" })
        XCTAssertTrue(tools.contains { $0["name"]?.stringValue == "CreateTeammate" })
        XCTAssertTrue(tools.contains { $0["name"]?.stringValue == "FishAction" })
        XCTAssertFalse(tools.contains { $0["name"]?.stringValue == "show_table" })
        XCTAssertTrue(tools.contains { $0["name"]?.stringValue == "BotVolatileContext" })

        let arguments = BotJSONValue.object([
            "question": .string("Continue?"),
            "options": .array([.object(["label": .string("Yes")]), .object(["label": .string("No")])]),
        ])
        let registrationURL = url.deletingLastPathComponent().appendingPathComponent("identity/register")
        let registered = try await request(registrationURL, body: .object([
            "runtimeId": .string(BotMCPRuntime.defaultRuntimeID), "sessionId": .string("gb-main"),
            "callId": .string("http-card"), "name": .string("ask_user"),
            "argsDigest": .string(try BotArgumentsDigest.string(for: arguments)),
            "sessionToken": .string(issued.token),
        ]), token: server.token)
        XCTAssertEqual(registered["ok"], .bool(true))

        let called = try await request(url, body: .object([
            "jsonrpc": .string("2.0"), "id": .string("http-card"), "method": .string("tools/call"),
            "params": .object(["name": .string("ask_user"), "arguments": arguments]),
        ]), token: server.token)
        XCTAssertEqual(called["result"]?["structuredContent"]?["card"]?["cardType"], .string("question"))
    }

    func testTokenMissingWrongAndOldAreRejected() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let server = BotMCPHTTPServer(handler: BotMCPHandler(runtime: fixture.runtime), token: "new-token")
        let url = try await server.start()
        defer { server.stop() }
        let body = BotJSONValue.object([
            "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("ping"),
        ])

        let missing = try await rawRequest(url, body: body, token: nil)
        XCTAssertEqual(missing.status, 401)
        let wrong = try await rawRequest(url, body: body, token: "wrong")
        XCTAssertEqual(wrong.status, 401)
        let old = try await rawRequest(url, body: body, token: "old-token")
        XCTAssertEqual(old.status, 401)
        let accepted = try await rawRequest(url, body: body, token: "new-token")
        XCTAssertEqual(accepted.status, 200)
        XCTAssertTrue(accepted.body["result"]?.objectValue != nil)
    }

    func testOriginMustBeOwnOriginWhenPresent() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let server = BotMCPHTTPServer(handler: BotMCPHandler(runtime: fixture.runtime), token: "origin-token")
        let url = try await server.start()
        defer { server.stop() }
        let body = BotJSONValue.object([
            "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("ping"),
        ])

        let hostile = try await rawRequest(url, body: body, token: "origin-token",
                                           origin: "http://127.0.0.1:1")
        XCTAssertEqual(hostile.status, 403)
        let own = try await rawRequest(url, body: body, token: "origin-token",
                                       origin: "http://127.0.0.1:\(url.port!)")
        XCTAssertEqual(own.status, 200)
        let absent = try await rawRequest(url, body: body, token: "origin-token")
        XCTAssertEqual(absent.status, 200)
    }

    func testPathsAreExactAndMethodsArePostOnly() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let server = BotMCPHTTPServer(handler: BotMCPHandler(runtime: fixture.runtime), token: "path-token")
        let url = try await server.start()
        defer { server.stop() }
        let body = BotJSONValue.object([
            "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("ping"),
        ])
        let paths: [(String, Int)] = [
            ("/mcp?x=1", 400),
            ("/mcp/", 404),
            ("/MCP", 404),
            ("/identity/../mcp", 400),
            ("/mcp/..", 400),
        ]
        let origin = "\(url.scheme!)://\(url.host!):\(url.port!)"
        for (path, expected) in paths {
            let target = try XCTUnwrap(URL(string: origin + path))
            let response = try await rawRequest(target, body: body, token: "path-token")
            XCTAssertEqual(response.status, expected, path)
        }
        let delete = try await rawRequest(url, method: "DELETE", body: nil, token: "path-token")
        XCTAssertEqual(delete.status, 405)
        let get = try await rawRequest(url, method: "GET", body: nil, token: "path-token")
        XCTAssertEqual(get.status, 405)
    }

    func testIdentityCancelAndApprovalRoutesAreUsableOverHTTP() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let issued = try await fixture.runtime.issueSessionToken(botId: "main", sessionId: "gb-main", kind: .chat)
        let handler = BotMCPHandler(runtime: fixture.runtime)
        let server = BotMCPHTTPServer(handler: handler, token: "routes-token")
        let url = try await server.start()
        defer { server.stop() }
        let base = url.deletingLastPathComponent()

        let arguments = BotJSONValue.object(["action": .string("list")])
        let registered = try await request(base.appendingPathComponent("identity/register"), body: .object([
            "runtimeId": .string(BotMCPRuntime.defaultRuntimeID), "sessionId": .string("gb-main"),
            "callId": .string("cancel-http"), "name": .string("ListRoutines"),
            "argsDigest": .string(try BotArgumentsDigest.string(for: arguments)),
            "sessionToken": .string(issued.token),
        ]), token: "routes-token")
        let registrationId = try XCTUnwrap(registered["id"]?.stringValue)
        let cancelled = try await request(base.appendingPathComponent("identity/cancel"), body: .object([
            "id": .string(registrationId),
        ]), token: "routes-token")
        XCTAssertEqual(cancelled["ok"], .bool(true))

        let invalid = try await request(base.appendingPathComponent("approval"), body: .object([
            "callId": .string("missing"),
        ]), token: "routes-token")
        XCTAssertEqual(invalid["ok"], .bool(false))
        XCTAssertEqual(invalid["allowed"], .bool(false))
    }

    func testListenerBindsLoopbackOnly() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let server = BotMCPHTTPServer(handler: BotMCPHandler(runtime: fixture.runtime), token: "loop-token")
        let url = try await server.start()
        defer { server.stop() }
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.scheme, "http")
        XCTAssertTrue(BotMCPHTTPServer.tokenMatches("Bearer loop-token", expected: "Bearer loop-token"))
        XCTAssertFalse(BotMCPHTTPServer.tokenMatches("Bearer loop-tokeN", expected: "Bearer loop-token"))
        XCTAssertFalse(BotMCPHTTPServer.tokenMatches("Bearer loop-token ", expected: "Bearer loop-token"))
        XCTAssertFalse(BotMCPHTTPServer.tokenMatches(nil, expected: "Bearer loop-token"))
        XCTAssertFalse(BotMCPHTTPServer.tokenMatches("Bearer short", expected: "Bearer loop-token"))
    }

    // MARK: - helpers

    private struct RawResponse {
        let status: Int
        let body: BotJSONValue
    }

    private func request(_ url: URL, body: BotJSONValue, token: String,
                         origin: String? = nil) async throws -> BotJSONValue {
        let response = try await rawRequest(url, body: body, token: token, origin: origin)
        XCTAssertEqual(response.status, 200, "\(url.absoluteString) -> \(response.status)")
        return response.body
    }

    private func rawRequest(_ url: URL, method: String = "POST", body: BotJSONValue?,
                            token: String?, origin: String? = nil) async throws -> RawResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try body.encoded()
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let value = (try? BotJSONValue.parse(data)) ?? .null
        return RawResponse(status: status, body: value)
    }
}

private extension URL {
    var port: Int? { URLComponents(url: self, resolvingAgainstBaseURL: false)?.port }
}
