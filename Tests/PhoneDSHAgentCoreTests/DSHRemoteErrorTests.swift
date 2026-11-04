// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHAgentCore

final class DSHRemoteErrorTests: XCTestCase {
    func testRejectedSettingsPreservesServerCodeMessageAndDetails() throws {
        let response = Data(#"{"type":"server-response","rpcId":"settings-1","result":{"ok":false,"error":{"code":"settings/rejected","message":"Configuration is overridden by a home patch","details":{"ns":"permission"}}}}"#.utf8)
        XCTAssertThrowsError(try DSHWebTransport.unwrap(response, rpcID: "settings-1")) { error in
            guard let remote = error as? DSHRemoteError else { return XCTFail("Expected the server error") }
            XCTAssertEqual(remote.code, "settings/rejected")
            XCTAssertEqual(remote.message, "Configuration is overridden by a home patch")
            XCTAssertEqual(remote.details?["ns"]?.stringValue, "permission")
            XCTAssertEqual(remote.localizedDescription, "[settings/rejected] Configuration is overridden by a home patch")
            XCTAssertFalse(remote.localizedDescription.contains("error 1"))
        }
    }

    func testErrorsWithoutDetailsRemainReadable() {
        let error = DSHRemoteError(code: "gateway/arguments-invalid", message: "unexpected action")
        XCTAssertNil(error.details)
        XCTAssertEqual(error.localizedDescription, "[gateway/arguments-invalid] unexpected action")
    }
}
