// SPDX-License-Identifier: MIT

import Foundation
import XCTest

/// `XCTAssertTrue` with an async expression. XCTest's assertion autoclosure is
/// synchronous, so the value is evaluated first and then handed to the normal
/// assertion (same shape as `WP6AssertEqual`).
func XCTAssertTrueAsync(_ expression: @autoclosure () async throws -> Bool,
                        _ message: @autoclosure () -> String = "",
                        file: StaticString = #filePath, line: UInt = #line) async rethrows {
    let value = try await expression()
    XCTAssertTrue(value, message(), file: file, line: line)
}

func XCTAssertFalseAsync(_ expression: @autoclosure () async throws -> Bool,
                         _ message: @autoclosure () -> String = "",
                         file: StaticString = #filePath, line: UInt = #line) async rethrows {
    let value = try await expression()
    XCTAssertFalse(value, message(), file: file, line: line)
}
