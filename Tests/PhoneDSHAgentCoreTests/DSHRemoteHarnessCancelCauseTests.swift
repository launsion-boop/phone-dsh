// SPDX-License-Identifier: MIT
// PhoneDSHAgentCore: DSH Remote cancel-cause regression tests.
//
// G2-FIX-76: `HarnessCommand.cancel` was cause-less, so `DSHRemoteHarness`
// always sent an anonymous user cancel. These tests pin the typed cause and the
// exact `session/cancel` request it produces; a fake transport records the
// request without a server, key or WKWebView.

import Foundation
import XCTest
@testable import PhoneDSHAgentCore

private final class RecordingRemoteTransport: DSHRemoteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(endpoint: String, args: JSONValue)] = []

    var calls: [(endpoint: String, args: JSONValue)] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func call(_ endpoint: String, args: JSONValue) async throws -> JSONValue {
        lock.lock()
        recorded.append((endpoint, args))
        lock.unlock()
        return .object([:])
    }

    func openMux() async throws -> any DSHMuxConnection {
        throw ProviderError.unsupported("the cancel test has no mux")
    }
}

final class DSHRemoteHarnessCancelCauseTests: XCTestCase {
    private func cancelRequest(_ cause: AgentCancelCause,
                               sessionID: String = "session-1") async throws
        -> JSONValue {
        let transport = RecordingRemoteTransport()
        let harness = DSHRemoteHarness(transport: transport)
        try await harness.send(.cancelWithCause(cause), to: sessionID)
        let call = try XCTUnwrap(transport.calls.first)
        XCTAssertEqual(call.endpoint, "session/cancel")
        let request = try XCTUnwrap(call.args["request"])
        XCTAssertEqual(request["sessionId"]?.stringValue, sessionID)
        return try XCTUnwrap(request["cause"])
    }

    func testBudgetCancelCauseReachesSessionCancelRequestUnchanged() async throws {
        let cause = try await cancelRequest(
            .budget("budget.max_model_requests=25 exceeded"))
        XCTAssertEqual(cause, .object([
            "kind": .string("hook"),
            "reason": .object([
                "kind": .string("budget"),
                "detail": .string("budget.max_model_requests=25 exceeded"),
            ]),
        ]))
    }

    func testTimeoutCancelCauseReachesSessionCancelRequestUnchanged() async throws {
        let cause = try await cancelRequest(
            .timeout("budget.max_minutes=10 elapsed"))
        XCTAssertEqual(cause, .object([
            "kind": .string("hook"),
            "reason": .object([
                "kind": .string("timeout"),
                "detail": .string("budget.max_minutes=10 elapsed"),
            ]),
        ]))
    }

    func testUserCancelCauseIsTheDSHUserShape() async throws {
        let cause = try await cancelRequest(.user)
        XCTAssertEqual(cause, .object(["kind": .string("user")]))
    }

    func testPlainCancelStillSendsNoCause() async throws {
        let transport = RecordingRemoteTransport()
        let harness = DSHRemoteHarness(transport: transport)
        try await harness.send(.cancel, to: "session-1")
        let call = try XCTUnwrap(transport.calls.first)
        XCTAssertEqual(call.endpoint, "session/cancel")
        XCTAssertNil(call.args["request"]?["cause"],
                     "the cause-less command keeps its existing shape")
    }
}
