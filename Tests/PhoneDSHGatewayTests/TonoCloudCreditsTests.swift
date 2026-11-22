// SPDX-License-Identifier: MIT
// spec/v1/tono-account.md §11 on the iOS gateway: the shared
// `credits_responses` cases judge the real policy, and the real `ModelGateway`
// forwards a cloud-origin 402 unchanged, never re-sends it (even for a
// replay-safe endpoint) and reports its credits condition once. Nothing here
// contacts pdsh.tonoai.cn.

import Foundation
import XCTest
@testable import PhoneDSHGateway
import PhoneDSHAgentCore

final class TonoCloudCreditsTests: XCTestCase {
    private struct Cases: Decodable {
        struct Item: Decodable {
            struct Expect: Decodable { var credits: String? }
            var name: String
            var url: URL
            var status: Int
            var body: RawJSON?
            var body_text: String?
            var pad_to_bytes: Int?
            var expect: Expect
        }
        var credits_responses: [Item]
    }

    private struct RawJSON: Decodable {
        let data: Data
        init(from decoder: Decoder) throws {
            data = try JSONSerialization.data(withJSONObject: try decoder.singleValueContainer().decode(Value.self).any,
                                              options: [.fragmentsAllowed, .sortedKeys])
        }
        private struct Value: Decodable {
            let any: Any
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if c.decodeNil() { any = NSNull() }
                else if let b = try? c.decode(Bool.self) { any = b }
                else if let i = try? c.decode(Int.self) { any = i }
                else if let s = try? c.decode(String.self) { any = s }
                else if let a = try? c.decode([Value].self) { any = a.map(\.any) }
                else { any = try c.decode([String: Value].self).mapValues(\.any) }
            }
        }
    }

    private func loadCases() throws -> Cases {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Cases.self, from: Data(contentsOf:
            root.appendingPathComponent("spec/v1/golden/tono-account/cases.json")))
    }

    private static func body(_ item: Cases.Item) -> Data {
        var body = item.body?.data ?? Data((item.body_text ?? "").utf8)
        if let target = item.pad_to_bytes { body.append(Data(repeating: 0x20, count: target - body.count)) }
        return body
    }

    func testCreditsResponsesMatchTheSharedCases() throws {
        let cases = try loadCases().credits_responses
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        for item in cases {
            let condition = TonoCloudResponsePolicy.production.creditsCondition(
                url: item.url, status: item.status, body: Self.body(item))
            XCTAssertEqual(condition?.rawValue, item.expect.credits, item.name)
            // A credits answer never changes the 401/503 decision.
            if item.status == 402 {
                XCTAssertEqual(TonoCloudResponsePolicy.production.decide(
                    url: item.url, status: 402, headers: [:], body: Self.body(item)), .forward, item.name)
            }
        }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [TonoCloudResponsePolicy.CreditsCondition] = []
        func add(_ c: TonoCloudResponsePolicy.CreditsCondition) { lock.withLock { items.append(c) } }
        var all: [TonoCloudResponsePolicy.CreditsCondition] { lock.withLock { items } }
    }

    private struct FixedProvider: CredentialProvider {
        func credential(for scope: CredentialScope) async throws -> Credential {
            Credential(kind: .apiKey(header: "x-api-key"), value: "at_TEST_ACCESS_0001")
        }
        func invalidate(_ credential: Credential, for scope: CredentialScope) async {}
    }

    /// Every 402 case on the gateway: one contact, the body unchanged, and the
    /// handler told exactly the shared condition (or nothing off-origin).
    func testGatewayForwardsCreditsAnswersOnceAndReportsThem() async throws {
        let cases = try loadCases().credits_responses.filter { $0.status == 402 }
        for item in cases {
            let body = Self.body(item)
            let server = try MockUpstreamServer { _ in
                .full(status: 402, headers: ["content-type": "application/json"], body: body)
            }
            let port = try await server.start()
            let local = "http://127.0.0.1:\(port)"
            // The case's cloud origin is played by the loopback upstream; an
            // off-origin case keeps the production policy, which never
            // matches loopback.
            let onCloud = item.expect.credits != nil
            let recorder = Recorder()
            let root = try makeTemporaryDirectory()
            let path = item.url.path
            let gateway = ModelGateway(
                configuration: ModelGatewayConfiguration(
                    allowedUpstreamHosts: ["127.0.0.1:\(port)"],
                    replaySafeModelEndpoints: [path],
                    responseLogQuotaBytes: 1_000_000,
                    backoff: ModelGatewayBackoffPolicy(initialDelay: 1, multiplier: 2, maximumDelay: 60,
                                                       jitterFraction: 0, maximumAttempts: 5),
                    upstreamRequestTimeout: 5),
                credentialProvider: FixedProvider(),
                responseLog: try ResponseLog(root: root, quotaBytes: 1_000_000),
                clock: ManualGatewayClock(),
                cloudResponsePolicy: onCloud ? TonoCloudResponsePolicy(origins: [local]) : .production,
                cloudCreditsHandler: { recorder.add($0) })
            let response = try await collectGatewayResponse(gateway.handle(GatewayRequest(
                method: "POST", url: URL(string: local + path)!,
                headers: ["content-type": "application/json", "x-api-key": "phone-host-injects-key"],
                body: Data(#"{"model":"deepseek-flash","messages":[]}"#.utf8))))
            XCTAssertEqual(response.status, 402, item.name)
            XCTAssertEqual(response.body, body, item.name)
            XCTAssertEqual(server.requests.count, 1, item.name)
            XCTAssertEqual(recorder.all.map(\.rawValue), item.expect.credits.map { [$0] } ?? [], item.name)
            await gateway.shutdown()
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
