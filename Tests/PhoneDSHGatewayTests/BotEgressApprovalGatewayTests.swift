// SPDX-License-Identifier: MIT
//
// `/v1/http` Bot egress write approval (P05 seam).
//
// The gateway must call the Bot approver only for POST/PUT/PATCH/DELETE, never
// for a configured model-inference endpoint, and only before any credential,
// socket or response-log side effect. A denied write fails with the stable
// `egress_approval_denied` cause and contacts nothing.

import Foundation
import XCTest
import PhoneDSHGateway
import PhoneDSHAgentCore

private struct AnonymousProvider: CredentialProvider {
    func credential(for scope: CredentialScope) async throws -> Credential { .none }
    func invalidate(_ credential: Credential, for scope: CredentialScope) async {}
}

private struct ExactRouteAuthorizer: EgressHostAuthorizing {
    let urls: Set<String>

    func allowsEgressHost(_ url: URL) -> Bool {
        urls.contains(url.absoluteString)
    }
}

private final class RecordingApprover: BotEgressWriteApproving, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [BotEgressWriteRequest] = []
    private let decision: BotEgressWriteDecision

    init(_ decision: BotEgressWriteDecision) {
        self.decision = decision
    }

    var requests: [BotEgressWriteRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func approveBotEgressWrite(_ request: BotEgressWriteRequest) async -> BotEgressWriteDecision {
        lock.lock()
        recorded.append(request)
        lock.unlock()
        return decision
    }
}

final class BotEgressApprovalGatewayTests: XCTestCase {
    private func makeGateway(port: UInt16,
                             repeats: Set<String> = [],
                             approver: BotEgressWriteApproving?) -> ModelGateway {
        let configuration = ModelGatewayConfiguration(
            allowedUpstreamHosts: ["127.0.0.1:\(port)"],
            replaySafeModelEndpoints: repeats,
            responseLogQuotaBytes: 1_000_000,
            backoff: ModelGatewayBackoffPolicy(initialDelay: 0, multiplier: 2,
                                               maximumDelay: 60, jitterFraction: 0,
                                               maximumAttempts: 1),
            upstreamRequestTimeout: 10)
        let gateway = ModelGateway(configuration: configuration,
                                   credentialProvider: AnonymousProvider(),
                                   botEgressApprover: approver)
        addTeardownBlock {
            await gateway.shutdown()
        }
        return gateway
    }

    private func request(port: UInt16, method: String = "POST",
                         path: String = "/upload") -> GatewayRequest {
        let body = method == "GET" || method == "HEAD" ? Data() : Data("payload".utf8)
        return GatewayRequest(method: method,
                              url: URL(string: "http://127.0.0.1:\(port)\(path)")!,
                              headers: ["content-type": "text/plain"],
                              body: body)
    }

