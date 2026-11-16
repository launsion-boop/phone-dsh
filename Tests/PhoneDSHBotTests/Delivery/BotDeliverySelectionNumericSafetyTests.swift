// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// Root numeric-entry audit: a valid JSON number such as 1e300 must become an
/// explicit invalid delivery record, never a trapping `Int(number)` conversion.
/// The shared `JSONValue.intValue` is the one safe conversion primitive.
final class BotDeliverySelectionNumericSafetyTests: XCTestCase {
    func testSharedIntValueRejectsOutOfRangeAndNonFiniteNumbers() {
        XCTAssertNil(BotJSONValue.number(1e300).intValue)
        XCTAssertNil(BotJSONValue.number(-1e300).intValue)
        XCTAssertNil(BotJSONValue.number(.infinity).intValue)
        XCTAssertNil(BotJSONValue.number(.nan).intValue)
        // The shared helper rounds a fraction; it is trap-safe but not an
        // integer-domain validator. D's strict helper below rejects it.
        XCTAssertEqual(BotJSONValue.number(1.5).intValue, 2)
        XCTAssertEqual(BotJSONValue.number(1_700_000_000_000).intValue, 1_700_000_000_000)
    }

    func testDeliverySourceRejectsUnrepresentableObservedAt() {
        let base: [String: BotJSONValue] = [
            "ref": .string("workspace:docs/a.md@sha256:"
                + String(repeating: "a", count: 64)),
            "label": .string("a.md"),
        ]
        var valid = base
        valid["observed_at_ms"] = .number(1_700_000_000_000)
        XCTAssertEqual(BotDeliverySelectionSource.parse(.object(valid))?.observedAtMS,
                       1_700_000_000_000)

        for value in [1e300, -1e300, 1.5, Double.infinity, Double.nan] {
            var bad = base
            bad["observed_at_ms"] = .number(value)
            XCTAssertNil(BotDeliverySelectionSource.parse(.object(bad)),
                         "observed_at_ms \(value) must be invalid, not trapped")
        }
    }

    func testDeliveryDraftRejectsUnrepresentableRevisionAndTimestamps() throws {
        let base: [String: BotJSONValue] = [
            "approvalID": .string("approval-numeric"),
            "status": .string("pending"),
            "digest": .string("sha256:" + String(repeating: "b", count: 64)),
            "delivery": .object([
                "draft_id": .string("draft-numeric"),
                "revision": .number(1),
                "resources": .array([]),
            ]),
        ]
        XCTAssertNoThrow(try parse(base))
        for field in ["revision", "requestedAt", "expiresAt"] {
            var bad = base
            var delivery = (bad["delivery"]?.objectValue ?? [:])
            if field == "revision" {
                delivery["revision"] = .number(1e300)
                bad["delivery"] = .object(delivery)
            } else {
                bad[field] = .number(1e300)
            }
            XCTAssertThrowsError(try parse(bad), "\(field) 1e300 must fail closed")
        }
        var valid = base
        valid["requestedAt"] = .number(1_700_000_000_000)
        valid["expiresAt"] = .number(1_700_000_100_000)
        let draft = try parse(valid)
        XCTAssertEqual(draft.requestedAtMS, 1_700_000_000_000)
        XCTAssertEqual(draft.expiresAtMS, 1_700_000_100_000)
    }

    private func parse(_ data: [String: BotJSONValue]) throws -> BotDeliverySelectionDraft {
        guard let draft = BotDeliverySelectionDraft.parse(
            botID: "main", sessionID: "gb-main", approvalID: "approval-numeric",
            data: data, requestSeq: 1) else {
            struct Invalid: Error {}
            throw Invalid()
        }
        return draft
    }
}
