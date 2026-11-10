// SPDX-License-Identifier: MIT
//
// WP3 Bot egress spike: shared HTTP helpers.
//
// The spike drives the real `BotMCPHTTPServer` and `BotMCPRuntime` over loopback
// HTTP, exactly as the Worker's `/v1/http` egress does after the host injects
// the real Bot bearer. The tests intentionally do not call the runtime's
// registration helper directly: the question is what an HTTP caller that does
// not have a Worker-side identity can do with only the endpoint token.

import Foundation
@testable import PhoneDSHBot

struct SpikeHTTPResponse {
    let status: Int
    let json: BotJSONValue

    var result: BotJSONValue? { json["result"] }
    var isError: Bool { result?["isError"]?.boolValue == true }
    var structured: BotJSONValue? { result?["structuredContent"] }
}

struct SpikeServer {
    /// Listener root (`http://127.0.0.1:<port>`), used for `/identity/register`.
    let base: URL
    /// The exact `/mcp` route.
    let mcp: URL
    let server: BotMCPHTTPServer
}

func spikeStartServer(_ fixture: BotMCPTestFixture, token: String = "wp3-fixture-bot-bearer")
    async throws -> SpikeServer {
    let server = BotMCPHTTPServer(handler: BotMCPHandler(runtime: fixture.runtime), token: token)
    let url = try await server.start()
    return SpikeServer(base: url.deletingLastPathComponent(), mcp: url, server: server)
}

func spikePost(_ url: URL, token: String?, body: BotJSONValue,
               headers: [String: String] = [:]) async throws -> SpikeHTTPResponse {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    if let token {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (name, value) in headers {
        request.setValue(value, forHTTPHeaderField: name)
    }
    request.httpBody = try body.encoded()
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    return SpikeHTTPResponse(status: status, json: (try? BotJSONValue.parse(data)) ?? .null)
}

func spikeRegister(_ base: URL, token: String, sessionId: String, callId: String,
                   name: String, arguments: BotJSONValue,
                   sessionToken: String? = nil,
                   headers: [String: String] = [:]) async throws -> SpikeHTTPResponse {
    let digest = try BotArgumentsDigest.string(for: arguments)
    var body: [String: BotJSONValue] = [
        "runtimeId": .string(BotMCPRuntime.defaultRuntimeID),
        "sessionId": .string(sessionId),
        "callId": .string(callId),
        "name": .string(name),
        "arguments": arguments,
        "argsDigest": .string(digest),
    ]
    if let sessionToken { body["sessionToken"] = .string(sessionToken) }
    return try await spikePost(
        base.appendingPathComponent("identity/register"), token: token,
        body: .object(body), headers: headers)
}

func spikeCall(_ base: URL, token: String, name: String, arguments: BotJSONValue,
               callId: String, headers: [String: String] = [:]) async throws -> SpikeHTTPResponse {
    try await spikePost(
        base, token: token,
        body: .object([
            "jsonrpc": .string("2.0"),
            "id": .string(callId),
            "method": .string("tools/call"),
            "params": .object([
                "name": .string(name),
                "arguments": arguments,
            ]),
        ]), headers: headers)
}

func spikeListTools(_ base: URL, token: String, session: String? = nil) async throws -> [String] {
    var headers: [String: String] = [:]
    if let session {
        headers[BotMCPHandler.callerSessionHeader] = session
    }
    let response = try await spikePost(
        base, token: token,
        body: .object([
            "jsonrpc": .string("2.0"),
            "id": .string("wp3-list"),
            "method": .string("tools/list"),
            "params": .object([:]),
        ]), headers: headers)
    return (response.result?["tools"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
}
