// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import PhoneDSHBot

final class BotModelImageTests: XCTestCase {
    func testLargeImageIsDownscaledAndReencodedWithinTheVisionBudget() throws {
        let source = try makeJPEG(width: 3_000, height: 2_000)
        let prepared = try BotModelImagePreparer.prepare(data: source, name: "camera.jpg")
        XCTAssertLessThanOrEqual(max(prepared.pixelWidth, prepared.pixelHeight),
                                 BotModelImagePolicy.maxDimension)
        XCTAssertLessThanOrEqual(prepared.data.count, BotModelImagePolicy.maxEncodedBytes)
        XCTAssertEqual(prepared.mediaType, "image/jpeg")
        XCTAssertEqual(prepared.name, "camera.jpg")
        XCTAssertEqual(Array(prepared.data.prefix(2)), [0xFF, 0xD8])
        let json = BotModelImagePreparer.mcpJSONValue(prepared)
        XCTAssertEqual(json["type"]?.stringValue, "image")
        XCTAssertEqual(json["mimeType"]?.stringValue, "image/jpeg")
        XCTAssertFalse(json["data"]?.stringValue?.isEmpty ?? true)
    }

    func testSmallImageKeepsItsPixels() throws {
        let source = try makeJPEG(width: 120, height: 80)
        let prepared = try BotModelImagePreparer.prepare(data: source, name: "small.jpg")
        XCTAssertEqual(prepared.pixelWidth, 120)
        XCTAssertEqual(prepared.pixelHeight, 80)
    }

    func testNonImageBytesFailClosed() {
        XCTAssertThrowsError(try BotModelImagePreparer.prepare(
            data: Data("not an image".utf8), name: "notes.txt")) {
            XCTAssertEqual($0 as? BotModelImageError, .unsupported)
        }
        XCTAssertThrowsError(try BotModelImagePreparer.prepare(data: Data(), name: "empty")) {
            XCTAssertEqual($0 as? BotModelImageError, .empty)
        }
    }

    func testBlankNameGetsADeterministicLeaf() throws {
        let prepared = try BotModelImagePreparer.prepare(
            data: try makeJPEG(width: 64, height: 64), name: "  ")
        XCTAssertEqual(prepared.name, "image.jpg")
    }

    private func makeJPEG(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw BotModelImageError.unsupported }
        let colors = [
            CGColor(red: 0.12, green: 0.46, blue: 0.82, alpha: 1),
            CGColor(red: 0.92, green: 0.48, blue: 0.14, alpha: 1),
        ] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: colorSpace, colors: colors, locations: [0, 1]
        ) else { throw BotModelImageError.unsupported }
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: width, y: height),
            options: [])
        guard let image = context.makeImage() else { throw BotModelImageError.unsupported }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, "public.jpeg" as CFString, 1, nil
        ) else { throw BotModelImageError.unsupported }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw BotModelImageError.unsupported
        }
        return output as Data
    }
}
