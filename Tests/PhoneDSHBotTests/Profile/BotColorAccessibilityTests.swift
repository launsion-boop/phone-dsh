// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotColorAccessibilityTests: XCTestCase {
    private let light = BotColorAccessibility.RGB.white
    private let dark = BotColorAccessibility.RGB(red: 0x1C / 255,
                                                 green: 0x1C / 255,
                                                 blue: 0x1E / 255)

    func testHexParsingAndRoundTrip() throws {
        let blue = try XCTUnwrap(BotColorAccessibility.rgb(hex: "#1680F3"))
        XCTAssertEqual(blue.hexString, "#1680F3")
        XCTAssertEqual(BotColorAccessibility.rgb(hex: "1680F3"), blue)
        XCTAssertNil(BotColorAccessibility.rgb(hex: "#12345"))
        XCTAssertNil(BotColorAccessibility.rgb(hex: "#GGGGGG"))
    }

    /// Every avatar coat must be readable as card ink, on both card surfaces.
    func testEveryAvatarCoatMeetsTheCardContrastTarget() throws {
        for color in BotFishColor.allCases {
            let source = try XCTUnwrap(BotColorAccessibility.rgb(hex: color.hex))
            for (background, label) in [(light, "light"), (dark, "dark")] {
                let adjusted = BotColorAccessibility.accessible(
                    source, on: background, minimumContrast: 4.5)
                XCTAssertGreaterThanOrEqual(
                    BotColorAccessibility.contrastRatio(adjusted, background), 4.49,
                    "\(color.rawValue) on \(label): \(adjusted.hexString)")
            }
        }
    }

    /// A strong coat must keep its hue and stay close to the avatar. The old
    /// fixed `value * 0.42` / `value + (1-value) * 0.48` transform turned
    /// purple into navy/pastel; the contrast walk may only move the channels a
    /// little.
    func testStrongCoatsStayCloseToTheAvatarColour() throws {
        let purple = try XCTUnwrap(BotColorAccessibility.rgb(hex: "#8F59F9"))
        let lightAccent = BotColorAccessibility.accessible(purple, on: light)
        let darkAccent = BotColorAccessibility.accessible(purple, on: dark)
        XCTAssertEqual(lightAccent.hexString, "#8A56F0")
        XCTAssertEqual(darkAccent.hexString, "#9863FF")

        let blue = try XCTUnwrap(BotColorAccessibility.rgb(hex: "#1680F3"))
        let blueAccent = BotColorAccessibility.accessible(blue, on: light)
        XCTAssertEqual(blueAccent.hexString, "#1475DF")

        for (source, adjusted) in [(purple, lightAccent), (purple, darkAccent), (blue, blueAccent)] {
            let delta = max(abs(source.red - adjusted.red),
                            abs(source.green - adjusted.green),
                            abs(source.blue - adjusted.blue))
            XCTAssertLessThanOrEqual(delta * 255, 25,
                                     "\(source.hexString) moved too far to \(adjusted.hexString)")
        }
    }

    /// Pale coats still need a readable sibling on white.
    func testPaleCoatsBecomeReadableOnWhite() throws {
        for hex in ["#FFFFFF", "#C9CBD1", "#F3B6A4", "#7ED0E8", "#FFB224"] {
            let source = try XCTUnwrap(BotColorAccessibility.rgb(hex: hex))
            let adjusted = BotColorAccessibility.accessible(source, on: light)
            XCTAssertGreaterThanOrEqual(
                BotColorAccessibility.contrastRatio(adjusted, light), 4.49,
                "\(hex) -> \(adjusted.hexString)")
            XCTAssertNotEqual(adjusted.hexString, source.hexString)
        }
    }

    /// Decorative fills only need to be visible; they keep the exact avatar
    /// hex whenever it clears that lower bar (all saturated coats).
    func testDecorativeBrandKeepsTheExactAvatarHex() throws {
        for hex in ["#8F59F9", "#1680F3", "#E5484D", "#14C16F", "#FFB224", "#F93498"] {
            let source = try XCTUnwrap(BotColorAccessibility.rgb(hex: hex))
            XCTAssertEqual(
                BotColorAccessibility.accessible(source, on: light, minimumContrast: 1.5),
                source, "\(hex) lost its exact brand colour")
        }
        let white = try XCTUnwrap(BotColorAccessibility.rgb(hex: "#FFFFFF"))
        let visibleWhite = BotColorAccessibility.accessible(white, on: light, minimumContrast: 1.5)
        XCTAssertGreaterThanOrEqual(
            BotColorAccessibility.contrastRatio(visibleWhite, light), 1.49)
    }

    /// Dark cards already give the saturated coats enough contrast; the raw
    /// avatar hex must survive untouched.
    func testDarkModeKeepsTheAvatarHexForMostCoats() throws {
        for hex in ["#FFB224", "#14C16F", "#F93498", "#C9CBD1", "#7ED0E8"] {
            let source = try XCTUnwrap(BotColorAccessibility.rgb(hex: hex))
            XCTAssertEqual(
                BotColorAccessibility.accessible(source, on: dark),
                source, "\(hex) changed on the dark card")
        }
    }

    func testInvalidContrastTargetIsANoOp() throws {
        let purple = try XCTUnwrap(BotColorAccessibility.rgb(hex: "#8F59F9"))
        XCTAssertEqual(
            BotColorAccessibility.accessible(purple, on: light, minimumContrast: 1),
            purple)
    }
}
