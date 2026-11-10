// SPDX-License-Identifier: MIT
// spec/v1/tono-account.md §5–§6 on the iOS gateway: the shared
// `cloud_responses` cases judge the real policy, and the shared `retry_flows`
// drive the real `ModelGateway` against a local upstream that stands in for
// the cloud origin. Nothing here contacts pdsh.tonoai.cn.

import Foundation
import XCTest
@testable import PhoneDSHGateway
import PhoneDSHAgentCore

final class TonoCloudResponsePolicyTests: XCTestCase {
    private struct Cases: Decodable {
        struct Constants: Decodable {
            var cloud_origin: String
            var inspect_body_limit_bytes: Int
            var credential_retry_max: Int
            var identity_retry_max: Int
            var identity_retry_default_seconds: Double
            var identity_retry_cap_seconds: Double
        }
        struct CloudResponse: Decodable {
            struct Expect: Decodable {
                var action: String
                var delay_seconds: Double?
            }
            var name: String
            var url: URL
            var status: Int
            var headers: [String: String]?
            var body: AnyJSON?
            var body_text: String?
            var pad_to_bytes: Int?
            var expect: Expect
        }
        struct RetryFlow: Decodable {
            struct Response: Decodable {
                var status: Int
                var code: String?
                var retry_after: String?
            }
            struct Expect: Decodable {
                var contacts: Int
                var final_status: Int
                var invalidations: Int
                var sleeps_seconds: [Double]
            }
            var name: String
            var responses: [Response]
            var refresh: String
            var expect: Expect
        }
        var constants: Constants
        var cloud_responses: [CloudResponse]
        var retry_flows: [RetryFlow]
    }

