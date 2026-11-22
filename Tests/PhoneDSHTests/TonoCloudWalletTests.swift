// SPDX-License-Identifier: MIT
// spec/v1/tono-account.md §10–§11 on iOS: the shared `wallet_responses`,
// `claim_responses`, `credit_display` and `credits_guidance` cases judge the
// real classifier, and the real client talks to a local fake transport.
// Nothing here contacts pdsh.tonoai.cn.

import Foundation
import XCTest
@testable import PhoneDSH
import PhoneDSHGateway

final class TonoCloudWalletTests: XCTestCase {
    private struct Cases: Decodable {
        struct Constants: Decodable {
            var wallet_path: String
            var claim_path: String
            var micro_credits_per_credit: Int
            var micro_credits_max_digits: Int
        }
        struct Answer: Decodable {
            struct Expect: Decodable {
                var outcome: String
                var available_micro_credits: String?
                var claimable: Bool?
                var mode: String?
                var granted_now: Bool?
            }
            var name: String
            var status: Int
            var body: RawJSON?
            var body_text: String?
            var expect: Expect
        }
        struct Display: Decodable { var micro: String; var expect: String }
        struct Guidance: Decodable { var credits: String; var wallet_claimable: Bool?; var expect: String }
        var constants: Constants
        var wallet_responses: [Answer]
        var claim_responses: [Answer]
        var credit_display: [Display]
        var credits_guidance: [Guidance]
    }

    private struct RawJSON: Decodable {
        let data: Data
        init(from decoder: Decoder) throws {
            data = try JSONSerialization.data(withJSONObject: try decoder.singleValueContainer().decode(Value.self).any,
                                              options: [.fragmentsAllowed])
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

    private static func answer(_ item: Cases.Answer) -> TonoAccountProtocol.Answer {
        TonoAccountProtocol.Answer(status: item.status, headers: [:],
                                   body: item.body?.data ?? Data((item.body_text ?? "").utf8))
    }

    private static func name(_ outcome: TonoCloudWalletProtocol.ReadOutcome) -> String {
        switch outcome {
        case .wallet: return "wallet"
        case .protocolError: return "protocol_error"
        case .unauthorized: return "unauthorized"
        case .rejected: return "rejected"
        case .unavailable: return "unavailable"
        case .transient: return "transient"
        }
    }

    func testConstantsMatchTheSharedCases() throws {
        let constants = try loadCases().constants
        XCTAssertEqual(constants.wallet_path, TonoCloudWalletProtocol.walletPath)
        XCTAssertEqual(constants.claim_path, TonoCloudWalletProtocol.claimPath)
        XCTAssertEqual(constants.micro_credits_per_credit, TonoCloudWalletProtocol.microCreditsPerCredit)
        XCTAssertEqual(constants.micro_credits_max_digits, TonoCloudWalletProtocol.microCreditsMaxDigits)
    }

    func testWalletResponsesMatchTheSharedCases() throws {
        let cases = try loadCases().wallet_responses
        XCTAssertGreaterThanOrEqual(cases.count, 20)
        for item in cases {
            let outcome = TonoCloudWalletProtocol.classifyRead(Self.answer(item))
            XCTAssertEqual(Self.name(outcome), item.expect.outcome, item.name)
            if case .wallet(let wallet) = outcome {
                XCTAssertEqual(wallet.availableMicroCredits, item.expect.available_micro_credits, item.name)
                XCTAssertEqual(wallet.claimable, item.expect.claimable, item.name)
                XCTAssertEqual(wallet.mode, item.expect.mode, item.name)
            }
        }
        XCTAssertEqual(Self.name(TonoCloudWalletProtocol.classifyRead(nil)), "transient")
    }

    func testClaimResponsesMatchTheSharedCases() throws {
        let cases = try loadCases().claim_responses
        XCTAssertGreaterThanOrEqual(cases.count, 8)
        for item in cases {
            switch TonoCloudWalletProtocol.classifyClaim(Self.answer(item)) {
            case .claimed(let grantedNow, let wallet):
                XCTAssertEqual("claimed", item.expect.outcome, item.name)
                XCTAssertEqual(grantedNow, item.expect.granted_now, item.name)
                XCTAssertEqual(wallet.availableMicroCredits, item.expect.available_micro_credits, item.name)
                XCTAssertEqual(wallet.claimable, item.expect.claimable, item.name)
            case .protocolError: XCTAssertEqual("protocol_error", item.expect.outcome, item.name)
            case .unauthorized: XCTAssertEqual("unauthorized", item.expect.outcome, item.name)
            case .rejected: XCTAssertEqual("rejected", item.expect.outcome, item.name)
            case .unavailable: XCTAssertEqual("unavailable", item.expect.outcome, item.name)
            case .transient: XCTAssertEqual("transient", item.expect.outcome, item.name)
            }
        }
    }

    func testCreditDisplayMatchesTheSharedCases() throws {
        for item in try loadCases().credit_display {
            XCTAssertEqual(TonoCloudWalletProtocol.displayCredits(item.micro), item.expect, item.micro)
        }
        XCTAssertNil(TonoCloudWalletProtocol.displayCredits("-1"))
        XCTAssertNil(TonoCloudWalletProtocol.displayCredits(""))
    }

    func testGuidanceMatchesTheSharedCases() throws {
        for item in try loadCases().credits_guidance {
            let condition = try XCTUnwrap(TonoCreditsCondition(rawValue: item.credits))
            XCTAssertEqual(TonoCloudWalletProtocol.guidance(condition, walletClaimable: item.wallet_claimable).rawValue,
                           item.expect, "\(item.credits)/\(String(describing: item.wallet_claimable))")
        }
    }

    // MARK: - Client

    private final class Tokens: TonoAccessTokenSource, @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        private var rotateTo: String?
        private(set) var invalidations = 0
        init(_ value: String?, rotateTo: String? = nil) { self.value = value; self.rotateTo = rotateTo }
        func accessToken() async throws -> String? { lock.withLock { value } }
        func invalidate(accessToken: String) async {
            lock.withLock { invalidations += 1; if let next = rotateTo { value = next } }
        }
        var hasSession: Bool { lock.withLock { value != nil } }
    }

