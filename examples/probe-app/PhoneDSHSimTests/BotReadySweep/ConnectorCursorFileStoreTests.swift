// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHBot
import ProbeKit
import XCTest

/// `ConnectorCursorFileStore` writes exactly the frozen cursor document and
/// reports absent/corrupt distinctly, so the scanner can establish or reset a
/// baseline without guessing.
final class ConnectorCursorFileStoreTests: XCTestCase {
    func testAbsentThenRoundTripForBothConnectorShapes() async throws {
        let directory = tempDirectory()
        let store = ConnectorCursorFileStore(directory: directory)
        guard case .absent = try await store.load(.gmail) else {
            return XCTFail("a missing file must load as absent")
        }

        let gmail = ConnectorCursorState(
            connector: .gmail, cursor: .gmail(historyId: "4100"),
            updatedAt: 1_760_000_000_000)
        try await store.save(gmail)
        guard case .stored(let loadedGmail) = try await store.load(.gmail) else {
            return XCTFail("the saved Gmail cursor must load")
        }
        XCTAssertEqual(loadedGmail, gmail)

        let github = ConnectorCursorState(
            connector: .github,
            cursor: .github(since: "2026-11-20T00:00:00Z",
                            lastModified: "Fri, 20 Nov 2026 00:00:00 GMT"),
            updatedAt: 1_760_000_001_000, status: .reset,
            lastError: .cursorRegressed)
        try await store.save(github)
        guard case .stored(let loadedGithub) = try await store.load(.github) else {
            return XCTFail("the saved GitHub cursor must load")
        }
        XCTAssertEqual(loadedGithub, github)

        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent(
                    "connector-cursor-github.json"))) as? [String: Any])
        XCTAssertEqual(Set(raw.keys),
                       ["version", "connector", "cursor", "updatedAt", "status", "lastError"])
        let cursor = try XCTUnwrap(raw["cursor"] as? [String: Any])
        XCTAssertEqual(Set(cursor.keys), ["since", "lastModified"])
        XCTAssertEqual(cursor["lastModified"] as? String, "Fri, 20 Nov 2026 00:00:00 GMT")
    }

    func testNullLastModifiedIsWrittenAsAnExplicitNull() async throws {
        let directory = tempDirectory()
        let store = ConnectorCursorFileStore(directory: directory)
        try await store.save(ConnectorCursorState(
            connector: .github,
            cursor: .github(since: "2026-11-20T00:00:00Z", lastModified: nil),
            updatedAt: 1))
        let data = try Data(contentsOf: directory.appendingPathComponent(
            "connector-cursor-github.json"))
        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cursor = try XCTUnwrap(raw["cursor"] as? [String: Any])
        XCTAssertTrue(cursor["lastModified"] is NSNull)
        guard case .stored(let loaded) = try await store.load(.github) else {
            return XCTFail("the null-lastModified cursor must load")
        }
        XCTAssertEqual(loaded.cursor,
                       .github(since: "2026-11-20T00:00:00Z", lastModified: nil))
    }

    func testCorruptOrWrongShapeFileLoadsAsCorrupt() async throws {
        let directory = tempDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ConnectorCursorFileStore(directory: directory)
        try Data("not json".utf8).write(to: directory.appendingPathComponent(
            "connector-cursor-gmail.json"))
        guard case .corrupt = try await store.load(.gmail) else {
            return XCTFail("unparseable bytes must load as corrupt")
        }
        // A structurally valid record for another connector is not guessed.
        let github = try ConnectorCursorCodec.encode(ConnectorCursorState(
            connector: .github,
            cursor: .github(since: "2026-11-20T00:00:00Z", lastModified: nil),
            updatedAt: 1))
        try github.write(to: directory.appendingPathComponent(
            "connector-cursor-gmail.json"))
        guard case .corrupt = try await store.load(.gmail) else {
            return XCTFail("a GitHub record in the Gmail slot must load as corrupt")
        }
    }

    func testAnUnreadableCursorFileThrowsAndIsNotOverwritten() async throws {
        let directory = tempDirectory()
        let store = ConnectorCursorFileStore(directory: directory)
        let file = directory.appendingPathComponent("connector-cursor-gmail.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A directory at the file path makes Data(contentsOf:) fail while the
        // path still exists: the file-protection/permission shape.
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        do {
            _ = try await store.load(.gmail)
            XCTFail("an unreadable cursor must not load as absent or corrupt")
        } catch let error as ConnectorCursorStoreError {
            XCTAssertEqual(error, .unavailable)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "loading must not delete or replace the unreadable record")
    }

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("connector-cursor-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
