// SPDX-License-Identifier: MIT

import XCTest
import PhoneDSHBot
@testable import PhoneDSHProbe

private actor SeenBotIDs {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
    func all() -> [String] { values }
}

private func makeContactsObservation() throws -> BotContextObservation {
    try BotContextObservation(
        id: "contacts:query:a07", source: .contacts, kind: .contactsChanged,
        observedAt: 1_000, permissionRevision: 1,
        sourceVersion: .unversioned(),
        uncertainty: BotContextUncertainty(level: .medium, reason: "fixture"),
        delivery: .os,
        payload: .object([
            "query": .string("A07"),
            "count": .number(1),
            "items": .array([.object([
                "id": .string("contact-1"),
                "name": .string("A07 Fixture"),
                "masked": .bool(true),
            ])]),
        ]),
        dedupeKey: "contacts:query:a07", wakeRequested: false,
        resource: try? BotContextResource(
            kind: .contextSource, key: "contacts:a07", owner: "bot-a"))
}

@MainActor
final class BotContextContactsToolBridgeTests: XCTestCase {

    func testBridgeUsesBoundBotIDAndIgnoresForgedModelArgument() async throws {
        let seen = SeenBotIDs()
        let bridge = BotContextContactsToolBridge(botID: "bot-a") { botID, _, _ in
            await seen.record(botID)
            return try makeContactsObservation()
        }
        let output = try await bridge.callTool(
            name: "phone.contacts.search",
            arguments: #"{"query":"A07","limit":5,"botID":"bot-b","bot_id":"bot-b"}"#)
        XCTAssertTrue(output.contains(#""ok":true"#))
        XCTAssertTrue(output.contains(#""masked":true"#))
        XCTAssertTrue(output.contains(#""sourceKey":"contacts:a07""#))
        let ids = await seen.all()
        XCTAssertEqual(ids, ["bot-a"], "model-supplied bot ids must be ignored")
    }

    func testRevokedOrUnsubscribedContactsReturnsNotAuthorizedWithoutReading() async throws {
        let bridge = BotContextContactsToolBridge(botID: "bot-a") { _, _, _ in
            throw BotContextSourceError.revoked(.contacts)
        }
        let output = try await bridge.callTool(
            name: "phone.contacts.search", arguments: #"{"query":"A07"}"#)
        XCTAssertTrue(output.contains(#""ok":false"#))
        XCTAssertTrue(output.contains(#""code":"not_authorized""#))
    }

    func testConcurrentBotsDoNotCrossBind() async throws {
        let bridgeA = BotContextContactsToolBridge(botID: "bot-a") { _, query, _ in
            return try makeContactsObservation()
        }
        let bridgeB = BotContextContactsToolBridge(botID: "bot-b") { _, query, _ in
            return try makeContactsObservation()
        }
        async let a = bridgeA.callTool(name: "contacts.search", arguments: #"{"query":"A"}"#)
        async let b = bridgeB.callTool(name: "contacts.search", arguments: #"{"query":"B"}"#)
        let (first, second) = try await (a, b)
        XCTAssertTrue(first.contains(#""ok":true"#))
        XCTAssertTrue(second.contains(#""ok":true"#))
        XCTAssertTrue(first.contains(#""sourceKey":"contacts:a07""#))
        XCTAssertTrue(second.contains(#""sourceKey":"contacts:a07""#))
    }

    func testOrdinaryProjectionRequiresCurrentSequencedStandardPreset() {
        let valid: PhoneDSHProbe.BotJSONValue = .object([
            "kind": .string("sequenced"),
            "asOfSeq": .number(12),
            "values": .object(["agentPreset": .string("standard")]),
        ])
        XCTAssertTrue(BotContextContactsSessionBridge.isVerifiedOrdinaryProjection(valid))
        let invalid: [PhoneDSHProbe.BotJSONValue] = [
            .null,
            .object(["kind": .string("migration"), "asOfSeq": .number(12),
                     "values": .object(["agentPreset": .string("standard")])]),
            .object(["kind": .string("sequenced"),
                     "values": .object(["agentPreset": .string("standard")])]),
            .object(["kind": .string("sequenced"), "asOfSeq": .number(12),
                     "values": .object(["agentPreset": .string("bot")])]),
            .object(["kind": .string("sequenced"), "asOfSeq": .number(12),
                     "values": .object([:])]),
        ]
        for projection in invalid {
            XCTAssertFalse(BotContextContactsSessionBridge.isVerifiedOrdinaryProjection(projection))
        }
    }
}