    private final class Fake: TonoAccountTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [TonoAccountProtocol.Answer]
        private(set) var requests: [URLRequest] = []
        init(_ answers: [TonoAccountProtocol.Answer]) { self.answers = answers }
        func send(_ request: URLRequest) async throws -> TonoAccountProtocol.Answer {
            try lock.withLock {
                requests.append(request)
                guard !answers.isEmpty else { throw URLError(.notConnectedToInternet) }
                return answers.removeFirst()
            }
        }
        var sent: [URLRequest] { lock.withLock { requests } }
    }

    private static let walletBody = Data(#"{"available_micro_credits":"4000000000","claimable":false,"mode":"live"}"#.utf8)

    func testSignedOutNeverContactsTheCloud() async {
        let fake = Fake([])
        let client = TonoCloudWalletClient(transport: fake, tokens: Tokens(nil))
        let read = await client.read()
        let claim = await client.claim()
        XCTAssertNil(read)
        XCTAssertNil(claim)
        XCTAssertTrue(fake.sent.isEmpty)
    }

    func testRequestsCarryTheBearerTokenOnly() async throws {
        let claimBody = Data(#"{"granted_now":false,"wallet":{"available_micro_credits":"0","claimable":false}}"#.utf8)
        let fake = Fake([.init(status: 200, headers: [:], body: Self.walletBody),
                         .init(status: 200, headers: [:], body: claimBody)])
        let client = TonoCloudWalletClient(transport: fake, tokens: Tokens("at_TEST_ACCESS_0001"))
        let read = await client.read()
        XCTAssertEqual(read, .wallet(TonoCloudWallet(availableMicroCredits: "4000000000", claimable: false, mode: "live")))
        // `granted_now: false` is a success, not an error.
        let claim = await client.claim()
        XCTAssertEqual(claim, .claimed(grantedNow: false,
                                       wallet: TonoCloudWallet(availableMicroCredits: "0", claimable: false, mode: nil)))
        let sent = fake.sent
        XCTAssertEqual(sent.map(\.url?.absoluteString), ["https://pdsh.tonoai.cn/v1/wallet",
                                                         "https://pdsh.tonoai.cn/v1/wallet/claim"])
        XCTAssertEqual(sent.map(\.httpMethod), ["GET", "POST"])
        for request in sent {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer at_TEST_ACCESS_0001")
            XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
            XCTAssertEqual(request.httpBody ?? Data(), Data())
        }
    }

    func testExpiredTokenIsRefreshedAndResentOnce() async {
        let expired = TonoAccountProtocol.Answer(status: 401, headers: [:],
                                                 body: Data(#"{"error":{"code":"credential_expired"}}"#.utf8))
        let fake = Fake([expired, .init(status: 200, headers: [:], body: Self.walletBody)])
        let tokens = Tokens("at_TEST_ACCESS_0001", rotateTo: "at_TEST_ACCESS_0002")
        let read = await TonoCloudWalletClient(transport: fake, tokens: tokens).read()
        XCTAssertEqual(read, .wallet(TonoCloudWallet(availableMicroCredits: "4000000000", claimable: false, mode: "live")))
        XCTAssertEqual(tokens.invalidations, 1)
        XCTAssertEqual(fake.sent.last?.value(forHTTPHeaderField: "Authorization"), "Bearer at_TEST_ACCESS_0002")

        // The same value after invalidation: the 401 stands, one contact.
        let again = Fake([expired])
        let unchanged = await TonoCloudWalletClient(transport: again, tokens: Tokens("at_TEST_ACCESS_0001")).read()
        XCTAssertEqual(unchanged, .unauthorized)
        XCTAssertEqual(again.sent.count, 1)
    }

    func testSignalReachesListenersOnly() async {
        var iterator = TonoCloudCreditsSignal.conditions().makeAsyncIterator()
        TonoCloudCreditsSignal.post(.notClaimed)
        let first = await iterator.next()
        XCTAssertEqual(first, .notClaimed)
    }
}
