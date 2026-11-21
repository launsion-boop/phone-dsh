// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// The shared `decisions.semanticInvalid` vectors pass the JSON schema but must
/// be rejected by the real candidate decoder: `connector-update` has no default
/// copy, so a missing/blank title or body is a construct error with the exact
/// code and path frozen in `spec/bot/v2/golden/proactive.json`.
final class ConnectorUpdateSemanticInvalidTests: XCTestCase {
    private let path = "spec/bot/v2/golden/proactive.json"

    func testSemanticInvalidVectorsAreRejectedWithTheFrozenCodeAndPath() throws {
        let url = try wp6RepoRoot().appendingPathComponent(path)
        let document = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let decisions = try XCTUnwrap(document["decisions"] as? [String: Any])
        let invalid = try XCTUnwrap(decisions["semanticInvalid"] as? [[String: Any]])
        XCTAssertEqual(invalid.count, 3)

        for vector in invalid {
            let name = try XCTUnwrap(vector["name"] as? String)
            let candidate = try XCTUnwrap(vector["candidate"])
            let data = try JSONSerialization.data(withJSONObject: candidate)
            do {
                _ = try ProactiveCandidateDecoder.decode(data)
                XCTFail("\(name): expected the candidate decoder to reject it")
            } catch let error as ProactiveCandidateValidationError {
                XCTAssertEqual(error.code, vector["error"] as? String, name)
                XCTAssertEqual(error.path, vector["path"] as? String, name)
            }
        }
    }

    func testTheValidConnectorVectorStillDecodes() throws {
        let url = try wp6RepoRoot().appendingPathComponent(path)
        let document = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let decisions = try XCTUnwrap(document["decisions"] as? [String: Any])
        let valid = try XCTUnwrap(decisions["valid"] as? [[String: Any]])
        let connector = try XCTUnwrap(valid.first {
            ($0["name"] as? String)?.contains("connector-update-delivers") == true
        })
        let steps = try XCTUnwrap(connector["steps"] as? [[String: Any]])
        let candidate = try XCTUnwrap(steps.first?["candidate"])
        let data = try JSONSerialization.data(withJSONObject: candidate)
        let decoded = try ProactiveCandidateDecoder.decode(data)
        XCTAssertEqual(decoded.kind, .connectorUpdate)
        XCTAssertFalse(decoded.title?.isEmpty ?? true)
        XCTAssertFalse(decoded.body?.isEmpty ?? true)
    }
}