    /// Raw JSON kept as bytes so a case body reaches the policy unchanged.
    private struct AnyJSON: Decodable {
        let data: Data
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(JSONAny.self)
            data = try JSONSerialization.data(withJSONObject: value.value, options: [.fragmentsAllowed, .sortedKeys])
        }
    }

    private struct JSONAny: Decodable {
        let value: Any
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { value = NSNull() }
            else if let b = try? c.decode(Bool.self) { value = b }
            else if let i = try? c.decode(Int.self) { value = i }
            else if let d = try? c.decode(Double.self) { value = d }
            else if let s = try? c.decode(String.self) { value = s }
            else if let a = try? c.decode([JSONAny].self) { value = a.map(\.value) }
            else { value = try c.decode([String: JSONAny].self).mapValues(\.value) }
        }
    }

    private func loadCases() throws -> Cases {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("spec/v1/golden/tono-account/cases.json")
        return try JSONDecoder().decode(Cases.self, from: Data(contentsOf: fixture))
    }

    func testConstantsMatchTheSharedCases() throws {
        let constants = try loadCases().constants
        XCTAssertEqual(constants.cloud_origin, TonoCloudResponsePolicy.cloudOrigin)
        XCTAssertEqual(constants.inspect_body_limit_bytes, TonoCloudResponsePolicy.inspectBodyLimit)
        XCTAssertEqual(constants.credential_retry_max, TonoCloudResponsePolicy.credentialRetryMax)
        XCTAssertEqual(constants.identity_retry_max, TonoCloudResponsePolicy.identityRetryMax)
        XCTAssertEqual(constants.identity_retry_default_seconds, TonoCloudResponsePolicy.identityRetryDefaultSeconds)
        XCTAssertEqual(constants.identity_retry_cap_seconds, TonoCloudResponsePolicy.identityRetryCapSeconds)
    }

    func testCloudResponsesMatchTheSharedCases() throws {
        let cases = try loadCases()
        XCTAssertFalse(cases.cloud_responses.isEmpty)
        for item in cases.cloud_responses {
            var body = item.body?.data ?? Data((item.body_text ?? "").utf8)
            if let target = item.pad_to_bytes {
                XCTAssertLessThanOrEqual(body.count, target, item.name)
                body.append(Data(repeating: 0x20, count: target - body.count))
            }
            let decision = TonoCloudResponsePolicy.production.decide(
                url: item.url, status: item.status, headers: item.headers ?? [:], body: body)
            switch item.expect.action {
            case "forward": XCTAssertEqual(decision, .forward, item.name)
            case "refresh_retry": XCTAssertEqual(decision, .refreshRetry, item.name)
            case "retry_after":
                XCTAssertEqual(decision, .retryAfter(try XCTUnwrap(item.expect.delay_seconds)), item.name)
            default: XCTFail("unknown action \(item.expect.action) in \(item.name)")
            }
        }
    }

    // MARK: - Retry flows on the real gateway

    /// A provider that hands out a token, counts invalidations, and on
    /// invalidation switches to the case's refresh behaviour.
    private final class FlowProvider: CredentialProvider, @unchecked Sendable {
        private let lock = NSLock()
        private let refresh: String
        private var value = "at_TEST_ACCESS_0001"
        private var unavailable = false
        private(set) var invalidations = 0

        init(refresh: String) { self.refresh = refresh }

        func credential(for scope: CredentialScope) async throws -> Credential {
            let (current, failed) = lock.withLock { (value, unavailable) }
            if failed { throw ProviderError.unauthorized("refresh failed") }
            return Credential(kind: .apiKey(header: "x-api-key"), value: current)
        }

        func invalidate(_ credential: Credential, for scope: CredentialScope) async {
            lock.withLock {
                invalidations += 1
                switch refresh {
                case "new_value": value = "at_TEST_ACCESS_\(1 + invalidations)"
                case "unavailable": unavailable = true
                default: break
                }
            }
        }

        var count: Int { lock.withLock { invalidations } }
    }

    private final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [MockHTTPResponse]
        init(_ responses: [MockHTTPResponse]) { self.responses = responses }
        func next() -> MockHTTPResponse {
            lock.withLock {
                responses.isEmpty
                    ? .full(status: 599, headers: [:], body: Data("script exhausted".utf8))
                    : responses.removeFirst()
            }
        }
    }

    func testRetryFlowsMatchTheSharedCases() async throws {
        let cases = try loadCases()
        XCTAssertFalse(cases.retry_flows.isEmpty)
        for flow in cases.retry_flows {
            let scripted = flow.responses.map { response -> MockHTTPResponse in
                var headers = ["content-type": "application/json"]
                if let retryAfter = response.retry_after { headers["retry-after"] = retryAfter }
                let body = response.code.map { #"{"error":{"code":"\#($0)"}}"# } ?? #"{"ok":true}"#
                return .full(status: response.status, headers: headers, body: Data(body.utf8))
            }
            let script = Script(scripted)
            let server = try MockUpstreamServer { _ in script.next() }
            let port = try await server.start()
            let provider = FlowProvider(refresh: flow.refresh)
            let clock = ManualGatewayClock()
            let root = try makeTemporaryDirectory()
            let configuration = ModelGatewayConfiguration(
                allowedUpstreamHosts: ["127.0.0.1:\(port)"],
                // No replay-safe endpoint: the re-sends must not depend on it.
                replaySafeModelEndpoints: [],
                responseLogQuotaBytes: 1_000_000,
                backoff: ModelGatewayBackoffPolicy(initialDelay: 1, multiplier: 2, maximumDelay: 60,
                                                   jitterFraction: 0, maximumAttempts: 5),
                upstreamRequestTimeout: 5)
            let gateway = ModelGateway(
                configuration: configuration,
                credentialProvider: provider,
                responseLog: try ResponseLog(root: root, quotaBytes: 1_000_000),
                clock: clock,
                cloudResponsePolicy: TonoCloudResponsePolicy(origins: ["http://127.0.0.1:\(port)"]))
            let request = GatewayRequest(
                method: "POST",
                url: URL(string: "http://127.0.0.1:\(port)/v1/llm/anthropic/v1/messages")!,
                headers: ["content-type": "application/json", "x-api-key": "phone-host-injects-key"],
                body: Data(#"{"model":"deepseek-flash","messages":[]}"#.utf8))
            let response = try await collectGatewayResponse(gateway.handle(request))

            XCTAssertEqual(server.requests.count, flow.expect.contacts, flow.name)
            XCTAssertEqual(response.status, flow.expect.final_status, flow.name)
            XCTAssertEqual(provider.count, flow.expect.invalidations, flow.name)
            XCTAssertEqual(clock.sleeps, flow.expect.sleeps_seconds, flow.name)
            // Every contact carried exactly one injected credential and the
            // same body; the Worker placeholder never reached the upstream.
            for observed in server.requests {
                XCTAssertNotEqual(observed.headers["x-api-key"], "phone-host-injects-key", flow.name)
                XCTAssertNil(observed.headers["authorization"], flow.name)
                XCTAssertEqual(observed.body, request.body, flow.name)
            }
            if flow.expect.final_status != 200, let last = flow.responses.last?.code {
                // A forwarded answer is byte-identical.
                XCTAssertEqual(String(decoding: response.body, as: UTF8.self), #"{"error":{"code":"\#(last)"}}"#, flow.name)
            }
            await gateway.shutdown()
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testOtherOriginsKeepTheExistingSurface() async throws {
        // The production policy never matches a loopback upstream, so a 401
        // `credential_expired` there is forwarded with one contact.
        let server = try MockUpstreamServer { _ in
            .full(status: 401, headers: ["content-type": "application/json"],
                  body: Data(#"{"error":{"code":"credential_expired"}}"#.utf8))
        }
        let port = try await server.start()
        addTeardownBlock { server.stop() }
        let provider = FlowProvider(refresh: "new_value")
        let root = try makeTemporaryDirectory()
        let gateway = ModelGateway(
            configuration: ModelGatewayConfiguration(allowedUpstreamHosts: ["127.0.0.1:\(port)"],
                                                     upstreamRequestTimeout: 5),
            credentialProvider: provider,
            responseLog: try ResponseLog(root: root, quotaBytes: 1_000_000))
        let response = try await collectGatewayResponse(gateway.handle(GatewayRequest(
            method: "POST", url: URL(string: "http://127.0.0.1:\(port)/v1/messages")!,
            headers: ["content-type": "application/json"], body: Data("{}".utf8))))
        XCTAssertEqual(response.status, 401)
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(provider.count, 0)
        await gateway.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}
