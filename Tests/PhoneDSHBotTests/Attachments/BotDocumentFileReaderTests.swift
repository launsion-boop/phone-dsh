// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class BotDocumentFileReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bot-document-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private func write(_ data: Data, name: String = "doc.md") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testReadsMarkdownAndReportsItsSize() throws {
        let body = "# 标题\n\n正文。\n"
        let url = try write(Data(body.utf8))
        let result = try BotDocumentFileReader.readText(at: url)
        XCTAssertEqual(result.text, body)
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.byteCount, body.utf8.count)
        XCTAssertEqual(result.limit, BotDocumentFileReader.defaultLimit)
    }

    func testTruncatesPastTheLimitWithAnExplicitFlag() throws {
        let body = String(repeating: "a", count: 300) + "尾巴"
        let url = try write(Data(body.utf8))
        let result = try BotDocumentFileReader.readText(at: url, limit: 128)
        XCTAssertEqual(result.text.utf8.count, 128)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.byteCount, body.utf8.count)
    }

    func testTruncationNeverSplitsAMultiByteScalar() throws {
        // 63 ASCII bytes then a 3-byte scalar straddles a 64-byte cap: the
        // reader must drop the partial scalar instead of emitting U+FFFD.
        let body = String(repeating: "a", count: 63) + "字" + "tail"
        let url = try write(Data(body.utf8))
        let result = try BotDocumentFileReader.readText(at: url, limit: 64)
        XCTAssertEqual(result.text, String(repeating: "a", count: 63))
        XCTAssertTrue(result.truncated)
    }

    func testExactLimitIsNotTruncated() throws {
        let body = String(repeating: "b", count: 64)
        let url = try write(Data(body.utf8))
        let result = try BotDocumentFileReader.readText(at: url, limit: 64)
        XCTAssertEqual(result.text, body)
        XCTAssertFalse(result.truncated)
    }

    func testRejectsNonUTF8InsteadOfShowingReplacementCharacters() throws {
        let url = try write(Data([0xC3, 0x28, 0x0A]))
        XCTAssertThrowsError(try BotDocumentFileReader.readText(at: url)) { error in
            XCTAssertEqual(error as? BotDocumentFileReadError, .notUTF8)
        }
    }

    func testRejectsDirectories() throws {
        XCTAssertThrowsError(try BotDocumentFileReader.readText(at: directory)) { error in
            XCTAssertEqual(error as? BotDocumentFileReadError, .notRegularFile)
        }
    }

    func testRejectsMissingFiles() throws {
        let missing = directory.appendingPathComponent("absent.md")
        XCTAssertThrowsError(try BotDocumentFileReader.readText(at: missing)) { error in
            XCTAssertEqual(error as? BotDocumentFileReadError, .notFound)
        }
    }

    func testStripsAByteOrderMark() throws {
        let url = try write(Data([0xEF, 0xBB, 0xBF]) + Data("# Title".utf8))
        XCTAssertEqual(try BotDocumentFileReader.readText(at: url).text, "# Title")
    }
}
