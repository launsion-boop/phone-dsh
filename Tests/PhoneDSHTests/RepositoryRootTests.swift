// SPDX-License-Identifier: MIT
// The handoff tests read goldens from the checkout's spec/ tree. These tests
// pin the walk-up lookup that replaces the old fixed parent-hop count, so the
// extracted package (which drops the `sdk/` level) keeps finding them.

import Foundation
import XCTest

final class RepositoryRootTests: XCTestCase {
    private func makeTemporaryRoot() throws -> URL {
        let directory = try HandoffTemporaryDirectory("repository-root")
        addTeardownBlock { directory.cleanUp() }
        return directory.url
    }

    private func writeNestedFile(in root: URL) throws -> URL {
        let file = root.appendingPathComponent("a/b/c/Tests/Target/File.swift")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
        return file
    }

    func testFindsCheckoutRootFromTestSource() throws {
        let root = try XCTUnwrap(repositoryRoot(startingAt: URL(fileURLWithPath: #filePath)))
        var isDirectory: ObjCBool = false
        let spec = root.appendingPathComponent("spec/v1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: spec.path, isDirectory: &isDirectory),
                      "repository root must contain spec/v1: \(root.path)")
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(root, repoRoot())
    }

    func testWalksUpFromNestedDirectoryToSpec() throws {
        let root = try makeTemporaryRoot()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("spec/v1"),
            withIntermediateDirectories: true)
        let file = try writeNestedFile(in: root)
        XCTAssertEqual(repositoryRoot(startingAt: file)?.resolvingSymlinksInPath(),
                       root.resolvingSymlinksInPath())
    }

    func testFallsBackToPackageRootWithoutSpec() throws {
        let root = try makeTemporaryRoot()
        XCTAssertTrue(FileManager.default.createFile(
            atPath: root.appendingPathComponent("Package.swift").path,
            contents: Data("// swift-tools-version: 5.10\n".utf8)))
        let file = try writeNestedFile(in: root)
        XCTAssertEqual(repositoryRoot(startingAt: file)?.resolvingSymlinksInPath(),
                       root.resolvingSymlinksInPath())
    }

    func testReturnsNilOutsideAnyCheckout() throws {
        let root = try makeTemporaryRoot()
        let file = try writeNestedFile(in: root)
        XCTAssertNil(repositoryRoot(startingAt: file))
    }
}