    func testDeniedWriteNeverContactsTheUpstream() async throws {
        let server = try MockUpstreamServer { _ in
            .full(status: 200, headers: [:], body: Data("should not run".utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let approver = RecordingApprover(.deny(code: "egress_approval_denied",
                                               message: "approval denied"))
        let gateway = makeGateway(port: server.port, approver: approver)

        let error = try await expectGatewayFailure(gateway.handle(request(port: server.port)))
        guard case .egressApprovalDenied(let code, let message)? = error as? ModelGatewayError else {
            XCTFail("expected egressApprovalDenied, got \(error)")
            return
        }
        XCTAssertEqual(code, "egress_approval_denied")
        XCTAssertEqual(message, "approval denied")
        XCTAssertEqual((error as? ModelGatewayError)?.structuredErrorCode,
                       "egress_approval_denied")
        XCTAssertEqual((error as? ModelGatewayError)?.proxyStatusCode, 403)
        XCTAssertEqual((error as? ModelGatewayError)?.proxyErrorCode,
                       "egress_approval_denied")
        XCTAssertEqual(server.requestCount, 0,
                       "a denied Bot write must not open a socket")
        XCTAssertEqual(approver.requests.count, 1)
        XCTAssertEqual(approver.requests.first?.method, "POST")
        XCTAssertEqual(approver.requests.first?.operation, "egress.post")
        XCTAssertEqual(approver.requests.first?.resource, "host=127.0.0.1")
    }

    func testAllowedWriteReachesTheUpstreamOnce() async throws {
        let server = try MockUpstreamServer { _ in
            .full(status: 200, headers: ["content-type": "text/plain"],
                  body: Data("ok".utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let approver = RecordingApprover(.allow)
        let gateway = makeGateway(port: server.port, approver: approver)

        let response = try await collectGatewayResponse(gateway.handle(request(port: server.port)))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(server.requestCount, 1)
        XCTAssertEqual(server.requests.first?.method, "POST")
        XCTAssertEqual(approver.requests.count, 1)
    }

    func testGetAndHeadKeepTheOrdinaryAllowListBehaviour() async throws {
        for method in ["GET", "HEAD"] {
            let server = try MockUpstreamServer { request in
                .full(status: 200, headers: ["content-type": "text/plain"],
                      body: request.method == "HEAD" ? Data() : Data("ok".utf8))
            }
            _ = try await server.start()
            defer { server.stop() }
            let approver = RecordingApprover(.allow)
            let gateway = makeGateway(port: server.port, approver: approver)
            let response = try await collectGatewayResponse(
                gateway.handle(request(port: server.port, method: method)))
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(approver.requests.count, 0,
                           "\(method) must never enter the Bot write approval layer")
        }
    }

    func testConfiguredModelEndpointIsNotAProxiedToolWrite() async throws {
        let server = try MockUpstreamServer { _ in
            .full(status: 200, headers: ["content-type": "application/json"],
                  body: Data("{}".utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let endpoint = "http://127.0.0.1:\(server.port)/v1/messages"
        let approver = RecordingApprover(.deny(code: "egress_approval_denied",
                                               message: "must not be called"))
        let gateway = makeGateway(port: server.port, repeats: [endpoint], approver: approver)

        let response = try await collectGatewayResponse(
            gateway.handle(request(port: server.port, path: "/v1/messages")))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(approver.requests.count, 0,
                       "the configured model POST keeps the model-inference path")
    }

    func testExactMCPRouteIsNotAskedAgainForNetworkApproval() async throws {
        let server = try MockUpstreamServer { _ in
            .full(status: 200, headers: ["content-type": "application/json"],
                  body: Data("{\"ok\":true}".utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let url = "http://127.0.0.1:\(server.port)/approval"
        let approver = RecordingApprover(.deny(code: "egress_approval_denied",
                                               message: "must not be called"))
        let configuration = ModelGatewayConfiguration(
            allowedUpstreamHosts: ["127.0.0.1:\(server.port)"],
            responseLogQuotaBytes: 1_000_000,
            backoff: ModelGatewayBackoffPolicy(initialDelay: 0, multiplier: 2,
                                               maximumDelay: 60, jitterFraction: 0,
                                               maximumAttempts: 1),
            upstreamRequestTimeout: 10)
        let gateway = ModelGateway(configuration: configuration,
                                   credentialProvider: AnonymousProvider(),
                                   egressAuthorizer: ExactRouteAuthorizer(urls: [url]),
                                   botEgressApprover: approver)
        addTeardownBlock { await gateway.shutdown() }

        let response = try await collectGatewayResponse(
            gateway.handle(request(port: server.port, path: "/approval")))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(approver.requests.count, 0,
                       "the Bot MCP approval route has its own credential gate; it must not recurse")
        XCTAssertEqual(server.requestCount, 1)
    }

    func testNotBotLeavesWorkbenchBehaviourUnchanged() async throws {
        let server = try MockUpstreamServer { _ in
            .full(status: 200, headers: [:], body: Data("ok".utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let approver = RecordingApprover(.notBot)
        let gateway = makeGateway(port: server.port, approver: approver)

        let response = try await collectGatewayResponse(gateway.handle(request(port: server.port)))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(server.requestCount, 1)
        XCTAssertEqual(approver.requests.count, 1,
                       "the gateway consults the policy and the policy says notBot")
    }

    func testApprovedWriteDoesNotFollowRedirects() async throws {
        let target = try MockUpstreamServer { _ in
            .full(status: 200, headers: [:], body: Data("followed".utf8))
        }
        _ = try await target.start()
        addTeardownBlock { target.stop() }
        let source = try MockUpstreamServer { _ in
            .full(status: 307,
                  headers: ["location": "http://127.0.0.1:\(target.port)/elsewhere"],
                  body: Data())
        }
        _ = try await source.start()
        addTeardownBlock { source.stop() }
        let gateway = makeGateway(port: source.port, approver: RecordingApprover(.allow))

        let response = try await collectGatewayResponse(gateway.handle(request(port: source.port)))
        XCTAssertEqual(response.status, 307,
                       "the approved write's 3xx is returned instead of re-issued")
        XCTAssertEqual(target.requestCount, 0,
                       "a redirect must not send the approved body to a second host")
    }
}
