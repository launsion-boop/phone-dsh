// SPDX-License-Identifier: MIT
// PhoneDSHGateway model-purpose execution point (P26 §2.10,
// PC-20261113-p12-model-purpose-sink).
//
// The execution point is exercised through the real gateway pump: a real
// `MockUpstreamServer` on 127.0.0.1, the real credential seam and the real
// response stream. Only the purpose *evidence* is scripted, because there is
// no wire carrier for a purpose (the proposed header was vetoed) and the
// production purpose source does not exist yet. Nothing here asserts a new
// request/response member: P05 has no wire delta.

import Foundation
import XCTest
import PhoneDSHGateway
import PhoneDSHAgentCore

final class ModelGatewayPurposeEnforcementTests: XCTestCase {
    /// Scripted host composition: fixed evidence, or `nil` for the absent
    /// branch. It never looks at the request (no inference from the URL, the
    /// model name or the body).
    private struct FixedPurposeProvider: ModelPurposeProviding {
        let evidence: BotModelRequest?

        init(_ evidence: BotModelRequest?) {
            self.evidence = evidence
        }

        func modelPurposeEvidence(for request: GatewayRequest) -> BotModelRequest? {
            evidence
        }
    }

    /// Credential seam that counts resolutions, so a purpose denial can be
    /// proven to happen before any credential work.
    private final class CountingCredentialProvider: CredentialProvider, @unchecked Sendable {
        private let inner: StaticCredentialProvider
        private let lock = NSLock()
        private var resolutions = 0

        init(_ inner: StaticCredentialProvider) {
            self.inner = inner
        }

        var resolutionCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return resolutions
        }

        func credential(for scope: CredentialScope) async throws -> Credential {
            lock.lock()
            resolutions += 1
            lock.unlock()
            return try await inner.credential(for: scope)
        }

