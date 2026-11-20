// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// The cursor vectors in `spec/bot/v2/golden/connector-cursor.json` run through
/// the real codec and the pure scan transition. Every valid vector's expected
/// record is decoded by the same codec; every invalid record must be rejected.
final class ConnectorCursorGoldenTests: XCTestCase {
    private let path = "spec/bot/v2/golden/connector-cursor.json"

    func testValidVectorsDriveTheRealTransition() throws {
        let root = try wp6RepoRoot().appendingPathComponent(path)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: root))
        let document = try XCTUnwrap(object as? [String: Any])
        let valid = try XCTUnwrap(document["valid"] as? [[String: Any]])
        XCTAssertFalse(valid.isEmpty)

        for vector in valid {
            let id = try XCTUnwrap(vector["id"] as? String)
            let connector = try XCTUnwrap(
                (vector["connector"] as? String).flatMap(ConnectorKind.init(rawValue:)))
            let load = try storedLoad(vector["stored"], connector: connector)
            let head = try ConnectorCursorCodec.decodeValue(
                try XCTUnwrap(vector["head"]), connector: connector)
            let now = try XCTUnwrap((vector["now"] as? NSNumber)?.int64Value)
            let decision = ConnectorScanTransition.decide(
                connector: connector, stored: load, head: head, now: now)

            let expected = try XCTUnwrap(vector["expected"] as? [String: Any])
            let recordData = try JSONSerialization.data(
                withJSONObject: try XCTUnwrap(expected["record"]))
            let expectedRecord = try ConnectorCursorCodec.decode(recordData)
            XCTAssertEqual(decision.record, expectedRecord, id)
            XCTAssertEqual(decision.emitConnectorUpdate,
                           expected["emitConnectorUpdate"] as? Bool, id)

            // The writer must reproduce a decodable document with the same
            // semantics (sorted keys, exact closed members).
            let encoded = try ConnectorCursorCodec.encode(decision.record)
            XCTAssertEqual(try ConnectorCursorCodec.decode(encoded), expectedRecord, id)
        }
    }

    func testInvalidVectorsAreRejectedByTheRealCodec() throws {
        let root = try wp6RepoRoot().appendingPathComponent(path)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: root))
        let document = try XCTUnwrap(object as? [String: Any])
        let invalid = try XCTUnwrap(document["invalid"] as? [[String: Any]])
        XCTAssertFalse(invalid.isEmpty)
        for vector in invalid {
            let id = try XCTUnwrap(vector["id"] as? String)
            let record = try XCTUnwrap(vector["record"])
            let data = try JSONSerialization.data(withJSONObject: record)
            XCTAssertThrowsError(try ConnectorCursorCodec.decode(data), id)
        }
    }

    private func storedLoad(_ raw: Any?, connector: ConnectorKind) throws -> ConnectorCursorLoad {
        guard let raw, !(raw is NSNull) else { return .absent }
        guard let value = try? ConnectorCursorCodec.decodeValue(raw, connector: connector) else {
            return .corrupt
        }
        return .stored(ConnectorCursorState(
            connector: connector, cursor: value, updatedAt: 1))
    }
}
