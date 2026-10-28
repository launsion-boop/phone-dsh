// SPDX-License-Identifier: MIT
// The scenario runner resolves the catalog and fixtures from the checkout
// root. These tests pin the walk-up lookup that replaces the old fixed
// parent-hop count, so the extracted package (which drops the `sdk/` level)
// keeps finding them.

import Foundation
import XCTest
@testable import PhoneDSHScenario

final class ScenarioRepositoryRootTests: XCTestCase {
    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-scenario-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func writeNestedFile(in root: URL) throws -> URL {
        let file = root.appendingPathComponent("a/b/c/Tests/Target/File.swift")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
        return file
    }

    func testFindsCheckoutRootFromTestSource() throws {
        let root = try XCTUnwrap(scenarioRepositoryRoot(
            startingAt: URL(fileURLWithPath: #filePath)))
        let spec = root.appendingPathComponent("spec/v1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: spec.path),
                      "repository root must contain spec/v1: \(root.path)")
    }

    func testWalksUpFromNestedDirectoryToSpec() throws {
        let root = try makeTemporaryRoot()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("spec/v1"),
            withIntermediateDirectories: true)
        let file = try writeNestedFile(in: root)
        XCTAssertEqual(scenarioRepositoryRoot(startingAt: file)?.resolvingSymlinksInPath(),
                       root.resolvingSymlinksInPath())
    }

    func testFallsBackToPackageRootWithoutSpec() throws {
        let root = try makeTemporaryRoot()
        XCTAssertTrue(FileManager.default.createFile(
            atPath: root.appendingPathComponent("Package.swift").path,
            contents: Data("// swift-tools-version: 5.10\n".utf8)))
        let file = try writeNestedFile(in: root)
        XCTAssertEqual(scenarioRepositoryRoot(startingAt: file)?.resolvingSymlinksInPath(),
                       root.resolvingSymlinksInPath())
    }
}
