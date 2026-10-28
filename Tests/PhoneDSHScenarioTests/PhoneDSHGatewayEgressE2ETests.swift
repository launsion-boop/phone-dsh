// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: gateway egress integration.
//
// G2-C09 failed every fetch of an allow-listed anonymous host with the same
// generic 502, so the scenario batch could not tell a denied host from a
// missing credential from a transport failure. This target owns the scenario
// credential provider, so the positive half of the contract lives here: an
// allow-listed, anonymous (`.none` credential) host is fetched through the
// real `ModelGateway` egress against a local HTTP server. The negative half —
// distinct structured failures — is pinned by the loopback and gateway
// component regressions, which is where the response writer lives.
//
// The class name deliberately contains `PhoneDSH` so the phone gate's
// `--filter 'PhoneDSH|PhoneDSHShell'` executes it; it does not
// match the scenario batch's `--filter PhoneDSHScenario` selection and so does
// not lengthen a catalog run.

import Foundation
import XCTest
import PhoneDSHAgentCore
import PhoneDSHGateway
@testable import PhoneDSHScenario

final class PhoneDSHScenarioEgressTests: XCTestCase {
    private func collect(_ stream: AsyncThrowingStream<GatewayResponseChunk, Error>)
        async throws -> (status: Int?, headers: [String: String], body: Data) {
        var status: Int?
        var headers: [String: String] = [:]
        var body = Data()
        for try await chunk in stream {
            if let chunkStatus = chunk.status {
                status = chunkStatus
                headers = chunk.headers
            }
            body.append(chunk.body)
        }
        return (status, headers, body)
    }

    /// An allow-listed anonymous host must be reachable through the real
    /// gateway: the scenario provider hands out `Credential.none`, no model key
    /// is involved, and the local server answers the request.
    func testAllowListedAnonymousHostFetchesThroughGatewayEgress() async throws {
        let server = ScenarioMockUpstream()
        var script = ScenarioMockScript.generic
        script.responseByteSizes = [2_048]
        server.script = script
        _ = try server.start()
        addTeardownBlock { server.stop() }

        let provider = ScenarioCredentialProvider(modelHost: "model.invalid",
                                                  modelKey: nil,
                                                  anonymousHosts: ["127.0.0.1"])
        let configuration = ModelGatewayConfiguration(
            allowedUpstreamHosts: ["127.0.0.1:\(server.port)"],
            backoff: ModelGatewayBackoffPolicy(maximumAttempts: 1),
            upstreamRequestTimeout: 10)
        let gateway = ModelGateway(configuration: configuration,
                                   credentialProvider: provider)
        addTeardownBlock { await gateway.shutdown() }

        let request = GatewayRequest(
            method: "POST",
            url: URL(string: "http://127.0.0.1:\(server.port)/v1/messages")!,
            headers: ["content-type": "application/json"],
            body: Data(#"{"model":"scenario-local","max_tokens":16}"#.utf8))
        let response = try await collect(gateway.handle(request))

        XCTAssertEqual(response.status, 200,
                       "the allow-listed anonymous host must be reachable")
        let text = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(text.contains("event: message_start"),
                      "the local server's body must arrive through the gateway")
        XCTAssertTrue(text.contains("message_stop"),
                      "the whole streamed body must arrive")
        XCTAssertEqual(provider.deniedHosts, 0,
                       "an allow-listed host must not count as denied")
        XCTAssertEqual(provider.modelRequests, 0,
                       "a non-model host must never consume the model credential")
        let received = try XCTUnwrap(server.requests.first)
        XCTAssertNil(received.headers["authorization"],
                     "the anonymous path must send no Authorization upstream")
    }
}
