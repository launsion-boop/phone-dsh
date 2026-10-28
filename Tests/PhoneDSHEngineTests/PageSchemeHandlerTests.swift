// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHEngine: pdsh-page resolution, ranges and CSP.

import Foundation
import XCTest
@testable import PhoneDSHEngine

final class PageSchemeHandlerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-page-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func workspace() throws -> URL {
        let dir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func library() throws -> URL {
        let dir = root.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    func testResolvesWorkspaceAndLibraryRoots() throws {
        let ws = try workspace()
        let lib = try library()
        try write("<html></html>", to: ws.appendingPathComponent("spin.html"))
        try write("three", to: lib.appendingPathComponent("three.module.min.js"))

        let resolver = PDSHPageResolver(libraryRoot: lib, workspaceRoot: { id in
            id == "SESSION-A" ? ws : nil
        })
        let page = try resolver.resolve(URL(string: "pdsh-page://SESSION-A/spin.html")!)
        XCTAssertEqual(page.url.resolvingSymlinksInPath(),
                       ws.appendingPathComponent("spin.html").resolvingSymlinksInPath())
        XCTAssertTrue(page.isHTML)

        let asset = try resolver.resolve(URL(string: "pdsh-page://lib/three.module.min.js")!)
        XCTAssertEqual(asset.url.lastPathComponent, "three.module.min.js")
        XCTAssertFalse(asset.isHTML)
    }

    func testUnknownSessionAndTraversalAreRejected() throws {
        let ws = try workspace()
        let lib = try library()
        let resolver = PDSHPageResolver(libraryRoot: lib, workspaceRoot: { $0 == "S" ? ws : nil })

        XCTAssertThrowsError(try resolver.resolve(URL(string: "pdsh-page://NOPE/a.html")!)) {
            XCTAssertEqual($0 as? PDSHPageResolutionError, .unknownSession("NOPE"))
        }
        XCTAssertThrowsError(try resolver.resolve(URL(string: "pdsh-page://S/../secret.html")!)) {
            XCTAssertEqual($0 as? PDSHPageResolutionError, .invalidPath("/../secret.html"))
        }
        XCTAssertThrowsError(try resolver.resolve(URL(string: "pdsh-page://S/a%5C..%5Cb.html")!)) {
            XCTAssertEqual($0 as? PDSHPageResolutionError, .invalidPath("/a\\..\\b.html"))
        }
    }

    func testSymlinkCannotEscapeTheWorkspace() throws {
        let ws = try workspace()
        let lib = try library()
        let outside = root.appendingPathComponent("secret.txt")
        try write("secret", to: outside)
        try FileManager.default.createSymbolicLink(
            at: ws.appendingPathComponent("leak.txt"), withDestinationURL: outside)

        let resolver = PDSHPageResolver(libraryRoot: lib, workspaceRoot: { _ in ws })
        // The symlink target resolves outside the workspace, so the root
        // prefix check rejects it before any bytes are served.
        XCTAssertThrowsError(try resolver.resolve(URL(string: "pdsh-page://S/leak.txt")!)) {
            XCTAssertEqual($0 as? PDSHPageResolutionError, .pathEscapesRoot("leak.txt"))
        }
    }

    func testMissingFileIsNotFound() throws {
        let ws = try workspace()
        let lib = try library()
        let resolver = PDSHPageResolver(libraryRoot: lib, workspaceRoot: { _ in ws })
        XCTAssertThrowsError(try resolver.resolve(URL(string: "pdsh-page://S/nope.html")!)) {
            XCTAssertEqual($0 as? PDSHPageResolutionError, .notFound("nope.html"))
        }
    }

    func testContentSecurityPolicyTiers() {
        let sandbox = PDSHPageScheme.contentSecurityPolicy(for: .sandbox)
        XCTAssertTrue(sandbox.contains("connect-src 'none'"))
        XCTAssertTrue(sandbox.contains("script-src 'unsafe-inline' blob: pdsh-page:"))
        XCTAssertFalse(sandbox.contains("https:"))

        let local = PDSHPageScheme.contentSecurityPolicy(for: .local)
        XCTAssertTrue(local.contains("connect-src pdsh-page:"))
        XCTAssertFalse(local.contains("https:"))

        let online = PDSHPageScheme.contentSecurityPolicy(for: .online)
        XCTAssertTrue(online.contains("connect-src pdsh-page: https:"))
        XCTAssertTrue(online.contains("https:"))

        for policy in [sandbox, local, online] {
            XCTAssertFalse(policy.contains("file:"))
            XCTAssertFalse(policy.contains("frame-src https:"))
            XCTAssertTrue(policy.contains("object-src 'none'"))
        }
    }

    func testDeclaredTierIsReadFromThePageAndDefaultsToSandbox() {
        XCTAssertEqual(PDSHPageScheme.declaredTier(
            inHTML: Data("<meta name=\"pdsh-csp\" content=\"local\">".utf8)), .local)
        XCTAssertEqual(PDSHPageScheme.declaredTier(
            inHTML: Data("<meta name='pdsh-csp' content='online'>".utf8)), .online)
        XCTAssertEqual(PDSHPageScheme.declaredTier(
            inHTML: Data("<html><head></head></html>".utf8)), .sandbox)
    }

    func testByteRanges() {
        func range(_ header: String, _ total: Int) -> (Int, Int)? {
            guard let value = PDSHPageScheme.byteRange(from: header, total: total) else {
                return nil
            }
            return (value.start, value.end)
        }
        XCTAssertEqual(range("bytes=0-1023", 2048)?.0, 0)
        XCTAssertEqual(range("bytes=0-1023", 2048)?.1, 1023)
        XCTAssertEqual(range("bytes=1024-", 2048)?.0, 1024)
        XCTAssertEqual(range("bytes=1024-", 2048)?.1, 2047)
        XCTAssertEqual(range("bytes=-100", 2048)?.0, 1948)
        XCTAssertEqual(range("bytes=-100", 2048)?.1, 2047)
        XCTAssertEqual(range("bytes=1000-9999", 2048)?.0, 1000)
        XCTAssertEqual(range("bytes=1000-9999", 2048)?.1, 2047)
        XCTAssertNil(PDSHPageScheme.byteRange(from: "bytes=4096-", total: 2048))
        XCTAssertNil(PDSHPageScheme.byteRange(from: "bytes=0-10,20-30", total: 2048))
        XCTAssertNil(PDSHPageScheme.byteRange(from: nil, total: 2048))
        XCTAssertNil(PDSHPageScheme.byteRange(from: "bytes=0-10", total: 0))
    }

    /// The shipped Web3DLib must serve every module the PAGE pages import and
    /// the demo assets; a missing file here is a blank 3D preview on a device.
    func testBundledWeb3DLibServesTheDemoAssets() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let lib = repo.appendingPathComponent("examples/probe-app/Web3DLib")
        let resolver = PDSHPageResolver(libraryRoot: lib, workspaceRoot: { _ in nil })
        let paths = [
            "three.module.min.js", "loaders/GLTFLoader.js",
            "controls/OrbitControls.js", "environments/RoomEnvironment.js",
            "utils/BufferGeometryUtils.js", "scaffold.html",
            "demo/spin.html", "demo/cube.glb",
        ]
        for path in paths {
            let file = try resolver.resolve(URL(string: "pdsh-page://lib/\(path)")!)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path), path)
        }
        let glb = try resolver.resolve(URL(string: "pdsh-page://lib/demo/cube.glb")!)
        let data = try Data(contentsOf: glb.url)
        XCTAssertEqual(Array(data.prefix(4)), Array("glTF".utf8))
        XCTAssertTrue(glb.url.pathExtension == "glb")
    }

    func testContentTypes() {
        XCTAssertEqual(PDSHPageScheme.contentType(forExtension: "glb"),
                       "model/gltf-binary")
        XCTAssertEqual(PDSHPageScheme.contentType(forExtension: "js"),
                       "text/javascript; charset=utf-8")
        XCTAssertEqual(PDSHPageScheme.contentType(forExtension: "unknown"),
                       "application/octet-stream")
    }
}
