// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class RowProjectionGoldenTests: XCTestCase {
    func testSharedDisplayProjectionVectors() throws {
        let fixture = try RowTestSupport.golden("row-projection")
        let valid = try RowTestSupport.array(fixture["valid"], in: "row-projection.valid")
        for vector in valid {
            let input = try RowTestSupport.decode(BotJSONValue.self, vector["input"] as Any)
            guard case .object(let object) = input else { return XCTFail("projection input must be an object") }
            let actual = BotDisplayContract.project(object, profile: .upstreamReference)
            XCTAssertEqual(actual.surface, vector["surface"] as? String, "input: \(object)")
            XCTAssertEqual(actual.renderable, vector["renderable"] as? Bool, "input: \(object)")
            let expectedWire = try RowTestSupport.decode(BotWireRecord.self, vector["wire"] as Any)
            XCTAssertEqual(actual.wire, expectedWire, "input: \(object)")
        }

        let invalid = try RowTestSupport.array(fixture["invalid"], in: "row-projection.invalid")
        for vector in invalid {
            let input = try RowTestSupport.decode(BotJSONValue.self, vector["input"] as Any)
            guard case .object(let object) = input else { return XCTFail("projection input must be an object") }
            let actual = BotDisplayContract.project(object, profile: .upstreamReference)
            XCTAssertEqual(actual.surface, vector["surface"] as? String)
            XCTAssertEqual(actual.renderable, vector["renderable"] as? Bool)
        }
    }

    func testApprovalReceiptGoldenMatchesTheSharedLabels() throws {
        let fixture = try RowTestSupport.golden("row-protocol.phone")
        let receipts = try RowTestSupport.array(
            fixture["approvalReceipts"], in: "row-protocol.phone.approvalReceipts")
        XCTAssertFalse(receipts.isEmpty)
        for entry in receipts {
            let status = try XCTUnwrap(entry["status"] as? String)
            let scope = try XCTUnwrap(entry["scope"] as? String)
            let label = try XCTUnwrap(entry["label"] as? String)
            XCTAssertEqual(BotApprovalReceipt.label(for: status, scope: scope), label)
        }
        XCTAssertEqual(BotApprovalReceipt.label(for: "allowed"), "已允许一次")
        XCTAssertEqual(BotApprovalReceipt.label(for: "allowed-session"), "本次对话都允许")
        XCTAssertEqual(BotApprovalReceipt.label(for: "always", scope: "session"), "本次对话都允许")
    }

    func testPhoneAttachmentProjectionVectorUsesTheRealProjector() throws {
        let fixture = try RowTestSupport.golden("row-protocol.phone")
        let vectors = try RowTestSupport.array(fixture["projection"], in: "row-protocol.phone.projection")
        XCTAssertFalse(vectors.isEmpty)
        for vector in vectors {
            let input = try RowTestSupport.decode(BotJSONValue.self, vector["input"] as Any)
            guard case .object(let object) = input else { return XCTFail("projection input must be an object") }
            XCTAssertEqual(object["kind"]?.stringValue, "message")
            XCTAssertNotNil(object["attachments"], "phone projection vector must carry attachments")
            let actual = BotDisplayContract.project(object, profile: .upstreamReference)
            XCTAssertEqual(actual.surface, vector["surface"] as? String)
            XCTAssertEqual(actual.renderable, vector["renderable"] as? Bool)
            let expectedWire = try RowTestSupport.decode(BotWireRecord.self, vector["wire"] as Any)
            XCTAssertEqual(actual.wire, expectedWire)
        }
    }

    func testP1GoldenCardsRemainProtocolVisibleButNotPhoneP0Renderable() throws {
        let fixture = try RowTestSupport.golden("row-projection")
        let valid = try RowTestSupport.array(fixture["valid"], in: "row-projection.valid")
        var tested: Set<String> = []
        for vector in valid {
            let inputObject = try RowTestSupport.object(vector["input"], in: "row-projection.valid.input")
            guard let cardType = inputObject["cardType"] as? String,
                  BotDisplayContract.p1CardTypes.map(\.rawValue).contains(cardType) else { continue }
            tested.insert(cardType)
            let input = try RowTestSupport.decode(BotJSONValue.self, inputObject)
            guard case .object(let object) = input else { continue }
            XCTAssertTrue(BotDisplayContract.project(object, profile: .upstreamReference).renderable)
            let phone = BotDisplayContract.project(object, profile: .phoneP0)
            XCTAssertFalse(phone.renderable)
            XCTAssertEqual(phone.surface, BotDisplayContract.hidden)
        }
        XCTAssertEqual(tested, Set(BotDisplayContract.p1CardTypes.map(\.rawValue)))
    }

    func testKnownCardsWithoutSurfaceDataFailClosed() throws {
        let fixture = try RowTestSupport.golden("row-projection")
        let valid = try RowTestSupport.array(fixture["valid"], in: "row-projection.valid")
        var testedCards = false
        for vector in valid {
            var input = try RowTestSupport.object(vector["input"], in: "row-projection.valid.input")
            guard input["kind"] as? String == "card", input["cardType"] != nil else { continue }
            testedCards = true
            input = input.filter { ["kind", "cardType"].contains($0.key) }
            let decoded = try RowTestSupport.decode(BotJSONValue.self, input)
            guard case .object(let object) = decoded else { continue }
            XCTAssertFalse(BotDisplayContract.project(object, profile: .upstreamReference).renderable,
                           "empty card must not render: \(object)")
            XCTAssertFalse(BotDisplayContract.project(object, profile: .phoneP0).renderable)
        }
        XCTAssertTrue(testedCards)
    }
}
