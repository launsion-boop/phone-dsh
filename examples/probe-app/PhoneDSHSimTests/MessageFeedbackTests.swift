// SPDX-License-Identifier: MIT
// The message-feedback pin returns business failures as `{ok:false,error}`;
// regression tests drive the real client through a fake transport.

import Foundation
import PhoneDSHAgentCore
import ProbeKit
import XCTest

private actor MessageFeedbackTransport: DSHRemoteTransport {
    private var responses: [JSONValue]
    private(set) var calls: [(String, JSONValue)] = []

    init(responses: [JSONValue]) {
        self.responses = responses
    }

    func call(_ endpoint: String, args: JSONValue) async throws -> JSONValue {
        calls.append((endpoint, args))
        guard !responses.isEmpty else {
            throw ProviderError.invalidResponse("no scripted feedback response")
        }
        return responses.removeFirst()
    }

    func openMux() async throws -> any DSHMuxConnection {
        throw ProviderError.invalidResponse("message feedback does not open a mux stream")
    }
}

@MainActor
final class MessageFeedbackTests: XCTestCase {
    private func success() -> JSONValue {
        .object([
            "ok": .bool(true),
            "value": .object([
                "messageId": .string("message-1"),
                "rating": .string("positive"),
                "version": .string("v2"),
                "createdAt": .number(1_000),
                "updatedAt": .number(2_000),
            ]),
        ])
    }

    private func conflict(version: String?) -> JSONValue {
        var current: JSONValue = .null
        if let version {
            current = .object([
                "messageId": .string("message-1"),
                "rating": .string("negative"),
                "version": .string(version),
                "createdAt": .number(1_000),
                "updatedAt": .number(2_000),
            ])
        }
        return .object([
            "ok": .bool(false),
            "error": .object(["code": .string("version-conflict"), "current": current]),
        ])
    }

    private func request(_ call: (String, JSONValue)) -> JSONValue? {
        call.1["request"]
    }

    func testRateTreatsOkTrueAsSuccess() async throws {
        let transport = MessageFeedbackTransport(responses: [success()])
        try await MessageFeedbackClient(transport: transport)
            .rate(messageID: "message-1", sessionID: "session-1", positive: true)

        let calls = await transport.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0, "messageFeedback/put")
        XCTAssertEqual(request(calls[0])?["sessionId"]?.stringValue, "session-1")
        XCTAssertEqual(request(calls[0])?["messageId"]?.stringValue, "message-1")
        XCTAssertEqual(request(calls[0])?["rating"]?.stringValue, "positive")
        XCTAssertEqual(request(calls[0])?["ifVersion"], JSONValue.null)
    }

    func testVersionConflictRetriesOnceWithTheAuthoritativeVersion() async throws {
        let transport = MessageFeedbackTransport(responses: [conflict(version: "v7"), success()])
        try await MessageFeedbackClient(transport: transport)
            .rate(messageID: "message-1", sessionID: "session-1", positive: true)

        let calls = await transport.calls
        XCTAssertEqual(calls.count, 2, "one compare-and-set retry, never a loop")
        XCTAssertEqual(request(calls[0])?["ifVersion"], JSONValue.null)
        XCTAssertEqual(request(calls[1])?["ifVersion"]?.stringValue, "v7")
    }

    func testTargetNotFoundIsRejectedInsteadOfReportedAsSuccess() async throws {
        let transport = MessageFeedbackTransport(responses: [
            .object([
                "ok": .bool(false),
                "error": .object([
                    "code": .string("target-not-found"),
                    "sessionId": .string("session-1"),
                    "messageId": .string("message-1"),
                ]),
            ]),
        ])

        do {
            try await MessageFeedbackClient(transport: transport)
                .rate(messageID: "message-1", sessionID: "session-1", positive: true)
            XCTFail("a rejected feedback write must not be reported as success")
        } catch let error as MessageFeedbackError {
            XCTAssertEqual(error, .targetNotFound)
        }
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testSecondVersionConflictKeepsTheTypedBusinessFailure() async throws {
        let transport = MessageFeedbackTransport(responses: [
            conflict(version: "v7"), conflict(version: "v8"),
        ])

        do {
            try await MessageFeedbackClient(transport: transport)
                .rate(messageID: "message-1", sessionID: "session-1", positive: false)
            XCTFail("the second conflict must surface")
        } catch let error as MessageFeedbackError {
            XCTAssertEqual(error, .rejected(code: "version-conflict"))
        }
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 2)
    }
}
