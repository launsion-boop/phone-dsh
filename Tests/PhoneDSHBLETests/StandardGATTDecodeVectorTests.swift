// SPDX-License-Identifier: MIT
import XCTest
@testable import PhoneDSHBLE

/// The iOS end of `spec/device/v1/golden/standard-gatt-decode.jsonl`; Android's
/// `StandardBleProfileTest` drives its decoder with the same file.
final class StandardGATTDecodeVectorTests: XCTestCase {
    private func bytes(_ hex: String) -> Data {
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    func testSharedVectorsDriveTheRealDecoder() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("spec/device/v1/golden/standard-gatt-decode.jsonl"), encoding: .utf8)
        var valid = 0, invalid = 0
        for line in text.split(separator: "\n") where !line.isEmpty {
            let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            if let level = row["alertLevel"] as? Int {
                if row["error"] != nil {
                    XCTAssertThrowsError(try StandardBLEProfile.alertCommand(level: level), "level \(level)")
                    invalid += 1
                } else {
                    XCTAssertEqual(try StandardBLEProfile.alertCommand(level: level), bytes(row["hex"] as! String))
                    valid += 1
                }
                continue
            }
            let profile = try XCTUnwrap(StandardBLEProfile(rawValue: row["profile"] as! String))
            let data = bytes(row["hex"] as! String)
            if let expected = row["value"] as? String {
                XCTAssertEqual(try profile.decode(data), expected, "\(profile) \(row["hex"]!)")
                valid += 1
            } else {
                XCTAssertThrowsError(try profile.decode(data), "\(profile) \(row["hex"]!) must fail")
                invalid += 1
            }
        }
        // A truncated or valid-only fixture must not turn this green.
        XCTAssertGreaterThanOrEqual(valid, 14)
        XCTAssertGreaterThanOrEqual(invalid, 16)
    }
}
