// SPDX-License-Identifier: MIT
// W0 skeleton checks for PhoneDSHGateway, updated by W1-GATEWAY to the
// PLAN §2.5 policy values (1 s base, 60 s cap, five attempts).

import Foundation
import XCTest
@testable import PhoneDSHGateway

final class ModelGatewaySkeletonTests: XCTestCase {
    func testConfigurationDefaults() {
        let configuration = ModelGatewayConfiguration()
        XCTAssertTrue(configuration.allowedUpstreamHosts.isEmpty)
        XCTAssertEqual(configuration.responseLogQuotaBytes, 128 * 1024 * 1024)
        XCTAssertEqual(configuration.responseLogHeaderNames, ["accept", "content-type"])
        XCTAssertEqual(configuration.backoff.initialDelay, 1)
        XCTAssertEqual(configuration.backoff.multiplier, 2)
        XCTAssertEqual(configuration.backoff.maximumDelay, 60)
        XCTAssertEqual(configuration.backoff.maximumAttempts, 5)
    }

    func testUpstreamHostsAreASet() {
        let configuration = ModelGatewayConfiguration(
            allowedUpstreamHosts: ["api.example.invalid", "api.example.invalid"])
        XCTAssertEqual(configuration.allowedUpstreamHosts.count, 1)
    }

    func testResponseLogEntryDefaultsToNotFinal() {
        let entry = ResponseLogEntry(requestID: "req-1", sequence: 0, body: Data("x".utf8))
        XCTAssertFalse(entry.isFinal)
    }

    func testBackoffSchedule() {
        let policy = ModelGatewayBackoffPolicy(jitterFraction: 0, maximumAttempts: 5)
        XCTAssertEqual(policy.delay(forRetry: 1, retryAfter: nil), 1)
        XCTAssertEqual(policy.delay(forRetry: 2, retryAfter: nil), 2)
        XCTAssertEqual(policy.delay(forRetry: 3, retryAfter: nil), 4)
        XCTAssertEqual(policy.delay(forRetry: 4, retryAfter: nil), 8)
        XCTAssertEqual(policy.delay(forRetry: 5, retryAfter: nil), 16)
        XCTAssertEqual(policy.delay(forRetry: 5, retryAfter: 120), 60)
    }

    func testRetryAfterSecondsAndDate() {
        XCTAssertEqual(ModelGateway.retryAfter(headers: ["retry-after": "3"],
                                               now: Date(timeIntervalSince1970: 10)), 3)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let date = httpDate(now.addingTimeInterval(7))
        let parsed = ModelGateway.retryAfter(headers: ["retry-after": date], now: now)
        XCTAssertEqual(parsed ?? -1, 7, accuracy: 0.5)
        XCTAssertNil(ModelGateway.retryAfter(headers: ["retry-after": "soon"], now: now))
    }

    func testProxyErrorMappingForEgressLayer() {
        XCTAssertEqual(ModelGatewayError.hostNotAllowed("x").proxyStatusCode, 403)
        XCTAssertEqual(ModelGatewayError.hostNotAllowed("x").proxyErrorCode, "forbidden")
        XCTAssertEqual(ModelGatewayError.credentialUnavailable.proxyStatusCode, 502)
        XCTAssertEqual(ModelGatewayError.credentialUnavailable.proxyErrorCode, "credential_unavailable")
        XCTAssertEqual(ModelGatewayError.invalidRequest("x").proxyStatusCode, 400)
    }

    func testJitterStaysWithinFractionOfTheExponentialDelay() {
        let policy = ModelGatewayBackoffPolicy(jitterFraction: 0.2)
        for _ in 0..<50 {
            let delay = policy.delay(forRetry: 2, retryAfter: nil)
            XCTAssertGreaterThanOrEqual(delay, 2 * 0.8)
            XCTAssertLessThanOrEqual(delay, 2)
        }
    }

    func testResponseLogFactoryUsesConfiguredQuota() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = ModelGatewayConfiguration(responseLogQuotaBytes: 4096)
        let log = try ModelGateway.makeResponseLog(configuration: configuration,
                                                   workspaceRoot: root)
        XCTAssertEqual(log.quotaBytes, 4096)
    }

    func testSHA256KnownAnswers() {
        XCTAssertEqual(GatewaySHA256.hexDigest(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let long = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        XCTAssertEqual(GatewaySHA256.hexDigest(Data(long.utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }
}
