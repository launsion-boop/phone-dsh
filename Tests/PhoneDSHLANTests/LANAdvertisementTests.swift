// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import PhoneDSHLAN

final class LANAdvertisementTests: XCTestCase {
    func testSharedDiscoveryVectors() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("spec/device/v1/golden/lan-discovery.jsonl")
        for line in try String(contentsOf: fixture, encoding: .utf8).split(separator: "\n") {
            let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let entries = try XCTUnwrap(row["txt_records"] as? [String])
            let raw = entries.reduce(into: Data()) { data, entry in
                let bytes = Array(entry.utf8)
                data.append(UInt8(bytes.count)); data.append(contentsOf: bytes)
            }
            let candidate = LANDeviceCandidate(service: try XCTUnwrap(row["service"] as? String),
                                               host: try XCTUnwrap(row["host"] as? String),
                                               port: try XCTUnwrap(row["port"] as? Int), txt: raw)
            let name = row["name"] as? String ?? "unknown"
            if let url = row["url"] as? String { XCTAssertEqual(candidate?.url.absoluteString, url, name) }
            else { XCTAssertNil(candidate, name) }
        }
    }

    func testMalformedTXTAndCaseInsensitiveDuplicateProfile() {
        XCTAssertNil(LANDeviceCandidate(service: "A", host: "a.local.", port: 443, txt: Data([10, 112])))
        let text = ["profile=pdsh-mcp-1", "PROFILE=pdsh-mcp-1"]
        var raw = Data()
        for entry in text { raw.append(UInt8(entry.utf8.count)); raw.append(contentsOf: entry.utf8) }
        XCTAssertNil(LANDeviceCandidate(service: "A", host: "a.local.", port: 443, txt: raw))
    }

    func testTXTKeysAreNotIdentityAndUnrelatedBinaryTXTIsIgnored() {
        let profile = Array("PrOfIlE=pdsh-mcp-1".utf8)
        var raw = Data([1, 255, UInt8(profile.count)])
        raw.append(contentsOf: profile)
        XCTAssertEqual(LANDeviceCandidate(service: "Light", host: "LIGHT.local.", port: 443, txt: raw)?.url.absoluteString,
                       "https://light.local/mcp")
    }
    @MainActor func testBonjourPublishAndDiscover() async throws {
        let name = "PDSH-" + UUID().uuidString.prefix(8)
        let service = NetService(domain: "local.", type: "_pdsh-mcp._tcp.", name: String(name), port: 18443)
        let txt = NetService.data(fromTXTRecord: ["profile": Data("pdsh-mcp-1".utf8)])
        XCTAssertTrue(service.setTXTRecord(txt))
        service.publish()
        let scanner = LANDeviceDiscovery()
        scanner.start()
        defer { scanner.clear(); service.stop() }
        for _ in 0..<120 {
            if let candidate = scanner.candidates.first(where: { $0.name == name }) {
                XCTAssertEqual(candidate.url.scheme, "https")
                XCTAssertEqual(candidate.url.port, 18443)
                XCTAssertEqual(candidate.url.path, "/mcp")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("The published reference service was not discovered")
    }

}
