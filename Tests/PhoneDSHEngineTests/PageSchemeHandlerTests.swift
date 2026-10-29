// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHEngine: pdsh-page resolution, ranges and CSP.

import Foundation
import WebKit
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

    private func makeHandler(_ resolver: PDSHPageResolver) -> PDSHPageSchemeHandler {
        PDSHPageSchemeHandler(resolver: resolver,
                              deliveryQueue: DispatchQueue(label: "test-page-delivery"))
    }

    private func run(_ handler: PDSHPageSchemeHandler, _ task: FakeTask) {
        handler.start(task)
        wait(for: [task.settled], timeout: 10)
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

    /// Cross-session (spec decision record 4): a page in one session may read
    /// another known session's files; a session the host does not list is
    /// still refused. The app supplies the map from `workspace/follow`.
    func testKnownSessionsResolveAndUnknownSessionsAreRejected() throws {
        let ws = try workspace()
        try Data("asset".utf8).write(to: ws.appendingPathComponent("asset.png"))
        let known: Set<String> = ["SESSION-A", "SESSION-B"]
        let resolver = PDSHPageResolver(libraryRoot: try library(),
                                        workspaceRoot: { known.contains($0) ? ws : nil })
        let page = try resolver.resolve(URL(string: "pdsh-page://SESSION-B/asset.png")!)
        XCTAssertEqual(page.url.lastPathComponent, "asset.png")
        XCTAssertThrowsError(try resolver.resolve(URL(string: "pdsh-page://SESSION-C/asset.png")!)) {
            XCTAssertEqual($0 as? PDSHPageResolutionError, .unknownSession("SESSION-C"))
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

    /// The handler streams one 1 MiB window per `didReceive`, never the whole
    /// mapped file (spec-render-media-v1 task B).
    func testStreamsAFileInOneMiBChunks() throws {
        let ws = try workspace()
        let size = 2 * 1024 * 1024 + 512 * 1024
        let bytes = Data(repeating: 0x41, count: size)
        try bytes.write(to: ws.appendingPathComponent("big.bin"))
        let resolver = PDSHPageResolver(libraryRoot: try library(), workspaceRoot: { _ in ws })
        let handler = makeHandler(resolver)
        let task = FakeTask(url: URL(string: "pdsh-page://S/big.bin")!)
        run(handler, task)

        XCTAssertNil(task.failure)
        XCTAssertTrue(task.finished)
        XCTAssertEqual(task.response?.statusCode, 200)
        XCTAssertEqual(task.response?.value(forHTTPHeaderField: "Content-Length"),
                       String(bytes.count))
        XCTAssertEqual(task.response?.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
        XCTAssertEqual(task.chunks.count, 3)
        XCTAssertTrue(task.chunks.allSatisfy { $0.count <= PDSHPageSchemeHandler.chunkBytes })
        XCTAssertEqual(task.chunks.reduce(Data(), +), bytes)
    }

    func testServesARangeWith206() throws {
        let ws = try workspace()
        let bytes = Data(repeating: 0x42, count: 4096)
        try bytes.write(to: ws.appendingPathComponent("range.bin"))
        let resolver = PDSHPageResolver(libraryRoot: try library(), workspaceRoot: { _ in ws })
        let handler = makeHandler(resolver)
        let task = FakeTask(url: URL(string: "pdsh-page://S/range.bin")!,
                            range: "bytes=100-1023")
        run(handler, task)

        XCTAssertNil(task.failure)
        XCTAssertEqual(task.response?.statusCode, 206)
        XCTAssertEqual(task.response?.value(forHTTPHeaderField: "Content-Range"),
                       "bytes 100-1023/4096")
        XCTAssertEqual(task.response?.value(forHTTPHeaderField: "Content-Length"), "924")
        XCTAssertEqual(task.chunks.reduce(Data(), +), bytes.subdata(in: 100..<1024))
    }

    func testEmptyFileServes200WithZeroLength() throws {
        let ws = try workspace()
        try Data().write(to: ws.appendingPathComponent("empty.bin"))
        let resolver = PDSHPageResolver(libraryRoot: try library(), workspaceRoot: { _ in ws })
        let handler = makeHandler(resolver)
        let task = FakeTask(url: URL(string: "pdsh-page://S/empty.bin")!)
        run(handler, task)

        XCTAssertNil(task.failure)
        XCTAssertEqual(task.response?.statusCode, 200)
        XCTAssertEqual(task.response?.value(forHTTPHeaderField: "Content-Length"), "0")
        XCTAssertTrue(task.chunks.isEmpty)
    }

    func testOutOfBoundsRangeAnswers416() throws {
        let ws = try workspace()
        try Data(repeating: 0x43, count: 4096).write(to: ws.appendingPathComponent("range.bin"))
        let resolver = PDSHPageResolver(libraryRoot: try library(), workspaceRoot: { _ in ws })
        let handler = makeHandler(resolver)
        let task = FakeTask(url: URL(string: "pdsh-page://S/range.bin")!,
                            range: "bytes=999999-")
        run(handler, task)

        XCTAssertNil(task.failure)
        XCTAssertEqual(task.response?.statusCode, 416)
        XCTAssertEqual(task.response?.value(forHTTPHeaderField: "Content-Range"),
                       "bytes */4096")
        XCTAssertTrue(task.chunks.isEmpty)
    }

    /// A stopped task must never see another `didReceive`; WebKit raises an
    /// internal consistency exception for one (task 1).
    func testStopAfterStartSuppressesAllDelivery() throws {
        let ws = try workspace()
        let data = Data(repeating: 0x44, count: 4 * 1024 * 1024)
        try data.write(to: ws.appendingPathComponent("big.bin"))
        let lib = try library()
        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let resolver = PDSHPageResolver(libraryRoot: lib, workspaceRoot: { _ in
            entered.signal()
            gate.wait()
            return ws
        })
        let handler = makeHandler(resolver)
        let task = FakeTask(url: URL(string: "pdsh-page://S/big.bin")!)
        handler.start(task)
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        handler.stop(task)
        gate.signal()
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if !task.chunks.isEmpty || task.finished || task.failure != nil { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertNil(task.response)
        XCTAssertTrue(task.chunks.isEmpty)
        XCTAssertFalse(task.finished)
        XCTAssertNil(task.failure)
    }

    func testUnreadableFileFailsBeforeTheHead() throws {
        let resolver = PDSHPageResolver(libraryRoot: try library(),
                                        workspaceRoot: { _ in try? self.workspace() })
        let handler = makeHandler(resolver)
        let task = FakeTask(url: URL(string: "pdsh-page://S/missing.bin")!)
        run(handler, task)

        XCTAssertNotNil(task.failure)
        XCTAssertNil(task.response)
        XCTAssertTrue(task.chunks.isEmpty)
        XCTAssertFalse(task.finished)
    }

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

/// Minimal in-memory `WKURLSchemeTask` for the handler tests.
private final class FakeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    let settled = XCTestExpectation(description: "the handler settled the task")
    private let lock = NSLock()
    private var _response: HTTPURLResponse?
    private var _chunks: [Data] = []
    private var _finished = false
    private var _failure: Error?

    init(url: URL, range: String? = nil) {
        var request = URLRequest(url: url)
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        self.request = request
    }

    var response: HTTPURLResponse? {
        lock.lock()
        defer { lock.unlock() }
        return _response
    }

    var chunks: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return _chunks
    }

    var finished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _finished
    }

    var failure: Error? {
        lock.lock()
        defer { lock.unlock() }
        return _failure
    }

    func didReceive(_ response: URLResponse) {
        lock.lock()
        _response = response as? HTTPURLResponse
        lock.unlock()
    }

    func didReceive(_ data: Data) {
        lock.lock()
        _chunks.append(data)
        lock.unlock()
    }

    func didFinish() {
        lock.lock()
        _finished = true
        lock.unlock()
        settled.fulfill()
    }

    func didFailWithError(_ error: Error) {
        lock.lock()
        _failure = error
        lock.unlock()
        settled.fulfill()
    }
}
