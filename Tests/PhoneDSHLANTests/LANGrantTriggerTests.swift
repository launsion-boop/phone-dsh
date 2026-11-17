// SPDX-License-Identifier: MIT
import XCTest
@testable import PhoneDSHLAN

final class LANGrantTriggerTests: XCTestCase {
    private func fire(_ url: String, cred: Bool = true, before: String? = nil, beforeCred: Bool = false) -> LANEndpoint? {
        LANGrantTrigger.newlySaved(beforeURL: before, beforeHasCredential: beforeCred,
                                   afterURL: url, afterHasCredential: cred)
    }

    func testValidLANURLFiresWithCanonicalHostAndDefaultPort() {
        XCTAssertEqual(fire("https://pdsh-lamp.local/mcp"), LANEndpoint(host: "pdsh-lamp.local", port: 443))
        XCTAssertEqual(fire("https://pdsh-lamp.local:443/mcp")?.port, 443)
    }

    func testNonDefaultPortIsKept() {
        XCTAssertEqual(fire("https://dev.example.net:8443/mcp"), LANEndpoint(host: "dev.example.net", port: 8443))
    }

    func testNonCanonicalHostFiresNothing() {
        for url in ["https://Device.local/mcp", "https://device.local./mcp", "https://xn--bcher-kva.example/mcp",
                    "https://192.168.1.5/mcp", "https://[::1]/mcp", "https://printer.123/mcp",
                    "https://dev_ice.local/mcp", "https://-a.local/mcp"] {
            XCTAssertNil(fire(url), url)
        }
    }

    func testNotTheLANEndpointShapeFiresNothing() {
        for url in ["http://device.local/mcp", "https://device.local/other", "https://device.local/",
                    "https://device.local/mcp?x=1", "https://device.local/mcp#f",
                    "https://u:p@device.local/mcp", "https://device.local:0/mcp", "https://device.local:70000/mcp",
                    "not a url", ""] {
            XCTAssertNil(fire(url), url)
        }
    }

    func testGrantWithoutCredentialFiresNothing() {
        XCTAssertNil(fire("https://device.local/mcp", cred: false))
    }

    func testCredentialWithoutValidGrantFiresNothing() {
        XCTAssertNil(fire("https://api.example.com/other", cred: true))
        XCTAssertNil(fire("", cred: true))
    }

    func testUnchangedResaveIsNotATrigger() {
        let url = "https://device.local:8443/mcp"
        XCTAssertNil(fire(url, before: url, beforeCred: true))
    }

    func testCredentialAddedLaterFires() {
        let url = "https://device.local/mcp"
        XCTAssertNotNil(fire(url, before: url, beforeCred: false))
    }

    func testEndpointChangeFiresAgain() {
        XCTAssertEqual(fire("https://device.local:9443/mcp", before: "https://device.local/mcp", beforeCred: true)?.port, 9443)
        XCTAssertEqual(fire("https://other.local/mcp", before: "https://device.local/mcp", beforeCred: true)?.host, "other.local")
        // A non-LAN previous URL does not suppress a LAN one.
        XCTAssertNotNil(fire("https://device.local/mcp", before: "https://api.example.com/x", beforeCred: true))
    }
}
