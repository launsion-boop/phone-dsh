// SPDX-License-Identifier: MIT
// P09: the chat banner may show a condensed host error, but never a URL with a
// path/query or a credential. These are the shapes the field reports carry.

import Foundation
import XCTest
import ProbeKit

final class ScreenSafeTextTests: XCTestCase {
    func testURLKeepsOnlySchemeHostAndPort() {
        let raw = "POST https://user:pw@api.example.com:8443/v1/messages?key=abc123&x=1 failed: 401"
        let out = ScreenSafeText.condensed(raw)
        XCTAssertTrue(out.contains("https://api.example.com:8443/…"), out)
        XCTAssertFalse(out.contains("pw"), out)
        XCTAssertFalse(out.contains("v1/messages"), out)
        XCTAssertFalse(out.contains("key=abc123"), out)
        XCTAssertTrue(out.contains("401"), "the diagnosis survives")
    }

    func testCredentialsAreMasked() {
        let raw = "provider rejected Bearer sk-live-9f8e7d6c5b4a and api_key=supersecretvalue"
        let out = ScreenSafeText.condensed(raw)
        XCTAssertFalse(out.contains("sk-live-9f8e7d6c5b4a"), out)
        XCTAssertFalse(out.contains("supersecretvalue"), out)
        XCTAssertTrue(out.lowercased().contains("provider rejected"), out)
    }

    func testLongOpaqueBlobsAreMasked() {
        let hex = String(repeating: "a1b2c3d4", count: 6)   // 48 characters
        let out = ScreenSafeText.condensed("sha mismatch \(hex) in journal")
        XCTAssertFalse(out.contains(hex), out)
        XCTAssertTrue(out.contains("sha mismatch"), out)
    }

    func testPlainSentencesAreLeftAlone() {
        let raw = "the inbound writes did not quiesce before the overlay repack"
        XCTAssertEqual(ScreenSafeText.condensed(raw), raw)
    }

    func testOneLineAndBounded() {
        let raw = "first line\nsecond " + String(repeating: "word ", count: 100)
        let out = ScreenSafeText.condensed(raw)
        XCTAssertFalse(out.contains("\n"))
        XCTAssertEqual(out.count, ScreenSafeText.maximumCharacters + 1, "cap plus the ellipsis")
        // A long unbroken blob is a credential shape, so it is masked instead.
        XCTAssertTrue(ScreenSafeText.condensed(String(repeating: "x", count: 400)).contains("***"))
    }

    func testEmptyStaysEmpty() {
        XCTAssertEqual(ScreenSafeText.condensed(""), "")
        XCTAssertEqual(ScreenSafeText.condensed("   "), "")
    }
}
