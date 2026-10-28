// SPDX-License-Identifier: MIT
// CRC32C known-answer tests (Castagnoli, reflected, init/xorout 0xFFFFFFFF).

import Foundation
import XCTest
import PhoneDSHWire

final class CRC32CTests: XCTestCase {
    func testKnownAnswer() {
        XCTAssertEqual(CRC32C.checksum(Array("123456789".utf8)), 0xE306_9283)
    }

    func testEmptyInputIsZero() {
        XCTAssertEqual(CRC32C.checksum([UInt8]()), 0)
    }

    func testIncrementalUpdateMatchesConcatenation() {
        let first = Array("1234".utf8)
        let second = Array("56789".utf8)
        let whole = CRC32C.checksum(first + second)
        XCTAssertEqual(CRC32C.update(CRC32C.checksum(first), with: second), whole)
    }

    func testHeaderConstantCRC() {
        let prefix = Data([
            0x58, 0x4C, 0x57, 0x41, 0x4C, 0x31, 0x00, 0x00,
            0x00, 0x01, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])
        XCTAssertEqual(CRC32C.checksum(prefix), 0x0B0F_9536)
    }
}
