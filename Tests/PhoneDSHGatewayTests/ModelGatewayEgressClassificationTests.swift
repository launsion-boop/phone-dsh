// SPDX-License-Identifier: MIT
// PhoneDSHGateway egress classification regression (ENG-04).
//
// G2-C09/G2-C10 showed the gateway allow-list only ever contained the model
// upstream, so every tool fetch was denied and the denial was not
// distinguishable from a transport problem. ENG-04 makes the effective
// allow-list the union of the model upstream hosts and the scenario/App
// `egressAllowHosts`, and completes the structured failure bridge with the
// `upstream_status` class and the URL error identity the loopback writer
// turns into `dns_failed` / `tls_failed` / `connect_timeout` /
// `transport_failed`.
//
// The tests use only the existing public surface plus the new union helper so
// the pre-ENG-04 code fails on the union assertion.

import Foundation
import XCTest
import PhoneDSHGateway
import PhoneDSHAgentCore

final class ModelGatewayEgressClassificationTests: XCTestCase {
    /// Credential provider that behaves like the scenario runner's
    /// `ScenarioCredentialProvider` for an allow-listed anonymous host.
    private struct AnonymousCredentialProvider: CredentialProvider {
        func credential(for scope: CredentialScope) async throws -> Credential { .none }
        func invalidate(_ credential: Credential, for scope: CredentialScope) async {}
    }

    private func makeGateway(allowedHosts: Set<String>,
                             maximumAttempts: Int = 1) -> ModelGateway {
        let configuration = ModelGatewayConfiguration(
            allowedUpstreamHosts: allowedHosts,
            responseLogQuotaBytes: 1_000_000,
            backoff: ModelGatewayBackoffPolicy(initialDelay: 0,
                                               multiplier: 2,
                                               maximumDelay: 60,
                                               jitterFraction: 0,
                                               maximumAttempts: maximumAttempts),
            upstreamRequestTimeout: 10)
        let gateway = ModelGateway(configuration: configuration,
                                   credentialProvider: AnonymousCredentialProvider())
        addTeardownBlock {
            await gateway.shutdown()
        }
        return gateway
    }

    private func request(port: UInt16, path: String = "/v1/file") -> GatewayRequest {
        GatewayRequest(method: "GET",
                       url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    }

    private func bridged(_ error: Error) -> NSError {
        error as NSError
    }

    // MARK: Allow-list

    /// The canonical allow-list contract: model upstream ∪ scenario
    /// `network.allow`, with blank entries dropped. This is exactly what
    /// `PhoneDSHConfiguration.resolvedGatewayConfiguration()` feeds to
    /// `ModelGateway` (the source wiring lives in the facade).
    func testScenarioAllowHostsAreUnionedWithModelUpstreamHosts() {
        let resolved = ModelGatewayConfiguration.effectiveAllowedUpstreamHosts(
            modelHosts: ["model.example.test"],
            egressAllowHosts: [" raw.githubusercontent.com ", "github.com", "  "])
        XCTAssertEqual(resolved,
                       ["model.example.test", "raw.githubusercontent.com", "github.com"],
                       "the scenario allow-list must extend, never replace, the model hosts")
        XCTAssertEqual(ModelGatewayConfiguration.effectiveAllowedUpstreamHosts(
            modelHosts: [], egressAllowHosts: []), [],
                       "an empty union still denies every host")
    }

    /// The catalog's `network.allow` lists (the scenario's egress contract)
    /// flow into the same union `PhoneDSHConfiguration.egressAllowHosts` uses.
    /// This is catalog-driven and generic: no scenario id is named here.
    func testCatalogNetworkAllowListsReachTheGatewayAllowList() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PhoneDSHGatewayTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
        let catalogURL = repoRoot.appendingPathComponent(
            "scripts/ci/scenarios/catalog.json")
        let data = try XCTUnwrap(try? Data(contentsOf: catalogURL),
                                 "the scenario catalog is required for this regression")
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let scenarios = try XCTUnwrap(object["scenarios"] as? [[String: Any]])
        let modelHost = "model.example.test"

        var checked = 0
        for scenario in scenarios {
            guard let id = scenario["id"] as? String else { continue }
            let allow: [String]
            if let network = scenario["network"] as? [String: Any],
               let hosts = network["allow"] as? [String] {
                allow = hosts
            } else if let network = scenario["network"] as? String,
                      network != "none" {
                allow = [network]
            } else {
                continue
            }
            guard !allow.isEmpty else { continue }
            let resolved = ModelGatewayConfiguration.effectiveAllowedUpstreamHosts(
                modelHosts: [modelHost], egressAllowHosts: Set(allow))
            for host in allow {
                XCTAssertTrue(resolved.contains(host),
                              "\(id): scenario allow host \(host) must reach the gateway allow-list")
            }
            XCTAssertTrue(resolved.contains(modelHost), "\(id): model host preserved")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0,
                             "the catalog must contain at least one network allow-list")
    }