        func invalidate(_ credential: Credential, for scope: CredentialScope) async {}
    }

    private static let responseBody = Data(#"{"ok":true}"#.utf8)

    private func makeServer() throws -> MockUpstreamServer {
        let server = try MockUpstreamServer { _ in
            .full(status: 200,
                  headers: ["content-type": "application/json"],
                  body: Self.responseBody)
        }
        addTeardownBlock { server.stop() }
        return server
    }

    private func makeGateway(server: MockUpstreamServer,
                             purposeProvider: (any ModelPurposeProviding)?,
                             credentials: any CredentialProvider,
                             diagnostics: GatewayUpstreamDiagnostics = .standardError)
        -> ModelGateway {
        let configuration = ModelGatewayConfiguration(
            allowedUpstreamHosts: ["127.0.0.1:\(server.port)"],
            responseLogQuotaBytes: 1_000_000,
            backoff: ModelGatewayBackoffPolicy(initialDelay: 0,
                                               multiplier: 2,
                                               maximumDelay: 60,
                                               jitterFraction: 0,
                                               maximumAttempts: 2),
            upstreamRequestTimeout: 5)
        let gateway = ModelGateway(configuration: configuration,
                                   credentialProvider: credentials,
                                   clock: ManualGatewayClock(),
                                   modelPurposeProvider: purposeProvider,
                                   upstreamDiagnostics: diagnostics)
        addTeardownBlock { await gateway.shutdown() }
        return gateway
    }

    private func makeCredentials() -> CountingCredentialProvider {
        CountingCredentialProvider(makeBearerProvider(host: "127.0.0.1",
                                                      value: "test-credential"))
    }

    /// One Worker `/v1/http` exchange. The body carries the model the enforcer
    /// checks, exactly as a model request would; the gateway itself never reads
    /// it for a purpose.
    private func request(port: UInt16) -> GatewayRequest {
        GatewayRequest(method: "POST",
                       url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!,
                       headers: ["content-type": "application/json",
                                 "accept": "application/json"],
                       body: Data(#"{"model":"deepseek-flash","messages":[]}"#.utf8))
    }

    // MARK: - Present purpose: deny

    /// A small-model-only purpose asking for the large model is refused by the
    /// real enforcer, and the refusal happens before any credential is
    /// resolved and before any socket is opened.
    func testPresentPurposeDenyStopsBeforeCredentialAndSocket() async throws {
        let server = try makeServer()
        _ = try await server.start()
        let credentials = makeCredentials()
        let gateway = makeGateway(
            server: server,
            purposeProvider: FixedPurposeProvider(
                BotModelRequest(purpose: .triage, model: "deepseek-v4-pro")),
            credentials: credentials)

        let error = try await expectGatewayFailure(gateway.handle(request(port: server.port)))
        let denial = try XCTUnwrap(error as? BotModelPurposeError,
                                   "the denial is the frozen enforcer error, got \(error)")
        XCTAssertEqual(denial.code, "EPURPOSE_MODEL_DENIED")
        XCTAssertEqual(denial.purpose, .triage)
        XCTAssertNil(error as? ModelGatewayError,
                     "the execution point must not add a second gateway error code")
        XCTAssertEqual(server.requestCount, 0, "a denied purpose must not open a socket")
        XCTAssertEqual(credentials.resolutionCount, 0,
                       "a denied purpose must be answered before credential resolution")
    }

    /// An unknown purpose is denied with the same frozen code instead of
    /// silently becoming a permitted worker turn.
    func testUnknownPurposeIsDeniedWithTheFrozenCode() async throws {
        let server = try makeServer()
        _ = try await server.start()
        let credentials = makeCredentials()
        let gateway = makeGateway(
            server: server,
            purposeProvider: FixedPurposeProvider(
                BotModelRequest(purposeName: "not-a-purpose", model: "deepseek-flash")),
            credentials: credentials)

        let error = try await expectGatewayFailure(gateway.handle(request(port: server.port)))
        let denial = try XCTUnwrap(error as? BotModelPurposeError)
        XCTAssertEqual(denial.code, "EPURPOSE_MODEL_DENIED")
        XCTAssertTrue(denial.message.contains("not-a-purpose"),
                      "the denial must name the unknown value, got: \(denial.message)")
        XCTAssertEqual(server.requestCount, 0)
        XCTAssertEqual(credentials.resolutionCount, 0)
    }

    // MARK: - Present purpose: allow

    /// The same small-model-only purpose with the small model is allowed, and
    /// the exchange reaches the upstream and streams back unchanged.
    func testPresentPurposeAllowForwardsTheExchange() async throws {
        let server = try makeServer()
        _ = try await server.start()
        let credentials = makeCredentials()
        let gateway = makeGateway(
            server: server,
            purposeProvider: FixedPurposeProvider(
                BotModelRequest(purpose: .triage, model: "deepseek-flash")),
            credentials: credentials)

        let response = try await collectGatewayResponse(gateway.handle(request(port: server.port)))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body, Self.responseBody)
        XCTAssertEqual(server.requestCount, 1)
        XCTAssertEqual(server.requests.first?.method, "POST")
        XCTAssertEqual(credentials.resolutionCount, 1,
                       "an allowed purpose resolves the credential normally")
    }

    // MARK: - Absent purpose: baseline behaviour

    /// The absent branch is the baseline: same status, same body, same
    /// credential work, no denial and no new request/response member. The only
    /// visible effect is one host-internal `purpose_absent` diagnostic line per
    /// gateway (not per request, not on the wire).
    func testPurposeAbsentKeepsTheBaselineAndRecordsOneDiagnostic() async throws {
        let server = try makeServer()
        _ = try await server.start()
        let credentials = makeCredentials()
        let lines = LockedBox<[String]>([])
        let diagnostics = GatewayUpstreamDiagnostics(sink: { line in
            lines.mutate { $0.append(line) }
        })

        // Baseline: no purpose seam at all.
        let baseline = makeGateway(server: server,
                                   purposeProvider: nil,
                                   credentials: credentials,
                                   diagnostics: diagnostics)
        let baselineResponse = try await collectGatewayResponse(
            baseline.handle(request(port: server.port)))

        // Wired execution point, but this exchange has no purpose evidence.
        let absent = makeGateway(server: server,
                                 purposeProvider: FixedPurposeProvider(nil),
                                 credentials: credentials,
                                 diagnostics: diagnostics)
        let absentResponse = try await collectGatewayResponse(
            absent.handle(request(port: server.port)))

        XCTAssertEqual(baselineResponse.status, absentResponse.status)
        XCTAssertEqual(baselineResponse.status, 200)
        XCTAssertEqual(baselineResponse.body, absentResponse.body)
        XCTAssertEqual(absentResponse.body, Self.responseBody,
                       "the absent branch must not alter the response")
        XCTAssertEqual(server.requestCount, 2)
        XCTAssertEqual(credentials.resolutionCount, 2)

        // The diagnostic is host-internal: one line per gateway, host only.
        let purposeLines = lines.value.filter { $0.contains("purpose_absent") }
        XCTAssertEqual(purposeLines.count, 2, "one absent diagnostic per gateway")
        for line in purposeLines {
            XCTAssertEqual(line, "gateway-purpose purpose_absent host=127.0.0.1")
            XCTAssertFalse(line.contains("/v1/chat/completions"),
                           "the diagnostic must not carry the path: \(line)")
        }

        // A second request does not repeat the gateway-wide fact...
        _ = try await collectGatewayResponse(absent.handle(request(port: server.port)))
        XCTAssertEqual(lines.value.filter { $0.contains("purpose_absent") }.count, 2)

        // ...and nothing was added to either direction of the wire (P05).
        for recorded in server.requests {
            XCTAssertFalse(recorded.headers.keys.contains { $0.lowercased().contains("purpose") })
        }
        XCTAssertFalse(absentResponse.headers.keys.contains {
            $0.lowercased().contains("purpose")
        })
    }
}
