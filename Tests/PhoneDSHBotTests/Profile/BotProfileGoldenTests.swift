// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class BotProfileGoldenTests: XCTestCase {
    private struct Golden: Decodable {
        struct Source: Decodable {
            let repo: String
            let commit: String
            let files: [String]
        }

        struct Color: Decodable {
            let id: String
            let hex: String
        }

        struct NormalizeCase: Decodable {
            let input: String?
            let output: String?
        }

        struct SeedCase: Decodable {
            let seed: String
            let color: String
            let hex: String
            let hairstyle: String
        }

        let source: Source
        let recordSchemaVersion: Int
        let colors: [Color]
        let colorOrderMain: [String]
        let hairstyles: [String]
        let normalizeFishColor: [NormalizeCase]
        let normalizeFishHairstyle: [NormalizeCase]
        let seed: [SeedCase]
    }

    private func golden() throws -> Golden {
        let url = try ProfileTestSupport.repositoryRoot()
            .appendingPathComponent("spec/bot/v1/golden/bot-profile.json")
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }

    func testGoldenSourcePinsUpstreamRecordSchema() throws {
        let fixture = try golden()
        XCTAssertEqual(fixture.source.repo, "launsion-boop/dsh-bot")
        XCTAssertEqual(fixture.source.commit, "bf4075b0a2e8092b04b726c59a7b085d5a37e6f6")
        XCTAssertEqual(fixture.recordSchemaVersion, 3)
        XCTAssertTrue(fixture.source.commit.count == 40)
        XCTAssertFalse(fixture.source.files.isEmpty)
    }

    func testColorOrderHexAndDisplayNameMatchGolden() throws {
        let fixture = try golden()
        XCTAssertEqual(BotFishColor.allCases.map(\.rawValue), fixture.colors.map(\.id))
        XCTAssertEqual(BotFishColor.allCases.map(\.rawValue), fixture.colorOrderMain)
        XCTAssertEqual(fixture.colors.count, 15)
        for entry in fixture.colors {
            let color = try XCTUnwrap(BotFishColor(rawValue: entry.id), entry.id)
            XCTAssertEqual(color.hex, entry.hex, entry.id)
            XCTAssertFalse(color.displayName.isEmpty, entry.id)
        }

        let expectedNames: [BotFishColor: String] = [
            .white: "白", .brown: "棕", .red: "红", .orange: "橘", .amber: "橙黄",
            .green: "绿", .teal: "青绿", .blue: "蓝", .purple: "紫", .magenta: "桃红",
            .gray: "灰", .black: "黑", .silver: "银", .peach: "粉肤", .sky: "天蓝",
        ]
        for color in BotFishColor.allCases {
            XCTAssertEqual(color.displayName, expectedNames[color], color.rawValue)
        }
    }

    func testHairstyleOrderAndNamesMatchGolden() throws {
        let fixture = try golden()
        XCTAssertEqual(BotFishHairstyle.allCases.map(\.rawValue), fixture.hairstyles)
        XCTAssertEqual(fixture.hairstyles, ["long", "twin-tail", "bob", "side-braid"])
        let expectedNames: [BotFishHairstyle: String] = [
            .long: "经典长卷发", .twinTail: "高双马尾", .bob: "短鲍伯", .sideBraid: "粗侧辫",
        ]
        for hairstyle in BotFishHairstyle.allCases {
            XCTAssertEqual(hairstyle.displayName, expectedNames[hairstyle], hairstyle.rawValue)
            XCTAssertFalse(hairstyle.accessibilityHint.isEmpty, hairstyle.rawValue)
        }
    }

    func testNormalizeFishColorGolden() throws {
        for entry in try golden().normalizeFishColor {
            XCTAssertEqual(BotProfileNormalizer.fishColor(entry.input)?.rawValue, entry.output,
                           "input: \(String(describing: entry.input))")
        }
    }

    func testNormalizeFishHairstyleGolden() throws {
        for entry in try golden().normalizeFishHairstyle {
            XCTAssertEqual(BotProfileNormalizer.fishHairstyle(entry.input)?.rawValue, entry.output,
                           "input: \(String(describing: entry.input))")
        }
    }

    func testSeedGoldenIncludingAstralScalar() throws {
        for entry in try golden().seed {
            let seeded = BotFishAppearance.seed(entry.seed)
            XCTAssertEqual(seeded.color.rawValue, entry.color, "seed: \(entry.seed)")
            XCTAssertEqual(seeded.color.hex, entry.hex, "seed: \(entry.seed)")
            XCTAssertEqual(seeded.hairstyle.rawValue, entry.hairstyle, "seed: \(entry.seed)")
        }

        // The golden's `🐟bot` case locks the JavaScript charCodeAt(0)
        // behaviour: the astral scalar contributes its high surrogate only.
        let astral = BotFishAppearance.seed("🐟bot")
        XCTAssertEqual(astral.color, .sky)
        XCTAssertEqual(astral.hairstyle, .twinTail)
    }

    func testResolveUsesSeedFromIDThenNameThenLiteralFish() throws {
        let auto = BotProfile(id: "main", name: "ignored")
        let resolved = BotFishAppearance.resolve(auto)
        XCTAssertEqual(resolved.color, .silver)
        XCTAssertEqual(resolved.hairstyle, .bob)
        XCTAssertTrue(resolved.autoColor)
        XCTAssertTrue(resolved.autoHairstyle)

        let nameSeeded = BotProfile(id: "", name: "main")
        XCTAssertEqual(BotFishAppearance.resolve(nameSeeded).color, .silver)
        XCTAssertEqual(BotFishAppearance.resolve(nameSeeded).hairstyle, .bob)

        let fallback = BotProfile(id: "", name: "")
        XCTAssertEqual(BotFishAppearance.resolve(fallback).color, .sky)
        XCTAssertEqual(BotFishAppearance.resolve(fallback).hairstyle, .sideBraid)
    }

    func testResolvePrefersExplicitFieldsIndividually() throws {
        let profile = BotProfile(id: "🐟bot", name: "ignored",
                                 fishColor: .red, fishHairstyle: nil)
        let resolved = BotFishAppearance.resolve(profile)
        XCTAssertEqual(resolved.color, .red)
        XCTAssertFalse(resolved.autoColor)
        XCTAssertEqual(resolved.hairstyle, .twinTail)
        XCTAssertTrue(resolved.autoHairstyle)

        let classic = BotFishAppearance.classic
        XCTAssertEqual(classic.color, .blue)
        XCTAssertEqual(classic.hairstyle, .long)
        XCTAssertFalse(classic.autoColor)
        XCTAssertFalse(classic.autoHairstyle)
    }
}

enum ProfileTestSupport {
    struct FixtureError: Error, CustomStringConvertible {
        let description: String
    }

    static func repositoryRoot() throws -> URL {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let marker = candidate.appendingPathComponent("spec/bot/v1/golden")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        throw FixtureError(description: "cannot locate Bot golden directory from #filePath")
    }

    static func temporaryDirectory(_ name: String = "profile") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneDSHBot-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
