// SPDX-License-Identifier: MIT

import XCTest

func assertEqualAsync<T: Equatable>(
    _ expression: @autoclosure () async throws -> T,
    _ expected: T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        let actual = try await expression()
        XCTAssertEqual(actual, expected, file: file, line: line)
    } catch {
        XCTFail("unexpected error: \(error)", file: file, line: line)
    }
}

func assertNilAsync<T>(
    _ expression: @autoclosure () async throws -> T?,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        let actual = try await expression()
        XCTAssertNil(actual, file: file, line: line)
    } catch {
        XCTFail("unexpected error: \(error)", file: file, line: line)
    }
}

func unwrapAsync<T>(
    _ expression: @autoclosure () async throws -> T?,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> T {
    let value = try await expression()
    return try XCTUnwrap(value, file: file, line: line)
}
