// SPDX-License-Identifier: MIT
// Drive the inner/relay-plane samples of schema-samples.json through the real
// Swift validators/decoders.

import Foundation
import XCTest
@testable import PhoneDSHPCLink

final class GoldenSchemaSampleTests: XCTestCase {
    private func validate(_ sample: PCLinkJSON, schema: String) throws {
        switch schema {
        case "relay-challenge.schema.json", "relay-auth.schema.json",
             "relay-ready.schema.json", "relay-allow.schema.json",
             "relay-offline.schema.json", "relay-error.schema.json",
             "relay-heartbeat.schema.json", "relay-redirect.schema.json",
             "relay-pair.schema.json":
            _ = try PCLinkWire.validateRelayFrame(sample)
        case "pairing-message.schema.json":
            _ = try PCLinkPairingMessage.decode(sample)
        case "pairing-record.schema.json":
            try PCLinkWire.validatePairingRecordShape(sample, phoneRecord: false)
        case "phone-pairing-record.schema.json":
            try PCLinkWire.validatePairingRecordShape(sample, phoneRecord: true)
        case "e2e-frame.schema.json":
            try PCLinkWire.validateE2EFrame(sample)
        case "e2e-handshake.schema.json":
            try PCLinkWire.validateE2EHandshake(sample)
        case "inner-message.schema.json":
            try PCLinkWire.validateInnerMessage(sample)
        case "endpoints.schema.json":
            try PCLinkWire.validateEndpointsInventory(sample)
        case "admin.schema.json", "admin-challenge.schema.json", "admin-status.schema.json":
            // Admin carrier samples are PC/CLI-side; the phone module does not
            // implement the loopback admin plane.
            break
        default:
            XCTFail("unmapped schema sample \(schema)")
        }
    }

    func testValidSamples() throws {
        let samples = try XCTUnwrap(try TestSupport.schemaSamples()["valid"]?.arrayValue)
        var seen = 0
        for sample in samples {
            let schema = try XCTUnwrap(sample["schema"]?.stringValue)
            if schema.hasPrefix("admin") { continue }
            seen += 1
            let name = try XCTUnwrap(sample["name"]?.stringValue)
            XCTAssertNoThrow(try validate(try XCTUnwrap(sample["value"]), schema: schema),
                             "\(schema)/\(name)")
        }
        XCTAssertGreaterThanOrEqual(seen, 24)
    }

    func testInvalidSamples() throws {
        let samples = try XCTUnwrap(try TestSupport.schemaSamples()["invalid"]?.arrayValue)
        var seen = 0
        for sample in samples {
            let schema = try XCTUnwrap(sample["schema"]?.stringValue)
            if schema.hasPrefix("admin") { continue }
            seen += 1
            let name = try XCTUnwrap(sample["name"]?.stringValue)
            XCTAssertThrowsError(try validate(try XCTUnwrap(sample["value"]), schema: schema),
                                 "\(schema)/\(name): \(sample["reason"]?.stringValue ?? "")")
        }
        XCTAssertGreaterThanOrEqual(seen, 26)
    }

    func testActualEndpointsFileMatchesEmbeddedInventory() throws {
        let document = try TestSupport.endpointsDocument()
        try PCLinkWire.validateEndpointsInventory(document)
        let endpoints = try XCTUnwrap(document["endpoints"]?.arrayValue)
        XCTAssertEqual(endpoints.count, PCLinkEndpoints.inventory.count)
        for entry in endpoints {
            let name = try XCTUnwrap(entry["name"]?.stringValue)
            let spec = try XCTUnwrap(PCLinkEndpoints.spec(for: name), name)
            XCTAssertEqual(spec.kind.rawValue, entry["kind"]?.stringValue, name)
            XCTAssertEqual(spec.retry.rawValue, entry["retry"]?.stringValue, name)
            XCTAssertEqual(spec.phoneOnly, entry["phoneOnly"]?.boolValue, name)
        }
    }
}
