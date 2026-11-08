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

    func testSharedRawDiscoveryVectors() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("spec/device/v1/golden/lan-discovery-raw.jsonl")
        let lines = try String(contentsOf: fixture, encoding: .utf8).split(separator: "\n")
        XCTAssertFalse(lines.isEmpty)
        var names = Set<String>()
        var validCount = 0
        var invalidCount = 0
        for line in lines {
            let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let name = try XCTUnwrap(row["name"] as? String)
            XCTAssertTrue(names.insert(name).inserted, "Duplicate vector: \(name)")
            let hex = try XCTUnwrap(row["txt_hex"] as? String)
            guard hex.count.isMultiple(of: 2) else { XCTFail("Odd hex length: \(name)"); continue }
            var raw = Data()
            var index = hex.startIndex
            while index < hex.endIndex {
                let end = hex.index(index, offsetBy: 2)
                raw.append(try XCTUnwrap(UInt8(hex[index..<end], radix: 16), name))
                index = end
            }
            let candidate = LANDeviceCandidate(service: try XCTUnwrap(row["service"] as? String),
                                               host: try XCTUnwrap(row["host"] as? String),
                                               port: try XCTUnwrap(row["port"] as? Int), txt: raw)
            let expectedURL = row["url"] as? String
            let expectedError = row["error"] as? String
            XCTAssertNotEqual(expectedURL == nil, expectedError == nil, name)
            if let expectedURL {
                validCount += 1
                XCTAssertEqual(candidate?.url.absoluteString, expectedURL, name)
            } else {
                invalidCount += 1
                XCTAssertEqual(expectedError, "invalid_advertisement", name)
                XCTAssertNil(candidate, name)
            }
        }
        XCTAssertGreaterThan(validCount, 0)
        XCTAssertGreaterThan(invalidCount, 0)
        XCTAssertTrue(Set(["valid", "truncated", "duplicate_case", "ipv4_dotted", "ipv4_short",
                           "hex_prefix_only", "named_numeric_final", "unicode_kelvin_casefold",
                           "numeric_label_named_domain"]).isSubset(of: names))
    }

    private func rows(_ file: String) throws -> [[String: Any]] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("spec/device/v1/golden/\(file)"), encoding: .utf8)
        return try text.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    private static let profileTXT: Data = {
        let entry = Array("profile=pdsh-mcp-1".utf8)
        return Data([UInt8(entry.count)] + entry)
    }()

    func testSharedALabelVectors() throws {
        let rows = try rows("lan-discovery-alabel.jsonl")
        let names = Set(rows.compactMap { $0["name"] as? String })
        XCTAssertEqual(names.count, rows.count)
        XCTAssertTrue(Set(["alabel_invalid_punycode", "alabel_valid_latin", "alabel_uppercase",
                           "alabel_unicode_version_dependent", "alabel_final_label", "ulabel_latin",
                           "ulabel_ideographic_full_stop", "ldh_double_hyphen_34", "ldh_xn_inside_label"]).isSubset(of: names))
        var outcomes = Set<Bool>()
        for row in rows {
            let name = try XCTUnwrap(row["name"] as? String)
            let hex = try XCTUnwrap(row["txt_hex"] as? String)
            var raw = Data()
            var index = hex.startIndex
            while index < hex.endIndex {
                let end = hex.index(index, offsetBy: 2)
                raw.append(try XCTUnwrap(UInt8(hex[index..<end], radix: 16), name))
                index = end
            }
            let candidate = LANDeviceCandidate(service: try XCTUnwrap(row["service"] as? String),
                                               host: try XCTUnwrap(row["host"] as? String),
                                               port: try XCTUnwrap(row["port"] as? Int), txt: raw)
            XCTAssertNotEqual(row["url"] == nil, row["error"] == nil, name)
            outcomes.insert(row["url"] != nil)
            if let url = row["url"] as? String {
                XCTAssertEqual(candidate?.url.absoluteString, url, name)
                XCTAssertEqual(candidate?.url.host, URLComponents(string: url)?.host, name)
            } else {
                XCTAssertEqual(row["error"] as? String, "invalid_advertisement", name)
                XCTAssertNil(candidate, name)
            }
        }
        XCTAssertEqual(outcomes, [true, false])
    }

    func testSharedPublicationVectorsKeepOneHostname() throws {
        let rows = try rows("lan-publication.jsonl")
        XCTAssertEqual(Set(rows.compactMap { $0["result"] as? String }),
                       ["consistent", "hostname_invalid", "certificate_name_missing", "srv_target_invalid",
                        "srv_target_mismatch", "srv_port_mismatch"])
        for row in rows {
            let name = try XCTUnwrap(row["name"] as? String)
            let candidate = LANDeviceCandidate(service: "Lamp", host: try XCTUnwrap(row["srv_target"] as? String),
                                               port: try XCTUnwrap(row["srv_port"] as? Int), txt: Self.profileTXT)
            XCTAssertEqual(candidate?.url.absoluteString, row["url"] as? String, name)
            if row["result"] as? String == "consistent" {
                let configured = try XCTUnwrap(LANDeviceCandidate.hostname(try XCTUnwrap(row["hostname"] as? String)), name)
                // The URL host is what URLSession uses for SNI and certificate verification.
                XCTAssertEqual(candidate?.url.host, configured, name)
            }
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
