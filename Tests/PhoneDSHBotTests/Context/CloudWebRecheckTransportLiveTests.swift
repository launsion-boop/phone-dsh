// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Real phone→cloud hop against SC's controlled loopback assembly. Gated on
/// PDSH_CLOUD_BASE_URL/PDSH_CLOUD_TOKEN; the phase selects the upstream mode
/// that the caller set with SC's set-mode.sh before this process started.
final class CloudWebRecheckTransportLiveTests: XCTestCase {
    private var baseURL: URL!
    private var token: String!
    private var phase: String!
    private var stateURL: URL!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["PDSH_CLOUD_BASE_URL"],
              let token = env["PDSH_CLOUD_TOKEN"],
              let phase = env["PDSH_CLOUD_PHASE"] else {
            throw XCTSkip("SC cloud freshness session is not supplied")
        }
        baseURL = try XCTUnwrap(URL(string: base))
        self.token = token
        self.phase = phase
        stateURL = URL(fileURLWithPath: env["PDSH_CLOUD_STATE_PATH"]
            ?? NSTemporaryDirectory() + "/c-cloud-live-state.json")
    }

    func testRealCloudFetchNormalizedBasisAndFailures() async throws {
        let target = phase == "private"
            ? "http://127.0.0.1/secret"
            : "https://public.example/freshness-report"
        let identity = BotWebResourceIdentity(kind: .webURL, url: target, owner: "bot-a")
        let token = self.token!
        let baseURL = self.baseURL!
        let transport = CloudWebRecheckTransport(
            configuration: .init(baseURL: baseURL),
            tokenProvider: { token })
        let rechecker = BotWebSourceRechecker(transport: transport)

        let baseline: BotWebRevision?
        if phase == "b", let data = try? Data(contentsOf: stateURL) {
            baseline = try JSONDecoder().decode(BotWebRevision.self, from: data)
        } else {
            baseline = nil
        }
        let outcome = await rechecker.recheck(
            BotWebRecheckRequest(resource: identity, baseline: baseline))

        switch phase {
        case "a":
            guard case let .observed(current, _, httpStatus) = outcome else {
                return XCTFail("expected first observation, got \(outcome)")
            }
            XCTAssertEqual(httpStatus, 200)
            XCTAssertEqual(current.basis, .contentSHA256)
            XCTAssertTrue(current.value.hasPrefix("sha256:"))
            try JSONEncoder().encode(current).write(to: stateURL)
        case "b":
            guard case let .changed(_, current) = outcome else {
                return XCTFail("expected changed after content_b, got \(outcome)")
            }
            XCTAssertEqual(current.basis, .contentSHA256)
        case "error_500":
            guard case .unavailable = outcome else {
                return XCTFail("expected unavailable on upstream 500, got \(outcome)")
            }
        case "private":
            guard case .denied = outcome else {
                return XCTFail("expected denied on private target, got \(outcome)")
            }
        default:
            XCTFail("unknown phase \(phase!)")
        }
    }
}