    /// A host outside the union is denied before any connection; the denial is
    /// the distinguishable `host_not_allowed` cause, not a generic 502.
    func testHostOutsideTheUnionIsHostNotAllowed() async throws {
        let server = try MockUpstreamServer { _ in
            .full(status: 200, headers: [:], body: Data("should not run".utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }

        let gateway = makeGateway(allowedHosts: ["api.example.invalid"],
                                  maximumAttempts: 1)
        let error = try await expectGatewayFailure(gateway.handle(request(port: server.port)))
        guard case .hostNotAllowed(let host)? = error as? ModelGatewayError else {
            XCTFail("expected hostNotAllowed, got \(error)")
            return
        }
        XCTAssertEqual(host, "127.0.0.1")
        XCTAssertEqual((error as? ModelGatewayError)?.structuredErrorCode,
                       "host_not_allowed")
        XCTAssertEqual(bridged(error).userInfo[NSLocalizedFailureReasonErrorKey] as? String,
                       "host_not_allowed")
        XCTAssertEqual(server.requestCount, 0,
                       "a denied host must not contact the upstream")
    }

    /// The positive half of the G2-C09 defect: a host admitted only through
    /// `egressAllowHosts` (the scenario allow-list) is reachable and needs no
    /// model credential.
    func testHostInsideTheScenarioAllowListIsReachable() async throws {
        let server = try MockUpstreamServer { _ in
            .full(status: 200,
                  headers: ["content-type": "text/plain"],
                  body: Data("allow-listed body\n".utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }

        let resolved = ModelGatewayConfiguration.effectiveAllowedUpstreamHosts(
            modelHosts: ["api.example.invalid"],
            egressAllowHosts: ["127.0.0.1:\(server.port)"])
        let gateway = makeGateway(allowedHosts: resolved)
        let response = try await collectGatewayResponse(gateway.handle(request(port: server.port)))
        XCTAssertEqual(response.status, 200,
                       "a scenario-allow-listed host must reach the upstream")
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self),
                       "allow-listed body\n")
        XCTAssertNil(server.requests.first?.headers["authorization"],
                     "an anonymous egress host must not receive the model credential")
    }

    // MARK: Upstream status

    /// Plain tool egress is transparent: an upstream 5xx after the retry budget
    /// is forwarded with its own status (curl/git must see the real answer).
    /// The model-side caller instead surfaces it as the `upstream_status`
    /// class, which this test pins on the structured bridge.
    func testUpstreamFiveHundredIsForwardedAndClassifiedForModelCallers() async throws {
        let server = try MockUpstreamServer { _ in
            .full(status: 503, headers: [:], body: Data("upstream unavailable".utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let gateway = makeGateway(allowedHosts: ["127.0.0.1:\(server.port)"])
        let response = try await collectGatewayResponse(gateway.handle(request(port: server.port)))
        XCTAssertEqual(response.status, 503, "tool egress sees the upstream status")
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "upstream unavailable")

        let failure = ModelGatewayError.upstreamStatus(status: 503,
                                                      host: "api.example.test")
        XCTAssertEqual(failure.structuredErrorCode, "upstream_status")
        XCTAssertEqual(failure.proxyStatusCode, 502)
        XCTAssertEqual(failure.proxyErrorCode, "upstream")
        let nsError = bridged(failure)
        XCTAssertEqual(nsError.domain, "PhoneDSHGateway.ModelGatewayError")
        XCTAssertEqual(nsError.code, 7)
        XCTAssertEqual(nsError.userInfo[NSLocalizedFailureReasonErrorKey] as? String,
                       "upstream_status")
        let description = (failure as? LocalizedError)?.errorDescription ?? ""
        XCTAssertTrue(description.contains("api.example.test"), description)
        XCTAssertTrue(description.contains("503"), description)
    }

    // MARK: Transport identity

    /// Every transport failure keeps the URL Loading System identity that the
    /// loopback writer turns into the specific taxonomy class. This is the
    /// gateway half of the cross-module seam: reason code + `NSUnderlyingErrorKey`.
    func testTransportBridgeKeepsTheURLErrorIdentityForEveryClass() {
        let cases: [(name: String, urlCode: Int)] = [
            ("dns", NSURLErrorDNSLookupFailed),
            ("cannot find host", NSURLErrorCannotFindHost),
            ("tls", NSURLErrorSecureConnectionFailed),
            ("tls trust", NSURLErrorServerCertificateUntrusted),
            ("timeout", NSURLErrorTimedOut),
            ("transport", NSURLErrorNetworkConnectionLost),
        ]
        for item in cases {
            let failure = ModelGatewayError.transportFailure(
                reason: "scripted \(item.name)",
                underlyingDomain: NSURLErrorDomain,
                underlyingCode: item.urlCode)
            XCTAssertEqual(failure.structuredErrorCode, "transport_failure")
            let nsError = bridged(failure)
            XCTAssertEqual(nsError.userInfo[NSLocalizedFailureReasonErrorKey] as? String,
                           "transport_failure", item.name)
            let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            XCTAssertEqual(underlying?.domain, NSURLErrorDomain, item.name)
            XCTAssertEqual(underlying?.code, item.urlCode, item.name)
        }
    }
}
